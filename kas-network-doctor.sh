#!/bin/sh

# kas-network-doctor.sh v0.1.0
#
# Explicit staged network diagnostic for KeeneticOS + Entware (issues #158,
# #166, #266, #270). Unlike the regular local Doctor, this tool PERFORMS
# network probes - and it does so only when the user explicitly runs it.
# For one user-supplied target it walks the delivery chain DNS -> TCP ->
# TLS -> HTTP, then reports the observed direct egress address, the local
# Mihomo path (SOCKS port, read-only Controller lookups, SOCKS5h target
# probe, SOCKS5h egress address) and read-only MagiTrickle/Keenetic ProxyN
# evidence.
#
# The tool changes nothing: no DNS, routes, firewall, interfaces, ProxyN,
# policies, Mihomo, MagiTrickle or configuration. Certificate verification
# is never disabled. The secret in MIHOMO_API_SECRET is never printed and
# selected proxy-server names are withheld, so reports are safe to share.
#
# Status vocabulary is stable: PASS / FAIL / UNKNOWN / NOT TESTED /
# UNSUPPORTED. Facts are separated from hypotheses: the verdict names only
# the confirmed failing stage; everything else is labeled H: (hypothesis).
#
# Vantage limitation (explicit, never hidden): every observation is made
# from the router. A success does NOT prove that a particular LAN client
# resolves, routes or is classified the same way (issue #270 scenario); the
# client.vantage check stays NOT TESTED by design. UDP transport beyond the
# implicit resolver exercise is UNSUPPORTED in this version and is reported
# as such instead of a fabricated PASS.
#
# Output: human report plus optional machine-readable JSON contract
# network-diagnostics/v1 (--json FILE; plain POSIX sh; jq is not required
# to produce it).
#
# Exit codes: 0 = target chain confirmed (required stages PASS, HTTP answered
# with any status); 1 = a required chain stage FAILed; 2 = usage error;
# 3 = inconclusive (nothing FAILed, but the chain never completed either -
# missing tools, timeouts or exhausted request budget).
#
# External request budget: <= 12 small requests per run (DNS queries count),
# each bounded by --connect-timeout/--max-time/--max-filesize. Downloaded
# bytes are never executed.

set -u

PROG_NAME="kas-network-doctor.sh"
PROG_VERSION="0.1.0"
SCHEMA="network-diagnostics/v1"

TARGET_INPUT=""
TARGET_SCHEME="https"
TARGET_HOST=""
TARGET_PORT=""
TARGET_PORT_CLI=""
TARGET_PATH="/"
PROBE_URL=""
DNS_SERVER=""
DO_EGRESS=1
JSON_FILE=""
REPORT_FILE=""
BRIEF=0

CONTROLLER_URL="${MIHOMO_CONTROLLER_URL:-http://127.0.0.1:9090}"
MIHOMO_SECRET="${MIHOMO_API_SECRET:-}"
SOCKS_HOST="${MIHOMO_SOCKS_HOST:-127.0.0.1}"
SOCKS_PORT="${MIHOMO_SOCKS_PORT:-7890}"
PROXY_GROUP="${MIHOMO_PROXY_GROUP:-GLOBAL}"

CONNECT_TIMEOUT=6
REQ_TIMEOUT=15
MAX_BYTES=262144
MAX_REQUESTS=12
REQUESTS_USED=0

EGRESS_URL="https://api.ipify.org"
DNS_QUERY_TIMEOUT=6

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

pass_out()    { printf '%s[PASS]%s %s\n'        "$COLOR_GREEN"  "$COLOR_RESET" "$1"; }
fail_out()    { printf '%s[FAIL]%s %s\n'        "$COLOR_RED"    "$COLOR_RESET" "$1"; }
unknown_out() { printf '%s[UNKNOWN]%s %s\n'     "$COLOR_YELLOW" "$COLOR_RESET" "$1"; }
nt_out()      { printf '%s[NOT TESTED]%s %s\n'  "$COLOR_CYAN"   "$COLOR_RESET" "$1"; }
unsup_out()   { printf '%s[UNSUPPORTED]%s %s\n' "$COLOR_CYAN"   "$COLOR_RESET" "$1"; }
info_out()    { printf '%s[INFO]%s %s\n'        "$COLOR_CYAN"   "$COLOR_RESET" "$1"; }

usage() {
    cat <<USAGE
$PROG_NAME v$PROG_VERSION

Explicit staged network diagnostic. Network probes run only because you
started this tool. Read-only: nothing on the router is changed, certificate
verification is never disabled, downloaded bytes are never executed.

Usage:
  sh $PROG_NAME --target <domain|IP|URL> [options]

Options:
  --target <arg>    target to diagnose (required). Examples: example.com,
                    192.0.2.10, https://example.com/path
  --port <n>        TCP port override. Priority: --port > the port inside
                    the target URL > the scheme default (443/80). The URL
                    path/query is probed as given; the query is never printed
  --dns-server <h>  additionally resolve the target against this DNS server
  --no-egress       skip the small egress-address observation (api.ipify.org)
  --json <file>     also write the network-diagnostics/v1 JSON report
  --report <file>   also write the human-readable report to <file>
  --brief           print only stage statuses and the verdict
  -h, --help        this help

Environment (read-only inputs): MIHOMO_CONTROLLER_URL, MIHOMO_API_SECRET,
MIHOMO_SOCKS_HOST, MIHOMO_SOCKS_PORT, MIHOMO_PROXY_GROUP.

Statuses: PASS / FAIL / UNKNOWN / NOT TESTED / UNSUPPORTED
Exit codes: 0 chain confirmed; 1 confirmed chain failure; 2 usage error;
3 inconclusive (nothing confirmed either way).
The secret in MIHOMO_API_SECRET is never printed; selected proxy-server
names are withheld from all output (safe for shared reports).
USAGE
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

while [ "$#" -gt 0 ]; do
    case "$1" in
        --target)
            [ "$#" -ge 2 ] || { fail_out "--target requires a value"; exit 2; }
            TARGET_INPUT=$2; shift ;;
        --port)
            [ "$#" -ge 2 ] || { fail_out "--port requires a value"; exit 2; }
            case "$2" in ''|*[!0-9]*|0*) fail_out "--port expects 1..65535: $2"; exit 2 ;; esac
            [ "$2" -le 65535 ] || { fail_out "--port expects 1..65535: $2"; exit 2; }
            TARGET_PORT_CLI=$2; shift ;;
        --dns-server)
            [ "$#" -ge 2 ] || { fail_out "--dns-server requires a value"; exit 2; }
            case "$2" in ''|*[!A-Za-z0-9._:-]*) fail_out "Unsupported --dns-server: $2"; exit 2 ;; esac
            DNS_SERVER=$2; shift ;;
        --no-egress) DO_EGRESS=0 ;;
        --json)
            [ "$#" -ge 2 ] || { fail_out "--json requires a value"; exit 2; }
            JSON_FILE=$2; shift ;;
        --report)
            [ "$#" -ge 2 ] || { fail_out "--report requires a value"; exit 2; }
            REPORT_FILE=$2; shift ;;
        --brief) BRIEF=1 ;;
        *) usage >&2; fail_out "Unknown option: $1"; exit 2 ;;
    esac
    shift
done

case "$TARGET_INPUT" in
    '') fail_out "--target is required"; exit 2 ;;
esac
if printf '%s' "$TARGET_INPUT" | LC_ALL=C grep -q "[^A-Za-z0-9._~:/?#@!&()*+,;=%-]"; then
    fail_out "Unsupported characters in target: $(sanitize_url "$TARGET_INPUT")"
    exit 2
fi

section() { printf '\n=== %s ===\n' "$1"; }

