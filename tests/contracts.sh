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

PROFILE_CONTRACT=20260921_2
for _f in install.sh mihomo-doctor.sh update-mihomo.sh; do
    grep -q "RESOURCE_PROFILE_CONTRACT_VERSION=$PROFILE_CONTRACT" "$ROOT/$_f" ||
        fail "$_f must carry resource-profile contract $PROFILE_CONTRACT"
done
pass "installer, doctor and updater pin the same resource-profile contract version"

grep -q '^PROJECT_REF="${KEENETIC_AUTO_SETUP_REF:-stable}"

grep -q 'LOW-RAM / BEST-EFFORT INSTALL' "$ROOT/install.sh" || fail "installer must warn clearly on low-RAM devices"
grep -q 'EXPERIMENTAL / NO STABILITY GUARANTEE' "$ROOT/install.sh" || fail "128 MB must stay explicitly experimental"
grep -q 'SWAP128_MIN_KB=393216' "$ROOT/install.sh" || fail "128 MB hard floor must remain 384 MB"
grep -q 'SWAP_MAX_KB=2097152' "$ROOT/install.sh" || fail "installer must cap external swap at 2 GiB"
grep -Fq "*'\\040(deleted)'*" "$ROOT/install.sh" || fail "installer must recognize kernel '(deleted)' swap sources"
grep -q "NOT counted toward verified external-SWAP capacity" "$ROOT/install.sh" || fail "installer must exclude deleted swap sources from capacity decisions"
grep -q '3x detected RAM, capped at 2048 MB' "$ROOT/install.sh" || fail "installer must expose the <=512 MB swap sizing target"
grep -q '256 MB-class device .*has neither active zRAM nor verified external storage-backed SWAP' "$ROOT/install.sh" || fail "256 MB missing backend must WARN"
grep -q '512 MB-class device .*has neither active zRAM nor verified external storage-backed SWAP' "$ROOT/install.sh" || fail "512 MB missing backend must WARN"
grep -q 'Stopping before package installation or project changes' "$ROOT/install.sh" || fail "oversized external swap must be an early installer error"
pass "installer enforces resource contract 20260921_2"

sh "$ROOT/tests/resource-scan-regression.sh" "$ROOT" ||
    fail "resource scanner must remain non-fatal for ordinary states under set -e"
pass "resource scanner does not abort install.sh before resource-profile policy handles the state"

sh "$ROOT/tests/resource-policy-regression.sh" "$ROOT" ||
    fail "resource policy fixtures must preserve hard gates and warning-only states"
pass "resource policy fixtures cover >2 GiB reject, 128 MB prerequisites, and zRAM+disk warning"

grep -q 'External storage-backed SWAP exceeds 2 GiB' "$ROOT/mihomo-doctor.sh" || fail "doctor must FAIL oversized external swap"
grep -q "swap source(s) are marked '(deleted)'" "$ROOT/mihomo-doctor.sh" || fail "doctor must surface stale/deleted swap sources"
grep -q '256 MB-class has neither active zRAM nor verified external storage-backed SWAP' "$ROOT/mihomo-doctor.sh" || fail "doctor must WARN 256 MB missing backend"
grep -q '512 MB-class has neither active zRAM nor verified external storage-backed SWAP' "$ROOT/mihomo-doctor.sh" || fail "doctor must WARN 512 MB missing backend"
grep -q 'External SWAP is below project sizing target' "$ROOT/mihomo-doctor.sh" || fail "doctor must explain project 3x sizing target"
pass "doctor mirrors resource contract 20260921_2"

grep -q 'UNSUPPORTED EXTERNAL SWAP SIZE: above 2 GiB' "$ROOT/update-mihomo.sh" || fail "updater must surface oversized external swap"
grep -q "UP_DELETED_COUNT" "$ROOT/update-mihomo.sh" || fail "updater must exclude deleted swap sources from capacity decisions"
grep -q 'MEMORY PROFILE WARNING: 256 MB-class without active zRAM or external swap' "$ROOT/update-mihomo.sh" || fail "updater must warn 256 MB missing backend"
grep -q 'MEMORY PROFILE WARNING: 512 MB-class without active zRAM or external swap' "$ROOT/update-mihomo.sh" || fail "updater must warn 512 MB missing backend"
grep -q 'The updater will continue only to service this existing installation' "$ROOT/update-mihomo.sh" || fail "profile warnings must not become updater hard gates"
pass "updater mirrors resource contract without blocking legacy service"

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
grep -q 'Enable one backend for the project profile: KeeneticOS zRAM OR external storage-backed SWAP' "$ROOT/mihomo-doctor.sh" || fail "doctor must explain the <=512 MB backend choice"
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

