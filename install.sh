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

# BEGIN MIHOMO PROCESS STATE v1
# Identical standalone contract: 0 running, 1 stopped, 2 unknown.
# MP_PIDS contains only positive evidence; unknown is never absence.
mp_state() {
    local rc p exe name flags state data tail seen uncertain
    MP_PIDS=""
    if command -v pidof >/dev/null 2>&1; then
        if MP_PIDS=$(pidof mihomo 2>/dev/null); then
            [ -n "$MP_PIDS" ] || return 2
            seen=0
            for p in $MP_PIDS; do
                seen=1
                case "$p" in ''|0|*[!0-9]*) MP_PIDS=""; return 2 ;; esac
            done
            [ "$seen" -eq 1 ] || return 2
            return 0
        else
            rc=$?
            MP_PIDS=""
            [ "$rc" -eq 1 ] && return 1
            return 2
        fi
    fi
    # A restricted/incomplete proc view cannot establish absence.
    [ -r /proc/self/stat ] && [ -d /proc/1 ] && [ -r /proc/mounts ] || return 2
    if grep -Eq 'hidepid=([1-9]|invisible|noaccess)' /proc/mounts; then
        return 2
    else
        rc=$?
        [ "$rc" -eq 1 ] || return 2
    fi
    seen=0; uncertain=0
    for p in /proc/[0-9]*; do
        [ -d "$p" ] || continue
        seen=1
        if exe=$(readlink "$p/exe" 2>/dev/null); then
            exe=${exe% (deleted)}
            case "$exe" in
                /opt/sbin/mihomo|/opt/bin/mihomo|*/mihomo)
                    MP_PIDS="$MP_PIDS ${p##*/}"
                    continue ;;
            esac
            # A renamed executable may still be the canonical inode.
            for name in /opt/sbin/mihomo /opt/bin/mihomo; do
                if [ "$p/exe" -ef "$name" ]; then
                    MP_PIDS="$MP_PIDS ${p##*/}"
                    break
                fi
            done
            continue
        fi
        # Vanished processes, zombies and kernel threads execute no userspace ELF.
        [ -d "$p" ] || continue
        if data=$(cat "$p/stat" 2>/dev/null); then
            tail=${data##*) }
            state=${tail%% *}
            case "$state" in Z|X) continue ;; esac
            flags=$(printf '%s\n' "$tail" | awk 'NF >= 7 {print $7}')
            case "$flags" in
                ''|*[!0-9]*) ;;
                *) [ $((flags & 2097152)) -ne 0 ] && continue ;;
            esac
        fi
        [ -d "$p" ] && uncertain=1
    done
    [ "$seen" -eq 1 ] || return 2
    [ "$uncertain" -eq 0 ] || return 2
    [ -n "$MP_PIDS" ] && return 0
    return 1
}

mp_running() { mp_state; }
mp_stopped() {
    local rc
    if mp_state; then return 1; else rc=$?; fi
    [ "$rc" -eq 1 ]
}
mp_known() {
    local rc
    if mp_state; then return 0; else rc=$?; fi
    [ "$rc" -eq 1 ]
}
mp_pids() {
    mp_state || return 1
    printf '%s\n' "$MP_PIDS"
}
# END MIHOMO PROCESS STATE v1


set -e

echo "=== Keenetic Auto Setup ==="

MODE="${1:-ram}"
ALLOW_INTERNAL_DISK=0

if [ "$MODE" != "ram" ] && [ "$MODE" != "disk" ]; then
    echo "Usage: sh install.sh [ram|disk] [--allow-internal-disk]" >&2
    exit 1
fi

case "${2:-}" in
    "") ;;
    --allow-internal-disk) ALLOW_INTERNAL_DISK=1 ;;
    *)
        echo "Usage: sh install.sh [ram|disk] [--allow-internal-disk]" >&2
        exit 1
        ;;
esac

if [ -n "${3:-}" ]; then
    echo "Usage: sh install.sh [ram|disk] [--allow-internal-disk]" >&2
    exit 1
fi

if [ "$ALLOW_INTERNAL_DISK" -eq 1 ] && [ "$MODE" != "disk" ]; then
    status_err "[ERROR] --allow-internal-disk is valid only with disk mode."
    exit 1
fi

echo "[*] Mode: $MODE"

TMP_DIR="/tmp"

# Production delivery channel. Release installs read project-managed helper files
# from stable; development/testing may override the ref explicitly.
PROJECT_REF="${KEENETIC_AUTO_SETUP_REF:-stable}"
PROJECT_RAW_BASE="https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/${PROJECT_REF}"
MIHOMO_STAGE_MARGIN_KB=4096

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

log() { status_out "$COLOR_GREEN" "[setup] $1"; }
warn() { status_out "$COLOR_YELLOW" "[WARN] $1"; }
err() { status_out "$COLOR_RED" "[ERROR] $1"; exit 1; }

retry() {
    for i in 1 2 3; do
        "$@" && return 0
        warn "Retry $i/3 failed for: $*"
        sleep 2
    done
    return 1
}

# Managed download retries are intentionally quiet per attempt. A transport
# failure is summarized once by the caller before moving to the next fallback.
retry_silent() {
    for i in 1 2 3; do
        "$@" 2>/dev/null && return 0
        sleep 2
    done
    return 1
}

# Cleanup temp files on any exit
WATCHDOG_STAGE="/opt/bin/.mihomo_watchdog.sh.new.$$"
# Cleanup temp files on any exit (the watchdog stage lives on /opt,
# next to its final destination - a /tmp -> /opt move is not atomic
# and must never be claimed as such)
MAGITRICKLE_REPO_STAGE="$TMP_DIR/magitrickle-add-repo.$"
installer_cleanup() {
    # Shared temporary names may only be cleaned while this installer owns lifecycle.
    [ "$ML_LIFECYCLE_HELD" -eq 1 ] || return 0
    [ "$(cat "$MIHOMO_LIFECYCLE_LOCK/owner" 2>/dev/null)" = "$ML_ID" ] || return 0
    rm -f "$TMP_DIR/mihomo.ipk" "$TMP_DIR/mihomo-watchdog.new" "$WATCHDOG_STAGE" "$MAGITRICKLE_REPO_STAGE" "${WRAPPER_STAGE:-}" "${CRONTAB_STAGE:-}" "${CRON_CANDIDATE:-}"
    ml_lifecycle_release || true
}
trap installer_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# ---------------------------
# CHECK BASE
# ---------------------------
command -v opkg >/dev/null 2>&1 || err "opkg not found"

# ---------------------------
# RAM / STORAGE / SWAP PREFLIGHT
# ---------------------------
# Memory capacity, /opt location and swap backends are detected from live
# system state - never guessed. Resource-profile contract 20260927_1:
#   - 128 MB-class: best-effort/experimental. Installation is REFUSED unless
#     /opt is on verified EXTERNAL persistent storage AND EXTERNAL
#     storage-backed active swap is >= 384 MB. This is a project-specific
#     experimental floor, not a vendor-stated minimum. zRAM never satisfies it.
#   - 256 MB-class: project expects at least ONE active memory-pressure backend:
#     native KeeneticOS zRAM OR verified EXTERNAL storage-backed swap. Absence
#     is a WARN (installation continues), not a hard gate.
#   - 512 MB-class: supported new installs REQUIRE one active backend: native
#     KeeneticOS zRAM OR verified EXTERNAL storage-backed swap. No backend =>
#     hard ERROR before downloads/mutations; there is no model/AP-role exception.
#   - Above the 512 MB class: swap/zRAM is optional.
#   - If external swap is chosen on 256/512 MB-class, 1x detected RAM is the
#     project minimum floor for warning severity. Below 1x => WARN; from 1x up
#     to the preferred 3x target => INFO only. The preferred target is 3x RAM,
#     capped at 2 GiB. Current vendor docs say ~500 MB is enough for most tasks
#     and that usually more than 3x RAM is unnecessary; neither 1x nor 3x is a
#     vendor-stated minimum.
#   - External storage-backed swap above 2 GiB is a hard install ERROR.
#   - Vendor guidance says not to use zRAM together with a disk/file swap.
#     If both are active, warn but never change either backend automatically.
# See docs/06-s00ubifs.md for the vendor references behind this contract.
# Detection: /proc/meminfo (RAM/totals), /proc/swaps (active swap entries),
# /proc/mounts (deepest mount carrying a path). Keenetic conventions used for
# classification: internal storage is UBIFS (ubi*/mtd*, no block-device
# nodes, cannot host swap), USB/NVMe disks appear as /dev/sd*|/dev/nvme*
# with partitions mounted under /tmp/mnt/*. Unrecognized state fails
# conservatively where the contract requires proof.
# This script never creates, enables, formats or resizes swap or storage.
RESOURCE_PROFILE_CONTRACT_VERSION=20260927_1
RAM128_MAX_KB=200000      # below this total RAM = 128 MB-class
RAM256_MAX_KB=450000      # below this total RAM = 256 MB-class
RAM512_MAX_KB=786432      # below this total RAM = 512 MB-class (real ~486 MB MemTotal fits here)
SWAP128_MIN_KB=393216     # project-specific 384 MB hard floor for experimental 128 MB profile
SWAP_MAX_KB=2097152       # 2 GiB project/vendor cap for external storage-backed swap
SYS_CLASS_BLOCK="${INSTALL_SYS_CLASS_BLOCK:-/sys/class/block}"
PROC_MOUNTS="${INSTALL_MOUNTS:-/proc/mounts}"
PROC_SWAPS="${INSTALL_SWAPS:-/proc/swaps}"

# BEGIN ZRAM IDENTITY v1
# Active partition + real block device + matching zramN sysfs device number.
# BusyBox stat on Keenetic lacks GNU -c; use portable ls -ln metadata instead.
# Missing/contradictory evidence is unverified, never native zRAM.
swap_is_zram() {
    local path name number listing perms major minor expected sys_class
    [ "$2" = partition ] || return 1
    sys_class="$3"
    path=$(readlink -f "$1" 2>/dev/null) || return 1
    name=${path##*/}
    case "$name" in zram*) number=${name#zram} ;; *) return 1 ;; esac
    case "$number" in ''|*[!0-9]*) return 1 ;; esac
    listing=$(LC_ALL=C ls -ln "$path" 2>/dev/null) || return 1
    set -- $listing
    [ "$#" -ge 6 ] || return 1
    perms="$1"
    case "$perms" in b?????????) ;; *) return 1 ;; esac
    major=${5%,}
    minor="$6"
    case "$major:$minor" in ''|*[!0-9:]*) return 1 ;; esac
    expected=$(cat "$sys_class/$name/dev" 2>/dev/null) || return 1
    case "$expected" in ''|*[!0-9:]*) return 1 ;; esac
    [ "$major:$minor" = "$expected" ]
}
# END ZRAM IDENTITY v1

