#!/bin/sh

# =========================================================
# MIHOMO TUN BOOTSTRAP MIGRATION
# ---------------------------------------------------------
# Adds the project-standard top-level TUN block to a legacy
# Mihomo config that has no top-level `tun:` section.
#
# Stack policy:
# - Mihomo >= 1.19.31 -> prefer `stack: mips`
# - older or unparseable version -> compatibility `stack: gvisor`
# - candidate config is always validated with the real `mihomo -t`
# - if a >=1.19.31 build still rejects mips explicitly, fall back
#   to gvisor and validate again
#
# The added block matches the normal router profile produced by
# saymer-alt/link-generators:
#   tun:
#     enable: true
#     device: mitun0
#     stack: mips|gvisor
#     auto-route: false
#     auto-detect-interface: true
#
# Safety:
# - existing top-level tun: is never rewritten by this script
# - one-Mihomo invariant: no binary execution beside a live daemon
# - controlled stop before version/config probes
# - per-run rollback copy + persistent config.yaml.pre-tun backup
# - same-filesystem candidate + atomic config replace
# - maintenance marker prevents watchdog resurrection mid-transaction
# - running service is restored and mitun0 + port 7890 are verified
# - a user-stopped service stays stopped
# - --check is strictly read-only
# =========================================================

set -e

CONFIG_DIR="/opt/etc/mihomo"
CONFIG="$CONFIG_DIR/config.yaml"
PERSIST_BACKUP="$CONFIG_DIR/config.yaml.pre-tun"
TMP_NEW="$CONFIG_DIR/.config.yaml.tun-tmp.$$"
RUN_BACKUP="/tmp/mihomo-tun-config.backup.$$"
VALIDATE_ERR="/tmp/mihomo-tun-validate.$$"
LOCK_DIR="/tmp/mihomo-tun-migrate.lock.d"
LOCK_TOOL_MARKER="migrate-mihomo-tun"
MAINT_MARKER="/tmp/mihomo.maintenance"
MIN_MIPS_VERSION="1.19.31"

COLOR_RESET=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_RED=""
COLOR_CYAN=""
COLOR_ERR_RESET=""
COLOR_ERR_RED=""

if [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    if [ -t 1 ] 2>/dev/null; then
        COLOR_RESET=$(printf "\033[0m")
        COLOR_GREEN=$(printf "\033[1;32m")
        COLOR_YELLOW=$(printf "\033[1;33m")
        COLOR_RED=$(printf "\033[1;31m")
        COLOR_CYAN=$(printf "\033[1;36m")
    fi
    if [ -t 2 ] 2>/dev/null; then
        COLOR_ERR_RESET=$(printf "\033[0m")
        COLOR_ERR_RED=$(printf "\033[1;31m")
    fi
fi

status_out() { printf "%s%s%s\n" "$1" "$2" "$COLOR_RESET"; }
status_err() { printf "%s%s%s\n" "$COLOR_ERR_RED" "$1" "$COLOR_ERR_RESET" >&2; }
log()  { status_out "$COLOR_GREEN" "[migrate-tun] $1"; }
info() { status_out "$COLOR_CYAN" "[INFO] $1"; }
warn() { status_out "$COLOR_YELLOW" "[WARN] $1"; }
error() { status_err "[ERROR] $1"; exit 1; }

CHECK_ONLY=0
SERVICE_WAS_RUNNING=0
SERVICE_WAS_STOPPED=0
REPLACEMENT_DONE=0
LOCK_HELD=0
MIHOMO_BIN=""
INIT_SCRIPT=""
CURRENT_VER=""
SELECTED_STACK=""
CFG_MODE=""

usage() {
    echo "Usage: sh migrate-mihomo-tun.sh [--check]"
}

ver_compare() {
    _va=$1; _vb=$2
    while :; do
        _a=${_va%%.*}; _ra=""
        case "$_va" in *.*) _ra=${_va#*.} ;; esac
        _b=${_vb%%.*}; _rb=""
        case "$_vb" in *.*) _rb=${_vb#*.} ;; esac
        [ -z "$_a" ] && _a=0
        [ -z "$_b" ] && _b=0
        case "$_a$_b" in *[!0-9]*) echo unknown; return 0 ;; esac
        if [ "$_a" -lt "$_b" ]; then echo lt; return 0; fi
        if [ "$_a" -gt "$_b" ]; then echo gt; return 0; fi
        if [ -z "$_ra" ] && [ -z "$_rb" ]; then echo eq; return 0; fi
        _va=$_ra; _vb=$_rb
    done
}