grep -q '^PROXY_COMPONENT_ID=proxy$' "$ROOT/install.sh" || fail "installer must use KeeneticOS component id proxy"
grep -q '^DNS_FILTER_COMPONENT_ID=dns-filter$' "$ROOT/install.sh" || fail "installer must use KeeneticOS component id dns-filter"
grep -q '^NETFILTER_COMPONENT_ID=opkg-kmod-netfilter$' "$ROOT/install.sh" || fail "installer must use KeeneticOS Netfilter component id"
grep -q 'Checking required KeeneticOS components' "$ROOT/install.sh" || fail "installer must run named-component preflight"
grep -q 'Missing required KeeneticOS component(s):' "$ROOT/install.sh" || fail "installer must label the missing-component list"
grep -Fq 'printf '\''%s\n'\'' "${_rc_missing_lines#?}" >&2' "$ROOT/install.sh" || fail "missing-component list must not start with a blank line"
grep -q 'Proxy client / Клиент прокси (${PROXY_COMPONENT_ID})' "$ROOT/install.sh" || fail "installer must name missing Proxy client clearly"
grep -q 'Cloud-based content filtering and ad blocking / Фильтрация контента и блокировка рекламы при помощи облачных сервисов (${DNS_FILTER_COMPONENT_ID})' "$ROOT/install.sh" || fail "installer must name missing dns-filter clearly"
grep -q 'Kernel modules for Netfilter / Модули ядра подсистемы Netfilter (${NETFILTER_COMPONENT_ID})' "$ROOT/install.sh" || fail "installer must name missing Netfilter clearly"
grep -q 'Full required component contract for the current default project profile' "$ROOT/install.sh" || fail "installer must distinguish missing list from full component contract"
grep -q 'No project components or router settings have been changed; stopping before installer-managed opkg update and project package installation' "$ROOT/install.sh" || fail "missing KeeneticOS prerequisites must stop before installer mutations"
_component_preflight_line=$(grep -n '^require_project_keeneticos_components$' "$ROOT/install.sh" | head -1 | cut -d: -f1)
_opkg_update_line=$(grep -n '^log "Updating opkg\.\.\."$' "$ROOT/install.sh" | head -1 | cut -d: -f1)
[ -n "$_component_preflight_line" ] && [ -n "$_opkg_update_line" ] && [ "$_component_preflight_line" -lt "$_opkg_update_line" ] ||
    fail "KeeneticOS component preflight must run before opkg update"
pass "required KeeneticOS components are verified before opkg or router changes"

grep -q 'proxy_client_missing' "$ROOT/install.sh" || fail "installer must retain post-create Proxy capability safety net"
grep -q 'running-config after create' "$ROOT/install.sh" || fail "installer must read Proxy creation back"
grep -q 'Proxy0 appeared in running-config but the required project profile' "$ROOT/install.sh" || fail "installer must reject an incomplete Proxy0 profile"
grep -q 'Proxy${_n} appeared in running-config but the required project profile' "$ROOT/install.sh" || fail "installer must reject an incomplete ProxyN profile"
pass "Proxy creation has a full-profile read-back/fail-fast contract"

grep -q '^mixed-port: 7890$' "$ROOT/install.sh" || fail "bootstrap must expose mixed-port 7890"
grep -q 'Failed to write required Mihomo bootstrap config' "$ROOT/install.sh" || fail "clean install must fail if required bootstrap cannot be written"
grep -q 'config.yaml not found (required bootstrap missing)' "$ROOT/install.sh" || fail "self-check must fail when required bootstrap is absent"
pass "bootstrap is mandatory and exposes contract port 7890"

grep -q '^wait_for_mihomo_contract_port()' "$ROOT/install.sh" || fail "installer must have a bounded Mihomo contract-port startup wait"
grep -q '\[ "$_wp_try" -le 5 \]' "$ROOT/install.sh" || fail "contract-port startup wait must remain bounded to five seconds after the immediate check"
grep -q 'Port 7890 still not listening after 5s startup wait' "$ROOT/install.sh" || fail "installer must warn only after the bounded startup wait"
grep -q 'Port 7890 listening' "$ROOT/install.sh" || fail "installer must report listener success"
pass "Mihomo contract-port self-check tolerates bounded startup latency"

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
 "$ROOT/install.sh" || fail "installer production ref must default to stable"
