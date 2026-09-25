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

PROFILE_CONTRACT=20260921_3
for _f in install.sh mihomo-doctor.sh update-mihomo.sh; do
    grep -q "RESOURCE_PROFILE_CONTRACT_VERSION=$PROFILE_CONTRACT" "$ROOT/$_f" ||
        fail "$_f must carry resource-profile contract $PROFILE_CONTRACT"
done
pass "installer, doctor and updater pin the same resource-profile contract version"

grep -Fq 'PROJECT_REF="${KEENETIC_AUTO_SETUP_REF:-stable}"' "$ROOT/install.sh" || fail "installer production ref must default to stable"
grep -Fq 'PROJECT_REF="${KEENETIC_AUTO_SETUP_REF:-stable}"' "$ROOT/update-watchdog.sh" || fail "watchdog updater production ref must default to stable"
grep -Fq 'PROJECT_REF="${KEENETIC_AUTO_SETUP_REF:-stable}"' "$ROOT/mihomo-doctor.sh" || fail "doctor delivery-path check must default to stable"
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
grep -q 'project minimum floor: .*1x detected RAM' "$ROOT/install.sh" || fail "installer must WARN only below the 1x RAM swap floor"
grep -q 'below the preferred project sizing target but meets the minimum floor' "$ROOT/install.sh" || fail "installer must keep the 1x..3x swap range informational"
grep -q '3x RAM, capped at 2048 MB' "$ROOT/install.sh" || fail "installer must retain the preferred 3x RAM sizing target"
grep -q '256 MB-class device .*has neither active zRAM nor verified external storage-backed SWAP' "$ROOT/install.sh" || fail "256 MB missing backend must WARN"
grep -q '512 MB-class device .*has neither active zRAM nor verified external storage-backed SWAP' "$ROOT/install.sh" || fail "512 MB missing backend must WARN"
grep -q 'Stopping before package installation or project changes' "$ROOT/install.sh" || fail "oversized external swap must be an early installer error"
pass "installer enforces resource contract 20260921_3"

sh "$ROOT/tests/resource-scan-regression.sh" "$ROOT" ||
    fail "resource scanner must remain non-fatal for ordinary states under set -e"
pass "resource scanner does not abort install.sh before resource-profile policy handles the state"

sh "$ROOT/tests/resource-policy-regression.sh" "$ROOT" ||
    fail "resource policy fixtures must preserve hard gates and warning-only states"
pass "resource policy fixtures cover >2 GiB reject, 128 MB prerequisites, zRAM+disk warning, and 1x/3x swap severity"

grep -Fq -- '--allow-internal-disk' "$ROOT/install.sh" || fail "installer must expose the narrow internal-disk override"
grep -Fq 'Storage-mode mismatch: disk mode was selected while /opt is on internal Keenetic storage' "$ROOT/install.sh" || fail "installer must hard-stop accidental disk mode on internal /opt"
grep -Fq 'Storage-mode mismatch: ram mode was selected while /opt is on external persistent storage' "$ROOT/install.sh" || fail "installer must warn on external /opt + ram mode"
pass "installer storage-mode mismatch guardrail is explicit and narrowly overridable"

grep -q '^EXT_COMPONENT_ID=ext$' "$ROOT/install.sh" || fail "installer must use KeeneticOS component id ext for external storage"
grep -q '^EXT_UTILS_COMPONENT_ID=ext-utils$' "$ROOT/install.sh" || fail "installer must use KeeneticOS component id ext-utils for external storage"
grep -Fq "The project supports external Entware /opt only on EXT4" "$ROOT/install.sh" || fail "installer must hard-gate external Entware to EXT4"
grep -Fq 'Unsupported external /opt filesystem:' "$ROOT/mihomo-doctor.sh" || fail "Doctor must diagnose unsupported external /opt filesystems"
grep -Fq 'UNSUPPORTED EXTERNAL /opt FILESYSTEM:' "$ROOT/update-mihomo.sh" || fail "updater must warn on legacy non-EXT4 external /opt"
pass "external Entware storage contract is EXT4-only and mirrored by installer/Doctor/updater"

for _f in install.sh mihomo-doctor.sh update-mihomo.sh; do
    grep -q '^MIHOMO_STAGE_MARGIN_KB=4096$' "$ROOT/$_f" || fail "$_f must use the shared 4 MB Mihomo staging margin"
done
! grep -q '32768' "$ROOT/install.sh" || fail "installer must not use the old fixed 32 MB free-space threshold"
! grep -q '32768' "$ROOT/mihomo-doctor.sh" || fail "Doctor must not use the old fixed 32 MB free-space threshold"
grep -q 'Mihomo update staging headroom' "$ROOT/install.sh" || fail "installer must report staging-aware free-space headroom"
grep -q 'Mihomo update staging estimate' "$ROOT/mihomo-doctor.sh" || fail "Doctor must report its current-binary staging estimate"
grep -q 'authoritative free-space gate' "$ROOT/mihomo-doctor.sh" || fail "Doctor must defer the authoritative staging decision to update-mihomo.sh"
! grep -q 'warn "Mihomo update staging' "$ROOT/mihomo-doctor.sh" || fail "Doctor staging estimate must not be a WARN because candidate size is unknown"
pass "Mihomo free-space checks distinguish Doctor estimate from updater candidate gate"