has_top_level_tun() {
    grep -Eq "^tun:[[:space:]]*" "$CONFIG" 2>/dev/null
}

resolve_mihomo_binary() {
    if command -v pidof >/dev/null 2>&1; then
        for _p in $(pidof mihomo 2>/dev/null); do
            _exe=$(readlink "/proc/$_p/exe" 2>/dev/null) || continue
            case "$_exe" in
                /opt/sbin/mihomo|/opt/bin/mihomo)
                    [ -x "$_exe" ] && { printf "%s\n" "$_exe"; return 0; }
                    ;;
            esac
        done
    fi
    [ -x /opt/sbin/mihomo ] && { printf "%s\n" /opt/sbin/mihomo; return 0; }
    [ -x /opt/bin/mihomo ] && { printf "%s\n" /opt/bin/mihomo; return 0; }
    return 0
}

read_current_ver() {
    CURRENT_VER=""
    if _vo=$("$MIHOMO_BIN" -v 2>/dev/null); then
        CURRENT_VER=$(printf "%s\n" "$_vo" | head -n 1 | awk "{print \$3}" | sed "s/^v//")
        case "$CURRENT_VER" in
            ""|*[!0-9.]*) CURRENT_VER="" ;;
        esac
        return 0
    fi
    return 1
}

choose_stack_from_version() {
    SELECTED_STACK="gvisor"
    if [ -n "$CURRENT_VER" ]; then
        _rel=$(ver_compare "$CURRENT_VER" "$MIN_MIPS_VERSION")
        case "$_rel" in
            eq|gt) SELECTED_STACK="mips" ;;
            lt) SELECTED_STACK="gvisor" ;;
            *) SELECTED_STACK="gvisor" ;;
        esac
    fi
}

write_candidate() {
    _stack=$1
    cat "$CONFIG" > "$TMP_NEW" || return 1
    printf "\n" >> "$TMP_NEW" || return 1
    printf "tun:\n" >> "$TMP_NEW" || return 1
    printf "  enable: true\n" >> "$TMP_NEW" || return 1
    printf "  device: mitun0\n" >> "$TMP_NEW" || return 1
    printf "  stack: %s\n" "$_stack" >> "$TMP_NEW" || return 1
    printf "  auto-route: false\n" >> "$TMP_NEW" || return 1
    printf "  auto-detect-interface: true\n" >> "$TMP_NEW" || return 1
    [ -n "$CFG_MODE" ] && chmod "$CFG_MODE" "$TMP_NEW" 2>/dev/null || true
}

validate_candidate() {
    rm -f "$VALIDATE_ERR" 2>/dev/null || true
    "$MIHOMO_BIN" -t -d "$CONFIG_DIR" -f "$TMP_NEW" >/dev/null 2>"$VALIDATE_ERR"
}

port_ok() {
    if command -v curl >/dev/null 2>&1; then
        curl -s --connect-timeout 3 --max-time 5 "http://127.0.0.1:7890" >/dev/null 2>&1 && return 0
        return 1
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q -T 5 -O /dev/null "http://127.0.0.1:7890" >/dev/null 2>&1 && return 0
        return 1
    fi
    return 2
}

stop_mihomo_confirmed() {
    "$INIT_SCRIPT" stop >/dev/null 2>&1 || true
    SERVICE_WAS_STOPPED=1
    _i=0
    while [ "$_i" -lt 10 ]; do
        pidof mihomo >/dev/null 2>&1 || return 0
        sleep 1
        _i=$((_i + 1))
    done
    return 1
}