grep -q '^PROJECT_REF="${KEENETIC_AUTO_SETUP_REF:-stable}"

grep -q 'LOW-RAM / BEST-EFFORT INSTALL' "$ROOT/install.sh" || fail "installer must warn clearly on low-RAM devices"
grep -q 'EXPERIMENTAL / NO STABILITY GUARANTEE' "$ROOT/install.sh" || fail "128 MB must stay explicitly experimental"
grep -q 'SWAP128_MIN_KB=393216' "$ROOT/install.sh" || fail "128 MB hard floor must remain 384 MB"
grep -q 'SWAP_MAX_KB=2097152' "$ROOT/install.sh" || fail "installer must cap external swap at 2 GiB"
grep -Fq "*'\\040(deleted)'*" "$ROOT/install.sh" || fail "installer must recognize kernel '(deleted)' swap sources"
grep -q "NOT counted toward verified external-SWAP capacity" "$ROOT/install.sh" || fail "installer must exclude deleted swap sources from capacity decisions"
grep -q '3x detected RAM, capped at 2048 MB' "$ROOT/install.sh" || fail "installer must expose the <=512 MB swap sizing target"
grep -q '256 MB-class device .*has neither active zRAM nor verified external storage-backed SWAP' "$ROOT/install.sh" || fail "256 MB missing backend must WARN"
grep -q '512 MB-class device .*has neither active zRAM nor verified external storage-backed SWAP' "$ROOT/install.sh" || fail "512 MB missing backend must WARN"
grep -q 'Stopping before package installation or project changes' "$ROOT/install.sh" || fail "oversized external swap must be an early installer error"
pass "installer enforces resource contract 20260921_2"

sh "$ROOT/tests/resource-scan-regression.sh" "$ROOT" ||
    fail "resource scanner must remain non-fatal for ordinary states under set -e"
pass "resource scanner does not abort install.sh before resource-profile policy handles the state"

sh "$ROOT/tests/resource-policy-regression.sh" "$ROOT" ||
    fail "resource policy fixtures must preserve hard gates and warning-only states"
pass "resource policy fixtures cover >2 GiB reject, 128 MB prerequisites, and zRAM+disk warning"

grep -q 'External storage-backed SWAP exceeds 2 GiB' "$ROOT/mihomo-doctor.sh" || fail "doctor must FAIL oversized external swap"
grep -q "swap source(s) are marked '(deleted)'" "$ROOT/mihomo-doctor.sh" || fail "doctor must surface stale/deleted swap sources"
grep -q '256 MB-class has neither active zRAM nor verified external storage-backed SWAP' "$ROOT/mihomo-doctor.sh" || fail "doctor must WARN 256 MB missing backend"
grep -q '512 MB-class has neither active zRAM nor verified external storage-backed SWAP' "$ROOT/mihomo-doctor.sh" || fail "doctor must WARN 512 MB missing backend"
grep -q 'External SWAP is below project sizing target' "$ROOT/mihomo-doctor.sh" || fail "doctor must explain project 3x sizing target"
pass "doctor mirrors resource contract 20260921_2"

grep -q 'UNSUPPORTED EXTERNAL SWAP SIZE: above 2 GiB' "$ROOT/update-mihomo.sh" || fail "updater must surface oversized external swap"
grep -q "UP_DELETED_COUNT" "$ROOT/update-mihomo.sh" || fail "updater must exclude deleted swap sources from capacity decisions"
grep -q 'MEMORY PROFILE WARNING: 256 MB-class without active zRAM or external swap' "$ROOT/update-mihomo.sh" || fail "updater must warn 256 MB missing backend"
grep -q 'MEMORY PROFILE WARNING: 512 MB-class without active zRAM or external swap' "$ROOT/update-mihomo.sh" || fail "updater must warn 512 MB missing backend"
grep -q 'The updater will continue only to service this existing installation' "$ROOT/update-mihomo.sh" || fail "profile warnings must not become updater hard gates"
pass "updater mirrors resource contract without blocking legacy service"

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
grep -q 'Enable one backend for the project profile: KeeneticOS zRAM OR external storage-backed SWAP' "$ROOT/mihomo-doctor.sh" || fail "doctor must explain the <=512 MB backend choice"
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