grep -q 'External storage-backed SWAP exceeds 2 GiB' "$ROOT/mihomo-doctor.sh" || fail "doctor must FAIL oversized external swap"
grep -q "swap source(s) are marked '(deleted)'" "$ROOT/mihomo-doctor.sh" || fail "doctor must surface stale/deleted swap sources"
grep -q '256 MB-class has neither active zRAM nor verified external storage-backed SWAP' "$ROOT/mihomo-doctor.sh" || fail "doctor must WARN 256 MB missing backend"
grep -q '512 MB-class has neither active zRAM nor verified external storage-backed SWAP' "$ROOT/mihomo-doctor.sh" || fail "doctor must WARN 512 MB missing backend"
grep -q 'External SWAP is below project minimum floor' "$ROOT/mihomo-doctor.sh" || fail "doctor must WARN below the 1x RAM swap floor"
grep -q 'External SWAP is below preferred project sizing target but meets the minimum floor' "$ROOT/mihomo-doctor.sh" || fail "doctor must report the 1x..3x swap range as INFO"
pass "doctor mirrors resource contract 20260921_3"

grep -q 'UNSUPPORTED EXTERNAL SWAP SIZE: above 2 GiB' "$ROOT/update-mihomo.sh" || fail "updater must surface oversized external swap"
grep -q "UP_DELETED_COUNT" "$ROOT/update-mihomo.sh" || fail "updater must exclude deleted swap sources from capacity decisions"
grep -q 'MEMORY PROFILE WARNING: 256 MB-class without active zRAM or external swap' "$ROOT/update-mihomo.sh" || fail "updater must warn 256 MB missing backend"
grep -q 'MEMORY PROFILE WARNING: 512 MB-class without active zRAM or external swap' "$ROOT/update-mihomo.sh" || fail "updater must warn 512 MB missing backend"
grep -q 'External SWAP is below project minimum floor' "$ROOT/update-mihomo.sh" || fail "updater must WARN below the 1x RAM swap floor"
grep -q 'External SWAP is below preferred project sizing target but meets the minimum floor' "$ROOT/update-mihomo.sh" || fail "updater must keep the 1x..3x swap range informational"
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

grep -q '^WATCHDOG_RECENT_WARN_THRESHOLD=2$' "$ROOT/mihomo-doctor.sh" || fail "Doctor must keep one recovered watchdog intervention per 24h informational"
grep -Fq 'Watchdog interventions in the last 24h: 1 isolated restart, followed by a healthy check - informational only' "$ROOT/mihomo-doctor.sh" || fail "Doctor must explain a single recovered recent restart as INFO"
grep -Fq 'elif [ "$WD_RECENT" -ge "$WATCHDOG_RECENT_WARN_THRESHOLD" ]; then' "$ROOT/mihomo-doctor.sh" || fail "Doctor must warn only when the recent intervention count reaches the repeated-event threshold"
grep -Fq 'if [ "$WD_RECENT_RL" -gt 0 ]; then' "$ROOT/mihomo-doctor.sh" || fail "Doctor must keep recent rate-limited watchdog detections warning-level"
grep -Fq 'Historical stability: OK - one isolated watchdog restart in the last 24h was followed by a healthy check' "$ROOT/mihomo-doctor.sh" || fail "Doctor must keep recovered single-event history at OK"
pass "doctor treats one recovered watchdog restart per 24h as INFO while preserving repeated/rate-limited WARNs"

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
grep -Fq '*"DNS transit interception not found"*)' "$ROOT/mihomo-doctor.sh" || fail "doctor must keep a dedicated DNS-interception action"
_dns_action_line=$(grep -nF '*"DNS transit interception not found"*)' "$ROOT/mihomo-doctor.sh" | head -1 | cut -d: -f1)
_mt_action_line=$(grep -nF '*"MagiTrickle"*|*"magitrickled"*|*"Port 53 remap"*|*"Functional DNS query via "*)' "$ROOT/mihomo-doctor.sh" | head -1 | cut -d: -f1)
[ -n "$_dns_action_line" ] && [ -n "$_mt_action_line" ] && [ "$_dns_action_line" -lt "$_mt_action_line" ] || fail "DNS-interception finding must resolve before the generic MagiTrickle action"
grep -Fq '/proc/PID/exe' "$ROOT/mihomo-doctor.sh" || fail "doctor output must use markdown-safe /proc/PID/exe wording"
! grep -Fq '/proc/<pid>/exe' "$ROOT/mihomo-doctor.sh" || fail "doctor output/comments must avoid markdown-eaten <pid> placeholder"
grep -Fq 'FAIL findings (%d):' "$ROOT/mihomo-doctor.sh" || fail "doctor summary must not call every FAIL a current blocking outage"
grep -Fq 'Legacy-profile note: direct component FAILs are reserved for prerequisites whose current runtime capability is not separately proven by Doctor.' "$ROOT/mihomo-doctor.sh" || fail "doctor must explain capability-correlated legacy component semantics"
pass "doctor summarizes WARN/FAIL findings with precise legacy-safe next steps"