# classify_mount SOURCE FSTYPE -> internal | external | ram | unknown
classify_mount() {
    case "$2" in
        ubifs|squashfs) echo internal; return 0 ;;
        tmpfs|ramfs)    echo ram; return 0 ;;
    esac
    case "$1" in
        ubi*|mtd*) echo internal; return 0 ;;
    esac
    case "$2" in
        ext2|ext3|ext4|btrfs|f2fs|xfs|vfat|fat|exfat|ntfs|ntfs3|fuseblk) ;;
        *) echo unknown; return 0 ;;
    esac
    case "$1" in
        /dev/sd*|/dev/nvme*|/tmp/mnt/*) echo external ;;
        *) echo unknown ;;
    esac
}

# opt_storage_class PATH -> class of the deepest mount carrying PATH
opt_storage_class() {
    _osc_path="$1" _osc_bl=0 _osc_cls=unknown
    [ -r "$PROC_MOUNTS" ] || { echo unknown; return 0; }
    while read -r _osc_src _osc_mp _osc_fst _osc_rest; do
        case "$_osc_path" in
            "$_osc_mp") ;;
            *) case "$_osc_path" in
                   "$_osc_mp"/*) ;;
                   *) continue ;;
               esac ;;
        esac
        _osc_len=${#_osc_mp}
        [ "$_osc_len" -ge "$_osc_bl" ] || continue
        _osc_bl=$_osc_len
        _osc_cls=$(classify_mount "$_osc_src" "$_osc_fst")
    done < "$PROC_MOUNTS"
    echo "$_osc_cls"
}

# opt_mount_fstype PATH -> filesystem type of the deepest mount carrying PATH.
# This is deliberately independent from the storage-class classifier: external
# storage can be NTFS/exFAT/etc., but the project supports external Entware only
# when the actual /opt filesystem is ext4.
opt_mount_fstype() {
    _omf_path="$1" _omf_bl=0 _omf_fst=unknown
    [ -r "$PROC_MOUNTS" ] || { echo unknown; return 0; }
    while read -r _omf_src _omf_mp _omf_type _omf_rest; do
        case "$_omf_path" in
            "$_omf_mp") ;;
            *) case "$_omf_path" in
                   "$_omf_mp"/*) ;;
                   *) continue ;;
               esac ;;
        esac
        _omf_len=${#_omf_mp}
        [ "$_omf_len" -ge "$_omf_bl" ] || continue
        _omf_bl=$_omf_len
        _omf_fst=$_omf_type
    done < "$PROC_MOUNTS"
    echo "$_omf_fst"
}

# scan_swap_backends -> sets SW_ZRAM_KB / SW_EXT_KB / SW_UNVER_KB (-1 = /proc/swaps unreadable)
swap_source_capacity_kb() {
    _ssc_src="$1"
    _ssc_type="$2"
    _ssc_active_kb="$3"
    _ssc_cap=""
    case "$_ssc_type" in
        partition)
            _ssc_base=${_ssc_src##*/}
            _ssc_sectors=$(cat "$SYS_CLASS_BLOCK/$_ssc_base/size" 2>/dev/null || true)
            case "$_ssc_sectors" in
                ''|*[!0-9]*) : ;;
                *) _ssc_cap=$((_ssc_sectors / 2)) ;; # sysfs block size is reported in 512-byte sectors
            esac
            ;;
        file)
            if [ -f "$_ssc_src" ]; then
                _ssc_bytes=$(wc -c < "$_ssc_src" 2>/dev/null || true)
                case "$_ssc_bytes" in ''|*[!0-9]*) : ;; *) _ssc_cap=$((_ssc_bytes / 1024)) ;; esac
            fi
            ;;
    esac
    [ -n "$_ssc_cap" ] || _ssc_cap="$_ssc_active_kb"
    printf '%s' "$_ssc_cap"
}

scan_swap_backends() {
    SW_ZRAM_KB=0; SW_EXT_KB=0; SW_UNVER_KB=0
    SW_DELETED_KB=0; SW_DELETED_COUNT=0
    SW_EXT_MAX_BACKEND_KB=0; SW_EXT_OVERSIZE=0
    [ -r "$PROC_SWAPS" ] || { SW_UNVER_KB=-1; return 0; }
    while read -r _sw_file _sw_type _sw_size _sw_rest; do
        case "$_sw_file" in ''|Filename) continue ;; esac
        case "$_sw_size" in ''|*[!0-9]*) continue ;; esac
        case "$_sw_file" in
            *'\040(deleted)'*|*' (deleted)'*)
                SW_DELETED_KB=$((SW_DELETED_KB + _sw_size))
                SW_DELETED_COUNT=$((SW_DELETED_COUNT + 1))
                continue
                ;;
        esac
        if swap_is_zram "$_sw_file" "$_sw_type" "$SYS_CLASS_BLOCK"; then
            SW_ZRAM_KB=$((SW_ZRAM_KB + _sw_size)); continue
        fi
        case "$_sw_type" in
            partition)
                # Keenetic internal storage (UBIFS) has no block-device nodes
                # and cannot host swap - sd*/nvme* partitions are USB/NVMe disks.
                case "$_sw_file" in
                    /dev/sd*|/dev/nvme*)
                        SW_EXT_KB=$((SW_EXT_KB + _sw_size))
                        _sw_cap=$(swap_source_capacity_kb "$_sw_file" "$_sw_type" "$_sw_size")
                        [ "$_sw_cap" -gt "$SW_EXT_MAX_BACKEND_KB" ] 2>/dev/null && SW_EXT_MAX_BACKEND_KB=$_sw_cap
                        [ "$_sw_cap" -gt "$SWAP_MAX_KB" ] 2>/dev/null && SW_EXT_OVERSIZE=1
                        ;;
                    *) SW_UNVER_KB=$((SW_UNVER_KB + _sw_size)) ;;
                esac ;;
            file)
                case "$(opt_storage_class "$(dirname "$_sw_file")")" in
                    external)
                        SW_EXT_KB=$((SW_EXT_KB + _sw_size))
                        _sw_cap=$(swap_source_capacity_kb "$_sw_file" "$_sw_type" "$_sw_size")
                        [ "$_sw_cap" -gt "$SW_EXT_MAX_BACKEND_KB" ] 2>/dev/null && SW_EXT_MAX_BACKEND_KB=$_sw_cap
                        [ "$_sw_cap" -gt "$SWAP_MAX_KB" ] 2>/dev/null && SW_EXT_OVERSIZE=1
                        ;;
                    *) SW_UNVER_KB=$((SW_UNVER_KB + _sw_size)) ;;
                esac ;;
            *) SW_UNVER_KB=$((SW_UNVER_KB + _sw_size)) ;;
        esac
    done < "$PROC_SWAPS"
    [ "$SW_EXT_KB" -gt "$SWAP_MAX_KB" ] 2>/dev/null && SW_EXT_OVERSIZE=1
    return 0
}

MEMINFO="${INSTALL_MEMINFO:-/proc/meminfo}"
MEM_TOTAL_KB=$(awk '/^MemTotal:/ {print $2; exit}' "$MEMINFO" 2>/dev/null || true)
SWAP_TOTAL_KB=$(awk '/^SwapTotal:/ {print $2; exit}' "$MEMINFO" 2>/dev/null || true)
SWAP_TARGET_KB=0
case "$MEM_TOTAL_KB" in
    ''|*[!0-9]*) : ;;
    *)
        SWAP_TARGET_KB=$((MEM_TOTAL_KB * 3))
        [ "$SWAP_TARGET_KB" -gt "$SWAP_MAX_KB" ] && SWAP_TARGET_KB=$SWAP_MAX_KB
        ;;
esac
OPT_CLASS=$(opt_storage_class /opt)
OPT_FSTYPE=$(opt_mount_fstype /opt)
scan_swap_backends
case "$OPT_CLASS" in
    internal) log "/opt: internal Keenetic storage (filesystem: ${OPT_FSTYPE:-unknown})" ;;
    external) log "/opt: external persistent storage (filesystem: ${OPT_FSTYPE:-unknown})" ;;
    ram)      log "/opt: RAM-backed (tmpfs/ramfs) - not persistent" ;;
    *)        log "/opt: storage class cannot be determined (filesystem: ${OPT_FSTYPE:-unknown})" ;;
esac

# External-storage filesystem contract:
# Keenetic's current OPKG guidance requires an EXT filesystem and recommends
# ext4. This project intentionally narrows the supported external Entware
# profile to ext4 only. We do not format, convert or repair storage here.
if [ "$OPT_CLASS" = "external" ] && [ "$OPT_FSTYPE" != "ext4" ]; then
    err "Unsupported external /opt filesystem: detected '${OPT_FSTYPE:-unknown}'. The project supports external Entware /opt only on EXT4. Reformat/migrate the OPKG storage to EXT4 yourself, verify Entware starts from it, then re-run. The installer never formats or converts storage."
fi
if [ "$MODE" = "disk" ] && [ "$OPT_CLASS" = "ram" ]; then
    err "Storage-mode mismatch: disk mode was selected while /opt is RAM-backed. disk mode requires persistent storage (external EXT4, or the explicit internal-storage override)."
fi
if [ "$MODE" = "disk" ] && [ "$OPT_CLASS" = "unknown" ]; then
    err "Cannot verify the /opt storage/filesystem for disk mode from $PROC_MOUNTS. Refusing to continue because the disk-mode storage contract requires a proven persistent layout; external Entware must be on EXT4."
fi

# Storage-mode guardrail:
#   internal /opt + disk mode skips S00ubifs and leaves runtime/log writes on
#   internal flash. Treat that as an accidental mismatch unless the operator
#   explicitly opts in with the narrowly scoped override.
#   external /opt + ram mode is supported (tmpfs runtime on external Entware),
#   but warn because omitting "disk" is an easy mistake.
if [ "$MODE" = "disk" ] && [ "$OPT_CLASS" = "internal" ]; then
    if [ "$ALLOW_INTERNAL_DISK" -eq 1 ]; then
        warn "Storage-mode override accepted: disk mode on internal /opt. S00ubifs will be skipped, so /opt/tmp, /opt/var/log and /opt/var/run remain on internal storage. This is an explicit operator choice."
    else
        err "Storage-mode mismatch: disk mode was selected while /opt is on internal Keenetic storage. disk mode skips S00ubifs and keeps runtime/log writes on internal flash. Re-run without 'disk' (default ram mode). If this is intentional, use: sh install.sh disk --allow-internal-disk"
    fi
elif [ "$MODE" = "ram" ] && [ "$OPT_CLASS" = "external" ]; then
    warn "Storage-mode mismatch: ram mode was selected while /opt is on external persistent storage. This is supported, but /opt/tmp, /opt/var/log and /opt/var/run will use tmpfs and logs will be volatile. Use disk mode if you intended runtime/logs to stay on the external storage."
fi
[ "$SW_ZRAM_KB" -gt 0 ] 2>/dev/null && log "zRAM swap active: $((SW_ZRAM_KB / 1024)) MB"
[ "$SW_EXT_KB" -gt 0 ] 2>/dev/null && log "External storage-backed swap: $((SW_EXT_KB / 1024)) MB"
case "$SW_UNVER_KB" in
    -1) log "Active swap entries: cannot read $PROC_SWAPS" ;;
    0)  : ;;
    *)  log "Swap entries that could not be classified: $((SW_UNVER_KB / 1024)) MB" ;;
esac
if [ "$SW_DELETED_COUNT" -gt 0 ]; then
    warn "$SW_DELETED_COUNT swap source(s) are marked '(deleted)' in $PROC_SWAPS ($((SW_DELETED_KB / 1024)) MB active according to the kernel). They are treated as stale/ambiguous and are NOT counted toward verified external-SWAP capacity, sizing target, or the 2 GiB check. Reboot or clean up the stale swap state before relying on it."
fi
if [ "$SW_EXT_OVERSIZE" -eq 1 ]; then
    err "External storage-backed SWAP exceeds the 2 GiB project/vendor cap (active total: $((SW_EXT_KB / 1024)) MB; largest detected backend: $((SW_EXT_MAX_BACKEND_KB / 1024)) MB). Reduce the SWAP partition/file to <= 2048 MB and re-run. Stopping before package installation or project changes."
fi
if [ "$SW_ZRAM_KB" -gt 0 ] 2>/dev/null && [ "$SW_EXT_KB" -gt 0 ] 2>/dev/null; then
    warn "zRAM and external storage-backed swap are active together. Vendor guidance says not to use zRAM together with a disk/file swap; when disk swap is used, disable zRAM. Installation continues without changing either backend."