grep -q '^PROXY_COMPONENT_ID=proxy$' "$ROOT/install.sh" || fail "installer must use KeeneticOS component id proxy"
grep -q '^DNS_FILTER_COMPONENT_ID=dns-filter$' "$ROOT/install.sh" || fail "installer must use KeeneticOS component id dns-filter"
grep -q '^NETFILTER_COMPONENT_ID=opkg-kmod-netfilter$' "$ROOT/install.sh" || fail "installer must use KeeneticOS Netfilter component id"
grep -q 'Checking required KeeneticOS components' "$ROOT/install.sh" || fail "installer must run named-component preflight"
grep -q 'Missing required KeeneticOS component(s):' "$ROOT/install.sh" || fail "installer must label the missing-component list"
grep -Fq 'printf '\''%s\n'\'' "${_rc_missing_lines#?}" >&2' "$ROOT/install.sh" || fail "missing-component list must not start with a blank line"
grep -q 'Proxy client / Клиент прокси (${PROXY_COMPONENT_ID})' "$ROOT/install.sh" || fail "installer must name missing Proxy client clearly"
grep -q 'Cloud-based content filtering and ad blocking / Фильтрация контента и блокировка рекламы при помощи облачных сервисов (${DNS_FILTER_COMPONENT_ID})' "$ROOT/install.sh" || fail "installer must name missing dns-filter clearly"
grep -q 'Kernel modules for Netfilter / Модули ядра подсистемы Netfilter (${NETFILTER_COMPONENT_ID})' "$ROOT/install.sh" || fail "installer must name missing Netfilter clearly"
grep -q 'Full required component contract for the current default project profile' "$ROOT/install.sh" || fail "installer must distinguish missing list from full component contract"
grep -q 'No project components or router settings have been changed; stopping before installer-managed opkg update and project package installation' "$ROOT/install.sh" || fail "missing KeeneticOS prerequisites must stop before installer mutations"
_component_preflight_line=$(grep -n '^require_project_keeneticos_components$' "$ROOT/install.sh" | head -1 | cut -d: -f1)
_opkg_update_line=$(grep -n '^log "Updating opkg\.\.\."$' "$ROOT/install.sh" | head -1 | cut -d: -f1)
[ -n "$_component_preflight_line" ] && [ -n "$_opkg_update_line" ] && [ "$_component_preflight_line" -lt "$_opkg_update_line" ] ||
    fail "KeeneticOS component preflight must run before opkg update"
pass "required KeeneticOS components are verified before opkg or router changes"

grep -q 'proxy_client_missing' "$ROOT/install.sh" || fail "installer must retain post-create Proxy capability safety net"
grep -q 'running-config after create' "$ROOT/install.sh" || fail "installer must read Proxy creation back"
grep -q 'Proxy0 appeared in running-config but the required project profile' "$ROOT/install.sh" || fail "installer must reject an incomplete Proxy0 profile"
grep -q 'Proxy${_n} appeared in running-config but the required project profile' "$ROOT/install.sh" || fail "installer must reject an incomplete ProxyN profile"
pass "Proxy creation has a full-profile read-back/fail-fast contract"

grep -q '^mixed-port: 7890$' "$ROOT/install.sh" || fail "bootstrap must expose mixed-port 7890"
grep -q 'Failed to write required Mihomo bootstrap config' "$ROOT/install.sh" || fail "clean install must fail if required bootstrap cannot be written"
grep -q 'config.yaml not found (required bootstrap missing)' "$ROOT/install.sh" || fail "self-check must fail when required bootstrap is absent"
pass "bootstrap is mandatory and exposes contract port 7890"

grep -q '^wait_for_mihomo_contract_port()' "$ROOT/install.sh" || fail "installer must have a bounded Mihomo contract-port startup wait"
grep -q '\[ "$_wp_try" -le 5 \]' "$ROOT/install.sh" || fail "contract-port startup wait must remain bounded to five seconds after the immediate check"
grep -q 'Port 7890 still not listening after 5s startup wait' "$ROOT/install.sh" || fail "installer must warn only after the bounded startup wait"
grep -q 'Port 7890 listening' "$ROOT/install.sh" || fail "installer must report listener success"
pass "Mihomo contract-port self-check tolerates bounded startup latency"

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
 "$ROOT/update-watchdog.sh" || fail "watchdog updater production ref must default to stable"