grep -q 'Provider-backed groups may expose the selected leaf only via' "$ROOT/mihomo-proxy-selection-watch.sh" || fail "proxy watcher must support provider-backed leaf names"
grep -q 'CHAIN="$CHAIN -> $_now"' "$ROOT/mihomo-proxy-selection-watch.sh" || fail "proxy watcher must report terminal now leaf"
pass "proxy watcher accepts a non-top-level selected leaf from group now"


grep -q 'Ensuring MagiTrickle package repository' "$ROOT/install.sh" || fail "installer must own the MagiTrickle repository/setup messaging"
grep -q 'sh >/dev/null' "$ROOT/install.sh" || fail "upstream MagiTrickle helper stdout must be suppressed"
grep -q 'MagiTrickle installed and started' "$ROOT/install.sh" || fail "installer must confirm the automated MagiTrickle outcome"
if grep -q 'pkg_ensure magitrickle || warn' "$ROOT/install.sh"; then
    fail "MagiTrickle install must not pretend pkg_ensure can fall through to warn"
fi
pass "MagiTrickle installation output is owned by install.sh"

grep -q '^PROXY_COMPONENT_ID=proxy$' "$ROOT/install.sh" || fail "installer must use KeeneticOS component id proxy"
grep -q '^DNS_FILTER_COMPONENT_ID=dns-filter$' "$ROOT/install.sh" || fail "installer must use KeeneticOS component id dns-filter"
grep -q '^NETFILTER_COMPONENT_ID=opkg-kmod-netfilter$' "$ROOT/install.sh" || fail "installer must use KeeneticOS Netfilter component id"
grep -q '^DNS_TLS_COMPONENT_ID=dns-tls$' "$ROOT/install.sh" || fail "installer must use KeeneticOS DNS-over-TLS component id"
grep -q '^DNS_HTTPS_COMPONENT_ID=dns-https$' "$ROOT/install.sh" || fail "installer must use KeeneticOS DNS-over-HTTPS component id"
grep -Fq '_rc_secure_dns_present="$DNS_TLS_COMPONENT_ID"' "$ROOT/install.sh" || fail "installer must detect dns-tls as satisfying the secure-DNS OR contract"
grep -Fq '_rc_secure_dns_present="$DNS_HTTPS_COMPONENT_ID"' "$ROOT/install.sh" || fail "installer must detect dns-https as satisfying the secure-DNS OR contract"
grep -Fq 'if [ -z "$_rc_secure_dns_present" ]; then' "$ROOT/install.sh" || fail "installer must fail only when neither secure-DNS component is present"
grep -Fq 'secure DNS: ${_rc_secure_dns_present}' "$ROOT/install.sh" || fail "installer success log must report the detected secure-DNS component(s)"
grep -q '^EXT_COMPONENT_ID=ext$' "$ROOT/install.sh" || fail "installer must use KeeneticOS Ext filesystem component id"
grep -q '^EXT_UTILS_COMPONENT_ID=ext-utils$' "$ROOT/install.sh" || fail "installer must use KeeneticOS EXT4 utilities component id"
grep -q 'Checking required KeeneticOS components' "$ROOT/install.sh" || fail "installer must run named-component preflight"
grep -q 'Missing required KeeneticOS component(s):' "$ROOT/install.sh" || fail "installer must label the missing-component list"
grep -Fq 'printf '\''%s\n'\'' "${_rc_missing_lines#?}" >&2' "$ROOT/install.sh" || fail "missing-component list must not start with a blank line"
grep -q 'Proxy client / Клиент прокси (${PROXY_COMPONENT_ID})' "$ROOT/install.sh" || fail "installer must name missing Proxy client clearly"
grep -q 'Cloud-based content filtering and ad blocking / Фильтрация контента и блокировка рекламы при помощи облачных сервисов (${DNS_FILTER_COMPONENT_ID})' "$ROOT/install.sh" || fail "installer must name missing dns-filter clearly"
grep -q 'Kernel modules for Netfilter / Модули ядра подсистемы Netfilter (${NETFILTER_COMPONENT_ID})' "$ROOT/install.sh" || fail "installer must name missing Netfilter clearly"
grep -q 'At least one secure DNS proxy component is required: DNS-over-TLS proxy (${DNS_TLS_COMPONENT_ID}) OR DNS-over-HTTPS proxy (${DNS_HTTPS_COMPONENT_ID})' "$ROOT/install.sh" || fail "installer must explain the secure-DNS OR requirement"
grep -q 'Required secure-DNS KeeneticOS component missing:' "$ROOT/mihomo-doctor.sh" || fail "doctor must mirror missing secure-DNS components as FAIL"
grep -q 'Secure-DNS KeeneticOS component prerequisite satisfied:' "$ROOT/mihomo-doctor.sh" || fail "doctor must report a satisfied secure-DNS OR contract"
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

