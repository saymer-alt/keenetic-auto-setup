#!/bin/sh

# mihomo-route-check.sh v1.0.0
#
# Focused read-only path diagnostic for one domain or IP.
# It does not modify routing, proxy selection, DNS, iptables, policies or config.
#
# Usage:
#   sh mihomo-route-check.sh example.com
#   sh mihomo-route-check.sh https://example.com/path
#   MIHOMO_API_SECRET='secret' sh mihomo-route-check.sh example.com

set -u

TARGET="${1:-}"
CONTROLLER_URL="${MIHOMO_CONTROLLER_URL:-http://127.0.0.1:9090}"
SECRET="${MIHOMO_API_SECRET:-}"
SOCKS_HOST="${MIHOMO_SOCKS_HOST:-127.0.0.1}"
SOCKS_PORT="${MIHOMO_SOCKS_PORT:-7890}"
GROUP="${MIHOMO_PROXY_GROUP:-GLOBAL}"
CURL_TIMEOUT=8

usage() {
    cat <<'USAGE'
mihomo-route-check.sh v1.0.0

Focused read-only diagnostic for one domain/IP.

Checks:
  1. target normalization and DNS resolution;
  2. project ProxyN evidence from Keenetic running-config;
  3. local Mihomo SOCKS/mixed port 7890;
  4. current Mihomo proxy-group selection through Controller GET /proxies;
  5. an HTTP(S) request to the target through SOCKS5h when curl is available.

This helper never changes routing, proxy selection, iptables, DNS or configuration.

Important limitation:
  A successful SOCKS5h probe proves that Mihomo can reach the target through the
  currently selected proxy path. It does NOT prove that a particular LAN client
  was classified into the expected MagiTrickle/Keenetic policy.

Usage:
  sh mihomo-route-check.sh <domain|IP|URL>

Examples:
  sh mihomo-route-check.sh example.com
  sh mihomo-route-check.sh https://example.com/
  MIHOMO_API_SECRET='secret' sh mihomo-route-check.sh example.com
USAGE
}

case "$TARGET" in
    ""|-h|--help) usage; [ -n "$TARGET" ] && exit 0 || exit 1 ;;
esac

say() { printf '%s\n' "$*"; }
section() { printf '\n=== %s ===\n' "$1"; }

# Normalize a URL to a host while preserving a probe URL.
case "$TARGET" in
    http://*|https://*)
        PROBE_URL="$TARGET"
        HOST=$(printf '%s' "$TARGET" | sed 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#/.*$##; s/:.*$//')
        ;;
    *)
        HOST="$TARGET"
        case "$TARGET" in
            *[!0-9.]* ) PROBE_URL="https://$TARGET/" ;;
            * )          PROBE_URL="http://$TARGET/" ;;
        esac
        ;;
esac

case "$HOST" in
    ""|*[!A-Za-z0-9._:-]*)
        say "[ERROR] Unsupported target: $TARGET"
        exit 1
        ;;
esac

section "Target"
say "Input: $TARGET"
say "Host:  $HOST"
say "Probe: $PROBE_URL"

section "DNS"
if command -v nslookup >/dev/null 2>&1; then
    if nslookup "$HOST" 2>&1; then
        :
    else
        say "[WARN] DNS resolution failed for $HOST"
    fi
else
    say "[INFO] nslookup unavailable; DNS resolution check skipped"
fi

section "Keenetic ProxyN"
if command -v ndmc >/dev/null 2>&1; then
    RUNNING=$(ndmc -c "show running-config" 2>/dev/null || true)
    if [ -n "$RUNNING" ]; then
        PROXY_LINES=$(printf '%s\n' "$RUNNING" | grep -E 'interface Proxy[0-9]+|proxy upstream|proxy protocol|description mihomo t2s' || true)
        if [ -n "$PROXY_LINES" ]; then
            printf '%s\n' "$PROXY_LINES"
            if printf '%s\n' "$RUNNING" | grep -q '127\.0\.0\.1.*7890'; then
                say "[OK] running-config contains a ProxyN path to 127.0.0.1:7890"
            else
                say "[WARN] no 127.0.0.1:7890 ProxyN upstream found in the filtered running-config evidence"
            fi
        else
            say "[WARN] no ProxyN evidence found in running-config"
        fi
    else
        say "[INFO] running-config could not be read"
    fi
