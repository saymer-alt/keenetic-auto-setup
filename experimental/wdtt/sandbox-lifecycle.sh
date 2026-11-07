#!/bin/sh
# Local fault-test prototype ONLY. Never installed in /opt/etc/init.d.
# The live install.sh gate remains closed. No downloads/opkg/routes/DNS/firewall.
set -f
umask 077
export LC_ALL=C
ROOT=${1-}; action=${2-}; shift 2 2>/dev/null || exit 78
fail() { printf '%s\n' "WDTT_SANDBOX_$1" >&2; exit 78; }
case $ROOT in /tmp/wdtt-sandbox-*) ;; *) fail PATH_REJECTED;; esac
[ -d "$ROOT" ] && [ ! -L "$ROOT" ] || fail ROOT_REJECTED
[ "$(cd -P "$ROOT" && pwd)" = "$ROOT" ] || fail ROOT_ALIAS
meta=$(ls -ldn "$ROOT" 2>/dev/null)
set -- $meta "$@"
[ "${1-}" = drwx------ ] && [ "${3-}" = "$(id -u)" ] || fail PRIVATE_ROOT_REQUIRED
# Recover arguments without evaluating the filesystem metadata as shell code.
args_source=${WDTT_SANDBOX_SOURCE-}
args_digest=${WDTT_SANDBOX_SHA256-}
command -v sha256sum >/dev/null 2>&1 || fail CHECKSUM_UNAVAILABLE
case $args_digest in *[!0-9a-f]*|'') [ "$action" != install ] || fail DIGEST_REJECTED;; esac
[ "$action" != install ] || [ "${#args_digest}" -eq 64 ] || fail DIGEST_REJECTED
if [ ! -f "$ROOT/owner" ]; then
    [ "$action" = install ] || fail NOT_INSTALLED
    [ -z "$(ls -A "$ROOT")" ] || fail FOREIGN_ROOT
    printf '%s\n' kas-wdtt-sandbox-v1 > "$ROOT/owner" || fail OWNER_WRITE
fi
[ ! -L "$ROOT/owner" ] && [ "$(cat "$ROOT/owner")" = kas-wdtt-sandbox-v1 ] || fail FOREIGN_OWNER
for name in versions current previous retry exit status pid config.json current.stage previous.stage pid.stage; do
    [ ! -L "$ROOT/$name" ] || fail STATE_SYMLINK