grep -q '^PROJECT_REF="${KEENETIC_AUTO_SETUP_REF:-stable}"

grep -q 'LOW-RAM / BEST-EFFORT INSTALL' "$ROOT/install.sh" || fail "installer must warn clearly on low-RAM devices"
grep -q 'EXPERIMENTAL / NO STABILITY GUARANTEE' "$ROOT/install.sh" || fail "128 MB must stay explicitly experimental"
grep -q 'SWAP128_MIN_KB=393216' "$ROOT/install.sh" || fail "128 MB hard floor must remain 384 MB"
grep -q 'SWAP_MAX_KB=2097152' "$ROOT/install.sh" || fail "installer must cap external swap at 2 GiB"
grep -Fq "*'\\040(deleted)'*" "$ROOT/install.sh" || fail "installer must recognize kernel '(deleted)' swap sources"
grep -q "NOT counted toward verified external-SWAP capacity" "$ROOT/install.sh" || fail "installer must exclude deleted swap sources from capacity decisions"
grep -q '3x detected RAM, capped at 2048 MB' "$ROOT/install.sh" || fail "installer must expose the <=512 MB swap sizing target"
grep -q '256 MB-class device .*has neither active zRAM nor verified external storage-backed SWAP' "$ROOT/install.sh" || fail "256 MB missing backend must WARN"
grep -q '512 MB-class device .*has neither active zRAM nor verified external storage-backed SWAP' "$ROOT/install.sh" || fail "512 MB missing backend must WARN"
grep -q 'Stopping before package installation or project changes' "$ROOT/install.sh" || fail "oversized external swap must be an early installer error"
pass "installer enforces resource contract 20260921_2"

sh "$ROOT/tests/resource-scan-regression.sh" "$ROOT" ||
    fail "resource scanner must remain non-fatal for ordinary states under set -e"
pass "resource scanner does not abort install.sh before resource-profile policy handles the state"

sh "$ROOT/tests/resource-policy-regression.sh" "$ROOT" ||
    fail "resource policy fixtures must preserve hard gates and warning-only states"
pass "resource policy fixtures cover >2 GiB reject, 128 MB prerequisites, and zRAM+disk warning"

grep -q 'External storage-backed SWAP exceeds 2 GiB' "$ROOT/mihomo-doctor.sh" || fail "doctor must FAIL oversized external swap"
grep -q "swap source(s) are marked '(deleted)'" "$ROOT/mihomo-doctor.sh" || fail "doctor must surface stale/deleted swap sources"
grep -q '256 MB-class has neither active zRAM nor verified external storage-backed SWAP' "$ROOT/mihomo-doctor.sh" || fail "doctor must WARN 256 MB missing backend"
grep -q '512 MB-class has neither active zRAM nor verified external storage-backed SWAP' "$ROOT/mihomo-doctor.sh" || fail "doctor must WARN 512 MB missing backend"
grep -q 'External SWAP is below project sizing target' "$ROOT/mihomo-doctor.sh" || fail "doctor must explain project 3x sizing target"
pass "doctor mirrors resource contract 20260921_2"

grep -q 'UNSUPPORTED EXTERNAL SWAP SIZE: above 2 GiB' "$ROOT/update-mihomo.sh" || fail "updater must surface oversized external swap"
grep -q "UP_DELETED_COUNT" "$ROOT/update-mihomo.sh" || fail "updater must exclude deleted swap sources from capacity decisions"
grep -q 'MEMORY PROFILE WARNING: 256 MB-class without active zRAM or external swap' "$ROOT/update-mihomo.sh" || fail "updater must warn 256 MB missing backend"
grep -q 'MEMORY PROFILE WARNING: 512 MB-class without active zRAM or external swap' "$ROOT/update-mihomo.sh" || fail "updater must warn 512 MB missing backend"
grep -q 'The updater will continue only to service this existing installation' "$ROOT/update-mihomo.sh" || fail "profile warnings must not become updater hard gates"
pass "updater mirrors resource contract without blocking legacy service"

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
grep -q 'Enable one backend for the project profile: KeeneticOS zRAM OR external storage-backed SWAP' "$ROOT/mihomo-doctor.sh" || fail "doctor must explain the <=512 MB backend choice"
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