# Full-report sink: stages write through rep() so --report captures the same
# evidence without duplicating print statements.
REP_TARGET=""
rep() {
    [ "$BRIEF" -eq 1 ] || printf '%s\n' "$1"
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

# ---------------------------------------------------------------
# Check registry: counters plus network-diagnostics/v1 records.
# record() is the single source of truth for stage statuses; stage
# functions compute STATUS/DETAIL globals and then call record().
# ---------------------------------------------------------------
N_PASS=0; N_FAIL=0; N_UNKNOWN=0; N_NT=0; N_UNSUP=0
CHECK_RECORDS=""

json_escape() {
    # Single-line JSON string escape for network-diagnostics/v1.
    # Callers pass single-line text; stray newlines are flattened,
    # backslash and quote are escaped, remaining control bytes are
    # replaced instead of being emitted raw.
    printf '%s' "$1" | tr '\n' ' ' | awk '
    {
        gsub(/\\/, "\\\\")
        gsub(/"/, "\\\"")
        gsub(/[\001-\037\177]/, "?")
        printf "%s", $0
    }'
}

sanitize_url() {
    # URL form safe for shareable reports: credentials, the query and the
    # whole non-root path are withheld; scheme://host[:port]/ stays
    # readable. The probe itself always uses the full URL.
    _su=$1
    _sq=""
    case "$_su" in
        *"?"*) _sq=1 ;;
    esac
    _su=$(printf '%s' "$_su" | sed 's#//[^/@]*@#//[credentials withheld]@#')
    _su=$(printf '%s' "$_su" | sed 's/[?#].*$//')
    case "$_su" in
        *://*)
            _scheme=${_su%%://*}
            _rest=${_su#*://}
            _authority=${_rest%%/*}
            _tail=${_rest#"$_authority"}
            case "$_tail" in
                ''|/) _su="${_scheme}://${_authority}/" ;;
                *)     _su="${_scheme}://${_authority}/[path withheld]" ;;
            esac
            ;;
    esac
    [ -n "$_sq" ] && _su="${_su}?[query withheld]"
    printf '%s' "$_su"
}

split_rinfo() {
    # probe_http write-out "code|url|redirect_url" -> R_CODE/R_URL/R_RURL
    R_CODE=${R_INFO%%|*}
    _rest=${R_INFO#*|}
    R_URL=${_rest%%|*}
    R_RURL=${_rest#*|}
    [ "$R_RURL" = "$_rest" ] && R_RURL=""
    R_URL=$(printf '%s' "$R_URL" | head -c 300)
    R_RURL=$(printf '%s' "$R_RURL" | head -c 300)
    return 0
}

record() {
    # record <id> <status> <detail> [observed]
    _id=$1; _st=$2; _det=$3; _obs=${4:-}
    case "$_st" in
        PASS)        N_PASS=$((N_PASS+1)) ;;
        FAIL)        N_FAIL=$((N_FAIL+1)) ;;
        UNKNOWN)     N_UNKNOWN=$((N_UNKNOWN+1)) ;;
        "NOT TESTED") N_NT=$((N_NT+1)) ;;
        UNSUPPORTED) N_UNSUP=$((N_UNSUP+1)) ;;
        *) return 0 ;;
    esac
    _rec=$(printf '{"id":"%s","status":"%s","detail":"%s"' \
        "$(json_escape "$_id")" "$_st" "$(json_escape "$_det")")
    if [ -n "$_obs" ]; then
        _rec=$_rec$(printf ',"observed":"%s"' "$(json_escape "$_obs")")
    fi
    _rec=$_rec"}"
    case "$CHECK_RECORDS" in
        '') CHECK_RECORDS=$_rec ;;
        *)  CHECK_RECORDS="$CHECK_RECORDS,$_rec" ;;
    esac
    return 0
}

# ---------------------------------------------------------------
# Bounded helpers. ALL network access goes through these two plus
# the dedicated DNS lookup. Both enforce the request budget and
# return 9 when it is exhausted (callers map that to NOT TESTED).
# probe_http <label> <url> [extra curl args...]  -> R_RC, R_INFO
# fetch_small <label> <url> [extra curl args...] -> R_RC, R_BODY
# ---------------------------------------------------------------
CURL=""
ERR_FILE=${TMPDIR:-/tmp}/kas-net-doctor.err.$$
R_RC=0; R_INFO=""; R_BODY=""

budget_left() { [ "$REQUESTS_USED" -lt "$MAX_REQUESTS" ]; }

probe_http() {
    _label=$1; _url=$2; shift 2
    R_RC=0; R_INFO=""
    [ -n "$CURL" ] || return 9
    budget_left || { rep "$_label: request budget exhausted ($MAX_REQUESTS), NOT TESTED"; return 9; }
    REQUESTS_USED=$((REQUESTS_USED+1))
    _show=""
    _prev=""
    for _a in "$@"; do
        case $_prev in
            -H) case $_a in
                    Authorization:*) _show=$_show" -H [authorization header]" ;;
                    *) _show=$_show" -H [header]" ;;
                esac ;;
            -H) : ;;
                *) _show=$_show" $_a" ;;
        esac
        _prev=$_a
    done
    rep "--- $_label"
    rep "request:  curl --connect-timeout $CONNECT_TIMEOUT --max-time $REQ_TIMEOUT --max-filesize $MAX_BYTES$_show <url>  ($REQUESTS_USED/$MAX_REQUESTS)"
    R_INFO=$("$CURL" -sS -o /dev/null --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$REQ_TIMEOUT" --max-filesize "$MAX_BYTES" \
        -w "%{http_code}|%{url_effective}|%{redirect_url}" "$@" "$_url" 2>"$ERR_FILE" </dev/null)
    R_RC=$?
    _err=$(cat "$ERR_FILE" 2>/dev/null || true)
    [ -n "$_err" ] && rep "stderr:   $(printf '%s' "$_err" | sed 's#//[^/@]*@#//[credentials withheld]@#')"
    case "$R_INFO" in
        *\|*)
            _rc_code=${R_INFO%%|*}
            _rc_rest=${R_INFO#*|}
            _rc_url=${_rc_rest%%|*}
            case "$_rc_rest" in
                *\|*) _rc_rurl=${_rc_rest#*|} ;;
                *) _rc_rurl="" ;;
            esac
            rep "result:   exit=$R_RC http_code=$_rc_code url=$(sanitize_url "$_rc_url")${_rc_rurl:+ redirect=$(sanitize_url "$_rc_rurl")}"
            ;;
        *) rep "result:   exit=$R_RC" ;;
    esac
    return 0
}

fetch_small() {
    _label=$1; _url=$2; shift 2
    R_RC=0; R_BODY=""
    [ -n "$CURL" ] || return 9
    budget_left || { rep "$_label: request budget exhausted ($MAX_REQUESTS), NOT TESTED"; return 9; }
    REQUESTS_USED=$((REQUESTS_USED+1))
    _show=""
    _prev=""
    for _a in "$@"; do
        case $_prev in
            -H) case $_a in
                    Authorization:*) _show=$_show" -H [authorization header]" ;;
                    *) _show=$_show" -H [header]" ;;
                esac ;;
            -H) : ;;
                *) _show=$_show" $_a" ;;
        esac
        _prev=$_a
    done
    rep "--- $_label"
    rep "request:  curl --connect-timeout $CONNECT_TIMEOUT --max-time $REQ_TIMEOUT --max-filesize 64$_show <url>  ($REQUESTS_USED/$MAX_REQUESTS)"
    # the body goes to a file so the REAL curl exit code survives the
    # head(1) trim; $? of a pipeline would be head's, not curl's
    BODY_FILE=$ERR_FILE.body
    "$CURL" -sS --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$REQ_TIMEOUT" --max-filesize 64 \
        -o "$BODY_FILE" "$@" "$_url" 2>"$ERR_FILE" </dev/null
    R_RC=$?
    R_BODY=$(head -c 128 "$BODY_FILE" 2>/dev/null || true)
    rm -f "$BODY_FILE" 2>/dev/null
    _err=$(cat "$ERR_FILE" 2>/dev/null || true)
    [ -n "$_err" ] && rep "stderr:   $(printf '%s' "$_err" | sed 's#//[^/@]*@#//[credentials withheld]@#')"
    rep "result:   exit=$R_RC body=${R_BODY:+present}"
    return 0
}

trap 'rm -f "$ERR_FILE" 2>/dev/null; exit' INT
trap 'rm -f "$ERR_FILE" 2>/dev/null; exit' TERM

# ---------------------------------------------------------------
# Tool inventory
# ---------------------------------------------------------------
section "Tools"
if command -v curl >/dev/null 2>&1; then
    CURL=$(command -v curl)
    CURL_VER=$("$CURL" --version 2>/dev/null | head -n 1)
    rep "curl:     $CURL"
    rep "version:  $CURL_VER"
    record "tools.curl" "PASS" "curl available" "version: $CURL_VER"
else
    rep "curl:     MISSING"
    record "tools.curl" "UNSUPPORTED" "curl is not installed; install it with: opkg update && opkg install curl"
fi
NSLOOKUP=""
if command -v nslookup >/dev/null 2>&1; then
    NSLOOKUP=$(command -v nslookup)
    rep "nslookup: $NSLOOKUP"
else
    rep "nslookup: not installed (DNS stage UNSUPPORTED; curl still resolves independently)"
fi
NDMC=""
if command -v ndmc >/dev/null 2>&1; then
    NDMC=$(command -v ndmc)
    rep "ndmc:     $NDMC"
else
    rep "ndmc:     not found (Keenetic ProxyN evidence stage NOT TESTED)"
fi
JQ=""
if command -v jq >/dev/null 2>&1; then
    JQ=$(command -v jq)
    rep "jq:       $JQ"
else
    rep "jq:       not found (Controller group selection readout NOT TESTED)"
fi
PORT_TOOL=""
if command -v netstat >/dev/null 2>&1; then
    PORT_TOOL=$(command -v netstat)
elif command -v ss >/dev/null 2>&1; then
    PORT_TOOL=$(command -v ss)
fi
[ -n "$PORT_TOOL" ] && rep "netstat/ss: $PORT_TOOL" || rep "netstat/ss: not found (listen check falls back to probe results)"
DNS_TO=""
if command -v timeout >/dev/null 2>&1; then
    DNS_TO=$(command -v timeout)
    rep "dns timeout: probes limited to ${DNS_QUERY_TIMEOUT}s via $DNS_TO"
else
    rep "dns timeout: no timeout wrapper found; a dead resolver can stall the DNS probe"
fi
PGREP=""
if command -v pgrep >/dev/null 2>&1; then
    PGREP=$(command -v pgrep)
elif command -v pidof >/dev/null 2>&1; then
    PGREP=$(command -v pidof)
fi
[ -n "$PGREP" ] && rep "pgrep/pidof: $PGREP" || rep "pgrep/pidof: not found (process presence UNKNOWN)"
rep "Read-only: nothing on this router is changed; certificate verification is never disabled."

# ---------------------------------------------------------------
# Target normalization
# ---------------------------------------------------------------
section "Target"
case "$TARGET_INPUT" in
    http://*|https://*)
        case "$TARGET_INPUT" in
            https://*) TARGET_SCHEME="https" ;;
            *)         TARGET_SCHEME="http" ;;
        esac
        # authority (userinfo stripped) and the actual path/query are
        # preserved: the tool must probe the resource the user named
        _authority=$(printf '%s' "$TARGET_INPUT" | sed 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#[/?#].*$##')
        TARGET_PATH=$(printf '%s' "$TARGET_INPUT" | sed 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#^[^/?]*##')
        _authority=$(printf '%s' "$_authority" | sed 's#^[^/@]*@##')
        case "$_authority" in
            '['*) fail_out "IPv6 literal targets are not supported: $(sanitize_url "$TARGET_INPUT")"; rm -f "$ERR_FILE"; exit 2 ;;
            *:*)
                TARGET_HOST=${_authority%%:*}
                TARGET_PORT=${_authority#*:}
                case "$TARGET_PORT" in ''|*[!0-9]*|0*) fail_out "Unsupported port in target URL: $(sanitize_url "$_authority")"; rm -f "$ERR_FILE"; exit 2 ;; esac
                [ "$TARGET_PORT" -le 65535 ] || { fail_out "Unsupported port in target URL: $(sanitize_url "$_authority")"; rm -f "$ERR_FILE"; exit 2; }
                ;;
            *) TARGET_HOST=$_authority ;;
        esac
        ;;
    *)
        case "$TARGET_INPUT" in
            *[!0-9.]*) TARGET_SCHEME="https" ;;
            *)         TARGET_SCHEME="http" ;;
        esac
        TARGET_HOST=$TARGET_INPUT
        TARGET_PATH="/"
        ;;
esac
# port priority: explicit --port > port inside the URL > scheme default
[ -n "$TARGET_PORT_CLI" ] && TARGET_PORT=$TARGET_PORT_CLI
if [ -z "$TARGET_PORT" ]; then
    case "$TARGET_SCHEME" in https) TARGET_PORT=443 ;; *) TARGET_PORT=80 ;; esac
fi
case "$TARGET_HOST" in
    ''|*[!A-Za-z0-9._-]) fail_out "Unsupported host after normalization: '$TARGET_HOST'"; rm -f "$ERR_FILE"; exit 2 ;;
esac
case "$TARGET_PATH" in
    /*) : ;;
    ''|*) TARGET_PATH="/$TARGET_PATH" ;;
esac
case "$TARGET_SCHEME:$TARGET_PORT" in
    https:443) PROBE_URL="https://$TARGET_HOST$TARGET_PATH" ;;
    https:*)   PROBE_URL="https://$TARGET_HOST:$TARGET_PORT$TARGET_PATH" ;;
    http:80)   PROBE_URL="http://$TARGET_HOST$TARGET_PATH" ;;
    http:*)    PROBE_URL="http://$TARGET_HOST:$TARGET_PORT$TARGET_PATH" ;;
esac
rep "Input:   $(sanitize_url "$TARGET_INPUT")"
rep "Host:    $TARGET_HOST"
rep "Port:    $TARGET_PORT"
rep "Probe:   $(sanitize_url "$PROBE_URL")"
rep "Vantage: this router only; a LAN client path is never proven by this tool."

# ---------------------------------------------------------------
# DNS stage (router vantage)
# ---------------------------------------------------------------
DNS_STATUS="NOT TESTED"
DNS_DETAIL="not run"
DNS_OBSERVED=""

classify_resolver_error() {
    # $1 = combined nslookup output -> C_STATUS / C_DETAIL
    case "$1" in
        *NXDOMAIN*)
            C_STATUS="FAIL"; C_DETAIL="NXDOMAIN: the resolver says the name does not exist" ;;
        *SERVFAIL*)
            C_STATUS="FAIL"; C_DETAIL="SERVFAIL: the resolver reports an upstream or server-side failure" ;;
        *REFUSED*)
            C_STATUS="FAIL"; C_DETAIL="REFUSED: the resolver refused the query" ;;
        *"timed out"*|*"no servers could be reached"*|*"connection refused"*|*"Temporary failure in name resolution"*)
            C_STATUS="FAIL"; C_DETAIL="timeout: no DNS answer within the attempt window" ;;
        *)
            C_STATUS="UNKNOWN"; C_DETAIL="resolver returned an unrecognized error" ;;
    esac
}

lookup_host() {
    # lookup_host <host> [server] -> L_STATUS / L_DETAIL / L_ADDRESSES
    L_STATUS="UNSUPPORTED"; L_DETAIL="no resolver utility"; L_ADDRESSES=""
    [ -n "$NSLOOKUP" ] || return 0
    if [ -z "$DNS_TO" ]; then
        # never run an unbounded resolver probe on a slow router
        L_STATUS="NOT TESTED"; L_DETAIL="no timeout wrapper available; the DNS probe was not run to avoid an unbounded wait"
        return 0
    fi
    budget_left || { L_STATUS="NOT TESTED"; L_DETAIL="request budget exhausted"; return 0; }
    REQUESTS_USED=$((REQUESTS_USED+1))
    if [ -n "${2:-}" ]; then
        rep "--- dns lookup via $2"
        if [ -n "$DNS_TO" ]; then
            _out=$("$DNS_TO" "$DNS_QUERY_TIMEOUT" "$NSLOOKUP" "$1" "$2" 2>&1 </dev/null)
        else
            _out=$("$NSLOOKUP" "$1" "$2" 2>&1 </dev/null)
        fi
    else
        rep "--- dns lookup via system resolver"
        if [ -n "$DNS_TO" ]; then
            _out=$("$DNS_TO" "$DNS_QUERY_TIMEOUT" "$NSLOOKUP" "$1" 2>&1 </dev/null)
        else
            _out=$("$NSLOOKUP" "$1" 2>&1 </dev/null)
        fi
    fi
    L_RC=$?
    rep "request:  nslookup $1${2:+ $2}  ($REQUESTS_USED/$MAX_REQUESTS)"
    rep "answer:   $(printf '%s' "$_out" | tr '\n' ' ' | head -c 300)"
    if [ "$L_RC" -eq 124 ]; then
        L_STATUS="FAIL"; L_DETAIL="timeout: no DNS answer within ${DNS_QUERY_TIMEOUT}s (probe terminated by the timeout wrapper)"
    elif [ "$L_RC" -eq 0 ] && ! printf '%s' "$_out" | grep -qi 'NXDOMAIN\|SERVFAIL\|REFUSED'; then
        # answer addresses only: exclude the resolver-server address and
        # busybox-style addr#port server lines
        _srv=$(printf '%s\n' "$_out" | awk 'tolower($1)=="server:"{print $2; exit}')
        L_ADDRESSES=$(printf '%s\n' "$_out" | awk '/^[[:space:]]*Address/{print $NF}' \
            | grep -v '#' | awk -v s="$_srv" 'length($0) > 0 && $0 != s' \
            | head -n 3 | tr '\n' ' ' | sed 's/ $//')
        if [ -n "$L_ADDRESSES" ]; then
            L_STATUS="PASS"; L_DETAIL="resolved"
        else
            L_STATUS="UNKNOWN"; L_DETAIL="exit 0 but no answer Address line recognized (only the resolver server address was seen)"
        fi
    else
        classify_resolver_error "$_out"
        L_STATUS=$C_STATUS; L_DETAIL=$C_DETAIL
    fi
    return 0
}

section "DNS (router vantage)"
case "$TARGET_HOST" in
    *[!0-9.]*)
        if [ -z "$NSLOOKUP" ]; then
            DNS_STATUS="UNSUPPORTED"; DNS_DETAIL="nslookup is not installed"
            unsup_out "dns.router: $DNS_DETAIL; curl results below still show the effective outcome"
        else
            lookup_host "$TARGET_HOST"
            DNS_STATUS=$L_STATUS; DNS_DETAIL=$L_DETAIL; DNS_OBSERVED=$L_ADDRESSES
            case "$DNS_STATUS" in
                PASS) pass_out "dns.router: $TARGET_HOST resolved${DNS_OBSERVED:+ -> $DNS_OBSERVED}" ;;
                FAIL) fail_out "dns.router: $DNS_DETAIL" ;;
                *)    unknown_out "dns.router: $DNS_DETAIL" ;;
            esac
        fi
        if [ -n "$DNS_SERVER" ]; then
            if [ -z "$NSLOOKUP" ]; then
                record "dns.custom" "UNSUPPORTED" "nslookup is not installed"
            else
                lookup_host "$TARGET_HOST" "$DNS_SERVER"
                case "$L_STATUS" in
                    PASS) pass_out "dns.custom: resolved via $DNS_SERVER${L_ADDRESSES:+ -> $L_ADDRESSES}" ;;
                    FAIL) fail_out "dns.custom: via $DNS_SERVER: $L_DETAIL" ;;
                    *)    unknown_out "dns.custom: via $DNS_SERVER: $L_DETAIL" ;;
                esac
                record "dns.custom" "$L_STATUS" "via $DNS_SERVER: $L_DETAIL" "${L_ADDRESSES:+addresses: $L_ADDRESSES}"
                if [ "$DNS_STATUS" = "PASS" ] && [ "$L_STATUS" = "FAIL" ]; then
                    rep "fact: the system resolver succeeded while $DNS_SERVER failed; the two resolvers disagree"
                elif [ "$DNS_STATUS" = "FAIL" ] && [ "$L_STATUS" = "PASS" ]; then
                    rep "fact: $DNS_SERVER resolves the name while the system resolver failed; compare resolver configurations"
                fi
            fi
        fi
        ;;
    *)
        DNS_STATUS="NOT TESTED"; DNS_DETAIL="target is an IP address literal; no name resolution involved"
        nt_out "dns.router: $DNS_DETAIL"
        ;;
esac

# ---------------------------------------------------------------
# TCP stage: curl telnet probe. stdin is /dev/null, so curl ends the
# probe immediately after connecting; a peer close after connect (56)
# still proves the TCP connection was established.
# ---------------------------------------------------------------
section "TCP connect"
TCP_STATUS="NOT TESTED"; TCP_DETAIL="not run"
if [ -z "$CURL" ]; then
    TCP_STATUS="UNSUPPORTED"; TCP_DETAIL="curl is not installed"
    unsup_out "tcp.connect: $TCP_DETAIL"
elif ! budget_left; then
    TCP_STATUS="NOT TESTED"; TCP_DETAIL="request budget exhausted"
    nt_out "tcp.connect: $TCP_DETAIL"
else
    probe_http "tcp.connect" "telnet://$TARGET_HOST:$TARGET_PORT" --noproxy '*'
    TCP_RC=$R_RC
    case "$TCP_RC" in
        0|56)
            TCP_STATUS="PASS"
            if [ "$TCP_RC" -eq 56 ]; then
                TCP_DETAIL="TCP connection established; the peer closed the probe connection (normal for TLS/HTTP ports)"
            else
                TCP_DETAIL="TCP connection established; probe ended after stdin EOF"
            fi
            pass_out "tcp.connect: $TARGET_HOST:$TARGET_PORT is reachable"
            ;;
        28)
            TCP_STATUS="UNKNOWN"
            TCP_DETAIL="curl timed out; the tool cannot distinguish a connect-timeout from a silently connected peer"
            unknown_out "tcp.connect: inconclusive - $TCP_DETAIL"
            ;;
        7)
            TCP_STATUS="FAIL"
            TCP_DETAIL="connection refused or host/network unreachable for $TARGET_HOST:$TARGET_PORT (curl 7)"
            fail_out "tcp.connect: $TCP_DETAIL"
            ;;
        6)
            TCP_STATUS="FAIL"
            TCP_DETAIL="curl-side resolver failure (curl 6); compare with the dns.router stage"
            fail_out "tcp.connect: $TCP_DETAIL"
            ;;
        *)
            TCP_STATUS="UNKNOWN"; TCP_DETAIL="curl exit $TCP_RC; stage inconclusive"
            unknown_out "tcp.connect: $TCP_DETAIL"
            ;;
    esac
fi


# ---------------------------------------------------------------
# TLS + HTTP stage. One bounded HTTPS request proves both layers:
# a curl success means the handshake AND certificate verification
# passed and an HTTP status came back; every curl TLS-family exit
# code maps to an explicit TLS fact. Facts stay separate from
# hypotheses (flagged HYP_* for the verdict block).
# ---------------------------------------------------------------
TLS_STATUS="NOT TESTED"; TLS_DETAIL="not run"
HTTP_STATUS="NOT TESTED"; HTTP_DETAIL="not run"

classify_https_result() {
    # caller ran probe_http on the https URL; sets TLS_*/HTTP_*/HYP_*
    # and TLS_REACH (the HTTPS exchange proved DNS resolution and TCP)
    case "$R_RC" in
        0|35|60|19|43|56|63)
            # every one of these exits means the name resolved on the
            # curl path and the TCP connection carried TLS data
            TLS_REACH=1
            ;;
    esac
    case "$R_RC" in
        0)
            TLS_STATUS="PASS"; TLS_DETAIL="TLS handshake and certificate verification succeeded"
            pass_out "tls.handshake: certificate verification OK"
            record "tls.handshake" "PASS" "$TLS_DETAIL"
            split_rinfo
            R_SURL=$(sanitize_url "$R_URL")
            case "$R_CODE" in
                2*|3*|4*|5*)
                    HTTP_STATUS="PASS"
                    case "$R_CODE" in
                        2*) HTTP_DETAIL="HTTP $R_CODE received; transport and application answered" ;;
                        3*)
                            _rr=""
                            [ -n "$R_RURL" ] && _rr="; redirect target: $(sanitize_url "$R_RURL")"
                            HTTP_DETAIL="HTTP $R_CODE received; the server answers with a redirect; this tool does not follow redirects$_rr" ;;
                        4*) HTTP_DETAIL="HTTP $R_CODE received - transport and TLS are healthy; the server declined the request (application-level fact)" ;;
                        5*) HTTP_DETAIL="HTTP $R_CODE received - transport and TLS are healthy; the service reports a server-side error (application-level fact)" ;;
                    esac
                    pass_out "http.response: HTTP $R_CODE"
                    info_out "fact: $HTTP_DETAIL"
                    _obs="http_code: $R_CODE; final_url: $R_SURL"
                    [ -n "$R_RURL" ] && _obs="$_obs; redirect_target: $(sanitize_url "$R_RURL")"
                    record "http.response" "PASS" "$HTTP_DETAIL" "$_obs"
                    case "$R_CODE" in
                        3*) [ -n "$R_RURL" ] && REDIRECT_LOCATION=$(sanitize_url "$R_RURL") ;;
                        4*|5*) HYP_APP=1 ;;
                    esac
                    ;;
                *)
                    HTTP_STATUS="UNKNOWN"
                    HTTP_DETAIL="curl succeeded but no usable HTTP status was returned (info=$R_CODE)"
                    unknown_out "http.response: $HTTP_DETAIL"
                    record "http.response" "UNKNOWN" "$HTTP_DETAIL" "info: $R_CODE"
                    ;;
            esac
            ;;
        35)
            TLS_STATUS="FAIL"; TLS_DETAIL="TLS handshake failed (curl 35); certificate verification stays enabled"
            fail_out "tls.handshake: $TLS_DETAIL"
            record "tls.handshake" "FAIL" "$TLS_DETAIL" "curl exit: 35"
            HYP_TLS35=1
            HTTP_STATUS="NOT TESTED"; HTTP_DETAIL="TLS stage failed; HTTP stage not attempted"
            record "http.response" "NOT TESTED" "$HTTP_DETAIL"
            ;;
        60|19)
            TLS_STATUS="FAIL"; TLS_DETAIL="TLS certificate verification failed (curl $R_RC); validation stays enabled"
            fail_out "tls.handshake: $TLS_DETAIL"
            record "tls.handshake" "FAIL" "$TLS_DETAIL" "curl exit: $R_RC"
            HYP_CERT=1
            HTTP_STATUS="NOT TESTED"; HTTP_DETAIL="TLS stage failed; HTTP stage not attempted"
            record "http.response" "NOT TESTED" "$HTTP_DETAIL"
            ;;
        43)
            TLS_STATUS="FAIL"; TLS_DETAIL="malformed TLS response (curl 43)"
            fail_out "tls.handshake: $TLS_DETAIL"
            record "tls.handshake" "FAIL" "$TLS_DETAIL" "curl exit: 43"
            HTTP_STATUS="NOT TESTED"; HTTP_DETAIL="TLS stage failed; HTTP stage not attempted"
            record "http.response" "NOT TESTED" "$HTTP_DETAIL"
            ;;
        7)
            TLS_STATUS="NOT TESTED"; TLS_DETAIL="consistent with the tcp.connect failure (curl 7 at the HTTPS request)"
            record "tls.handshake" "NOT TESTED" "$TLS_DETAIL" "curl exit: 7"
            HTTP_STATUS="NOT TESTED"; HTTP_DETAIL="no transport; not attempted"
            record "http.response" "NOT TESTED" "$HTTP_DETAIL"
            ;;
        6)
            TLS_STATUS="NOT TESTED"; TLS_DETAIL="curl-side resolver failure (curl 6) at the HTTPS request; compare with dns.router"
            record "tls.handshake" "NOT TESTED" "$TLS_DETAIL" "curl exit: 6"
            HTTP_STATUS="NOT TESTED"; HTTP_DETAIL="not attempted"
            record "http.response" "NOT TESTED" "$HTTP_DETAIL"
            ;;
        56)
            TLS_STATUS="UNKNOWN"; TLS_DETAIL="connection reset during the TLS exchange (curl 56); the mid-handshake cut is observed, its cause is not confirmed"
            unknown_out "tls.handshake: $TLS_DETAIL"
            record "tls.handshake" "UNKNOWN" "$TLS_DETAIL" "curl exit: 56"
            HYP_RESET=1
            HTTP_STATUS="NOT TESTED"; HTTP_DETAIL="TLS stage did not complete; not attempted"
            record "http.response" "NOT TESTED" "$HTTP_DETAIL"
            ;;
        28)
            TLS_STATUS="UNKNOWN"; TLS_DETAIL="timed out (curl 28); the tool cannot confirm which TLS sub-stage stalled"
            unknown_out "tls.handshake: $TLS_DETAIL"
            record "tls.handshake" "UNKNOWN" "$TLS_DETAIL" "curl exit: 28"
            HTTP_STATUS="NOT TESTED"; HTTP_DETAIL="not attempted"
            record "http.response" "NOT TESTED" "$HTTP_DETAIL"
            ;;
        63)
            split_rinfo
            case "$R_CODE" in
                2*|3*|4*|5*)
                    TLS_STATUS="PASS"; TLS_DETAIL="TLS handshake and certificate verification succeeded; the response was cut at the diagnostic size limit"
                    pass_out "tls.handshake: certificate verification OK"
                    record "tls.handshake" "PASS" "$TLS_DETAIL" "curl exit: 63"
                    HTTP_STATUS="PASS"
                    HTTP_DETAIL="HTTP $R_CODE received before the diagnostic size limit cut the transfer; transport and TLS are healthy, body inspection is out of scope"
                    pass_out "http.response: HTTP $R_CODE"
                    info_out "fact: $HTTP_DETAIL"
                    record "http.response" "PASS" "$HTTP_DETAIL" "http_code: $R_CODE; size_limit: $MAX_BYTES"
                    case "$R_CODE" in 4*|5*) HYP_APP=1 ;; esac
                    ;;
                *)
                    TLS_STATUS="UNKNOWN"; TLS_DETAIL="maximum response size reached before an HTTP status arrived (curl 63)"
                    unknown_out "tls.handshake: $TLS_DETAIL"
                    record "tls.handshake" "UNKNOWN" "$TLS_DETAIL" "curl exit: 63"
                    HTTP_STATUS="UNKNOWN"; HTTP_DETAIL="response larger than the diagnostic limit"
                    record "http.response" "UNKNOWN" "$HTTP_DETAIL"
                    ;;
            esac
            ;;
        23)
            TLS_STATUS="UNKNOWN"; TLS_DETAIL="curl reported a write error (curl 23); stage inconclusive"
            unknown_out "tls.handshake: $TLS_DETAIL"
            record "tls.handshake" "UNKNOWN" "$TLS_DETAIL" "curl exit: 23"
            HTTP_STATUS="NOT TESTED"; HTTP_DETAIL="not attempted"
            record "http.response" "NOT TESTED" "$HTTP_DETAIL"
            ;;
        *)
            TLS_STATUS="UNKNOWN"; TLS_DETAIL="curl exit $R_RC; stage inconclusive"
            unknown_out "tls.handshake: $TLS_DETAIL"
            record "tls.handshake" "UNKNOWN" "$TLS_DETAIL" "curl exit: $R_RC"
            HTTP_STATUS="NOT TESTED"; HTTP_DETAIL="not attempted"
            record "http.response" "NOT TESTED" "$HTTP_DETAIL"
            ;;
    esac
}

