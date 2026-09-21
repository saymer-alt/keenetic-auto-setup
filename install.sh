#!/bin/sh

set -e

echo "=== Keenetic Auto Setup ==="

MODE="${1:-ram}"

if [ "$MODE" != "ram" ] && [ "$MODE" != "disk" ]; then
    echo "Usage: sh install.sh [ram|disk]"
    exit 1
fi

echo "[*] Mode: $MODE"

TMP_DIR="/tmp"

log() { echo "[setup] $1"; }
warn() { echo "[WARN] $1"; }
err() { echo "[ERROR] $1"; exit 1; }

retry() {
    for i in 1 2 3; do
        "$@" && return 0
        warn "Retry $i/3 failed for: $*"
        sleep 2
    done
    return 1
}

# Cleanup temp files on any exit
WATCHDOG_STAGE="/opt/bin/.mihomo_watchdog.sh.new.$$"
# Cleanup temp files on any exit (the watchdog stage lives on /opt,
# next to its final destination - a /tmp -> /opt move is not atomic
# and must never be claimed as such)
trap 'rm -f "$TMP_DIR/mihomo.ipk" "$TMP_DIR/mihomo-watchdog.new" "$WATCHDOG_STAGE"' EXIT INT TERM HUP

# ---------------------------
# CHECK BASE
# ---------------------------
command -v opkg >/dev/null 2>&1 || err "opkg not found"

# ---------------------------
# RAM / STORAGE / SWAP PREFLIGHT
# ---------------------------
# Memory capacity, /opt location and swap backends are detected from live
# system state - never guessed. Resource-profile contract 20260921_1:
#   - 128 MB-class: best-effort/experimental. Installation is REFUSED unless
#     /opt is on verified EXTERNAL persistent storage AND EXTERNAL
#     storage-backed active swap is >= 384 MB. This is a project-specific
#     experimental floor, not a vendor-stated minimum. zRAM never satisfies it.
#   - 256 MB-class: project expects at least ONE active memory-pressure backend:
#     native KeeneticOS zRAM OR verified EXTERNAL storage-backed swap. Absence
#     is a WARN (installation continues), not a hard gate.
#   - 512 MB-class: same project expectation; no backend => WARN and continue.
#   - Above the 512 MB class: swap/zRAM is optional.
#   - If external swap is chosen on <=512 MB-class, project target size is
#     3x detected RAM, capped at 2 GiB. Below target => WARN, not a hard gate.
#     Current vendor docs say ~500 MB is enough for most tasks and that usually
#     more than 3x RAM is unnecessary; therefore 3x is PROJECT POLICY, not a
#     vendor minimum.
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
RESOURCE_PROFILE_CONTRACT_VERSION=20260921_2
RAM128_MAX_KB=200000      # below this total RAM = 128 MB-class
RAM256_MAX_KB=450000      # below this total RAM = 256 MB-class
RAM512_MAX_KB=786432      # below this total RAM = 512 MB-class (real ~486 MB MemTotal fits here)
SWAP128_MIN_KB=393216     # project-specific 384 MB hard floor for experimental 128 MB profile
SWAP_MAX_KB=2097152       # 2 GiB project/vendor cap for external storage-backed swap
SYS_CLASS_BLOCK="${INSTALL_SYS_CLASS_BLOCK:-/sys/class/block}"
PROC_MOUNTS="${INSTALL_MOUNTS:-/proc/mounts}"
PROC_SWAPS="${INSTALL_SWAPS:-/proc/swaps}"

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
            *zram*) SW_ZRAM_KB=$((SW_ZRAM_KB + _sw_size)); continue ;;
        esac
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

MEM_TOTAL_KB=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)
SWAP_TOTAL_KB=$(awk '/^SwapTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)
SWAP_TARGET_KB=0
case "$MEM_TOTAL_KB" in
    ''|*[!0-9]*) : ;;
    *)
        SWAP_TARGET_KB=$((MEM_TOTAL_KB * 3))
        [ "$SWAP_TARGET_KB" -gt "$SWAP_MAX_KB" ] && SWAP_TARGET_KB=$SWAP_MAX_KB
        ;;
