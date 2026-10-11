#!/bin/sh
# Experimental Entware lifecycle. No downloads/opkg/routes/DNS/firewall.
# Installation remains blocked by a reviewed source policy, without env bypass.
set -f
umask 077
export LC_ALL=C
port_free() {
    port_hex=$(printf '%04X' "$1") || return 1
    [ -r /proc/net/udp ] && [ -r /proc/net/udp6 ] || return 1
    awk -v port="$port_hex" 'FNR>1 {split($2,a,":"); if(toupper(a[2])==port)busy=1} END {exit busy}' /proc/net/udp /proc/net/udp6
}
memory_available_kib() {
    # Linux 3.4 may lack MemAvailable. MemFree alone is a conservative floor;
    # do not invent available RAM by summing reclaimable caches.
    awk '/^MemFree:/ {free=$2} /^MemAvailable:/ {available=$2;found=1} END {if(found)print available;else if(free!="")print free}' /proc/meminfo
}
runtime_mount_ok() {
    awk '$2=="/tmp" && $3=="tmpfs" {ok=1} END {exit !ok}' /proc/mounts
}
elf_arch() {
    bytes=$(od -An -tu1 -N20 "$1" 2>/dev/null) || return 1
    set -f; set -- $bytes
    [ "${1-}:${2-}:${3-}:${4-}" = 127:69:76:70 ] || return 1
    case ${5-}:${6-}:${19-}:${20-} in
        2:1:183:0) printf '%s\n' aarch64-3.10;;
        1:1:8:0) printf '%s\n' mipsel-3.4;;
        *) return 1;;
    esac
}
admission() {
    candidate=$1; wanted_sha=$2; wanted_arch=$3; requested_port=$4
    [ "$(id -u)" = 0 ] || return 1
    case $requested_port in ''|*[!0-9]*) return 1;; esac
    [ "$requested_port" -ge 1024 ] && [ "$requested_port" -le 65535 ] || return 1
    case $wanted_sha in ''|*[!0-9a-f]*) return 1;; esac
    [ "${#wanted_sha}" -eq 64 ] || return 1
    [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
    [ "$(sha256sum "$candidate" 2>/dev/null | awk '{print $1}')" = "$wanted_sha" ] || return 1
    [ "$(elf_arch "$candidate")" = "$wanted_arch" ] || return 1
    userspace=''
    for f in /opt/bin/opkg /opt/bin/busybox /opt/sbin/opkg; do
        [ -f "$f" ] || continue
        userspace=$(elf_arch "$f") && break
    done
    [ "$userspace" = "$wanted_arch" ] || return 1
    opkg print-architecture 2>/dev/null | awk -v wanted="$wanted_arch" '$1=="arch" && $2==wanted {ok=1} END {exit !ok}' || return 1
    case $wanted_arch:$(uname -m) in aarch64-3.10:aarch64|mipsel-3.4:mips*) ;; *) return 1;; esac
    # Do not infer softfloat from ELF e_machine. Require pinned build provenance.
    provenance=$(dirname "$candidate")/provenance.json
    [ -f "$provenance" ] && [ ! -L "$provenance" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    case $wanted_arch in aarch64-3.10) goarch=arm64;; mipsel-3.4) goarch=mipsle;; *) return 1;; esac
    jq -e --arg sha "$wanted_sha" --arg arch "$goarch" '
      .source == "1110a75f76e42c23149b8e24f9182c1ff179e515" and
      .toolchain == "go version go1.26.1 linux/amd64" and
      .install_ready == true and .license_gate == "APPROVED" and
      any(.builds[]; .arch==$arch and .sha256==$sha and .pt_interp==false and
          ($arch!="mipsle" or (.go_metadata|contains("GOMIPS=softfloat"))))
    ' "$provenance" >/dev/null 2>&1 || return 1
    # Conservative WDTT lab floor; 128MB class remains unsupported here.
    total=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    available=$(memory_available_kib)
    case $total:$available in *[!0-9:]*|:*|*:) return 1;; esac
    [ "$total" -ge 196608 ] && [ "$available" -ge 98304 ] || return 1
    fs=$(awk '$2=="/opt" || index("/opt/",$2"/")==1 {if(length($2)>n){n=length($2);fs=$3}} END {print fs}' /proc/mounts)
    case $fs in
        ext4)
            # Component/mount identity and external swap acceptance remain part
            # of the owner preflight gate; never provision storage here.
            ;;
        ubifs)
            [ -x /opt/etc/init.d/S00ubifs ] || return 1
            for m in /opt/tmp /opt/var/log /opt/var/run; do
                awk -v p="$m" '$2==p && $3=="tmpfs" {ok=1} END {exit !ok}' /proc/mounts || return 1
            done;;
        *) return 1;;
    esac
    # Native verified zRAM is the only supported pressure backend in this first
    # installer profile; external swap needs separate identity admission.
    if [ "$total" -le 600000 ]; then
        backend=no
        while read -r swap_source swap_type swap_size rest; do
            case $swap_source:$swap_type in /dev/zram[0-9]*:partition)
                zname=${swap_source##*/}
                [ -b "$swap_source" ] && [ -r "/sys/class/block/$zname/dev" ] || continue
                numbers=$(ls -ln "$swap_source" | awk '{gsub(/,/,"",$5);print $5 ":" $6}')
                [ "$numbers" = "$(cat "/sys/class/block/$zname/dev")" ] && backend=yes;;
            esac
        done < /proc/swaps
        [ "$backend" = yes ] || return 1
    fi
    free=$(df -Pk /opt 2>/dev/null | awk 'NR==2 {print $4}')
    size=$(wc -c < "$candidate") || return 1
    case $size in ''|*[!0-9]*) return 1;; esac
    need=$(( (size+1023)/1024 + 32768 ))
    case $free in ''|*[!0-9]*) return 1;; esac
    [ "$free" -ge "$need" ] || return 1
    # Volatile runtime must not silently land on flash.
    awk '$2=="/tmp" && $3=="tmpfs" {ok=1} END {exit !ok}' /proc/mounts || return 1
    if ! port_free "$requested_port"; then
        private_dir "$ROOT" && private_dir "$STATE" && [ ! -L "$ROOT/port" ] &&
            [ "$(cat "$ROOT/port")" = "$requested_port" ] && owned_running || return 1
    fi
    return 0
}

