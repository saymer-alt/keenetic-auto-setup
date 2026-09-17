#!/bin/sh

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
# - automatic rollback to the backup on any post-replacement
#   failure
# - at most one Mihomo instance runs at any moment: the
#   service is stopped (and the stop confirmed) before any
#   probe or validation executes the binary; a watchdog-revived
#   instance is re-stopped before every binary execution and
#   before the final start
# - no secrets or config contents are printed, only statuses
#   and counters
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
LOCK_FILE="/tmp/mihomo-migrate.lock"
GATE_HOME="/tmp/mihomo-migrate-gate.$$"
MIN_VERSION="1.19.31"

CHECK_ONLY=0
SERVICE_WAS_RUNNING=0
SERVICE_WAS_STOPPED=0
REPLACEMENT_DONE=0
MIHOMO_BIN=""
INIT_SCRIPT=""
GATE_REASON=""

log()   { echo "[migrate] $1"; }
warn()  { echo "[WARN] $1"; }
error() { echo "[ERROR] $1"; exit 1; }

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
  if [ "$SERVICE_WAS_STOPPED" -ne 1 ] || [ -z "$INIT_SCRIPT" ]; then
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
    log "WARNING: could not confirm Mihomo is running after restore."
  else
    log "pidof not available, skipping restore verification."
  fi
  return 0
}

# Restore the pre-migration config from the backup.
rollback_config() {
  if [ -f "$BACKUP" ]; then
    cp -f "$BACKUP" "$CONFIG" || return 1
    log "Pre-migration config restored from $BACKUP."
    return 0
  fi
  return 1
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
  rm -f "$LOCK_FILE" 2>/dev/null || true
  rm -f "$TMP_NEW" 2>/dev/null || true
  rm -rf "$GATE_HOME" 2>/dev/null || true
}

signal_handler() {
  trap '' INT TERM
  log "Received $1 — aborting migration."
  if [ "$REPLACEMENT_DONE" -eq 1 ]; then
    log "Config already replaced — rolling back from backup..."
    if rollback_config; then
      log "Pre-migration config restored."
    else
      log "WARNING: rollback failed — backup kept at $BACKUP, restore it manually."
    fi
  else
    log "No changes were made."
  fi
  restore_stopped_service
  cleanup_tmp
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
# Shared discovery
# -----------------------------
MIHOMO_BIN=$(find /opt -name "mihomo" -type f 2>/dev/null | head -1)
INIT_SCRIPT=$(find /opt/etc/init.d -name '*mihomo*' -type f 2>/dev/null | head -1)

# -----------------------------
# --check: read-only diagnosis
# -----------------------------
if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "=== Mihomo MIPS stack migration check (read-only) ==="
  trap 'rm -rf "$GATE_HOME" 2>/dev/null || true' EXIT
  if [ -z "$MIHOMO_BIN" ]; then
    echo "[SKIP] mihomo binary not found — nothing to migrate"
    exit 0
  fi
  log "Binary: $MIHOMO_BIN"
  read_current_ver
  if [ -n "$CURRENT_VER" ]; then
    log "Installed Mihomo: $CURRENT_VER"
  else
    warn "Could not read the version (crash under memory pressure with the daemon running?)"
  fi
  if support_gate "$GATE_HOME"; then
    echo "[OK] tun.stack: mips is supported by this binary"
  else
    case "$GATE_REASON" in
      unsupported) echo "[SKIP] tun.stack: mips is NOT supported by this binary (needs mihomo >= $MIN_VERSION)" ;;
      crash)       echo "[SKIP] support probe crashed (likely memory pressure with the daemon running) — rerun --check with the service stopped" ;;
      *)           warn "Support probe failed for an unexpected reason" ;;
    esac
  fi
  if [ -f "$CONFIG" ]; then
    _g=$(count_gvisor "$CONFIG")
    _m=$(count_mips "$CONFIG")
    log "TUN stack keys found: gvisor=$_g mips=$_m"
    if [ "$_g" -gt 0 ]; then
      echo "[OK] migration would rewrite $_g stack line(s) to mips"
    elif [ "$_m" -gt 0 ]; then
      echo "[SKIP] already migrated (stack: mips present)"
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

# -----------------------------
# Apply mode
# -----------------------------
echo "=== Mihomo MIPS stack migration ==="

# 0. Prevent parallel migrations (same pattern as the updater)
if [ -e "$LOCK_FILE" ]; then
  error "Another Mihomo migration is already running. Aborting."
fi
touch "$LOCK_FILE"
trap cleanup_tmp EXIT
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

# 4. Cheap version pre-filter (not the gate). A crash here is
# tolerated: the -t gate after the stop decides definitively.
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

# 8. Backup (the first original is never overwritten). The
# config holds secrets (external-controller secret, proxy
# credentials), so the original file mode is preserved on the
# backup and on the replacement instead of relying on umask.
CFG_MODE=""
if command -v stat >/dev/null 2>&1; then
  CFG_MODE=$(stat -c '%a' "$CONFIG" 2>/dev/null) || true
fi
if [ ! -f "$BACKUP" ]; then
  cp -f "$CONFIG" "$BACKUP" || { restore_stopped_service; error "Failed to create backup $BACKUP"; }
  if [ -n "$CFG_MODE" ]; then
    chmod "$CFG_MODE" "$BACKUP" 2>/dev/null || true
  fi
  log "Backup saved: $BACKUP"
else
  log "Backup already exists, kept: $BACKUP"
fi

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
if [ -n "$CFG_MODE" ]; then
  chmod "$CFG_MODE" "$TMP_NEW" 2>/dev/null || true
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
  rollback_config || log "WARNING: rollback failed — backup kept at $BACKUP"
  restore_stopped_service
  error "Failed to replace the config — rolled back"
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
    _port_rc=0
    port_ok || _port_rc=$?
    if [ "$_port_rc" -eq 1 ]; then
      SERVICE_OK=0
      log "Process is running but the contract port 7890 does not answer."
    elif [ "$_port_rc" -eq 2 ]; then
      warn "No curl/wget available — port verification skipped (pidof check only)."
    fi
  fi
  if [ "$SERVICE_OK" -ne 1 ]; then
    log "Verification failed — rolling back to the pre-migration config..."
    if rollback_config; then
      "$INIT_SCRIPT" restart >/dev/null 2>&1 || true
      if command -v pidof >/dev/null 2>&1 && pidof mihomo >/dev/null 2>&1; then
        error "Rolled back: pre-migration config restored and Mihomo is running."
      else
        error "Rolled back: pre-migration config restored, but Mihomo is not detected — check manually."
      fi
    else
      error "Migration failed AND rollback failed — backup kept at $BACKUP, restore it manually."
    fi
  fi
  log "Process is running, contract port 7890 answers."
else
  log "Service was stopped before the migration — leaving it stopped."
fi

# -----------------------------
# Done (cleanup runs via the exit trap)
# -----------------------------
log "[OK] Migrated $GVISOR_N TUN stack line(s) to mips. Pre-migration config kept at $BACKUP."
exit 0
