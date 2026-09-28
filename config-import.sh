#!/bin/sh

# BEGIN MIHOMO LIFECYCLE LOCK v1
# Kept identical in standalone consumers (curl | sh needs no library).
# A short mkdir guard serializes ALL metadata changes, including stale recovery.
# Never steal this guard: a crash inside its tiny critical section fails closed.
# An operator may remove an abandoned guard only with maintenance stopped.
MIHOMO_LIFECYCLE_LOCK="/tmp/mihomo-lifecycle.lock.d"
MAINT_MARKER="/tmp/mihomo.maintenance"
ML_ID=""
ML_GATE=""
ML_MARKER=""
ML_LIFECYCLE_HELD=0

ml_starttime() {
    local data tail
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    data=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    # comm (field 2) may contain spaces and ')'; strip through its LAST ') '.
    tail=${data##*) }
    [ "$tail" != "$data" ] || return 1
    printf '%s\n' "$tail" | awk 'NF >= 20 && $20 ~ /^[0-9]+$/ { print $20; ok=1 } END { if (!ok) exit 1 }'
}

ml_identity() {
    local start
    [ -n "$ML_ID" ] && return 0
    start=$(ml_starttime "$$") || return 1
    ML_ID="$$ $start"
}

# 0 = live identity, 1 = proven stale, 2 = unknown (never steal).
ml_owner_state() {
    local pid start extra current
    IFS=' ' read -r pid start extra < "$1" || return 2
    case "$pid" in ''|0*|*[!0-9]*) return 2 ;; esac
    case "$start" in ''|*[!0-9]*) return 2 ;; esac
    [ -z "$extra" ] || return 2
    if current=$(ml_starttime "$pid"); then
        [ "$current" = "$start" ] && return 0
        return 1
    fi
    [ ! -d "/proc/$pid" ] && return 1
    return 2
}

ml_gate_enter() {
    [ -z "$ML_GATE" ] || return 1
    (umask 077; mkdir "$1.guard") 2>/dev/null || return 1
    ML_GATE="$1.guard"
}

ml_gate_leave() {
    [ -n "$ML_GATE" ] || return 0
    rmdir "$ML_GATE" 2>/dev/null || return 1
    ML_GATE=""
}

ml_lock_acquire() {
    local path state
    path=$1
    ml_identity || return 1
    ml_gate_enter "$path" || return 1
    if [ -e "$path" ] || [ -L "$path" ]; then
        if [ ! -d "$path" ] || [ -L "$path" ] || [ ! -f "$path/owner" ] || [ -L "$path/owner" ]; then
            ml_gate_leave
            return 1
        fi
        if ml_owner_state "$path/owner"; then state=0; else state=$?; fi
        if [ "$state" -ne 1 ]; then
            ml_gate_leave
            return 1
        fi
        # Under the guard no new owner can appear between inspect/remove/mkdir.
        if ! rm -f "$path/owner" || ! rmdir "$path"; then
            ml_gate_leave
            return 1
        fi
    fi
    if ! (umask 077; mkdir "$path"); then
        ml_gate_leave
        return 1
    fi
    if ! printf '%s\n' "$ML_ID" > "$path/owner"; then
        rm -f "$path/owner"
        rmdir "$path" 2>/dev/null || true
        ml_gate_leave
        return 1
    fi
    ml_gate_leave
}

ml_lock_release() {
    local path
    path=$1
    [ -n "$ML_ID" ] || return 0
    # A signal during metadata work may already own this short guard.
    if [ "$ML_GATE" != "$path.guard" ]; then
        ml_gate_enter "$path" || return 1
    fi
    if [ -d "$path" ] && [ ! -L "$path" ] && [ -f "$path/owner" ] &&
       [ ! -L "$path/owner" ] && [ "$(cat "$path/owner" 2>/dev/null)" = "$ML_ID" ]; then
        if [ "$path" = "$MIHOMO_LIFECYCLE_LOCK" ] && [ -n "$ML_MARKER" ] &&
           [ ! -L "$MAINT_MARKER" ] && [ -f "$MAINT_MARKER" ] &&
           [ "$(cat "$MAINT_MARKER" 2>/dev/null)" = "$ML_MARKER" ]; then
            rm -f "$MAINT_MARKER" || { ml_gate_leave; return 1; }
        fi
        rm -f "$path/owner" || { ml_gate_leave; return 1; }
        rmdir "$path" 2>/dev/null || { ml_gate_leave; return 1; }
    fi
    ml_gate_leave
}