fi
case "$MEM_TOTAL_KB" in
    ''|*[!0-9]*)
        warn "Cannot determine total RAM from /proc/meminfo; continuing without the low-RAM preflight"
        ;;
    *)
        MEM_TOTAL_MB=$((MEM_TOTAL_KB / 1024))
        log "RAM: ${MEM_TOTAL_MB} MB total"
        if [ "$MEM_TOTAL_KB" -lt "$RAM128_MAX_KB" ]; then
            # 128 MB-class: hard prerequisites - external /opt AND external
            # storage-backed swap >= 384 MB. zRAM never counts. Anything that
            # cannot be verified fails conservatively, stating what exactly.
            case "$OPT_CLASS" in
                external) ;;
                internal|ram)
                    err "128 MB-class device (${MEM_TOTAL_MB} MB): /opt is on INTERNAL storage - the low-RAM prerequisite is not met. Stopping before any download or change. The best-effort/experimental 128 MB profile requires /opt on EXTERNAL persistent storage plus EXTERNAL storage-backed active swap of at least 384 MB (project-specific floor). Move Entware to external storage yourself - this project never mounts or formats anything - then re-run."
                    ;;
                *)
                    err "128 MB-class device (${MEM_TOTAL_MB} MB): cannot verify that /opt is on external persistent storage (unrecognized mount state in $PROC_MOUNTS). Stopping conservatively before any download or change. The best-effort/experimental 128 MB profile requires external /opt plus EXTERNAL storage-backed active swap of at least 384 MB (project-specific floor). Verify the mount state yourself and re-run."
                    ;;
            esac
            if [ "$SW_EXT_KB" -lt "$SWAP128_MIN_KB" ]; then
                err "128 MB-class device (${MEM_TOTAL_MB} MB): only $((SW_EXT_KB / 1024)) MB of EXTERNAL storage-backed active swap detected - the low-RAM prerequisite is not met (required at least 384 MB on external storage, 512 MB preferred). Active zRAM: $((SW_ZRAM_KB / 1024)) MB - zRAM does NOT count toward the required external-swap minimum; vendor guidance says zRAM should be disabled when disk/file swap is used. This project never creates or resizes swap; enable/attach the external swap yourself and re-run."
            fi
            warn "============================================================"
            warn "LOW-RAM / BEST-EFFORT INSTALL: ${MEM_TOTAL_MB} MB RAM + $((SW_EXT_KB / 1024)) MB external storage-backed swap"
            warn "EXPERIMENTAL / NO STABILITY GUARANTEE: prerequisites met (external /opt,"
            warn ">= 384 MB external storage-backed swap) - this profile"
            warn "is still NOT guaranteed to be stable."
            warn "Never run a second Mihomo process beside the daemon."
            warn "============================================================"
        elif [ "$MEM_TOTAL_KB" -lt "$RAM256_MAX_KB" ]; then
            if [ "$SW_UNVER_KB" = "-1" ]; then
                warn "256 MB-class device (${MEM_TOTAL_MB} MB): cannot read $PROC_SWAPS, so zRAM/external-SWAP presence cannot be verified. Project policy expects one active backend on the 256 MB-class, but installation continues."
            elif [ "$SW_ZRAM_KB" -gt 0 ]; then
                log "256 MB-class with active zRAM - supported project profile"
            elif [ "$SW_EXT_KB" -gt 0 ]; then
                log "256 MB-class with external storage-backed swap ($((SW_EXT_KB / 1024)) MB) and zRAM off"
                if [ "$SW_EXT_KB" -lt "$MEM_TOTAL_KB" ]; then
                    warn "External SWAP is below the project minimum floor: $((SW_EXT_KB / 1024)) MB active vs about $((MEM_TOTAL_KB / 1024)) MB minimum (1x detected RAM). Installation continues; this is project policy, not a vendor minimum."
                elif [ "$SWAP_TARGET_KB" -gt 0 ] && [ "$SW_EXT_KB" -lt "$SWAP_TARGET_KB" ]; then
                    log "External SWAP is below the preferred project sizing target but meets the minimum floor: $((SW_EXT_KB / 1024)) MB active, minimum about $((MEM_TOTAL_KB / 1024)) MB (1x RAM), preferred target about $((SWAP_TARGET_KB / 1024)) MB (3x RAM, capped at 2048 MB)."
                fi
            else
                warn "256 MB-class device (${MEM_TOTAL_MB} MB) has neither active zRAM nor verified external storage-backed SWAP. Project policy expects one backend on the 256 MB-class; installation continues, but memory-pressure stability is not guaranteed."
            fi
        elif [ "$MEM_TOTAL_KB" -lt "$RAM512_MAX_KB" ]; then
            if [ "$SW_ZRAM_KB" -gt 0 ]; then
                log "512 MB-class with active zRAM - supported project profile"
            elif [ "$SW_EXT_KB" -gt 0 ]; then
                log "512 MB-class with external storage-backed swap ($((SW_EXT_KB / 1024)) MB) and zRAM off"
                if [ "$SW_EXT_KB" -lt "$MEM_TOTAL_KB" ]; then
                    warn "External SWAP is below the project minimum floor: $((SW_EXT_KB / 1024)) MB active vs about $((MEM_TOTAL_KB / 1024)) MB minimum (1x detected RAM). Installation continues; this is project policy, not a vendor minimum."
                elif [ "$SWAP_TARGET_KB" -gt 0 ] && [ "$SW_EXT_KB" -lt "$SWAP_TARGET_KB" ]; then
                    log "External SWAP is below the preferred project sizing target but meets the minimum floor: $((SW_EXT_KB / 1024)) MB active, minimum about $((MEM_TOTAL_KB / 1024)) MB (1x RAM), preferred target about $((SWAP_TARGET_KB / 1024)) MB (3x RAM, capped at 2048 MB)."
                fi
            else
                err "512 MB-class device (${MEM_TOTAL_MB} MB) has neither active zRAM nor verified external storage-backed SWAP. Bare 512 MB RAM is NOT a supported project baseline: this memory class REQUIRES active KeeneticOS zRAM OR verified external storage-backed SWAP. Stopping before package installation or project changes to preserve memory-pressure/OOM headroom. There is no low-memory/AP-role override; enable one backend and re-run."
            fi
        else
            log "Above-512 MB memory class (${MEM_TOTAL_MB} MB): swap/zRAM is optional"
        fi
        ;;
esac

# ---------------------------
# REQUIRED KEENETICOS COMPONENT PREFLIGHT
# ---------------------------
# Current default project install depends on three fixed named KeeneticOS
# components plus at least ONE secure-DNS proxy component. Keenetic's Proxy
# Client documentation warns that Internet access through a proxy may work
# incorrectly without DoT/DoH and recommends enabling DNS-over-TLS or
# DNS-over-HTTPS for reliable proxy access. External Entware /opt additionally
# requires the two EXT4 storage components:
#   proxy                -> Proxy client / Клиент прокси
#   dns-filter           -> Cloud-based content filtering and ad blocking
#   opkg-kmod-netfilter  -> Kernel modules for Netfilter
#   dns-tls OR dns-https -> at least one secure-DNS proxy component
#   ext                  -> Ext filesystem / Файловая система Ext (external /opt)
#   ext-utils            -> EXT4 filesystem utilities / Утилиты EXT4 (external /opt)
# Open Package support itself is verified earlier by command -v opkg.
# Read the component set from "show version" and fail BEFORE installer-managed
# opkg update, package installation, or persistent router configuration changes.
PROXY_COMPONENT_ID=proxy
DNS_FILTER_COMPONENT_ID=dns-filter
NETFILTER_COMPONENT_ID=opkg-kmod-netfilter
DNS_TLS_COMPONENT_ID=dns-tls
DNS_HTTPS_COMPONENT_ID=dns-https
EXT_COMPONENT_ID=ext
EXT_UTILS_COMPONENT_ID=ext-utils

component_list_from_show_version() {
    # ndmc wraps long component IDs at the terminal width. The wrap may split
    # an ID after '-' (for example dns- / filter or opkg-kmod- / netfilter),
    # so parse only the components field and concatenate its continuation
    # lines before matching exact comma-delimited IDs.
    printf '%s\n' "$KEENETIC_VERSION_DUMP" | awk '
        /^[[:space:]]*components:[[:space:]]*/ {
            in_components=1
            line=$0
            sub(/^[[:space:]]*components:[[:space:]]*/, "", line)
            gsub(/[[:space:]]/, "", line)
            printf "%s", line
            next
        }
        in_components {
            line=$0
            sub(/^[[:space:]]*/, "", line)
            if (line ~ /^[[:alnum:]_-]+(,[[:alnum:]_-]+)*,?$/) {
                gsub(/[[:space:]]/, "", line)
                printf "%s", line
                next
            }
            exit
        }
        END {
            if (in_components) printf "\n"
        }
    '
}

component_list_has() {
    _clh_id="$1"
    [ -n "$KEENETIC_COMPONENT_LIST" ] || return 1
    printf '%s\n' "$KEENETIC_COMPONENT_LIST" | grep -Eq "(^|,)${_clh_id}(,|$)"
}

required_components_preflight_error() {
    _rc_reason="$1"
    status_err "[ERROR] $_rc_reason"
    status_err "[ERROR] Full required component contract for the current default project profile:"
    status_err "[ERROR]   - Proxy client / Клиент прокси (component id: ${PROXY_COMPONENT_ID}) — provides ProxyN -> Mihomo."
    status_err "[ERROR]   - Cloud-based content filtering and ad blocking / Фильтрация контента и блокировка рекламы при помощи облачных сервисов (component id: ${DNS_FILTER_COMPONENT_ID}) — provides the DNS-filter/interception component family required by the supported dns-proxy intercept profile."
    status_err "[ERROR]   - Kernel modules for Netfilter / Модули ядра подсистемы Netfilter (component id: ${NETFILTER_COMPONENT_ID}) — required by the project 020-bypass_wa.sh VoIP bypass path."
    status_err "[ERROR]   - At least ONE secure DNS proxy component: DNS-over-TLS proxy (${DNS_TLS_COMPONENT_ID}) OR DNS-over-HTTPS proxy (${DNS_HTTPS_COMPONENT_ID}) — Keenetic recommends DoT/DoH for reliable Internet access through Proxy Client."
    if [ "$OPT_CLASS" = "external" ]; then
        status_err "[ERROR]   - Ext filesystem / Файловая система Ext (component id: ${EXT_COMPONENT_ID}) — required for the supported external EXT4 /opt profile."
        status_err "[ERROR]   - EXT4 filesystem utilities / Утилиты EXT4 (component id: ${EXT_UTILS_COMPONENT_ID}) — required so KeeneticOS can check/repair the external EXT4 filesystem (KeeneticOS 5.1+ storage tools)."
    fi
    status_err "[ERROR] Enable the missing component(s) manually in KeeneticOS -> General system settings / Общие настройки системы -> KeeneticOS update and components / Обновление и компоненты KeeneticOS -> Change component set / Изменить набор компонентов."
    status_err "[ERROR] The installer does not install KeeneticOS components. No project components or router settings have been changed; stopping before installer-managed opkg update and project package installation."
    exit 1
}

require_project_keeneticos_components() {
    log "Checking required KeeneticOS components"
    command -v ndmc >/dev/null 2>&1 ||
        required_components_preflight_error "Cannot verify KeeneticOS components because ndmc is not available."

    KEENETIC_VERSION_DUMP=$(ndmc -c "show version" 2>/dev/null || true)
    [ -n "$KEENETIC_VERSION_DUMP" ] ||
        required_components_preflight_error "Cannot read 'show version'; required component state is UNKNOWN."

    KEENETIC_COMPONENT_LIST=$(component_list_from_show_version)
    [ -n "$KEENETIC_COMPONENT_LIST" ] ||
        required_components_preflight_error "Cannot parse the components field from 'show version'; required component state is UNKNOWN."

    _rc_missing_count=0
    _rc_missing_lines=""

    if ! component_list_has "$PROXY_COMPONENT_ID"; then
        _rc_missing_count=$((_rc_missing_count + 1))
        _rc_missing_lines="${_rc_missing_lines}
[ERROR]   - Proxy client / Клиент прокси (${PROXY_COMPONENT_ID})"
    fi
    if ! component_list_has "$DNS_FILTER_COMPONENT_ID"; then
        _rc_missing_count=$((_rc_missing_count + 1))
        _rc_missing_lines="${_rc_missing_lines}
[ERROR]   - Cloud-based content filtering and ad blocking / Фильтрация контента и блокировка рекламы при помощи облачных сервисов (${DNS_FILTER_COMPONENT_ID})"
    fi
    if ! component_list_has "$NETFILTER_COMPONENT_ID"; then
        _rc_missing_count=$((_rc_missing_count + 1))
        _rc_missing_lines="${_rc_missing_lines}
[ERROR]   - Kernel modules for Netfilter / Модули ядра подсистемы Netfilter (${NETFILTER_COMPONENT_ID})"
    fi
    _rc_secure_dns_present=""
    if component_list_has "$DNS_TLS_COMPONENT_ID"; then
        _rc_secure_dns_present="$DNS_TLS_COMPONENT_ID"
    fi
    if component_list_has "$DNS_HTTPS_COMPONENT_ID"; then
        if [ -n "$_rc_secure_dns_present" ]; then
            _rc_secure_dns_present="$_rc_secure_dns_present + $DNS_HTTPS_COMPONENT_ID"
        else
            _rc_secure_dns_present="$DNS_HTTPS_COMPONENT_ID"
        fi
    fi
    if [ -z "$_rc_secure_dns_present" ]; then
        _rc_missing_count=$((_rc_missing_count + 1))
        _rc_missing_lines="${_rc_missing_lines}
[ERROR]   - At least one secure DNS proxy component is required: DNS-over-TLS proxy (${DNS_TLS_COMPONENT_ID}) OR DNS-over-HTTPS proxy (${DNS_HTTPS_COMPONENT_ID})"
    fi
    if [ "$OPT_CLASS" = "external" ] && ! component_list_has "$EXT_COMPONENT_ID"; then
        _rc_missing_count=$((_rc_missing_count + 1))
        _rc_missing_lines="${_rc_missing_lines}
[ERROR]   - Ext filesystem / Файловая система Ext (${EXT_COMPONENT_ID})"
    fi
    if [ "$OPT_CLASS" = "external" ] && ! component_list_has "$EXT_UTILS_COMPONENT_ID"; then
        _rc_missing_count=$((_rc_missing_count + 1))
        _rc_missing_lines="${_rc_missing_lines}
[ERROR]   - EXT4 filesystem utilities / Утилиты EXT4 (${EXT_UTILS_COMPONENT_ID})"
    fi

    if [ "$_rc_missing_count" -gt 0 ]; then
        status_err "[ERROR] Missing required KeeneticOS component(s):"
        printf '%s%s%s\n' "$COLOR_ERR_RED" "${_rc_missing_lines#?}" "$COLOR_ERR_RESET" >&2
        required_components_preflight_error "Install the component(s) listed above before continuing."
    fi

    if [ "$OPT_CLASS" = "external" ]; then
        log "Required KeeneticOS components present: ${PROXY_COMPONENT_ID}, ${DNS_FILTER_COMPONENT_ID}, ${NETFILTER_COMPONENT_ID}, secure DNS: ${_rc_secure_dns_present}, ${EXT_COMPONENT_ID}, ${EXT_UTILS_COMPONENT_ID}"
    else
        log "Required KeeneticOS components present: ${PROXY_COMPONENT_ID}, ${DNS_FILTER_COMPONENT_ID}, ${NETFILTER_COMPONENT_ID}, secure DNS: ${_rc_secure_dns_present}"
    fi
}

