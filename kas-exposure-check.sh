#!/bin/sh

# kas-exposure-check.sh v0.2.0
#
# Read-only local exposure audit (issue #159). It reports which TCP ports are
# actually LISTENING on this router (from /proc/net/tcp and /proc/net/tcp6,
# so it works even without ss/netstat), how each is bound (loopback / wildcard
# / specific address), and cross-checks the Mihomo config (allow-lan,
# bind-address, external-controller, secret state — never the secret
# value) and the Controller authentication state.
#
# Owner contract (issue #159, 2026-11-01): a Mihomo Controller with no usable
# secret and non-loopback accessibility is an accepted KAS deployment
# contract. The audit therefore reports FACTS and never treats an open
# binding, allow-lan, a missing/empty/YAML-null secret or an unauthenticated
# HTTP 200 as a violation. Three distinct concepts are kept apart:
#   1. the socket listens on an address (fact from /proc);
#   2. a local unauthenticated API request is answered (fact from the probe);
#   3. the API is reachable from outside (NOT verified here; firewall/NAT is
#      not parsed).
#
# Hard limits of the evidence (stated in the verdict, not hidden):
#   - a LISTENING socket is NOT proof of reachability from WAN or any other
#     network; Keenetic firewall/NAT decisions are NOT parsed here;
#   - binding to br0 does NOT stop clients of other routed networks (home,
#     dacha, work, VPN subnets) — no single-bind assumption is made;
#   - UDP listeners are not audited (their /proc state semantics differ);
#   - missing data sources are reported UNKNOWN/NOT TESTED, never guessed.
#
# The tool changes nothing. It never prints subscriptions, secrets, passwords
# or full running-config; only filtered, non-sensitive lines are shown.
# Exit codes: 0 = audit completed with socket evidence and no declared-vs-
# observed authentication contradiction; 1 = the declared Controller
# authentication state contradicts the live probe (e.g. a secret is
# configured but the API still answers HTTP 200 without Authorization);
# 2 = usage error; 3 = no listening-socket evidence was available at all.

set -u

PROG_NAME="kas-exposure-check.sh"
PROG_VERSION="0.2.0"
PROC_ROOT="${KAS_EXPOSURE_PROC_ROOT:-/proc}"
CONFIG_PATH="${KAS_EXPOSURE_CONFIG:-/opt/etc/mihomo/config.yaml}"
CONTROLLER_URL="${KAS_EXPOSURE_CONTROLLER_URL:-}"
CURL_TIMEOUT=3

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
info_out() { printf '%s[INFO]%s %s\n' "$COLOR_CYAN" "$COLOR_RESET" "$1"; }

usage() {
    cat <<USAGE
$PROG_NAME v$PROG_VERSION

Read-only local exposure audit. Changes nothing; prints no secrets.

Usage:
  sh $PROG_NAME [-h|--help]

Environment overrides (tests / special layouts):
  KAS_EXPOSURE_PROC_ROOT        default /proc
  KAS_EXPOSURE_CONFIG           default /opt/etc/mihomo/config.yaml
  KAS_EXPOSURE_CONTROLLER_URL   default: derived from external-controller

Statuses: PASS / FAIL / UNKNOWN / NOT TESTED / UNSUPPORTED.
[INFO] lines are observed facts (open bindings and unauthenticated answers
are the accepted KAS deployment contract, not violations).
Exit codes: 0 audit facts collected, declared vs observed Controller
            authentication consistent; 1 contradiction between the declared
            authentication state and the live probe; 2 usage error;
            3 no listening-socket evidence was available at all.
USAGE
}

case "${1:-}" in
    "") : ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail_out "Unknown argument: $1"; exit 2 ;;
esac

section() { printf '\n=== %s ===\n' "$1"; }

section "Local exposure audit"
info_out "Scope: LISTENING TCP sockets and their bind addresses. A listening socket is NOT proof of WAN reachability; firewall/NAT is not parsed."

