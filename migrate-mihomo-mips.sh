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


# =========================================================
# MIHOMO MIPS STACK MIGRATION
# ---------------------------------------------------------
# Rewrites `stack: gvisor` -> `stack: mips` inside an existing
# Mihomo configuration (the "mips" TUN stack = Mihomo IP Stack,
# supported since mihomo 1.19.31). Read-only with --check.
#
# Guaranteed properties:
# - idempotent: an already-migrated config is a safe no-op
# - minimal mutation: only TUN `stack` key values change
#   (the schema has no other `stack` key); everything else in
#   the user config is preserved byte-for-byte
# - the new config is validated with `mihomo -t` BEFORE the
#   atomic same-filesystem replace; the user config is never
#   edited in place
# - service state preservation: the service is restarted only
#   when it was running before the migration; a user-stopped
#   service stays stopped
# - backup: /opt/etc/mihomo/config.yaml.pre-mips, kept after
#   success as a persistent revert artifact, never overwritten
# - per-run snapshot of the current config for atomic rollback;
#   the historical .pre-mips file is never a transaction rollback source
# - at most one Mihomo instance runs at any moment: the
#   service is stopped (and the stop confirmed) before any
#   probe or validation executes the binary; a watchdog-revived
#   instance is re-stopped before every binary execution and
#   before the final start
# - no secrets or config contents are printed, only statuses
#   and counters
# - locking (apply mode): atomic mkdir lock with stale-safe takeover
#   and PID+cmdline ownership; the legacy plain-file lock form is
#   still honored (a legacy lock backed by a live migration process
#   blocks the run, an orphaned one is reclaimed); --check never locks
#
# Feature detection: the binary is asked, not trusted —
# `mihomo -t` on a minimal config with `stack: mips` fails at
# config parse time ("invalid tun stack") on binaries older
# than 1.19.31 and passes on 1.19.31+. The version is only a
# cheap pre-filter.
#
# Usage:
#   sh migrate-mihomo-mips.sh [--check]
#
# Exit codes: 0 = migrated, safe no-op, or completed --check;
#             1 = failure (system restored, or fatal documented)
# =========================================================

set -e

CONFIG_DIR="/opt/etc/mihomo"
CONFIG="$CONFIG_DIR/config.yaml"
BACKUP="$CONFIG_DIR/config.yaml.pre-mips"
TMP_NEW="$CONFIG_DIR/.config.yaml.mips-tmp"
RUN_BACKUP="$CONFIG_DIR/.config.yaml.mips-backup.$$"
ROLLBACK_STAGE="$CONFIG_DIR/.config.yaml.mips-rollback.$$"
RECOVERY_FAILED=0

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

# Runtime probes and apply join lifecycle; --check never changes config/service.
acquire_lock() {
  ml_lifecycle_acquire || error "Mihomo lifecycle is busy or unverifiable; no migration started. Check /tmp/mihomo-lifecycle.lock.d and its .guard."
}
GATE_HOME="/tmp/mihomo-migrate-gate.$$"
MIN_VERSION="1.19.31"

CHECK_ONLY=0
SERVICE_WAS_RUNNING=0
SERVICE_WAS_STOPPED=0
REPLACEMENT_DONE=0
MIHOMO_BIN=""
INIT_SCRIPT=""
GATE_REASON=""

log()   { status_out "$COLOR_GREEN" "[migrate] $1"; }
warn()  { status_out "$COLOR_YELLOW" "[WARN] $1"; }
error() { status_out "$COLOR_RED" "[ERROR] $1"; exit 1; }

usage() {
  echo "Usage: sh migrate-mihomo-mips.sh [--check]"
}

# -----------------------------
# Numeric dotted-version comparator: prints lt | eq | gt, or
# "unknown" when either version carries non-numeric components.
# Same minimal comparator as update-mihomo.sh.
# -----------------------------
ver_compare() {
  _va=$1
  _vb=$2
  while :; do
    _a=${_va%%.*}
    _ra=""
    case "$_va" in *.*) _ra=${_va#*.} ;; esac
    _b=${_vb%%.*}
    _rb=""
    case "$_vb" in *.*) _rb=${_vb#*.} ;; esac
    if [ -z "$_a" ]; then _a=0; fi
    if [ -z "$_b" ]; then _b=0; fi
    case "$_a$_b" in
      *[!0-9]*) echo unknown; return 0 ;;
    esac
    if [ "$_a" -lt "$_b" ]; then echo lt; return 0; fi
    if [ "$_a" -gt "$_b" ]; then echo gt; return 0; fi
    if [ -z "$_ra" ] && [ -z "$_rb" ]; then echo eq; return 0; fi
    _va=$_ra
    _vb=$_rb
  done
}