# ---------------------------------------------------------------
# TLS + HTTP stage driver
# ---------------------------------------------------------------
section "TLS handshake and HTTP response"
if [ -z "$CURL" ]; then
    TLS_STATUS="UNSUPPORTED"; TLS_DETAIL="curl is not installed"
    HTTP_STATUS="UNSUPPORTED"; HTTP_DETAIL="curl is not installed"
    unsup_out "tls.handshake: $TLS_DETAIL"
    record "tls.handshake" "UNSUPPORTED" "$TLS_DETAIL"
    record "http.response" "UNSUPPORTED" "$HTTP_DETAIL"
elif [ "$TARGET_SCHEME" = "http" ]; then
    TLS_STATUS="NOT TESTED"; TLS_DETAIL="plain HTTP target; no TLS involved"
    rep "Plain HTTP target: TLS stage NOT TESTED by design."
    record "tls.handshake" "NOT TESTED" "$TLS_DETAIL"
    if ! budget_left; then
        HTTP_STATUS="NOT TESTED"; HTTP_DETAIL="request budget exhausted"
        record "http.response" "NOT TESTED" "$HTTP_DETAIL"
    else
        probe_http "http.response" "$PROBE_URL" --noproxy '*'
        case "$R_RC" in
            0|63)
                case "$R_RC" in 0|63) HTTP_REACH=1 ;; esac
                split_rinfo
                R_SURL=$(sanitize_url "$R_URL")
                case "$R_CODE" in
                    2*|3*|4*|5*)
                        HTTP_STATUS="PASS"
                        case "$R_CODE" in
                            2*) HTTP_DETAIL="HTTP $R_CODE received; transport and application answered" ;;
                            3*)
                                _rr=""
                                [ -n "$R_RURL" ] && _rr="; redirect target: $(sanitize_url "$R_RURL")"
                                HTTP_DETAIL="HTTP $R_CODE received; the server answers with a redirect; this tool does not follow redirects$_rr" ;;
                            4*) HTTP_DETAIL="HTTP $R_CODE received - transport is healthy; the server declined the request (application-level fact)" ;;
                            5*) HTTP_DETAIL="HTTP $R_CODE received - transport is healthy; the service reports a server-side error (application-level fact)" ;;
                        esac
                        pass_out "http.response: HTTP $R_CODE"
                        info_out "fact: $HTTP_DETAIL"
                        _obs="http_code: $R_CODE; final_url: $R_SURL"
                        [ -n "$R_RURL" ] && _obs="$_obs; redirect_target: $(sanitize_url "$R_RURL")"
                        record "http.response" "PASS" "$HTTP_DETAIL" "$_obs"
                        case "$R_CODE" in
                            3*) [ -n "$R_RURL" ] && REDIRECT_LOCATION=$(sanitize_url "$R_RURL") ;;
                            4*|5*) HYP_APP=1 ;;
                        esac
                        ;;
                    *)
                        HTTP_STATUS="UNKNOWN"
                        HTTP_DETAIL="curl succeeded but no usable HTTP status was returned (info=$R_CODE)"
                        unknown_out "http.response: $HTTP_DETAIL"
                        record "http.response" "UNKNOWN" "$HTTP_DETAIL" "info: $R_CODE"
                        ;;
                esac
                ;;
            63)
                split_rinfo
                case "$R_CODE" in
                    2*|3*|4*|5*)
                        HTTP_REACH=1
                        HTTP_STATUS="PASS"
                        HTTP_DETAIL="HTTP $R_CODE received before the diagnostic size limit cut the transfer; transport is healthy, body inspection is out of scope"
                        pass_out "http.response: HTTP $R_CODE"
                        info_out "fact: $HTTP_DETAIL"
                        record "http.response" "PASS" "$HTTP_DETAIL" "http_code: $R_CODE; size_limit: $MAX_BYTES"
                        case "$R_CODE" in 4*|5*) HYP_APP=1 ;; esac
                        ;;
                    *)
                        HTTP_STATUS="UNKNOWN"
                        HTTP_DETAIL="maximum response size reached before an HTTP status arrived (curl 63)"
                        record "http.response" "UNKNOWN" "$HTTP_DETAIL" "curl exit: 63"
                        ;;
                esac
                ;;
            7)  HTTP_STATUS="FAIL"; HTTP_DETAIL="connection refused or unreachable (curl 7); consistent with tcp.connect"
                record "http.response" "FAIL" "$HTTP_DETAIL" "curl exit: 7" ;;
            6)  HTTP_STATUS="NOT TESTED"; HTTP_DETAIL="curl-side resolver failure (curl 6) at the HTTP request"
                record "http.response" "NOT TESTED" "$HTTP_DETAIL" ;;
            28) HTTP_STATUS="UNKNOWN"; HTTP_DETAIL="timed out (curl 28)"
                record "http.response" "UNKNOWN" "$HTTP_DETAIL" "curl exit: 28" ;;
            63) R_CODE=${R_INFO%%|*}
                case "$R_CODE" in
                    2*|3*|4*|5*)
                        HTTP_STATUS="PASS"
                        HTTP_DETAIL="HTTP $R_CODE received before the diagnostic size limit cut the transfer; transport is healthy, body inspection is out of scope"
                        pass_out "http.response: HTTP $R_CODE"
                        info_out "fact: $HTTP_DETAIL"
                        record "http.response" "PASS" "$HTTP_DETAIL" "http_code: $R_CODE; size_limit: $MAX_BYTES"
                        ;;
                    *) HTTP_STATUS="UNKNOWN"; HTTP_DETAIL="maximum response size reached before an HTTP status arrived (curl 63)"
                       record "http.response" "UNKNOWN" "$HTTP_DETAIL" "curl exit: 63" ;;
                esac ;;
            *)  HTTP_STATUS="UNKNOWN"; HTTP_DETAIL="curl exit $R_RC; stage inconclusive"
                record "http.response" "UNKNOWN" "$HTTP_DETAIL" "curl exit: $R_RC" ;;
        esac
    fi
