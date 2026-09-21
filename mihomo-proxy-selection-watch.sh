#!/bin/sh

# mihomo-proxy-selection-watch.sh v1.2.0
#
# Watches the selected Mihomo proxy-group chain.
# This script does NOT inspect or change Keenetic/Linux routing tables.
#
# =========================================================
# MIHOMO PROXY SELECTION WATCH - read-only view of the proxy-group
# selection chain (universal Mihomo diagnostics).
#
# Resolves the effective final leaf server through nested
# groups (Selector / URLTest / Fallback / LoadBalance /
# Relay) via the Controller REST API and reports it. Useful
# for measuring exact failover and failback moments.
#
# STRICTLY READ-ONLY:
#   - the only request ever made is GET /proxies;
#   - never selects a node (PUT /proxies/:name), never
#     clears a fixed choice (DELETE), never triggers delay
#     tests (/delay endpoints), never restarts anything,
#     never writes configuration;
#   - observing cannot influence failover/failback.
#
# Semantics (mihomo source): Fallback.now = first alive
# member; Selector.now = the selected member; LoadBalance
# carries an empty "now" (per-connection choice) and is
# reported as "load-balanced" instead of a single server.
#
# Usage:
#   mihomo-proxy-selection-watch.sh [-g GROUP] [-u URL] [-s SECRET]
#                         [--watch N]
#
#   -g GROUP    starting group (default: GLOBAL)
#   -u URL      controller base URL
#               (default: http://127.0.0.1:9090)
#   -s SECRET   controller secret; otherwise the
#               MIHOMO_API_SECRET environment variable is
#               used when set. Never logged.
#   --watch N   poll every N seconds, print only changes,
#               each line timestamped; Ctrl-C to stop.
#
# Exit codes:
#   0  success (or watch ended by INT/TERM/HUP)
#   1  usage error, or curl/jq missing
#   2  controller unreachable (is external-controller set?
#      the doctor will tell you)
#   3  HTTP 401/403 - secret required or wrong
#   4  start group not found in /proxies
#   5  selection anomaly (cycle, depth cap, unknown "now",
#      malformed JSON response)
#
# Dependencies: curl, jq (both already project-standard).
# No files are written; everything goes to stdout/stderr.
# =========================================================

GROUP="GLOBAL"
URL="http://127.0.0.1:9090"
SECRET="${MIHOMO_API_SECRET:-}"
WATCH=""
CURL_TIMEOUT=5
MAX_HOPS=32

usage() {
    cat <<'USAGE'
mihomo-proxy-selection-watch.sh v1.2.0

What it does:
  Reads Mihomo Controller GET /proxies and follows the selected proxy-group
  chain (Selector / URLTest / Fallback / Relay). It prints the final selected
  proxy server. LoadBalance is reported as load-balanced because there is no
  single selected server.

What it does NOT do:
  It does not inspect Keenetic/Linux routing tables, change a proxy selection,
  trigger delay tests, restart Mihomo, or write configuration.

Requirements:
  - run on the Keenetic/Entware shell (or another host that can reach Controller)
  - curl and jq
  - Mihomo Controller enabled and reachable

Usage:
  sh mihomo-proxy-selection-watch.sh [-g GROUP] [-u URL] [-s SECRET] [--watch N]

Options:
  -g GROUP    starting Mihomo group (default: GLOBAL)
  -u URL      Controller base URL (default: http://127.0.0.1:9090)
  -s SECRET   Controller secret
              MIHOMO_API_SECRET is preferred so the secret is not typed into
              the command line
  --watch N   poll every N seconds and print only changes
  -h, --help  show this help
  -V, --version
              print script version

Examples:
  sh mihomo-proxy-selection-watch.sh
  sh mihomo-proxy-selection-watch.sh --watch 1
  sh mihomo-proxy-selection-watch.sh -g "My Group"
  sh mihomo-proxy-selection-watch.sh -u http://192.168.1.1:9090
  MIHOMO_API_SECRET='secret' sh mihomo-proxy-selection-watch.sh --watch 1

Typical output:
  GLOBAL -> Primary -> Sweden-1
  CURRENT SERVER: Sweden-1

Read-only contract: the only HTTP request ever made is GET /proxies.
Exit codes: 0 ok, 1 usage/missing tool, 2 Controller unreachable,
3 auth (401/403), 4 start group not found, 5 selection anomaly.
USAGE
}

usage_err() {
    echo "[proxy-selection-watch] $1" >&2
    usage >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        -g)          [ $# -ge 2 ] || usage_err "option $1 requires an argument"
                     GROUP=$2; shift 2 ;;
        -u)          [ $# -ge 2 ] || usage_err "option $1 requires an argument"
                     URL=$2; shift 2 ;;
        -s)          [ $# -ge 2 ] || usage_err "option $1 requires an argument"
                     SECRET=$2; shift 2 ;;
        --watch)     [ $# -ge 2 ] || usage_err "option $1 requires an argument"
                     WATCH=$2; shift 2 ;;
        --watch=*)   WATCH=${1#--watch=}; shift ;;
        -h|--help)   usage; exit 0 ;;
        -V|--version) echo "mihomo-proxy-selection-watch.sh v1.2.0"; exit 0 ;;
        --)          shift; break ;;
        *)           usage_err "unknown option: $1" ;;
    esac
