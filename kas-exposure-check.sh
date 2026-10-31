#!/bin/sh

# kas-exposure-check.sh v0.1.0
#
# Read-only local exposure audit (issue #159). It reports which TCP ports are
# actually LISTENING on this router (from /proc/net/tcp and /proc/net/tcp6,
# so it works even without ss/netstat), how each is bound (loopback / wildcard
# / specific address), and cross-checks the Mihomo config (allow-lan,
# bind-address, external-controller, secret presence — never the secret
# value) and the Controller authentication state.
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
# Exit codes: 0 = no unauthenticated non-loopback wildcard listener found;
# 1 = at least one risky listener; 2 = usage error.

set -u

PROG_NAME="kas-exposure-check.sh"
PROG_VERSION="0.1.0"
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

Statuses: PASS / FAIL / UNKNOWN / NOT TESTED / UNSUPPORTED
Exit codes: 0 no unauthenticated non-loopback wildcard listener found;
            1 at least one risky listener; 2 usage error;
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

RISKY=0
LISTEN_SEEN=0

report_listener() {
    # $1=family $2=hexaddr $3=hexport
    local _fam=$1 _hx=$2 _port=$3 _cls _what
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
            fail_out "$_fam port $_port bound to $_cls${_what:+ — $_what}; reachability depends on firewall/NAT (not verified here)"
            RISKY=$((RISKY+1))
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
            *true*) fail_out "allow-lan is enabled: Mihomo ports are intended to serve LAN clients, not only loopback" ;;
        esac
    else
        info_out "config: allow-lan not set (Mihomo defaults to loopback binding)"
    fi
    _ec=$(grep -E "^external-controller:" "$CONFIG_PATH" 2>/dev/null | head -n 1 | tr -d '\r')
    if [ -n "$_ec" ]; then
        info_out "config: $_ec"
        case "$_ec" in
            *127.0.0.1*|*localhost*) pass_out "external-controller bound to loopback" ;;
            *) fail_out "external-controller bound to a non-loopback address"; RISKY=$((RISKY+1)) ;;
        esac
    else
        info_out "config: external-controller not set"
    fi
    # Classify presence only. The secret value is masked before any use.
    _sec=$(grep -E "^secret:" "$CONFIG_PATH" 2>/dev/null | head -n 1 | tr -d '\r')
    if [ -n "$_sec" ]; then
        _sec=${_sec#secret:}
        _sec=${_sec%%#*}                 # drop trailing comment
        _sec_masked=$(printf '%s' "$_sec" | tr -d "'\"" | tr -d ' \t')
        if [ -n "$_sec_masked" ]; then
            pass_out "Controller secret: SET (value intentionally not shown)"
        else
            fail_out "Controller secret: present but empty (unauthenticated API if the controller is not loopback-only)"
            RISKY=$((RISKY+1))
        fi
    else
        fail_out "Controller secret: not found in config (unauthenticated API if the controller is not loopback-only)"
        RISKY=$((RISKY+1))
    fi
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
    _code=$(curl -sS -o /dev/null --connect-timeout "$CURL_TIMEOUT" --max-time "$CURL_TIMEOUT" -w '%{http_code}' "$_PROBE_URL" 2>/dev/null </dev/null)
    _rc=$?
    case "$_rc" in
        0)
            case "$_code" in
                401|403) pass_out "Controller answered HTTP $_code: authentication enforced at $_PROBE_URL" ;;
                200) fail_out "Controller answered HTTP 200 WITHOUT authentication at $_PROBE_URL"; RISKY=$((RISKY+1)) ;;
                *) unknown_out "Controller answered HTTP $_code at $_PROBE_URL" ;;
            esac
            ;;
        *)
            unknown_out "Controller probe could not connect (curl exit $_rc) at $_PROBE_URL"
            ;;
    esac
else
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
info_out "Reminder: LISTENING does not equal reachable. Keenetic firewall/NAT rules are not read; WAN exposure must be judged from router firewall and port-forwarding settings. Multi-network routers (home/dacha/work/VPN) may expose non-loopback listeners to several subnets; binding to br0 alone does not prevent that."
if [ "$RISKY" -eq 0 ]; then
    if [ "$HAVE_TCP" -eq 0 ] && [ "$HAVE_TCP6" -eq 0 ]; then
        unknown_out "No listening-socket evidence was available at all; the audit is inconclusive, not clean."
        exit 3
    fi
    pass_out "No unauthenticated non-loopback wildcard listener detected in the checked evidence."
    exit 0
fi
fail_out "$RISKY risky binding(s)/finding(s) above; review firewall/NAT for the listed ports and consider loopback-only bindings or authentication."
exit 1
