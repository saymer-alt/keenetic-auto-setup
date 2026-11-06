#!/bin/sh
# The actual Doctor IPv4/IPv6 layer reader and read-only audit are extracted
# from production source. Mock ndmc responses model KeeneticOS summary.layer,
# including a link-local address despite IPv6 being disabled on a LAN bridge.
# No real router, WAN, config, DNS or network mutation.
set -eu

ROOT="$1"
DOCTOR="$ROOT/mihomo-doctor.sh"
TMP="/tmp/kas-doctor-ipv6.$$"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP"
die() { echo "[FAIL] $1" >&2; exit 1; }

awk '
    /# BEGIN DOCTOR INTERFACE IPV6 LAYER READER v1/ {copy=1}
    copy {print}
    /# END DOCTOR INTERFACE IPV6 LAYER READER v1/ {exit}
' "$DOCTOR" > "$TMP/reader.sh"
awk '
    /# BEGIN DOCTOR INTERFACE IPV6 AUDIT v1/ {copy=1}
    copy {print}
    /# END DOCTOR INTERFACE IPV6 AUDIT v1/ {exit}
' "$DOCTOR" > "$TMP/audit.sh"
[ -s "$TMP/reader.sh" ] || die "Doctor IPv6 layer reader missing"
[ -s "$TMP/audit.sh" ] || die "Doctor IPv6 audit missing"
sh -n "$TMP/reader.sh"
sh -n "$TMP/audit.sh"

ndmc() {
    [ "$1" = "-c" ] || return 90
    case "$2" in
        "show interface Proxy0")
            if [ "$MODE" = unknown ]; then
                echo 'error: read timeout'
                return 1
            fi
            cat <<EOF
id: Proxy0
link: up
connected: yes
state: up
ipv6:
    addresses:
        address: fe80::1111
summary:
    layer:
        conf: running
        ipv4: $( [ "$MODE" = incident ] && echo disabled || echo running )
        ipv6: $( [ "$MODE" = incident ] && echo pending || echo running )
        ctrl: running
EOF
            ;;
        "show interface Bridge0")
            cat <<'EOF'
id: Bridge0
description: SSTP_SE
ipv6:
    addresses:
        address: fe80::abcd
summary:
    layer:
        ipv4: running
        ipv6: disabled
EOF
            ;;
        "show interface Bridge1")
            cat <<'EOF'
id: Bridge1
summary:
    layer:
        ipv4: running
        ipv6: running
EOF
            ;;
        *)
            return 91
            ;;
    esac
}

run_case() {
    MODE=$1
    PROJECT_PROXY=Proxy0
    RC_DUMP='interface Proxy0
 proxy protocol socks5
!
interface Bridge0
!
interface Bridge1
!'
    out=$(
        info() { printf 'INFO %s\n' "$1"; }
        warn() { printf 'WARN %s\n' "$1"; }
        . "$TMP/reader.sh"
        . "$TMP/audit.sh"
    )
    printf '%s\n' "$out" | grep -Fq 'LAN segment Bridge0: IPv6 runtime=disabled' ||
        die "$MODE: disabled segment not reported"
    printf '%s\n' "$out" | grep -Fq 'LAN segment Bridge1: IPv6 runtime=running' ||
        die "$MODE: enabled segment not reported"
    if [ "$MODE" = incident ]; then
        printf '%s\n' "$out" | grep -Fq 'WARN Project proxy Proxy0: IPv4 runtime=disabled' ||
            die "incident: disabled ProxyN IPv4 must WARN"
        printf '%s\n' "$out" | grep -Fq 'INFO Project proxy Proxy0: IPv6 runtime=pending' ||
            die "incident: ProxyN pending IPv6 must be reported separately"
    elif [ "$MODE" = normal ]; then
        if printf '%s\n' "$out" | grep -Fq 'WARN '; then
            die "normal: disabled LAN IPv6 must not WARN"
        fi
        printf '%s\n' "$out" | grep -Fq 'INFO Project proxy Proxy0: IPv4 runtime=running' ||
            die "normal: proxy IPv4 not found"
    else
        if printf '%s\n' "$out" | grep -Fq 'WARN '; then
            die "unknown: unreadable interface must never be treated as failure"
        fi
        printf '%s\n' "$out" | grep -Fq 'INFO Project proxy Proxy0: IPv4/IPv6 runtime=unknown' ||
            die "unknown: unreadable ProxyN not reported honestly"
    fi
    echo "[OK] $MODE"
}

run_case incident
run_case normal
run_case unknown
echo "[OK] Doctor per-segment IPv6 vs ProxyN runtime regression passed"