require_project_keeneticos_components
ml_lifecycle_acquire || err "Mihomo lifecycle is busy or unverifiable; installation not started. Check /tmp/mihomo-lifecycle.lock.d and its .guard."
mp_known || err "Mihomo runtime UNKNOWN; installation not started."
# ---------------------------
# OPKG UPDATE
# ---------------------------
log "Updating opkg..."
retry opkg update || err "opkg update failed"

# ---------------------------
# BASE PACKAGES (strict install)
# ---------------------------
log "Installing base packages..."

pkg_is_installed() {
    case "$1" in
        curl|jq|nano)
            command -v "$1" >/dev/null 2>&1
            ;;
        *)
            opkg list-installed 2>/dev/null | grep -q "^$1 "
            ;;
    esac
}

pkg_ensure() {
    _pkg="$1"
    if pkg_is_installed "$_pkg"; then
        log "$_pkg already installed"
        return 0
    fi
    log "Installing $_pkg..."
    opkg install "$_pkg" || err "Failed to install $_pkg"
}

pkg_ensure ca-bundle
pkg_ensure curl
pkg_ensure jq
pkg_ensure nano
pkg_ensure cron

command -v jq >/dev/null 2>&1 || err "jq not available after install"

# ---------------------------
# PROJECT FILE DELIVERY
# ---------------------------
# A live field install saw raw.githubusercontent.com reset the connection after
# earlier GitHub downloads had already succeeded. Project-managed helper scripts
# therefore use a bounded multi-transport delivery chain:
#   1) raw.githubusercontent.com via curl (3 attempts)
#   2) the same raw URL via wget (3 attempts, when wget exists)
#   3) GitHub Contents API raw media via api.github.com (3 attempts)
#
# Every candidate is downloaded to /tmp first, must be a non-empty /bin/sh
# script and pass sh -n, then is copied beside the destination and committed
# with a same-filesystem rename. A failed transfer never truncates an already
# installed project file.
PROJECT_API_CONTENTS="https://api.github.com/repos/saymer-alt/keenetic-auto-setup/contents"

project_script_candidate_ok() {
    _psc_file="$1"
    [ -s "$_psc_file" ] || return 1
    [ "$(head -n 1 "$_psc_file" 2>/dev/null)" = "#!/bin/sh" ] || return 1
    sh -n "$_psc_file" >/dev/null 2>&1
}

# Invalidate each attempt, including retries within one transport. A successful
# attempt that writes nothing must not inherit a failed attempt's valid prefix.
project_script_transfer() {
    _pst_dest="$1"
    shift
    rm -f "$_pst_dest" || return 1
    if "$@"; then
        return 0
    fi
    rm -f "$_pst_dest"
    return 1
}

project_script_curl_retry() {
    _pc_url="$1"
    _pc_dest="$2"
    _pc_api="${3:-0}"

    if [ "$_pc_api" -eq 1 ]; then
        if retry_silent project_script_transfer "$_pc_dest" curl -fsSL \
            --connect-timeout 5 --max-time 20 \
            -H "Accept: application/vnd.github.raw+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "$_pc_url" -o "$_pc_dest"; then
            return 0
        fi
        project_script_transfer "$_pc_dest" curl -fsSL \
            --connect-timeout 5 --max-time 20 -4 --curves X25519 \
            -H "Accept: application/vnd.github.raw+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "$_pc_url" -o "$_pc_dest"
    else
        if retry_silent project_script_transfer "$_pc_dest" curl -fsSL \
            --connect-timeout 5 --max-time 20 \
            "$_pc_url" -o "$_pc_dest"; then
            return 0
        fi
        project_script_transfer "$_pc_dest" curl -fsSL \
            --connect-timeout 5 --max-time 20 -4 --curves X25519 \
            "$_pc_url" -o "$_pc_dest"
    fi
}

project_script_download() {
    _psd_rel="$1"
    _psd_dest="$2"
    _psd_tmp="$TMP_DIR/.keenetic-auto-setup-download.$$"
    _psd_stage="${_psd_dest}.new.$$"
    _psd_raw="$PROJECT_RAW_BASE/$_psd_rel"
    _psd_api="$PROJECT_API_CONTENTS/$_psd_rel?ref=$PROJECT_REF"

    rm -f "$_psd_tmp" "$_psd_stage" 2>/dev/null || return 1

    if project_script_curl_retry "$_psd_raw" "$_psd_tmp"; then
        if project_script_candidate_ok "$_psd_tmp"; then
            :
        else
            rm -f "$_psd_tmp" || return 1
            if command -v wget >/dev/null 2>&1; then
                warn "raw/curl returned an invalid script candidate for $_psd_rel; trying wget fallback"
            else
                warn "raw/curl returned an invalid script candidate for $_psd_rel; wget unavailable, trying GitHub Contents API fallback"
            fi
        fi
    else
        # curl may leave a partial non-empty file after a reset; never let that
        # suppress the next transport.
        rm -f "$_psd_tmp" || return 1
        if command -v wget >/dev/null 2>&1; then
            warn "raw/curl failed after bounded retries for $_psd_rel; trying wget fallback"
        else
            warn "raw/curl failed after bounded retries for $_psd_rel; wget unavailable, trying GitHub Contents API fallback"
        fi
    fi

    if [ ! -s "$_psd_tmp" ] && command -v wget >/dev/null 2>&1; then
        rm -f "$_psd_tmp" || return 1
        if retry_silent project_script_transfer "$_psd_tmp" wget -qO "$_psd_tmp" "$_psd_raw"; then
            if project_script_candidate_ok "$_psd_tmp"; then
                :
            else
                warn "raw/wget returned an invalid script candidate for $_psd_rel; trying GitHub Contents API fallback"
                rm -f "$_psd_tmp" || return 1
            fi
        else
            rm -f "$_psd_tmp" || return 1
            warn "raw/wget failed after 3 attempts for $_psd_rel; trying GitHub Contents API fallback"
        fi
    fi

    if [ ! -s "$_psd_tmp" ]; then
        rm -f "$_psd_tmp" || return 1
        if project_script_curl_retry "$_psd_api" "$_psd_tmp" 1; then
            if ! project_script_candidate_ok "$_psd_tmp"; then
                warn "GitHub Contents API returned an invalid script candidate for $_psd_rel"
                rm -f "$_psd_tmp" || return 1
            fi
        else
            # Syntax-valid partial content is still invalid after transport failure.
            rm -f "$_psd_tmp" "$_psd_stage" 2>/dev/null || true
            return 1
        fi
    fi

    if ! project_script_candidate_ok "$_psd_tmp"; then
        rm -f "$_psd_tmp" "$_psd_stage" 2>/dev/null || true
        return 1
    fi

    _psd_dir=${_psd_dest%/*}
    [ "$_psd_dir" = "$_psd_dest" ] && _psd_dir="."
    mkdir -p "$_psd_dir" || {
        rm -f "$_psd_tmp" "$_psd_stage" 2>/dev/null || true
        return 1
    }

    if ! cp -f "$_psd_tmp" "$_psd_stage" || ! project_script_candidate_ok "$_psd_stage"; then
        rm -f "$_psd_tmp" "$_psd_stage" 2>/dev/null || true
        return 1
    fi
    if ! mv -f "$_psd_stage" "$_psd_dest"; then
        rm -f "$_psd_tmp" "$_psd_stage" 2>/dev/null || true
        return 1
    fi

    rm -f "$_psd_tmp" 2>/dev/null || true
    return 0
}

fetch_url_text() {
    _fut_url="$1"
    _fut_out=""

    if command -v curl >/dev/null 2>&1; then
        _fut_out=$(retry_silent curl -fsSL --connect-timeout 5 --max-time 20 "$_fut_url") || _fut_out=""
        if [ -z "$_fut_out" ]; then
            _fut_out=$(curl -fsSL --connect-timeout 5 --max-time 20 -4 --curves X25519 "$_fut_url" 2>/dev/null) || _fut_out=""
        fi
        if [ -n "$_fut_out" ]; then
            printf '%s' "$_fut_out"
            return 0
        fi
    fi

    if command -v wget >/dev/null 2>&1; then
        _fut_out=$(retry_silent wget -qO- -T 20 "$_fut_url") || _fut_out=""
        if [ -n "$_fut_out" ]; then
            printf '%s' "$_fut_out"
            return 0
        fi
    fi

    return 1
}

download_url_file() {
    _duf_url="$1"
    _duf_dst="$2"

    rm -f "$_duf_dst" 2>/dev/null || true

    if command -v curl >/dev/null 2>&1; then
        if retry_silent curl -fL --connect-timeout 5 --max-time 20 "$_duf_url" -o "$_duf_dst"; then
            [ -s "$_duf_dst" ] && return 0
        fi
        rm -f "$_duf_dst" 2>/dev/null || true
        if curl -fL --connect-timeout 5 --max-time 20 -4 --curves X25519 "$_duf_url" -o "$_duf_dst" 2>/dev/null; then
            [ -s "$_duf_dst" ] && return 0
        fi
        rm -f "$_duf_dst" 2>/dev/null || true
    fi

    if command -v wget >/dev/null 2>&1; then
        warn "curl download failed after 3 attempts; trying wget fallback"
        if retry_silent wget -qO "$_duf_dst" "$_duf_url"; then
            [ -s "$_duf_dst" ] && return 0
        fi
        rm -f "$_duf_dst" 2>/dev/null || true
    fi

    return 1
}

# ---------------------------
# SYSTEM INFO
# ---------------------------
log "Router: $(ndmc -c "show version" 2>/dev/null | grep -Ei 'model|hw id' | head -1 || echo "unknown")"
log "Free space on /opt: $(df -h /opt 2>/dev/null | awk 'NR==2 {print $4}' || echo "unknown")"

# ---------------------------
# bypass_wa policy
# ---------------------------
log "Configuring bypass_wa..."

if ! ndmc -c "show ip policy" 2>/dev/null | grep -w -q "bypass_wa"; then
    ndmc -c "ip policy bypass_wa" >/dev/null 2>&1 || warn "Failed to create bypass_wa policy"
    ndmc -c "ip policy bypass_wa description bypass_wa" >/dev/null 2>&1
fi

# ---------------------------
# DNS TRANSIT INTERCEPTION
# ---------------------------
# Clients' classic (port 53) DNS must go through Keenetic's DNS proxy so
# MagiTrickle sees every query and can classify routes. Enabling transit
# interception redirects queries addressed straight to external resolvers
# into the system DNS profile instead of letting them bypass the router.
# This is not a DoH/DoT protection: encrypted DNS is not affected.
log "Configuring DNS transit interception..."

if ndmc -c "show running-config" 2>/dev/null | grep -q "intercept enable"; then
    log "DNS transit interception already enabled, skipping"
else
    if ! ndmc -c "dns-proxy intercept enable" >/dev/null 2>&1; then
        err "Failed to enable required DNS transit interception"
    fi
    ndmc -c "system configuration save" >/dev/null 2>&1 || warn "Failed to save DNS transit interception immediately"
    # Critical persistent mutation: do not continue a long install after a
    # command that appeared to succeed but did not take effect.
    if ! ndmc -c "show running-config" 2>/dev/null | grep -q "intercept enable"; then
        err "DNS transit interception did not appear in running-config after enable; installation cannot satisfy the MagiTrickle DNS contract"
    fi
fi

# ---------------------------
# TMPFS
# ---------------------------
if [ "$MODE" = "ram" ]; then
    log "Installing S00ubifs..."

    if project_script_download "S00ubifs" "/opt/etc/init.d/S00ubifs"; then
        chmod +x /opt/etc/init.d/S00ubifs
        /opt/etc/init.d/S00ubifs start || err "S00ubifs start failed; RAM mode initialization incomplete"
    else
        warn "S00ubifs download failed after raw/curl, raw/wget and GitHub API fallbacks"
    fi
else
    log "Skip S00ubifs (disk mode)"
fi

# ---------------------------
# DETECT ARCH
# ---------------------------
ARCH=$(opkg print-architecture | awk '/^arch/ && $2~/^(mips|mipsel|aarch64|arm)/{
    sub(/[-_].*/,"",$2); print $2; exit
}')