esac
OPT_CLASS=$(opt_storage_class /opt)
scan_swap_backends
case "$OPT_CLASS" in
    internal) log "/opt: internal Keenetic storage" ;;
    external) log "/opt: external persistent storage" ;;
    ram)      log "/opt: RAM-backed (tmpfs/ramfs) - not persistent" ;;
    *)        log "/opt: storage class cannot be determined (unrecognized mount state)" ;;
esac
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
                warn "256 MB-class device (${MEM_TOTAL_MB} MB): cannot read $PROC_SWAPS, so zRAM/external-SWAP presence cannot be verified. Project policy expects one active backend on <=512 MB-class, but installation continues."
            elif [ "$SW_ZRAM_KB" -gt 0 ]; then
                log "256 MB-class with active zRAM - supported project profile"
            elif [ "$SW_EXT_KB" -gt 0 ]; then
                log "256 MB-class with external storage-backed swap ($((SW_EXT_KB / 1024)) MB) and zRAM off"
                if [ "$SWAP_TARGET_KB" -gt 0 ] && [ "$SW_EXT_KB" -lt "$SWAP_TARGET_KB" ]; then
                    warn "External SWAP is below the project sizing target: $((SW_EXT_KB / 1024)) MB active, target about $((SWAP_TARGET_KB / 1024)) MB (3x detected RAM, capped at 2048 MB). This target is project policy, not a vendor minimum."
                fi
            else
                warn "256 MB-class device (${MEM_TOTAL_MB} MB) has neither active zRAM nor verified external storage-backed SWAP. Project policy expects one backend on <=512 MB-class; installation continues, but memory-pressure stability is not guaranteed."
            fi
        elif [ "$MEM_TOTAL_KB" -lt "$RAM512_MAX_KB" ]; then
            if [ "$SW_ZRAM_KB" -gt 0 ]; then
                log "512 MB-class with active zRAM - supported project profile"
            elif [ "$SW_EXT_KB" -gt 0 ]; then
                log "512 MB-class with external storage-backed swap ($((SW_EXT_KB / 1024)) MB) and zRAM off"
                if [ "$SWAP_TARGET_KB" -gt 0 ] && [ "$SW_EXT_KB" -lt "$SWAP_TARGET_KB" ]; then
                    warn "External SWAP is below the project sizing target: $((SW_EXT_KB / 1024)) MB active, target about $((SWAP_TARGET_KB / 1024)) MB (3x detected RAM, capped at 2048 MB). This target is project policy, not a vendor minimum."
                fi
            else
                warn "512 MB-class device (${MEM_TOTAL_MB} MB) has neither active zRAM nor verified external storage-backed SWAP. Project policy expects one backend on <=512 MB-class; installation continues, but memory-pressure stability is not guaranteed."
            fi
        else
            log "Above-512 MB memory class (${MEM_TOTAL_MB} MB): swap/zRAM is optional"
        fi
        ;;
esac

# ---------------------------
# REQUIRED KEENETICOS COMPONENT PREFLIGHT
# ---------------------------
# Current default project install depends on three named KeeneticOS components:
#   proxy                -> Proxy client / Клиент прокси
#   dns-filter           -> Cloud-based content filtering and ad blocking
#   opkg-kmod-netfilter  -> Kernel modules for Netfilter
# Open Package support itself is verified earlier by command -v opkg.
# Read the component set from "show version" and fail BEFORE installer-managed
# opkg update, package installation, or persistent router configuration changes.
PROXY_COMPONENT_ID=proxy
DNS_FILTER_COMPONENT_ID=dns-filter
NETFILTER_COMPONENT_ID=opkg-kmod-netfilter

