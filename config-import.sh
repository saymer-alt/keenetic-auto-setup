#!/bin/sh

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
LOCK_DIR="/tmp/mihomo-config-import.lock.d"
MAINT_MARKER="/tmp/mihomo.maintenance"
UPDATER_LOCK_DIR="/tmp/mihomo-update.lock.d"
UPDATER_LOCK_LEGACY="/tmp/mihomo-update.lock"
INIT_SCRIPT="/opt/etc/init.d/S99mihomo"

LOCK_OWNED=0
MARKER_OWNED=0
SERVICE_WAS_RUNNING=0
SERVICE_STOPPED_BY_US=0
CONFIG_REPLACED=0
CONFIG_COMMIT_STARTED=0

log() { echo "[config] $1"; }
warn() { echo "[WARN] $1"; }
error() { echo "[ERROR] $1" >&2; exit 1; }

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
    if [ "$MARKER_OWNED" -eq 1 ]; then
        rm -f "$MAINT_MARKER" 2>/dev/null || true
    fi
    if [ "$LOCK_OWNED" -eq 1 ]; then
        rm -rf "$LOCK_DIR" 2>/dev/null || true
    fi
}

config_import_process_alive() {
    _ci_pid="$1"
    case "$_ci_pid" in ''|*[!0-9]*) return 1 ;; esac
    [ -d "/proc/$_ci_pid" ] || return 1
    grep -q "config-import" "/proc/$_ci_pid/cmdline" 2>/dev/null
}

acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        LOCK_OWNED=1
        echo "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
        return 0
    fi

    [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ] ||
        error "Config-import lock has an unexpected form: $LOCK_DIR"

    _ci_owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    if config_import_process_alive "$_ci_owner"; then
        error "Another config import is already running (pid $_ci_owner)."
    fi

    log "Removing stale config-import lock..."
    rm -rf "$LOCK_DIR" || error "Cannot remove stale lock: $LOCK_DIR"
    mkdir "$LOCK_DIR" || error "Another config import started at the same time."
    LOCK_OWNED=1
    echo "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
}

updater_in_progress() {
    [ -e "$UPDATER_LOCK_DIR" ] && return 0
    [ -e "$UPDATER_LOCK_LEGACY" ] && return 0
    for _ci_proc in /proc/[0-9]*; do
        grep -q "update-mihomo" "$_ci_proc/cmdline" 2>/dev/null && return 0
    done
    return 1
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
    if mihomo_running; then
        return 0
    fi
    log "Restoring previous Mihomo service state..."
    start_mihomo_confirmed
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
    echo "Paste the COMPLETE Mihomo YAML below."
    echo "When the paste is finished, press Ctrl+D once."
    echo "Nothing will be changed until the candidate passes validation."
    echo
    cat < /dev/tty > "$STAGE_CONFIG"
    echo
    log "Configuration received."
fi

[ -s "$STAGE_CONFIG" ] || error "Received configuration is empty."

if ! grep -Eq '^[[:space:]]*mixed-port:[[:space:]]*7890([[:space:]]*(#.*)?)?$' "$STAGE_CONFIG"; then
    error "Project contract missing: config must contain 'mixed-port: 7890'. Existing config was not changed."
fi
log "Project contract found: mixed-port 7890."

acquire_lock

if updater_in_progress; then
    error "Mihomo binary update appears to be running or locked. Finish/recover update-mihomo.sh before importing a config."
fi

if [ -e "$MAINT_MARKER" ]; then
    error "Another Mihomo maintenance operation is active (or left a marker): $MAINT_MARKER"
fi

echo "$$ $(date +%s)" > "$MAINT_MARKER" ||
    error "Cannot create watchdog maintenance marker."
MARKER_OWNED=1

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
echo "[OK] Mihomo configuration installed successfully."
echo "[OK] Previous configuration backup: $BACKUP_PATH"
if [ "$SERVICE_WAS_RUNNING" -eq 1 ]; then
    echo "[OK] Mihomo is running with the new config."
else
    echo "[info] Mihomo was stopped before import and was left stopped."
fi
