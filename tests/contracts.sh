#!/bin/sh
# Small committed contract smoke test. It intentionally checks only regressions
# learned from real installations; it is not a KeeneticOS emulator.
set -eu

ROOT=${1:-.}
fail() { echo "[FAIL] $1" >&2; exit 1; }
pass() { echo "[OK] $1"; }

grep -q 'Proxy client / Клиент прокси' "$ROOT/docs/COMPONENTS.md" || fail "component contract must name Proxy client"
grep -q '\*\*REQUIRED\*\*' "$ROOT/docs/COMPONENTS.md" || fail "component contract must mark required capabilities"
pass "component contract records Proxy client prerequisite"

PROFILE_CONTRACT=20260921_1
for _f in install.sh mihomo-doctor.sh update-mihomo.sh; do
    grep -q "RESOURCE_PROFILE_CONTRACT_VERSION=$PROFILE_CONTRACT" "$ROOT/$_f" ||
        fail "$_f must carry resource-profile contract $PROFILE_CONTRACT"
done
pass "installer, doctor and updater pin the same resource-profile contract version"

grep -q 'LOW-RAM / BEST-EFFORT INSTALL' "$ROOT/install.sh" || fail "installer must warn clearly on low-RAM devices"
grep -q 'EXPERIMENTAL / NO STABILITY GUARANTEE' "$ROOT/install.sh" || fail "128 MB must stay explicitly experimental"
grep -q 'requires /opt on EXTERNAL persistent storage' "$ROOT/install.sh" || fail "128 MB-class requires external /opt"
grep -q 'EXTERNAL storage-backed active swap' "$ROOT/install.sh" || fail "128 MB-class requires external swap >=384 MB"
grep -q 'does NOT count toward the required external-swap minimum' "$ROOT/install.sh" || fail "zRAM must not satisfy 128 MB external-swap minimum"
grep -q 'SWAP128_MIN_KB=393216' "$ROOT/install.sh" || fail "128 MB external-swap project floor must remain 384 MB"
grep -q 'requires at least one ACTIVE memory-pressure backend' "$ROOT/install.sh" || fail "256 MB must accept one of two supported memory backends"
grep -q 'KeeneticOS zRAM OR EXTERNAL storage-backed swap' "$ROOT/install.sh" || fail "256 MB contract must allow zRAM or external storage-backed swap"
grep -q 'Vendor guidance says not to use zRAM together with a disk/file swap' "$ROOT/install.sh" || fail "installer must warn against simultaneous zRAM and disk swap"
if grep -q 'requires ACTIVE native KeeneticOS zRAM' "$ROOT/install.sh"; then fail "installer must not require zRAM when external swap is active"; fi
grep -q '512 MB+ device.*no active zRAM/swap - allowed' "$ROOT/install.sh" || fail "512 MB+ without swap must be allowed"
pass "installer enforces corrected resource profile"

grep -q 'Low-RAM prerequisite NOT met' "$ROOT/mihomo-doctor.sh" || fail "doctor must FAIL unmet 128 MB prerequisite"
grep -q '256 MB-class with external storage-backed swap' "$ROOT/mihomo-doctor.sh" || fail "doctor must accept external swap as the 256 MB alternative to zRAM"
grep -q 'zRAM and external storage-backed swap are active together' "$ROOT/mihomo-doctor.sh" || fail "doctor must surface the vendor coexistence warning"
grep -q '512 MB+ device has no active zRAM/swap - allowed' "$ROOT/mihomo-doctor.sh" || fail "doctor must treat 512 MB+ without swap as allowed"
grep -q 'Swap backends: zRAM' "$ROOT/mihomo-doctor.sh" || fail "doctor must classify swap backends"
pass "doctor mirrors corrected resource profile"