done
mkdir "$ROOT/lock" 2>/dev/null || fail LOCKED
trap 'rmdir "$ROOT/lock" 2>/dev/null' 0
trap 'exit 78' 1 2 15
digest() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
version_ok() {
    case $1 in *[!0-9a-f]*|'') return 1;; esac
    [ "${#1}" -eq 64 ] && [ -d "$ROOT/versions/$1" ] && [ ! -L "$ROOT/versions/$1" ] &&
        [ -f "$ROOT/versions/$1/worker" ] && [ ! -L "$ROOT/versions/$1/worker" ] &&
        [ "$(digest "$ROOT/versions/$1/worker")" = "$1" ]
}
start_time() { sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}'; }
owned_running() {
    [ -r "$ROOT/pid" ] && [ ! -L "$ROOT/pid" ] || return 1
    read -r worker_pid worker_time worker_version < "$ROOT/pid" || return 2
    case $worker_pid:$worker_time in *[!0-9:]*|:*) return 2;; esac
    [ -d "/proc/$worker_pid" ] || return 1
    version_ok "$worker_version" || return 2
    if [ "$(start_time "$worker_pid")" != "$worker_time" ]; then
        [ -d "/proc/$worker_pid" ] || return 1
        return 2
    fi
    process_state=$(sed 's/^.*) //' "/proc/$worker_pid/stat" 2>/dev/null | awk '{print $1}')
    [ "$process_state" != Z ] || return 1
    if [ ! "/proc/$worker_pid/exe" -ef "$ROOT/versions/$worker_version/worker" ]; then
        [ -d "/proc/$worker_pid" ] || return 1
        process_state=$(sed 's/^.*) //' "/proc/$worker_pid/stat" 2>/dev/null | awk '{print $1}')
        [ "$process_state" != Z ] || return 1
        return 2
    fi
    # Exact config-file argv admission; never print the process command line.
    tr '\000' '\n' < "/proc/$worker_pid/cmdline" 2>/dev/null | awk -v e="$ROOT/versions/$worker_version/worker" -v c="$ROOT/config.json" '
      NR==1 && $0!=e {bad=1} NR==2 && $0!="-config-file" {bad=1} NR==3 && $0!=c {bad=1}
      END {exit (bad || NR!=3)}' || { [ -d "/proc/$worker_pid" ] || return 1; return 2; }
    return 0
}
stop_worker() {
    owned_running; state=$?
    [ "$state" -ne 2 ] || fail PROCESS_OWNERSHIP_UNKNOWN
    if [ "$state" -eq 0 ]; then
        # Recheck inode/start-time/argv immediately before the signal.
        owned_running || fail PROCESS_CHANGED
        kill -TERM "$worker_pid" || fail STOP_FAILED
        n=0
        while [ "$n" -lt 10 ]; do
            owned_running; state=$?
            [ "$state" -ne 2 ] || fail PROCESS_CHANGED
            [ "$state" -eq 0 ] || break
            sleep 1; n=$((n+1))
        done
        [ "$state" -ne 0 ] || fail STOP_TIMEOUT
    fi
    rm -f "$ROOT/pid"
    printf '%s\n' STOPPED > "$ROOT/status"
}
start_worker() {
    owned_running; state=$?
    [ "$state" -ne 2 ] || fail PROCESS_OWNERSHIP_UNKNOWN
    [ "$state" -ne 0 ] || return 0
    [ -f "$ROOT/config.json" ] && [ ! -L "$ROOT/config.json" ] || fail CONFIG_REQUIRED
    config_meta=$(ls -ln "$ROOT/config.json" 2>/dev/null)
    config_mode=$(printf '%s\n' "$config_meta" | awk '{print $1}')
    config_uid=$(printf '%s\n' "$config_meta" | awk '{print $3}')
    [ "$config_mode" = -rw------- ] && [ "$config_uid" = "$(id -u)" ] || fail PRIVATE_CONFIG_REQUIRED
    read -r current < "$ROOT/current" || fail NO_CURRENT
    version_ok "$current" || fail BINARY_CHANGED
    attempts=0; next=0
    if [ -r "$ROOT/retry" ]; then read -r attempts next < "$ROOT/retry" || fail RETRY_STATE; fi
    case $attempts:$next in *[!0-9:]*|:*) fail RETRY_STATE;; esac
    [ "$attempts" -lt 5 ] || fail RETRY_EXHAUSTED
    now=$(date +%s); [ "$now" -ge "$next" ] || fail BACKOFF
    if [ -r "$ROOT/exit" ]; then read -r code < "$ROOT/exit"; [ "$code" != 78 ] || fail FATAL_CONFIG; fi
    attempts=$((attempts+1)); delay=$((1 << attempts)); next=$((now+delay))
    printf '%s %s\n' "$attempts" "$next" > "$ROOT/retry"
    rm -f "$ROOT/exit"
    # No automatic restart, stdout/stderr or persistent flash logs.
    # The monitor only waits for this child and records its numeric exit code.
    (
        "$ROOT/versions/$current/worker" -config-file "$ROOT/config.json" </dev/null >/dev/null 2>&1 &
        pid=$!
        born=$(start_time "$pid")
        printf '%s %s %s\n' "$pid" "$born" "$current" > "$ROOT/pid.stage"
        mv "$ROOT/pid.stage" "$ROOT/pid"
        wait "$pid"; rc=$?
        printf '%s\n' "$rc" > "$ROOT/exit"
    ) </dev/null >/dev/null 2>&1 &
    n=0
    while [ "$n" -lt 3 ]; do
        sleep 1
        if owned_running; then printf '%s\n' RUNNING_NOT_TUNNEL_PROOF > "$ROOT/status"; return 0; fi
        [ ! -f "$ROOT/exit" ] || fail START_FAILED
        n=$((n+1))
    done
    fail START_UNVERIFIED
}
case $action in
    install)
        [ -f "$args_source" ] && [ ! -L "$args_source" ] || fail SOURCE_REJECTED
        [ "$(digest "$args_source")" = "$args_digest" ] || fail CHECKSUM_MISMATCH
        mkdir -p "$ROOT/versions" || fail DIRECTORY_FAILED
        [ ! -L "$ROOT/versions" ] || fail FOREIGN_VERSIONS
        stage="$ROOT/versions/.stage-$$"
        mkdir "$stage" || fail STAGE_CONFLICT
        if ! cp "$args_source" "$stage/worker" || ! chmod 700 "$stage/worker" || [ "$(digest "$stage/worker")" != "$args_digest" ]; then
            rm -f "$stage/worker"; rmdir "$stage"; fail STAGE_FAILED
        fi
        if ! "$stage/worker" -h >/dev/null 2>&1; then rm -f "$stage/worker"; rmdir "$stage"; fail STARTUP_REJECTED; fi
        if [ -e "$ROOT/versions/$args_digest" ]; then
            version_ok "$args_digest" || fail FOREIGN_VERSION
            rm -f "$stage/worker"; rmdir "$stage"
        else mv "$stage" "$ROOT/versions/$args_digest" || fail COMMIT_FAILED; fi
        owned_running; state=$?; [ "$state" -ne 2 ] || fail PROCESS_OWNERSHIP_UNKNOWN
        stop_worker
        previous=''; [ ! -r "$ROOT/current" ] || read -r previous < "$ROOT/current"
        [ "$previous" = "$args_digest" ] || printf '%s\n' "$previous" > "$ROOT/previous.stage"
        printf '%s\n' "$args_digest" > "$ROOT/current.stage" || fail STATE_WRITE
        mv "$ROOT/current.stage" "$ROOT/current" || fail STATE_COMMIT
        [ ! -e "$ROOT/previous.stage" ] || mv "$ROOT/previous.stage" "$ROOT/previous"
        rm -f "$ROOT/retry" "$ROOT/exit"
        printf '%s\n' INSTALLED_AUTOSTART_DISABLED > "$ROOT/status"
        ;;
    start) start_worker;;
    stop) stop_worker;;
    restart) stop_worker; start_worker;;
    status) if owned_running; then echo RUNNING_NOT_TUNNEL_PROOF; else state=$?; [ "$state" -ne 2 ] || fail PROCESS_OWNERSHIP_UNKNOWN; echo STOPPED; fi;;
    rollback)
        read -r previous < "$ROOT/previous" || fail NO_PREVIOUS
        version_ok "$previous" || fail PREVIOUS_CHANGED
        stop_worker
        printf '%s\n' "$previous" > "$ROOT/current.stage" && mv "$ROOT/current.stage" "$ROOT/current" || fail ROLLBACK_FAILED
        rm -f "$ROOT/retry" "$ROOT/exit"
        printf '%s\n' ROLLED_BACK_STOPPED > "$ROOT/status"
        ;;
    uninstall)
        stop_worker
        set +f
        # Validate every owned binary before deleting any version.
        for v in "$ROOT"/versions/*; do [ -e "$v" ] || continue; version_ok "${v##*/}" || fail FOREIGN_VERSION; done
        for v in "$ROOT"/versions/*; do [ -e "$v" ] || continue; rm -f "$v/worker"; rmdir "$v" 2>/dev/null || :; done
        rmdir "$ROOT/versions" 2>/dev/null || :
        # Keep operator secrets and unknown files. Never rm -rf the sandbox.
        rm -f "$ROOT/current" "$ROOT/previous" "$ROOT/retry" "$ROOT/exit" "$ROOT/status"
        printf '%s\n' UNINSTALLED_SECRETS_AND_UNKNOWN_FILES_RETAINED
        ;;
    *) fail ACTION_REJECTED;;
esac