grep -Fq 'iptables -t mangle -S _CUST_BYPASS_WA_' "$ROOT/mihomo-doctor.sh" || fail "Doctor must inspect the live bypass chain, not only policy/chain existence"
grep -Fq 'iptables -t mangle -S PREROUTING' "$ROOT/mihomo-doctor.sh" || fail "Doctor must verify the bypass PREROUTING attachment"
grep -Fq 'multiport-MARK' "$ROOT/mihomo-doctor.sh" || fail "Doctor must require the bypass multiport MARK rule"
grep -Fq 'multiport-CONNMARK' "$ROOT/mihomo-doctor.sh" || fail "Doctor must require the bypass multiport CONNMARK rule"
grep -Fq 'multiport-RETURN' "$ROOT/mihomo-doctor.sh" || fail "Doctor must require the bypass multiport RETURN rule"
grep -Fq 'bypass_wa Netfilter rules incomplete' "$ROOT/mihomo-doctor.sh" || fail "Doctor must FAIL an empty/incomplete bypass chain"
grep -Fq 'xt_multiport' "$ROOT/docs/COMPONENTS_RU.md" || fail "component docs must preserve the proven xt_multiport dependency"
grep -Fq 'НЕ ТРЕБУЕТСЯ текущему bypass' "$ROOT/docs/COMPONENTS_RU.md" || fail "component docs must preserve the proven Xtables-addons result"
pass "Doctor and docs preserve the KN-1010 bypass_wa runtime contract"

grep -Fq 'DOC_DNS_FILTER_COMPONENT=missing' "$ROOT/mihomo-doctor.sh" || fail "Doctor must track dns-filter component drift separately from runtime capability"
grep -Fq 'DNS_INTERCEPT_RUNTIME=ok' "$ROOT/mihomo-doctor.sh" || fail "Doctor must record live DNS interception capability"
grep -Fq 'Supported-profile component missing: dns-filter; runtime DNS interception is currently active on this legacy installation' "$ROOT/mihomo-doctor.sh" || fail "Doctor must WARN, not FAIL, when legacy dns-filter ID is absent but DNS interception is live"
grep -Fq 'Supported-profile component missing and runtime DNS interception is not active: dns-filter' "$ROOT/mihomo-doctor.sh" || fail "Doctor must FAIL when dns-filter profile evidence and runtime interception are both absent"
grep -Fq 'DOC_NETFILTER_COMPONENT=missing' "$ROOT/mihomo-doctor.sh" || fail "Doctor must track opkg-kmod-netfilter component drift separately from runtime capability"
grep -Fq 'BYPASS_NETFILTER_RUNTIME=ok' "$ROOT/mihomo-doctor.sh" || fail "Doctor must record live bypass Netfilter capability"
grep -Fq 'Supported-profile component missing: opkg-kmod-netfilter; runtime bypass_wa Netfilter capability is currently verified on this legacy installation' "$ROOT/mihomo-doctor.sh" || fail "Doctor must WARN, not FAIL, when legacy Netfilter component ID is absent but bypass rules are live"
! grep -Fq 'for _drc_id in proxy dns-filter opkg-kmod-netfilter' "$ROOT/mihomo-doctor.sh" || fail "Doctor must not collapse proxy/dns-filter/netfilter into one immediate component-ID severity loop"
grep -Fq 'DNS_FILTER_COMPONENT_ID=dns-filter' "$ROOT/install.sh" || fail "installer must keep dns-filter as a hard preflight component"
grep -Fq 'NETFILTER_COMPONENT_ID=opkg-kmod-netfilter' "$ROOT/install.sh" || fail "installer must keep opkg-kmod-netfilter as a hard preflight component"
pass "Doctor separates legacy profile drift from proven runtime capability without weakening installer gates"


# Keenetic/Netcraze ndmc may wrap component IDs inside a token at terminal width.
# NC-1812 / KeeneticOS 5.1.5 had already shown this formatting class with
# a non-required component (ike- + client). KN-3811 / 5.1.5 and 5.1.6 later
# reproduced dns- + filter and opkg-kmod- + netfilter with a real false-missing
# consequence under line-oriented parsing.
WRAPPED_COMPONENT_FIXTURE='          release: 5.01.C.6.0-1
           components: base,cloudcontrol,corewireless,dhcpd,dns-
                       filter,dns-https,dns-tls,ext,openvpn,opkg,opkg-kmod-
                       netfilter,opkg-kmod-netfilter-addons,opkg-kmod-tc,
                       proxy,ssh,wireguard
             ndw4:
              version: 5.1.C.6.0'

_install_component_parser=$(sed -n '/^component_list_from_show_version() {$/,/^}$/p' "$ROOT/install.sh")
_install_component_has=$(sed -n '/^component_list_has() {$/,/^}$/p' "$ROOT/install.sh")
[ -n "$_install_component_parser" ] && [ -n "$_install_component_has" ] ||
    fail "installer component parser functions must remain extractable for regression testing"
(
    eval "$_install_component_parser"
    eval "$_install_component_has"
    KEENETIC_VERSION_DUMP=$WRAPPED_COMPONENT_FIXTURE
    KEENETIC_COMPONENT_LIST=$(component_list_from_show_version)
    component_list_has dns-filter || exit 11
    component_list_has opkg-kmod-netfilter || exit 12
    component_list_has dns-tls || exit 13
    component_list_has proxy || exit 14
    if component_list_has definitely-not-installed; then
        exit 15
    fi
) || fail "installer must reconstruct wrapped show version component IDs before exact matching"