# Old tools do not participate in this protocol. Never remove their lock files;
# require a quiescent handover. A PID-only live marker is conservatively busy.
ml_legacy_busy() {
    local path
    for path in /tmp/mihomo-update.lock /tmp/mihomo-update.lock.d \
        /tmp/mihomo-config-import.lock.d /tmp/mihomo-migrate.lock \
        /tmp/mihomo-migrate.lock.d /tmp/mihomo-tun-migrate.lock.d; do
        if [ -e "$path" ] || [ -L "$path" ]; then return 0; fi
    done
    return 1
}

ml_marker_busy() {
    local pid stamp start extra current
    [ -e "$MAINT_MARKER" ] || [ -L "$MAINT_MARKER" ] || return 1
    [ -f "$MAINT_MARKER" ] && [ ! -L "$MAINT_MARKER" ] || return 0
    IFS=' ' read -r pid stamp start extra < "$MAINT_MARKER" || return 0
    case "$pid" in ''|*[!0-9]*) return 0 ;; esac
    if current=$(ml_starttime "$pid"); then
        case "$start" in ''|*[!0-9]*) return 0 ;; esac
        [ "$start" != "$current" ] && [ -z "$extra" ] && return 1
        return 0
    fi
    [ ! -d "/proc/$pid" ] && return 1
    return 0
}

ml_lifecycle_acquire() {
    ml_lock_acquire "$MIHOMO_LIFECYCLE_LOCK" || return 1
    ML_LIFECYCLE_HELD=1
    if ml_legacy_busy || ml_marker_busy; then
        ml_lifecycle_release
        return 1
    fi
    # First two fields remain compatible with older watchdogs.
    ML_MARKER="$$ $(date +%s) ${ML_ID#* }"
    if ! (umask 077; printf '%s\n' "$ML_MARKER" > "$MAINT_MARKER"); then
        ml_lifecycle_release
        return 1
    fi
    return 0
}

ml_lifecycle_release() {
    [ "$ML_LIFECYCLE_HELD" -eq 1 ] || return 0
    ml_lock_release "$MIHOMO_LIFECYCLE_LOCK" || return 1
    ML_LIFECYCLE_HELD=0
    ML_MARKER=""
}
# END MIHOMO LIFECYCLE LOCK v1


# Safe Mihomo configuration importer for keenetic-auto-setup.
#
# Usage:
#   curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/config-import.sh | sh
#   sh config-import.sh /path/to/config.yaml
#
# Interactive mode reads pasted YAML from /dev/tty so it still works when
# this script itself is delivered through "curl | sh". Finish with Ctrl+D.
#
# Safety:
# candidate -> contract check -> controlled one-Mihomo stop -> mihomo -t ->
# previous-config backup -> atomic rename -> start/process/port verification.
# Any post-commit failure restores the previous config and service state.

set -e

CONFIG_DIR="/opt/etc/mihomo"
CONFIG_PATH="$CONFIG_DIR/config.yaml"
BACKUP_PATH="$CONFIG_DIR/config.yaml.bak"
STAGE_CONFIG="$CONFIG_DIR/.config.yaml.new.$$"
BACKUP_STAGE="$CONFIG_DIR/.config.yaml.bak.new.$$"
ROLLBACK_STAGE="$CONFIG_DIR/.config.yaml.rollback.$$"
TEST_LOG="/tmp/mihomo-config-test.$$"
INIT_SCRIPT="/opt/etc/init.d/S99mihomo"

SERVICE_WAS_RUNNING=0
SERVICE_STOPPED_BY_US=0
CONFIG_REPLACED=0
CONFIG_COMMIT_STARTED=0

# Terminal status colors are presentation only. Semantic prefixes remain the
# source of truth; redirects/log captures stay plain and NO_COLOR/TERM=dumb
# disable ANSI output.
COLOR_RESET=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_RED=""
COLOR_CYAN=""
COLOR_ERR_RESET=""
COLOR_ERR_RED=""