component_list_has() {
    _clh_id="$1"
    printf '%s\n' "$KEENETIC_VERSION_DUMP" | grep -Eq "(^|[,:[:space:]])${_clh_id}([,[:space:]]|$)"
}

required_components_preflight_error() {
    _rc_reason="$1"
    echo "[ERROR] $_rc_reason" >&2
    echo "[ERROR] Full required component contract for the current default project profile:" >&2
    echo "[ERROR]   - Proxy client / Клиент прокси (component id: ${PROXY_COMPONENT_ID}) — provides ProxyN -> Mihomo." >&2
    echo "[ERROR]   - Cloud-based content filtering and ad blocking / Фильтрация контента и блокировка рекламы при помощи облачных сервисов (component id: ${DNS_FILTER_COMPONENT_ID}) — provides the DNS-filter/interception component family required by the supported dns-proxy intercept profile." >&2
    echo "[ERROR]   - Kernel modules for Netfilter / Модули ядра подсистемы Netfilter (component id: ${NETFILTER_COMPONENT_ID}) — required by the project 020-bypass_wa.sh VoIP bypass path." >&2
    echo "[ERROR] Enable the missing component(s) manually in KeeneticOS -> General system settings / Общие настройки системы -> KeeneticOS update and components / Обновление и компоненты KeeneticOS -> Change component set / Изменить набор компонентов." >&2
    echo "[ERROR] The installer does not install KeeneticOS components. No project components or router settings have been changed; stopping before installer-managed opkg update and project package installation." >&2
    exit 1
}

require_project_keeneticos_components() {
    log "Checking required KeeneticOS components"
    command -v ndmc >/dev/null 2>&1 ||
        required_components_preflight_error "Cannot verify KeeneticOS components because ndmc is not available."

    KEENETIC_VERSION_DUMP=$(ndmc -c "show version" 2>/dev/null || true)
    [ -n "$KEENETIC_VERSION_DUMP" ] ||
        required_components_preflight_error "Cannot read 'show version'; required component state is UNKNOWN."

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

    if [ "$_rc_missing_count" -gt 0 ]; then
        echo "[ERROR] Missing required KeeneticOS component(s):" >&2
        printf '%s\n' "${_rc_missing_lines#?}" >&2
        required_components_preflight_error "Install the component(s) listed above before continuing."
    fi

    log "Required KeeneticOS components present: ${PROXY_COMPONENT_ID}, ${DNS_FILTER_COMPONENT_ID}, ${NETFILTER_COMPONENT_ID}"
}

require_project_keeneticos_components
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

    if retry curl -fsSL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/S00ubifs \
        -o /opt/etc/init.d/S00ubifs; then

        chmod +x /opt/etc/init.d/S00ubifs
        /opt/etc/init.d/S00ubifs start || warn "S00ubifs start failed"
    else
        warn "S00ubifs download failed"
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
log "Installing Mihomo..."

REPO_OWNER="saymer-alt"
REPO_NAME="entware-go"

case "$ARCH" in
    aarch64*) IPK_SUFFIX="aarch64-3.10" ;;
    armv7*|arm*) IPK_SUFFIX="armv7-3.2" ;;
    mipsel*) IPK_SUFFIX="mipsel-3.4" ;;
    mips*) IPK_SUFFIX="mips-3.4" ;;
    *) err "Unsupported arch: $ARCH" ;;
esac

log "Looking for mihomo ipk (${IPK_SUFFIX}) in ${REPO_OWNER}/${REPO_NAME}..."

API_URL="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
ASSETS_JSON=$(retry curl -fsSL "$API_URL" 2>/dev/null) || ASSETS_JSON=""

DOWNLOAD_URL=""