section "Data sources"
HAVE_TCP=0; HAVE_TCP6=0
[ -r "$PROC_ROOT/net/tcp" ] && HAVE_TCP=1
[ -r "$PROC_ROOT/net/tcp6" ] && HAVE_TCP6=1
[ "$HAVE_TCP" -eq 1 ] || nt_out "$PROC_ROOT/net/tcp is not readable; IPv4 listeners UNKNOWN"
[ "$HAVE_TCP6" -eq 1 ] || nt_out "$PROC_ROOT/net/tcp6 is not readable; IPv6 listeners UNKNOWN"
for helper in netstat ss; do
    if command -v "$helper" >/dev/null 2>&1; then
        info_out "$helper is present (presence noted only; /proc tables remain the single primary source)"
    fi
done
HAVE_CONFIG=0
if [ -r "$CONFIG_PATH" ]; then
    HAVE_CONFIG=1
    info_out "Mihomo config readable: $CONFIG_PATH"
else
    nt_out "Mihomo config not readable at $CONFIG_PATH; allow-lan/bind-address/secret checks UNKNOWN"
fi
HAVE_CURL=0
if command -v curl >/dev/null 2>&1; then HAVE_CURL=1; else nt_out "curl missing; live Controller probe skipped"; fi
HAVE_NDMC=0
if command -v ndmc >/dev/null 2>&1; then HAVE_NDMC=1; else nt_out "ndmc missing; Keenetic ProxyN/segments evidence skipped"; fi

# Private temp area; nothing is ever written into /proc.
TMPD=""
if command -v mktemp >/dev/null 2>&1; then
    TMPD=$(mktemp -d "${TMPDIR:-/tmp}/kas-exposure.XXXXXXXX" 2>/dev/null) || TMPD=""
fi
[ -n "$TMPD" ] || TMPD="${TMPDIR:-/tmp}/kas-exposure.$$"
mkdir -p "$TMPD" 2>/dev/null
cleanup() { [ -n "$TMPD" ] && rm -rf "$TMPD"; return 0; }
trap 'cleanup' 0
trap 'exit 130' INT
trap 'exit 143' TERM

# hex4 <8-hex-digits> -> dotted quad; /proc/net/tcp stores IPv4 little-endian.
hex4() {
    printf '%d.%d.%d.%d' \
        "0x$(printf '%s' "$1" | cut -c7-8)" \
        "0x$(printf '%s' "$1" | cut -c5-6)" \
        "0x$(printf '%s' "$1" | cut -c3-4)" \
        "0x$(printf '%s' "$1" | cut -c1-2)"
}

# Parse LISTEN rows (st == 0A) into "<hexaddr> <hexport>" lines of $2.
parse_listeners() {
    awk '$4 == "0A" { split($2, a, ":"); print a[1], a[2] }' "$1" 2>/dev/null | sort -u > "$2"
}

# classify_secret_value <text after the "secret:" colon>
# Prints ENABLED, DISABLED or UNKNOWN. The value itself is never echoed.
# YAML semantics: an empty value, an unquoted null/Null/NULL/~ or empty
# quotes mean NO secret (DISABLED); any quoted non-empty string — including
# quoted "null" — is a real password (ENABLED); an unbalanced quote cannot
# be classified honestly (UNKNOWN). A '#' starts a comment only outside
# quotes, so quoted values keep their '#'.
classify_secret_value() {
    _sv=$(printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [ -z "$_sv" ]; then
        printf 'DISABLED'
        return 0
    fi
    _first=$(printf '%s' "$_sv" | cut -c1)
    if [ "$_first" = "'" ] || [ "$_first" = '"' ]; then
        _len=${#_sv}
        if [ "$_len" -ge 2 ] && [ "$(printf '%s' "$_sv" | cut -c"$_len")" = "$_first" ]; then
            _inner=$(printf '%s' "$_sv" | cut -c2-"$((_len - 1))")
            if [ -n "$_inner" ]; then printf 'ENABLED'; else printf 'DISABLED'; fi
        else
            printf 'UNKNOWN'
        fi
        return 0
    fi
    _unquoted=$(printf '%s' "$_sv" | sed 's/#.*$//' | sed -e 's/[[:space:]]*$//')
    case "$_unquoted" in
        ''|null|Null|NULL|'~') printf 'DISABLED' ;;
        *) printf 'ENABLED' ;;
    esac
}