grep -q 'UNSUPPORTED MEMORY PROFILE: 128 MB-class' "$ROOT/update-mihomo.sh" || fail "updater must warn unsupported 128 MB legacy layouts"
grep -q 'UNSUPPORTED MEMORY PROFILE: 256 MB-class without active zRAM or external swap' "$ROOT/update-mihomo.sh" || fail "updater must warn 256 MB only when neither backend is active"
grep -q 'MEMORY BACKEND WARNING: zRAM + external storage-backed swap are both active' "$ROOT/update-mihomo.sh" || fail "updater must warn against simultaneous zRAM and disk swap"
if grep -q 'MEMORY PROFILE WARNING: 512 MB+ with no active zRAM/swap' "$ROOT/update-mihomo.sh"; then fail "updater must not warn solely because 512 MB+ has no swap"; fi
grep -q 'The updater will continue only to service this existing installation' "$ROOT/update-mihomo.sh" || fail "profile warning must not become updater hard gate"
pass "updater warns strongly but keeps legacy updates serviceable"

grep -q '^HEALTHY_LOG_INTERVAL=1200$' "$ROOT/mihomo-watchdog.sh" || fail "watchdog healthy heartbeat must stay throttled to 20 minutes"
grep -q 'log_healthy "$wan_path" "$wan_target_ok"' "$ROOT/mihomo-watchdog.sh" || fail "watchdog must use the throttled healthy heartbeat"
grep -q 'reset_healthy_heartbeat' "$ROOT/mihomo-watchdog.sh" || fail "watchdog problems must force the next healthy recovery marker"
grep -Fq '[ "$last_path" != "$wan_path" ]' "$ROOT/mihomo-watchdog.sh" || fail "watchdog must detect primary/whitelist path changes"
grep -q 'path_changed=1' "$ROOT/mihomo-watchdog.sh" || fail "watchdog WAN path changes must bypass the 20-minute heartbeat throttle"
if grep -q 'log "\[WAN\] Connectivity OK via' "$ROOT/mihomo-watchdog.sh"; then
    fail "watchdog must not restore the per-run WAN success log noise"
fi
pass "watchdog throttles routine healthy noise but logs problems, recovery and WAN-path changes immediately"

grep -q 'CHECK_CAN_EXEC=0' "$ROOT/migrate-mihomo-mips.sh" || fail "migrator --check must default to no Mihomo execution"
grep -q 'executable version/support probes skipped (one-Mihomo invariant)' "$ROOT/migrate-mihomo-mips.sh" || fail "migrator --check must skip binary probes while daemon runs"
grep -Fq 'if [ "$CHECK_CAN_EXEC" -eq 1 ]; then' "$ROOT/migrate-mihomo-mips.sh" || fail "migrator --check binary probes must be guarded"
pass "migrator --check obeys the one-Mihomo invariant"

grep -q 'CRON_LEGACY_BAK="/opt/etc/mihomo_watchdog.legacy.bak"' "$ROOT/update-watchdog.sh" || fail "watchdog legacy backup must live outside cron.5mins"
grep -q 'CRON_LEGACY_BAK_OLD="/opt/etc/cron.5mins/mihomo_watchdog.legacy.bak"' "$ROOT/update-watchdog.sh" || fail "watchdog updater must recognize the old in-cron backup path"
grep -q 'chmod -x "$CRON_LEGACY_BAK"' "$ROOT/update-watchdog.sh" || fail "watchdog legacy backup must be non-executable"
pass "watchdog updater cannot leave an executable legacy backup in cron.5mins"

grep -q 'WATCHDOG_LEGACY_BAK_OLD=' "$ROOT/mihomo-doctor.sh" || fail "doctor must know the historical in-cron watchdog backup path"
grep -q 'Executable legacy watchdog backup remains inside cron.5mins' "$ROOT/mihomo-doctor.sh" || fail "doctor must warn about executable legacy watchdog backup"
pass "doctor detects the historical duplicate-watchdog backup condition"