restore_service_if_needed() {
    [ "$SERVICE_WAS_RUNNING" -eq 1 ] || return 0
    [ -n "$INIT_SCRIPT" ] || return 0
    if pidof mihomo >/dev/null 2>&1; then
        return 0
    fi
    "$INIT_SCRIPT" start >/dev/null 2>&1 || true
    _i=0
    while [ "$_i" -lt 10 ]; do
        pidof mihomo >/dev/null 2>&1 && return 0
        sleep 1
        _i=$((_i + 1))
    done
    return 1
}

rollback_config() {
    [ -f "$RUN_BACKUP" ] || return 1
    cp -f "$RUN_BACKUP" "$CONFIG" || return 1
    [ -n "$CFG_MODE" ] && chmod "$CFG_MODE" "$CONFIG" 2>/dev/null || true
    return 0
}

lock_tool_alive() {
    for _d in /proc/[0-9]*; do
        [ "$_d" = "/proc/$$" ] && continue
        [ "$_d" = "/proc/$PPID" ] && continue
        grep -q "$LOCK_TOOL_MARKER" "$_d/cmdline" 2>/dev/null && return 0
    done
    return 1
}

acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
        date +%s > "$LOCK_DIR/ts" 2>/dev/null || true
        LOCK_HELD=1
        return 0
    fi
    [ -d "$LOCK_DIR" ] || error "Migration lock path is not a directory: $LOCK_DIR"
    _lp=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    case "$_lp" in
        ""|*[!0-9]*) : ;;
        *)
            if [ -d "/proc/$_lp" ] && grep -q "$LOCK_TOOL_MARKER" "/proc/$_lp/cmdline" 2>/dev/null; then
                error "Another TUN migration is already running (pid $_lp)."
            fi
            ;;
    esac
    lock_tool_alive && error "Another TUN migration process is already running."
    _stale="$LOCK_DIR.stale.$$"
    if mv "$LOCK_DIR" "$_stale" 2>/dev/null; then
        rm -rf "$_stale"
        mkdir "$LOCK_DIR" 2>/dev/null || error "Could not acquire migration lock."
        echo "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
        date +%s > "$LOCK_DIR/ts" 2>/dev/null || true
        LOCK_HELD=1
        return 0
    fi
    error "Could not acquire migration lock."
}

cleanup() {
    rm -f "$TMP_NEW" "$RUN_BACKUP" "$VALIDATE_ERR" 2>/dev/null || true
    rm -f "$MAINT_MARKER" 2>/dev/null || true
    if [ "$LOCK_HELD" -eq 1 ]; then
        rm -rf "$LOCK_DIR" 2>/dev/null || true
    fi
}

signal_handler() {
    trap "" INT TERM HUP
    warn "Received $1 - aborting migration."
    if [ "$REPLACEMENT_DONE" -eq 1 ]; then
        warn "Config was already replaced; rolling back the current transaction."
        if rollback_config; then
            if [ "$SERVICE_WAS_RUNNING" -eq 1 ] && [ -n "$INIT_SCRIPT" ]; then
                "$INIT_SCRIPT" restart >/dev/null 2>&1 || true
            fi
        else
            warn "Automatic config rollback failed; persistent backup remains at $PERSIST_BACKUP"
        fi
    else
        restore_service_if_needed || warn "Could not confirm Mihomo service restoration."
    fi
    cleanup
    exit 1
}

for arg in "$@"; do
    case "$arg" in
        --check) CHECK_ONLY=1 ;;
        -h|--help) usage; exit 0 ;;
        *) error "Unknown argument: $arg" ;;
    esac
done

if [ ! -f "$CONFIG" ]; then
    info "No config at $CONFIG - nothing to migrate."
    exit 0
fi
[ -r "$CONFIG" ] || error "Config is not readable: $CONFIG"

