#!/bin/sh
# KAS_FIRSTFETCH_V1
# KAS public entry point. The short HTTPS installation command streams THIS
# initial launcher to sh (an explicitly accepted first-fetch risk).
# This launcher downloads setup.sh into a private temporary file, validates
# the full candidate before execution, and uses GitHub transport fallbacks.
# No setup.sh remote bytes are piped directly into sh.
# --script NAME selects another supported entry point instead of setup.sh:
# config-import.sh, update-mihomo.sh or mihomo-doctor.sh — the same private
# staging, transport fallbacks and pre-execution checks, so a mid-stream
# failure of a large script can no longer execute as a partially delivered
# curl-to-sh stream (issue #255).
#
# Independent source fallback (issue #232): after all GitHub transports, the
# read-only GitLab source mirror is tried once for the SAME ref and script.
# The GitLab candidate must byte-match the mirror's own repository
# attestation (size + SHA256 + git blob id) locally before the same
# validation contract applies; any miss fails closed. The mirror is an
# availability fallback, not a trust anchor: while GitHub is down, a lagged
# mirror can serve the previous (authentic) stable commit until sync catches
# up. Pin KAS_BOOTSTRAP_REF to a tag for an immutable identity.
#
# Full-content EOF/size contract: every staged candidate must end with the
# exact sentinel line '# KAS_EOF_V1'. A truncated response can never carry
# it, even when curl exits 0, the first bytes and sh -n look correct.
# sh -n is a syntax check, never a content integrity proof.
set -u

CHECK_ONLY=0
SCRIPT=setup.sh
while [ "$#" -gt 0 ]; do
    case "$1" in
        --check) CHECK_ONLY=1 ;;
        --script)
            if [ "$#" -lt 2 ]; then
                printf '[ERROR] --script requires a script name\n' >&2
                exit 2
            fi
            case "$2" in
                config-import.sh) SCRIPT=config-import.sh ;;
                update-mihomo.sh) SCRIPT=update-mihomo.sh ;;
                mihomo-doctor.sh) SCRIPT=mihomo-doctor.sh ;;
                *)
                    printf '[ERROR] Unsupported --script: %s\n' "$2" >&2
                    exit 2
                    ;;
            esac
            shift
            ;;
        *) printf '[ERROR] Usage: bootstrap.sh [--check] [--script config-import.sh|update-mihomo.sh|mihomo-doctor.sh]\n' >&2; exit 2 ;;
    esac
    shift
done

REF=${KAS_BOOTSTRAP_REF:-stable}
case "$REF" in
    ''|/*|*/|*..*|*[!A-Za-z0-9._/-]*)
        printf '[ERROR] Invalid KAS_BOOTSTRAP_REF\n' >&2
        exit 2
        ;;
esac

# Test-only endpoint overrides. Without them the production sources below are
# used. An override is accepted only as a plain loopback HTTP URL, so a stray
# environment can never redirect a real install at an arbitrary host.
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

GH_RAW_BASE=$(pick_mock_base KAS_MOCK_GH_RAW_BASE \
    'https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup') || exit 2
GH_API_BASE=$(pick_mock_base KAS_MOCK_GH_API_BASE \
    'https://api.github.com/repos/saymer-alt/keenetic-auto-setup') || exit 2
GL_RAW_BASE=$(pick_mock_base KAS_MOCK_GL_RAW_BASE \
    'https://gitlab.com/saymer-alt/keenetic-auto-setup') || exit 2
GL_API_BASE=$(pick_mock_base KAS_MOCK_GL_API_BASE \
    'https://gitlab.com/api/v4') || exit 2
RAW="$GH_RAW_BASE/$REF/$SCRIPT"
API="$GH_API_BASE/contents/$SCRIPT?ref=$REF"
GL_RAW="$GL_RAW_BASE/-/raw/$REF/$SCRIPT"
GL_API="$GL_API_BASE/projects/saymer-alt%2Fkeenetic-auto-setup/repository/files/$SCRIPT?ref=$REF"