grep -q 'probe_controller_proxy_state' "$ROOT/mihomo-doctor.sh" || fail "doctor must retain Controller /proxies selection sanity check"
grep -q 'GET /proxies' "$ROOT/mihomo-doctor.sh" || fail "doctor proxy sanity check must remain read-only"
grep -q 'GLOBAL and selected group report current choices' "$ROOT/mihomo-doctor.sh" || fail "doctor must recognize a usable selected-group state"
grep -q 'non-empty provider-backed/current choice' "$ROOT/mihomo-doctor.sh" || fail "doctor must accept provider-backed current choices"
pass "doctor performs lightweight read-only Mihomo proxy-selection sanity"

grep -q '=== What needs attention ===' "$ROOT/mihomo-doctor.sh" || fail "doctor must provide a human-readable findings block"
grep -q 'Next: %s' "$ROOT/mihomo-doctor.sh" || fail "doctor findings block must include actionable next steps"
grep -q 'No FAIL/WARN findings. No action is required' "$ROOT/mihomo-doctor.sh" || fail "doctor must explain a clean result"
grep -q 'Enable one supported backend: KeeneticOS zRAM OR external storage-backed swap' "$ROOT/mihomo-doctor.sh" || fail "doctor must explain the corrected 256 MB backend choice"
grep -q 'Run update-watchdog.sh, then run Doctor again' "$ROOT/mihomo-doctor.sh" || fail "doctor must explain watchdog repair findings"
pass "doctor summarizes WARN/FAIL findings with human-readable next steps"




grep -q 'Provider-backed groups may expose the selected leaf only via' "$ROOT/mihomo-proxy-selection-watch.sh" || fail "proxy watcher must support provider-backed leaf names"
grep -q 'CHAIN="$CHAIN -> $_now"' "$ROOT/mihomo-proxy-selection-watch.sh" || fail "proxy watcher must report terminal now leaf"
pass "proxy watcher accepts a non-top-level selected leaf from group now"


grep -q 'Adding MagiTrickle package repository' "$ROOT/install.sh" || fail "installer must own the MagiTrickle repository/setup messaging"
grep -q 'sh >/dev/null' "$ROOT/install.sh" || fail "upstream MagiTrickle helper stdout must be suppressed"
grep -q 'MagiTrickle installed and started' "$ROOT/install.sh" || fail "installer must confirm the automated MagiTrickle outcome"
if grep -q 'pkg_ensure magitrickle || warn' "$ROOT/install.sh"; then
    fail "MagiTrickle install must not pretend pkg_ensure can fall through to warn"
fi
pass "MagiTrickle installation output is owned by install.sh"

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

sh -n "$ROOT/mihomo-proxy-selection-watch.sh" || fail "proxy-selection-watch must remain valid POSIX shell syntax"
grep -qi 'read-only' "$ROOT/mihomo-proxy-selection-watch.sh" || fail "proxy-selection-watch must document its read-only API contract"
grep -Eq 'the only (HTTP )?request ever made is GET /proxies' "$ROOT/mihomo-proxy-selection-watch.sh" || fail "proxy-selection-watch must keep GET /proxies as its only request"
grep -q '401|403)' "$ROOT/mihomo-proxy-selection-watch.sh" || fail "proxy-selection-watch must classify Controller 401/403 as auth rejection"
grep -q 'CURRENT SERVER:' "$ROOT/mihomo-proxy-selection-watch.sh" || fail "proxy-selection-watch must retain the final leaf-server output contract"
grep -q 'does NOT inspect or change Keenetic/Linux routing tables' "$ROOT/mihomo-proxy-selection-watch.sh" || fail "proxy-selection-watch must not be confused with Keenetic route-table diagnostics"
grep -q -- '--version' "$ROOT/mihomo-proxy-selection-watch.sh" || fail "proxy-selection-watch must remain self-identifying"
grep -q 'mihomo-proxy-selection-watch.sh' "$ROOT/README.md" || fail "README must surface the optional proxy-selection-watch helper"
grep -q 'docs/11-proxy-selection-watch.md' "$ROOT/README.md" || fail "README must link the shareable proxy-selection-watch guide"
pass "proxy-selection-watch remains visible, self-explanatory, read-only and auth-aware"

echo "[OK] Contract smoke tests passed"