_doctor_component_parser=$(sed -n '/^    _doctor_component_list_from_show_version() {$/,/^    }$/p' "$ROOT/mihomo-doctor.sh" | sed 's/^    //')
_doctor_component_has=$(sed -n '/^        _doctor_component_has() {$/,/^        }$/p' "$ROOT/mihomo-doctor.sh" | sed 's/^        //')
[ -n "$_doctor_component_parser" ] && [ -n "$_doctor_component_has" ] ||
    fail "Doctor component parser functions must remain extractable for regression testing"
(
    eval "$_doctor_component_parser"
    eval "$_doctor_component_has"
    SV_OUT=$WRAPPED_COMPONENT_FIXTURE
    DOC_COMPONENT_LIST=$(_doctor_component_list_from_show_version)
    _doctor_component_has dns-filter || exit 21
    _doctor_component_has opkg-kmod-netfilter || exit 22
    _doctor_component_has dns-https || exit 23
    _doctor_component_has proxy || exit 24
    if _doctor_component_has definitely-not-installed; then
        exit 25
    fi
) || fail "Doctor must reconstruct wrapped show version component IDs before exact matching"

# The field failure was caused by formatting, not by those two specific IDs.
# Exercise every required KeeneticOS component plus the historical NC-1812
# non-required sentinel (ike-client) at every possible internal wrap position.
# This proves the parser is generic across the field grammar rather than being
# accidentally tailored only to today's prerequisite list or the two KN-3811
# split points we happened to observe.
_component_wrap_fixture() {
    _cwf_id="$1"
    _cwf_cut="$2"
    _cwf_left=$(printf '%s\n' "$_cwf_id" | awk -v n="$_cwf_cut" '{ print substr($0, 1, n) }')
    _cwf_right=$(printf '%s\n' "$_cwf_id" | awk -v n="$((_cwf_cut + 1))" '{ print substr($0, n) }')
    printf '%s\n' \
        '          release: 5.01.C.6.0-1' \
        "           components: base,$_cwf_left" \
        "                       $_cwf_right,tail-marker" \
        '             ndw4:' \
        '              version: 5.1.C.6.0'
}