LISTEN_SEEN=0
AUTH_STATE="UNKNOWN"     # ENABLED | DISABLED | UNKNOWN (declared, from config)
ACCESS_STATE="UNKNOWN"   # CONFIRMED | REJECTED | UNKNOWN (observed, from probe)
CONTRADICTION=0          # declared vs observed authentication disagreement

report_listener() {
    # $1=family $2=hexaddr $3=hexport
    local _fam=$1 _hx=$2 _port _cls _what
    # /proc/net/tcp* encodes the listening port as hex (e.g. 1ED2 = 7890).
    # Convert before both presentation and well-known-port matching.
    _port=$(printf '%d' "0x$3" 2>/dev/null) || {
        unknown_out "$_fam listener with unreadable hex port (ignored)"
        return 0
    }
    case "$_fam" in
        ipv4)
            case "$_hx" in
                00000000) _cls="wildcard 0.0.0.0 (all IPv4 interfaces)" ;;
                0100007F) _cls="loopback 127.0.0.1" ;;
                *) _cls="specific $(hex4 "$_hx")" ;;
            esac
            ;;
        ipv6)
            case "$_hx" in
                00000000000000000000000000000000) _cls="wildcard :: (all IPv6 interfaces)" ;;
                00000000000000000000000001000000) _cls="loopback ::1" ;;
                *) _cls="specific IPv6 ($_hx)" ;;
            esac
            ;;
        *) _cls="unknown" ;;
    esac
    _what=""
    case "$_port" in
        7890) _what="Mihomo mixed/proxy port" ;;
        9090) _what="Mihomo Controller" ;;
        53)   _what="DNS (TCP side)" ;;
        8081) _what="KAS Control Center (default port)" ;;
        79)   _what="Keenetic ndmq/RCI" ;;
        80|443) _what="Web" ;;
        22)   _what="SSH" ;;
    esac
    LISTEN_SEEN=$((LISTEN_SEEN+1))
    case "$_cls" in
        loopback*)
            pass_out "$_fam port $_port bound to $_cls${_what:+ — $_what}"
            ;;
        wildcard*)
            info_out "$_fam port $_port bound to $_cls${_what:+ — $_what}; a listening socket is a fact, not a vulnerability — external reachability depends on firewall/NAT and is NOT verified here"
            ;;
        *)
            unknown_out "$_fam port $_port bound to a specific address ($_cls)${_what:+ — $_what}; clients of other routed subnets may still reach it"
            ;;
    esac
}

section "Listening TCP sockets (from /proc)"
if [ "$HAVE_TCP" -eq 1 ]; then
    parse_listeners "$PROC_ROOT/net/tcp" "$TMPD/tcp4.lst"
    while read -r hx port; do
        [ -n "$hx" ] || continue
        report_listener ipv4 "$hx" "$port"
    done < "$TMPD/tcp4.lst"
fi
if [ "$HAVE_TCP6" -eq 1 ]; then
    parse_listeners "$PROC_ROOT/net/tcp6" "$TMPD/tcp6.lst"
    while read -r hx port; do
        [ -n "$hx" ] || continue
        report_listener ipv6 "$hx" "$port"
    done < "$TMPD/tcp6.lst"
fi
if [ "$LISTEN_SEEN" -eq 0 ]; then
    unknown_out "no listening TCP sockets found in readable /proc tables; either nothing listens or the tables are not readable"
