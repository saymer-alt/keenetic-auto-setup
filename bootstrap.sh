#!/bin/sh
# KAS_FIRSTFETCH_V1
# KAS public entry point. The short HTTPS installation command streams THIS
# initial launcher to sh (an explicitly accepted first-fetch risk).
# This launcher downloads setup.sh into a private temporary file, validates
# the full candidate before execution, and uses GitHub transport fallbacks.
# No setup.sh remote bytes are piped directly into sh.
# --script config-import.sh selects the standalone YAML importer instead:
# the same private staging, transport fallbacks and pre-execution checks,
# so a mid-stream failure of the large importer can no longer execute as a
# partially delivered `curl | sh` (issue #255).
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
                *)
                    printf '[ERROR] Unsupported --script: %s\n' "$2" >&2
                    exit 2
                    ;;
            esac
            shift
            ;;
        *) printf '[ERROR] Usage: bootstrap.sh [--check] [--script config-import.sh]\n' >&2; exit 2 ;;
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

RAW="https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/$REF/$SCRIPT"
API="https://api.github.com/repos/saymer-alt/keenetic-auto-setup/contents/$SCRIPT?ref=$REF"

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
    esac
    sh -n "$STAGE" >/dev/null 2>&1 || return 1
}

fetch() {
    _label=$1
    shift
    : > "$STAGE" || return 1
    printf '[bootstrap] Downloading %s via %s (connect 7s, total 25s)...\n' "$SCRIPT" "$_label"
    curl -fSsL --connect-timeout 7 --max-time 25 "$@" -o "$STAGE"
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

if fetch 'GitHub raw' "$RAW" ||
   fetch 'GitHub raw IPv4/X25519' -4 --curves X25519 "$RAW" ||
   fetch 'GitHub Contents API' -4 -H 'Accept: application/vnd.github.raw+json' \
       -H 'X-GitHub-Api-Version: 2022-11-28' "$API"; then
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

printf '[ERROR] Could not fetch valid KAS %s from raw or Contents API; no script executed.\n' "$SCRIPT" >&2
exit 1