command -v curl >/dev/null 2>&1 || {
    printf '[ERROR] curl is required: opkg update && opkg install curl\n' >&2
    exit 1
}
command -v mktemp >/dev/null 2>&1 || {
    printf '[ERROR] mktemp is required for a private download\n' >&2
    exit 1
}

umask 077
STAGE=$(mktemp "${TMPDIR:-/tmp}/kas-setup.XXXXXXXX") || {
    printf '[ERROR] Cannot create private setup staging file\n' >&2
    exit 1
}
trap 'rm -f "$STAGE"' 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

valid_script() {
    [ -s "$STAGE" ] || return 1
    [ "$(head -n 1 "$STAGE" 2>/dev/null)" = '#!/bin/sh' ] || return 1
    # Full-content EOF/size contract: reject any truncated or partial
    # candidate even when the head and sh -n look correct. The size floor
    # stays far below released sizes so legitimate future versions can
    # never trip it; the sentinel is the authoritative completeness check.
    [ "$(tail -n 1 "$STAGE" 2>/dev/null)" = '# KAS_EOF_V1' ] || return 1
    _vs_size=$(wc -c < "$STAGE" 2>/dev/null | tr -d ' \t')
    [ -n "$_vs_size" ] && [ "$_vs_size" -ge 5000 ] || return 1
    # Verify the returned file is this project's real entry point,
    # not an HTML, JSON, or unrelated syntactically valid shell response.
    # Each supported script keeps its own stable markers.
    case "$SCRIPT" in
        setup.sh)
            grep -Fq 'PROJECT_API_CONTENTS=' "$STAGE" || return 1
            grep -Fq 'download_project_script' "$STAGE" || return 1
            ;;
        config-import.sh)
            grep -Fq 'BEGIN MIHOMO LIFECYCLE LOCK v1' "$STAGE" || return 1
            grep -Fq 'mixed-port: 7890' "$STAGE" || return 1
            ;;
        update-mihomo.sh)
            grep -Fq 'BINARY_STATE=' "$STAGE" || return 1
            grep -Fq 'BEGIN MIHOMO INIT RESOLUTION v1' "$STAGE" || return 1
            ;;
        mihomo-doctor.sh)
            grep -Fq 'BEGIN MIHOMO INIT RESOLUTION v1' "$STAGE" || return 1
            grep -Fq 'resolve_mihomo_init' "$STAGE" || return 1
            ;;
    esac
    sh -n "$STAGE" >/dev/null 2>&1 || return 1
}

fetch() {
    _label=$1
    shift
    : > "$STAGE" || return 1
    printf '[bootstrap] Downloading %s via %s (connect 7s, total 25s)...\n' "$SCRIPT" "$_label"
    curl -fSsL $MOCK_NOR --connect-timeout 7 --max-time 25 "$@" -o "$STAGE"
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        printf '[WARN] %s: curl failed (exit %s)\n' "$_label" "$_rc" >&2
        return 1
    fi
    if ! valid_script; then
        printf '[WARN] %s: empty/invalid response or shell syntax; refusing execution\n' "$_label" >&2
        return 1
    fi
    printf '[bootstrap] Validated source from %s\n' "$_label"
    return 0
}