if [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    if [ -t 1 ] 2>/dev/null; then
        COLOR_RESET=$(printf '\033[0m')
        COLOR_GREEN=$(printf '\033[1;32m')
        COLOR_YELLOW=$(printf '\033[1;33m')
        COLOR_RED=$(printf '\033[1;31m')
        COLOR_CYAN=$(printf '\033[1;36m')
    fi
    if [ -t 2 ] 2>/dev/null; then
        COLOR_ERR_RESET=$(printf '\033[0m')
        COLOR_ERR_RED=$(printf '\033[1;31m')
    fi
fi

status_out() { printf '%s%s%s\n' "$1" "$2" "$COLOR_RESET"; }
status_err() { printf '%s%s%s\n' "$COLOR_ERR_RED" "$1" "$COLOR_ERR_RESET" >&2; }

log() { status_out "$COLOR_GREEN" "[config] $1"; }
warn() { status_out "$COLOR_YELLOW" "[WARN] $1"; }
error() { status_err "[ERROR] $1"; exit 1; }

resolve_mihomo() {
    for _cm_bin in /opt/sbin/mihomo /opt/bin/mihomo; do
        if [ -x "$_cm_bin" ]; then
            printf '%s\n' "$_cm_bin"
            return 0
        fi
    done
    return 1
}

cleanup() {
    rm -f "$STAGE_CONFIG" "$BACKUP_STAGE" "$ROLLBACK_STAGE" "$TEST_LOG" 2>/dev/null || true
    ml_lifecycle_release || true
}







mihomo_running() {
    pidof mihomo >/dev/null 2>&1
}

stop_mihomo_confirmed() {
    "$INIT_SCRIPT" stop >/dev/null 2>&1 || true
    _ci_try=0
    while [ "$_ci_try" -lt 10 ]; do
        if ! mihomo_running; then
            SERVICE_STOPPED_BY_US=1
            return 0
        fi
        sleep 1
        _ci_try=$((_ci_try + 1))
    done
    return 1
}

start_mihomo_confirmed() {
    "$INIT_SCRIPT" start >/dev/null 2>&1 || true
    _ci_try=0
    while [ "$_ci_try" -lt 8 ]; do
        mihomo_running && return 0
        sleep 1
        _ci_try=$((_ci_try + 1))
    done
    return 1
}

contract_port_listening() {
    if command -v netstat >/dev/null 2>&1; then
        netstat -tln 2>/dev/null | grep -q '[:.]7890[[:space:]]'
        return $?
    fi
    if command -v ss >/dev/null 2>&1; then
        ss -tln 2>/dev/null | grep -q '[:.]7890[[:space:]]'
        return $?
    fi
    return 2
}

wait_for_contract_port() {
    _ci_try=0
    while [ "$_ci_try" -le 8 ]; do
        if contract_port_listening; then
            return 0
        else
            _ci_rc=$?
        fi
        [ "$_ci_rc" -eq 2 ] && return 2
        [ "$_ci_try" -eq 8 ] && break
        sleep 1
        _ci_try=$((_ci_try + 1))
    done
    return 1
}

restore_old_service() {
    if [ "$SERVICE_WAS_RUNNING" -ne 1 ]; then
        return 0
    fi

    if ! mihomo_running; then
        log "Restoring previous Mihomo service state..."
        start_mihomo_confirmed || return 1
    fi

    if wait_for_contract_port; then
        log "Previous Mihomo service restored; port 7890 is listening."
        return 0
    fi

    _ci_restore_port_rc=$?
    if [ "$_ci_restore_port_rc" -eq 2 ]; then
        warn "Previous Mihomo process was restored, but neither netstat nor ss is available to verify port 7890."
        return 0
    fi

    return 1
}

rollback_config() {
    _ci_reason="$1"
    log "Rolling back config.yaml..."

    if mihomo_running; then
        "$INIT_SCRIPT" stop >/dev/null 2>&1 || true
        _ci_try=0
        while [ "$_ci_try" -lt 10 ]; do
            mihomo_running || break
            sleep 1
            _ci_try=$((_ci_try + 1))
        done
    fi

    [ -s "$BACKUP_PATH" ] ||
        error "$_ci_reason — rollback backup is missing or empty: $BACKUP_PATH"

    cp -f "$BACKUP_PATH" "$ROLLBACK_STAGE" ||
        error "$_ci_reason — cannot stage rollback config. Backup remains at $BACKUP_PATH"
    chmod 600 "$ROLLBACK_STAGE" 2>/dev/null || true

    mv -f "$ROLLBACK_STAGE" "$CONFIG_PATH" ||
        error "$_ci_reason — cannot restore config.yaml atomically. Backup remains at $BACKUP_PATH"

    CONFIG_REPLACED=0
    CONFIG_COMMIT_STARTED=0
    log "Previous config restored."

    if [ "$SERVICE_WAS_RUNNING" -eq 1 ]; then
        start_mihomo_confirmed ||
            error "$_ci_reason — old config restored, but Mihomo did not restart. Backup: $BACKUP_PATH"
        log "Previous Mihomo service restored."
    fi

    error "$_ci_reason — new config rejected, previous config restored."
}

signal_handler() {
    trap '' INT TERM HUP
    warn "Import interrupted ($1)."
    if [ "$CONFIG_COMMIT_STARTED" -eq 1 ] || [ "$CONFIG_REPLACED" -eq 1 ]; then
        rollback_config "Import interrupted"
    fi
    if [ "$SERVICE_STOPPED_BY_US" -eq 1 ]; then
        restore_old_service || true
    fi
    cleanup
    exit 1
}

trap cleanup EXIT
trap 'signal_handler INT' INT
trap 'signal_handler TERM' TERM
trap 'signal_handler HUP' HUP

echo "=== Mihomo Config Import ==="

command -v pidof >/dev/null 2>&1 ||
    error "pidof is required for the one-Mihomo safety check."
[ -x "$INIT_SCRIPT" ] || error "Mihomo init script not found: $INIT_SCRIPT"
[ -d "$CONFIG_DIR" ] || error "Mihomo config directory not found: $CONFIG_DIR. Run setup.sh first."
[ -s "$CONFIG_PATH" ] || error "Current config.yaml is missing or empty. Run setup.sh first."

MIHOMO_BIN=$(resolve_mihomo) || error "Mihomo binary not found in /opt/sbin or /opt/bin."

umask 077
rm -f "$STAGE_CONFIG" "$BACKUP_STAGE" "$ROLLBACK_STAGE" "$TEST_LOG" 2>/dev/null || true

if [ "$#" -gt 1 ]; then
    error "Usage: sh config-import.sh [config.yaml]"
fi

if [ "$#" -eq 1 ]; then
    [ -f "$1" ] && [ -s "$1" ] || error "Input file is missing or empty: $1"
    cp -f "$1" "$STAGE_CONFIG" || error "Could not stage input file."
    log "Configuration loaded from: $1"
else
    [ -r /dev/tty ] ||
        error "Interactive terminal not available. Save YAML to a file and run: sh config-import.sh /path/to/config.yaml"
    echo
    echo "Open the generator if needed:"
    echo "  https://saymer-alt.github.io/link-generators/"
    echo
    echo "Paste the COMPLETE Mihomo YAML starting with its first line."
    echo "When the paste is finished, press Ctrl+D once."
    echo "To skip import, type only: s"
    echo "Nothing will be changed until the candidate passes validation."
    echo
    printf "YAML (or s to skip): " > /dev/tty

    if ! IFS= read -r _ci_first_line < /dev/tty; then
        echo
        log "No configuration entered; import skipped."
        exit 0
    fi

    case "$_ci_first_line" in
        s|S|skip|SKIP)
            log "Config import skipped."
            exit 0
            ;;
    esac

    printf '%s\n' "$_ci_first_line" > "$STAGE_CONFIG"
    cat < /dev/tty >> "$STAGE_CONFIG"
    echo
    log "Configuration received."
