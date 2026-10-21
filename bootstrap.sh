#!/bin/sh
# KAS_FIRSTFETCH_V1
# Safe second-stage entry point: no remote stream is ever piped into sh.
# This script itself must be downloaded into a private file and validated.
set -u

REF=${KAS_BOOTSTRAP_REF:-stable}
case "$REF" in
    ''|/*|*/|*..*|*[!A-Za-z0-9._/-]*)
        printf '[ERROR] Invalid KAS_BOOTSTRAP_REF\n' >&2
        exit 2
        ;;
esac

RAW="https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/$REF/setup.sh"
API="https://api.github.com/repos/saymer-alt/keenetic-auto-setup/contents/setup.sh?ref=$REF"

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
    # Verify the returned file is this project's real setup entry point,
    # not an HTML, JSON, or unrelated syntactically valid shell response.
    grep -Fq 'PROJECT_API_CONTENTS=' "$STAGE" || return 1
    grep -Fq 'download_project_script' "$STAGE" || return 1
    sh -n "$STAGE" >/dev/null 2>&1 || return 1
}

fetch() {
    _label=$1
    shift
    rm -f "$STAGE"
    printf '[bootstrap] Downloading setup.sh via %s (connect 7s, total 25s)...\n' "$_label"
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
    printf '[bootstrap] Executing validated setup.sh (ref: %s)\n' "$REF"
    sh "$STAGE"
    _rc=$?
    printf '[bootstrap] setup.sh finished (exit %s)\n' "$_rc"
    exit "$_rc"
fi

printf '[ERROR] Could not fetch valid KAS setup.sh from raw or Contents API; no script executed.\n' >&2
exit 1