grep -q '^PROXY_COMPONENT_ID=proxy$' "$ROOT/install.sh" || fail "installer must use KeeneticOS component id proxy"
grep -q '^DNS_FILTER_COMPONENT_ID=dns-filter$' "$ROOT/install.sh" || fail "installer must use KeeneticOS component id dns-filter"
grep -q '^NETFILTER_COMPONENT_ID=opkg-kmod-netfilter$' "$ROOT/install.sh" || fail "installer must use KeeneticOS Netfilter component id"
grep -q 'Checking required KeeneticOS components' "$ROOT/install.sh" || fail "installer must run named-component preflight"
grep -q 'Missing required KeeneticOS component(s):' "$ROOT/install.sh" || fail "installer must label the missing-component list"
grep -Fq 'printf '\''%s\n'\'' "${_rc_missing_lines#?}" >&2' "$ROOT/install.sh" || fail "missing-component list must not start with a blank line"
grep -q 'Proxy client / Клиент прокси (${PROXY_COMPONENT_ID})' "$ROOT/install.sh" || fail "installer must name missing Proxy client clearly"
grep -q 'Cloud-based content filtering and ad blocking / Фильтрация контента и блокировка рекламы при помощи облачных сервисов (${DNS_FILTER_COMPONENT_ID})' "$ROOT/install.sh" || fail "installer must name missing dns-filter clearly"
grep -q 'Kernel modules for Netfilter / Модули ядра подсистемы Netfilter (${NETFILTER_COMPONENT_ID})' "$ROOT/install.sh" || fail "installer must name missing Netfilter clearly"
grep -q 'Full required component contract for the current default project profile' "$ROOT/install.sh" || fail "installer must distinguish missing list from full component contract"
grep -q 'No project components or router settings have been changed; stopping before installer-managed opkg update and project package installation' "$ROOT/install.sh" || fail "missing KeeneticOS prerequisites must stop before installer mutations"
_component_preflight_line=$(grep -n '^require_project_keeneticos_components$' "$ROOT/install.sh" | head -1 | cut -d: -f1)
_opkg_update_line=$(grep -n '^log "Updating opkg\.\.\."$' "$ROOT/install.sh" | head -1 | cut -d: -f1)
[ -n "$_component_preflight_line" ] && [ -n "$_opkg_update_line" ] && [ "$_component_preflight_line" -lt "$_opkg_update_line" ] ||
    fail "KeeneticOS component preflight must run before opkg update"
pass "required KeeneticOS components are verified before opkg or router changes"

grep -q 'proxy_client_missing' "$ROOT/install.sh" || fail "installer must retain post-create Proxy capability safety net"
grep -q 'running-config after create' "$ROOT/install.sh" || fail "installer must read Proxy creation back"
grep -q 'Proxy0 appeared in running-config but the required project profile' "$ROOT/install.sh" || fail "installer must reject an incomplete Proxy0 profile"
grep -q 'Proxy${_n} appeared in running-config but the required project profile' "$ROOT/install.sh" || fail "installer must reject an incomplete ProxyN profile"
pass "Proxy creation has a full-profile read-back/fail-fast contract"

grep -q '^mixed-port: 7890$' "$ROOT/install.sh" || fail "bootstrap must expose mixed-port 7890"
grep -q 'Failed to write required Mihomo bootstrap config' "$ROOT/install.sh" || fail "clean install must fail if required bootstrap cannot be written"
grep -q 'config.yaml not found (required bootstrap missing)' "$ROOT/install.sh" || fail "self-check must fail when required bootstrap is absent"
pass "bootstrap is mandatory and exposes contract port 7890"

grep -q '^wait_for_mihomo_contract_port()' "$ROOT/install.sh" || fail "installer must have a bounded Mihomo contract-port startup wait"
grep -q '\[ "$_wp_try" -le 5 \]' "$ROOT/install.sh" || fail "contract-port startup wait must remain bounded to five seconds after the immediate check"
grep -q 'Port 7890 still not listening after 5s startup wait' "$ROOT/install.sh" || fail "installer must warn only after the bounded startup wait"
grep -q 'Port 7890 listening' "$ROOT/install.sh" || fail "installer must report listener success"
pass "Mihomo contract-port self-check tolerates bounded startup latency"

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
 "$ROOT/mihomo-doctor.sh" || fail "doctor delivery-path check must default to stable"