elif ! budget_left; then
    TLS_STATUS="NOT TESTED"; TLS_DETAIL="request budget exhausted"
    HTTP_STATUS="NOT TESTED"; HTTP_DETAIL="not attempted"
    record "tls.handshake" "NOT TESTED" "$TLS_DETAIL"
    record "http.response" "NOT TESTED" "$HTTP_DETAIL"
else
    probe_http "tls+https request" "$PROBE_URL" --noproxy '*'
    classify_https_result
fi

# ---------------------------------------------------------------
# Chain record finalization: exactly one record per chain check;
# contradictions are resolved against the strongest evidence.
# ---------------------------------------------------------------
CHAIN_REACH=0
[ "${TLS_REACH:-0}" = "1" ] && CHAIN_REACH=1
[ "${HTTP_REACH:-0}" = "1" ] && CHAIN_REACH=1
CHAIN_DNS_NEUTRAL=0
if [ "$CHAIN_REACH" = "1" ] && [ "$TCP_STATUS" != "PASS" ]; then
    TCP_STATUS="PASS"
    TCP_DETAIL="proven by the TLS/HTTPS stage (the server answered above TCP)"
    case "${TCP_RC:-}" in
        ''|0|56) : ;;
        *) TCP_DETAIL="$TCP_DETAIL; the telnet probe disagreed (curl exit $TCP_RC) - telnet-specific or transient" ;;
    esac
    rep "note: tcp.connect recorded as PASS - $TCP_DETAIL"