# TUN stack key counters. The `stack` yaml key exists in the
# mihomo schema only for TUN structures (the main tun block and
# per-proxy tun listeners), so every match is a TUN stack value.
count_gvisor() {
  _n=$(grep -cE '^[[:space:]]*stack:[[:space:]]*gvisor([[:space:]].*)?$' "$1" 2>/dev/null) || true
  if [ -z "$_n" ]; then _n=0; fi
  echo "$_n"
}
count_mips() {
  _n=$(grep -cE '^[[:space:]]*stack:[[:space:]]*mips([[:space:]].*)?$' "$1" 2>/dev/null) || true
  if [ -z "$_n" ]; then _n=0; fi
  echo "$_n"
}

# Read the installed version. Empty result means "could not
# read" (missing binary, crash under memory pressure, garbage).
read_current_ver() {
  CURRENT_VER=""
  if VERSION_OUTPUT=$("$MIHOMO_BIN" -v 2>/dev/null); then
    CURRENT_VER=$(echo "$VERSION_OUTPUT" | head -1 | awk '{print $3}' | sed 's/^v//')
  fi
}

# Ask the binary whether it accepts tun.stack: mips. The check
# is parse-time only: `mihomo -t` never creates devices or
# starts listeners. Returns 0 = supported; 1 = not, with
# GATE_REASON = unsupported | crash | error.
support_gate() {
  GATE_REASON=""
  _gdir="$1"
  rm -rf "$_gdir"
  mkdir -p "$_gdir"
  printf 'tun:\n  enable: true\n  stack: mips\n' > "$_gdir/gate.yaml"
  _gerr="$_gdir/err.txt"
  if "$MIHOMO_BIN" -t -d "$_gdir" -f "$_gdir/gate.yaml" > /dev/null 2> "$_gerr"; then
    return 0
  fi
  if grep -q "invalid tun stack" "$_gerr" 2>/dev/null; then
    GATE_REASON="unsupported"
  elif [ ! -s "$_gerr" ]; then
    GATE_REASON="crash"
  else
    GATE_REASON="error"
  fi
  return 1
}

# Stop Mihomo and confirm it is really down before anything may
# execute the binary. Returns 1 when the daemon refused to stop.
stop_mihomo_confirmed() {
  "$INIT_SCRIPT" stop >/dev/null 2>&1 || true
  SERVICE_WAS_STOPPED=1
  _i=0
  while [ "$_i" -lt 10 ]; do
    pidof mihomo >/dev/null 2>&1 || break
    sleep 1
    _i=$((_i + 1))
  done
  if pidof mihomo >/dev/null 2>&1; then
    return 1
  fi
  sleep 1
  return 0
}

# The cron watchdog restarts Mihomo whenever the contract port is
# unreachable - which it is during this downtime. Re-check right
# before every execution of the binary (same discipline as the
# updater): a watchdog-revived instance must never run alongside
# the probe, and the final start must load the migrated config.
ensure_stopped_before_exec() {
  if command -v pidof >/dev/null 2>&1 && pidof mihomo >/dev/null 2>&1; then
    log "Mihomo is running again (watchdog restart?) - stopping before executing the binary..."
    if ! stop_mihomo_confirmed; then
      restore_stopped_service
      error "Mihomo could not be stopped - refusing a second instance, config untouched."
    fi
  fi
}

# Bring back a service that THIS script stopped. A user-stopped
# service is never started.
restore_stopped_service() {
  if [ "$SERVICE_WAS_RUNNING" -ne 1 ] || [ "$SERVICE_WAS_STOPPED" -ne 1 ] || [ -z "$INIT_SCRIPT" ]; then
    return 0
  fi
  if command -v pidof >/dev/null 2>&1 && pidof mihomo >/dev/null 2>&1; then
    log "Mihomo is already running again; nothing to restore."
    return 0
  fi
  log "Restarting Mihomo stopped by this script..."
  "$INIT_SCRIPT" start >/dev/null 2>&1 || true
  if command -v pidof >/dev/null 2>&1; then
    _i=0
    while [ "$_i" -lt 5 ]; do
      if pidof mihomo >/dev/null 2>&1; then
        log "Mihomo is running again."
        return 0
      fi
      sleep 1
      _i=$((_i + 1))
    done
    warn "Could not confirm Mihomo is running after restore."
    return 1
  else
    log "pidof not available, skipping restore verification."
  fi
  return 0
}