[ -z "$ARCH" ] && err "Cannot detect architecture"

log "Arch: $ARCH"

# ---------------------------
# MIHOMO INSTALL
# ---------------------------
# install.sh owns initial installation, not upgrades of an existing Mihomo.
# Existing canonical binaries are left untouched; update-mihomo.sh is the
# supported transactional path for replacing an installed binary.
resolve_installed_mihomo() {
    for _mb in /opt/sbin/mihomo /opt/bin/mihomo; do
        if [ -x "$_mb" ]; then
            printf '%s\n' "$_mb"
            return 0
        fi
    done
    return 1
}

# Conservative one-Mihomo guard used by both the early informational version
# probe and final self-check. Only a positive stopped observation permits ELF probes.
mihomo_running() {
    mp_running
}

REPO_OWNER="saymer-alt"
REPO_NAME="entware-go"

case "$ARCH" in
    aarch64*) IPK_SUFFIX="aarch64-3.10" ;;
    armv7*|arm*) IPK_SUFFIX="armv7-3.2" ;;
    mipsel*) IPK_SUFFIX="mipsel-3.4" ;;
    mips*) IPK_SUFFIX="mips-3.4" ;;
    *) err "Unsupported arch: $ARCH" ;;
esac

# Select a unique exact package basename for the already-detected architecture.
# Input is one URL/path per line from jq, API grep or HTML; duplicates are harmless.
select_mihomo_asset() {
    awk -v suffix="_$IPK_SUFFIX.ipk" '
    {
        url=$0; name=url; sub(/^.*\//, "", name)
        if (substr(name, length(name)-length(suffix)+1) != suffix) next
        version=substr(name, 8, length(name)-7-length(suffix))
        if (substr(name,1,7) != "mihomo_" || version !~ /^[0-9][A-Za-z0-9.+-]*$/) next
        if (!seen[url]++) {selected=url; count++}
    }
    END {if (count == 1) print selected; else if (count > 1) exit 2; else exit 1}'
}

asset_selection_failed() {
    [ "$1" -ne 2 ] || err "Ambiguous Mihomo packages for $IPK_SUFFIX; refusing selection or feed fallback"
    return 0
}

MIHOMO_RESTART_NEEDED=0
MIHOMO_BIN=$(resolve_installed_mihomo 2>/dev/null || true)

if [ -n "$MIHOMO_BIN" ]; then
    log "Existing Mihomo binary found at $MIHOMO_BIN - package install/upgrade skipped"
    log "Use update-mihomo.sh to update an installed Mihomo transactionally"
else
    mp_stopped || err "Cannot prove Mihomo stopped before package installation."
    log "Installing Mihomo..."
    log "Looking for mihomo ipk ($IPK_SUFFIX) in $REPO_OWNER/$REPO_NAME..."

    API_URL="https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest"
    ASSETS_JSON=$(fetch_url_text "$API_URL") || ASSETS_JSON=""
    DOWNLOAD_URL=""

    if [ -n "$ASSETS_JSON" ]; then
        DOWNLOAD_URL=$(printf '%s\n' "$ASSETS_JSON" | jq -r '
            .assets[]? | select(.name == (.browser_download_url | split("/") | last))
            | .browser_download_url
        ' 2>/dev/null | select_mihomo_asset) || asset_selection_failed "$?"
    fi

    if [ -z "$DOWNLOAD_URL" ]; then
        log "jq filter empty, trying grep fallback on API response..."
        DOWNLOAD_URL=$(printf '%s\n' "$ASSETS_JSON" |
            grep -o '"browser_download_url": *"[^"]*"' | sed 's/.*": *"//;s/"$//' |
            select_mihomo_asset) || asset_selection_failed "$?"
    fi

    if [ -z "$DOWNLOAD_URL" ]; then
        log "API failed, trying direct API grep..."
        ASSETS_JSON=$(fetch_url_text "$API_URL") || ASSETS_JSON=""
        DOWNLOAD_URL=$(printf '%s\n' "$ASSETS_JSON" |
            grep -o '"browser_download_url": *"[^"]*"' | sed 's/.*": *"//;s/"$//' |
            select_mihomo_asset) || asset_selection_failed "$?"
    fi

    if [ -z "$DOWNLOAD_URL" ]; then
        log "Trying HTML scraping..."
        HTML_URL="https://github.com/$REPO_OWNER/$REPO_NAME/releases/latest"
        HTML_BODY=$(fetch_url_text "$HTML_URL") || HTML_BODY=""
        REL_PATH=$(printf '%s\n' "$HTML_BODY" |
            grep -oE 'href="/[^"]*releases/download/[^"]*"' | cut -d'"' -f2 |
            select_mihomo_asset) || asset_selection_failed "$?"
        if [ -n "$REL_PATH" ]; then DOWNLOAD_URL="https://github.com$REL_PATH"; fi
    fi

    # GitHub Releases are the primary package source; the Entware feed below
    # is a last-resort initial-install fallback, not an upgrade path.
    MIHOMO_INSTALLED=0

    if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ]; then
        warn "No mihomo ipk found for arch suffix: $IPK_SUFFIX. Check https://github.com/$REPO_OWNER/$REPO_NAME/releases"
    else
        log "Found: $(basename "$DOWNLOAD_URL")"
        log "Downloading..."
        if download_url_file "$DOWNLOAD_URL" "$TMP_DIR/mihomo.ipk"; then
            log "Installing package..."
            if opkg install "$TMP_DIR/mihomo.ipk"; then
                MIHOMO_INSTALLED=1
                MIHOMO_RESTART_NEEDED=1
            else
                warn "Mihomo install from the downloaded GitHub package failed"
            fi
        else
            warn "Failed to download mihomo ipk"
        fi
    fi

    rm -f "$TMP_DIR/mihomo.ipk"

    if [ "$MIHOMO_INSTALLED" -eq 0 ]; then
        warn "GitHub Mihomo package unavailable, trying Entware feed fallback..."
        opkg install mihomo || err "Mihomo install failed: GitHub package unavailable and Entware feed fallback failed"
        MIHOMO_RESTART_NEEDED=1
        log "Mihomo installed from Entware feed fallback (version may be older than the GitHub release build)"
    fi

    MIHOMO_BIN=$(resolve_installed_mihomo 2>/dev/null || true)
    [ -z "$MIHOMO_BIN" ] && err "Mihomo package installation completed but no executable canonical binary was found at /opt/sbin/mihomo or /opt/bin/mihomo"
fi

if ! mp_stopped; then
    log "Mihomo version probe skipped - daemon is running or state is unknown (one-Mihomo invariant)"
elif MIHOMO_VERSION_OUTPUT=$("$MIHOMO_BIN" -v 2>/dev/null); then
    log "Mihomo version: $(printf '%s\n' "$MIHOMO_VERSION_OUTPUT" | head -1)"
else
    warn "Mihomo version probe failed while no daemon was detected"
fi

# ---------------------------
# MIHOMO BOOTSTRAP CONFIG
# ---------------------------
# The mihomo ipk ships a placeholder config.yaml (a conffile). Package builds
# before the entware-go mixed-port fix declared only transparent-proxy ports
# (tproxy/redir) and no mixed-port: 7890 — the project contract port (Proxy0
# upstream, watchdog, self-check). Provide a project bootstrap instead:
#   - config.yaml missing -> create it;
#   - config.yaml still identical to the conffile md5 recorded by opkg at
#     package install time (untouched package placeholder) -> replace it;
#   - anything else is a user config -> never modified.
# Once replaced, the file differs from the recorded conffile md5, so future
# package upgrades preserve it exactly like a user config.
ensure_bootstrap_config() {
    _config="$1"

    mkdir -p "${_config%/*}" || err "Cannot create ${_config%/*} for required Mihomo bootstrap config"

    _replace=0
    if [ ! -f "$_config" ]; then
        _replace=1
    elif command -v md5sum >/dev/null 2>&1; then
        _pkg_md5=$(opkg status mihomo 2>/dev/null | awk -v cf="$_config" '$1 == cf {print $2}' | head -n 1)
        _file_md5=$(md5sum "$_config" 2>/dev/null | awk '{print $1}')
        if [ -n "$_pkg_md5" ] && [ "$_pkg_md5" = "$_file_md5" ]; then
            log "Untouched package placeholder detected, replacing with bootstrap"
            _replace=1
        fi
    fi

    if [ "$_replace" -eq 1 ]; then
        mp_known || err "Runtime UNKNOWN; bootstrap config not changed."
        log "Writing bootstrap config (mixed-port 7890)..."
        cat > "$_config" <<'EOF' || err "Failed to write required Mihomo bootstrap config"
# Bootstrap config installed by keenetic-auto-setup.
# mixed-port 7890 is the project contract port (Proxy0, watchdog, self-check);
# until it listens, Proxy0 and the watchdog tunnel check stay down.
# Replace this file with your real Mihomo config (docs/HOWTO, or build one at
# https://github.com/saymer-alt/link-generators), then:
#   /opt/etc/init.d/S99mihomo restart
mixed-port: 7890
EOF
        MIHOMO_RESTART_NEEDED=1
    else
        log "Existing Mihomo config left untouched"
    fi
}

ensure_bootstrap_config "/opt/etc/mihomo/config.yaml"

# ---------------------------
# PROJECT PROXY INTERFACE
# ---------------------------
# The project proxy is a Keenetic Proxy-class interface pointing at Mihomo's
# local SOCKS5 upstream (127.0.0.1:7890 — fixed project contract).
#
# Canonical new installs use all of:
#   description "mihomo t2sN"      (N = interface number; project convention)
#   proxy protocol socks5
#   proxy socks5-udp
#   proxy upstream 127.0.0.1 7890
#
# Legacy installers used other descriptions (for example "mihomo" or the
# platform/default ProxyN naming). Backward compatibility is therefore based
# on the functional bridge signature: SOCKS5 + socks5-udp + 127.0.0.1:7890.
# A compatible legacy ProxyN is reused exactly as found and is NEVER renamed.
# Preference order: canonical project ProxyN -> compatible legacy ProxyN ->
# create Proxy0 when absent -> otherwise create the first free ProxyN.
# Every Proxy decision reads ONE validated running-config snapshot
# (load_rc_dump; positive control: a real running-config always contains at
# least one `interface ` block). A failed or unconvincing ndmc read is
# UNKNOWN: nothing is created or modified, and UNKNOWN is never treated as
# NOT_FOUND — a transient ndmc error must not turn an occupied slot into a
# "free" one.
MAX_PROXY_PROBE=32   # Protective scan cap ONLY: KeeneticOS documents no limit
                     # for Proxy instances; the cap bounds ndmc probing cost
                     # in a pathological setup and is not an OS maximum.

load_rc_dump() {
    # One validated running-config snapshot (RC_DUMP) for every Proxy
    # decision. Two bounded attempts (an inline loop rather than retry():
    # retry() prints its WARN to stdout, which would pollute the captured
    # dump). The positive control separates a trustworthy NOT_FOUND from
    # an ndmc failure (UNKNOWN). Returns 1 only for UNKNOWN.
    _attempt=0
    while [ "$_attempt" -lt 2 ]; do
        RC_DUMP=$(ndmc -c "show running-config" 2>/dev/null | tr -d '\r')
        if printf '%s\n' "$RC_DUMP" | grep -q '^interface '; then
            return 0
        fi
        _attempt=$((_attempt + 1))
        if [ "$_attempt" -lt 2 ]; then
            sleep 2
        fi
    done
    RC_DUMP=""
    return 1
}

proxy_state() {
    # Classifies one interface against RC_DUMP: sets PROXY_STATE to FOUND
    # or NOT_FOUND. Must only be called after a successful load_rc_dump;
    # always returns 0 (callers branch on $PROXY_STATE, keeping bare calls
    # set -e-safe).
    if printf '%s\n' "$RC_DUMP" | grep -qx "interface $1"; then
        PROXY_STATE="FOUND"
    else
        PROXY_STATE="NOT_FOUND"
    fi
    return 0
}

proxy_profile_class() {
    # Classify one ProxyN block from the validated RC_DUMP snapshot.
    # Functional compatibility is the safety boundary for old installations:
    # SOCKS5 protocol + UDP support + the fixed local Mihomo endpoint. The
    # canonical description is metadata only and is never retrofitted.
    PROXY_PROFILE=$(printf '%s\n' "$RC_DUMP" | awk -v iface="$1" -v num="$2" '
        $0 == "interface " iface {pdesc=0; pproto=0; pudp=0; pup=0; inblk=1; next}
        inblk && /^!/ {
            if (pproto && pudp && pup) {
                if (pdesc) profile="canonical"; else profile="legacy"
            } else {
                profile="foreign"
            }
            inblk=0
            next
        }
        inblk && $0 ~ "^ *description \"?mihomo t2s" num "\"? *$" {pdesc=1}
        inblk && /^ *proxy protocol socks5 *$/ {pproto=1}
        inblk && /^ *proxy socks5-udp *$/ {pudp=1}
        inblk && /^ *proxy upstream 127\.0\.0\.1 7890 *$/ {pup=1}
        END {
            if (inblk) {
                if (pproto && pudp && pup) {
                    if (pdesc) profile="canonical"; else profile="legacy"
                } else {
                    profile="foreign"
                }
            }
            if (profile == "") profile="foreign"
            print profile
        }
    ')
}

proxy_is_compatible() {
    proxy_profile_class "$1" "$2"
    [ "$PROXY_PROFILE" = "canonical" ] || [ "$PROXY_PROFILE" = "legacy" ]
}

proxy_is_canonical() {
    proxy_profile_class "$1" "$2"
    [ "$PROXY_PROFILE" = "canonical" ]
}

create_project_proxy() {
    _iface="$1"
    _num="${_iface#Proxy}"
    # Every step is best-effort (the pre-function block relied on its
    # if-context for the same); the self-check reports any missed delivery.
    ndmc -c "interface ${_iface}" >/dev/null 2>&1 || true
    ndmc -c "interface ${_iface} proxy protocol socks5" >/dev/null 2>&1 || true
    ndmc -c "interface ${_iface} proxy socks5-udp" >/dev/null 2>&1 || true
    ndmc -c "interface ${_iface} proxy upstream 127.0.0.1 7890" >/dev/null 2>&1 || true
    ndmc -c "interface ${_iface} description \"mihomo t2s${_num}\"" >/dev/null 2>&1 || warn "Failed to set ${_iface} description"
    ndmc -c "interface ${_iface} ip global auto" >/dev/null 2>&1 || true
    ndmc -c "interface ${_iface} up" >/dev/null 2>&1 || true
    ndmc -c "system configuration save" >/dev/null 2>&1 || true
}

proxy_client_missing() {
    # Safety net after the early read-only component preflight: the component
    # was reported installed by show version, but the requested Proxy interface
    # still did not materialize. Fail before dependent mutations and avoid
    # misdiagnosing this as a simple missing-component case.
    _pi="$1"
    status_err "[ERROR] Не удалось создать проектный Proxy-интерфейс (${_pi}): он не появился в running-config после попытки создания."
    status_err "[ERROR] Ранний component preflight видел полный обязательный набор KeeneticOS, поэтому возможность Proxy* не применилась или состояние KeeneticOS изменилось после preflight."
    status_err "[ERROR] Проверьте, что компонент Proxy client по-прежнему установлен, и повторите запуск. Установщик сам компоненты KeeneticOS не устанавливает."
    exit 1
}

select_project_proxy() {
    PROXY_IFACE=""

    # The whole selection runs against one validated snapshot. If the
    # snapshot cannot be validated the Proxy state is UNKNOWN and nothing
    # is created or modified: empty PROXY_IFACE is the "no proxy" signal
    # for the callers, and the self-check reports the undetermined state.
    if ! load_rc_dump; then
        warn "Cannot validate running-config, Proxy state UNKNOWN — no Proxy created or modified"
        return 0
    fi

    # 1) Prefer an existing canonical project proxy. Remember the first
    # compatible legacy bridge while scanning, but do not let an old label
    # outrank a canonical interface that may exist at a higher ProxyN.
    _legacy_proxy=""
    _n=0
    while [ "$_n" -lt "$MAX_PROXY_PROBE" ]; do
        proxy_state "Proxy$_n"
        if [ "$PROXY_STATE" = "FOUND" ]; then
            proxy_profile_class "Proxy$_n" "$_n"
            case "$PROXY_PROFILE" in
                canonical)
                    PROXY_IFACE="Proxy$_n"
                    log "Using existing canonical project proxy ${PROXY_IFACE}"
                    return 0
                    ;;
                legacy)
                    [ -n "$_legacy_proxy" ] || _legacy_proxy="Proxy$_n"
                    ;;
            esac
        fi
        _n=$((_n+1))
    done

    # 2) No canonical proxy exists: reuse the first legacy-compatible bridge.
    if [ -n "$_legacy_proxy" ]; then
        PROXY_IFACE="$_legacy_proxy"
        log "Using legacy-compatible proxy ${PROXY_IFACE}: SOCKS5 UDP -> 127.0.0.1:7890; existing description preserved"
        return 0
    fi

    # 3) No compatible proxy exists: create Proxy0 when the slot is free.
    proxy_state "Proxy0"
    if [ "$PROXY_STATE" = "NOT_FOUND" ]; then
        log "Creating project proxy Proxy0..."
        create_project_proxy "Proxy0"
        PROXY_IFACE="Proxy0"
        # Refresh the snapshot and VERIFY the creation took effect: a
        # component-less KeeneticOS (no "Proxy client") silently rejects
        # every Proxy* write above, and the failure must not hide until the
        # self-check. On a reload failure the creation result is UNKNOWN:
        # nothing is bound or assumed, verification is left to the
        # self-check (safe direction, no mutation).
        if ! load_rc_dump; then
            warn "Cannot re-validate running-config after create - creation result UNKNOWN; verify the project proxy manually"
            return 0
        fi
        proxy_state "Proxy0"
        if [ "$PROXY_STATE" != "FOUND" ]; then
            proxy_client_missing "Proxy0"
        fi
        if ! proxy_is_canonical "Proxy0" "0"; then
            err "Proxy0 appeared in running-config but the required project profile (mihomo t2s0 / SOCKS5 upstream 127.0.0.1:7890) did not fully apply"
        fi
        log "Project proxy Proxy0 created and verified"
        return 0
    fi

    # 3) Proxy0 is foreign: leave it untouched, take the first free ProxyN.
    _n=1
    while [ "$_n" -lt "$MAX_PROXY_PROBE" ]; do
        proxy_state "Proxy$_n"
        if [ "$PROXY_STATE" = "NOT_FOUND" ]; then
            break
        fi
        _n=$((_n+1))
    done

    if [ "$_n" -ge "$MAX_PROXY_PROBE" ]; then
        warn "No free ProxyN within the ${MAX_PROXY_PROBE}-interface scan cap; existing proxy interfaces left untouched"
        # Empty PROXY_IFACE is the "no proxy" signal for the caller; the
        # function itself returns 0 so the bare top-level call stays
        # set -e-safe.
        return 0
    fi

    log "Proxy0 is not project-managed, creating project proxy Proxy${_n}..."
    create_project_proxy "Proxy${_n}"
    PROXY_IFACE="Proxy${_n}"
    # Same verification as in step 2: the new interface must be visible to
    # ensure_bypass_policy_exit, and its absence after the create is the
    # missing-Proxy-client signature (fail before the bypass_wa binding).
    if ! load_rc_dump; then
        warn "Cannot re-validate running-config after create - creation result UNKNOWN; verify the project proxy manually"
        return 0
    fi
    proxy_state "Proxy${_n}"
    if [ "$PROXY_STATE" != "FOUND" ]; then
        proxy_client_missing "Proxy${_n}"
    fi
    if ! proxy_is_canonical "Proxy${_n}" "$_n"; then
        err "Proxy${_n} appeared in running-config but the required project profile (mihomo t2s${_n} / SOCKS5 upstream 127.0.0.1:7890) did not fully apply"
    fi
    log "Project proxy Proxy${_n} created and verified"
}