fi
if [ "$CHAIN_REACH" != "1" ] && [ "$TCP_STATUS" = "UNKNOWN" ]; then
    TCP_DETAIL="$TCP_DETAIL; the TLS stage did not prove TCP either"
fi
if [ "$DNS_STATUS" = "FAIL" ] && [ "$CHAIN_REACH" = "1" ]; then
    CHAIN_DNS_NEUTRAL=1
    rep "fact: the target was reached despite the system resolver failure; the HTTPS/HTTP path resolved the name via a different resolver path"
fi
record "dns.router" "$DNS_STATUS" "$DNS_DETAIL" "${DNS_OBSERVED:+addresses: $DNS_OBSERVED}"
record "tcp.connect" "$TCP_STATUS" "$TCP_DETAIL" "curl exit: ${TCP_RC:-n/a}"

# ---------------------------------------------------------------
# Egress observation (small, optional, factual; two tiny requests
# when the Mihomo path is up, one otherwise)
# ---------------------------------------------------------------
section "Egress observation"
EGRESS_DIRECT=""
EGRESS_VIA_MIHOMO=""
if [ "$DO_EGRESS" -eq 0 ]; then
    nt_out "egress.direct: disabled by --no-egress"
    record "egress.direct" "NOT TESTED" "disabled by --no-egress"
elif [ -z "$CURL" ]; then
    unsup_out "egress.direct: curl is not installed"
    record "egress.direct" "UNSUPPORTED" "curl is not installed"
elif ! budget_left; then
    nt_out "egress.direct: request budget exhausted"
    record "egress.direct" "NOT TESTED" "request budget exhausted"