# Restore the pre-migration config from the backup.
rollback_config() {
  [ -f "$RUN_BACKUP" ] || return 1
  # Never restart an already-running candidate after restoring only its file.
  command -v pidof >/dev/null 2>&1 || return 1
  if pidof mihomo >/dev/null 2>&1; then
    [ -n "$INIT_SCRIPT" ] && stop_mihomo_confirmed || return 1
  fi
  cp -p "$RUN_BACKUP" "$ROLLBACK_STAGE" || return 1
  cmp -s "$RUN_BACKUP" "$ROLLBACK_STAGE" || return 1
  mv -f "$ROLLBACK_STAGE" "$CONFIG" || return 1
  REPLACEMENT_DONE=0
  log "Current-run config restored from $RUN_BACKUP."
}

# Contract port check (mixed-port 7890). Returns 2 when no HTTP
# client exists to check with (pidof verification remains).
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

cleanup_tmp() {
  [ "$ML_LIFECYCLE_HELD" -eq 1 ] || return 0
  [ "$(cat "$MIHOMO_LIFECYCLE_LOCK/owner" 2>/dev/null)" = "$ML_ID" ] || return 0
  rm -f "$TMP_NEW" "${ROLLBACK_STAGE:-}" 2>/dev/null || true
  if [ "${RECOVERY_FAILED:-0}" -eq 0 ]; then
    rm -f "${RUN_BACKUP:-}" 2>/dev/null || true
  fi
  rm -rf "$GATE_HOME" 2>/dev/null || true
  ml_lifecycle_release || true
}

# EXIT also handles unexpected command failures under set -e. Recovery runs
# once, under the lifecycle lock; failed recovery preserves this run's snapshot.
finish_transaction() {
  _finish_rc=$?
  trap - EXIT
  trap '' INT TERM HUP
  if [ "$REPLACEMENT_DONE" -eq 1 ]; then
    if ! rollback_config; then
      RECOVERY_FAILED=1
      _finish_rc=1
      status_out "$COLOR_RED" "[ERROR] Config rollback FAILED. Service not restarted; restore $RUN_BACKUP manually. Historical $BACKUP is not this transaction's snapshot."
    fi
  fi
  if [ "$RECOVERY_FAILED" -eq 0 ]; then
    if ! restore_stopped_service; then
      RECOVERY_FAILED=1
      _finish_rc=1
      status_out "$COLOR_RED" "[ERROR] Service restoration FAILED; current-run backup kept at $RUN_BACKUP."
    fi
  fi
  cleanup_tmp
  exit "$_finish_rc"
}

signal_handler() {
  trap '' INT TERM HUP
  log "Received $1 — aborting migration; EXIT will restore the current transaction."
  exit 1
}

# -----------------------------
# Argument
# -----------------------------
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) error "Unknown argument: $arg (see --help)" ;;
  esac
done

# -----------------------------
# Shared discovery. Binary resolution is deterministic (see the resolver
# comment); the init-script glob is bounded to /opt/etc/init.d.
# -----------------------------
# -----------------------------
# Resolve the Mihomo runtime binary deterministically. The Entware init
# script resolves `mihomo` through a PATH in which /opt/sbin precedes
# /opt/bin, so a router keeping both copies runs /opt/sbin/mihomo
# (live-verified through /proc/<pid>/exe). A running daemon's
# /proc/<pid>/exe is authoritative when it names one of these two
# canonical paths; nested copies such as meta-backup/mihomo are never
# considered.
# -----------------------------
resolve_mihomo_binary() {
  if command -v pidof >/dev/null 2>&1; then
    for _p in $(pidof mihomo 2>/dev/null); do
      _exe=$(readlink "/proc/$_p/exe" 2>/dev/null) || continue
      if [ "$_exe" = "/opt/sbin/mihomo" ] || [ "$_exe" = "/opt/bin/mihomo" ]; then
        if [ -x "$_exe" ]; then
          printf '%s\n' "$_exe"
          return 0
        fi
      fi
    done
  fi
  if [ -x /opt/sbin/mihomo ]; then
    printf '%s\n' /opt/sbin/mihomo
    return 0
  fi
  if [ -x /opt/bin/mihomo ]; then
    printf '%s\n' /opt/bin/mihomo
    return 0
  fi
  return 0
}

MIHOMO_BIN=$(resolve_mihomo_binary)
INIT_SCRIPT=$(find /opt/etc/init.d -name '*mihomo*' -type f 2>/dev/null | head -1)