select_project_proxy

# ---------------------------
# BYPASS_WA POLICY EXIT
# ---------------------------
# Keenetic routes traffic marked with a policy mark through the interfaces in
# that policy's permit list (permit global <iface>); an empty policy has no
# default route, so the VoIP bypass silently goes nowhere (docs/05). Add the
# selected project proxy (Proxy0 or a free ProxyN) to the bypass_wa permit
# list. Existing permits are never removed or reordered: if the policy
# already permits other interfaces (e.g. a VPN tunnel bound manually), they
# keep working and the route order remains the user's choice.
ensure_bypass_policy_exit() {
    _px="$1"

    if [ -z "$_px" ]; then
        warn "No project proxy selected, bypass_wa exit binding skipped"
        return 0
    fi
    _num="${_px#Proxy}"

    # Bind only a project-managed proxy interface. Both markers are checked
    # in the validated running-config snapshot: the upstream port is not
    # visible in "show interface". A foreign Proxy interface is never
    # modified and never used as the bypass_wa exit — the policy keeps
    # exactly the exits its owner configured.
    proxy_state "$_px"
    if [ "$PROXY_STATE" != "FOUND" ]; then
        warn "${_px} not available, bypass_wa exit binding skipped"
        return 0
    fi
    if ! proxy_is_compatible "$_px" "$_num"; then
        warn "Existing ${_px} is not a compatible Mihomo SOCKS5-UDP bridge to 127.0.0.1:7890, bypass_wa exit binding skipped"
        return 0
    fi

    # Find the policy block by its description (the policy NAME may differ,
    # e.g. Policy0 when created via web UI). Prints the policy name when it
    # lacks the project permit, "BOUND" when the permit already exists, and
    # nothing when no bypass_wa policy exists. Read from the same validated
    # snapshot that approved the ownership check, so both decisions see the
    # same configuration state. Running-config nests policy directives, so
    # a plain grep would false-positive on other policies' permit lists;
    # block state is evaluated when each block closes, not at END.
    _pol_state=$(printf '%s\n' "$RC_DUMP" | awk -v px="$_px" '
        /^ip policy / {if (inblk && pdesc && !ppermit) target=pname; if (inblk && pdesc && ppermit) bound=1; pname=$3; pdesc=0; ppermit=0; inblk=1; next}
        inblk && /^ *description bypass_wa *$/ {pdesc=1}
        inblk && $0 ~ "^ *permit global " px " *$" {ppermit=1}
        /^!/ {if (inblk && pdesc) {if (!ppermit) target=pname; else bound=1} inblk=0}
        END {if (inblk && pdesc) {if (!ppermit) target=pname; else bound=1}; if (target != "") print target; else if (bound) print "BOUND"}
    ')

    case "$_pol_state" in
        "")    warn "bypass_wa policy not found, exit binding skipped" ; return 0 ;;
        BOUND) log "bypass_wa policy exit already set" ; return 0 ;;
    esac

    if ndmc -c "ip policy ${_pol_state} permit global ${_px}" >/dev/null 2>&1; then
        log "bypass_wa policy bound to ${_px} (mihomo t2s${_num})"
        ndmc -c "system configuration save" >/dev/null 2>&1 || warn "Failed to save configuration"
    else
        warn "Failed to bind bypass_wa policy to ${_px}"
    fi
}

ensure_bypass_policy_exit "$PROXY_IFACE"