fi

section "Mihomo config cross-check (no secret values are shown)"
if [ "$HAVE_CONFIG" -eq 1 ]; then
    for key in mixed-port port socks-port bind-address; do
        _v=$(grep -E "^${key}:" "$CONFIG_PATH" 2>/dev/null | head -n 1 | tr -d '\r')
        [ -n "$_v" ] && info_out "config: $_v"
    done
    _al=$(grep -E "^allow-lan:" "$CONFIG_PATH" 2>/dev/null | head -n 1 | tr -d '\r')
    if [ -n "$_al" ]; then
        info_out "config: $_al"
        case "$_al" in
            *true*) info_out "allow-lan is enabled: Mihomo serves LAN clients by design (owner-confirmed KAS deployment contract); actual reachability is still governed by firewall/NAT, which is not parsed here" ;;
        esac
    else
        info_out "config: allow-lan not set (Mihomo defaults to loopback binding)"
    fi
    _ec=$(grep -E "^external-controller:" "$CONFIG_PATH" 2>/dev/null | head -n 1 | tr -d '\r')
    if [ -n "$_ec" ]; then
        info_out "config: $_ec"
        case "$_ec" in
            *127.0.0.1*|*localhost*) pass_out "external-controller bound to loopback" ;;
            *) info_out "external-controller bound to a non-loopback address (accepted KAS deployment contract); external reachability depends on firewall/NAT and is NOT verified here" ;;
        esac
    else
        info_out "config: external-controller not set"
    fi
    # Classify the declared authentication state. The secret value is never
    # echoed: only ENABLED / DISABLED / UNKNOWN is reported.
    _sec=$(grep -E "^secret:" "$CONFIG_PATH" 2>/dev/null | head -n 1 | tr -d '\r')
    if [ -n "$_sec" ]; then
        _sec_class=$(classify_secret_value "${_sec#secret:}")
        case "$_sec_class" in
            ENABLED)
                AUTH_STATE="ENABLED"
                info_out "Controller secret: ENABLED (value intentionally not shown)"
                ;;
            DISABLED)
                AUTH_STATE="DISABLED"
                info_out "Controller secret: DISABLED (empty value or YAML null; accepted KAS deployment contract — value intentionally not shown)"
                ;;
            *)
                AUTH_STATE="UNKNOWN"
                unknown_out "Controller secret: UNKNOWN (unbalanced quoting; value intentionally not shown)"
                ;;
        esac
    else
        AUTH_STATE="DISABLED"
        info_out "Controller secret: DISABLED (no top-level secret line; accepted KAS deployment contract)"
    fi
else
    AUTH_STATE="UNKNOWN"
    nt_out "Controller authentication state UNKNOWN (config not readable)"
fi

section "Controller authentication probe (read-only GET /version)"
_EC_ADDR=""
if [ "$HAVE_CONFIG" -eq 1 ]; then
    _EC_ADDR=$(grep -E "^external-controller:" "$CONFIG_PATH" 2>/dev/null | head -n 1 \
        | sed 's/^external-controller:[[:space:]]*//; s/["'\'']//g' | tr -d '\r')
fi
_PROBE_URL="${CONTROLLER_URL:-}"
if [ -z "$_PROBE_URL" ] && [ -n "$_EC_ADDR" ]; then
    case "$_EC_ADDR" in
        *:*) _PROBE_URL="http://$_EC_ADDR/version" ;;
    esac