else
    fetch_small "egress.direct" "$EGRESS_URL" --noproxy '*'
    if [ "$R_RC" -eq 0 ]; then
        EGRESS_DIRECT=$(printf '%s' "$R_BODY" | tr -d '[:space:]' | head -c 64)
    fi
    case "$EGRESS_DIRECT" in
        ''|*[!0-9.]*)
            unknown_out "egress.direct: observation inconclusive (curl exit $R_RC, answer not a plain address); the egress address stays unknown"
            EGRESS_DIRECT=""
            record "egress.direct" "UNKNOWN" "egress observation returned no plain IPv4 answer" "curl exit: $R_RC"
            ;;
        *)
            pass_out "egress.direct: direct traffic currently exits from $EGRESS_DIRECT (observation at probe time, not a diagnosis)"
            record "egress.direct" "PASS" "direct egress address observed at probe time" "address: $EGRESS_DIRECT"
            ;;
    esac
fi

# ---------------------------------------------------------------
# Mihomo local path (read-only): SOCKS port, Controller, SOCKS5h
# target probe, Mihomo-path egress. GET requests only.
# ---------------------------------------------------------------
section "Mihomo local path (read-only)"
SOCKS_LISTEN=""
if [ -n "$PORT_TOOL" ]; then
    if "$PORT_TOOL" -tln 2>/dev/null | grep -q "[:.]$SOCKS_PORT[[:space:]]"; then
        SOCKS_LISTEN=1
        pass_out "mihomo.socks-port: TCP $SOCKS_PORT is listening (fact)"
        record "mihomo.socks-port" "PASS" "local port $SOCKS_PORT is listening per netstat/ss"
    else
        SOCKS_LISTEN=0
        fail_out "mihomo.socks-port: TCP $SOCKS_PORT is NOT listening per netstat/ss; the local Mihomo endpoint looks down"
        record "mihomo.socks-port" "FAIL" "local port $SOCKS_PORT is not listening per netstat/ss"
    fi
else
    nt_out "mihomo.socks-port: netstat/ss unavailable; listening state UNKNOWN (the probe below decides empirically)"
    record "mihomo.socks-port" "UNKNOWN" "netstat/ss unavailable; listening state not confirmed"
fi

if [ -z "$CURL" ]; then
    unsup_out "mihomo.controller: curl is not installed"
    record "mihomo.controller" "UNSUPPORTED" "curl is not installed"
elif ! budget_left; then
    nt_out "mihomo.controller: request budget exhausted"
    record "mihomo.controller" "NOT TESTED" "request budget exhausted"
else
    if [ -n "$MIHOMO_SECRET" ]; then
        probe_http "mihomo.controller" "$CONTROLLER_URL/version" -H "Authorization: Bearer $MIHOMO_SECRET" --noproxy '*'
    else
        probe_http "mihomo.controller" "$CONTROLLER_URL/version" --noproxy '*'
    fi
    case "$R_RC" in
        0)
            case "${R_INFO%%|*}" in
                200)
                    pass_out "mihomo.controller: reachable and authorized (HTTP 200, read-only GET /version)"
                    record "mihomo.controller" "PASS" "Controller reachable and authorized (GET /version)"
                    ;;
                401|403)
                    unknown_out "mihomo.controller: reachable but the secret is missing or rejected (HTTP ${R_INFO%%|*})"
                    record "mihomo.controller" "UNKNOWN" "Controller reachable; secret missing or rejected (HTTP ${R_INFO%%|*})"
                    ;;
                *)
                    unknown_out "mihomo.controller: reachable, unexpected HTTP ${R_INFO%%|*}"
                    record "mihomo.controller" "UNKNOWN" "Controller reachable; unexpected HTTP ${R_INFO%%|*}"
                    ;;
            esac
            ;;
        *)
            unknown_out "mihomo.controller: request failed (curl exit $R_RC); the Mihomo API endpoint is not confirmed"
            record "mihomo.controller" "UNKNOWN" "Controller request failed (curl exit $R_RC); the Mihomo API endpoint is not confirmed"
            ;;
    esac
fi

if [ -n "$CURL" ] && [ -n "$JQ" ] && budget_left; then
    if [ -n "$MIHOMO_SECRET" ]; then
        R_INFO=$("$CURL" -sS --connect-timeout "$CONNECT_TIMEOUT" --max-time "$REQ_TIMEOUT" \
            -H "Authorization: Bearer $MIHOMO_SECRET" \
            --noproxy '*' --max-filesize "$MAX_BYTES" \
            -w '\n%{http_code}' "$CONTROLLER_URL/proxies" 2>/dev/null </dev/null)
    else
        R_INFO=$("$CURL" -sS --connect-timeout "$CONNECT_TIMEOUT" --max-time "$REQ_TIMEOUT" \
            --noproxy '*' --max-filesize "$MAX_BYTES" \
            -w '\n%{http_code}' "$CONTROLLER_URL/proxies" 2>/dev/null </dev/null)
    fi
    REQUESTS_USED=$((REQUESTS_USED+1))
    rep "--- mihomo.controller.selection"
    rep "request:  curl GET $CONTROLLER_URL/proxies (request $REQUESTS_USED/$MAX_REQUESTS); parsed locally, only group facts are kept"
    R_CODE=$(printf '%s\n' "$R_INFO" | tail -n 1)
    R_BODY=$(printf '%s\n' "$R_INFO" | sed '$d')
    if [ "$R_CODE" = "200" ]; then
        SEL_NOW=$("$JQ" -r --arg g "$PROXY_GROUP" '.proxies[$g].now // empty' 2>/dev/null <<JQIN
$R_BODY
JQIN
)
        SEL_TYPE=$("$JQ" -r --arg g "$PROXY_GROUP" '.proxies[$g].type // empty' 2>/dev/null <<JQIN2
$R_BODY
JQIN2
)
        if [ -n "$SEL_NOW" ]; then
            pass_out "mihomo.controller.selection: group '$PROXY_GROUP' has a selected leaf (name withheld from the report)"
            record "mihomo.controller.selection" "PASS" "group '$PROXY_GROUP' has a selected proxy leaf (name withheld)" "type: ${SEL_TYPE:-unknown}"
        else
            unknown_out "mihomo.controller.selection: group '$PROXY_GROUP' not found or has no single selected leaf"
            record "mihomo.controller.selection" "UNKNOWN" "group '$PROXY_GROUP' not found or exposes no single selected leaf"
        fi
    else
        unknown_out "mihomo.controller.selection: Controller answered HTTP ${R_CODE:-n/a}; selection not read"
        record "mihomo.controller.selection" "UNKNOWN" "Controller answered HTTP ${R_CODE:-n/a}; selection not read"
    fi
else
    nt_out "mihomo.controller.selection: jq or curl unavailable, or budget exhausted; selection not read"
    record "mihomo.controller.selection" "NOT TESTED" "jq or curl unavailable, or request budget exhausted; selection not read"
fi

SOCKS_PROBE="NOT TESTED"; SOCKS_PROBE_DETAIL="not run"
if [ -z "$CURL" ]; then
    SOCKS_PROBE="UNSUPPORTED"; SOCKS_PROBE_DETAIL="curl is not installed"
    unsup_out "mihomo.socks-probe: $SOCKS_PROBE_DETAIL"
    record "mihomo.socks-probe" "UNSUPPORTED" "$SOCKS_PROBE_DETAIL"
elif [ "$SOCKS_LISTEN" = "0" ]; then
    SOCKS_PROBE="NOT TESTED"; SOCKS_PROBE_DETAIL="local port $SOCKS_PORT was confirmed not listening; probe skipped"
    nt_out "mihomo.socks-probe: $SOCKS_PROBE_DETAIL"
    record "mihomo.socks-probe" "NOT TESTED" "$SOCKS_PROBE_DETAIL"
elif ! budget_left; then
    SOCKS_PROBE="NOT TESTED"; SOCKS_PROBE_DETAIL="request budget exhausted"
    record "mihomo.socks-probe" "NOT TESTED" "$SOCKS_PROBE_DETAIL"
else
    probe_http "mihomo.socks-probe" "$PROBE_URL" -I --socks5-hostname "$SOCKS_HOST:$SOCKS_PORT"
    SOCKS_RC=$R_RC; SOCKS_CODE=${R_INFO%%|*}
    SOCKS_OK=0
    case "$SOCKS_RC" in
        0) case "$SOCKS_CODE" in 2*|3*|4*|5*) SOCKS_OK=1 ;; esac ;;
    esac
    if [ "$SOCKS_OK" -eq 0 ] && budget_left; then
        probe_http "mihomo.socks-probe (GET fallback)" "$PROBE_URL" --range 0-0 --socks5-hostname "$SOCKS_HOST:$SOCKS_PORT"
        SOCKS_RC=$R_RC; SOCKS_CODE=${R_INFO%%|*}
        case "$SOCKS_RC" in
            0) case "$SOCKS_CODE" in 2*|3*|4*|5*) SOCKS_OK=1 ;; esac ;;
        esac
    fi
    if [ "$SOCKS_OK" -eq 1 ]; then
        SOCKS_PROBE="PASS"; SOCKS_PROBE_DETAIL="the target answered through the local Mihomo path (HTTP $SOCKS_CODE)"
        pass_out "mihomo.socks-probe: $SOCKS_PROBE_DETAIL"
        record "mihomo.socks-probe" "PASS" "$SOCKS_PROBE_DETAIL" "http_code: $SOCKS_CODE"
    else
        SOCKS_PROBE="FAIL"; SOCKS_PROBE_DETAIL="no usable HTTP answer through the local Mihomo path (last curl exit $SOCKS_RC)"
        fail_out "mihomo.socks-probe: $SOCKS_PROBE_DETAIL"
        record "mihomo.socks-probe" "FAIL" "$SOCKS_PROBE_DETAIL" "curl exit: $SOCKS_RC"
        HYP_MIHOMO=1
    fi
    rep "limitation: a successful SOCKS5h probe proves the Mihomo path from THIS router; it does not classify any LAN client."
fi