# ---------------------------
# MAGITRICKLE
# ---------------------------
# Keep running the upstream helper on every installer run so future feed-layout
# changes can still be applied. A second full opkg update is needed only when
# that helper actually changes the opkg repository configuration: otherwise the
# initial opkg update above has already refreshed the existing MagiTrickle feeds.
opkg_repo_snapshot() {
    for _opkg_conf in /opt/etc/opkg/*.conf; do
        [ -f "$_opkg_conf" ] || continue
        printf '%s\n' "### $_opkg_conf"
        cat "$_opkg_conf" 2>/dev/null || true
    done
}

MAGITRICKLE_REPO_BEFORE=$(opkg_repo_snapshot)

log "Ensuring MagiTrickle package repository..."
# The upstream helper prints an interactive "do not forget to install magitrickle"
# reminder. install.sh performs that step itself, so suppress helper stdout to avoid
# telling users to repeat an action that is already automated. Keep stderr visible.
rm -f "$MAGITRICKLE_REPO_STAGE" 2>/dev/null || true
if ! download_url_file "https://bin.magitrickle.dev/packages/add_repo.sh" "$MAGITRICKLE_REPO_STAGE"; then
    err "Failed to download MagiTrickle repository helper through curl/wget"
fi
if ! sh -n "$MAGITRICKLE_REPO_STAGE"; then
    err "Downloaded MagiTrickle repository helper failed shell syntax validation"
fi
if ! sh "$MAGITRICKLE_REPO_STAGE" >/dev/null; then
    err "Failed to add MagiTrickle package repository"
fi
rm -f "$MAGITRICKLE_REPO_STAGE" 2>/dev/null || true

MAGITRICKLE_REPO_AFTER=$(opkg_repo_snapshot)
if [ "$MAGITRICKLE_REPO_BEFORE" != "$MAGITRICKLE_REPO_AFTER" ]; then
    log "MagiTrickle repository configuration changed - refreshing package metadata..."
    retry opkg update || err "opkg update after changing the MagiTrickle repository failed"
else
    log "MagiTrickle repository configuration unchanged - initial opkg update already refreshed its metadata"
fi

log "Installing MagiTrickle package..."
pkg_ensure magitrickle

pkg_is_installed magitrickle || err "MagiTrickle package is not present after installation"
[ -x /opt/etc/init.d/S99magitrickle ] || err "MagiTrickle init script missing after installation"

log "Starting MagiTrickle..."
/opt/etc/init.d/S99magitrickle start || err "MagiTrickle start failed"
log "MagiTrickle installed and started"

# ---------------------------
# BYPASS RULES
# ---------------------------
log "Installing bypass rules..."

mkdir -p /opt/etc/ndm/netfilter.d

if project_script_download "020-bypass-wa.sh" "/opt/etc/ndm/netfilter.d/020-bypass_wa.sh"; then
    chmod +x /opt/etc/ndm/netfilter.d/020-bypass_wa.sh
else
    warn "bypass download failed after raw/curl, raw/wget and GitHub API fallbacks"
fi

# ---------------------------
# WATCHDOG
# ---------------------------
# Layout: the canonical watchdog lives at /opt/bin/mihomo_watchdog.sh;
# /opt/etc/cron.5mins/mihomo_watchdog is only a thin scheduler wrapper
# (exec). The installer installs the new layout on a clean router,
# accepts an existing new layout, and never touches legacy or unknown
# installations — update-watchdog.sh migrates; the installer installs
# and recognizes.
log "Installing watchdog..."

WATCHDOG_BIN="/opt/bin/mihomo_watchdog.sh"
WATCHDOG_CRON="/opt/etc/cron.5mins/mihomo_watchdog"
CRONTAB_FILE="/opt/etc/crontab"
WRAPPER_STAGE="/opt/etc/cron.5mins/.mihomo_watchdog.new.$$"
CRONTAB_STAGE="/opt/etc/.mihomo-crontab.new.$$"
CRON_CANDIDATE="/tmp/mihomo-crontab.new.$$"
BACKUP_STAGE="/opt/etc/.mihomo-watchdog-backup.new.$$"
# BEGIN WATCHDOG MANAGED FILES v1
# Shared by installer and updater, both under the existing lifecycle lock.
# Keenetic BusyBox stat does not provide GNU -c formatting.
wd_file_state() {
    local listing perms uid gid
    [ -f "$1" ] && [ ! -L "$1" ] || return 1
    listing=$(LC_ALL=C ls -ldn "$1" 2>/dev/null) || return 1
    set -- $listing
    [ "$#" -ge 4 ] || return 1
    perms="$1"; uid="$3"; gid="$4"
    printf '%s:%s:%s\n' "$uid" "$gid" "$perms"
}

wd_permissions() {
    local expected
    case "$2" in
        755) expected='-rwxr-xr-x' ;;
        600) expected='-rw-------' ;;
        *) return 1 ;;
    esac
    if [ "$(wd_file_state "$1")" != "0:0:$expected" ]; then
        chown 0:0 "$1" && chmod "$2" "$1" || return 1
    fi
    [ "$(wd_file_state "$1")" = "0:0:$expected" ]
}

wd_wrapper_install() {
    mkdir -p /opt/etc/cron.5mins || return 1
    [ ! -L "$WATCHDOG_CRON" ] || return 1
    if [ -f "$WATCHDOG_CRON" ] &&
       [ "$(cat "$WATCHDOG_CRON")" = "$(printf '#!/bin/sh\nexec /opt/bin/mihomo_watchdog.sh "$@"\n')" ]; then
        wd_permissions "$WATCHDOG_CRON" 755
        return $?
    fi
    (umask 077; printf '#!/bin/sh\nexec /opt/bin/mihomo_watchdog.sh "$@"\n' > "$WRAPPER_STAGE") || return 1
    sh -n "$WRAPPER_STAGE" && wd_permissions "$WRAPPER_STAGE" 755 || return 1
    mv -f "$WRAPPER_STAGE" "$WATCHDOG_CRON"
}

wd_normalize_cron() {
    # Only recognized five-minute project routes are normalized. Unknown active
    # references are preserved and require operator review; comments are inert.
    [ -f "$CRONTAB_FILE" ] && [ ! -L "$CRONTAB_FILE" ] || return 1
    if ! awk -v direct='*/5 * * * * root /bin/sh /opt/etc/cron.5mins/mihomo_watchdog' '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ {lines[++n]=$0; next}
    {
        line=$0; norm=$0; gsub(/^[ \t]+|[ \t]+$/, "", norm); gsub(/[ \t]+/, " ", norm)
        prefix="*/5 * * * * root "
        cmd=substr(norm,length(prefix)+1)
        if (substr(norm,1,length(prefix)) == prefix) {
            if (cmd == "run-parts /opt/etc/cron.5mins" || cmd == "/opt/bin/run-parts /opt/etc/cron.5mins") {
                if (!route) route=line
                next
            }
            if (cmd == "/bin/sh /opt/etc/cron.5mins/mihomo_watchdog" || cmd == "/opt/etc/cron.5mins/mihomo_watchdog" ||
                cmd == "/bin/sh /opt/bin/mihomo_watchdog.sh" || cmd == "/opt/bin/mihomo_watchdog.sh") next
        }
        if (index(norm,"mihomo_watchdog") || index(norm,"cron.5mins")) unknown=1
        lines[++n]=line
    }
    END {
        if (unknown) exit 2
        for (i=1;i<=n;i++) print lines[i]
        if (route) print route; else print direct
    }' "$CRONTAB_FILE" > "$CRON_CANDIDATE"; then
        return 1
    fi
    if cmp -s "$CRONTAB_FILE" "$CRON_CANDIDATE"; then
        rm -f "$CRON_CANDIDATE"
        return 0
    fi
    cp -p "$CRONTAB_FILE" "$CRONTAB_STAGE" &&
        cat "$CRON_CANDIDATE" > "$CRONTAB_STAGE" || return 1
    mv -f "$CRONTAB_STAGE" "$CRONTAB_FILE" || return 1
    rm -f "$CRON_CANDIDATE"
    if [ -x /opt/etc/init.d/S10cron ]; then /opt/etc/init.d/S10cron restart || return 1; fi
}
# END WATCHDOG MANAGED FILES v1


watchdog_is_canonical() {
    [ -f "$1" ] && grep -q "MIHOMO WATCHDOG SCRIPT" "$1" 2>/dev/null
}

install_watchdog_bin() {
    mkdir -p /opt/bin || return 1
    if ! project_script_download "mihomo-watchdog.sh" "$TMP_DIR/mihomo-watchdog.new"; then
        warn "Watchdog download failed after raw/curl, raw/wget and GitHub API fallbacks"
        return 1
    fi
    # Same watchdog-specific sanity marker as update-watchdog.sh; generic shell
    # syntax validation already ran inside project_script_download().
    if ! grep -q "MIHOMO WATCHDOG SCRIPT" "$TMP_DIR/mihomo-watchdog.new"; then
        warn "Watchdog sanity marker missing, not installed"
        return 1
    fi
    # Same-filesystem staging: copy the validated candidate next to its
    # destination, then commit with one atomic rename. The canonical
    # watchdog never passes through a partially copied state; a crash
    # mid-copy leaves only this updater's stage file, which the next
    # install.sh or update-watchdog.sh run removes.
    if ! cp -f "$TMP_DIR/mihomo-watchdog.new" "$WATCHDOG_STAGE"; then
        warn "Failed to stage the new watchdog at $WATCHDOG_STAGE"
        return 1
    fi
    wd_permissions "$WATCHDOG_STAGE" 755 || return 1
    if ! mv -f "$WATCHDOG_STAGE" "$WATCHDOG_BIN"; then
        warn "Failed to install $WATCHDOG_BIN"
        return 1
    fi
    return 0
}

ensure_watchdog_cron() {
    wd_wrapper_install || return 1
    mkdir -p /opt/var/log
    touch /opt/var/log/mihomo_watchdog.log
    chmod 666 /opt/var/log/mihomo_watchdog.log
    wd_normalize_cron || return 1
}

if watchdog_is_canonical "$WATCHDOG_BIN"; then
    wd_permissions "$WATCHDOG_BIN" 755 || err "Watchdog permissions need repair"
    # Canonical binary present: accept the new layout, keep one cron route.
    # A wrapper is recognized by its exec line, so a full watchdog that
    # merely mentions the canonical path in its header is not mistaken
    # for one.
    if [ -f "$WATCHDOG_CRON" ] && ! grep -q "^exec $WATCHDOG_BIN" "$WATCHDOG_CRON" 2>/dev/null; then
        warn "Unknown file at $WATCHDOG_CRON, left unchanged"
    elif [ -f "$WATCHDOG_CRON" ]; then
        wd_permissions "$WATCHDOG_BIN" 755 && wd_permissions "$WATCHDOG_CRON" 755 &&
            wd_normalize_cron || err "Watchdog permissions/schedule need repair"
        log "New watchdog layout already in place"
    else
        log "Canonical watchdog present, installing cron wrapper"
        ensure_watchdog_cron || warn "Watchdog cron wrapper installation failed"
    fi
elif watchdog_is_canonical "$WATCHDOG_CRON"; then
    # Old project layout (full watchdog in cron.5mins): not the installer's
    # job to migrate — the updater owns that transition.
    warn "Legacy watchdog installation detected."
    warn "Left unchanged."
    warn "Use update-watchdog.sh to migrate/update it safely."
elif [ -e "$WATCHDOG_BIN" ] || [ -e "$WATCHDOG_CRON" ]; then
    warn "Unrecognized watchdog installation, left unchanged"
else
    log "Installing canonical watchdog to $WATCHDOG_BIN"
    if install_watchdog_bin && ensure_watchdog_cron; then
        log "Watchdog installed (new layout)"
    else
        warn "Watchdog installation incomplete"
    fi
fi

# ---------------------------
# MIHOMO SERVICE STATE
# ---------------------------
# A repeat install with an unchanged Mihomo binary/config should be a true
# no-op for the running service. Restart only when this installer changed
# something Mihomo must reload. If the service is stopped, start it so the
# installer can still satisfy its working-stack contract.
mp_known || err "Runtime UNKNOWN; service action aborted."
MIHOMO_SERVICE_ACTION=none
if [ -x /opt/etc/init.d/S99mihomo ]; then
    if [ "$MIHOMO_RESTART_NEEDED" -eq 1 ]; then
        if mihomo_running; then
            log "Mihomo binary/config changed - restarting service"
            /opt/etc/init.d/S99mihomo restart || warn "Mihomo restart failed"
            MIHOMO_SERVICE_ACTION=restart
        else
            log "Mihomo binary/config changed and service is stopped - starting service"
            mp_stopped || err "Cannot prove stop before service start."
            /opt/etc/init.d/S99mihomo start || warn "Mihomo start failed"
            MIHOMO_SERVICE_ACTION=start
        fi
    elif mihomo_running; then
        log "Mihomo binary/config unchanged and daemon is running - restart skipped"
    else
        log "Mihomo binary/config unchanged but daemon is stopped - starting service"
        mp_stopped || err "Cannot prove stop before service start."
        /opt/etc/init.d/S99mihomo start || warn "Mihomo start failed"
        MIHOMO_SERVICE_ACTION=start
    fi
else
    warn "S99mihomo not found, cannot manage Mihomo service"
fi

if [ "$MIHOMO_SERVICE_ACTION" != "none" ]; then
    sleep 2
    mp_running || err "Mihomo start/restart could not be confirmed."
fi

