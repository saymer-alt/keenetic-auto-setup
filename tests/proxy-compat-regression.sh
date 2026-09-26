#!/bin/sh
# Focused regression for the real legacy-Proxy duplication bug reported on
# 2026-09-26. Execute both independent parsers; do not emulate KeeneticOS.
set -eu

ROOT=${1:-.}

fail() { echo "[FAIL] $1" >&2; exit 1; }

extract_classifier() {
    sed -n '/^proxy_profile_class() {$/,/^}$/p' "$1"
}

run_cases() {
    _script="$1"
    _fn=$(extract_classifier "$ROOT/$_script")
    [ -n "$_fn" ] || fail "$_script: proxy_profile_class() not found"

    (
        eval "$_fn"

        RC_DUMP='interface Proxy0
 description "mihomo t2s0"
 proxy protocol socks5
 proxy socks5-udp
 proxy upstream 127.0.0.1 7890
!'
        proxy_profile_class Proxy0 0
        [ "$PROXY_PROFILE" = canonical ] || exit 21

        RC_DUMP='interface Proxy0
 description "mihomo"
 proxy protocol socks5
 proxy socks5-udp
 proxy upstream 127.0.0.1 7890
!'
        proxy_profile_class Proxy0 0
        [ "$PROXY_PROFILE" = legacy ] || exit 22

        RC_DUMP='interface Proxy0
 description "Proxy0"
 proxy protocol socks5
 proxy socks5-udp
 proxy upstream 127.0.0.1 7890
!'
        proxy_profile_class Proxy0 0
        [ "$PROXY_PROFILE" = legacy ] || exit 23

        RC_DUMP='interface Proxy0
 description "mihomo"
 proxy protocol socks5
 proxy upstream 127.0.0.1 7890
!'
        proxy_profile_class Proxy0 0
        [ "$PROXY_PROFILE" = foreign ] || exit 24

        RC_DUMP='interface Proxy0
 description "mihomo"
 proxy protocol socks5
 proxy socks5-udp
 proxy upstream 127.0.0.1 7891
!'
        proxy_profile_class Proxy0 0
        [ "$PROXY_PROFILE" = foreign ] || exit 25
    ) || fail "$_script: ProxyN compatibility classification mismatch"
}

run_cases install.sh
run_cases mihomo-doctor.sh

grep -Fq 'Using legacy-compatible proxy ${PROXY_IFACE}: SOCKS5 UDP -> 127.0.0.1:7890; existing description preserved' "$ROOT/install.sh" ||
    fail "installer must reuse legacy-compatible ProxyN without renaming"
grep -Fq 'Legacy Proxy naming detected; existing description is preserved and rename to mihomo t2s${PROJECT_PROXY#Proxy} is not required' "$ROOT/mihomo-doctor.sh" ||
    fail "Doctor must keep legacy naming informational"
grep -Fq 'check_info "Legacy Proxy description preserved as-is; rename to mihomo t2s${PROXY_IFACE#Proxy} is not required"' "$ROOT/install.sh" ||
    fail "installer self-check must keep old naming INFO-only"

echo "[OK] ProxyN legacy compatibility regression passed"