if has_top_level_tun; then
    if grep -Eq "^[[:space:]]*stack:[[:space:]]*gvisor([[:space:]].*)?$" "$CONFIG" 2>/dev/null; then
        info "Top-level tun: already exists and gvisor is present. This script does not rewrite existing TUN; use migrate-mihomo-mips.sh for the stack-only migration."
    elif grep -Eq "^[[:space:]]*stack:[[:space:]]*mips([[:space:]].*)?$" "$CONFIG" 2>/dev/null; then
        status_out "$COLOR_GREEN" "[OK] Top-level tun: already exists and mips is present - nothing to add."
    else
        info "Top-level tun: already exists. Existing TUN settings are preserved; nothing was changed."
    fi
    exit 0
fi

MIHOMO_BIN=$(resolve_mihomo_binary)
[ -n "$MIHOMO_BIN" ] || error "Mihomo binary not found in canonical Entware paths."
INIT_SCRIPT=$(find /opt/etc/init.d -name "*mihomo*" -type f 2>/dev/null | head -n 1)

if [ "$CHECK_ONLY" -eq 1 ]; then
    echo "=== Mihomo TUN bootstrap migration check (read-only) ==="
    info "Top-level tun: is absent; this legacy config is eligible for TUN bootstrap migration."
    info "The migrator would add device mitun0, auto-route:false and auto-detect-interface:true."
    if command -v pidof >/dev/null 2>&1 && ! pidof mihomo >/dev/null 2>&1; then
        if read_current_ver; then
            choose_stack_from_version
            if [ "$SELECTED_STACK" = "mips" ]; then
                status_out "$COLOR_GREEN" "[OK] Mihomo $CURRENT_VER -> migration would prefer stack: mips."
            else
                info "Mihomo ${CURRENT_VER:-unknown} -> migration would use compatibility stack: gvisor; mips requires Mihomo >= $MIN_MIPS_VERSION."
            fi
        else
            warn "Could not execute Mihomo version probe; apply mode would abort rather than modify the config."
        fi
    else
        info "Runtime version probe skipped while Mihomo is running (one-Mihomo invariant). Apply mode determines the version after a controlled stop."
    fi
    exit 0
fi

command -v pidof >/dev/null 2>&1 || error "pidof is required for safe apply mode (one-Mihomo invariant)."

if pidof mihomo >/dev/null 2>&1; then
    SERVICE_WAS_RUNNING=1
    [ -n "$INIT_SCRIPT" ] || error "Mihomo is running but no init script was found; refusing an unmanaged stop."
fi

acquire_lock
echo "$$ $(date +%s)" > "$MAINT_MARKER" 2>/dev/null || true
trap cleanup EXIT
trap "signal_handler INT" INT
trap "signal_handler TERM" TERM
trap "signal_handler HUP" HUP

if command -v stat >/dev/null 2>&1; then
    CFG_MODE=$(stat -c "%a" "$CONFIG" 2>/dev/null) || true
fi

if [ "$SERVICE_WAS_RUNNING" -eq 1 ]; then
    log "Stopping Mihomo for safe version/config validation..."
    stop_mihomo_confirmed || error "Mihomo did not stop; config untouched."
fi

pidof mihomo >/dev/null 2>&1 && error "Mihomo is still running; refusing to execute a second instance."

if ! read_current_ver; then
    restore_service_if_needed || true
    error "Mihomo version probe failed with the daemon stopped; config untouched."
fi
choose_stack_from_version

if [ "$SELECTED_STACK" = "mips" ]; then
    log "Mihomo $CURRENT_VER meets >= $MIN_MIPS_VERSION; selecting stack: mips."
else
    if [ -n "$CURRENT_VER" ]; then
        warn "Mihomo $CURRENT_VER is older than $MIN_MIPS_VERSION; adding TUN with compatibility stack: gvisor. Upgrade Mihomo to use stack: mips."
    else
        warn "Mihomo version is unparseable; adding TUN with compatibility stack: gvisor. stack: mips requires a confirmed Mihomo >= $MIN_MIPS_VERSION."
    fi
fi

write_candidate "$SELECTED_STACK" || { restore_service_if_needed || true; error "Could not build candidate config."; }