fi

[ -s "$STAGE_CONFIG" ] || error "Received configuration is empty."

if ! grep -Eq '^[[:space:]]*mixed-port:[[:space:]]*7890([[:space:]]*(#.*)?)?$' "$STAGE_CONFIG"; then
    error "Project contract missing: config must contain 'mixed-port: 7890'. Existing config was not changed."
fi
log "Project contract found: mixed-port 7890."

ml_lifecycle_acquire ||
    error "Mihomo lifecycle is busy or unverifiable; config not changed. Check /tmp/mihomo-lifecycle.lock.d and its .guard."

if mihomo_running; then
    SERVICE_WAS_RUNNING=1
    log "Mihomo is running. Stopping it for one-instance config validation..."
    stop_mihomo_confirmed ||
        error "Mihomo did not stop. Candidate left uninstalled; refusing to run a second Mihomo process."
else
    log "Mihomo was already stopped; it will remain stopped after a successful import."
fi

if updater_in_progress; then
    restore_old_service || true
    error "Mihomo updater became active during config import. Candidate was not installed."
fi

log "Validating candidate with Mihomo..."
if ! "$MIHOMO_BIN" -d "$CONFIG_DIR" -f "$STAGE_CONFIG" -t >"$TEST_LOG" 2>&1; then
    echo
    cat "$TEST_LOG" 2>/dev/null || true
    echo
    restore_old_service || true
    error "Mihomo rejected the candidate config. Existing config.yaml was not changed."
