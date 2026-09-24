#!/bin/sh

set -e

PROJECT_REF="${KEENETIC_AUTO_SETUP_REF:-stable}"
PROJECT_RAW_BASE="https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/${PROJECT_REF}"
INSTALL_STAGE="/tmp/keenetic-auto-setup-install.$$"
PROC_MOUNTS="${SETUP_MOUNTS:-/proc/mounts}"

log() { echo "[setup] $1"; }
warn() { echo "[WARN] $1"; }
err() { echo "[ERROR] $1" >&2; exit 1; }

cleanup() {
    rm -f "$INSTALL_STAGE"
}
trap cleanup EXIT INT TERM HUP

retry_download() {
    _rd_url="$1"
    _rd_dst="$2"
    for _rd_try in 1 2 3; do
        if curl -fSsL "$_rd_url" -o "$_rd_dst"; then
            return 0
        fi
        warn "Download attempt $_rd_try/3 failed"
        sleep 2
    done
    return 1
}

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

opt_storage_class() {
    _osc_path="$1"
    _osc_best_len=0
    _osc_class=unknown

    [ -r "$PROC_MOUNTS" ] || { echo unknown; return 0; }

    while read -r _osc_src _osc_mp _osc_fstype _osc_rest; do
        case "$_osc_path" in
            "$_osc_mp") ;;
            *)
                case "$_osc_path" in
                    "$_osc_mp"/*) ;;
                    *) continue ;;
                esac
                ;;
        esac

        _osc_len=${#_osc_mp}
        [ "$_osc_len" -ge "$_osc_best_len" ] || continue
        _osc_best_len=$_osc_len
        _osc_class=$(classify_mount "$_osc_src" "$_osc_fstype")
    done < "$PROC_MOUNTS"

    echo "$_osc_class"
}

echo "=== Keenetic Auto Setup — Simple Installer ==="

command -v opkg >/dev/null 2>&1 || err "Entware/OPKG not found. Install Entware first."
command -v curl >/dev/null 2>&1 || err "curl not found. Run: opkg update && opkg install curl"

OPT_CLASS=$(opt_storage_class /opt)
case "$OPT_CLASS" in
    internal)
        MODE=ram
        log "Detected /opt on internal Keenetic storage"
        log "Selected installation profile: ram"
        ;;
    external)
        MODE=disk
        log "Detected /opt on external persistent storage"
        log "Selected installation profile: disk"
        ;;
    ram)
        err "/opt appears to be on volatile RAM storage; automatic installation is unsafe"
        ;;
    *)
        err "Could not safely classify /opt storage. Use the documented advanced install path instead."
        ;;
esac

log "Downloading the canonical installer from '${PROJECT_REF}'..."
retry_download "$PROJECT_RAW_BASE/install.sh" "$INSTALL_STAGE" || \
    err "Could not download install.sh after 3 attempts"

sh -n "$INSTALL_STAGE" || err "Downloaded install.sh failed shell syntax validation"

log "Starting canonical installer..."
KEENETIC_AUTO_SETUP_REF="$PROJECT_REF" sh "$INSTALL_STAGE" "$MODE"

echo
echo "=== Installation completed ==="
echo "The storage mode was selected automatically; all safety checks were performed by install.sh."
echo
echo "Next step: create your Mihomo configuration:"
echo "  https://saymer-alt.github.io/link-generators/"
echo
echo "Then edit:"
echo "  nano /opt/etc/mihomo/config.yaml"
echo
echo "After saving the config:"
echo "  /opt/etc/init.d/S99mihomo restart"
echo "  /opt/etc/init.d/S99mihomo status"
echo
echo "Optional full diagnostic:"
echo "  curl -fSsL ${PROJECT_RAW_BASE}/mihomo-doctor.sh | sh"