log "Validating candidate config with mihomo -t..."
if ! validate_candidate; then
    if [ "$SELECTED_STACK" = "mips" ] && grep -qi "invalid tun stack" "$VALIDATE_ERR" 2>/dev/null; then
        warn "This build rejected stack: mips despite its version; falling back to gvisor."
        SELECTED_STACK="gvisor"
        write_candidate "$SELECTED_STACK" || { restore_service_if_needed || true; error "Could not rebuild gvisor candidate."; }
        if ! validate_candidate; then
            restore_service_if_needed || true
            error "gvisor candidate also failed mihomo -t; config untouched."
        fi
    else
        restore_service_if_needed || true
        error "Candidate config failed mihomo -t; config untouched."
    fi
fi

cp -f "$CONFIG" "$RUN_BACKUP" || { restore_service_if_needed || true; error "Could not create per-run rollback copy."; }
[ -n "$CFG_MODE" ] && chmod "$CFG_MODE" "$RUN_BACKUP" 2>/dev/null || true
if [ ! -f "$PERSIST_BACKUP" ]; then
    cp -f "$CONFIG" "$PERSIST_BACKUP" || { restore_service_if_needed || true; error "Could not create persistent backup $PERSIST_BACKUP."; }
    [ -n "$CFG_MODE" ] && chmod "$CFG_MODE" "$PERSIST_BACKUP" 2>/dev/null || true
    log "Persistent pre-TUN backup saved: $PERSIST_BACKUP"
else
    info "Persistent pre-TUN backup already exists and is kept unchanged: $PERSIST_BACKUP"
fi

log "Committing TUN block atomically..."
if ! mv -f "$TMP_NEW" "$CONFIG"; then
    restore_service_if_needed || true
    error "Atomic config replace failed; original config is still available in the rollback copy."
fi
REPLACEMENT_DONE=1

if [ "$SERVICE_WAS_RUNNING" -eq 1 ]; then
    log "Starting Mihomo with the migrated config..."
    "$INIT_SCRIPT" start >/dev/null 2>&1 || true

    _process_ok=0
    _tun_ok=0
    _port_rc=1
    _i=0
    while [ "$_i" -lt 15 ]; do
        pidof mihomo >/dev/null 2>&1 && _process_ok=1 || _process_ok=0
        [ -d /sys/class/net/mitun0 ] && _tun_ok=1 || _tun_ok=0
        _port_rc=0
        port_ok || _port_rc=$?
        if [ "$_process_ok" -eq 1 ] && [ "$_tun_ok" -eq 1 ] && { [ "$_port_rc" -eq 0 ] || [ "$_port_rc" -eq 2 ]; }; then
            break
        fi
        sleep 1
        _i=$((_i + 1))
    done

    if [ "$_process_ok" -ne 1 ] || [ "$_tun_ok" -ne 1 ] || [ "$_port_rc" -eq 1 ]; then
        warn "Post-migration verification failed (process=$_process_ok mitun0=$_tun_ok port7890_rc=$_port_rc); rolling back."
        rollback_config || error "Migration failed and automatic config rollback failed. Restore $PERSIST_BACKUP manually."
        "$INIT_SCRIPT" restart >/dev/null 2>&1 || true
        REPLACEMENT_DONE=0
        error "Rolled back to the pre-migration config."
    fi
    [ "$_port_rc" -eq 2 ] && warn "No curl/wget available; port 7890 probe skipped, but process and mitun0 were confirmed."
    status_out "$COLOR_GREEN" "[OK] Mihomo is running and mitun0 is present."
else
    info "Mihomo was stopped before migration; service state is preserved. mitun0 will appear when Mihomo starts successfully."
fi

REPLACEMENT_DONE=0
status_out "$COLOR_GREEN" "[OK] Added project TUN block with device mitun0 and stack: $SELECTED_STACK."
if [ "$SELECTED_STACK" = "gvisor" ]; then
    info "stack: mips requires Mihomo >= $MIN_MIPS_VERSION. After upgrading, use migrate-mihomo-mips.sh for the stack-only migration."
fi
info "Persistent pre-TUN backup: $PERSIST_BACKUP"
exit 0