done

URL=${URL%/}
case "$WATCH" in
    '') : ;;
    *[!0-9]*) usage_err "--watch requires a number of seconds" ;;
    0) usage_err "--watch requires at least 1 second" ;;
esac

command -v curl >/dev/null 2>&1 || {
    echo "[proxy-selection-watch] curl is required but not installed" >&2
    exit 1
}
command -v jq >/dev/null 2>&1 || {
    echo "[proxy-selection-watch] jq is required but not installed" >&2
    exit 1
}

# fetch_state(): one GET /proxies; sets FETCH_STATE and PROXIES_JSON.
# Classification is by curl exit code and HTTP status only.
fetch_state() {
    set --
    if [ -n "$SECRET" ]; then
        set -- "$@" -H "Authorization: Bearer $SECRET"
    fi
    RESP=$(curl -sS --max-time "$CURL_TIMEOUT" "$@" -w '
%{http_code}' "$URL/proxies" 2>/dev/null)
    FETCH_RC=$?
    if [ "$FETCH_RC" -ne 0 ]; then
        FETCH_STATE="unreachable"
        return 0
    fi
    CODE=$(printf '%s' "$RESP" | tail -n 1)
    BODY=$(printf '%s' "$RESP" | sed '$d')
    case "$CODE" in
        200) : ;;
        401|403) FETCH_STATE="auth"; return 0 ;;
        404) FETCH_STATE="notfound"; return 0 ;;
        *)   FETCH_STATE="http"; return 0 ;;
    esac
    PROXIES_JSON=$(printf '%s' "$BODY" | jq -c '.proxies // empty' 2>/dev/null)
    if [ -z "$PROXIES_JSON" ]; then
        FETCH_STATE="badjson"
        return 0
    fi
    FETCH_STATE="ok"
}

node_exists() {
    printf '%s' "$PROXIES_JSON" | jq -r --arg n "$1" 'if has($n) then "yes" else "no" end'
}

node_type() {
    printf '%s' "$PROXIES_JSON" | jq -r --arg n "$1" 'if has($n) then (.[$n].type // "") else "" end'
}

node_now() {
    printf '%s' "$PROXIES_JSON" | jq -r --arg n "$1" 'if has($n) then (.[$n].now // "") else "" end'
}