# Verified GitLab mirror stage (issue #232). Runs only after every GitHub
# transport failed. The mirror's own repository files API attests the exact
# blob id, byte size and content SHA256 for the same ref; the downloaded
# candidate must reproduce all three locally before the full script contract
# applies. Anything else fails closed: no partial, drifted, or foreign
# content is ever executed.
gitlab_fetch_verified() {
    command -v sha256sum >/dev/null 2>&1 || {
        printf '[WARN] GitLab mirror: sha256sum unavailable; mirror fallback disabled\n' >&2
        return 1
    }
    command -v sha1sum >/dev/null 2>&1 || {
        printf '[WARN] GitLab mirror: sha1sum unavailable; mirror fallback disabled\n' >&2
        return 1
    }
    _gf_meta=$(curl -fSsL $MOCK_NOR --connect-timeout 7 --max-time 25 "$GL_API" 2>/dev/null) || {
        printf '[WARN] GitLab mirror: attestation request failed\n' >&2
        return 1
    }
    _gf_blob=$(printf '%s' "$_gf_meta" | grep -oE '"blob_id":"[0-9a-f]{40}"' | head -n 1 | cut -d '"' -f4)
    _gf_size=$(printf '%s' "$_gf_meta" | grep -oE '"size":[0-9]+' | head -n 1 | tr -cd '0-9')
    _gf_sha=$(printf '%s' "$_gf_meta" | grep -oE '"content_sha256":"[0-9a-f]{64}"' | head -n 1 | cut -d '"' -f4)
    if [ -z "$_gf_blob" ] || [ -z "$_gf_size" ] || [ -z "$_gf_sha" ]; then
        printf '[WARN] GitLab mirror: incomplete attestation; refusing to use mirror\n' >&2
        return 1
    fi
    : > "$STAGE" || return 1
    printf '[bootstrap] Downloading %s via verified GitLab mirror (attested %s bytes)...\n' "$SCRIPT" "$_gf_size"
    curl -fSsL $MOCK_NOR --connect-timeout 7 --max-time 25 "$GL_RAW" -o "$STAGE"
    _gf_rc=$?
    if [ "$_gf_rc" -ne 0 ]; then
        printf '[WARN] GitLab mirror: curl failed (exit %s)\n' "$_gf_rc" >&2
        return 1
    fi
    _gf_got=$(wc -c < "$STAGE" 2>/dev/null | tr -d ' \t')
    if [ "$_gf_got" != "$_gf_size" ]; then
        printf '[WARN] GitLab mirror: partial/wrong size (got %s); refusing\n' "$_gf_got" >&2
        return 1
    fi
    _gf_have=$(sha256sum "$STAGE" 2>/dev/null | awk '{print $1}')
    if [ "$_gf_have" != "$_gf_sha" ]; then
        printf '[WARN] GitLab mirror: SHA256 does not match attestation; refusing\n' >&2
        return 1
    fi
    _gf_gitblob=$( { printf 'blob %s\0' "$(wc -c < "$STAGE")"; cat "$STAGE"; } | sha1sum | awk '{print $1}')
    if [ "$_gf_gitblob" != "$_gf_blob" ]; then
        printf '[WARN] GitLab mirror: git blob id does not match attestation; refusing\n' >&2
        return 1
    fi
    if ! valid_script; then
        printf '[WARN] GitLab mirror: content contract failed; refusing execution\n' >&2
        return 1
    fi
    printf '[bootstrap] Validated source from verified GitLab mirror\n'
    return 0
}

if fetch 'GitHub raw' "$RAW" ||
   fetch 'GitHub raw IPv4/X25519' -4 --curves X25519 "$RAW" ||
   fetch 'GitHub Contents API' -4 -H 'Accept: application/vnd.github.raw+json' \
       -H 'X-GitHub-Api-Version: 2022-11-28' "$API" ||
   gitlab_fetch_verified; then
    if [ "$CHECK_ONLY" -eq 1 ]; then
        printf '[bootstrap] CHECK_ONLY: %s verified for ref %s; nothing executed\n' "$SCRIPT" "$REF"
        exit 0
    fi
    printf '[bootstrap] Executing validated %s (ref: %s)\n' "$SCRIPT" "$REF"
    sh "$STAGE"
    _rc=$?
    printf '[bootstrap] %s finished (exit %s)\n' "$SCRIPT" "$_rc"
    exit "$_rc"
fi

printf '[ERROR] Could not fetch valid KAS %s from GitHub raw/API or the verified GitLab mirror; no script executed.\n' "$SCRIPT" >&2
exit 1