ROOT=/opt/wdtt-experimental
STATE=/tmp/wdtt-runtime-$(id -u)
INIT=/opt/etc/init.d/S98wdtt-lab
action=${1-}
fail() { printf '%s\n' "WDTT_$1" >&2; exit 78; }
# Change only through a reviewed commit after the stated gates close.
INSTALL_ADMITTED=no
[ "$action" != install ] || [ "$INSTALL_ADMITTED" = yes ] || fail INSTALL_BLOCKED
private_dir() {
    [ -d "$1" ] && [ ! -L "$1" ] && [ "$(cd -P "$1" && pwd)" = "$1" ] || return 1
    ls -ldn "$1" 2>/dev/null | awk -v uid="$(id -u)" '$1=="drwx------" && $3==uid {ok=1} END {exit !ok}'
}
digest() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
version_ok() {
    case $1 in *[!0-9a-f]*|'') return 1;; esac
    [ "${#1}" -eq 64 ] && [ ! -L "$ROOT/versions" ] && [ -d "$ROOT/versions/$1" ] && [ ! -L "$ROOT/versions/$1" ] &&
        [ -f "$ROOT/versions/$1/worker" ] && [ ! -L "$ROOT/versions/$1/worker" ] &&
        [ "$(digest "$ROOT/versions/$1/worker")" = "$1" ]
}
start_time() { sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $20}'; }
owned_running() {
    [ -r "$STATE/pid" ] && [ ! -L "$STATE/pid" ] || return 1
    read -r worker_pid worker_time worker_version < "$STATE/pid" || return 2
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
    tr '\000' '\n' < "/proc/$worker_pid/cmdline" 2>/dev/null | awk -v e="$ROOT/versions/$worker_version/worker" -v c="$STATE/config.json" '
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
    rm -f "$STATE/pid"
    printf '%s\n' STOPPED > "$STATE/status"
}
start_worker() {
    owned_running; state=$?
    [ "$state" -ne 2 ] || fail PROCESS_OWNERSHIP_UNKNOWN
    [ "$state" -ne 0 ] || return 0
    [ -f "$ROOT/config.json" ] && [ ! -L "$ROOT/config.json" ] || fail CONFIG_REQUIRED
    config_meta=$(ls -ln "$ROOT/config.json" 2>/dev/null)
    printf '%s\n' "$config_meta" | awk -v uid="$(id -u)" '$1=="-rw-------" && $2==1 && $3==uid {ok=1} END {exit !ok}' || fail PRIVATE_CONFIG_REQUIRED
    port=$(cat "$ROOT/port")
    jq -e --arg endpoint "127.0.0.1:$port" '.listen == $endpoint' "$ROOT/config.json" >/dev/null 2>&1 || fail CONFIG_PORT_MISMATCH
    port_free "$port" || fail PORT_CONFLICT
    [ ! -L "$STATE/config.json" ] || fail STATE_SYMLINK
    cp "$ROOT/config.json" "$STATE/config.json" && chmod 600 "$STATE/config.json" || fail CONFIG_COPY
    [ -f "$STATE/config.json" ] && [ ! -L "$STATE/config.json" ] || fail CONFIG_REQUIRED
    config_meta=$(ls -ln "$STATE/config.json" 2>/dev/null)
    config_mode=$(printf '%s\n' "$config_meta" | awk '{print $1}')
    config_uid=$(printf '%s\n' "$config_meta" | awk '{print $3}')
    [ "$config_mode" = -rw------- ] && [ "$config_uid" = "$(id -u)" ] || fail PRIVATE_CONFIG_REQUIRED
    read -r current < "$ROOT/current" || fail NO_CURRENT
    version_ok "$current" || fail BINARY_CHANGED
    attempts=0; next=0
    if [ -r "$STATE/retry" ]; then read -r attempts next < "$STATE/retry" || fail RETRY_STATE; fi
    case $attempts:$next in *[!0-9:]*|:*) fail RETRY_STATE;; esac
    [ "$attempts" -lt 5 ] || fail RETRY_EXHAUSTED
    now=$(date +%s); [ "$now" -ge "$next" ] || fail BACKOFF
    if [ -r "$STATE/exit" ]; then read -r code < "$STATE/exit"; [ "$code" != 78 ] || fail FATAL_CONFIG; fi
    attempts=$((attempts+1)); delay=$((1 << attempts)); next=$((now+delay))
    printf '%s %s\n' "$attempts" "$next" > "$STATE/retry"
    rm -f "$STATE/exit"
    # No automatic restart, stdout/stderr or persistent flash logs.
    # The monitor only waits for this child and records its numeric exit code.
    (
        "$ROOT/versions/$current/worker" -config-file "$STATE/config.json" </dev/null >/dev/null 2>&1 &
        pid=$!
        born=$(start_time "$pid")
        if [ -z "$born" ]; then wait "$pid"; printf '%s\n' "$?" > "$STATE/exit"; exit; fi
        printf '%s %s %s\n' "$pid" "$born" "$current" > "$STATE/pid.stage"
        mv "$STATE/pid.stage" "$STATE/pid"
        wait "$pid"; rc=$?
        if [ "$(cat "$STATE/pid" 2>/dev/null)" = "$pid $born $current" ]; then
            printf '%s\n' "$rc" > "$STATE/exit"
        fi
    ) </dev/null >/dev/null 2>&1 &
    n=0
    while [ "$n" -lt 3 ]; do
        sleep 1
        if owned_running; then printf '%s\n' RUNNING_NOT_TUNNEL_PROOF > "$STATE/status"; return 0; fi
        [ ! -f "$STATE/exit" ] || fail START_FAILED
        n=$((n+1))
    done
    fail START_UNVERIFIED
}
if [ "$action" = install ]; then
    [ "$(id -u)" = 0 ] || fail ROOT_REQUIRED
    args_source=${2-}; args_digest=${3-}; args_arch=${4-}; args_port=${5-}
    admission "$args_source" "$args_digest" "$args_arch" "$args_port" || fail PREFLIGHT_REJECTED
    if [ ! -e "$ROOT" ]; then mkdir -m 700 "$ROOT" || fail ROOT_CREATE; fi
