#!/bin/sh
# Regression for the 2026-10-31 field failure (issue #310) and its 2026-10-14
# Hopper precedent (#144): on a fresh Entware stack with a reused
# legacy-compatible Proxy0 nothing invoked netfilter.d after hook delivery —
# the interface reactivation trigger skipped every non-canonical interface —
# so _CUST_BYPASS_WA_ stayed absent and the post-install self-check failed
# ("bypass_wa Netfilter not ready ... chain cannot be inspected", exit 1).
#
# The test executes the REAL production functions extracted from install.sh
# with a mocked ndmc and logging only (same convention as
# tests/netfilter-live-regression.sh). It does not emulate KeeneticOS beyond a
# running-config fixture, and no router, firewall, policy or table is touched.
set -eu

ROOT=${1:-.}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kas-nf-first-install.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

fail() { echo "[FAIL] $1" >&2; exit 1; }

# --- real production functions, extracted verbatim --------------------------
{
    sed -n '/^load_rc_dump() {$/,/^}$/p' "$ROOT/install.sh"
    sed -n '/^proxy_state() {$/,/^}$/p' "$ROOT/install.sh"
    sed -n '/^proxy_profile_class() {$/,/^}$/p' "$ROOT/install.sh"
    sed -n '/^proxy_is_compatible() {$/,/^}$/p' "$ROOT/install.sh"
    sed -n '/^proxy_is_canonical() {$/,/^}$/p' "$ROOT/install.sh"
    sed -n '/^activate_bypass_on_fresh_proxy() {$/,/^}$/p' "$ROOT/install.sh"
} > "$WORK/functions.sh"
[ -s "$WORK/functions.sh" ] || fail "could not extract production functions"
grep -q '^activate_bypass_on_fresh_proxy() {' "$WORK/functions.sh" ||
    fail "activation function was not extracted from install.sh"
sh -n "$WORK/functions.sh" || fail "extracted production functions are not valid shell"

# --- mocks and captures ------------------------------------------------------
NDMC_LOG="$WORK/ndmc.log"
NDMC_DOWN_FAILS=0
RC_FIXTURE=""
MESSAGES=""