fi
if [ "$HAVE_CURL" -eq 1 ] && [ -n "$_PROBE_URL" ]; then
    _code=$(curl -sS --noproxy '*' -o /dev/null --connect-timeout "$CURL_TIMEOUT" --max-time "$CURL_TIMEOUT" -w '%{http_code}' "$_PROBE_URL" 2>/dev/null </dev/null)
    _rc=$?
    case "$_rc" in
        0)
            case "$_code" in
                401|403)
                    ACCESS_STATE="REJECTED (HTTP $_code, localhost vantage)"
                    case "$AUTH_STATE" in
                        ENABLED) pass_out "Controller answered HTTP $_code: authentication enforced, consistent with declared ENABLED" ;;
                        DISABLED)
                            fail_out "Contradiction: declared authentication DISABLED but Controller answered HTTP $_code; the running instance may use a different config than $CONFIG_PATH"
                            CONTRADICTION=1
                            ;;
                        *) unknown_out "Controller answered HTTP $_code: authentication enforced; declared authentication state UNKNOWN" ;;
                    esac
                    ;;
                200)
                    ACCESS_STATE="CONFIRMED (HTTP 200 without Authorization, localhost vantage)"
                    case "$AUTH_STATE" in
                        DISABLED) info_out "Controller answered HTTP 200 without Authorization: confirmed local unauthenticated access, consistent with declared DISABLED authentication (accepted KAS deployment contract; external reachability NOT verified)" ;;
                        ENABLED)
                            fail_out "Contradiction: declared authentication ENABLED but Controller answered HTTP 200 without Authorization; the configured secret is not being enforced (value intentionally not shown)"
                            CONTRADICTION=1
                            ;;
                        *) unknown_out "Controller answered HTTP 200 without Authorization; declared authentication state UNKNOWN" ;;
                    esac
                    ;;
                *)
                    ACCESS_STATE="UNKNOWN"
                    unknown_out "Controller answered HTTP $_code at $_PROBE_URL"
                    ;;
            esac
            ;;
        *)
            ACCESS_STATE="UNKNOWN"
            unknown_out "Controller probe could not connect (curl exit $_rc) at $_PROBE_URL"
            ;;
    esac
else
    ACCESS_STATE="UNKNOWN"
    nt_out "Controller authentication NOT TESTED (no curl or no external-controller address known)"
fi

section "Keenetic ProxyN evidence (filtered, non-sensitive)"
if [ "$HAVE_NDMC" -eq 1 ]; then
    ndmc -c "show running-config" 2>/dev/null \
        | grep -E 'interface Proxy[0-9]+|proxy protocol socks5|proxy socks5-udp|proxy upstream 127\.0\.0\.1' \
        | head -n 12 > "$TMPD/proxy.lst"
    if [ -s "$TMPD/proxy.lst" ]; then
        while IFS= read -r line; do
            info_out "ProxyN: $line"
        done < "$TMPD/proxy.lst"
        info_out "Evidence is filtered on purpose; full running-config is intentionally not dumped (may contain unrelated secrets)"
    else
        unknown_out "no ProxyN evidence found in filtered running-config"
    fi
else
    nt_out "ProxyN/segments evidence NOT TESTED (ndmc unavailable)"
fi

section "Verdict"
info_out "Controller authentication: $AUTH_STATE"
info_out "Local unauthenticated API access: $ACCESS_STATE"
info_out "Reminder: LISTENING does not equal reachable, and localhost-vantage answers do not prove external reachability. Keenetic firewall/NAT rules are not read; WAN exposure must be judged from router firewall and port-forwarding settings. Multi-network routers (home/dacha/work/VPN) may expose non-loopback listeners to several subnets; binding to br0 alone does not prevent that."
if [ "$HAVE_TCP" -eq 0 ] && [ "$HAVE_TCP6" -eq 0 ]; then
    unknown_out "No listening-socket evidence was available at all; the audit is inconclusive, not clean."
    exit 3
fi
if [ "$CONTRADICTION" -eq 1 ]; then
    fail_out "Declared Controller authentication state and the live unauthenticated probe disagree; review the [FAIL] line above (read-only audit; nothing was changed)."
    exit 1
fi
pass_out "Audit complete: the lines above are observed facts and clearly marked UNKNOWN items; wildcard and non-loopback bindings are facts, not counted as vulnerabilities."
exit 0
