#!/bin/sh

set -e

PROJECT_REF="${KEENETIC_AUTO_SETUP_REF:-stable}"
# Test-only endpoint overrides (issue #232 offline regressions). Without them
# the production sources are used. An override is accepted only as a plain
# loopback HTTP URL, so a stray environment can never redirect a real install
# at an arbitrary host.
pick_mock_base() {
    _pmb_name=${1:-}
    eval "_pmb_val=\${$_pmb_name:-}"
    if [ -z "$_pmb_val" ]; then printf '%s\n' "$2"; return 0; fi
    case "$_pmb_val" in
        http://127.0.0.1:*|http://localhost:*)
            _pmb_port=${_pmb_val#http://}
            _pmb_port=${_pmb_port%%/*}
            _pmb_port=${_pmb_port#*:}
            case "$_pmb_port" in
                ''|*[!0-9]*) ;;
                *)
                    case "$_pmb_val" in
                        *[!A-Za-z0-9_./:-]*) ;;
                        *) printf '%s\n' "$_pmb_val"; return 0 ;;
                    esac ;;
            esac ;;
    esac
    printf '[ERROR] %s must be unset or a loopback http URL\n' "$_pmb_name" >&2
    return 2
}
MOCK_NOR=
[ -z "${KAS_MOCK_GH_RAW_BASE:-}${KAS_MOCK_GH_API_BASE:-}${KAS_MOCK_GL_RAW_BASE:-}${KAS_MOCK_GL_API_BASE:-}" ] || MOCK_NOR='--max-redirs 0'

PROJECT_RAW_BASE="$(pick_mock_base KAS_MOCK_GH_RAW_BASE 'https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup')/${PROJECT_REF}" || exit 2
PROJECT_API_CONTENTS="$(pick_mock_base KAS_MOCK_GH_API_BASE 'https://api.github.com/repos/saymer-alt/keenetic-auto-setup/contents')" || exit 2
PROJECT_GL_RAW_BASE="$(pick_mock_base KAS_MOCK_GL_RAW_BASE 'https://gitlab.com/saymer-alt/keenetic-auto-setup')" || exit 2
PROJECT_GL_API_BASE="$(pick_mock_base KAS_MOCK_GL_API_BASE 'https://gitlab.com/api/v4')" || exit 2
INSTALL_STAGE="/tmp/keenetic-auto-setup-install.$$"
CONFIG_IMPORT_STAGE="/tmp/keenetic-auto-setup-config-import.$$"
PROC_MOUNTS="${SETUP_MOUNTS:-/proc/mounts}"
# Wall-clock budget for one small metadata/script fetch (issue #89): matches
# the --max-time 20 the curl paths above already use for the same payloads.
# wget -T alone bounds connect/read gaps only, not the whole attempt.
SETUP_SMALL_TRANSFER_MAX_TIME="${SETUP_SMALL_TRANSFER_MAX_TIME:-20}"

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
err() { status_err "[ERROR] $1"; exit 1; }

cleanup() {
    rm -f "$INSTALL_STAGE" "$CONFIG_IMPORT_STAGE"
}
trap cleanup EXIT INT TERM HUP

script_candidate_ok() {
    _sc_file="$1"
    _sc_rel="$2"
    [ -s "$_sc_file" ] || return 1
    [ "$(head -n 1 "$_sc_file" 2>/dev/null)" = "#!/bin/sh" ] || return 1
    # Full-content EOF/size contract (issue #232): reject any truncated or
    # partial candidate even when the head and sh -n look correct; curl may
    # exit 0 on a short read. The size floor stays far below released sizes
    # so legitimate future versions can never trip it; the exact sentinel
    # line is the authoritative completeness check, sh -n is only syntax.
    [ "$(tail -n 1 "$_sc_file" 2>/dev/null)" = "# KAS_EOF_V1" ] || return 1
    _sc_size=$(wc -c < "$_sc_file" 2>/dev/null | tr -d ' \t')
    [ -n "$_sc_size" ] && [ "$_sc_size" -ge 5000 ] || return 1
    # Each staged script keeps its own stable project markers, so an HTML,
    # JSON, or unrelated syntactically valid response cannot pass.
    case "$_sc_rel" in
        install.sh)
            grep -Fq 'MIHOMO_LIFECYCLE_LOCK=' "$_sc_file" || return 1
            grep -Fq 'magitrickle' "$_sc_file" || return 1
            ;;
        config-import.sh)
            grep -Fq 'BEGIN MIHOMO LIFECYCLE LOCK v1' "$_sc_file" || return 1
            grep -Fq 'mixed-port: 7890' "$_sc_file" || return 1
            ;;
    esac
    sh -n "$_sc_file" >/dev/null 2>&1
}

curl_to_file_once() {
    _rc_url="$1"
    _rc_dst="$2"
    _rc_api="${3:-0}"
    _rc_curve="${4:-}"
    if [ "$_rc_api" -eq 1 ]; then
        if [ -n "$_rc_curve" ]; then
            curl -fSsL $MOCK_NOR --connect-timeout 5 --max-time 20 -4 --curves "$_rc_curve" \
                -H "Accept: application/vnd.github.raw+json" \
                -H "X-GitHub-Api-Version: 2022-11-28" \
                "$_rc_url" -o "$_rc_dst" 2>/dev/null
        else
            curl -fSsL $MOCK_NOR --connect-timeout 5 --max-time 20 \
                -H "Accept: application/vnd.github.raw+json" \
                -H "X-GitHub-Api-Version: 2022-11-28" \
                "$_rc_url" -o "$_rc_dst" 2>/dev/null
        fi
    elif [ -n "$_rc_curve" ]; then
        curl -fSsL $MOCK_NOR --connect-timeout 5 --max-time 20 -4 --curves "$_rc_curve" \
            "$_rc_url" -o "$_rc_dst" 2>/dev/null
    else
        curl -fSsL $MOCK_NOR --connect-timeout 5 --max-time 20 \
            "$_rc_url" -o "$_rc_dst" 2>/dev/null
    fi
}

retry_curl_to_file() {
    _rc_url="$1"
    _rc_dst="$2"
    _rc_api="${3:-0}"
    for _rc_try in 1 2 3; do
        rm -f "$_rc_dst" 2>/dev/null || true
        if curl_to_file_once "$_rc_url" "$_rc_dst" "$_rc_api"; then
            return 0
        fi
        rm -f "$_rc_dst" 2>/dev/null || true
        sleep 2
    done

    # OpenSSL 3.5+ can emit a much larger hybrid-PQ TLS ClientHello. Some
    # middleboxes/path-MTU combinations drop it while classical X25519 works.
    # Keep normal TLS first; use one bounded compatibility retry before wget/API.
    rm -f "$_rc_dst" 2>/dev/null || true
    if curl_to_file_once "$_rc_url" "$_rc_dst" "$_rc_api" X25519; then
        return 0
    fi
    rm -f "$_rc_dst" 2>/dev/null || true
    return 1
}

retry_wget_to_file() {
    _rw_url="$1"
    _rw_dst="$2"
    # BusyBox wget has no portable redirect limit. In explicit mock mode,
    # never let a loopback test URL redirect to an arbitrary network host.
    # Normal (non-mock) wget fallback stays unchanged.
    [ -z "$MOCK_NOR" ] || return 1
    command -v wget >/dev/null 2>&1 || return 1
    # wget -T bounds connect/read gaps only: a trickling server keeps one
    # attempt alive indefinitely because every read arrives before -T fires.
    # When a BusyBox/GNU timeout applet exists, each attempt additionally
    # runs under the same wall-clock budget curl uses for these small
    # payloads; without it the per-read timeout stays the only bound
    # (issue #89). TLS/CA handling is untouched.
    _rw_wrap=""
    if command -v timeout >/dev/null 2>&1; then
        _rw_wrap="timeout $SETUP_SMALL_TRANSFER_MAX_TIME"
    fi
    for _rw_try in 1 2 3; do
        rm -f "$_rw_dst" 2>/dev/null || true
        if $_rw_wrap wget -qO "$_rw_dst" -T "$SETUP_SMALL_TRANSFER_MAX_TIME" "$_rw_url" 2>/dev/null; then
            return 0
        fi
        rm -f "$_rw_dst" 2>/dev/null || true
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

    if retry_curl_to_file "$_dps_raw" "$_dps_dst"; then
        if script_candidate_ok "$_dps_dst" "$_dps_rel"; then
            return 0
        fi
        rm -f "$_dps_dst" 2>/dev/null || true
        if [ -z "$MOCK_NOR" ] && command -v wget >/dev/null 2>&1; then
            warn "raw/curl returned an invalid script candidate for $_dps_rel; trying wget fallback"
        else
            warn "raw/curl returned an invalid script candidate for $_dps_rel; wget unavailable, trying GitHub Contents API fallback"
        fi
    else
        rm -f "$_dps_dst" 2>/dev/null || true
        if [ -z "$MOCK_NOR" ] && command -v wget >/dev/null 2>&1; then
            warn "raw/curl failed after bounded retries for $_dps_rel; trying wget fallback"
        else
            warn "raw/curl failed after bounded retries for $_dps_rel; wget unavailable, trying GitHub Contents API fallback"
        fi
    fi

    if [ -z "$MOCK_NOR" ] && command -v wget >/dev/null 2>&1; then
        if retry_wget_to_file "$_dps_raw" "$_dps_dst"; then
            if script_candidate_ok "$_dps_dst" "$_dps_rel"; then
                return 0
            fi
            rm -f "$_dps_dst" 2>/dev/null || true
            warn "raw/wget returned an invalid script candidate for $_dps_rel; trying GitHub Contents API fallback"
        else
            rm -f "$_dps_dst" 2>/dev/null || true
            warn "raw/wget failed after 3 attempts for $_dps_rel; trying GitHub Contents API fallback"
        fi
    fi

    if retry_curl_to_file "$_dps_api" "$_dps_dst" 1; then
        if script_candidate_ok "$_dps_dst" "$_dps_rel"; then
            return 0
        fi
        warn "GitHub Contents API returned an invalid script candidate for $_dps_rel"
    fi

    # Verified GitLab mirror stage (issue #232): runs only after every GitHub
    # transport failed. The mirror's own repository files API attests the
    # exact blob id, byte size and content SHA256 for the same ref; the
    # candidate must reproduce all three locally before the full script
    # contract applies. Any miss fails closed: no partial, drifted, or
    # foreign content is ever executed.
    if download_project_script_gitlab "$_dps_rel" "$_dps_dst"; then
        return 0
    fi

    rm -f "$_dps_dst" 2>/dev/null || true
    return 1
}

download_project_script_gitlab() {
    _dpg_rel="$1"
    _dpg_dst="$2"
    command -v sha256sum >/dev/null 2>&1 || {
        warn "sha256sum unavailable; GitLab mirror fallback disabled"
        return 1
    }
    command -v sha1sum >/dev/null 2>&1 || {
        warn "sha1sum unavailable; GitLab mirror fallback disabled"
        return 1
    }
    if ! retry_curl_to_file "$PROJECT_GL_API_BASE/projects/saymer-alt%2Fkeenetic-auto-setup/repository/files/$_dpg_rel?ref=$PROJECT_REF" "$_dpg_dst.meta"; then
        warn "GitLab mirror attestation request failed for $_dpg_rel"
        rm -f "$_dpg_dst.meta" 2>/dev/null || true
        return 1
    fi
    _dpg_blob=$(grep -oE '"blob_id":"[0-9a-f]{40}"' "$_dpg_dst.meta" 2>/dev/null | head -n 1 | cut -d '"' -f4)
    _dpg_size=$(grep -oE '"size":[0-9]+' "$_dpg_dst.meta" 2>/dev/null | head -n 1 | tr -cd '0-9')
    _dpg_sha=$(grep -oE '"content_sha256":"[0-9a-f]{64}"' "$_dpg_dst.meta" 2>/dev/null | head -n 1 | cut -d '"' -f4)
    rm -f "$_dpg_dst.meta" 2>/dev/null || true
    if [ -z "$_dpg_blob" ] || [ -z "$_dpg_size" ] || [ -z "$_dpg_sha" ]; then
        warn "GitLab mirror attestation incomplete for $_dpg_rel; refusing to use mirror"
        return 1
    fi
    if ! retry_curl_to_file "$PROJECT_GL_RAW_BASE/-/raw/$PROJECT_REF/$_dpg_rel" "$_dpg_dst"; then
        warn "GitLab mirror download failed for $_dpg_rel"
        rm -f "$_dpg_dst" 2>/dev/null || true
        return 1
    fi
    _dpg_got=$(wc -c < "$_dpg_dst" 2>/dev/null | tr -d ' \t')
    if [ "$_dpg_got" != "$_dpg_size" ]; then
        warn "GitLab mirror partial/wrong size for $_dpg_rel (got $_dpg_got); refusing"
        rm -f "$_dpg_dst" 2>/dev/null || true
        return 1
    fi
    _dpg_have=$(sha256sum "$_dpg_dst" 2>/dev/null | awk '{print $1}')
    if [ "$_dpg_have" != "$_dpg_sha" ]; then
        warn "GitLab mirror SHA256 does not match attestation for $_dpg_rel; refusing"
        rm -f "$_dpg_dst" 2>/dev/null || true
        return 1
    fi
    _dpg_gitblob=$( { printf 'blob %s\0' "$(wc -c < "$_dpg_dst")"; cat "$_dpg_dst"; } | sha1sum | awk '{print $1}')
    if [ "$_dpg_gitblob" != "$_dpg_blob" ]; then
        warn "GitLab mirror git blob id does not match attestation for $_dpg_rel; refusing"
        rm -f "$_dpg_dst" 2>/dev/null || true
        return 1
    fi
    if ! script_candidate_ok "$_dpg_dst" "$_dpg_rel"; then
        warn "GitLab mirror content contract failed for $_dpg_rel; refusing execution"
        rm -f "$_dpg_dst" 2>/dev/null || true
        return 1
    fi
    log "Validated source from verified GitLab mirror for $_dpg_rel"
    return 0
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
# BusyBox wget in KeeneticOS may expose HTTP/FTP only, so cannot safely
# bootstrap HTTPS downloads from GitHub. curl is the documented prerequisite.
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
    echo "  curl -fSsL --connect-timeout 5 --max-time 20 ${PROJECT_RAW_BASE}/config-import.sh | sh"
fi

echo
echo "Optional full diagnostic:"
echo "  curl -fSsL --connect-timeout 5 --max-time 20 ${PROJECT_RAW_BASE}/mihomo-doctor.sh | sh"
echo "If raw GitHub TLS stalls before script output, retry curl with: --curves X25519"

# Full-content EOF contract marker for bootstrap staging (issue #232).
# KAS_EOF_V1
