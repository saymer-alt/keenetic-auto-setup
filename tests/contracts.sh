#!/bin/sh
# Small committed contract smoke test. It intentionally checks only regressions
# learned from real installations; it is not a KeeneticOS emulator.
set -eu

ROOT=${1:-.}
fail() { echo "[FAIL] $1" >&2; exit 1; }
pass() { echo "[OK] $1"; }

grep -q 'Клиент прокси' "$ROOT/README.md" || fail "README must name Proxy client as required"
pass "README names Proxy client prerequisite"

grep -q 'LOW-RAM / BEST-EFFORT INSTALL' "$ROOT/install.sh" || fail "installer must warn clearly on low-RAM devices"
grep -q '128 MB-class devices are allowed, but stability is NOT guaranteed' "$ROOT/install.sh" || fail "128 MB must remain allowed but explicitly best-effort"
pass "low-RAM install remains allowed with an explicit best-effort warning"

grep -q 'proxy_client_missing' "$ROOT/install.sh" || fail "installer must retain missing Proxy-client fail-fast path"
grep -q 'running-config after create' "$ROOT/install.sh" || fail "installer must read Proxy creation back"
grep -q 'Proxy0 appeared in running-config but the required project profile' "$ROOT/install.sh" || fail "installer must reject an incomplete Proxy0 profile"
grep -q 'Proxy${_n} appeared in running-config but the required project profile' "$ROOT/install.sh" || fail "installer must reject an incomplete ProxyN profile"
pass "Proxy creation has a full-profile read-back/fail-fast contract"

grep -q '^mixed-port: 7890$' "$ROOT/install.sh" || fail "bootstrap must expose mixed-port 7890"
grep -q 'Failed to write required Mihomo bootstrap config' "$ROOT/install.sh" || fail "clean install must fail if required bootstrap cannot be written"
grep -q 'config.yaml not found (required bootstrap missing)' "$ROOT/install.sh" || fail "self-check must fail when required bootstrap is absent"
pass "bootstrap is mandatory and exposes contract port 7890"

grep -q 'dns-proxy intercept enable' "$ROOT/install.sh" || fail "installer must enable DNS transit interception"
grep -q 'DNS transit interception (dns-proxy intercept enable) not found' "$ROOT/install.sh" || fail "self-check must verify DNS interception"
grep -q 'did not appear in running-config after enable' "$ROOT/install.sh" || fail "installer must fail early when DNS interception did not persist"
pass "DNS transit interception is installed, read back and verified"

grep -q 'No project-managed ProxyN marker found; existing Proxy interface(s):' "$ROOT/mihomo-doctor.sh" || fail "Doctor must keep unmarked ProxyN informational"
! grep -q 'foreign Proxy interface(s).*Keenetic has no bridge into Mihomo' "$ROOT/mihomo-doctor.sh" || fail "Doctor must not infer no Mihomo bridge from an unmarked ProxyN"
pass "Doctor does not misclassify an unmarked ProxyN as no bridge"

grep -q 'permit order is user-defined' "$ROOT/mihomo-doctor.sh" || fail "Doctor must preserve user-owned bypass_wa ordering semantics"
! grep -q 'bypass_wa policy has other interface permits but not the project proxy' "$ROOT/mihomo-doctor.sh" || fail "Doctor must not require the project ProxyN in a nonempty user-owned bypass policy"
pass "Doctor accepts nonempty user-owned bypass_wa policy"

echo "[OK] Contract smoke tests passed"