else
    say "[INFO] ndmc unavailable; Keenetic ProxyN check skipped"
fi

section "Local Mihomo endpoint"
PORT_OK=0
if command -v netstat >/dev/null 2>&1; then
    if netstat -tln 2>/dev/null | grep -q "[:.]$SOCKS_PORT[[:space:]]"; then
        say "[OK] TCP port $SOCKS_PORT is listening"
        PORT_OK=1
    else
        say "[WARN] TCP port $SOCKS_PORT is not listening"
    fi
elif command -v ss >/dev/null 2>&1; then
    if ss -tln 2>/dev/null | grep -q "[:.]$SOCKS_PORT[[:space:]]"; then
        say "[OK] TCP port $SOCKS_PORT is listening"
        PORT_OK=1
    else
        say "[WARN] TCP port $SOCKS_PORT is not listening"
    fi
else
    say "[INFO] netstat/ss unavailable; port check skipped"
fi

section "Current Mihomo selection"
if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    set -- 
    if [ -n "$SECRET" ]; then
        set -- "$@" -H "Authorization: Bearer $SECRET"
    fi
    RESP=$(curl -sS --max-time "$CURL_TIMEOUT" "$@" -w '\n%{http_code}' "${CONTROLLER_URL%/}/proxies" 2>/dev/null || true)
    CODE=$(printf '%s\n' "$RESP" | tail -n 1)
    BODY=$(printf '%s\n' "$RESP" | sed '$d')
    case "$CODE" in
        200)
            NOW=$(printf '%s\n' "$BODY" | jq -r --arg g "$GROUP" '.proxies[$g].now // empty' 2>/dev/null)
            TYPE=$(printf '%s\n' "$BODY" | jq -r --arg g "$GROUP" '.proxies[$g].type // empty' 2>/dev/null)
            if [ -n "$TYPE" ]; then
                say "Group: $GROUP ($TYPE)"
                [ -n "$NOW" ] && say "Selected: $NOW" || say "Selected: not exposed as a single leaf"
            else
                say "[WARN] group '$GROUP' not found in Controller response"
            fi
            ;;
        401|403) say "[WARN] Controller requires a secret or the supplied secret was rejected" ;;
        *) say "[INFO] Controller selection unavailable (HTTP ${CODE:-unknown})" ;;
    esac
else
    say "[INFO] curl+jq unavailable; Controller selection check skipped"
fi

section "SOCKS5h target probe"
if ! command -v curl >/dev/null 2>&1; then
    say "[INFO] curl unavailable; target probe skipped"
elif [ "$PORT_OK" -eq 0 ]; then
    say "[INFO] target probe skipped because port $SOCKS_PORT was not confirmed listening"
else
    # -I is intentionally non-mutating for ordinary HTTP servers. Some servers reject
    # HEAD, so retry with a tiny GET that discards the body before declaring failure.
    CODE=$(curl -sS -o /dev/null -I --max-time "$CURL_TIMEOUT"         --socks5-hostname "$SOCKS_HOST:$SOCKS_PORT" -w '%{http_code}' "$PROBE_URL" 2>/dev/null || true)
    case "$CODE" in
        2??|3??|4??|5??)
            say "[OK] SOCKS5h request reached the target path (HTTP $CODE)"
            ;;
        *)
            CODE=$(curl -sS -o /dev/null --max-time "$CURL_TIMEOUT"                 --range 0-0 --socks5-hostname "$SOCKS_HOST:$SOCKS_PORT"                 -w '%{http_code}' "$PROBE_URL" 2>/dev/null || true)
            case "$CODE" in
                2??|3??|4??|5??) say "[OK] SOCKS5h request reached the target path (HTTP $CODE)" ;;
                *) say "[WARN] SOCKS5h request did not produce an HTTP response" ;;
            esac
            ;;
    esac
fi

section "Interpretation"
say "This report is read-only."
say "A successful SOCKS5h probe confirms Mihomo can reach the target through its current proxy path."
say "It does not by itself prove which policy a specific LAN client used; correlate client-policy issues with MagiTrickle/Keenetic policy evidence."