if grep -q 'raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/' "$ROOT/install.sh"; then
    fail "installer must not fetch project-managed runtime files from main"
fi
if grep -q 'raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/' "$ROOT/update-watchdog.sh"; then
    fail "watchdog updater must not fetch canonical watchdog from main"
fi
pass "production project delivery defaults to stable with explicit ref override"

grep -q 'LOW-RAM / BEST-EFFORT INSTALL' "$ROOT/install.sh" || fail "installer must warn clearly on low-RAM devices"
grep -q 'EXPERIMENTAL / NO STABILITY GUARANTEE' "$ROOT/install.sh" || fail "128 MB must stay explicitly experimental"
grep -q 'SWAP128_MIN_KB=393216' "$ROOT/install.sh" || fail "128 MB hard floor must remain 384 MB"
grep -q 'SWAP_MAX_KB=2097152' "$ROOT/install.sh" || fail "installer must cap external swap at 2 GiB"
grep -Fq "*'\\040(deleted)'*" "$ROOT/install.sh" || fail "installer must recognize kernel '(deleted)' swap sources"
grep -q "NOT counted toward verified external-SWAP capacity" "$ROOT/install.sh" || fail "installer must exclude deleted swap sources from capacity decisions"
grep -q '3x detected RAM, capped at 2048 MB' "$ROOT/install.sh" || fail "installer must expose the <=512 MB swap sizing target"
grep -q '256 MB-class device .*has neither active zRAM nor verified external storage-backed SWAP' "$ROOT/install.sh" || fail "256 MB missing backend must WARN"
grep -q '512 MB-class device .*has neither active zRAM nor verified external storage-backed SWAP' "$ROOT/install.sh" || fail "512 MB missing backend must WARN"
grep -q 'Stopping before package installation or project changes' "$ROOT/install.sh" || fail "oversized external swap must be an early installer error"
pass "installer enforces resource contract 20260921_2"

sh "$ROOT/tests/resource-scan-regression.sh" "$ROOT" ||
    fail "resource scanner must remain non-fatal for ordinary states under set -e"
pass "resource scanner does not abort install.sh before resource-profile policy handles the state"

sh "$ROOT/tests/resource-policy-regression.sh" "$ROOT" ||
    fail "resource policy fixtures must preserve hard gates and warning-only states"
pass "resource policy fixtures cover >2 GiB reject, 128 MB prerequisites, and zRAM+disk warning"

grep -q 'External storage-backed SWAP exceeds 2 GiB' "$ROOT/mihomo-doctor.sh" || fail "doctor must FAIL oversized external swap"
grep -q "swap source(s) are marked '(deleted)'" "$ROOT/mihomo-doctor.sh" || fail "doctor must surface stale/deleted swap sources"
grep -q '256 MB-class has neither active zRAM nor verified external storage-backed SWAP' "$ROOT/mihomo-doctor.sh" || fail "doctor must WARN 256 MB missing backend"
grep -q '512 MB-class has neither active zRAM nor verified external storage-backed SWAP' "$ROOT/mihomo-doctor.sh" || fail "doctor must WARN 512 MB missing backend"
grep -q 'External SWAP is below project sizing target' "$ROOT/mihomo-doctor.sh" || fail "doctor must explain project 3x sizing target"
pass "doctor mirrors resource contract 20260921_2"

grep -q 'UNSUPPORTED EXTERNAL SWAP SIZE: above 2 GiB' "$ROOT/update-mihomo.sh" || fail "updater must surface oversized external swap"
grep -q "UP_DELETED_COUNT" "$ROOT/update-mihomo.sh" || fail "updater must exclude deleted swap sources from capacity decisions"
grep -q 'MEMORY PROFILE WARNING: 256 MB-class without active zRAM or external swap' "$ROOT/update-mihomo.sh" || fail "updater must warn 256 MB missing backend"
grep -q 'MEMORY PROFILE WARNING: 512 MB-class without active zRAM or external swap' "$ROOT/update-mihomo.sh" || fail "updater must warn 512 MB missing backend"
grep -q 'The updater will continue only to service this existing installation' "$ROOT/update-mihomo.sh" || fail "profile warnings must not become updater hard gates"
pass "updater mirrors resource contract without blocking legacy service"

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
grep -q 'Enable one backend for the project profile: KeeneticOS zRAM OR external storage-backed SWAP' "$ROOT/mihomo-doctor.sh" || fail "doctor must explain the <=512 MB backend choice"
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