log()  { MESSAGES="$MESSAGES
LOG: $1"; }
warn() { MESSAGES="$MESSAGES
WARN: $1"; }
err()  { MESSAGES="$MESSAGES
ERROR: $1"; exit 70; }

ndmc() {
    printf '%s\n' "$*" >> "$NDMC_LOG"
    case "$2" in
        "show running-config")
            [ -n "$RC_FIXTURE" ] || return 1
            printf '%s\n' "$RC_FIXTURE"
            return 0
            ;;
    esac
    case "$*" in
        *" down")
            # Simulate a KeeneticOS that rejects the DOWN write.
            [ "$NDMC_DOWN_FAILS" -gt 0 ] && return 1
            ;;
    esac
    return 0
}

# Production retry loop sleeps 1s between UP attempts; tests must not wait.
sleep() { :; }

# --- running-config fixtures -------------------------------------------------
RC_CANONICAL_UP='interface Proxy0
 description "mihomo t2s0"
 proxy protocol socks5
 proxy socks5-udp
 proxy upstream 127.0.0.1 7890
 up
!'
RC_CANONICAL_DOWN='interface Proxy0
 description "mihomo t2s0"
 proxy protocol socks5
 proxy socks5-udp
 proxy upstream 127.0.0.1 7890
!'
# The field case: a bridge left by a previous KAS life before Entware was
# wiped. Functionally project-owned (SOCKS5 + UDP -> 127.0.0.1:7890, UP), but
# with the user legacy description, hence not "canonical".
RC_LEGACY_UP='interface Proxy0
 description "Proxy0"
 proxy protocol socks5
 proxy socks5-udp
 proxy upstream 127.0.0.1 7890
 up
!'
RC_FOREIGN_UP='interface Proxy0
 description "my own tunnel"
 proxy protocol socks5
 proxy socks5-udp
 proxy upstream 192.168.10.5 1080
 up
!'

init_case() {
    PROXY_IFACE="Proxy0"
    PROXY_CREATED_THIS_RUN=0
    PROXY_FRESH_ENTWARE=1
    PROXY_RESTORE_PENDING=""
    RC_FIXTURE="$1"
    NDMC_DOWN_FAILS=0
    MESSAGES=""
    : > "$NDMC_LOG"
}

toggled() {
    grep -Fq -- '-c interface Proxy0 down' "$NDMC_LOG" &&
        grep -Fq -- '-c interface Proxy0 up' "$NDMC_LOG"
}

not_toggled() { ! grep -Fq -- 'interface Proxy0 down' "$NDMC_LOG"; }
not_renamed() { ! grep -Eq 'description' "$NDMC_LOG"; }
warned_no_toggle() { printf '%s\n' "$MESSAGES" | grep -Fq 'no interface toggle'; }

. "$WORK/functions.sh"

run_activation() {
    # The installer invocation guard, verbatim in effect: the function is
    # called only when the delivered hook is executable.
    activate_bypass_on_fresh_proxy
}

# 1) THE FIELD CASE (#310): fresh Entware + reused legacy-compatible Proxy0.
#    The hook was just delivered; nothing else will invoke netfilter.d, so the
#    installer MUST apply the verified down/up trigger. It must never rename
#    the legacy description (proxy-compat contract).
init_case "$RC_LEGACY_UP"
run_activation
toggled || fail "field case: legacy-compatible Proxy0 on a fresh stack got no down/up hook trigger (issue #310)"
not_renamed || fail "field case: legacy description must be preserved, never renamed"
warned_no_toggle && fail "field case: compatible bridge must not be reported as an unverified interface"
echo "[OK] field case: fresh Entware + legacy-compatible Proxy0 applies the hook trigger"

# 2) Foreign Proxy0 stays untouched even on a fresh stack.
init_case "$RC_FOREIGN_UP"
run_activation
not_toggled || fail "foreign Proxy0 must never be toggled"
warned_no_toggle || fail "foreign Proxy0 must be reported as not toggled"
echo "[OK] foreign Proxy0 untouched"

# 3) Canonical Proxy0 on a fresh stack: behavior already present on main must
#    not regress.
init_case "$RC_CANONICAL_UP"
run_activation
toggled || fail "canonical UP Proxy0 regression: down/up trigger missing"
echo "[OK] canonical UP Proxy0 trigger preserved"

# 4) Intentionally disabled canonical Proxy0 must stay DOWN (owner config).
init_case "$RC_CANONICAL_DOWN"
run_activation
not_toggled || fail "explicitly DOWN Proxy0 must not be activated"
printf '%s\n' "$MESSAGES" | grep -Fq 'not explicitly UP' ||
    fail "DOWN Proxy0 must be reported as intentionally disabled"
echo "[OK] explicitly DOWN Proxy0 preserved"

# 5) Existing (non-fresh) stack + reused interface: never bounce (reinstall
#    invariant, contracts.sh line pinned).
init_case "$RC_LEGACY_UP"
PROXY_FRESH_ENTWARE=0
run_activation
not_toggled || fail "existing stack + reused interface must not be toggled"
printf '%s\n' "$MESSAGES" | grep -Fq 'Skipping proxy activation' ||
    fail "existing-stack reuse must be reported as skipped"
echo "[OK] existing stack + reused interface not toggled"

# 6) KeeneticOS rejects the DOWN write: the installer must still try to
#    restore UP and must not leave the interface down.
init_case "$RC_LEGACY_UP"
NDMC_DOWN_FAILS=1
run_activation
grep -Fq -- '-c interface Proxy0 up' "$NDMC_LOG" ||
    fail "failed DOWN transition must still attempt the UP restore"
[ -z "$PROXY_RESTORE_PENDING" ] ||
    fail "restore pending marker must be cleared after a failed DOWN transition"
printf '%s\n' "$MESSAGES" | grep -Fq 'DOWN transition failed' ||
    fail "failed DOWN transition must be reported"
echo "[OK] failed DOWN transition restores UP and reports"

# 7) Created-this-run canonical proxy on an existing stack keeps the trigger
#    (PROXY_CREATED_THIS_RUN path).
init_case "$RC_CANONICAL_UP"
PROXY_FRESH_ENTWARE=0
PROXY_CREATED_THIS_RUN=1
run_activation
toggled || fail "created-this-run proxy must still be activated"
echo "[OK] created-this-run proxy trigger preserved"

echo "[OK] Netfilter first-install trigger regression passed"
