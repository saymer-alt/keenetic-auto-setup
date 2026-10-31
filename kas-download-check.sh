#!/bin/sh

# kas-download-check.sh v0.1.0
#
# Read-only staged diagnostic of KAS script download and GitHub reachability
# (issues #158, #266, #270). It checks the delivery chain stage by stage:
# tools/capabilities -> device time/CA notes -> DNS -> TCP -> TLS/HTTP ->
# bounded transfer -> received-file validation, and reports GitHub RAW
# (normal, IPv4/X25519 compatibility, wget), GitHub Contents API and an
# optional mirror separately, because a single alternative success does not
# prove one shared cause.
#
# The tool changes nothing: no DNS, routes, firewall, interfaces, ProxyN,
# Mihomo, MagiTrickle or configuration. Downloaded bytes are never executed.
# It never prints subscription URLs, passwords, tokens or YAML content.
# This is an explicit diagnostic mode; the regular Doctor does not probe
# external networks.
#
# Exit codes: 0 = at least one source fully valid; 1 = no source valid;
# 2 = usage error.

set -u

PROG_NAME="kas-download-check.sh"
PROG_VERSION="0.1.0"
REPO="saymer-alt/keenetic-auto-setup"
REF="stable"
SCRIPT="setup.sh"
REPORT_FILE=""
PROBE_MIRROR=0
BRIEF=0
RAW_HOST="raw.githubusercontent.com"
API_HOST="api.github.com"
CONNECT_TIMEOUT=7
TOTAL_TIMEOUT=25
MAX_FILESIZE=262144

# Terminal status colors are presentation only (docs/18). Semantic prefixes
# remain the source of truth; NO_COLOR/TERM=dumb and non-TTY keep it plain.
COLOR_RESET=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_RED=""
COLOR_CYAN=""
if [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    if [ -t 1 ] 2>/dev/null; then
        COLOR_RESET=$(printf '\033[0m')
        COLOR_GREEN=$(printf '\033[1;32m')
        COLOR_YELLOW=$(printf '\033[1;33m')
        COLOR_RED=$(printf '\033[1;31m')
        COLOR_CYAN=$(printf '\033[1;36m')
    fi
fi

pass_out() { printf '%s[PASS]%s %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$1"; }
fail_out() { printf '%s[FAIL]%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$1" >&2; }
unknown_out() { printf '%s[UNKNOWN]%s %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$1"; }
nt_out() { printf '%s[NOT TESTED]%s %s\n' "$COLOR_CYAN" "$COLOR_RESET" "$1"; }
unsupported_out() { printf '%s[UNSUPPORTED]%s %s\n' "$COLOR_CYAN" "$COLOR_RESET" "$1"; }
info_out() { printf '%s[INFO]%s %s\n' "$COLOR_CYAN" "$COLOR_RESET" "$1"; }

usage() {
    cat <<USAGE
$PROG_NAME v$PROG_VERSION

Read-only diagnostic of KAS script download and GitHub reachability.
Nothing is modified; downloaded bytes are validated, never executed.

Usage:
  sh $PROG_NAME [options]

Options:
  --ref <ref>          GitHub ref to probe (default: stable)
  --script <name>      setup.sh (default) or config-import.sh
  --report <file>      also write the full report to <file> (bounded, no secrets)
  --moshub             additionally probe the optional mirror URL from
                       KAS_MOSHUB_URL if it is set (no verified public
                       Mos.Hub mirror is recorded in this repository, so the
                       default result for it is NOT TESTED)
  --brief              print only the final verdict and next steps
  -h, --help           this help

Statuses: PASS / FAIL / UNKNOWN / NOT TESTED / UNSUPPORTED
Exit codes: 0 at least one source fully valid; 1 none valid; 2 usage error.
USAGE
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

while [ "$#" -gt 0 ]; do
    case "$1" in
        --ref)
            [ "$#" -ge 2 ] || { fail_out "--ref requires a value"; exit 2; }
            case "$2" in
                ''|*[!A-Za-z0-9._/-]*) fail_out "Unsupported --ref: $2"; exit 2 ;;
            esac
            REF="$2"; shift ;;
        --script)
            [ "$#" -ge 2 ] || { fail_out "--script requires a value"; exit 2; }
            case "$2" in
                setup.sh|config-import.sh) SCRIPT="$2" ;;
                *) fail_out "Unsupported --script: $2 (allowed: setup.sh, config-import.sh)"; exit 2 ;;
            esac
            shift ;;
        --report)
            [ "$#" -ge 2 ] || { fail_out "--report requires a value"; exit 2; }
            REPORT_FILE="$2"; shift ;;
        --moshub) PROBE_MIRROR=1 ;;
        --brief) BRIEF=1 ;;
        *) usage >&2; fail_out "Unknown option: $1"; exit 2 ;;
    esac
    shift