grep -q '^PROXY_COMPONENT_ID=proxy$' "$ROOT/install.sh" || fail "installer must use KeeneticOS component id proxy"
grep -q '^DNS_FILTER_COMPONENT_ID=dns-filter$' "$ROOT/install.sh" || fail "installer must use KeeneticOS component id dns-filter"
grep -q '^NETFILTER_COMPONENT_ID=opkg-kmod-netfilter$' "$ROOT/install.sh" || fail "installer must use KeeneticOS Netfilter component id"
grep -q 'Checking required KeeneticOS components' "$ROOT/install.sh" || fail "installer must run named-component preflight"
grep -q 'Missing required KeeneticOS component(s):' "$ROOT/install.sh" || fail "installer must label the missing-component list"
grep -Fq 'printf '\''%s\n'\'' "${_rc_missing_lines#?}" >&2' "$ROOT/install.sh" || fail "missing-component list must not start with a blank line"
grep -q 'Proxy client / Клиент прокси (${PROXY_COMPONENT_ID})' "$ROOT/install.sh" || fail "installer must name missing Proxy client clearly"
grep -q 'Cloud-based content filtering and ad blocking / Фильтрация контента и блокировка рекламы при помощи облачных сервисов (${DNS_FILTER_COMPONENT_ID})' "$ROOT/install.sh" || fail "installer must name missing dns-filter clearly"
grep -q 'Kernel modules for Netfilter / Модули ядра подсистемы Netfilter (${NETFILTER_COMPONENT_ID})' "$ROOT/install.sh" || fail "installer must name missing Netfilter clearly"
grep -q 'Full required component contract for the current default project profile' "$ROOT/install.sh" || fail "installer must distinguish missing list from full component contract"
grep -q 'No project components or router settings have been changed; stopping before installer-managed opkg update and project package installation' "$ROOT/install.sh" || fail "missing KeeneticOS prerequisites must stop before installer mutations"
_component_preflight_line=$(grep -n '^require_project_keeneticos_components$' "$ROOT/install.sh" | head -1 | cut -d: -f1)
_opkg_update_line=$(grep -n '^log "Updating opkg\.\.\."$' "$ROOT/install.sh" | head -1 | cut -d: -f1)
[ -n "$_component_preflight_line" ] && [ -n "$_opkg_update_line" ] && [ "$_component_preflight_line" -lt "$_opkg_update_line" ] ||
    fail "KeeneticOS component preflight must run before opkg update"
pass "required KeeneticOS components are verified before opkg or router changes"

grep -q 'proxy_client_missing' "$ROOT/install.sh" || fail "installer must retain post-create Proxy capability safety net"
grep -q 'running-config after create' "$ROOT/install.sh" || fail "installer must read Proxy creation back"
grep -q 'Proxy0 appeared in running-config but the required project profile' "$ROOT/install.sh" || fail "installer must reject an incomplete Proxy0 profile"
grep -q 'Proxy${_n} appeared in running-config but the required project profile' "$ROOT/install.sh" || fail "installer must reject an incomplete ProxyN profile"
pass "Proxy creation has a full-profile read-back/fail-fast contract"

grep -q '^mixed-port: 7890$' "$ROOT/install.sh" || fail "bootstrap must expose mixed-port 7890"
grep -q 'Failed to write required Mihomo bootstrap config' "$ROOT/install.sh" || fail "clean install must fail if required bootstrap cannot be written"
grep -q 'config.yaml not found (required bootstrap missing)' "$ROOT/install.sh" || fail "self-check must fail when required bootstrap is absent"
pass "bootstrap is mandatory and exposes contract port 7890"

grep -q '^wait_for_mihomo_contract_port()' "$ROOT/install.sh" || fail "installer must have a bounded Mihomo contract-port startup wait"
grep -q '\[ "$_wp_try" -le 5 \]' "$ROOT/install.sh" || fail "contract-port startup wait must remain bounded to five seconds after the immediate check"
grep -q 'Port 7890 still not listening after 5s startup wait' "$ROOT/install.sh" || fail "installer must warn only after the bounded startup wait"
grep -q 'Port 7890 listening' "$ROOT/install.sh" || fail "installer must report listener success"
pass "Mihomo contract-port self-check tolerates bounded startup latency"

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