# -----------------------------
# --check: read-only diagnosis
# -----------------------------
if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "=== Mihomo MIPS stack migration check (read-only) ==="
  trap 'rm -rf "$GATE_HOME" 2>/dev/null || true; ml_lifecycle_release || true' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  if [ -z "$MIHOMO_BIN" ]; then
    echo "[SKIP] mihomo binary not found — nothing to migrate"
    exit 0
  fi
  log "Binary: $MIHOMO_BIN"

  # --check is read-only AND obeys the universal one-Mihomo invariant.
  # A version/support probe executes the Mihomo binary, so it is allowed only
  # when pidof is available and confirms that no daemon is running. Otherwise
  # the config inspection below still runs, but binary support stays unknown.
  CHECK_CAN_EXEC=0
  if command -v pidof >/dev/null 2>&1; then
    if pidof mihomo >/dev/null 2>&1; then
      log "Mihomo daemon is running - executable version/support probes skipped (one-Mihomo invariant)"
    elif ml_lifecycle_acquire; then
      if ! pidof mihomo >/dev/null 2>&1; then CHECK_CAN_EXEC=1; fi
    else
      log "Mihomo lifecycle busy or unverifiable - executable probes skipped"
    fi
  else
    warn "pidof unavailable - executable version/support probes skipped conservatively (one-Mihomo invariant)"
  fi

  # Support state controls how the config findings below may be worded:
  # supported   = the probe passed;
  # unsupported = the binary positively rejected the stack;
  # unknown     = executable probing was skipped or failed.
  GATE_STATE="unknown"
  if [ "$CHECK_CAN_EXEC" -eq 1 ]; then
    read_current_ver
    if [ -n "$CURRENT_VER" ]; then
      log "Installed Mihomo: $CURRENT_VER"
    else
      warn "Could not read the installed Mihomo version"
    fi

    if support_gate "$GATE_HOME"; then
      GATE_STATE="supported"
      status_out "$COLOR_GREEN" "[OK] tun.stack: mips is supported by this binary"
    else
      case "$GATE_REASON" in
        unsupported)
          GATE_STATE="unsupported"
          echo "[SKIP] tun.stack: mips is NOT supported by this binary (needs mihomo >= $MIN_VERSION)"
          ;;
        crash)
          warn "Support could not be verified: the probe crashed even though no daemon was detected. Apply mode performs the definitive gate after its controlled stop."
          ;;
        *)
          warn "Support could not be verified: the probe failed for an unexpected reason. Apply mode performs the definitive gate after its controlled stop."
          ;;
      esac
    fi
  fi
  ml_lifecycle_release || true
  if [ -f "$CONFIG" ]; then
    _g=$(count_gvisor "$CONFIG")
    _m=$(count_mips "$CONFIG")
    log "TUN stack keys found: gvisor=$_g mips=$_m"
    if [ "$_g" -gt 0 ]; then
      case "$GATE_STATE" in
        supported)   status_out "$COLOR_GREEN" "[OK] migration would rewrite $_g stack line(s) to mips" ;;
        unsupported) echo "[SKIP] $_g stack line(s) would become mips, but this binary does not support them — update Mihomo first" ;;
        *)           warn "$_g stack line(s) would become mips, but support is UNVERIFIED — apply mode performs the definitive gate (controlled stop, automatic rollback)" ;;
      esac
    elif [ "$_m" -gt 0 ]; then
      case "$GATE_STATE" in
        unsupported) warn "stack: mips is already in the config, but this binary does not support it — Mihomo may fail to load this config" ;;
        unknown)     echo "[SKIP] already migrated (stack: mips present) — binary support unverified/skipped by one-Mihomo safety" ;;
        *)           echo "[SKIP] already migrated (stack: mips present)" ;;
      esac
    else
      echo "[SKIP] no 'stack: gvisor' found — nothing to migrate (other values are left untouched; a missing key defaults to gVisor upstream)"
    fi
  else
    echo "[SKIP] no config at $CONFIG — nothing to migrate"
  fi
  if [ -n "$INIT_SCRIPT" ]; then
    log "Init script: $INIT_SCRIPT"
  else
    warn "No init script found in /opt/etc/init.d"
  fi
  exit 0
fi

echo "=== Mihomo MIPS stack migration ==="

# Serialize the entire apply transaction, including restoration.
acquire_lock

