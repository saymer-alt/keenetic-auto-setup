#!/bin/sh
# KAS-CONTROL-CENTER-MANAGED-v1
# Optional standalone Control Center lifecycle; NEVER touches core KAS.
set -eu
umask 077

ROOT=${KAS_WEB_ROOT:-/opt}
# Non-production root is allowed only for isolated unit tests.
if [ "$ROOT" != /opt ] && [ "${KAS_WEB_LAB:-}" != 1 ]; then
    echo "ERROR: custom root is only permitted in lab" >&2; exit 2
fi
case "$ROOT" in /*) ;; *) echo "ERROR: root must be absolute" >&2; exit 2;; esac
case "$ROOT" in *".."*|*" "*|*":"*|*"
"* ) echo "ERROR: unsafe root" >&2; exit 2;; esac
BIN="$ROOT/bin/kas-control-center"
INIT="$ROOT/etc/init.d/S98kas-control-center"
MANIFEST="$ROOT/etc/kas-control-center.web.sha256"
PID="$ROOT/var/run/kas-control-center.pid"
MARKER="# KAS-CONTROL-CENTER-MANAGED-v1"

check_parent_dirs() {
    # Never follow a redirected Entware/Web directory into foreign storage.
    for d in "$ROOT" "$ROOT/bin" "$ROOT/etc" "$ROOT/etc/init.d" "$ROOT/var" "$ROOT/var/run"; do
        [ ! -L "$d" ] || deny "unsafe symlink in Web service directory"
    done
}
message() { printf '%s\n' "$*"; }
deny() { message "BLOCKED: $*" >&2; exit 2; }
is_managed() {
    [ -f "$INIT" ] && [ ! -L "$INIT" ] &&
        grep -Fxq "$MARKER" "$INIT"
}
pid_value() {
    [ -f "$PID" ] && [ ! -L "$PID" ] || return 1
    value=$(cat "$PID" 2>/dev/null) || return 1
    case "$value" in ''|*[!0-9]*) return 1;; esac
    [ "$value" -gt 1 ] 2>/dev/null || return 1
    printf '%s\n' "$value"
}
pid_matches() {
    test_pid=$1
    [ -r "/proc/$test_pid/cmdline" ] || return 1
    # Verify exact staged executable path, never signal an unrelated PID.
    tr '\000' '\n' < "/proc/$test_pid/cmdline" | grep -Fxq "$BIN"
}
running() {
    run_pid=$(pid_value) || return 1
    kill -0 "$run_pid" 2>/dev/null && pid_matches "$run_pid"
}
untracked_running() {
    for proc in /proc/[0-9]*; do
        [ -r "$proc/cmdline" ] || continue
        tr '\000' '\n' < "$proc/cmdline" 2>/dev/null | grep -Fxq "$BIN" && return 0
    done
    return 1
}
verify_owned() {
    is_managed || deny "service init is not a managed KAS Web component"
    [ ! -L "$BIN" ] && [ -f "$BIN" ] || deny "managed binary missing/unsafe"
    [ ! -L "$MANIFEST" ] && [ -f "$MANIFEST" ] || deny "missing ownership digest"
    expected=$(cat "$MANIFEST")
    case "$expected" in
        *[!0123456789abcdef]*|'') deny "invalid ownership digest";;
    esac
    [ "${#expected}" -eq 64 ] || deny "invalid ownership digest length"
    actual=$(sha256sum "$BIN" | cut -d ' ' -f 1) || deny "cannot verify installed binary"
    [ "$actual" = "$expected" ] || deny "installed binary was modified; refuse removal"
}
install_ui() {
    [ "$#" -eq 2 ] || deny "usage: install /path/to/arm64-binary sha256"
    source=$1
    digest=$2
    case "$digest" in *[!0123456789abcdef]*|'') deny "invalid requested digest";; esac
    [ "${#digest}" -eq 64 ] || deny "invalid requested digest length"
    [ -f "$source" ] && [ -r "$source" ] && [ ! -L "$source" ] ||
        deny "source file is missing or unsafe"
    [ ! -e "$BIN" ] && [ ! -L "$BIN" ] &&
    [ ! -e "$INIT" ] && [ ! -L "$INIT" ] &&
    [ ! -e "$MANIFEST" ] && [ ! -L "$MANIFEST" ] ||
        deny "web component paths already exist; no overwrite"
    actual=$(sha256sum "$source" | cut -d ' ' -f 1) || deny "checksum unavailable"
    [ "$actual" = "$digest" ] || deny "binary SHA256 mismatch"
    check_parent_dirs
    mkdir -p "$ROOT/bin" "$ROOT/etc/init.d" "$ROOT/var/run" || deny "cannot create Web dirs"
    check_parent_dirs
    stage_bin="$ROOT/bin/.kas-control-center.$$"
    stage_init="$ROOT/etc/init.d/.S98kas-control-center.$$"
    stage_manifest="$ROOT/etc/.kas-control-center.web.sha256.$$"
    [ ! -e "$stage_bin" ] && [ ! -e "$stage_init" ] && [ ! -e "$stage_manifest" ] ||
        deny "unexpected staging collision"
    trap 'rm -f "$stage_bin" "$stage_init" "$stage_manifest"' EXIT
    trap 'exit 1' HUP INT TERM
    cp "$source" "$stage_bin" || deny "copy failed"
    chmod 700 "$stage_bin" || deny "chmod failed"
    [ "$(sha256sum "$stage_bin" | cut -d ' ' -f 1)" = "$digest" ] ||
        deny "staging digest mismatch"
    [ -f "$0" ] && [ ! -L "$0" ] || deny "installer must run from a regular script"
    cp "$0" "$stage_init" || deny "service staging failed"
    chmod 700 "$stage_init" || deny "service chmod failed"
    printf '%s\n' "$digest" > "$stage_manifest" || deny "manifest staging failed"
    chmod 600 "$stage_manifest" || deny "manifest chmod failed"
    # Single-purpose, no overwrite. Leave partial install blocked rather than
    # automatically touching files we may no longer own after an interruption.
    mv "$stage_bin" "$BIN" || deny "binary install failed"
    mv "$stage_manifest" "$MANIFEST" || deny "manifest install failed"
    mv "$stage_init" "$INIT" || deny "service install failed"
    trap - EXIT HUP INT TERM
    message "INSTALLED: optional localhost-only KAS Control Center"
    message "START: sh $INIT start"
}
start_ui() {
    verify_owned
    if running; then message "RUNNING"; return 0; fi
    if [ -e "$PID" ] || [ -L "$PID" ]; then deny "stale/unverifiable pid; inspect manually"; fi
    untracked_running && deny "untracked Web process found; refusing duplicate"
    check_parent_dirs
    mkdir -p "$ROOT/var/run" || deny "runtime directory unavailable"
    # Default is the actual private IP of Home bridge br0, not wildcard.
    # Optional local-only password lives in a user-owned 0600 config file.
    password_file="$ROOT/etc/kas-control-center.password"
    if [ -e "$password_file" ] || [ -L "$password_file" ]; then
        "$BIN" -lan -listen auto -lan-interface br0 -password-file "$password_file" </dev/null >/dev/null 2>&1 &
    else
        "$BIN" -lan -listen auto -lan-interface br0 </dev/null >/dev/null 2>&1 &
    fi
    child=$!
    printf '%s\n' "$child" > "$PID" || deny "cannot record service pid"
    sleep 1
    if ! running; then
        rm -f "$PID"
        deny "Web process did not remain active"
    fi
    message "RUNNING: Home LAN TCP/18081 (br0)"
}
stop_ui() {
    if [ ! -e "$PID" ] && [ ! -L "$PID" ]; then
        message "NOT_RUNNING"; return 0
    fi
    running || deny "pid unverified; refusing to signal unrelated process"
    kill -TERM "$run_pid" || deny "cannot signal Web process"
    # Go server drains any in-flight importer on SIGTERM; no SIGKILL fallback.
    n=0
    while running; do
        [ "$n" -lt 60 ] || deny "Web process still draining; do not force kill during import"
        sleep 1
        n=$((n+1))
    done
    rm -f "$PID"
    message "STOPPED"
}
remove_ui() {
    [ "$#" -eq 0 ] || deny "remove takes no arguments"
    check_parent_dirs
    verify_owned
    stop_ui
    untracked_running && deny "untracked Web process found; refusing removal"
    # Only three owned files. NEVER clean /opt/etc/mihomo, /tmp maintenance
    # locks, configs, backups, watchdog, MagiTrickle or foreign services.
    rm "$BIN" "$INIT" "$MANIFEST" || deny "partial Web-only removal"
    message "REMOVED: Control Center only; KAS core unchanged"
}
case "${1:-}" in
    install) shift; install_ui "$@";;
    start) shift; [ "$#" -eq 0 ] || deny "start takes no arguments"; start_ui;;
    stop) shift; [ "$#" -eq 0 ] || deny "stop takes no arguments"; stop_ui;;
    status)
        shift; [ "$#" -eq 0 ] || deny "status takes no arguments"
        if running; then message RUNNING
        elif [ -e "$PID" ] || [ -L "$PID" ]; then message UNKNOWN; exit 2
        else message NOT_RUNNING; fi;;
    remove) shift; remove_ui "$@";;
    *) deny "usage: sh kas-web-manage.sh install BIN SHA | start | stop | status | remove";;
esac