done

RAW_URL="https://$RAW_HOST/$REPO/$REF/$SCRIPT"
API_URL="https://$API_HOST/repos/$REPO/contents/$SCRIPT?ref=$REF"

section() { printf '\n=== %s ===\n' "$1"; }

# Full-report sink: every stage writes through rep() so --report captures the
# same evidence without duplicating print statements.
REP_TARGET=""
rep() {
    printf '%s\n' "$1"
    [ -z "$REP_TARGET" ] || printf '%s\n' "$1" >> "$REP_TARGET"
}

if [ -n "$REPORT_FILE" ]; then
    case "$REPORT_FILE" in
        */*)
            REP_DIR=${REPORT_FILE%/*}
            [ -d "$REP_DIR" ] || { fail_out "report directory does not exist: $REP_DIR"; exit 2; }
            ;;
    esac
    : > "$REPORT_FILE" 2>/dev/null && REP_TARGET="$REPORT_FILE" || {
        fail_out "cannot write report file: $REPORT_FILE"; exit 2;
    }
fi

section "KAS download check"
rep "Tool:     $PROG_NAME v$PROG_VERSION"
rep "Repo:     $REPO"
rep "Ref:      $REF"
rep "Script:   $SCRIPT"
rep "Raw URL:  $RAW_URL"
rep "API URL:  $API_URL"
rep "Limits:   connect ${CONNECT_TIMEOUT}s, total ${TOTAL_TIMEOUT}s per attempt, max ${MAX_FILESIZE} bytes"
rep "Read-only: nothing on this router is changed; downloads are never executed."

section "Tools and capabilities"
CURL=""
CURL_HAS_CURVES=0
if command -v curl >/dev/null 2>&1; then
    CURL=$(command -v curl)
    rep "curl:     $CURL"
    rep "version:  $($CURL --version 2>/dev/null | head -n 1)"
    if $CURL --help all 2>/dev/null | grep -q -- '--curves'; then
        CURL_HAS_CURVES=1
        rep "capability: --curves supported"
    else
        rep "capability: --curves NOT advertised by this curl (IPv4/X25519 compatibility attempt will be reported UNSUPPORTED)"
    fi
else
    unsupported_out "curl is not installed; nothing can be probed. Install it with: opkg update && opkg install curl"
    rep "curl:     MISSING"
fi
WGET=""
if command -v wget >/dev/null 2>&1; then
    WGET=$(command -v wget)
    rep "wget:     $WGET"
else
    rep "wget:     not installed (optional; its source will be NOT TESTED)"
fi
NSLOOKUP=""
if command -v nslookup >/dev/null 2>&1; then
    NSLOOKUP=$(command -v nslookup)
    rep "nslookup: $NSLOOKUP"
else
    rep "nslookup: not installed (optional; DNS stage will be UNKNOWN, TCP/TLS stages still run)"
fi

section "Device time and CA notes"
NOW_EPOCH=$(date +%s 2>/dev/null || true)
NOW_HUMAN=$(date 2>/dev/null || true)
rep "date:     $NOW_HUMAN (epoch: ${NOW_EPOCH:-unknown})"
if [ -z "$NOW_EPOCH" ]; then
    unknown_out "system date is not readable; TLS certificate validation may fail for time reasons"
fi
CA_FOUND=""
for ca in /opt/etc/ssl/cert.pem /etc/ssl/cert.pem /opt/etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt; do
    if [ -s "$ca" ]; then
        CA_FOUND="$ca"
        rep "CA bundle found: $ca"
        break
    fi
done
[ -n "$CA_FOUND" ] || rep "CA bundle: none of the common Entware paths found (install.sh normally installs the ca-bundle package); TLS results will show the observed exit code either way"

# Downloaded bytes go to a private stage; nothing is executed from it.
umask 077
TMPDIR_KAS=${TMPDIR:-/tmp}
STAGE=""
if command -v mktemp >/dev/null 2>&1; then
    STAGE=$(mktemp "$TMPDIR_KAS/kas-dl-check.XXXXXXXX" 2>/dev/null) || STAGE=""
fi
[ -n "$STAGE" ] || STAGE="$TMPDIR_KAS/kas-dl-check.$$"
trap 'rm -f "$STAGE"' 0
trap 'exit 130' INT
trap 'exit 143' TERM

classify_curl_rc() {
    # $1 = curl exit code; prints a short human classification.
    case "$1" in
        0)  printf 'transfer completed' ;;
        6)  printf 'DNS resolution failed' ;;
        7)  printf 'TCP connection failed (refused/unreachable)' ;;
        28) printf 'timed out (connect or total limit)' ;;
        35) printf 'TLS handshake failed (observed field case #255)' ;;
        47) printf 'too many redirects' ;;
        18) printf 'connection dropped mid-transfer (partial file)' ;;
        22) printf 'HTTP error status (see http_code)' ;;
        60) printf 'TLS certificate verification failed (check device date and ca-bundle)' ;;
        *)  printf 'curl reported an error; see exit code' ;;
    esac
}

valid_download() {
    [ -s "$STAGE" ] || return 1
    [ "$(head -n 1 "$STAGE" 2>/dev/null)" = '#!/bin/sh' ] || return 1
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
    return 0
}

# probe_curl <label> <url> [extra curl args...]
# Fetches the URL into the shared stage, prints PASS/FAIL/UNKNOWN with the
# stage-level reason, http_code, size and duration. Never executes bytes.
probe_curl() {
    local _label=$1 _url=$2 _rc _out _err _http _size _dur
    shift 2
    : > "$STAGE" 2>/dev/null || { fail_out "$_label: cannot prepare stage file"; return 1; }
    rep "--- $_label"
    rep "args:     curl -o <stage> -sS --connect-timeout $CONNECT_TIMEOUT --max-time $TOTAL_TIMEOUT --max-filesize $MAX_FILESIZE $* <url>"
    _out=$("$CURL" -o "$STAGE" -sS --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$TOTAL_TIMEOUT" --max-filesize "$MAX_FILESIZE" \
        -w '%{http_code} %{size_download} %{time_total}' \
        "$@" "$_url" 2>"$TMPDIR_KAS/kas-dl-check.err.$$" </dev/null)
    _rc=$?
    _err=$(cat "$TMPDIR_KAS/kas-dl-check.err.$$" 2>/dev/null || true)
    rm -f "$TMPDIR_KAS/kas-dl-check.err.$$"
    _http=$(printf '%s' "$_out" | awk '{print $1}')
    _size=$(printf '%s' "$_out" | awk '{print $2}')
    _dur=$(printf '%s' "$_out" | awk '{print $3}')
    rep "result:   exit=$_rc http_code=${_http:-n/a} size=${_size:-n/a} time=${_dur:-n/a}"
    [ -n "$_err" ] && rep "stderr:   $_err"
    if [ "$_rc" -eq 0 ]; then
        if valid_download; then
            pass_out "$_label: HTTP ${_http:-?}, ${_size:-?} bytes in ${_dur:-?}s; shebang, project markers and sh -n OK (bytes NOT executed)"
            return 0
        fi
        case "${_http:-}" in
            4*|5*) fail_out "$_label: HTTP ${_http:-?} — service returned an error page instead of the KAS $SCRIPT; nothing was executed" ;;
            *)     fail_out "$_label: transfer completed but the file does not look like the KAS $SCRIPT (shebang/markers/sh -n failed); nothing was executed" ;;
        esac
        return 1
    fi
    if [ "$_rc" -eq 18 ]; then
        fail_out "$_label: $(classify_curl_rc "$_rc") (got ${_size:-0} bytes)"
    else
        fail_out "$_label: exit $_rc — $(classify_curl_rc "$_rc")"
    fi
    return 1
}

probe_wget() {
    local _label="wget raw" _rc _out
    : > "$STAGE" 2>/dev/null || { fail_out "$_label: cannot prepare stage file"; return 1; }
    rep "--- $_label"
    rep "args:     wget -q -O <stage> -T $TOTAL_TIMEOUT <url>"
    _out=$("$WGET" -q -O "$STAGE" -T "$TOTAL_TIMEOUT" "$RAW_URL" 2>&1 </dev/null)
    _rc=$?
    [ -n "$_out" ] && rep "stderr:   $_out"
    if [ "$_rc" -eq 0 ]; then
        if valid_download; then
            pass_out "$_label: transfer OK; shebang, project markers and sh -n OK (bytes NOT executed)"
            return 0
        fi
        fail_out "$_label: transfer completed but the file does not look like the KAS $SCRIPT; nothing was executed"
        return 1
    fi
    fail_out "$_label: wget exit $_rc"
    return 1
}

section "DNS resolution"
DNS_RESULT="UNKNOWN"
if [ -n "$NSLOOKUP" ]; then
    DNS_OK_COUNT=0
    for h in "$RAW_HOST" "$API_HOST"; do
        if "$NSLOOKUP" "$h" >/dev/null 2>&1 </dev/null; then
            rep "$h: resolved"
            DNS_OK_COUNT=$((DNS_OK_COUNT+1))
        else
            rep "$h: resolution FAILED"
        fi
    done
    if [ "$DNS_OK_COUNT" -eq 2 ]; then
        pass_out "both $RAW_HOST and $API_HOST resolve"
        DNS_RESULT="PASS"
    elif [ "$DNS_OK_COUNT" -eq 0 ]; then
        fail_out "neither $RAW_HOST nor $API_HOST resolves; downstream results are expected to fail at the DNS stage"
        DNS_RESULT="FAIL"
    else
        unknown_out "only one of $RAW_HOST/$API_HOST resolves"
        DNS_RESULT="UNKNOWN"
    fi
else
    nt_out "nslookup unavailable; DNS stage left UNKNOWN (curl results below still show the effective outcome)"
    rep "DNS: NOT TESTED (no resolver utility)"
fi

section "TCP connect (443)"
if [ -n "$CURL" ]; then
    for h in "$RAW_HOST" "$API_HOST"; do
        _tcp_out=$("$CURL" -sS -o /dev/null --connect-timeout "$CONNECT_TIMEOUT" --max-time 5 "telnet://$h:443" 2>&1 </dev/null)
        _tcp_rc=$?
        _tcp_note=""
        [ -n "$_tcp_out" ] && _tcp_note=" [$(printf '%s' "$_tcp_out" | head -c 120)]"
        rep "telnet://$h:443 -> exit=$_tcp_rc ($(classify_curl_rc "$_tcp_rc"))$_tcp_note"
        case "$_tcp_rc" in
            28) pass_out "$h:443 TCP connection established (probe then timed out by design)" ;;
            7)  fail_out "$h:443 TCP connection failed" ;;
            *)  unknown_out "$h:443 TCP stage inconclusive (curl exit $_tcp_rc)" ;;
        esac
    done
else
    nt_out "TCP stage skipped: curl is missing"
fi

section "Source-by-source probe (TLS/HTTP/content)"
ANY_PASS=0

if [ -n "$CURL" ]; then
    if probe_curl "RAW normal TLS" "$RAW_URL"; then
        ANY_PASS=1
    fi
    if [ "$CURL_HAS_CURVES" -eq 1 ]; then
        if probe_curl "RAW IPv4 + X25519 compatibility" "$RAW_URL" -4 --curves X25519; then
            [ "$ANY_PASS" -eq 0 ] && rep "compatibility transport delivered a valid script while earlier attempts had not"
            ANY_PASS=1
        fi
    else
        unsupported_out "RAW IPv4 + X25519 compatibility: this curl does not advertise --curves"
    fi
    if [ -n "$WGET" ]; then
        if probe_wget; then
            [ "$ANY_PASS" -eq 0 ] && rep "wget delivered a valid script while earlier attempts had not"
            ANY_PASS=1
        fi
    else
        nt_out "wget raw: wget is not installed"
    fi
    if probe_curl "GitHub Contents API (raw media)" "$API_URL" -H 'Accept: application/vnd.github.raw+json' -H 'X-GitHub-Api-Version: 2022-11-28'; then
        [ "$ANY_PASS" -eq 0 ] && rep "Contents API delivered a valid script while earlier attempts had not"
        ANY_PASS=1
    fi
    if [ "$PROBE_MIRROR" -eq 1 ]; then
        if [ -n "${KAS_MOSHUB_URL:-}" ]; then
            if probe_curl "Optional mirror (KAS_MOSHUB_URL)" "$KAS_MOSHUB_URL"; then
                ANY_PASS=1
            fi
        else
            nt_out "Optional mirror: --moshub requested but KAS_MOSHUB_URL is not set; nothing probed"
        fi
    else
        nt_out "Optional mirror (Mos.Hub): not probed (no verified public mirror is recorded in this repository); use --moshub with KAS_MOSHUB_URL to probe one"
    fi
else
    nt_out "Source probes skipped: curl is missing"
fi

section "Verdict"
if [ "$ANY_PASS" -eq 1 ]; then
    pass_out "At least one delivery source returned a valid KAS $SCRIPT. Script download from this router works (at least via the sources marked PASS above)."
    FINAL_RC=0
else
    fail_out "No delivery source returned a valid KAS $SCRIPT. Compare the failing stages above: consistent DNS failure points at resolver setup; TCP failure at routing/provider; exit 35 at TLS handshake (docs/03 documents the IPv4+X25519 compatibility case); exit 60 at device clock/CA bundle; HTTP 404 at ref/URL; HTTP 5xx at the service. These are stage-level hypotheses, not proven causes."
    rep "Next steps (read-only suggestions):"
    rep "  1. Check device date/time correctness; wrong clock is a common TLS-verification failure."
    rep "  2. Ensure the ca-bundle package is installed (opkg list-installed | grep ca-bundle)."
    rep "  3. Retry the normal install command; installers retry with IPv4/X25519 and Contents API automatically."
    rep "  4. See docs/03-install.md advanced first-fetch and the SCP/offline path when GitHub is fully unreachable."
    FINAL_RC=1
fi

if [ "${DNS_RESULT:-}" = "FAIL" ]; then
    info_out "DNS stage failed; every networked result above is consistent with resolver failure first."
fi

if [ -n "$REP_TARGET" ]; then
    info_out "Full report written to $REP_TARGET"
fi

exit "$FINAL_RC"