trap finish_transaction EXIT
trap 'signal_handler INT' INT
trap 'signal_handler TERM' TERM
trap 'signal_handler HUP' HUP

# 1. Config present?
if [ ! -f "$CONFIG" ]; then
  log "[SKIP] no config at $CONFIG — nothing to migrate"
  exit 0
fi
if [ ! -r "$CONFIG" ]; then
  error "Config at $CONFIG is not readable"
fi

# 2. Binary present?
if [ -z "$MIHOMO_BIN" ]; then
  log "[SKIP] mihomo binary not found — nothing to migrate"
  exit 0
fi
log "Binary: $MIHOMO_BIN"

# 3. Service state + init script requirements
if command -v pidof >/dev/null 2>&1 && pidof mihomo >/dev/null 2>&1; then
  SERVICE_WAS_RUNNING=1
fi
if [ "$SERVICE_WAS_RUNNING" -eq 1 ] && [ -z "$INIT_SCRIPT" ]; then
  error "Mihomo is running but no init script was found in /opt/etc/init.d. Stop Mihomo manually and re-run."
fi

# -----------------------------
# 4. Cheap version pre-filter (not the gate) - one-Mihomo invariant:
# the installed binary is probed with -v ONLY when no daemon is
# running (pidof reports none). While a daemon lives, executing a
# second Mihomo is the established SIGSEGV pattern on constrained
# hardware, so the probe is deferred: the definitive support gate
# after the controlled stop decides anyway, and the version
# pre-filter is only a zero-downtime optimization for the
# daemon-stopped case.
# -----------------------------
DEFER_VERSION_DECISION=1
if command -v pidof >/dev/null 2>&1 && ! pidof mihomo >/dev/null 2>&1; then
  DEFER_VERSION_DECISION=0
fi
if [ "$DEFER_VERSION_DECISION" -eq 0 ]; then
  read_current_ver
  if [ -n "$CURRENT_VER" ]; then
    _rel=$(ver_compare "$CURRENT_VER" "$MIN_VERSION")
    if [ "$_rel" = "lt" ]; then
      log "[SKIP] installed Mihomo $CURRENT_VER predates $MIN_VERSION — tun.stack: mips is not supported. Nothing changed."
      exit 0
    fi
    log "Installed Mihomo: $CURRENT_VER"
  else
    warn "Could not read the installed version — the support gate will decide."
  fi
else
  log "Mihomo may be running — the version pre-filter is deferred (one-Mihomo invariant); the support gate after the controlled stop decides."
fi
# 5. Config scan -> no-op states. Pure file reads: performed
# BEFORE the stop so "already migrated" and "nothing to
# migrate" cost zero downtime.
GVISOR_N=$(count_gvisor "$CONFIG")
MIPS_N=$(count_mips "$CONFIG")
if [ "$GVISOR_N" -eq 0 ]; then
  if [ "$MIPS_N" -gt 0 ]; then
    log "[SKIP] already migrated (stack: mips present, no gvisor left). Nothing changed."
  else
    log "[SKIP] no 'stack: gvisor' found — nothing to migrate (other values are left untouched; a missing key defaults to gVisor upstream). Nothing changed."
  fi
  exit 0
fi
log "Found $GVISOR_N TUN stack line(s) with gvisor."

# 6. Stop the service before anything executes the binary
if [ "$SERVICE_WAS_RUNNING" -eq 1 ]; then
  log "Stopping Mihomo for the migration (short controlled downtime)..."
  if ! stop_mihomo_confirmed; then
    error "Old Mihomo did not stop — refusing to run a second Mihomo instance. Update aborted, config untouched."
  fi
fi

# 7. Support gate (definitive with the daemon down)
ensure_stopped_before_exec
if ! support_gate "$GATE_HOME"; then
  case "$GATE_REASON" in
    unsupported)
      log "[SKIP] this binary does not support tun.stack: mips (needs mihomo >= $MIN_VERSION). Nothing changed."
      restore_stopped_service
      exit 0
      ;;
    crash)
      restore_stopped_service
      error "Support probe crashed even with the service stopped — aborting, config untouched."
      ;;
    *)
      restore_stopped_service
      error "Support probe failed for an unexpected reason — aborting, config untouched."
      ;;
  esac
fi
log "tun.stack: mips is supported by this binary."

# 8. Snapshot the CURRENT config for this run, preserving permissions.
# The historical pre-first-migration copy is for operator recovery only.
if [ -e "$RUN_BACKUP" ] || [ -L "$RUN_BACKUP" ]; then
  RECOVERY_FAILED=1
  error "Existing recovery snapshot at $RUN_BACKUP — preserve it and resolve manually before retrying"