# Primary: GitHub API + jq (без regex)
if [ -n "$ASSETS_JSON" ]; then
    DOWNLOAD_URL=$(echo "$ASSETS_JSON" | jq -r --arg suffix "$IPK_SUFFIX" '
        .assets[]? 
        | select(.name | startswith("mihomo_") and endswith("_" + $suffix + ".ipk")) 
        | .browser_download_url
    ' 2>/dev/null | head -n 1)
fi

# Fallback 1: grep/sed на API JSON
if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ]; then
    log "jq filter empty, trying grep fallback on API response..."
    if [ -n "$ASSETS_JSON" ]; then
        DOWNLOAD_URL=$(echo "$ASSETS_JSON" | grep -o '"browser_download_url": *"[^"]*mihomo_[^"]*_'${IPK_SUFFIX}'\.ipk"' | head -1 | sed 's/.*": *"//;s/"$//')
    fi
fi

# Fallback 2: повторный API fetch + grep (если первый был пустым)
if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ]; then
    log "API failed, trying direct API grep..."
    ASSETS_JSON=$(curl -fsSL "$API_URL" 2>/dev/null) || ASSETS_JSON=""
    if [ -n "$ASSETS_JSON" ]; then
        DOWNLOAD_URL=$(echo "$ASSETS_JSON" | grep -o '"browser_download_url": *"[^"]*mihomo_[^"]*_'${IPK_SUFFIX}'\.ipk"' | head -1 | sed 's/.*": *"//;s/"$//')
    fi
fi

# Fallback 3: HTML scraping
if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ]; then
    log "Trying HTML scraping..."
    HTML_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest"
    REL_PATH=$(curl -fsSL "$HTML_URL" 2>/dev/null | \
        grep -oE 'href="[^"]*releases/download/[^"]*mihomo_[^"]*_'${IPK_SUFFIX}'\.ipk"' | \
        head -n 1 | cut -d'"' -f2)
    if [ -n "$REL_PATH" ]; then
        DOWNLOAD_URL="https://github.com${REL_PATH}"
    fi
fi

# GitHub Releases (saymer-alt/entware-go) are the PRIMARY package source;
# the Entware feed install below is a LAST RESORT, not an equal alternative.
MIHOMO_INSTALLED=0

if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ]; then
    warn "No mihomo ipk found for arch suffix: ${IPK_SUFFIX}. Check https://github.com/${REPO_OWNER}/${REPO_NAME}/releases"
else
    log "Found: $(basename "$DOWNLOAD_URL")"
    log "Downloading..."
    if retry curl -fL "$DOWNLOAD_URL" -o "$TMP_DIR/mihomo.ipk"; then
        log "Installing package..."
        if opkg install "$TMP_DIR/mihomo.ipk"; then
            MIHOMO_INSTALLED=1
        else
            warn "Mihomo install from the downloaded GitHub package failed"
        fi
    else
        warn "Failed to download mihomo ipk"
    fi
fi

# Timely cleanup after the GitHub attempt (the EXIT trap is only a backstop):
# a failed attempt must not leave a partial ipk in /tmp.
rm -f "$TMP_DIR/mihomo.ipk"

# LAST RESORT: package `mihomo` from the configured Entware feed. Reached
# only after the whole GitHub path failed before a successful install; the
# feed version may be older than the GitHub release build.
if [ "$MIHOMO_INSTALLED" -eq 0 ]; then
    warn "GitHub Mihomo package unavailable, trying Entware feed fallback..."
    opkg install mihomo || err "Mihomo install failed: GitHub package unavailable and Entware feed fallback failed"
    log "Mihomo installed from Entware feed fallback (version may be older than the GitHub release build)"
fi

MIHOMO_BIN=$(command -v mihomo 2>/dev/null || echo "/opt/bin/mihomo")
log "Mihomo version: $(${MIHOMO_BIN} -v 2>/dev/null | head -1 || echo "unknown")"

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
    else
        log "Existing Mihomo config left untouched"
    fi
}

ensure_bootstrap_config "/opt/etc/mihomo/config.yaml"