for _component_id in proxy dns-filter opkg-kmod-netfilter dns-tls dns-https ext ext-utils ike-client; do
    _component_len=${#_component_id}
    _component_cut=1
    while [ "$_component_cut" -lt "$_component_len" ]; do
        _component_fixture=$(_component_wrap_fixture "$_component_id" "$_component_cut")

        (
            eval "$_install_component_parser"
            eval "$_install_component_has"
            KEENETIC_VERSION_DUMP=$_component_fixture
            KEENETIC_COMPONENT_LIST=$(component_list_from_show_version)
            component_list_has "$_component_id"
        ) || fail "installer component parser lost $_component_id when wrapped after character $_component_cut"

        (
            eval "$_doctor_component_parser"
            eval "$_doctor_component_has"
            SV_OUT=$_component_fixture
            DOC_COMPONENT_LIST=$(_doctor_component_list_from_show_version)
            _doctor_component_has "$_component_id"
        ) || fail "Doctor component parser lost $_component_id when wrapped after character $_component_cut"

        _component_cut=$((_component_cut + 1))
    done
done

ADDONS_ONLY_COMPONENT_FIXTURE='           components: base,dns-filter,dns-tls,opkg,opkg-kmod-
                       netfilter-addons,proxy
             ndw4:
              version: 5.1.C.6.0'
(
    eval "$_install_component_parser"
    eval "$_install_component_has"
    KEENETIC_VERSION_DUMP=$ADDONS_ONLY_COMPONENT_FIXTURE
    KEENETIC_COMPONENT_LIST=$(component_list_from_show_version)
    component_list_has opkg-kmod-netfilter && exit 31
    component_list_has opkg-kmod-netfilter-addons || exit 32
) || fail "installer component matching must stay exact: netfilter-addons must not satisfy opkg-kmod-netfilter"

(
    eval "$_doctor_component_parser"
    eval "$_doctor_component_has"
    SV_OUT=$ADDONS_ONLY_COMPONENT_FIXTURE
    DOC_COMPONENT_LIST=$(_doctor_component_list_from_show_version)
    _doctor_component_has opkg-kmod-netfilter && exit 33
    _doctor_component_has opkg-kmod-netfilter-addons || exit 34
) || fail "Doctor component matching must stay exact: netfilter-addons must not satisfy opkg-kmod-netfilter"

pass "Doctor and installer parse wrapped Keenetic show version component IDs exactly"

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


# Installer/update ownership and one-Mihomo safety.
grep -q '^resolve_installed_mihomo()' "$ROOT/install.sh" || fail "installer must resolve existing Mihomo before deciding to install"
grep -q 'Existing Mihomo binary found at .*package install/upgrade skipped' "$ROOT/install.sh" || fail "repeat install must leave an existing Mihomo binary untouched"
grep -q 'Use update-mihomo.sh to update an installed Mihomo transactionally' "$ROOT/install.sh" || fail "installer must direct existing-binary updates to update-mihomo.sh"
[ "$(grep -c '^mihomo_running()' "$ROOT/install.sh")" -eq 1 ] || fail "installer must have exactly one shared one-Mihomo daemon guard"
grep -q 'Mihomo version probe skipped - daemon is running (one-Mihomo invariant)' "$ROOT/install.sh" || fail "early installer version probe must obey one-Mihomo"
pass "repeat install does not replace live Mihomo and all installer probes share one-Mihomo guard"

grep -Fq 'MIHOMO_RESTART_NEEDED=0' "$ROOT/install.sh" || fail "installer must track whether Mihomo actually needs a reload"
grep -Fq 'MIHOMO_RESTART_NEEDED=1' "$ROOT/install.sh" || fail "installer must mark binary/config changes as restart-relevant"
grep -Fq 'if [ "$MIHOMO_RESTART_NEEDED" -eq 1 ]; then' "$ROOT/install.sh" || fail "Mihomo restart must be gated on actual installer changes"
grep -Fq 'Mihomo binary/config unchanged and daemon is running - restart skipped' "$ROOT/install.sh" || fail "repeat install must explicitly skip unnecessary Mihomo restart"
grep -Fq 'Mihomo binary/config unchanged but daemon is stopped - starting service' "$ROOT/install.sh" || fail "installer must still recover a stopped service"
grep -Fq 'if [ "$MIHOMO_SERVICE_ACTION" != "none" ]; then' "$ROOT/install.sh" || fail "installer must skip startup delay when no Mihomo service action occurred"
_restart_gate_line=$(grep -n 'if \[ "$MIHOMO_RESTART_NEEDED" -eq 1 \]; then' "$ROOT/install.sh" | head -1 | cut -d: -f1)
_restart_cmd_line=$(grep -n '^[[:space:]]*/opt/etc/init.d/S99mihomo restart' "$ROOT/install.sh" | head -1 | cut -d: -f1)
[ -n "$_restart_gate_line" ] && [ -n "$_restart_cmd_line" ] || fail "installer restart gate/command ordering could not be determined"
[ "$_restart_gate_line" -lt "$_restart_cmd_line" ] || fail "S99mihomo restart must remain behind the restart-needed gate"
pass "repeat install skips Mihomo restart when binary/config are unchanged"

grep -q '^opkg_repo_snapshot()' "$ROOT/install.sh" || fail "installer must snapshot opkg repository configuration around the MagiTrickle helper"
grep -Fq 'MAGITRICKLE_REPO_BEFORE=$(opkg_repo_snapshot)' "$ROOT/install.sh" || fail "installer must capture repository configuration before the MagiTrickle helper"
grep -Fq 'MAGITRICKLE_REPO_AFTER=$(opkg_repo_snapshot)' "$ROOT/install.sh" || fail "installer must capture repository configuration after the MagiTrickle helper"
grep -Fq 'if [ "$MAGITRICKLE_REPO_BEFORE" != "$MAGITRICKLE_REPO_AFTER" ]; then' "$ROOT/install.sh" || fail "second opkg update must be gated on an actual repository-config change"
grep -Fq 'initial opkg update already refreshed its metadata' "$ROOT/install.sh" || fail "unchanged MagiTrickle repo must skip the duplicate metadata refresh"
grep -Fq 'retry opkg update || err "opkg update after changing the MagiTrickle repository failed"' "$ROOT/install.sh" || fail "changed MagiTrickle repo must still refresh metadata reliably"
pass "MagiTrickle helper avoids duplicate opkg update when repository configuration is unchanged"

# Permanent contracts for the two previously fixed high-consequence updater bugs:
# stale/racy locking and non-atomic cross-filesystem replacement.
grep -Fq 'LOCK_DIR="/tmp/mihomo-update.lock.d"' "$ROOT/update-mihomo.sh" || fail "updater must use the atomic lock directory"
grep -Fq 'if mkdir "$LOCK_DIR" 2>/dev/null; then' "$ROOT/update-mihomo.sh" || fail "updater lock acquisition must remain mkdir-based"
grep -Fq 'MAINT_MARKER="/tmp/mihomo.maintenance"' "$ROOT/update-mihomo.sh" || fail "updater must coordinate planned downtime with watchdog"
grep -Fq 'STAGE_BIN="$MIHOMO_DIR/.mihomo.new.' "$ROOT/update-mihomo.sh" || fail "updater candidate must stage on the destination filesystem"
grep -Fq 'TMP_BACKUP="$TMP_DIR/mihomo.backup.' "$ROOT/update-mihomo.sh" || fail "updater must create a bounded rollback backup"
grep -Fq 'cp -f "$MIHOMO_PATH" "$TMP_BACKUP"' "$ROOT/update-mihomo.sh" || fail "updater must copy the current binary to rollback backup before commit"
grep -Fq 'mv -f "$STAGE_BIN" "$MIHOMO_PATH"' "$ROOT/update-mihomo.sh" || fail "updater commit must remain a same-filesystem atomic rename"
grep -Fq 'cp -f "$TMP_BACKUP" "$MIHOMO_PATH"' "$ROOT/update-mihomo.sh" || fail "updater must retain rollback restoration"
! grep -Fq 'rm -f "$MIHOMO_PATH"' "$ROOT/update-mihomo.sh" || fail "updater must never delete the canonical binary before atomic commit"
_stage_line=$(grep -n 'STAGE_BIN="$MIHOMO_DIR/.mihomo.new.' "$ROOT/update-mihomo.sh" | head -1 | cut -d: -f1)
_backup_line=$(grep -n 'TMP_BACKUP="$TMP_DIR/mihomo.backup.' "$ROOT/update-mihomo.sh" | head -1 | cut -d: -f1)
_commit_line=$(grep -n 'mv -f "$STAGE_BIN" "$MIHOMO_PATH"' "$ROOT/update-mihomo.sh" | head -1 | cut -d: -f1)
[ -n "$_stage_line" ] && [ -n "$_backup_line" ] && [ -n "$_commit_line" ] || fail "updater transaction line ordering could not be determined"
[ "$_stage_line" -lt "$_backup_line" ] && [ "$_backup_line" -lt "$_commit_line" ] || fail "updater must stage, then back up, then atomically commit"
pass "updater lock/stage/backup/atomic-commit/rollback invariants remain pinned"

# Binary-only Mihomo updates intentionally do not synchronize the Entware opkg
# database. Runtime version is the truth; stale package metadata is expected
# after update-mihomo.sh and after Mihomo/MetaCubeXD self-upgrade.
! grep -Eq 'opkg[[:space:]]+install[[:space:]].*mihomo' "$ROOT/update-mihomo.sh" || fail "binary updater must not install Mihomo through opkg"
grep -Fq 'Already up to date ($CURRENT_VER). Use --force to replace anyway.' "$ROOT/update-mihomo.sh" || fail "same-version update must skip replacement unless --force is requested"
grep -Fq 'Same version ($CURRENT_VER) and --force given: replacing the binary anyway.' "$ROOT/update-mihomo.sh" || fail "--force must retain same-version binary replacement semantics"
grep -Fq 'stale metadata - expected after binary-only updates' "$ROOT/mihomo-doctor.sh" || fail "Doctor must explain stale opkg metadata as expected binary-only update state"
pass "binary-only Mihomo update and stale-opkg semantics remain pinned"

# User-facing HOWTOs must mirror the storage-mode guard and current ProxyN behavior.
for _f in docs/HOWTO_RU.md docs/HOWTO.md; do
    grep -Fq -- '--allow-internal-disk' "$ROOT/$_f" || fail "$_f must document the narrow internal-disk override"
done
grep -Fq 'первый свободный `ProxyN`' "$ROOT/docs/HOWTO_RU.md" || fail "Russian HOWTO must describe foreign Proxy0 -> first free ProxyN"
grep -Fq 'first free `ProxyN`' "$ROOT/docs/HOWTO.md" || fail "English HOWTO must describe foreign Proxy0 -> first free ProxyN"
for _f in docs/HOWTO_RU.md docs/HOWTO.md; do
    grep -Fqi 'EXT4' "$ROOT/$_f" || fail "$_f must document the external EXT4 storage contract"
    grep -Fq 'ext-utils' "$ROOT/$_f" || fail "$_f must document the external ext-utils prerequisite"
done
pass "RU/EN HOWTOs mirror storage-mode, external EXT4 and ProxyN contracts"
# Simple front-end must remain a thin selector/delegator, not a second installer.
grep -Fq 'PROJECT_REF="${KEENETIC_AUTO_SETUP_REF:-stable}"' "$ROOT/setup.sh" || fail "simple setup wrapper must default to stable"
grep -Fq 'INSTALL_STAGE="/tmp/keenetic-auto-setup-install.$$"' "$ROOT/setup.sh" || fail "simple setup installer staging path must use the shell PID ($$) and remain process-unique"
grep -Fq 'CONFIG_IMPORT_STAGE="/tmp/keenetic-auto-setup-config-import.$$"' "$ROOT/setup.sh" || fail "simple setup importer staging path must use the shell PID ($$) and remain process-unique"
grep -Fq 'PROC_MOUNTS="${SETUP_MOUNTS:-/proc/mounts}"' "$ROOT/setup.sh" || fail "simple setup wrapper must keep injectable mount detection for focused tests"
grep -q 'MODE=ram' "$ROOT/setup.sh" || fail "simple setup wrapper must select ram for internal /opt"
grep -q 'MODE=disk' "$ROOT/setup.sh" || fail "simple setup wrapper must select disk for external /opt"
grep -q 'KEENETIC_AUTO_SETUP_REF="$PROJECT_REF" sh "$INSTALL_STAGE" "$MODE"' "$ROOT/setup.sh" || fail "simple setup wrapper must delegate to canonical install.sh"
grep -Fq 'retry_download "$PROJECT_RAW_BASE/config-import.sh" "$CONFIG_IMPORT_STAGE"' "$ROOT/setup.sh" || fail "simple setup must fetch the safe config importer after installation"
grep -Fq 'sh "$CONFIG_IMPORT_STAGE"' "$ROOT/setup.sh" || fail "simple setup must continue directly into the safe importer"
! grep -Fq '_setup_import_answer' "$ROOT/setup.sh" || fail "simple setup must not consume the first YAML line in a separate confirmation prompt"
! grep -q 'dns-proxy intercept enable' "$ROOT/setup.sh" || fail "simple setup wrapper must not duplicate persistent router configuration"
! grep -q 'ip policy bypass_wa' "$ROOT/setup.sh" || fail "simple setup wrapper must not duplicate policy mutations"
grep -q 'stable/setup.sh | sh' "$ROOT/README.md" || fail "README must expose the simple setup wrapper as the happy path"
grep -Fq 'nano /opt/etc/mihomo/config.yaml' "$ROOT/README.md" || fail "README must keep the quick manual config edit command visible"
! grep -Fq 'stable/install.sh | sh -s -- disk' "$ROOT/README.md" || fail "README must keep advanced manual install commands in detailed documentation"
! grep -Fq 'INSTALL_STAGE="/tmp/keenetic-auto-setup-install.$"' "$ROOT/setup.sh" || fail "simple setup staging path must not regress to a literal single-dollar suffix"
! grep -Fq 'CONFIG_IMPORT_STAGE="/tmp/keenetic-auto-setup-config-import.$"' "$ROOT/setup.sh" || fail "simple setup importer path must not regress to a literal single-dollar suffix"
pass "simple setup wrapper auto-selects storage profile, uses PID-unique staging and delegates all mutations"

# Config import is a transactional config replacement, not a direct overwrite.
grep -Fq 'MAINT_MARKER="/tmp/mihomo.maintenance"' "$ROOT/config-import.sh" || fail "config importer must coordinate planned downtime with watchdog"
grep -Fq 'BACKUP_PATH="$CONFIG_DIR/config.yaml.bak"' "$ROOT/config-import.sh" || fail "config importer must retain the previous config backup"
grep -Fq 'read -r _ci_first_line < /dev/tty' "$ROOT/config-import.sh" || fail "interactive importer must capture the first pasted YAML line itself"
grep -Fq "printf '%s\\n' \"\$_ci_first_line\" > \"\$STAGE_CONFIG\"" "$ROOT/config-import.sh" || fail "interactive importer must preserve the first pasted YAML line"
grep -Fq 'cat < /dev/tty >> "$STAGE_CONFIG"' "$ROOT/config-import.sh" || fail "interactive importer must append the remaining YAML from /dev/tty"
grep -Fq 's|S|skip|SKIP)' "$ROOT/config-import.sh" || fail "interactive importer must offer an explicit skip path"
grep -Fq "mixed-port:[[:space:]]*7890" "$ROOT/config-import.sh" || fail "config importer must enforce project port 7890 before downtime"
grep -Fq '"$MIHOMO_BIN" -d "$CONFIG_DIR" -f "$STAGE_CONFIG" -t' "$ROOT/config-import.sh" || fail "candidate config must be tested before commit"
grep -Fq 'mv -f "$STAGE_CONFIG" "$CONFIG_PATH"' "$ROOT/config-import.sh" || fail "config commit must be a same-filesystem atomic rename"
grep -q '^rollback_config()' "$ROOT/config-import.sh" || fail "config importer must retain rollback logic"
grep -Fq 'rollback_config "Mihomo did not start with the new config"' "$ROOT/config-import.sh" || fail "failed runtime start must roll back config"
grep -Fq 'rollback_config "Mihomo started but project port 7890 did not become ready"' "$ROOT/config-import.sh" || fail "missing contract port after start must roll back config"
grep -Fq 'Previous Mihomo service restored; port 7890 is listening.' "$ROOT/config-import.sh" || fail "pre-commit failure recovery must wait for old service port 7890 readiness"
grep -Fq 'start_mihomo_confirmed || return 1' "$ROOT/config-import.sh" || fail "old service restoration must fail if the process cannot be restarted"
grep -Fq 'UPDATER_LOCK_DIR="/tmp/mihomo-update.lock.d"' "$ROOT/config-import.sh" || fail "config importer must refuse known updater transactions"
grep -Fq 'CONFIG_COMMIT_STARTED=1' "$ROOT/config-import.sh" || fail "config importer must mark the commit phase before atomic replacement"
grep -Fq 'if [ "$CONFIG_COMMIT_STARTED" -eq 1 ] || [ "$CONFIG_REPLACED" -eq 1 ]; then' "$ROOT/config-import.sh" || fail "signals during the commit window must roll back"
grep -Fq 'CONFIG_IMPORT_LOCK="/tmp/mihomo-config-import.lock.d"' "$ROOT/update-mihomo.sh" || fail "updater must coordinate with active config import"
grep -Fq 'if config_import_active; then' "$ROOT/update-mihomo.sh" || fail "updater must refuse active config import before acquiring update lock"
! grep -Fq 'cat > "$CONFIG_PATH"' "$ROOT/config-import.sh" || fail "config importer must never stream input directly into canonical config"
pass "config importer validates, atomically commits and rolls back under one-Mihomo safety"

echo "[OK] Contract smoke tests passed"