# ---------------------------
# POST-INSTALL SELF-CHECK
# ---------------------------
# Validates what this installer promises to install. install.sh leaves a
# bootstrap config.yaml (mixed-port 7890) in place unless a user config
# already exists. Missing config.yaml means bootstrap creation failed — FAIL.
# Port 7890 is checked whenever a config exists: the bootstrap must
# listen on 7890, so a miss here means Mihomo is not running properly (or a
# user config does not define the contract port) — never a package
# placeholder, which install.sh replaces.
FAILS=0
WARNS=0

check_ok()   { status_out "$COLOR_GREEN" "[ok] $1"; }
check_warn() { status_out "$COLOR_YELLOW" "[WARN] $1"; WARNS=$((WARNS+1)); }
check_fail() { status_out "$COLOR_RED" "[FAIL] $1"; FAILS=$((FAILS+1)); }
check_info() { status_out "$COLOR_CYAN" "[info] $1"; }

# One-Mihomo invariant: executable self-check probes reuse the conservative
# mihomo_running() guard defined before the Mihomo install section.

mihomo_contract_port_listening() {
    if command -v netstat >/dev/null 2>&1; then
        netstat -tln 2>/dev/null | grep -q 7890
        return $?
    fi
    if command -v ss >/dev/null 2>&1; then
        ss -tln 2>/dev/null | grep -q 7890
        return $?
    fi
    return 2
}

wait_for_mihomo_contract_port() {
    # Some constrained routers (observed on KN-1010 / MT7621) return from the
    # init-script start before Mihomo has opened its listening socket. Check
    # immediately, then allow up to five seconds for the contract port to
    # appear. Fast devices pay no delay.
    _wp_try=0
    while [ "$_wp_try" -le 5 ]; do
        if mihomo_contract_port_listening; then
            return 0
        else
            _wp_rc=$?
        fi
        [ "$_wp_rc" -eq 2 ] && return 2
        [ "$_wp_try" -eq 5 ] && break
        _wp_try=$((_wp_try + 1))
        sleep 1
    done
    return 1
}

CONFIG="/opt/etc/mihomo/config.yaml"

# Mihomo binary + version
MIHOMO_BIN=$(resolve_installed_mihomo 2>/dev/null || true)
if [ -n "$MIHOMO_BIN" ]; then
    if ! mp_stopped; then
        check_info "Mihomo daemon is running or unknown - binary probe (-v) skipped (one-Mihomo invariant); runtime execution is not verified by this probe"
    elif MIHOMO_VERSION_OUTPUT=$("$MIHOMO_BIN" -v 2>/dev/null); then
        check_ok "Mihomo binary: $(printf '%s\n' "$MIHOMO_VERSION_OUTPUT" | head -1)"
    else
        check_fail "Mihomo binary exists but 'mihomo -v' failed"
    fi
else
    check_fail "Mihomo binary not found (/opt/sbin/mihomo or /opt/bin/mihomo)"
fi

# Mihomo init script
if [ -x /opt/etc/init.d/S99mihomo ]; then
    check_ok "Mihomo init script present"
else
    check_fail "Mihomo init script /opt/etc/init.d/S99mihomo missing"
fi

# Project proxy — canonical or legacy-compatible ProxyN. Compatibility is
# verified against a freshly validated running-config snapshot by SOCKS5 +
# socks5-udp + 127.0.0.1:7890. Legacy descriptions are informational only and
# are never rewritten. An ndmc failure here is UNKNOWN: reported as FAIL.
if [ -z "$PROXY_IFACE" ]; then
    check_fail "No project proxy (ndmc read failed during selection, or no free ProxyN with foreign Proxy0)"
elif ! load_rc_dump; then
    check_fail "Proxy state cannot be determined (running-config read failed)"
else
    proxy_state "$PROXY_IFACE"
    if [ "$PROXY_STATE" = "FOUND" ]; then
        proxy_profile_class "$PROXY_IFACE" "${PROXY_IFACE#Proxy}"
        case "$PROXY_PROFILE" in
            canonical)
                check_ok "Project proxy ${PROXY_IFACE}: canonical mihomo t2s${PROXY_IFACE#Proxy}, SOCKS5 UDP -> 127.0.0.1:7890"
                ;;
            legacy)
                check_ok "Project proxy ${PROXY_IFACE}: legacy-compatible SOCKS5 UDP -> 127.0.0.1:7890"
                check_info "Legacy Proxy description preserved as-is; rename to mihomo t2s${PROXY_IFACE#Proxy} is not required"
                ;;
            *)
                check_fail "Project proxy ${PROXY_IFACE} does not match the compatible SOCKS5-UDP 127.0.0.1:7890 profile"
                ;;
        esac
    else
        check_fail "Project proxy ${PROXY_IFACE} is missing"
    fi
fi

# DNS transit interception
if ndmc -c "show running-config" 2>/dev/null | grep -q "intercept enable"; then
    check_ok "DNS transit interception enabled"
else
    check_fail "DNS transit interception (dns-proxy intercept enable) not found"
fi

# Bypass rules
if [ -x /opt/etc/ndm/netfilter.d/020-bypass_wa.sh ]; then
    check_ok "bypass rules: 020-bypass_wa.sh present"
else
    check_fail "bypass rules: /opt/etc/ndm/netfilter.d/020-bypass_wa.sh missing or not executable"
fi

# bypass_wa policy exit: report specifically whether the selected project
# proxy is permitted; other permits (e.g. a manually bound VPN) are fine and
# preserved
_bp_state=$(ndmc -c "show running-config" 2>/dev/null | awk -v px="${PROXY_IFACE:-__none__}" '
    /^ip policy / {pdesc=0; ppermit=0; pother=0; inblk=1; next}
    inblk && /^ *description bypass_wa *$/ {pdesc=1}
    inblk && $0 ~ "^ *permit global " px " *$" {ppermit=1}
    inblk && /^ *permit global [A-Za-z0-9_-]+ *$/ {pother=1}
    /^!/ {if (inblk && pdesc) {if (ppermit) st="bound"; else if (pother) st="other"} inblk=0}
    END {if (inblk && pdesc) {if (ppermit) st="bound"; else if (pother) st="other"}; print st""}
')
case "$_bp_state" in
    bound) check_ok "bypass_wa policy has permit global ${PROXY_IFACE}" ;;
    other) check_warn "bypass_wa policy has interface permits but not ${PROXY_IFACE:-the project proxy} — VoIP exit is not the project proxy" ;;
    *)     check_warn "bypass_wa policy missing or has no interface permit — VoIP bypass has no exit route" ;;
esac

# Watchdog: canonical binary + cron wrapper (or a legacy layout we left alone)
if watchdog_is_canonical "$WATCHDOG_BIN"; then
    check_ok "watchdog canonical present ($WATCHDOG_BIN)"
    if [ -x "$WATCHDOG_CRON" ] && grep -q "^exec $WATCHDOG_BIN" "$WATCHDOG_CRON" 2>/dev/null; then
        check_ok "watchdog cron wrapper present"
    else
        check_fail "watchdog cron wrapper missing or does not point at $WATCHDOG_BIN"
    fi
elif watchdog_is_canonical "$WATCHDOG_CRON"; then
    check_warn "Legacy watchdog layout (full script in cron.5mins) — left unchanged, update-watchdog.sh migrates"
else
    check_fail "watchdog not installed (neither $WATCHDOG_BIN nor legacy cron layout found)"
fi
if grep -q "cron.5mins" /opt/etc/crontab 2>/dev/null || grep -q "mihomo_watchdog" /opt/etc/crontab 2>/dev/null; then
    check_ok "watchdog scheduled in crontab"
else
    check_fail "watchdog not scheduled (no cron.5mins/mihomo_watchdog entry in /opt/etc/crontab)"
fi

# Cron
if [ -x /opt/etc/init.d/S10cron ]; then
    check_ok "cron init script present"
    if ps 2>/dev/null | grep -q "[c]ron"; then
        check_ok "cron is running"
    else
        check_warn "cron process not visible in ps (init script present)"
    fi
else
    check_fail "cron init script /opt/etc/init.d/S10cron missing"
fi

# MagiTrickle
if opkg list-installed 2>/dev/null | grep -q "^magitrickle "; then
    check_ok "MagiTrickle installed"
    if [ -x /opt/etc/init.d/S99magitrickle ]; then
        check_ok "MagiTrickle init script present"
    else
        check_warn "MagiTrickle init script /opt/etc/init.d/S99magitrickle missing"
    fi
else
    check_fail "MagiTrickle package not installed"
fi

# S00ubifs (ram mode only)
if [ "$MODE" = "ram" ]; then
    if [ -x /opt/etc/init.d/S00ubifs ]; then
        check_ok "S00ubifs present (ram mode)"
    else
        check_fail "S00ubifs missing (ram mode)"
    fi
fi

# Config.yaml: the bootstrap (mixed-port 7890) should always be present;
# port 7890 is checked whenever a config exists.
if [ -f "$CONFIG" ]; then
    if ! mp_stopped; then
        check_info "Mihomo config syntax check skipped - the daemon is running or unknown and 'mihomo -t' would execute a second Mihomo (one-Mihomo invariant); this probe does not verify the running config"
    elif ${MIHOMO_BIN} -t -d /opt/etc/mihomo -f "$CONFIG" >/dev/null 2>&1; then
        check_ok "Mihomo config syntax valid"
    else
        check_warn "Mihomo config syntax check (mihomo -t) failed"
    fi
    if wait_for_mihomo_contract_port; then
        check_ok "Port 7890 listening"
    else
        _wp_result=$?
        if [ "$_wp_result" -eq 2 ]; then
            check_info "Port 7890 listener check skipped — neither netstat nor ss is available"
        else
            check_warn "Port 7890 still not listening after 5s startup wait — verify Mihomo startup/config/logs"
        fi
    fi
else
    check_fail "config.yaml not found (required bootstrap missing) — project ProxyN cannot reach Mihomo on 7890"
fi

# Mihomo endpoint distinction (read-only): the project ProxyN upstream needs
# a SOCKS5/Mixed endpoint on 7890. A user config exposing only transparent
# proxy ports (tproxy/redir) cannot feed ProxyN; the installer never
# modifies the user config — reported so the gap is visible immediately.
if [ -f "$CONFIG" ] &&    grep -qE '^[[:space:]]*(tproxy-port|redir-port):' "$CONFIG" &&    ! grep -qE '^[[:space:]]*(mixed-port|socks-port|port):' "$CONFIG"; then
    check_warn "config.yaml defines only transparent-proxy ports (tproxy/redir) and no SOCKS5/Mixed endpoint — the project ProxyN upstream (127.0.0.1:7890) needs one, e.g. 'mixed-port: 7890' (user config is never modified by the installer)"
fi

# Free-space / update-staging headroom on /opt.
# Use the same model as update-mihomo.sh: current binary size + 4 MB margin.
# This avoids a fixed absolute threshold that is noisy on small internal
# Entware filesystems while still surfacing a real inability to stage an update.
AVAIL_KB=$(df -k /opt 2>/dev/null | awk 'NR==2 {print $4}')
BIN_SIZE_BYTES=$(wc -c < "$MIHOMO_BIN" 2>/dev/null || true)
_SPACE_VALID=1
case "$AVAIL_KB" in ''|*[!0-9]*) _SPACE_VALID=0 ;; esac
case "$BIN_SIZE_BYTES" in ''|*[!0-9]*) _SPACE_VALID=0 ;; esac
if [ "$_SPACE_VALID" -ne 1 ]; then
    check_info "Mihomo update staging headroom on /opt: cannot determine"
else
    BIN_SIZE_KB=$(( (BIN_SIZE_BYTES + 1023) / 1024 ))
    STAGE_NEED_KB=$((BIN_SIZE_KB + MIHOMO_STAGE_MARGIN_KB))
    if [ "$AVAIL_KB" -lt "$STAGE_NEED_KB" ]; then
        check_warn "Mihomo update staging headroom is insufficient on /opt: ${AVAIL_KB} KB available, current-binary estimate needs ~${STAGE_NEED_KB} KB (${BIN_SIZE_KB} KB binary + ${MIHOMO_STAGE_MARGIN_KB} KB margin)"
    else
        check_ok "Mihomo update staging headroom on /opt: ${AVAIL_KB} KB available; current-binary estimate needs ~${STAGE_NEED_KB} KB"
    fi
fi

# Verdict
if [ "$FAILS" -gt 0 ]; then
    status_out "$COLOR_RED" "[FAIL] $FAILS check(s) failed, $WARNS warning(s) — installation incomplete"
    exit 1
fi
if [ "$WARNS" -gt 0 ]; then
    status_out "$COLOR_GREEN" "[OK] Done ($WARNS warning(s))"
else
    status_out "$COLOR_GREEN" "[OK] Done"
fi