fi
log "Mihomo config test passed."

log "Saving previous config as $BACKUP_PATH ..."
cp -f "$CONFIG_PATH" "$BACKUP_STAGE" || {
    restore_old_service || true
    error "Could not create config backup; candidate was not installed."
}

_old_size=$(wc -c < "$CONFIG_PATH" 2>/dev/null || true)
_bak_size=$(wc -c < "$BACKUP_STAGE" 2>/dev/null || true)
[ -n "$_old_size" ] && [ "$_old_size" = "$_bak_size" ] || {
    restore_old_service || true
    error "Config backup verification failed; candidate was not installed."
}

chmod 600 "$BACKUP_STAGE" 2>/dev/null || true
mv -f "$BACKUP_STAGE" "$BACKUP_PATH" || {
    restore_old_service || true
    error "Could not commit config backup; candidate was not installed."
}

if updater_in_progress; then
    restore_old_service || true
    error "Mihomo updater became active before config commit. Candidate was not installed."
fi

log "Installing config atomically..."
chmod 600 "$STAGE_CONFIG" 2>/dev/null || true
CONFIG_COMMIT_STARTED=1
if ! mv -f "$STAGE_CONFIG" "$CONFIG_PATH"; then
    restore_old_service || true
    error "Atomic config replacement failed. Existing config remains recoverable at $BACKUP_PATH"
fi
CONFIG_REPLACED=1

log "Re-checking installed config..."
if ! "$MIHOMO_BIN" -d "$CONFIG_DIR" -t >"$TEST_LOG" 2>&1; then
    echo
    cat "$TEST_LOG" 2>/dev/null || true
    echo
    rollback_config "Installed config failed Mihomo validation"
fi

if [ "$SERVICE_WAS_RUNNING" -eq 1 ]; then
    log "Starting Mihomo with the new config..."
    if ! start_mihomo_confirmed; then
        rollback_config "Mihomo did not start with the new config"
    fi

    if wait_for_contract_port; then
        log "Port 7890 is listening."
    else
        _ci_port_rc=$?
        if [ "$_ci_port_rc" -eq 2 ]; then
            warn "Neither netstat nor ss is available; process start was verified but port 7890 could not be checked."
        else
            rollback_config "Mihomo started but project port 7890 did not become ready"
        fi
    fi
else
    log "Service state preserved: Mihomo remains stopped."
fi

CONFIG_REPLACED=0
CONFIG_COMMIT_STARTED=0
SERVICE_STOPPED_BY_US=0

echo
status_out "$COLOR_GREEN" "[OK] Mihomo configuration installed successfully."
status_out "$COLOR_GREEN" "[OK] Previous configuration backup: $BACKUP_PATH"
if [ "$SERVICE_WAS_RUNNING" -eq 1 ]; then
    status_out "$COLOR_GREEN" "[OK] Mihomo is running with the new config."
else
    status_out "$COLOR_CYAN" "[info] Mihomo was stopped before import and was left stopped."
fi