fi
private_dir "$ROOT" || fail PRIVATE_ROOT_REQUIRED
runtime_mount_ok || fail VOLATILE_RUNTIME_REQUIRED
if [ ! -e "$STATE" ]; then mkdir -m 700 "$STATE" || fail STATE_CREATE; fi
private_dir "$STATE" || fail PRIVATE_STATE_REQUIRED
command -v sha256sum >/dev/null 2>&1 || fail CHECKSUM_UNAVAILABLE
case $args_digest in *[!0-9a-f]*|'') [ "$action" != install ] || fail DIGEST_REJECTED;; esac
[ "$action" != install ] || [ "${#args_digest}" -eq 64 ] || fail DIGEST_REJECTED
if [ ! -f "$ROOT/owner" ]; then
    [ "$action" = install ] || fail NOT_INSTALLED
    [ -z "$(ls -A "$ROOT")" ] || fail FOREIGN_ROOT
    printf '%s\n' kas-wdtt-experimental-v1 > "$ROOT/owner" || fail OWNER_WRITE
fi
[ ! -L "$ROOT/owner" ] && [ "$(cat "$ROOT/owner")" = kas-wdtt-experimental-v1 ] || fail FOREIGN_OWNER
for name in versions current previous config.json current.stage previous.stage port service.sh service.sha256 init.sha256 owner; do
    [ ! -L "$ROOT/$name" ] || fail STATE_SYMLINK
    if [ -e "$ROOT/$name" ] && [ "$name" != versions ]; then
        ls -ln "$ROOT/$name" | awk -v uid="$(id -u)" '$1 ~ /^-rw[x-]------$/ && $2==1 && $3==uid {ok=1} END {exit !ok}' || fail PRIVATE_FILE_REQUIRED
    fi