if [ "$DO_EGRESS" -eq 1 ] && [ -n "$CURL" ] && [ "$SOCKS_LISTEN" != "0" ] && budget_left; then
    fetch_small "egress.via-mihomo" "$EGRESS_URL" --socks5-hostname "$SOCKS_HOST:$SOCKS_PORT"
    if [ "$R_RC" -eq 0 ]; then
        EGRESS_VIA_MIHOMO=$(printf '%s' "$R_BODY" | tr -d '[:space:]' | head -c 64)
    fi
    case "$EGRESS_VIA_MIHOMO" in
        ''|*[!0-9.]*)
            unknown_out "egress.via-mihomo: observation inconclusive (curl exit $R_RC, answer not a plain address)"
            EGRESS_VIA_MIHOMO=""
            record "egress.via-mihomo" "UNKNOWN" "Mihomo-path egress observation returned no plain IPv4 answer" "curl exit: $R_RC"
            ;;
        *)
            pass_out "egress.via-mihomo: traffic through the local Mihomo path currently exits from $EGRESS_VIA_MIHOMO (observation at probe time)"
            record "egress.via-mihomo" "PASS" "Mihomo-path egress address observed at probe time" "address: $EGRESS_VIA_MIHOMO"
            if [ -n "$EGRESS_DIRECT" ]; then
                if [ "$EGRESS_DIRECT" = "$EGRESS_VIA_MIHOMO" ]; then
                    rep "fact: both paths exit from the same address; Mihomo-path traffic currently leaves like direct traffic"
                else
                    rep "fact: the paths exit from different addresses; via Mihomo the traffic leaves from $EGRESS_VIA_MIHOMO"
                fi
            fi
            ;;
    esac
elif [ "$DO_EGRESS" -eq 0 ]; then
    record "egress.via-mihomo" "NOT TESTED" "disabled by --no-egress"
fi

# ---------------------------------------------------------------
# MagiTrickle process evidence (read-only) and Keenetic ProxyN
# bridge evidence via ndmc (read-only).
# ---------------------------------------------------------------
section "MagiTrickle and Keenetic evidence (read-only)"
MT_STATUS="UNKNOWN"; MT_DETAIL=""
if [ -n "$PGREP" ]; then
    case "$PGREP" in
        *pidof)
            if pidof magitrickled >/dev/null 2>&1; then
                MT_STATUS="PASS"; MT_DETAIL="magitrickled process is running"
            else
                MT_STATUS="FAIL"; MT_DETAIL="magitrickled process is not running"
            fi
            ;;
        *)
            if "$PGREP" -f magitrickled >/dev/null 2>&1; then
                MT_STATUS="PASS"; MT_DETAIL="magitrickled process is running"
            else
                MT_STATUS="FAIL"; MT_DETAIL="magitrickled process is not running"
            fi
            ;;
    esac
    case "$MT_STATUS" in
        PASS) pass_out "magitrickle.process: $MT_DETAIL" ;;
        FAIL) fail_out "magitrickle.process: $MT_DETAIL" ;;
    esac
else
    MT_DETAIL="pgrep/pidof unavailable; process presence not observed"
    unknown_out "magitrickle.process: $MT_DETAIL"
fi
record "magitrickle.process" "$MT_STATUS" "$MT_DETAIL"

if [ -z "$NDMC" ]; then
    nt_out "keenetic.proxyn: ndmc unavailable; Keenetic-side evidence NOT TESTED"
    record "keenetic.proxyn" "NOT TESTED" "ndmc unavailable"
else
    RUN_CFG=$(ndmc -c "show running-config" 2>/dev/null || true)
    if [ -z "$RUN_CFG" ]; then
        nt_out "keenetic.proxyn: running-config could not be read via ndmc"
        record "keenetic.proxyn" "NOT TESTED" "running-config could not be read via ndmc"
    else
        PROXY_LINES=$(printf '%s\n' "$RUN_CFG" | grep -E 'interface Proxy[0-9]+|proxy upstream|proxy protocol|description mihomo t2s' | head -n 20)
        if [ -n "$PROXY_LINES" ]; then
            N_PROXY_IF=$(printf '%s\n' "$PROXY_LINES" | grep -c 'interface Proxy[0-9]' || true)
            rep "evidence summary (raw running-config lines are withheld from the report): ${N_PROXY_IF:-0} Proxy interface line(s) matched the project filters"
            if printf '%s\n' "$RUN_CFG" | grep -q '127\.0\.0\.1.*7890'; then
                pass_out "keenetic.proxyn: running-config contains a ProxyN upstream to 127.0.0.1:7890 (read-only fact)"
                record "keenetic.proxyn" "PASS" "running-config contains a ProxyN upstream to 127.0.0.1:7890"
            else
                unknown_out "keenetic.proxyn: ProxyN lines exist but no 127.0.0.1:7890 upstream was found in the filtered evidence"
                record "keenetic.proxyn" "UNKNOWN" "ProxyN lines present but no 127.0.0.1:7890 upstream in filtered evidence"
            fi
        else
            unknown_out "keenetic.proxyn: no ProxyN evidence in the filtered running-config"
            record "keenetic.proxyn" "UNKNOWN" "no ProxyN evidence in filtered running-config"
        fi
    fi
fi

# ---------------------------------------------------------------
# Honest limits of this version
# ---------------------------------------------------------------
section "Limits of this version"
unsup_out "udp.transport: no reliable UDP probe with verified semantics on BusyBox/Entware; NOT performed. The DNS stage only exercises the resolver (which may use UDP 53) - no UDP transport proof is claimed either way."
record "udp.transport" "UNSUPPORTED" "no reliable UDP probe with verified semantics on BusyBox/Entware; the DNS stage only exercises the resolver, no UDP transport proof is claimed"
nt_out "client.vantage: every check above ran on the router. A specific LAN client's DNS behavior, protected DNS, IPv4/IPv6 preference, policy classification or proxy usage is NOT TESTED here and needs client-side evidence."
record "client.vantage" "NOT TESTED" "all observations are router-side; LAN-client DNS/routing/policy classification requires separate client-side evidence"

# ---------------------------------------------------------------
# Verdict: name only the CONFIRMED failing stage; everything else
# is a labeled hypothesis. Chain order: dns -> tcp -> tls -> http.
# ---------------------------------------------------------------
chain_state() {
    # prints: failure | incomplete | ok  (required stages only)
    for _pair in "dns:$DNS_STATUS" "tcp:$TCP_STATUS" "tls:$TLS_STATUS" "http:$HTTP_STATUS"; do
        _sid=${_pair%%:*}; _sst=${_pair#*:}
        case "$_sid" in
            dns) [ "${CHAIN_DNS_NEUTRAL:-0}" = "1" ] && continue
                case "$TARGET_HOST" in *[!0-9.]*) : ;; *) continue ;; esac ;;
            tls) [ "$TARGET_SCHEME" = "https" ] || continue ;;
        esac
        if [ "$_sst" = "FAIL" ]; then printf 'failure'; return 0; fi
    done
    for _pair in "dns:$DNS_STATUS" "tcp:$TCP_STATUS" "tls:$TLS_STATUS" "http:$HTTP_STATUS"; do
        _sid=${_pair%%:*}; _sst=${_pair#*:}
        case "$_sid" in
            dns) [ "${CHAIN_DNS_NEUTRAL:-0}" = "1" ] && continue
                case "$TARGET_HOST" in *[!0-9.]*) : ;; *) continue ;; esac ;;
            tls) [ "$TARGET_SCHEME" = "https" ] || continue ;;
        esac
        case "$_sst" in PASS) : ;; *) printf 'incomplete'; return 0 ;; esac
    done
    printf 'ok'
}

section "Verdict"
HYP_ALL=""
NEXT_ALL=""
FIRST_FAIL=""

CHAIN_STATE=$(chain_state)
case "$CHAIN_STATE" in
    failure)
        for _pair in "dns:$DNS_STATUS" "tcp:$TCP_STATUS" "tls:$TLS_STATUS" "http:$HTTP_STATUS"; do
            _sid=${_pair%%:*}; _sst=${_pair#*:}
            case "$_sid" in
                dns) [ "${CHAIN_DNS_NEUTRAL:-0}" = "1" ] && continue
                case "$TARGET_HOST" in *[!0-9.]*) : ;; *) continue ;; esac ;;
                tls) [ "$TARGET_SCHEME" = "https" ] || continue ;;
            esac
            if [ "$_sst" = "FAIL" ]; then FIRST_FAIL=$_sid; break; fi
        done
        case "$FIRST_FAIL" in
            dns)
                FIRST_FAIL="dns.router"
                case "$DNS_DETAIL" in
                    NXDOMAIN*) HYP_ALL="${HYP_ALL}the name does not exist per this resolver (fact: NXDOMAIN); spelling, DNS propagation or name interception are candidate explanations
" ;;
                    SERVFAIL*) HYP_ALL="${HYP_ALL}the resolver could not complete upstream resolution (SERVFAIL is reported by the resolver, not produced locally)
" ;;
                    REFUSED*)  HYP_ALL="${HYP_ALL}the resolver refused the query; a resolver ACL, a wrong upstream or interception are candidate explanations
" ;;
                    timeout*)  HYP_ALL="${HYP_ALL}the resolver did not answer within the window; upstream reachability, resolver outage or interception are candidate explanations
" ;;
                esac
                NEXT_ALL="${NEXT_ALL}rerun with --dns-server <server> to separate the system resolver from a specific upstream
review KeeneticOS DNS settings and MagiTrickle DNS-interception evidence (read-only sources only)
" ;;
            tcp)
                FIRST_FAIL="tcp.connect"
                HYP_ALL="${HYP_ALL}the target port refused the connection or the route was unreachable from this router at probe time (fact: curl 7); server-side downtime, a firewall, provider blocking or routing are candidate causes and this run does not distinguish them
"
                NEXT_ALL="${NEXT_ALL}retry from another network (for example a phone hotspot) to separate router/provider causes from server-side ones