# resolve(): walk the group "now" chain; sets CHAIN, LEAF and
# RESOLVE_STATUS (ok | load-balanced | not-found | depth | cycle |
# unknown-now). A visited-set plus the hop cap bound the walk.
resolve() {
    CHAIN="$1"
    LEAF=""
    RESOLVE_STATUS=""
    if [ "$(node_exists "$1")" != "yes" ]; then
        RESOLVE_STATUS="not-found"
        return 0
    fi
    _cur="$1"
    _visited=" $1 "
    _hops=0
    while :; do
        _t=$(node_type "$_cur")
        case "$_t" in
            Selector|URLTest|Fallback|LoadBalance|Relay) : ;;
            *) LEAF="$_cur"; RESOLVE_STATUS="ok"; return 0 ;;
        esac
        _hops=$((_hops + 1))
        if [ "$_hops" -gt "$MAX_HOPS" ]; then
            LEAF="$_cur"
            RESOLVE_STATUS="depth"
            return 0
        fi
        _now=$(node_now "$_cur")
        if [ "$_t" = "LoadBalance" ] && [ -z "$_now" ]; then
            LEAF="$_cur"
            RESOLVE_STATUS="load-balanced"
            return 0
        fi
        if [ -z "$_now" ]; then
            LEAF="$_cur"
            RESOLVE_STATUS="unknown-now"
            return 0
        fi
        case "$_visited" in
            *" $_now "*)
                LEAF="$_now"
                RESOLVE_STATUS="cycle"
                return 0 ;;
        esac
        if [ "$(node_exists "$_now")" != "yes" ]; then
            # Provider-backed groups may expose the selected leaf only via
            # the group's "now" field without a separate top-level /proxies
            # object for that leaf. The non-empty "now" value is still the
            # effective selected server, so treat it as a terminal leaf.
            CHAIN="$CHAIN -> $_now"
            LEAF="$_now"
            RESOLVE_STATUS="ok"
            return 0
        fi
        _visited="$_visited$_now "
        CHAIN="$CHAIN -> $_now"
        _cur="$_now"
    done
}

if [ -z "$WATCH" ]; then
    # ---------------- one-shot ----------------
    fetch_state
    case "$FETCH_STATE" in
        unreachable)
            echo "[proxy-selection-watch] controller unreachable at $URL - is external-controller set in config.yaml? (the doctor will tell you)" >&2
            exit 2 ;;
        auth)
            echo "[proxy-selection-watch] controller rejected the request (HTTP $CODE) - a secret is required or the secret is wrong" >&2
            exit 3 ;;
        notfound)
            echo "[proxy-selection-watch] unexpected HTTP 404 from the controller" >&2
            exit 4 ;;
        http)
            echo "[proxy-selection-watch] unexpected HTTP status from the controller: $CODE" >&2
            exit 2 ;;
        badjson)
            echo "[proxy-selection-watch] controller returned malformed JSON" >&2
            exit 5 ;;
    esac
    resolve "$GROUP"
    case "$RESOLVE_STATUS" in
        ok)
            printf '%s\n' "$CHAIN"
            printf 'CURRENT SERVER: %s\n' "$LEAF"
            exit 0 ;;
        load-balanced)
            printf '%s\n' "$CHAIN"
            printf 'CURRENT SERVER: [load-balanced - no single selected node]\n'
            exit 0 ;;
        not-found)
            echo "[proxy-selection-watch] start group not found in /proxies: $GROUP" >&2
            exit 4 ;;
        *)
            echo "[proxy-selection-watch] selection anomaly ($RESOLVE_STATUS): $CHAIN" >&2
            exit 5 ;;
    esac
fi

# ---------------- watch mode ----------------
trap 'exit 0' INT TERM HUP
_prev="__init__"
while :; do
    fetch_state
    line=""
    case "$FETCH_STATE" in
        unreachable)
            line="[controller unreachable]" ;;
        auth)
            echo "[proxy-selection-watch] controller rejected the request (HTTP $CODE) - a secret is required or the secret is wrong" >&2
            exit 3 ;;
        notfound)
            echo "[proxy-selection-watch] unexpected HTTP 404 from the controller" >&2
            exit 4 ;;
        http)
            line="[controller error: HTTP $CODE]" ;;
        badjson)
            line="[controller error: malformed response]" ;;
        ok)
            resolve "$GROUP"
            case "$RESOLVE_STATUS" in
                ok)
                    line="$CHAIN | CURRENT SERVER: $LEAF" ;;
                load-balanced)
                    line="$CHAIN | CURRENT SERVER: [load-balanced]" ;;
                not-found)
                    echo "[proxy-selection-watch] start group not found in /proxies: $GROUP" >&2
                    exit 4 ;;
                *)
                    echo "[proxy-selection-watch] selection anomaly ($RESOLVE_STATUS): $CHAIN" >&2
                    exit 5 ;;
            esac ;;
    esac
    if [ "$line" != "$_prev" ]; then
        printf '%s %s\n' "$(date '+%H:%M:%S')" "$line"
        _prev="$line"
    fi
    sleep "$WATCH"
done
