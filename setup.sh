#!/bin/sh

set -e

PROJECT_REF="${KEENETIC_AUTO_SETUP_REF:-stable}"
PROJECT_RAW_BASE="https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/${PROJECT_REF}"
PROJECT_API_CONTENTS="https://api.github.com/repos/saymer-alt/keenetic-auto-setup/contents"
INSTALL_STAGE="/tmp/keenetic-auto-setup-install.$$"
CONFIG_IMPORT_STAGE="/tmp/keenetic-auto-setup-config-import.$$"
PROC_MOUNTS="${SETUP_MOUNTS:-/proc/mounts}"

log() { echo "[setup] $1"; }
warn() { echo "[WARN] $1"; }
err() { echo "[ERROR] $1" >&2; exit 1; }

cleanup() {
    rm -f "$INSTALL_STAGE" "$CONFIG_IMPORT_STAGE"
}
trap cleanup EXIT INT TERM HUP

script_candidate_ok() {
    _sc_file="$1"
    [ -s "$_sc_file" ] || return 1
    [ "$(head -n 1 "$_sc_file" 2>/dev/null)" = "#!/bin/sh" ] || return 1
    sh -n "$_sc_file" >/dev/null 2>&1
}

retry_curl_to_file() {
    _rc_url="$1"
    _rc_dst="$2"
    _rc_api="${3:-0}"
    for _rc_try in 1 2 3; do
        rm -f "$_rc_dst" 2>/dev/null || true
        if [ "$_rc_api" -eq 1 ]; then
            if curl -fSsL \
                -H "Accept: application/vnd.github.raw+json" \
                -H "X-GitHub-Api-Version: 2022-11-28" \
                "$_rc_url" -o "$_rc_dst"; then
                return 0
            fi
        elif curl -fSsL "$_rc_url" -o "$_rc_dst"; then
            return 0
        fi
        rm -f "$_rc_dst" 2>/dev/null || true
        warn "curl download attempt $_rc_try/3 failed"
        sleep 2
    done
    return 1
}

retry_wget_to_file() {
    _rw_url="$1"
    _rw_dst="$2"
    command -v wget >/dev/null 2>&1 || return 1
    for _rw_try in 1 2 3; do
        rm -f "$_rw_dst" 2>/dev/null || true
        if wget -qO "$_rw_dst" "$_rw_url"; then
            return 0
        fi
        rm -f "$_rw_dst" 2>/dev/null || true
        warn "wget download attempt $_rw_try/3 failed"
        sleep 2
    done
    return 1
}

download_project_script() {
    _dps_rel="$1"
    _dps_dst="$2"
    _dps_raw="$PROJECT_RAW_BASE/$_dps_rel"
    _dps_api="$PROJECT_API_CONTENTS/$_dps_rel?ref=$PROJECT_REF"

    rm -f "$_dps_dst" 2>/dev/null || true

    if retry_curl_to_file "$_dps_raw" "$_dps_dst" && script_candidate_ok "$_dps_dst"; then
        return 0
    fi
    rm -f "$_dps_dst" 2>/dev/null || true

    log "Trying wget fallback for $_dps_rel..."
    if retry_wget_to_file "$_dps_raw" "$_dps_dst" && script_candidate_ok "$_dps_dst"; then
        return 0
    fi
    rm -f "$_dps_dst" 2>/dev/null || true

    log "Trying GitHub Contents API fallback for $_dps_rel..."
    if retry_curl_to_file "$_dps_api" "$_dps_dst" 1 && script_candidate_ok "$_dps_dst"; then
        return 0
    fi

    rm -f "$_dps_dst" 2>/dev/null || true
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
download_project_script "install.sh" "$INSTALL_STAGE" || \
    err "Could not download a valid install.sh through raw/curl, raw/wget or GitHub API fallbacks"

log "Starting canonical installer..."
KEENETIC_AUTO_SETUP_REF="$PROJECT_REF" sh "$INSTALL_STAGE" "$MODE"

echo
echo "=== Installation completed ==="
echo "The storage mode was selected automatically; all safety checks were performed by install.sh."
echo
echo "Next step: Mihomo configuration"

if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    log "Downloading safe config importer..."
    download_project_script "config-import.sh" "$CONFIG_IMPORT_STAGE" || \
        err "Could not download a valid config-import.sh through raw/curl, raw/wget or GitHub API fallbacks"
    log "Starting safe config importer..."
    sh "$CONFIG_IMPORT_STAGE"
else
    warn "Interactive terminal not available; config import was not started."
    echo "Run it later with:"
    echo "  curl -fSsL ${PROJECT_RAW_BASE}/config-import.sh | sh"
fi

echo
echo "Optional full diagnostic:"
echo "  curl -fSsL ${PROJECT_RAW_BASE}/mihomo-doctor.sh | sh"