review KeeneticOS policy/interface state for this destination (read-only sources only)
" ;;
            tls)
                FIRST_FAIL="tls.handshake"
                case "$TLS_DETAIL" in
                    *curl\ 35*)
                        HYP_ALL="${HYP_ALL}the TLS handshake is broken on the path (curl 35). Known field case (docs/03): some providers break X25519/IPv6 handshake paths; the IPv4+X25519 compatibility retry is the documented candidate check. DPI interference is one hypothesis among several and is NOT proven by this exit code alone
" ;;
                    *curl\ 60*|*curl\ 19*)
                        HYP_ALL="${HYP_ALL}certificate verification failed while validation stayed enabled; device clock skew and a missing CA bundle are the most common router-side causes
" ;;
                    *) HYP_ALL="${HYP_ALL}the TLS exchange failed with the recorded curl exit code; the specific cause needs more evidence
" ;;
                esac
                NEXT_ALL="${NEXT_ALL}retry with the IPv4+X25519 compatibility approach documented in docs/03-install.md (advanced first-fetch section) when the failure is curl 35
check the device date/time and the ca-bundle package (opkg list-installed | grep ca-bundle) when the failure is curl 60/19
compare the same URL from another network to separate provider-side from server-side causes
" ;;
            http)
                FIRST_FAIL="http.response"
                HYP_ALL="${HYP_ALL}TLS succeeded but no HTTP answer arrived; the connection may have been cut mid-response or the service stalled after accepting the request
" ;;
        esac
        fail_out "VERDICT: confirmed failure at stage '$FIRST_FAIL'. Later stages may show secondary effects; the first confirmed failing stage above is the primary evidence."
        SUMMARY="confirmed_failure"
        FINAL_RC=1
        ;;
    ok)
        if [ "$TARGET_SCHEME" = "https" ]; then
            pass_out "VERDICT: target chain confirmed - DNS, TCP and TLS answered and HTTP responded with a status. No local network failure is proven; application-level notes above still apply."
        else
            pass_out "VERDICT: target chain confirmed - DNS and TCP answered and HTTP responded with a status (plain HTTP target). No local network failure is proven; application-level notes above still apply."
        fi
        SUMMARY="ok"
        FINAL_RC=0
        ;;
    *)
        unknown_out "VERDICT: inconclusive - no required stage FAILed, but the chain never completed (missing tools, timeouts or exhausted budget). Nothing is proven either way."
        SUMMARY="inconclusive"
        FINAL_RC=3
        ;;
esac

case "$FIRST_FAIL" in
    dns.router)    rep "consistency: later networked results are consistent with the DNS failure observed first" ;;
    tcp.connect)   rep "consistency: DNS answered while TCP failed; later stages are consistent with a transport-level block or outage" ;;
    tls.handshake) rep "consistency: DNS and TCP answered; the failure localizes to the TLS exchange (curl exit recorded above)" ;;
esac

if [ "${REDIRECT_LOCATION:-}" != "" ]; then
    HYP_ALL="${HYP_ALL}the HTTP path was redirected to $REDIRECT_LOCATION: a captive portal, an interception-style redirect or a normal site redirect is possible (fact: the redirect target was observed; this tool does not follow redirects)
"
    NEXT_ALL="${NEXT_ALL}re-check after authenticating to the captive portal, or compare from another network
"
fi
if [ "${CHAIN_DNS_NEUTRAL:-0}" = "1" ]; then
    HYP_ALL="${HYP_ALL}the system resolver failed while the target was still reached: local DNS interception (dnsmasq/MagiTrickle), a different upstream or a stale negative cache are candidate explanations
"
    NEXT_ALL="${NEXT_ALL}compare resolver answers (KeeneticOS DNS settings, --dns-server probes) before treating the resolver failure as user-visible
"
fi
if [ "${HYP_RESET:-0}" = "1" ]; then
    HYP_ALL="${HYP_ALL}the connection was cut during the TLS exchange (curl 56); DPI, MTU and server behavior are candidate causes, none is proven by this observation alone
"
fi
if [ "${HYP_MIHOMO:-0}" = "1" ]; then
    HYP_ALL="${HYP_ALL}the local Mihomo path did not deliver an HTTP answer for this target; Mihomo-side routing or selection is a candidate cause
"
    NEXT_ALL="${NEXT_ALL}compare with mihomo-route-check.sh for this target and review the current proxy-group selection (read-only)
"
fi

if [ -n "$HYP_ALL" ]; then
    rep ""
    rep "Hypotheses (explicitly NOT confirmed causes):"
    printf '%s' "$HYP_ALL" | while IFS= read -r _hline; do
        [ -n "$_hline" ] || continue
        rep "  H: $_hline"
    done
fi
if [ -n "$NEXT_ALL" ]; then
    rep ""
    rep "Suggested next steps (read-only unless stated otherwise):"
    printf '%s' "$NEXT_ALL" | while IFS= read -r _nline; do
        [ -n "$_nline" ] || continue
        rep "  N: $_nline"
    done
fi

info_out "Read-only: no files, services or settings were changed; certificate verification stayed enabled."
info_out "Requests used: $REQUESTS_USED of $MAX_REQUESTS (counting DNS queries)."
[ -n "$EGRESS_DIRECT" ] && info_out "Direct egress at probe time: $EGRESS_DIRECT (observation, not a diagnosis)."
[ -n "$REP_TARGET" ] && info_out "Human report written to $REP_TARGET."

# ---------------------------------------------------------------
# JSON contract: network-diagnostics/v1. Produced with plain sh;
# jq is not required. All free text goes through json_escape();
# statuses are from the fixed vocabulary.
# ---------------------------------------------------------------
if [ -n "$JSON_FILE" ]; then
    case "$JSON_FILE" in
        */*)
            JSON_DIR=${JSON_FILE%/*}
            [ -d "$JSON_DIR" ] || { fail_out "json directory does not exist: $JSON_DIR"; rm -f "$ERR_FILE"; exit 2; }
            ;;
    esac
    NOW_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)
    [ -n "$NOW_UTC" ] || NOW_UTC="unknown"

    _tmp_json=${TMPDIR:-/tmp}/kas-net-doctor.json.$$
    : > "$_tmp_json" 2>/dev/null || { fail_out "cannot prepare the JSON staging file"; rm -f "$ERR_FILE"; exit 2; }

    json_array_from_lines() {
        # $1 = multi-line text -> ["item","item"] (empty text -> [])
        _items=""
        if [ -n "$1" ]; then
            _items=$(printf '%s' "$1" | while IFS= read -r _jline; do
                [ -n "$_jline" ] || continue
                printf '"%s",' "$(json_escape "$_jline")"
            done)
            _items=${_items%,}
        fi
        printf '[%s]' "$_items"
    }
    HYP_JSON=$(json_array_from_lines "$HYP_ALL")
    NEXT_JSON=$(json_array_from_lines "$NEXT_ALL")

    {
        printf '{\n'
        printf '  "schema": "%s",\n' "$SCHEMA"
        printf '  "tool": "%s",\n' "$PROG_NAME"
        printf '  "tool_version": "%s",\n' "$PROG_VERSION"
        printf '  "generated_utc": "%s",\n' "$NOW_UTC"
        printf '  "exit_code": %s,\n' "$FINAL_RC"
        printf '  "verdict": {\n'
        printf '    "summary": "%s",\n' "$SUMMARY"
        printf '    "first_failed_stage": "%s",\n' "$FIRST_FAIL"
        printf '    "hypotheses": %s,\n' "$HYP_JSON"
        printf '    "next_steps": %s\n' "$NEXT_JSON"
        printf '  },\n'
        printf '  "target": {\n'
        printf '    "input": "%s",\n' "$(json_escape "$(sanitize_url "$TARGET_INPUT")")"
        printf '    "host": "%s",\n' "$(json_escape "$TARGET_HOST")"
        printf '    "port": %s,\n' "$TARGET_PORT"
        printf '    "url": "%s",\n' "$(json_escape "$(sanitize_url "$PROBE_URL")")"
        printf '    "scheme": "%s"\n' "$TARGET_SCHEME"
        printf '  },\n'
        printf '  "vantage": "router",\n'
        printf '  "budget": {\n'
        printf '    "connect_timeout_s": %s,\n' "$CONNECT_TIMEOUT"
        printf '    "request_timeout_s": %s,\n' "$REQ_TIMEOUT"
        printf '    "max_bytes": %s,\n' "$MAX_BYTES"
        printf '    "requests_used": %s,\n' "$REQUESTS_USED"
        printf '    "requests_limit": %s\n' "$MAX_REQUESTS"
        printf '  },\n'
        printf '  "egress": {\n'
        printf '    "direct": "%s",\n' "$(json_escape "$EGRESS_DIRECT")"
        printf '    "via_mihomo": "%s",\n' "$(json_escape "$EGRESS_VIA_MIHOMO")"
        printf '    "note": "%s"\n' "$(json_escape "addresses observed at probe time; empty value means not observed")"
        printf '  },\n'
        printf '  "counts": {\n'
        printf '    "pass": %s,\n' "$N_PASS"
        printf '    "fail": %s,\n' "$N_FAIL"
        printf '    "unknown": %s,\n' "$N_UNKNOWN"
        printf '    "not_tested": %s,\n' "$N_NT"
        printf '    "unsupported": %s\n' "$N_UNSUP"
        printf '  },\n'
        printf '  "checks": [%s]\n' "$CHECK_RECORDS"
        printf '}\n'
    } > "$JSON_FILE" 2>/dev/null || {
        fail_out "cannot write the JSON file: $JSON_FILE"
        rm -f "$_tmp_json" "$ERR_FILE"
        exit 2
    }
    rm -f "$_tmp_json"
    info_out "JSON contract ($SCHEMA) written to $JSON_FILE."
fi

rm -f "$ERR_FILE" 2>/dev/null
exit "$FINAL_RC"