# ---------------------------
# PROJECT PROXY INTERFACE
# ---------------------------
# The project proxy is a Keenetic Proxy-class interface pointing at Mihomo's
# local SOCKS5 upstream (127.0.0.1:7890 — fixed project contract). It is
# identified by BOTH markers in running-config:
#   description "mihomo t2sN"      (N = interface number; project convention)
#   proxy upstream 127.0.0.1 7890
# A Proxy interface matching only one marker (or neither) is foreign and is
# never modified. Preference order: reuse an existing project ProxyN (lowest
# number first); otherwise create Proxy0 when absent; otherwise — Proxy0 is
# foreign — create the first free ProxyN and leave Proxy0 exactly as is.
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

proxy_is_project() {
    # Ownership check against the validated RC_DUMP snapshot: BOTH project
    # markers must sit in the same interface block.
    printf '%s\n' "$RC_DUMP" | awk -v iface="$1" -v num="$2" '
        $0 == "interface " iface {pdesc=0; pup=0; inblk=1; next}
        inblk && /^!/ {if (pdesc && pup) found=1; inblk=0; next}
        inblk && $0 ~ "^ *description \"?mihomo t2s" num "\"? *$" {pdesc=1}
        inblk && /^ *proxy upstream 127\.0\.0\.1 7890 *$/ {pup=1}
        END {if (inblk && pdesc && pup) found=1; exit !found}
    '
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
    echo "[ERROR] Не удалось создать проектный Proxy-интерфейс (${_pi}): он не появился в running-config после попытки создания." >&2
    echo "[ERROR] Ранний component preflight видел полный обязательный набор KeeneticOS, поэтому возможность Proxy* не применилась или состояние KeeneticOS изменилось после preflight." >&2
    echo "[ERROR] Проверьте, что компонент Proxy client по-прежнему установлен, и повторите запуск. Установщик сам компоненты KeeneticOS не устанавливает." >&2
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

    # 1) Reuse an existing project proxy (lowest number first).
    _n=0
    while [ "$_n" -lt "$MAX_PROXY_PROBE" ]; do
        proxy_state "Proxy$_n"
        if [ "$PROXY_STATE" = "FOUND" ] && proxy_is_project "Proxy$_n" "$_n"; then
            PROXY_IFACE="Proxy$_n"
            log "Using existing project proxy ${PROXY_IFACE}"
            return 0
        fi
        _n=$((_n+1))
    done

    # 2) No project proxy exists: create Proxy0 when the slot is free.
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
        if ! proxy_is_project "Proxy0" "0"; then
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
    if ! proxy_is_project "Proxy${_n}" "$_n"; then
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
    if ! proxy_is_project "$_px" "$_num"; then
        warn "Existing ${_px} does not match the project profile (mihomo t2s${_num} / 127.0.0.1:7890), bypass_wa exit binding skipped"
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
log "Adding MagiTrickle package repository..."
# The upstream helper prints an interactive "do not forget to install magitrickle"
# reminder. install.sh performs that step itself, so suppress helper stdout to avoid
# telling users to repeat an action that is already automated. Keep stderr visible.
if curl -fsSL https://bin.magitrickle.dev/packages/add_repo.sh 2>/dev/null | sh >/dev/null; then
    :
elif wget -qO- https://bin.magitrickle.dev/packages/add_repo.sh | sh >/dev/null; then
    :
else
    err "Failed to add MagiTrickle package repository"
fi

log "Refreshing package metadata for MagiTrickle..."
opkg update || err "opkg update after adding the MagiTrickle repository failed"

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

if retry curl -fsSL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/020-bypass-wa.sh \
    -o /opt/etc/ndm/netfilter.d/020-bypass_wa.sh; then

    chmod +x /opt/etc/ndm/netfilter.d/020-bypass_wa.sh
else
    warn "bypass download failed"
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
WATCHDOG_URL="https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo-watchdog.sh"

watchdog_is_canonical() {
    [ -f "$1" ] && grep -q "MIHOMO WATCHDOG SCRIPT" "$1" 2>/dev/null
}

install_watchdog_bin() {
    mkdir -p /opt/bin || return 1
    if ! retry curl -fsSL "$WATCHDOG_URL" -o "$TMP_DIR/mihomo-watchdog.new"; then
        warn "Watchdog download failed"
        return 1
    fi
    # Same sanity gates as update-watchdog.sh: marker + syntax.
    if ! grep -q "MIHOMO WATCHDOG SCRIPT" "$TMP_DIR/mihomo-watchdog.new" || \
       ! sh -n "$TMP_DIR/mihomo-watchdog.new"; then
        warn "Watchdog sanity check failed, not installed"
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
    if ! mv -f "$WATCHDOG_STAGE" "$WATCHDOG_BIN"; then
        warn "Failed to install $WATCHDOG_BIN"
        return 1
    fi
    chmod +x "$WATCHDOG_BIN"
}

ensure_watchdog_cron() {
    mkdir -p /opt/etc/cron.5mins
    cat > "$WATCHDOG_CRON" <<'EOF' || { warn "Failed to write $WATCHDOG_CRON"; return 1; }
#!/bin/sh
exec /opt/bin/mihomo_watchdog.sh "$@"
EOF
    chmod +x "$WATCHDOG_CRON"

    mkdir -p /opt/var/log
    touch /opt/var/log/mihomo_watchdog.log
    chmod 666 /opt/var/log/mihomo_watchdog.log

    # Exactly one cron route: run-parts on cron.5mins when the crontab
    # already delegates it, otherwise one direct line (deduplicated).
    if grep -q "cron.5mins" /opt/etc/crontab 2>/dev/null; then
        log "Using run-parts"
    else
        log "Fallback to crontab"
        grep -q "mihomo_watchdog" /opt/etc/crontab 2>/dev/null || \
            echo "*/5 * * * * root /bin/sh /opt/etc/cron.5mins/mihomo_watchdog" >> /opt/etc/crontab
    fi

    /opt/etc/init.d/S10cron restart || warn "Cron restart failed"
}

if watchdog_is_canonical "$WATCHDOG_BIN"; then
    # Canonical binary present: accept the new layout, keep one cron route.
    # A wrapper is recognized by its exec line, so a full watchdog that
    # merely mentions the canonical path in its header is not mistaken
    # for one.
    if [ -f "$WATCHDOG_CRON" ] && ! grep -q "^exec $WATCHDOG_BIN" "$WATCHDOG_CRON" 2>/dev/null; then
        warn "Unknown file at $WATCHDOG_CRON, left unchanged"
    elif [ -f "$WATCHDOG_CRON" ]; then
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
# RESTART
# ---------------------------
if [ -x /opt/etc/init.d/S99mihomo ]; then
    /opt/etc/init.d/S99mihomo restart || warn "Mihomo restart failed"
else
    warn "S99mihomo not found, cannot restart"
fi

sleep 2

# ---------------------------
# POST-INSTALL SELF-CHECK
# ---------------------------
# Validates what this installer promises to install. install.sh leaves a
# bootstrap config.yaml (mixed-port 7890) in place unless a user config
# already exists. Missing config.yaml means bootstrap creation failed — WARN,
# not FAIL. Port 7890 is checked whenever a config exists: the bootstrap must
# listen on 7890, so a miss here means Mihomo is not running properly (or a
# user config does not define the contract port) — never a package
# placeholder, which install.sh replaces.
FAILS=0
WARNS=0

check_ok()   { echo "[ok] $1"; }
check_warn() { echo "[WARN] $1"; WARNS=$((WARNS+1)); }
check_fail() { echo "[FAIL] $1"; FAILS=$((FAILS+1)); }
check_info() { echo "[info] $1"; }

# One-Mihomo invariant: the self-check executes the Mihomo binary (-v/-t)
# ONLY when no daemon is running - a second execution is the documented
# SIGSEGV pattern on constrained hardware. Without pidof the state cannot
# be verified, so the probes are skipped conservatively (assumed running).
mihomo_running() {
    if command -v pidof >/dev/null 2>&1; then
        pidof mihomo >/dev/null 2>&1
    else
        return 0
    fi
}

CONFIG="/opt/etc/mihomo/config.yaml"

# Mihomo binary + version
if [ -x /opt/bin/mihomo ] || command -v mihomo >/dev/null 2>&1; then
    MIHOMO_BIN=$(command -v mihomo 2>/dev/null || echo "/opt/bin/mihomo")
    if mihomo_running; then
        check_info "Mihomo daemon is running - binary probe (-v) skipped (one-Mihomo invariant); the running daemon itself proves the binary executes"
    elif ${MIHOMO_BIN} -v >/dev/null 2>&1; then
        check_ok "Mihomo binary: $(${MIHOMO_BIN} -v 2>/dev/null | head -1)"
    else
        check_fail "Mihomo binary exists but 'mihomo -v' failed"
    fi
else
    check_fail "Mihomo binary not found (/opt/bin/mihomo)"
fi

# Mihomo init script
if [ -x /opt/etc/init.d/S99mihomo ]; then
    check_ok "Mihomo init script present"
else
    check_fail "Mihomo init script /opt/etc/init.d/S99mihomo missing"
fi

# Project proxy — Proxy0 or a free ProxyN when Proxy0 is foreign; both project
# markers are verified against a freshly validated running-config snapshot.
# An ndmc failure here is UNKNOWN: reported as FAIL, never misread as an
# absent or non-project proxy.
if [ -z "$PROXY_IFACE" ]; then
    check_fail "No project proxy (ndmc read failed during selection, or no free ProxyN with foreign Proxy0)"
elif ! load_rc_dump; then
    check_fail "Proxy state cannot be determined (running-config read failed)"
else
    proxy_state "$PROXY_IFACE"
    if [ "$PROXY_STATE" = "FOUND" ] && proxy_is_project "$PROXY_IFACE" "${PROXY_IFACE#Proxy}"; then
        check_ok "Project proxy ${PROXY_IFACE}: mihomo t2s${PROXY_IFACE#Proxy} -> 127.0.0.1:7890"
    else
        check_fail "Project proxy ${PROXY_IFACE} missing or does not match the project profile"
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
    if mihomo_running; then
        check_info "Mihomo config syntax check skipped - the daemon is running and 'mihomo -t' would execute a second Mihomo (one-Mihomo invariant); the running service proves the config loads"
    elif ${MIHOMO_BIN} -t -d /opt/etc/mihomo -f "$CONFIG" >/dev/null 2>&1; then
        check_ok "Mihomo config syntax valid"
    else
        check_warn "Mihomo config syntax check (mihomo -t) failed"
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -tln 2>/dev/null | grep -q 7890 || check_warn "Port 7890 not listening — Mihomo may not be running, or config.yaml does not define mixed-port 7890"
    elif command -v ss >/dev/null 2>&1; then
        ss -tln 2>/dev/null | grep -q 7890 || check_warn "Port 7890 not listening — Mihomo may not be running, or config.yaml does not define mixed-port 7890"
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

# Free space on /opt (critical low)
AVAIL_KB=$(df -k /opt 2>/dev/null | awk 'NR==2 {print $4}')
case "$AVAIL_KB" in
    ''|*[!0-9]*)
        check_warn "Cannot determine free space on /opt"
        ;;
    *)
        if [ "$AVAIL_KB" -lt 32768 ]; then
            check_warn "Low free space on /opt: ${AVAIL_KB} KB"
        else
            check_ok "Free space on /opt: ${AVAIL_KB} KB"
        fi
        ;;
esac

# Verdict
if [ "$FAILS" -gt 0 ]; then
    echo "[FAIL] $FAILS check(s) failed, $WARNS warning(s) — installation incomplete"
    exit 1
fi
if [ "$WARNS" -gt 0 ]; then
    echo "[OK] Done ($WARNS warning(s))"
else
    echo "[OK] Done"
fi