done
for name in retry exit status pid config.json pid.stage; do
    [ ! -L "$STATE/$name" ] || fail STATE_SYMLINK
    if [ -e "$STATE/$name" ]; then
        ls -ln "$STATE/$name" | awk -v uid="$(id -u)" '$1=="-rw-------" && $2==1 && $3==uid {ok=1} END {exit !ok}' || fail PRIVATE_STATE_FILE_REQUIRED
    fi
done
mkdir "$STATE/lock" 2>/dev/null || fail LOCKED
trap 'rmdir "$STATE/lock" 2>/dev/null' 0
trap 'exit 78' 1 2 15

case $action in
    install)
        if [ -e "$ROOT/service.sh" ]; then
            [ -r "$ROOT/service.sha256" ] && [ "$(digest "$ROOT/service.sh")" = "$(cat "$ROOT/service.sha256")" ] || fail FOREIGN_SERVICE
        fi
        if [ -e "$INIT" ] || [ -L "$INIT" ]; then
            [ ! -L "$INIT" ] && [ -r "$ROOT/init.sha256" ] && [ "$(digest "$INIT")" = "$(cat "$ROOT/init.sha256")" ] || fail FOREIGN_INIT
        fi
        [ -f "$args_source" ] && [ ! -L "$args_source" ] || fail SOURCE_REJECTED
        [ "$(digest "$args_source")" = "$args_digest" ] || fail CHECKSUM_MISMATCH
        if [ "$(cat "$ROOT/current" 2>/dev/null)" = "$args_digest" ] && version_ok "$args_digest" &&
            [ "$(cat "$ROOT/port" 2>/dev/null)" = "$args_port" ] &&
            [ "$(digest "$ROOT/service.sh")" = "$(digest "$0")" ] &&
            [ "$(digest "$INIT")" = "$(digest "$(dirname "$0")/init.d")" ]; then
            printf '%s\n' INSTALL_UNCHANGED
            exit 0
        fi
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
        # Prepare script copies before stopping the old worker. Refuse stale
        # or foreign stage paths rather than following/overwriting them.
        txn="$ROOT/.txn-$$"
        mkdir "$txn" || fail SCRIPT_STAGE_CONFLICT
        [ ! -e "$INIT.stage-$$" ] && [ ! -L "$INIT.stage-$$" ] || fail INIT_STAGE_CONFLICT
        cp "$0" "$txn/service" && chmod 700 "$txn/service" || fail SERVICE_STAGE
        cp "$(dirname "$0")/init.d" "$INIT.stage-$$" && chmod 700 "$INIT.stage-$$" || fail INIT_STAGE
        owned_running; state=$?; [ "$state" -ne 2 ] || fail PROCESS_OWNERSHIP_UNKNOWN
        stop_worker
        previous=''; [ ! -r "$ROOT/current" ] || read -r previous < "$ROOT/current"
        [ "$previous" = "$args_digest" ] || printf '%s\n' "$previous" > "$ROOT/previous.stage"
        printf '%s\n' "$args_digest" > "$ROOT/current.stage" || fail STATE_WRITE
        mv "$ROOT/current.stage" "$ROOT/current" || fail STATE_COMMIT
        [ ! -e "$ROOT/previous.stage" ] || mv "$ROOT/previous.stage" "$ROOT/previous"
        # Files are staged on their own filesystem and selected atomically.
        mv "$txn/service" "$ROOT/service.sh" || fail SERVICE_COMMIT
        mv "$INIT.stage-$$" "$INIT" || fail INIT_COMMIT
        rmdir "$txn" || fail SCRIPT_STAGE_CLEANUP
        digest "$ROOT/service.sh" > "$ROOT/service.sha256"
        digest "$INIT" > "$ROOT/init.sha256"
        printf '%s\n' "$args_port" > "$ROOT/port"
        rm -f "$STATE/retry" "$STATE/exit"
        printf '%s\n' INSTALLED_AUTOSTART_DISABLED > "$STATE/status"
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
        rm -f "$STATE/retry" "$STATE/exit"
        printf '%s\n' ROLLED_BACK_STOPPED > "$STATE/status"
        ;;
    uninstall)
        # Validate all owned script hashes before deleting any managed file.
        [ "$(digest "$ROOT/service.sh")" = "$(cat "$ROOT/service.sha256")" ] || fail FOREIGN_SERVICE
        [ ! -L "$INIT" ] && [ "$(digest "$INIT")" = "$(cat "$ROOT/init.sha256")" ] || fail FOREIGN_INIT
        stop_worker
        set +f
        # Validate every owned binary before deleting any version.
        for v in "$ROOT"/versions/*; do [ -e "$v" ] || continue; version_ok "${v##*/}" || fail FOREIGN_VERSION; done
        for v in "$ROOT"/versions/*; do [ -e "$v" ] || continue; rm -f "$v/worker"; rmdir "$v" 2>/dev/null || :; done
        rmdir "$ROOT/versions" 2>/dev/null || :
        # Keep operator secrets and unknown files. Never rm -rf the sandbox.
        rm -f "$ROOT/current" "$ROOT/previous" "$STATE/retry" "$STATE/exit" "$STATE/status"
        rm -f "$INIT" "$ROOT/init.sha256" "$ROOT/service.sh" "$ROOT/service.sha256" "$ROOT/port"
        # Keep private config, WG output, credentials, owner marker and foreign files.
        printf '%s\n' UNINSTALLED_SECRETS_AND_UNKNOWN_FILES_RETAINED
        ;;
    *) fail ACTION_REJECTED;;
esac