fi
cp -p "$CONFIG" "$RUN_BACKUP" || error "Failed to create per-run config backup"
cmp -s "$CONFIG" "$RUN_BACKUP" || error "Per-run config backup verification failed"
if [ ! -f "$BACKUP" ]; then
  cp -p "$RUN_BACKUP" "$BACKUP" || error "Failed to create historical backup $BACKUP"
  log "Backup saved: $BACKUP"
else
  log "Backup already exists, kept: $BACKUP"
fi
# Seed candidate mode/ownership before rewriting its contents.
cp -p "$RUN_BACKUP" "$TMP_NEW" || error "Failed to prepare config candidate"

# 9. Write the migrated config to a same-filesystem temp file
#    (the final mv stays atomic; /tmp -> /opt would not be)
if ! sed 's/^\([[:space:]]*stack:[[:space:]]*\)gvisor\([[:space:]].*\)\{0,1\}$/\1mips\2/' "$CONFIG" > "$TMP_NEW"; then
  rm -f "$TMP_NEW"
  restore_stopped_service
  error "Failed to write the migrated config — config untouched"
fi
NEW_GVISOR_N=$(count_gvisor "$TMP_NEW")
if [ "$NEW_GVISOR_N" -ne 0 ]; then
  rm -f "$TMP_NEW"
  restore_stopped_service
  error "Internal error: gvisor lines remain after the rewrite — config untouched"
fi

# 10. Validate the migrated config BEFORE replacing anything
ensure_stopped_before_exec
log "Testing the migrated config with mihomo -t..."
if ! "$MIHOMO_BIN" -t -d "$CONFIG_DIR" -f "$TMP_NEW" > /dev/null 2>&1; then
  rm -f "$TMP_NEW"
  restore_stopped_service
  error "The migrated config does not pass validation — config untouched, nothing was changed"
fi

# 11. Atomic replace; from here any failure must roll back
REPLACEMENT_DONE=1
log "Replacing config..."
if ! mv -f "$TMP_NEW" "$CONFIG"; then
  error "Failed to replace the config — restoring current-run snapshot"
fi

# 12. Restore the service and verify
ensure_stopped_before_exec
if [ "$SERVICE_WAS_RUNNING" -eq 1 ]; then
  log "Starting Mihomo with the migrated config..."
  if ! "$INIT_SCRIPT" start >/dev/null 2>&1; then
    log "WARNING: Mihomo init script reported start failure. Checking process..."
  fi
  SERVICE_OK=0
  if command -v pidof >/dev/null 2>&1; then
    _i=0
    while [ "$_i" -lt 5 ]; do
      if pidof mihomo >/dev/null 2>&1; then
        SERVICE_OK=1
        break
      fi
      sleep 1
      _i=$((_i + 1))
    done
  else
    SERVICE_OK=1
    log "pidof not available, skipping process verification."
  fi
  if [ "$SERVICE_OK" -eq 1 ]; then
    # The process may appear several seconds before the proxy listener is ready.
    # Wait for readiness instead of treating the first connection refusal as a
    # failed migration.  Live Keenetic testing observed pidof at t=0 while the
    # contract port became ready only at t=4.
    _port_rc=1
    _i=0
    while [ "$_i" -lt 15 ]; do
      _port_rc=0
      port_ok || _port_rc=$?
      if [ "$_port_rc" -eq 0 ] || [ "$_port_rc" -eq 2 ]; then
        break
      fi
      sleep 1
      _i=$((_i + 1))
    done
    if [ "$_port_rc" -eq 1 ]; then
      SERVICE_OK=0
      log "Process is running but the contract port 7890 did not become ready within 15 seconds."
    elif [ "$_port_rc" -eq 2 ]; then
      warn "No curl/wget available — port verification skipped (pidof check only)."
    fi
  fi
  if [ "$SERVICE_OK" -ne 1 ]; then
    log "Verification failed — rolling back to the pre-migration config..."
    error "Migration verification failed — restoring current-run snapshot"
  fi
  log "Process is running, contract port 7890 answers."
else
  log "Service was stopped before the migration — leaving it stopped."
fi

# -----------------------------
# Done (cleanup runs via the exit trap)
# -----------------------------
REPLACEMENT_DONE=0
SERVICE_WAS_STOPPED=0
log "[OK] Migrated $GVISOR_N TUN stack line(s) to mips. Pre-migration config kept at $BACKUP."
exit 0
