#!/bin/sh

# =========================================================
# mihomo-doctor.sh v1.2.6 - READ-ONLY diagnostic for the
# keenetic-auto-setup stack (Mihomo + watchdog + Keenetic
# proxy bridge) on Keenetic + Entware.
#
# The doctor collects facts and prints a report. It NEVER:
#   installs, updates or removes anything; never touches
#   config.yaml or Keenetic configuration; never creates
#   Proxy interfaces; never starts/stops/restarts Mihomo;
#   never runs install.sh / update-mihomo.sh, and never
#   modifies anything via opkg (read-only opkg queries only).
#   THE ONE-MIHOMO INVARIANT IS UNIVERSAL: while a Mihomo daemon
#   is running, the doctor never executes a second Mihomo binary
#   (no `-v`, no `-t` - a second execution is the established
#   SIGSEGV pattern on constrained hardware); the runtime version
#   then comes from the read-only Controller API (GET /version
#   only). Executable probes run only when no daemon was observed.
# It is safe to run at any time and safe to paste the whole
# output into a support chat: no config contents, secrets,
# subscription URLs or proxy credentials are printed.
#
# Statuses: [OK] / [WARN] / [FAIL] / [INFO]
# Exit codes: 0 = no FAIL, no WARN; 1 = WARN but no FAIL;
#             2 = at least one FAIL.
#
# Test hooks (do not set in normal use): DOCTOR_OPT_ROOT
# redirects the /opt prefix and DOCTOR_MEMINFO the meminfo
# source, so the doctor can be exercised on a non-Entware
# host. Unset they behave exactly like /opt and /proc/meminfo.
# =========================================================

OPT_ROOT="${DOCTOR_OPT_ROOT:-/opt}"
MEMINFO="${DOCTOR_MEMINFO:-/proc/meminfo}"

MIHOMO_PATH="$OPT_ROOT/bin/mihomo"
CONFIG_DIR="$OPT_ROOT/etc/mihomo"
CONFIG="$CONFIG_DIR/config.yaml"
INIT_EXPECTED="$OPT_ROOT/etc/init.d/S99mihomo"
WATCHDOG_BIN="$OPT_ROOT/bin/mihomo_watchdog.sh"
WATCHDOG_CRON="$OPT_ROOT/etc/cron.5mins/mihomo_watchdog"
WATCHDOG_LEGACY_BAK_OLD="$OPT_ROOT/etc/cron.5mins/mihomo_watchdog.legacy.bak"
WATCHDOG_LOG="$OPT_ROOT/var/log/mihomo_watchdog.log"
CRONTAB_FILE="$OPT_ROOT/etc/crontab"

# MagiTrickle (optional component) - ground truth from the
# magitrickle 0.8.2 Entware package (entware build paths)
MT_BIN="$OPT_ROOT/bin/magitrickled"
MT_CFG="$OPT_ROOT/var/lib/magitrickle/config.yaml"
MT_INIT="$OPT_ROOT/etc/init.d/S99magitrickle"
MT_PIDFILE="$OPT_ROOT/var/run/magitrickle.pid"

ENTWARE_REPO="saymer-alt/entware-go"
PROJECT_REF="${KEENETIC_AUTO_SETUP_REF:-stable}"
PROJECT_RAW_BASE="https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/${PROJECT_REF}"
CONTRACT_PORT=7890          # watchdog PROXY + project ProxyN upstream
MAX_PROXY_PROBE=32          # same protective scan cap as install.sh
# Same updater staging safety margin as install.sh/update-mihomo.sh.
MIHOMO_STAGE_MARGIN_KB=4096
# A single recovered watchdog intervention in 24h is informational noise, not
# evidence of instability. Two or more recent interventions are WARN; any
# recent rate-limited event remains WARN because it means another problem was
# detected while restart cooldown was active.
WATCHDOG_RECENT_WARN_THRESHOLD=2

N_OK=0; N_WARN=0; N_FAIL=0; N_INFO=0
WARN_MESSAGES=""
FAIL_MESSAGES=""

append_finding() {
    _af_kind=$1
    _af_msg=$2
    case "$_af_kind" in
        WARN)
            if [ -n "$WARN_MESSAGES" ]; then
                WARN_MESSAGES="$WARN_MESSAGES
$_af_msg"
            else
                WARN_MESSAGES=$_af_msg
            fi
            ;;
        FAIL)
            if [ -n "$FAIL_MESSAGES" ]; then
                FAIL_MESSAGES="$FAIL_MESSAGES
$_af_msg"
            else
                FAIL_MESSAGES=$_af_msg
            fi
            ;;
    esac
}

ok()   { printf '[OK]   %s\n' "$1"; N_OK=$((N_OK+1)); }
warn() { printf '[WARN] %s\n' "$1"; N_WARN=$((N_WARN+1)); append_finding WARN "$1"; }
fail() { printf '[FAIL] %s\n' "$1"; N_FAIL=$((N_FAIL+1)); append_finding FAIL "$1"; }
info() { printf '[INFO] %s\n' "$1"; N_INFO=$((N_INFO+1)); }
hdr()  { printf '\n===== %s =====\n\n' "$1"; }

finding_action() {
    _fa_msg=$1
    case "$_fa_msg" in
        *"swap source(s) are marked '(deleted)'"*)
            printf '%s' "Reboot or remove the stale swap state so /proc/swaps contains only current backends, then run Doctor again."
            ;;
        *"External storage-backed SWAP exceeds 2 GiB"*)
            printf '%s' "Reduce the external SWAP partition/file to 2048 MB or less, then run Doctor again."
            ;;
        *"External SWAP is below project minimum floor"*)
            printf '%s' "If using disk SWAP as the chosen backend, increase it to at least about 1x detected RAM. The preferred project target remains 3x RAM, capped at 2048 MB; these are project thresholds, not vendor minimums."
            ;;
        *"zRAM and external storage-backed swap are active together"*)
            printf '%s' "Keep one swap backend: if using disk/file swap, disable zRAM per vendor guidance; otherwise remove/disable the disk swap and keep zRAM."
            ;;
        *"256 MB-class"*zRAM*|*"256 MB-class"*swap*|*"256 MB-class"*backend*|*"512 MB-class"*zRAM*|*"512 MB-class"*swap*|*"512 MB-class"*backend*)
            printf '%s' "Enable one backend for the project profile: KeeneticOS zRAM OR external storage-backed SWAP. When disk/file SWAP is used, disable zRAM; then run Doctor again."
            ;;
        *"Low-RAM prerequisite NOT met"*"/opt"*|*"128 MB-class"*"/opt"*)
            printf '%s' "Move Entware /opt to external persistent storage; 128 MB-class devices also require at least 384 MB external storage-backed active swap (project-specific experimental floor)."
            ;;
        *"Low-RAM prerequisite NOT met"*swap*|*"128 MB-class"*swap*)
            printf '%s' "Provide at least 384 MB active swap on external storage (project-specific experimental floor), then run Doctor again."
            ;;
        *"Unsupported external /opt filesystem:"*)
            printf '%s' "Migrate/reformat the external Entware storage to EXT4, verify that Keenetic mounts it and Entware starts from it, then run Doctor again. This project never formats or converts storage."
            ;;
        *"Supported-profile component missing: dns-filter; runtime DNS interception is currently active"*)
            printf '%s' "No immediate runtime repair is required: DNS interception is live. This legacy installation does not match the supported component profile; install dns-filter before reprovisioning or rebuilding the component set, then re-check."
            ;;
        *"Supported-profile component missing: opkg-kmod-netfilter; runtime bypass_wa Netfilter capability is currently verified"*)
            printf '%s' "No immediate runtime repair is required: the bypass rules are live. This legacy installation does not match the supported component profile; install opkg-kmod-netfilter before reprovisioning or rebuilding the component set, then re-check."
            ;;
        *"Supported-profile component missing and runtime DNS interception is not active: dns-filter"*)
            printf '%s' "Install dns-filter, enable dns-proxy intercept, and run Doctor again; both supported-profile evidence and the required runtime DNS-interception capability are absent."
            ;;
        *"Supported-profile component missing:"*"unverified"*)
            printf '%s' "The component profile is incomplete and Doctor could not prove the corresponding runtime capability. Restore the named component or re-run when the runtime state can be validated."
            ;;
        *"Required secure-DNS KeeneticOS component missing:"*)
            printf '%s' "Install at least one KeeneticOS secure-DNS component: DNS-over-TLS proxy (dns-tls) or DNS-over-HTTPS proxy (dns-https), then run Doctor again. Keenetic recommends DoT/DoH for reliable Internet access through Proxy Client."
            ;;
        *"Required KeeneticOS component missing:"*)
            printf '%s' "Install the reported KeeneticOS component in General system settings -> KeeneticOS update and components, then run Doctor again."
            ;;
        *"Required external-storage KeeneticOS component missing:"*)
            printf '%s' "Install the reported KeeneticOS component in General system settings -> KeeneticOS update and components. External /opt requires both ext and ext-utils; ext-utils provides the supported filesystem check/repair tooling."
            ;;
        *"Very low available memory"*)
            printf '%s' "Reduce memory pressure and verify an appropriate swap/zRAM fallback before heavy install/update operations."
            ;;
        *"Mihomo update staging headroom is insufficient on "*)
            printf '%s' "Free space on the reported /opt filesystem before updating Mihomo. Doctor uses the current binary size plus the same 4 MB staging margin as update-mihomo.sh; the updater re-checks the actual candidate before modifying anything."
            ;;
        *"Entware root "*|*"opkg not found"*)
            printf '%s' "Install or repair Entware first, then run Doctor again."
            ;;
        *"Neither curl nor wget available"*|*"No curl/wget"*)
            printf '%s' "Install curl or wget in Entware; project downloads and update checks need one of them."
            ;;
        *"Mihomo binary not found"*)
            printf '%s' "Restore/install the project Mihomo binary with install.sh after preserving your user config."
            ;;
        *"Mihomo binary exists but is not executable"*)
            printf '%s' "Restore executable permission on the reported Mihomo binary (chmod +x), then re-run Doctor."
            ;;
        *"Mihomo binary"*cannot*execute*|*"Mihomo binary"*SIGSEGV*|*"Mihomo binary"*Segmentation*|*"Mihomo binary"*killed*|*"Mihomo binary exits with an error"*)
            printf '%s' "Do not keep retrying the binary blindly; inspect the reported architecture/runtime state and repair or reinstall Mihomo before normal use."
            ;;
        *"config.yaml not found"*)
            printf '%s' "Restore your Mihomo config or run install.sh for a fresh project bootstrap."
            ;;
        *"config.yaml is not readable"*)
            printf '%s' "Fix permissions/ownership so the Mihomo service can read config.yaml, then run Doctor again."
            ;;
        *"Contract port "*"not among the configured ports"*|*"contract port "*"NOT listening"*|*"configured port "*"not listening"*|*"No port defined in config"*)
            printf '%s' "Check Mihomo inbound configuration and keep the project contract port 7890 reachable by ProxyN/watchdog."
            ;;
        *"Config test FAILED"*)
            printf '%s' "Fix or regenerate config.yaml for this Mihomo version before restarting normal traffic."
            ;;
        *"Multiple mihomo processes"*)
            printf '%s' "Stop stale duplicate Mihomo processes; the project invariant is exactly one running Mihomo."
            ;;
        *"Mihomo init script"*|*"Mihomo is running"*"no init script"*|*"Mihomo is not running and no init script exists"*)
            printf '%s' "Repair the project service installation/init script so Mihomo has one managed boot path."
            ;;
        *"Mihomo service is stopped"*)
            printf '%s' "If this was intentional, no action is needed; otherwise start/repair the Mihomo service and re-check."
            ;;
        *"DNS transit interception not found"*)
            printf '%s' "Enable Keenetic DNS transit interception (dns-proxy intercept enable); install.sh configures it."
            ;;
        *"MagiTrickle"*|*"magitrickled"*|*"Port 53 remap"*|*"Functional DNS query via "*)
            printf '%s' "If MagiTrickle is intended on this router, repair/restart its package/service or DNS remap and run Doctor again."
            ;;
        *"No Proxy interfaces found at all"*)
            printf '%s' "Install/enable the KeeneticOS Proxy client component and run install.sh to create the project ProxyN bridge."
            ;;
        *"Cannot read/validate running-config"*)
            printf '%s' "Retry when Keenetic ndmc is responsive; Doctor deliberately makes no proxy-state assumption while running-config is unreadable."
            ;;
        *"bypass_wa hook missing"*|*"bypass_wa hook is not executable"*)
            printf '%s' "Restore the project 020-bypass_wa.sh hook with install.sh, then rebuild firewall or reboot and run Doctor again."
            ;;
        *"bypass_wa Netfilter verification unavailable"*|*"bypass_wa Netfilter chain missing"*|*"bypass_wa Netfilter rules incomplete"*)
            printf '%s' "Ensure KeeneticOS opkg-kmod-netfilter is installed, then rebuild firewall or reboot. Doctor expects PREROUTING -> _CUST_BYPASS_WA_ plus UDP multiport MARK/CONNMARK/RETURN rules."
            ;;
        *"bypass_wa policy exists but has no interface permit"*)
            printf '%s' "Add the intended interface permit to bypass_wa if failover is used; otherwise the policy has no exit route."
            ;;
        *"bypass_wa policy not found"*)
            printf '%s' "Run install.sh or create the intended bypass_wa failover policy if this project routing path is required."
            ;;
        *"Executable legacy watchdog backup remains inside cron.5mins"*|*"Legacy watchdog layout"*|*"Canonical watchdog present but the cron wrapper is missing"*|*"Watchdog not scheduled"*|*"Watchdog not installed"*|*"Unknown file at "*"cron.5mins"*)
            printf '%s' "Run update-watchdog.sh, then run Doctor again."
            ;;
        *"Canonical watchdog present but not executable"*)
            printf '%s' "Repair the watchdog installation with update-watchdog.sh."
            ;;
        *"Watchdog log not found"*|*"Watchdog log exists but is not readable"*|*"Watchdog log is empty"*|*"Log last updated "*)
            printf '%s' "Verify cron/watchdog scheduling and wait for a normal 5-minute check cycle, then run Doctor again."
            ;;
        *"Restart outcome failures"*|*"No healthy check recorded after the last problem event"*|*"No '[OK] All good' entry found"*|*"Repeated failures"*|*"Watchdog interventions in the last 24h"*|*"Historical stability: WARN"*)
            printf '%s' "Review new watchdog events after the latest fixes; if fresh failures continue, inspect WAN/proxy availability and Mihomo runtime separately."
            ;;
        *"DNS resolution FAILED"*)
            printf '%s' "Fix router/WAN DNS resolution before relying on project downloads or remote proxy health."
            ;;
        *"GitHub"*unreachable*|*"raw.githubusercontent.com unreachable"*)
            printf '%s' "Restore network access to GitHub/raw.githubusercontent.com; running Mihomo may keep working, but installs/updates cannot fetch files."
            ;;
        *"GitHub API rate-limited"*)
            printf '%s' "No router repair is needed; retry the availability check later."
            ;;
        *"No mihomo package for suffix "*)
            printf '%s' "Do not force an update from the GitHub package path; wait for/build the matching entware-go package or use the documented feed fallback."
            ;;
        *"Proxy selection sanity:"*)
            printf '%s' "Check the configured Mihomo Controller/secret and current proxy group selection; the Doctor only performs read-only GET /proxies."
            ;;
        *)
            printf '%s' "Review the matching diagnostic section above; Doctor made no changes to the router."
            ;;
    esac
}

print_finding_group() {
    _pfg_kind=$1
    _pfg_data=$2
    [ -n "$_pfg_data" ] || return 0
    printf '%s\n' "$_pfg_data" | while IFS= read -r _pfg_msg; do
        [ -n "$_pfg_msg" ] || continue
        printf '[%s] %s\n' "$_pfg_kind" "$_pfg_msg"
        printf '       Next: %s\n' "$(finding_action "$_pfg_msg")"
    done
}

print_human_result() {
    echo
    echo "=== What needs attention ==="
    if [ "$N_FAIL" -eq 0 ] && [ "$N_WARN" -eq 0 ]; then
        echo "[OK] No FAIL/WARN findings. No action is required by the current Doctor checks."
        return 0
    fi

    if [ "$N_FAIL" -gt 0 ]; then
        printf '\nFAIL findings (%d):\n' "$N_FAIL"
        print_finding_group FAIL "$FAIL_MESSAGES"
        case "$FAIL_MESSAGES" in
            *"Required KeeneticOS component missing:"*|*"Required secure-DNS KeeneticOS component missing:"*|*"Required external-storage KeeneticOS component missing:"*)
                info "Legacy-profile note: direct component FAILs are reserved for prerequisites whose current runtime capability is not separately proven by Doctor. dns-filter/opkg-kmod-netfilter are capability-correlated later in the report."
                ;;
        esac
    fi
    if [ "$N_WARN" -gt 0 ]; then
        printf '\nWarnings (%d):\n' "$N_WARN"
        print_finding_group WARN "$WARN_MESSAGES"
    fi

    echo
    if [ "$N_FAIL" -gt 0 ]; then
        printf 'Result: %d FAIL finding(s) and %d warning(s) need attention.\n' "$N_FAIL" "$N_WARN"
    else
        printf 'Result: no FAIL findings; %d warning(s) should be reviewed.\n' "$N_WARN"
    fi
}

is_num() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    return 0
}

first_line() {
    printf '%s\n' "$1" | head -n 1
}

# fetch_url URL -> globals FETCH_OUT (body) and FETCH_RC.
# curl preferred, wget fallback; nothing is written to disk.
fetch_url() {
    if command -v curl >/dev/null 2>&1; then
        FETCH_OUT=$(curl -fsSL --connect-timeout 5 --max-time 15 "$1" 2>/dev/null)
        FETCH_RC=$?
    elif command -v wget >/dev/null 2>&1; then
        FETCH_OUT=$(wget -qO- -T 15 "$1" 2>/dev/null)
        FETCH_RC=$?
    else
        FETCH_OUT=""; FETCH_RC=127
    fi
}

# run_with_timeout SECS CMD... -> globals RUN_OUT / RUN_RC.
# Uses the timeout applet when present, otherwise runs directly.
run_with_timeout() {
    _to="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        RUN_OUT=$(timeout "$_to" "$@" 2>&1)
    else
        RUN_OUT=$( "$@" 2>&1 )
    fi
    RUN_RC=$?
}

# port_listening N -> PL_RC: 0 listening, 1 not listening,
# 2 cannot determine. netstat -> ss -> /proc/net/tcp(6) hex
# compare (no strtonum: the decimal port is converted to hex).
port_listening() {
    _pl="$1"
    if command -v netstat >/dev/null 2>&1; then
        if netstat -tln 2>/dev/null | awk '{print $4}' | grep -q ":$_pl\$"; then
            PL_RC=0; else PL_RC=1; fi
    elif command -v ss >/dev/null 2>&1; then
        if ss -tln 2>/dev/null | awk '{print $4}' | grep -q ":$_pl\$"; then
            PL_RC=0; else PL_RC=1; fi
    elif [ -r /proc/net/tcp ] || [ -r /proc/net/tcp6 ]; then
        _hx=$(printf '%04X' "$_pl")
        PL_RC=1
        for _f in /proc/net/tcp /proc/net/tcp6; do
            [ -r "$_f" ] || continue
            if awk -v h="$_hx" 'NR>1 {n=split($2,a,":"); if (a[n]==h) found=1} END{exit !found}' "$_f" 2>/dev/null; then
                PL_RC=0
                break
            fi
        done
    else
        PL_RC=2
    fi
}

# udp_listening N -> UL_RC: UDP counterpart of port_listening
# (netstat -uln -> ss -uln -> /proc/net/udp(6) hex compare).
udp_listening() {
    _ul="$1"
    if command -v netstat >/dev/null 2>&1; then
        if netstat -uln 2>/dev/null | awk '{print $4}' | grep -q ":$_ul\$"; then
            UL_RC=0; else UL_RC=1; fi
    elif command -v ss >/dev/null 2>&1; then
        if ss -uln 2>/dev/null | awk '{print $4}' | grep -q ":$_ul\$"; then
            UL_RC=0; else UL_RC=1; fi
    elif [ -r /proc/net/udp ] || [ -r /proc/net/udp6 ]; then
        _hx=$(printf '%04X' "$_ul")
        UL_RC=1
        for _f in /proc/net/udp /proc/net/udp6; do
            [ -r "$_f" ] || continue
            if awk -v h="$_hx" 'NR>1 {n=split($2,a,":"); if (a[n]==h) found=1} END{exit !found}' "$_f" 2>/dev/null; then
                UL_RC=0
                break
            fi
        done
    else
        UL_RC=2
    fi
}

# observe_mihomo_procs -> MIHOMO_PROCS + MIHOMO_PIDS. pidof
# preferred; without it, scan /proc cmdlines for argv0 basename ==
# "mihomo" (the watchdog and this doctor have different basenames
# and are not counted). Observed ONCE near the start and reused by
# the later sections: the report is an interval observation, not an
# atomic snapshot.
observe_mihomo_procs() {
    MIHOMO_PROCS=0
    MIHOMO_PIDS=""
    if command -v pidof >/dev/null 2>&1; then
        MIHOMO_PIDS=$(pidof mihomo 2>/dev/null)
        set -- $MIHOMO_PIDS
        MIHOMO_PROCS=$#
    else
        for _p in /proc/[0-9]*/cmdline; do
            _pid=${_p%/cmdline}; _pid=${_pid#/proc/}
            [ "$_pid" = "$$" ] && continue
            _a0=$(tr '\000' '\n' < "$_p" 2>/dev/null | head -n 1)
            [ "$(basename "$_a0" 2>/dev/null)" = "mihomo" ] || continue
            MIHOMO_PIDS="$MIHOMO_PIDS $_pid"
            MIHOMO_PROCS=$((MIHOMO_PROCS+1))
        done
    fi
}

# probe_controller_version - read-only runtime-version evidence via the
# Mihomo Controller REST API (GET /version only - the same request class
# as mihomo-proxy-selection-watch.sh's GET /proxies). Called ONLY while a Mihomo
# daemon is running: the one-Mihomo invariant forbids executing the
# binary for -v then. Sets BIN_VER ("" stays unknown) and prints the
# evidence lines. A configured secret is sent in the Authorization
# header and is NEVER printed. Every failure mode lands on
# UNKNOWN/UNVERIFIED - never on a FAIL: the controller being off is the
# project default, not a defect.
probe_controller_version() {
    BIN_VER=""
    EC_VAL=$(cfg_scalar external-controller)
    if [ -z "$EC_VAL" ]; then
        info "Runtime version: UNKNOWN / UNVERIFIED (external-controller not configured - the project default; the binary is not executed for -v while the daemon runs)"
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
        info "Runtime version: UNKNOWN / UNVERIFIED (curl unavailable - the Controller probe needs header support wget cannot provide)"
        return 0
    fi
    _ec_secret=$(grep -E "^[[:space:]]*secret:" "$CONFIG" 2>/dev/null | head -n 1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d "\"'")
    if [ -n "$_ec_secret" ]; then
        _resp=$(curl -sS --connect-timeout 3 --max-time 8 -H "Authorization: Bearer $_ec_secret" -w '\n%{http_code}' "http://$EC_VAL/version" 2>/dev/null)
    else
        _resp=$(curl -sS --connect-timeout 3 --max-time 8 -w '\n%{http_code}' "http://$EC_VAL/version" 2>/dev/null)
    fi
    _rc=$?
    if [ "$_rc" -ne 0 ] || [ -z "$_resp" ]; then
        info "Runtime version: UNKNOWN / UNVERIFIED (Controller at $EC_VAL unreachable - connection failure, timeout, or a non-HTTP answer; this is NOT a config or service verdict)"
        return 0
    fi
    _code=$(printf '%s\n' "$_resp" | tail -n 1)
    _body=$(printf '%s\n' "$_resp" | sed '$d')
    case "$_code" in
        200) : ;;
        401|403)
            info "Runtime version: UNKNOWN / UNVERIFIED (Controller answered HTTP $_code - the request was rejected; check the configured secret)"
            return 0 ;;
        404)
            info "Runtime version: UNKNOWN / UNVERIFIED (Controller answered HTTP 404 - /version not found; unexpected service on the controller port?)"
            return 0 ;;
        *)
            info "Runtime version: UNKNOWN / UNVERIFIED (Controller answered HTTP ${_code:-<empty>} - port collision with an unexpected service?)"
            return 0 ;;
    esac
    _ver=""
    if command -v jq >/dev/null 2>&1; then
        _ver=$(printf '%s' "$_body" | jq -r '.version // empty' 2>/dev/null)
        [ "$_ver" = "null" ] && _ver=""
        [ "$_ver" = "empty" ] && _ver=""
    fi
    if [ -z "$_ver" ]; then
        _ver=$(printf '%s\n' "$_body" | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null | head -n 1 | sed 's/.*:[[:space:]]*"//;s/"$//')
    fi
    if [ -z "$_ver" ]; then
        info "Runtime version: UNKNOWN / UNVERIFIED (Controller answered 200 but reported no usable version field - possible foreign service on the controller port)"
        return 0
    fi
    _ver=${_ver#v}
    case "$_ver" in
        ''|*[!0-9.]*)
            info "Runtime version: UNKNOWN / UNVERIFIED (Controller reported an unparseable version string)"
            return 0 ;;
    esac
    BIN_VER=$_ver
    ok "Runtime version $BIN_VER (read-only Controller GET /version at $EC_VAL - the binary itself is NOT executed while the daemon runs)"
    info "Controller evidence scope: proves the runtime version only - not proxy, network or config health (the dedicated sections below cover those)."
}

# probe_controller_proxy_state - lightweight read-only sanity check of
# Mihomo's current proxy selection via GET /proxies. This deliberately does
# NOT duplicate the full proxy-selection watcher: it validates the Controller
# payload and the first selected-group hop only, never changes selection,
# triggers delay tests, restarts Mihomo, or prints proxy/server names.
probe_controller_proxy_state() {
    if [ "$MIHOMO_PROCS" -eq 0 ]; then
        info "Proxy selection sanity skipped: Mihomo is not running"
        return 0
    fi
    _ps_ec=$(cfg_scalar external-controller)
    if [ -z "$_ps_ec" ]; then
        info "Proxy selection sanity: UNKNOWN / UNVERIFIED (external-controller not configured)"
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        info "Proxy selection sanity: UNKNOWN / UNVERIFIED (curl + jq required for read-only GET /proxies)"
        return 0
    fi

    _ps_secret=$(grep -E "^[[:space:]]*secret:" "$CONFIG" 2>/dev/null | head -n 1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d "\"'")
    if [ -n "$_ps_secret" ]; then
        _ps_resp=$(curl -sS --connect-timeout 3 --max-time 8 -H "Authorization: Bearer $_ps_secret" -w '\n%{http_code}' "http://$_ps_ec/proxies" 2>/dev/null)
    else
        _ps_resp=$(curl -sS --connect-timeout 3 --max-time 8 -w '\n%{http_code}' "http://$_ps_ec/proxies" 2>/dev/null)
    fi
    _ps_rc=$?
    if [ "$_ps_rc" -ne 0 ] || [ -z "$_ps_resp" ]; then
        info "Proxy selection sanity: UNKNOWN / UNVERIFIED (Controller /proxies unreachable)"
        return 0
    fi

    _ps_code=$(printf '%s\n' "$_ps_resp" | tail -n 1)
    _ps_body=$(printf '%s\n' "$_ps_resp" | sed '$d')
    case "$_ps_code" in
        200) : ;;
        401|403)
            warn "Proxy selection sanity: Controller /proxies rejected authentication (HTTP $_ps_code)"
            return 0 ;;
        404)
            warn "Proxy selection sanity: Controller /proxies returned HTTP 404"
            return 0 ;;
        *)
            warn "Proxy selection sanity: Controller /proxies returned unexpected HTTP status"
            return 0 ;;
    esac

    if ! printf '%s' "$_ps_body" | jq -e '.proxies | type == "object"' >/dev/null 2>&1; then
        warn "Proxy selection sanity: Controller /proxies returned no usable proxies object"
        return 0
    fi
    _ps_count=$(printf '%s' "$_ps_body" | jq -r '.proxies | keys | length' 2>/dev/null)
    case "$_ps_count" in ''|*[!0-9]*) _ps_count=0 ;; esac

    if ! printf '%s' "$_ps_body" | jq -e '.proxies | has("GLOBAL")' >/dev/null 2>&1; then
        info "Controller /proxies is valid ($_ps_count entries); GLOBAL not present, selection-chain sanity skipped"
        return 0
    fi

    _ps_gtype=$(printf '%s' "$_ps_body" | jq -r '.proxies["GLOBAL"].type // ""' 2>/dev/null)
    _ps_gnow=$(printf '%s' "$_ps_body" | jq -r '.proxies["GLOBAL"].now // ""' 2>/dev/null)
    if [ -z "$_ps_gnow" ]; then
        case "$_ps_gtype" in
            LoadBalance)
                ok "Controller /proxies selection state is usable (GLOBAL is load-balanced; no single current choice)"
                ;;
            *)
                warn "Proxy selection sanity: GLOBAL has no current choice in Controller /proxies"
                ;;
        esac
        return 0
    fi

    if ! printf '%s' "$_ps_body" | jq -e --arg n "$_ps_gnow" '.proxies | has($n)' >/dev/null 2>&1; then
        ok "Controller /proxies selection state is usable (GLOBAL reports a non-empty provider-backed/current choice)"
        return 0
    fi

    _ps_stype=$(printf '%s' "$_ps_body" | jq -r --arg n "$_ps_gnow" '.proxies[$n].type // ""' 2>/dev/null)
    _ps_snow=$(printf '%s' "$_ps_body" | jq -r --arg n "$_ps_gnow" '.proxies[$n].now // ""' 2>/dev/null)
    case "$_ps_stype" in
        Selector|URLTest|Fallback|Relay)
            if [ -n "$_ps_snow" ]; then
                ok "Controller /proxies selection state is usable (GLOBAL and selected group report current choices)"
            else
                warn "Proxy selection sanity: selected proxy group has no current choice in Controller /proxies"
            fi
            ;;
        LoadBalance)
            ok "Controller /proxies selection state is usable (GLOBAL selects a load-balanced group)"
            ;;
        *)
            ok "Controller /proxies selection state is usable (GLOBAL has a current proxy choice)"
            ;;
    esac
}

# cfg_scalar KEY -> prints the first column-0 YAML scalar value
# for KEY, quotes stripped. Nested keys are not matched.
cfg_scalar() {
    _v=$(grep -E "^$1:" "$CONFIG" 2>/dev/null | head -n 1 | sed "s/^$1:[[:space:]]*//")
    printf '%s' "$_v" | tr -d "\"'"
}

# Numeric dotted-version comparator (same semantics as
# update-mihomo.sh): prints lt | eq | gt, or "unknown" when a
# component is non-numeric (prerelease/build suffixes).
ver_compare() {
    _va=$1; _vb=$2
    while :; do
        _a=${_va%%.*}; _ra=""
        case "$_va" in *.*) _ra=${_va#*.} ;; esac
        _b=${_vb%%.*}; _rb=""
        case "$_vb" in *.*) _rb=${_vb#*.} ;; esac
        [ -z "$_a" ] && _a=0
        [ -z "$_b" ] && _b=0
        case "$_a$_b" in *[!0-9]*) echo unknown; return 0 ;; esac
        if [ "$_a" -lt "$_b" ]; then echo lt; return 0; fi
        if [ "$_a" -gt "$_b" ]; then echo gt; return 0; fi
        if [ -z "$_ra" ] && [ -z "$_rb" ]; then echo eq; return 0; fi
        _va=$_ra; _vb=$_rb
    done
}

if [ $# -gt 0 ]; then
    echo "Usage: sh mihomo-doctor.sh"
    echo "  No options. The doctor is strictly read-only."
    exit 0
fi

echo "=== Mihomo Doctor (read-only diagnostic) ==="
info "Nothing is installed, updated, removed, started or stopped; config.yaml and Keenetic settings are not touched."
info "Observation model: the doctor reads the system over an interval - processes may appear or disappear between individual checks; no atomic snapshot is claimed."

BIN_STATE=""      # "" | missing | noexec | ok | segv | execfail | running
BIN=""            # resolved binary path
BIN_VER=""        # parsed version ("" when unrecognized)
RELEASE_JSON=""
NET_GITHUB=1

# One-Mihomo invariant: observe the daemon state ONCE, before any
# decision about executing the binary. While any mihomo process lives,
# the doctor never runs a second Mihomo (-v/-t); the runtime version is
# taken from the read-only Controller API instead.
observe_mihomo_procs
DAEMON_RUNNING=0
[ "$MIHOMO_PROCS" -gt 0 ] && DAEMON_RUNNING=1
if [ "$MIHOMO_PROCS" -gt 1 ]; then
    warn "Multiple mihomo processes observed ($MIHOMO_PROCS PIDs:$MIHOMO_PIDS) - the invariant is exactly one; no Mihomo executable is run while any of them lives"
fi

# Component IDs are install-profile evidence. For two legacy-sensitive
# capabilities (DNS interception and bypass_wa Netfilter rules), Doctor defers
# missing-component severity until the live runtime capability is checked.
DOC_DNS_FILTER_COMPONENT=unknown
DOC_NETFILTER_COMPONENT=unknown
DNS_INTERCEPT_RUNTIME=unknown
BYPASS_NETFILTER_RUNTIME=unknown

# =========================================================
hdr "1. System"
# =========================================================

if command -v ndmc >/dev/null 2>&1; then
    SV_OUT=$(ndmc -c "show version" 2>/dev/null | tr -d '\r')
    _sv_field() { printf '%s\n' "$SV_OUT" | sed -n "s/^[[:space:]]*$1:[[:space:]]*//p" | head -n 1 | sed 's/[[:space:]]*$//'; }
    _model_value=$(_sv_field model)
    if [ -n "$_model_value" ]; then
        MODEL="model: $_model_value"
    else
        MODEL=$(printf '%s\n' "$SV_OUT" | grep -Ei 'model|hw id' | head -n 1 | sed 's/^[[:space:]]*//')
    fi
    if [ -z "$MODEL" ] && command -v ndmq >/dev/null 2>&1; then
        MODEL=$(ndmq -p 'show version' -f json 2>/dev/null | grep -o '"title":"[^"]*"' | cut -d'"' -f4)
    fi
    if [ -n "$MODEL" ]; then
        info "Router: $MODEL"
    else
        info "Router model: not reported by ndmc/ndmq"
    fi
    # KeeneticOS identity from the same read-only `show version` observation.
    # title/release/sandbox/hw_id are each authoritative for their field and
    # are never inferred from each other; informational only - no firmware
    # comparison, no version-based behavior. A field that cannot be read is
    # reported as such, never fabricated.
    _OS_TITLE=$(_sv_field title)
    _OS_RELEASE=$(_sv_field release)
    _OS_CHANNEL=$(_sv_field sandbox)
    _OS_HWID=$(_sv_field hw_id)
    if [ -n "$_OS_TITLE" ]; then info "KeeneticOS: $_OS_TITLE"; else info "KeeneticOS: not reported by ndmc"; fi
    if [ -n "$_OS_RELEASE" ]; then info "Release: $_OS_RELEASE"; else info "Release: not reported by ndmc"; fi
    if [ -n "$_OS_CHANNEL" ]; then info "Channel: $_OS_CHANNEL"; else info "Channel: not reported by ndmc"; fi
    if [ -n "$_OS_HWID" ]; then info "Hardware ID: $_OS_HWID"; else info "Hardware ID: not reported by ndmc"; fi

    # Mirror the installer's named KeeneticOS component contract read-only.
    # Keenetic wraps long component IDs in show version output (for example
    # "dns-" + "filter" and "opkg-kmod-" + "netfilter" on the next line).
    # Normalize only the components field before matching; otherwise a
    # line-oriented grep creates false missing-component findings.
    _doctor_component_list_from_show_version() {
        printf '%s\n' "$SV_OUT" | awk '
            /^[[:space:]]*components:[[:space:]]*/ {
                in_components=1
                line=$0
                sub(/^[[:space:]]*components:[[:space:]]*/, "", line)
                gsub(/[[:space:]]/, "", line)
                printf "%s", line
                next
            }
            in_components {
                line=$0
                sub(/^[[:space:]]*/, "", line)
                if (line ~ /^[[:alnum:]_-]+(,[[:alnum:]_-]+)*,?$/) {
                    gsub(/[[:space:]]/, "", line)
                    printf "%s", line
                    next
                }
                exit
            }
            END {
                if (in_components) printf "\n"
            }
        '
    }

    # Missing evidence is UNKNOWN, not proof that every component is absent.
    if [ -n "$SV_OUT" ]; then
        DOC_COMPONENT_LIST=$(_doctor_component_list_from_show_version)
        _doctor_component_has() {
            _dch_id="$1"
            [ -n "$DOC_COMPONENT_LIST" ] || return 1
            printf '%s\n' "$DOC_COMPONENT_LIST" | grep -Eq "(^|,)${_dch_id}(,|$)"
        }

        if [ -z "$DOC_COMPONENT_LIST" ]; then
            info "Required KeeneticOS component state: UNKNOWN / UNVERIFIED because the components field could not be parsed from show version"
        else
        # Proxy remains a direct hard prerequisite. dns-filter and
        # opkg-kmod-netfilter can be absent from show version on an already
        # running legacy installation while the corresponding capability is
        # still live, so their final severity is decided in section 7.
        if _doctor_component_has proxy; then
            ok "Required KeeneticOS component present: proxy"
        else
            fail "Required KeeneticOS component missing: proxy"
        fi

        if _doctor_component_has dns-filter; then
            DOC_DNS_FILTER_COMPONENT=present
            ok "Required KeeneticOS component present: dns-filter"
        else
            DOC_DNS_FILTER_COMPONENT=missing
            info "Supported-profile component not reported by show version: dns-filter; current severity will be decided from live DNS-interception capability"
        fi

        if _doctor_component_has opkg-kmod-netfilter; then
            DOC_NETFILTER_COMPONENT=present
            ok "Required KeeneticOS component present: opkg-kmod-netfilter"
        else
            DOC_NETFILTER_COMPONENT=missing
            info "Supported-profile component not reported by show version: opkg-kmod-netfilter; current severity will be decided from live bypass_wa Netfilter capability"
        fi
        if _doctor_component_has dns-tls || _doctor_component_has dns-https; then
            _secure_dns_components=""
            _doctor_component_has dns-tls && _secure_dns_components="dns-tls"
            if _doctor_component_has dns-https; then
                if [ -n "$_secure_dns_components" ]; then
                    _secure_dns_components="$_secure_dns_components + dns-https"
                else
                    _secure_dns_components="dns-https"
                fi
            fi
            ok "Secure-DNS KeeneticOS component prerequisite satisfied: $_secure_dns_components"
        else
            fail "Required secure-DNS KeeneticOS component missing: install at least one of dns-tls (DNS-over-TLS proxy) or dns-https (DNS-over-HTTPS proxy)"
        fi
        fi
    else
        info "Required KeeneticOS component state: UNKNOWN / UNVERIFIED because show version is unavailable"
    fi
else
    info "ndmc not available - Keenetic model/component info skipped"
fi
info "Kernel: $(uname -sr 2>/dev/null)  Machine: $(uname -m 2>/dev/null)"

if command -v opkg >/dev/null 2>&1; then
    ARCH_LINES=$(opkg print-architecture 2>/dev/null)
    if [ -n "$ARCH_LINES" ]; then
        info "opkg architectures: $(printf '%s\n' "$ARCH_LINES" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    fi
    ARCH=$(printf '%s\n' "$ARCH_LINES" | awk '/^arch/ && $2~/^(mips|mipsel|aarch64|arm)/{
        sub(/[-_].*/,"",$2); print $2; exit
    }')
    case "$ARCH" in
        aarch64*)    IPK_SUFFIX="aarch64-3.10" ;;
        armv7*|arm*) IPK_SUFFIX="armv7-3.2" ;;
        mipsel*)     IPK_SUFFIX="mipsel-3.4" ;;
        mips*)       IPK_SUFFIX="mips-3.4" ;;
        *)           IPK_SUFFIX="" ;;
    esac
    info "Detected Entware arch: ${ARCH:-unknown}; expected ipk suffix: ${IPK_SUFFIX:-unknown}"
else
    IPK_SUFFIX=""
    info "opkg not available - Entware architecture unknown"
fi

MEM_TOTAL=$(awk '/^MemTotal:/ {print $2}' "$MEMINFO" 2>/dev/null)
MEM_AVAIL=$(awk '/^MemAvailable:/ {print $2}' "$MEMINFO" 2>/dev/null)
SWAP_TOTAL=$(awk '/^SwapTotal:/ {print $2}' "$MEMINFO" 2>/dev/null)
SWAP_FREE=$(awk '/^SwapFree:/ {print $2}' "$MEMINFO" 2>/dev/null)
SWAPS_SRC="${DOCTOR_SWAPS:-/proc/swaps}"
MOUNTS_SRC="${DOCTOR_MOUNTS:-/proc/mounts}"
RESOURCE_PROFILE_CONTRACT_VERSION=20260921_3
DOC_RAM256_MAX_KB=450000
DOC_RAM512_MAX_KB=786432
DOC_SWAP_MAX_KB=2097152
DOC_SYS_CLASS_BLOCK="${DOCTOR_SYS_CLASS_BLOCK:-/sys/class/block}"

# Storage/swap classification - read-only mirror of the installer preflight.
# Keenetic conventions: internal storage is UBIFS (ubi*/mtd*, no block-device
# nodes, cannot host swap); USB/NVMe disks appear as /dev/sd*|/dev/nvme*
# with partitions mounted under /tmp/mnt/*. Sources are overridable
# (DOCTOR_MEMINFO, DOCTOR_SWAPS, DOCTOR_MOUNTS) for read-only testing.
_doc_classify_mount() {
    case "$2" in
        ubifs|squashfs) echo internal; return 0 ;;
        tmpfs|ramfs)    echo ram; return 0 ;;
    esac
    case "$1" in
        ubi*|mtd*) echo internal; return 0 ;;
    esac
    case "$2" in
        ext2|ext3|ext4|btrfs|f2fs|xfs|vfat|fat|exfat|ntfs|ntfs3|fuseblk) ;;
        *) echo unknown; return 0 ;;
    esac
    case "$1" in
        /dev/sd*|/dev/nvme*|/tmp/mnt/*) echo external ;;
        *) echo unknown ;;
    esac
}
_doc_opt_class() {
    # classify the deepest mount carrying $1 (defaults to $OPT_ROOT for the
    # /opt report; swap-file classification passes the file's directory)
    _doc_oc_path="${1:-$OPT_ROOT}" _doc_oc_bl=0 _doc_oc_cls=unknown
    [ -r "$MOUNTS_SRC" ] || { echo unknown; return 0; }
    while read -r _doc_oc_src _doc_oc_mp _doc_oc_fst _doc_oc_rest; do
        case "$_doc_oc_path" in
            "$_doc_oc_mp") ;;
            *) case "$_doc_oc_path" in
                   "$_doc_oc_mp"/*) ;;
                   *) continue ;;
               esac ;;
        esac
        _doc_oc_len=${#_doc_oc_mp}
        [ "$_doc_oc_len" -ge "$_doc_oc_bl" ] || continue
        _doc_oc_bl=$_doc_oc_len
        _doc_oc_cls=$(_doc_classify_mount "$_doc_oc_src" "$_doc_oc_fst")
    done < "$MOUNTS_SRC"
    echo "$_doc_oc_cls"
}

_doc_opt_fstype() {
    _doc_of_path="${1:-$OPT_ROOT}" _doc_of_bl=0 _doc_of_fst=unknown
    [ -r "$MOUNTS_SRC" ] || { echo unknown; return 0; }
    while read -r _doc_of_src _doc_of_mp _doc_of_type _doc_of_rest; do
        case "$_doc_of_path" in
            "$_doc_of_mp") ;;
            *) case "$_doc_of_path" in
                   "$_doc_of_mp"/*) ;;
                   *) continue ;;
               esac ;;
        esac
        _doc_of_len=${#_doc_of_mp}
        [ "$_doc_of_len" -ge "$_doc_of_bl" ] || continue
        _doc_of_bl=$_doc_of_len
        _doc_of_fst=$_doc_of_type
    done < "$MOUNTS_SRC"
    echo "$_doc_of_fst"
}
_doc_swap_source_capacity_kb() {
    _dsc_src="$1"; _dsc_type="$2"; _dsc_active="$3"; _dsc_cap=""
    case "$_dsc_type" in
        partition)
            _dsc_base=${_dsc_src##*/}
            _dsc_sectors=$(cat "$DOC_SYS_CLASS_BLOCK/$_dsc_base/size" 2>/dev/null || true)
            case "$_dsc_sectors" in ''|*[!0-9]*) : ;; *) _dsc_cap=$((_dsc_sectors / 2)) ;; esac
            ;;
        file)
            if [ -f "$_dsc_src" ]; then
                _dsc_bytes=$(wc -c < "$_dsc_src" 2>/dev/null || true)
                case "$_dsc_bytes" in ''|*[!0-9]*) : ;; *) _dsc_cap=$((_dsc_bytes / 1024)) ;; esac
            fi
            ;;
    esac
    [ -n "$_dsc_cap" ] || _dsc_cap="$_dsc_active"
    printf '%s' "$_dsc_cap"
}

_doc_scan_swap() {
    _doc_zram_kb=0; _doc_ext_kb=0; _doc_unver_kb=0
    _doc_deleted_kb=0; _doc_deleted_count=0
    _doc_ext_max_backend_kb=0; _doc_ext_oversize=0
    [ -r "$SWAPS_SRC" ] || { _doc_unver_kb=-1; return 0; }
    while read -r _doc_sw_file _doc_sw_type _doc_sw_size _doc_sw_rest; do
        case "$_doc_sw_file" in ''|Filename) continue ;; esac
        case "$_doc_sw_size" in ''|*[!0-9]*) continue ;; esac
        case "$_doc_sw_file" in
            *'\040(deleted)'*|*' (deleted)'*)
                _doc_deleted_kb=$((_doc_deleted_kb + _doc_sw_size))
                _doc_deleted_count=$((_doc_deleted_count + 1))
                continue
                ;;
            *zram*) _doc_zram_kb=$((_doc_zram_kb + _doc_sw_size)); continue ;;
        esac
        case "$_doc_sw_type" in
            partition)
                case "$_doc_sw_file" in
                    /dev/sd*|/dev/nvme*)
                        _doc_ext_kb=$((_doc_ext_kb + _doc_sw_size))
                        _doc_cap=$(_doc_swap_source_capacity_kb "$_doc_sw_file" "$_doc_sw_type" "$_doc_sw_size")
                        [ "$_doc_cap" -gt "$_doc_ext_max_backend_kb" ] 2>/dev/null && _doc_ext_max_backend_kb=$_doc_cap
                        [ "$_doc_cap" -gt "$DOC_SWAP_MAX_KB" ] 2>/dev/null && _doc_ext_oversize=1
                        ;;
                    *) _doc_unver_kb=$((_doc_unver_kb + _doc_sw_size)) ;;
                esac ;;
            file)
                case "$(_doc_opt_class "$(dirname "$_doc_sw_file")")" in
                    external)
                        _doc_ext_kb=$((_doc_ext_kb + _doc_sw_size))
                        _doc_cap=$(_doc_swap_source_capacity_kb "$_doc_sw_file" "$_doc_sw_type" "$_doc_sw_size")
                        [ "$_doc_cap" -gt "$_doc_ext_max_backend_kb" ] 2>/dev/null && _doc_ext_max_backend_kb=$_doc_cap
                        [ "$_doc_cap" -gt "$DOC_SWAP_MAX_KB" ] 2>/dev/null && _doc_ext_oversize=1
                        ;;
                    *) _doc_unver_kb=$((_doc_unver_kb + _doc_sw_size)) ;;
                esac ;;
            *) _doc_unver_kb=$((_doc_unver_kb + _doc_sw_size)) ;;
        esac
    done < "$SWAPS_SRC"
    [ "$_doc_ext_kb" -gt "$DOC_SWAP_MAX_KB" ] 2>/dev/null && _doc_ext_oversize=1
}

_doc_opt=$(_doc_opt_class)
_doc_opt_fstype_value=$(_doc_opt_fstype)
case "$_doc_opt" in
    internal) info "/opt storage: internal Keenetic storage (filesystem: ${_doc_opt_fstype_value:-unknown})" ;;
    external) info "/opt storage: external persistent storage (filesystem: ${_doc_opt_fstype_value:-unknown})" ;;
    ram)      info "/opt storage: RAM-backed (tmpfs/ramfs) - not persistent" ;;
    *)        info "/opt storage: cannot determine (filesystem: ${_doc_opt_fstype_value:-unknown})" ;;
esac

if [ "$_doc_opt" = external ]; then
    if [ "$_doc_opt_fstype_value" = ext4 ]; then
        ok "External /opt filesystem is EXT4 (supported project storage contract)"
    else
        fail "Unsupported external /opt filesystem: ${_doc_opt_fstype_value:-unknown} - project contract supports external Entware only on EXT4"
    fi

    if [ -n "${SV_OUT:-}" ]; then
        if _doctor_component_has ext; then
            ok "External-storage KeeneticOS component present: ext"
        else
            fail "Required external-storage KeeneticOS component missing: ext (Ext filesystem / Файловая система Ext)"
        fi
        if _doctor_component_has ext-utils; then
            ok "External-storage KeeneticOS component present: ext-utils"
        else
            fail "Required external-storage KeeneticOS component missing: ext-utils (EXT4 filesystem utilities / Утилиты EXT4)"
        fi
    else
        info "External-storage component state (ext/ext-utils): UNKNOWN / UNVERIFIED because show version is unavailable"
    fi
fi

_doc_scan_swap
_doc_swap_target_kb=0
if is_num "$MEM_TOTAL"; then
    _doc_swap_target_kb=$((MEM_TOTAL * 3))
    [ "$_doc_swap_target_kb" -gt "$DOC_SWAP_MAX_KB" ] && _doc_swap_target_kb=$DOC_SWAP_MAX_KB
fi
if [ "$_doc_deleted_count" -gt 0 ]; then
    warn "$_doc_deleted_count swap source(s) are marked '(deleted)' in $SWAPS_SRC ($((_doc_deleted_kb/1024)) MB active according to the kernel) - stale/ambiguous entries are ignored for verified external-SWAP capacity, sizing target and 2 GiB checks"
fi
if [ "$_doc_ext_oversize" -eq 1 ]; then
    fail "External storage-backed SWAP exceeds 2 GiB (active total: $((_doc_ext_kb/1024)) MB; largest detected backend: $((_doc_ext_max_backend_kb/1024)) MB) - project/vendor cap is 2048 MB"
fi
if [ "$_doc_zram_kb" -gt 0 ] 2>/dev/null && [ "$_doc_ext_kb" -gt 0 ] 2>/dev/null; then
    warn "zRAM and external storage-backed swap are active together - vendor guidance says not to use both; when disk/file swap is used, disable zRAM"
fi
if is_num "$MEM_TOTAL"; then
    info "RAM total: $((MEM_TOTAL/1024)) MB, available: $(is_num "$MEM_AVAIL" && echo $((MEM_AVAIL/1024)) || echo '?') MB"
    if [ "$MEM_TOTAL" -lt 200000 ]; then
        if [ "$_doc_opt" != external ]; then
            fail "Low-RAM prerequisite NOT met (/opt is not on verified external persistent storage): the 128 MB-class best-effort/experimental profile requires external /opt plus >= 384 MB active swap on external storage, project-specific experimental floor; zRAM does not count (docs/06)"
        elif [ "$_doc_ext_kb" -ge 393216 ]; then
            warn "Low-RAM / best-effort profile ($((MEM_TOTAL/1024)) MB + $((_doc_ext_kb/1024)) MB external storage-backed swap on external /opt): prerequisite met - still EXPERIMENTAL, stability is NOT guaranteed (docs/06)"
        else
            fail "Low-RAM prerequisite NOT met ($((MEM_TOTAL/1024)) MB, only $((_doc_ext_kb/1024)) MB external storage-backed active swap on external /opt; zRAM $((_doc_zram_kb/1024)) MB does not count): >= 384 MB active swap on external storage is required, 512 MB preferred; best-effort/experimental regardless (docs/06)"
        fi
    elif [ "$MEM_TOTAL" -lt "$DOC_RAM256_MAX_KB" ]; then
        if [ "$_doc_zram_kb" -gt 0 ]; then
            ok "256 MB-class has active zRAM ($((_doc_zram_kb/1024)) MB)"
        elif [ "$_doc_ext_kb" -gt 0 ]; then
            ok "256 MB-class has external storage-backed swap ($((_doc_ext_kb/1024)) MB) with zRAM off"
            if [ "$_doc_ext_kb" -lt "$MEM_TOTAL" ]; then
                warn "External SWAP is below project minimum floor: $((_doc_ext_kb/1024)) MB active vs about $((MEM_TOTAL/1024)) MB minimum (1x detected RAM; project policy, not vendor minimum)"
            elif [ "$_doc_swap_target_kb" -gt 0 ] && [ "$_doc_ext_kb" -lt "$_doc_swap_target_kb" ]; then
                info "External SWAP is below preferred project sizing target but meets the minimum floor: $((_doc_ext_kb/1024)) MB active, minimum about $((MEM_TOTAL/1024)) MB (1x RAM), preferred target about $((_doc_swap_target_kb/1024)) MB (3x RAM, capped at 2048 MB)"
            fi
        else
            warn "256 MB-class has neither active zRAM nor verified external storage-backed SWAP - project policy expects one backend on <=512 MB-class"
        fi
    elif [ "$MEM_TOTAL" -lt "$DOC_RAM512_MAX_KB" ]; then
        if [ "$_doc_zram_kb" -gt 0 ]; then
            ok "512 MB-class has active zRAM ($((_doc_zram_kb/1024)) MB)"
        elif [ "$_doc_ext_kb" -gt 0 ]; then
            ok "512 MB-class has external storage-backed swap ($((_doc_ext_kb/1024)) MB) with zRAM off"
            if [ "$_doc_ext_kb" -lt "$MEM_TOTAL" ]; then
                warn "External SWAP is below project minimum floor: $((_doc_ext_kb/1024)) MB active vs about $((MEM_TOTAL/1024)) MB minimum (1x detected RAM; project policy, not vendor minimum)"
            elif [ "$_doc_swap_target_kb" -gt 0 ] && [ "$_doc_ext_kb" -lt "$_doc_swap_target_kb" ]; then
                info "External SWAP is below preferred project sizing target but meets the minimum floor: $((_doc_ext_kb/1024)) MB active, minimum about $((MEM_TOTAL/1024)) MB (1x RAM), preferred target about $((_doc_swap_target_kb/1024)) MB (3x RAM, capped at 2048 MB)"
            fi
        else
            warn "512 MB-class has neither active zRAM nor verified external storage-backed SWAP - project policy expects one backend on <=512 MB-class"
        fi
    else
        info "Above-512 MB memory class: swap/zRAM is optional"
    fi
    if is_num "$MEM_AVAIL" && [ "$MEM_AVAIL" -lt 25000 ]; then
        warn "Very low available memory ($((MEM_AVAIL/1024)) MB) - Mihomo (UPX-packed, unpacks in RAM) and updates need headroom"
    fi
else
    info "RAM usage cannot be read ($MEMINFO)"
fi
if is_num "$SWAP_TOTAL"; then
    if [ "$SWAP_TOTAL" -eq 0 ]; then
        info "Swap: none configured"
    else
        info "Swap: $((SWAP_TOTAL/1024)) MB (free $((SWAP_FREE/1024)) MB)"
    fi
fi
# Swap backend breakdown (read-only): /proc/swaps, when readable, shows
# which backends are actually ACTIVE - KeeneticOS zRAM (compressed swap
# in RAM, written without a NAND swap file) vs external storage-backed
# (block device / swap file on external storage). Unrecognized entries are
# reported separately, never guessed into a class.
if is_num "$SWAP_TOTAL" && [ "$SWAP_TOTAL" -gt 0 ] && [ -r "$SWAPS_SRC" ]; then
    _doc_scan_swap
    if [ "$_doc_unver_kb" -gt 0 ]; then
        info "Swap entries that could not be classified: $((_doc_unver_kb/1024)) MB"
    fi
    if [ "$_doc_zram_kb" -gt 0 ] && [ "$_doc_ext_kb" -gt 0 ]; then
        info "Swap backends: zRAM $((_doc_zram_kb/1024)) MB (compressed in RAM) + storage-backed $((_doc_ext_kb/1024)) MB"
    elif [ "$_doc_zram_kb" -gt 0 ]; then
        info "Swap backends: zRAM only, $((_doc_zram_kb/1024)) MB (compressed swap in RAM - not a NAND swap file)"
    elif [ "$_doc_ext_kb" -gt 0 ]; then
        info "Swap backends: storage-backed $((_doc_ext_kb/1024)) MB (external block device/swap file)"
    fi
fi

for _mount in "$OPT_ROOT" /tmp; do
    _df_line=$(df -k "$_mount" 2>/dev/null | awk 'NR==2 {print $2 " " $4}')
    _fs_total_kb=${_df_line%% *}
    _fs_avail_kb=${_df_line#* }
    _fs_valid=1
    case "$_fs_total_kb" in ''|*[!0-9]*) _fs_valid=0 ;; esac
    case "$_fs_avail_kb" in ''|*[!0-9]*) _fs_valid=0 ;; esac
    if [ "$_fs_valid" -ne 1 ]; then
        info "Free space on $_mount: cannot determine"
    elif [ "$_fs_total_kb" -gt 0 ]; then
        _fs_free_pct=$((_fs_avail_kb * 100 / _fs_total_kb))
        info "Free space on $_mount: $((_fs_avail_kb/1024)) MB of $((_fs_total_kb/1024)) MB (${_fs_free_pct}% free)"
    else
        info "Free space on $_mount: $((_fs_avail_kb/1024)) MB"
    fi
done

# =========================================================
hdr "2. Entware"
# =========================================================

if [ -d "$OPT_ROOT" ]; then
    ok "Entware root present ($OPT_ROOT)"
else
    fail "Entware root $OPT_ROOT not found - is Entware installed?"
fi
if command -v opkg >/dev/null 2>&1; then
    ok "opkg present"
else
    fail "opkg not found - Entware package manager unavailable"
fi
for _d in bin etc etc/init.d etc/mihomo var/log; do
    if [ -d "$OPT_ROOT/$_d" ]; then
        info "Directory present: $OPT_ROOT/$_d"
    else
        info "Directory absent:  $OPT_ROOT/$_d"
    fi
done

PRESENT_TOOLS=""; MISSING_TOOLS=""
for _t in opkg curl wget jq tar gzip pidof ss netstat nslookup ndmc ndmq timeout; do
    if command -v "$_t" >/dev/null 2>&1; then
        PRESENT_TOOLS="$PRESENT_TOOLS $_t"
    else
        MISSING_TOOLS="$MISSING_TOOLS $_t"
    fi
done
info "Tools present:${PRESENT_TOOLS:- none}"
info "Tools missing:${MISSING_TOOLS:- none}"
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    warn "Neither curl nor wget available - network checks, install.sh and update-mihomo.sh cannot download anything"
fi

# =========================================================
hdr "3. Mihomo binary"
# =========================================================

# Runtime resolution (mirrors update-mihomo.sh / migrate-mihomo-mips.sh):
# the running daemon's /proc/PID/exe is authoritative when it names a
# canonical path; otherwise /opt/sbin/mihomo (the Entware init PATH
# order), then /opt/bin/mihomo. Nested copies such as meta-backup/mihomo
# are never selected as the diagnostic subject; they are only reported
# as extras. Read-only-specific: everything below respects DOCTOR_OPT_ROOT.
RUNTIME_EXE=""
_RUNTIME_SEEN=""
_READLINK_FAILED=0
if command -v pidof >/dev/null 2>&1; then
    for _p in $(pidof mihomo 2>/dev/null); do
        _exe=$(readlink "/proc/$_p/exe" 2>/dev/null)
        if [ -z "$_exe" ]; then
            _READLINK_FAILED=1
            continue
        fi
        _RUNTIME_SEEN="$_exe"
        if [ "$_exe" = "$OPT_ROOT/sbin/mihomo" ] || [ "$_exe" = "$OPT_ROOT/bin/mihomo" ]; then
            RUNTIME_EXE="$_exe"
            break
        fi
    done
fi
if [ -n "$RUNTIME_EXE" ]; then
    BIN="$RUNTIME_EXE"
    info "Runtime binary resolved from the running daemon (/proc/PID/exe): $BIN"
else
    if [ -n "$_RUNTIME_SEEN" ]; then
        info "Running daemon executes: $_RUNTIME_SEEN (non-canonical path - reported, never selected as the runtime)"
    elif [ "$_READLINK_FAILED" = "1" ]; then
        info "Could not inspect /proc/PID/exe - falling back to the deterministic path order"
    fi
    if [ -f "$OPT_ROOT/sbin/mihomo" ]; then
        BIN="$OPT_ROOT/sbin/mihomo"
        info "Diagnostic subject resolved by the init PATH order: $BIN (/opt/sbin precedes /opt/bin)"
    elif [ -f "$MIHOMO_PATH" ]; then
        BIN="$MIHOMO_PATH"
    elif COMMAND_PATH=$(command -v mihomo 2>/dev/null) && [ -n "$COMMAND_PATH" ]; then
        BIN="$COMMAND_PATH"
        info "Binary not at $OPT_ROOT/sbin/mihomo or $MIHOMO_PATH, found via PATH: $BIN"
    else
        fail "Mihomo binary not found ($OPT_ROOT/sbin/mihomo, $MIHOMO_PATH)"
        info "Install with install.sh - the doctor does not install anything."
        BIN_STATE="missing"
    fi
fi

if [ -n "$BIN" ]; then
    if [ -x "$BIN" ]; then
        BIN_STATE=""   # decided by the run below
    else
        fail "Mihomo binary exists but is not executable ($BIN) - 'chmod +x $BIN' is needed; the doctor does not modify files"
        BIN_STATE="noexec"
    fi

    BIN_SIZE=$(wc -c < "$BIN" 2>/dev/null)
    if is_num "$BIN_SIZE"; then
        BIN_SIZE_KB=$(( (BIN_SIZE + 1023) / 1024 ))
        info "Binary: $BIN (${BIN_SIZE_KB} KB)"

        _stage_avail_kb=$(df -k "$OPT_ROOT" 2>/dev/null | awk 'NR==2 {print $4}')
        case "$_stage_avail_kb" in
            ''|*[!0-9]*)
                info "Mihomo update staging headroom on $OPT_ROOT: cannot determine free space"
                ;;
            *)
                _stage_need_kb=$((BIN_SIZE_KB + MIHOMO_STAGE_MARGIN_KB))
                if [ "$_stage_avail_kb" -lt "$_stage_need_kb" ]; then
                    info "Mihomo update staging estimate on $OPT_ROOT: $((_stage_avail_kb/1024)) MB available; current binary + ${MIHOMO_STAGE_MARGIN_KB} KB margin would suggest ~$((_stage_need_kb/1024)) MB, but this is NOT an update gate because the extracted candidate can differ substantially in size. update-mihomo.sh measures the actual candidate before stopping or replacing Mihomo."
                else
                    info "Mihomo update staging estimate on $OPT_ROOT: $((_stage_avail_kb/1024)) MB available; current binary + ${MIHOMO_STAGE_MARGIN_KB} KB margin suggests ~$((_stage_need_kb/1024)) MB. This is only an estimate; update-mihomo.sh measures the actual extracted candidate and is the authoritative free-space gate."
                fi
                ;;
        esac
    fi

    EXTRA_BINS=$(find "$OPT_ROOT" -name mihomo -type f 2>/dev/null | grep -v "^$BIN\$" | head -n 4)
    if [ -n "$EXTRA_BINS" ]; then
        info "Additional mihomo files present (never selected as the runtime by update-mihomo.sh / migrate-mihomo-mips.sh):"
        printf '%s\n' "$EXTRA_BINS" | while IFS= read -r _x; do info "  $_x"; done
    fi

    if [ "$BIN_STATE" != "noexec" ]; then
    if [ "$DAEMON_RUNNING" -eq 1 ]; then
        # One-Mihomo invariant: the binary is NEVER executed here.
        BIN_STATE="running"
        info "Mihomo daemon is running - the binary is NOT executed (-v would start a second Mihomo: the established SIGSEGV pattern on constrained hardware)"
        if [ "$MIHOMO_PROCS" -gt 1 ]; then
            info "PID-level runtime resolution is ambiguous with multiple processes - each PID was inspected; none is reported as 'the healthy runtime'"
        fi
        probe_controller_version
    else
        run_with_timeout 15 "$BIN" -v
        MV_RC=$RUN_RC
        MV_OUT=$RUN_OUT
        case "$MV_RC" in
            0)
                BIN_STATE="ok"
                BIN_VER=$(first_line "$MV_OUT" | awk '{print $3}')
                BIN_VER=${BIN_VER#v}
                case "$BIN_VER" in
                    ''|*[!0-9.]*) BIN_VER="" ;;
                esac
                if [ -n "$BIN_VER" ]; then
                    ok "Mihomo binary runs - version $BIN_VER ($(first_line "$MV_OUT"))"
                else
                    ok "Mihomo binary executes (exit 0)"
                    info "Version string not recognized from: $(first_line "$MV_OUT")"
                    info "A successful exit with an unparseable version is NOT proof of corruption; update-mihomo.sh reports 'Current Mihomo: unknown' for such builds and treats it as a repair case."
                fi
                ;;
            124)
                fail "Mihomo binary did not exit within 15s (timeout) - hung execution"
                BIN_STATE="execfail"
                ;;
            139)
                fail "Mihomo binary exists but cannot execute (exit 139 / possible SIGSEGV)"
                BIN_STATE="segv"
                ;;
            126)
                fail "Mihomo binary cannot be executed (exit 126 - wrong architecture or corrupted file)"
                BIN_STATE="execfail"
                ;;
            127)
                fail "Mihomo binary execution failed (exit 127 - missing dynamic loader or broken file)"
                BIN_STATE="execfail"
                ;;
            *)
                if [ "$MV_RC" -gt 128 ] && [ "$MV_RC" -lt 192 ]; then
                    fail "Mihomo binary killed by signal $((MV_RC-128)) (exit $MV_RC)"
                else
                    fail "Mihomo binary exits with an error (exit $MV_RC)"
                fi
                BIN_STATE="execfail"
                ;;
        esac
        if [ "$MV_RC" -ne 0 ] && printf '%s\n' "$MV_OUT" | grep -q "Segmentation fault"; then
            if [ "$BIN_STATE" != "segv" ]; then
                fail "Mihomo binary exists but cannot execute (Segmentation fault reported, exit $MV_RC)"
                BIN_STATE="segv"
            fi
        fi
        if [ "$BIN_STATE" = "segv" ]; then
            info "Output: $(first_line "$MV_OUT")"
            info "Confirmed live on a 256 MB MIPSLE device (no swap): a second Mihomo execution while the daemon is running SIGSEGVs regardless of UPX packing - the packed installed binary and an UPX-unpacked build both crashed, and the same binary passed once the daemon was stopped. UPX is not the established cause."
            info "Likely mechanism: memory pressure from two concurrent Mihomo instances. This probe ran only because NO Mihomo daemon was observed running (the doctor never executes a second Mihomo while one lives), so the failure belongs to the binary or its environment, not to probe interference."
        fi
    fi
    fi
    if command -v opkg >/dev/null 2>&1; then
        # BusyBox opkg prints "mihomo - 1.19.30-1": the version is $3
        # when $2 is the literal dash. Package metadata is NOT runtime
        # truth - a stale opkg entry beside a newer runtime is a
        # legitimate observable state, never a FAIL.
        _opkg_mihomo=$(opkg list-installed 2>/dev/null | awk '$1 == "mihomo" { if ($2 == "-" && $3 != "") print $3; else print $2; exit }')
        if [ -n "$_opkg_mihomo" ]; then
            _opkg_base=$_opkg_mihomo
            case "${_opkg_mihomo#*-}" in
                ''|*[!0-9]*) : ;;   # no numeric -<release> suffix
                *) _opkg_base=${_opkg_mihomo%-"${_opkg_mihomo#*-}"} ;;
            esac
            if [ -n "$BIN_VER" ] && [ "$_opkg_base" != "$BIN_VER" ]; then
                info "opkg database: mihomo $_opkg_mihomo (stale metadata - expected under the binary-update model; the binary version above is the runtime truth)"
            else
                info "opkg database: mihomo $_opkg_mihomo"
            fi
        else
            info "opkg database has no mihomo entry (expected: the updater replaces the binary without touching opkg)"
        fi
    fi
fi

# =========================================================
hdr "4. Config"
# =========================================================

if [ ! -f "$CONFIG" ]; then
    warn "config.yaml not found ($CONFIG) - Mihomo has nothing to load; install.sh writes a bootstrap (mixed-port 7890) on fresh installs"
elif [ ! -r "$CONFIG" ]; then
    warn "config.yaml is not readable ($CONFIG)"
else
    CONFIG_SIZE=$(wc -c < "$CONFIG" 2>/dev/null)
    if is_num "$CONFIG_SIZE"; then
        info "config.yaml present ($((CONFIG_SIZE/1024)) KB) - contents are never printed by the doctor"
    fi

    CFG_PORTS=""
    CFG_HAS_CONTRACT=0
    for _key in mixed-port port socks-port redir-port tproxy-port; do
        _val=$(cfg_scalar "$_key")
        is_num "$_val" || continue
        info "Configured port ($_key): $_val"
        case " $CFG_PORTS " in *" $_val "*) ;; *) CFG_PORTS="$CFG_PORTS $_val" ;; esac
        [ "$_val" = "$CONTRACT_PORT" ] && CFG_HAS_CONTRACT=1
    done
    if [ -z "$CFG_PORTS" ]; then
        info "No inbound proxy port parsed from config (contract port $CONTRACT_PORT normally comes from mixed-port; the bootstrap sets it)"
    elif [ "$CFG_HAS_CONTRACT" -eq 0 ]; then
        warn "Contract port $CONTRACT_PORT is not among the configured ports - watchdog port check and the project ProxyN upstream (127.0.0.1:$CONTRACT_PORT) will fail with this config"
    fi

    EC_VAL=$(cfg_scalar external-controller)
    if [ -z "$EC_VAL" ]; then
        info "external-controller not set - REST API disabled (the project default; port 9090 is a convention, not a default)"
    else
        EC_HOST=${EC_VAL%:*}
        EC_PORT=${EC_VAL##*:}
        case "$EC_HOST" in
            127.0.0.1|localhost|::1)
                info "external-controller bound to loopback (port $EC_PORT)"
                ;;
            *)
                EC_SECRET=$(grep -E "^[[:space:]]*secret:" "$CONFIG" 2>/dev/null | head -n 1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d "\"'")
                if [ -z "$EC_SECRET" ]; then
                    info "external-controller bound beyond loopback without a secret - accepted by the project trust-boundary contract; keep the Controller inside a trusted LAN/VPN and out of WAN/untrusted segments"
                else
                    info "external-controller bound beyond loopback with a secret set (port $EC_PORT)"
                fi
                ;;
        esac
    fi

    if grep -Eq "^tun:" "$CONFIG" 2>/dev/null && \
       awk '/^tun:/{f=1;next} f&&/^[^[:space:]]/{f=0} f&&/enable:/&&/true/{found=1} END{exit !found}' "$CONFIG" 2>/dev/null; then
        info "TUN enabled in config (mitun0 inbound expected)"
    fi

    DL_VAL=$(grep -E "^[[:space:]]+listen:" "$CONFIG" 2>/dev/null | head -n 1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d "\"'")
    DL_PORT=${DL_VAL##*:}
    DNS_PORT=""
    if is_num "$DL_PORT"; then
        DNS_PORT="$DL_PORT"
        info "DNS listen (best-effort parse): port $DNS_PORT"
    fi

    if [ "$DAEMON_RUNNING" -eq 1 ]; then
        info "Config validation SKIPPED / UNVERIFIED: Mihomo is running and 'mihomo -t' would execute a second Mihomo (the established SIGSEGV pattern on constrained hardware) - the one-Mihomo invariant wins. The running config is NOT judged by this test; stop the service to enable the executable validation."
    elif [ "$BIN_STATE" = "ok" ]; then
        run_with_timeout 30 "$BIN" -d "$CONFIG_DIR" -t
        if [ "$RUN_RC" -eq 0 ]; then
            ok "Config test passed ($BIN -d $CONFIG_DIR -t)"
        else
            fail "Config test FAILED (exit $RUN_RC) - the running config is rejected by this Mihomo version"
            info "Run 'mihomo -t -d $CONFIG_DIR' interactively for the exact error (the doctor does not print config-derived error text to avoid leaking details)."
        fi
    else
        info "Config test not performed: the binary cannot be executed right now (state: ${BIN_STATE:-unknown}) - the config itself is NOT judged"
    fi
fi

# =========================================================
hdr "5. Service"
# =========================================================

INIT_SCRIPT=""
if [ -x "$INIT_EXPECTED" ]; then
    INIT_SCRIPT="$INIT_EXPECTED"
    ok "Mihomo init script present ($INIT_SCRIPT)"
elif [ -f "$INIT_EXPECTED" ]; then
    INIT_SCRIPT="$INIT_EXPECTED"
    warn "Mihomo init script exists but is not executable ($INIT_SCRIPT)"
else
    INIT_SCRIPT=$(find "$OPT_ROOT/etc/init.d" -name '*mihomo*' -type f 2>/dev/null | head -n 1)
    if [ -n "$INIT_SCRIPT" ]; then
        info "Init script found (non-standard name): $INIT_SCRIPT"
    else
        info "No Mihomo init script in $OPT_ROOT/etc/init.d (expected $INIT_EXPECTED)"
    fi
fi

# Process state was observed once at the top of section 3 and is
# reused here (interval observation, not an atomic snapshot).
if [ "$MIHOMO_PROCS" -gt 0 ]; then
    if [ -n "$INIT_SCRIPT" ]; then
        ok "Mihomo is running ($MIHOMO_PROCS process(es)), managed by $INIT_SCRIPT"
    else
        warn "Mihomo is running ($MIHOMO_PROCS process(es)) but no init script found - not managed, not started on boot"
    fi
    if [ "$MIHOMO_PROCS" -gt 1 ]; then
        warn "Multiple mihomo processes ($MIHOMO_PROCS) - expected 1, possible stale leftovers"
    fi
else
    if [ -n "$INIT_SCRIPT" ]; then
        warn "Mihomo service is stopped (init script present). If you stopped it yourself, this is expected - the doctor never starts services"
    else
        fail "Mihomo is not running and no init script exists - nothing will start it on boot ($INIT_EXPECTED missing)"
    fi
fi
if ! command -v pidof >/dev/null 2>&1; then
    info "pidof unavailable - process count done via /proc scan"
fi

# =========================================================
hdr "6. Ports"
# =========================================================

if [ "$MIHOMO_PROCS" -eq 0 ]; then
    info "Mihomo is not running - listener checks are informational only"
    port_listening "$CONTRACT_PORT"
    if [ "$PL_RC" -eq 0 ]; then
        warn "Port $CONTRACT_PORT is listening but Mihomo is not running - a foreign process or a stale instance holds the contract port"
    else
        info "Contract port $CONTRACT_PORT not listening (consistent with the stopped service)"
    fi
else
    if [ -n "$CFG_PORTS" ]; then
        for _pl in $CFG_PORTS; do
            port_listening "$_pl"
            if [ "$PL_RC" -eq 0 ]; then
                ok "Listening on configured port $_pl"
            elif [ "$PL_RC" -eq 2 ]; then
                info "Cannot verify listeners (no netstat/ss and no /proc/net/tcp)"
            elif [ "$_pl" = "$CONTRACT_PORT" ]; then
                fail "Mihomo is running but contract port $CONTRACT_PORT is NOT listening - the proxy is unreachable (check config and startup logs)"
            else
                warn "Mihomo is running but configured port $_pl is not listening"
            fi
        done
    else
        port_listening "$CONTRACT_PORT"
        if [ "$PL_RC" -eq 0 ]; then
            ok "Listening on contract port $CONTRACT_PORT"
        elif [ "$PL_RC" -eq 2 ]; then
            info "Cannot verify listeners (no netstat/ss and no /proc/net/tcp)"
        else
            warn "No port defined in config and contract port $CONTRACT_PORT not listening - the watchdog will treat the proxy as down (TUN-only config?)"
        fi
    fi

    if [ -n "$EC_PORT" ] && is_num "$EC_PORT"; then
        port_listening "$EC_PORT"
        if [ "$PL_RC" -eq 0 ]; then
            info "external-controller port $EC_PORT is listening"
        else
            info "external-controller port $EC_PORT is configured but not listening (optional listener)"
        fi
    fi
    if [ -n "$DNS_PORT" ]; then
        port_listening "$DNS_PORT"
        if [ "$PL_RC" -eq 0 ]; then
            info "DNS listen port $DNS_PORT is listening"
        else
            info "DNS listen port $DNS_PORT is configured but not listening (optional listener)"
        fi
    fi
fi

# =========================================================
hdr "6a. Mihomo proxy selection (read-only)"
# =========================================================

probe_controller_proxy_state

# =========================================================
hdr "6b. MagiTrickle (optional component, read-only)"
# =========================================================

# Ground truth: magitrickle 0.8.2 Entware package. The daemon
# is magitrickled (NEVER executed by the doctor - running the
# binary without arguments would start a second daemon); the
# config is /opt/var/lib/magitrickle/config.yaml (nested YAML);
# DNS proxy listens on :3553 and forwards to 127.0.0.1:53; the
# web UI sits on :8080; port 53 is remapped via nat-table DNAT
# rules into MT_* chains; ipset tables use the mt_ prefix.
# MagiTrickle logs go to stdout and are lost at daemonization,
# so there is no log file to analyze.

MT_INSTALLED=0
MT_VER=""
if command -v opkg >/dev/null 2>&1; then
    MT_VER=$(opkg list-installed 2>/dev/null | awk '$1 == "magitrickle" { if ($2 == "-" && $3 != "") print $3; else print $2; exit }')
    [ -n "$MT_VER" ] && MT_INSTALLED=1
fi
if [ -f "$MT_BIN" ]; then
    MT_INSTALLED=1
fi

if [ "$MT_INSTALLED" -eq 0 ]; then
    info "MagiTrickle is not installed - nothing to check (optional component; install.sh installs it when present)"
else
    if [ -n "$MT_VER" ]; then
        ok "MagiTrickle package installed (opkg version $MT_VER)"
    else
        warn "magitrickled binary present but the opkg database has no magitrickle package - partial install?"
    fi
    if [ -x "$MT_BIN" ]; then
        ok "MagiTrickle daemon binary is executable ($MT_BIN)"
    elif [ -f "$MT_BIN" ]; then
        warn "MagiTrickle daemon binary is not executable ($MT_BIN)"
    else
        warn "MagiTrickle daemon binary missing ($MT_BIN)"
    fi
    if [ -x "$MT_INIT" ]; then
        ok "MagiTrickle init script present ($MT_INIT)"
    else
        warn "MagiTrickle init script missing or not executable ($MT_INIT)"
    fi

    # Layer 1: process
    MT_PROCS=0
    MT_PID=""
    if command -v pidof >/dev/null 2>&1; then
        set -- $(pidof magitrickled 2>/dev/null)
        MT_PROCS=$#
        [ "$MT_PROCS" -gt 0 ] && MT_PID=$1
    else
        for _p in /proc/[0-9]*/cmdline; do
            _pid=${_p%/cmdline}; _pid=${_pid#/proc/}
            [ "$_pid" = "$$" ] && continue
            _a0=$(tr '\000' '\n' < "$_p" 2>/dev/null | head -n 1)
            [ "$(basename "$_a0" 2>/dev/null)" = "magitrickled" ] || continue
            MT_PROCS=$((MT_PROCS+1))
            [ -z "$MT_PID" ] && MT_PID=$_pid
        done
    fi
    if [ "$MT_PROCS" -gt 0 ]; then
        ok "magitrickled process is running ($MT_PROCS process(es))"
    else
        warn "magitrickled process is not running - MagiTrickle DNS classification is down (if you stopped it yourself, this is expected)"
    fi

    # PID file cross-check
    if [ -f "$MT_PIDFILE" ]; then
        MT_PIDFILE_PID=$(cat "$MT_PIDFILE" 2>/dev/null)
        case "$MT_PIDFILE_PID" in
            ''|*[!0-9]*)
                warn "MagiTrickle PID file is malformed ($MT_PIDFILE)"
                ;;
            *)
                if [ "$MT_PROCS" -gt 0 ] && [ -d "/proc/$MT_PIDFILE_PID" ]; then
                    ok "PID file is consistent (pid $MT_PIDFILE_PID)"
                elif [ "$MT_PROCS" -eq 0 ]; then
                    warn "PID file exists (pid $MT_PIDFILE_PID) but magitrickled is not running - stale"
                else
                    ok "PID file exists (pid $MT_PIDFILE_PID)"
                fi
                ;;
        esac
    else
        info "No MagiTrickle PID file ($MT_PIDFILE)"
    fi

    # Resource fact
    if [ -n "$MT_PID" ] && [ -r "/proc/$MT_PID/status" ]; then
        MT_RSS=$(awk '/^VmRSS:/ {print $2}' "/proc/$MT_PID/status" 2>/dev/null)
        if is_num "$MT_RSS"; then
            info "magitrickled RSS: $((MT_RSS/1024)) MB (resource fact only)"
        fi
    fi

    # Config (nested scalars; package defaults as fallback)
    MT_DNS_PORT=3553
    MT_WEB_PORT=8080
    MT_UPSTREAM_ADDR=127.0.0.1
    MT_UPSTREAM_PORT=53
    MT_CHAIN="MT_"
    MT_IPSET_PREFIX="mt_"
    MT_REMAP="false"
    MT_WEB_ENABLED="true"
    MT_LINK=""
    MT_CFG_SRC="package defaults"
    if [ -r "$MT_CFG" ]; then
        MT_CFG_SRC="$MT_CFG"
        _v=$(awk '/^  dnsProxy:/{f=1;next} /^  [^[:space:]#]/{f=0} f&&/^    port:/{print $2; exit}' "$MT_CFG")
        is_num "$_v" && MT_DNS_PORT=$_v
        _v=$(awk '/^  httpWeb:/{f=1;next} /^  [^[:space:]#]/{f=0} f&&/^    port:/{print $2; exit}' "$MT_CFG")
        is_num "$_v" && MT_WEB_PORT=$_v
        _v=$(awk '/^  httpWeb:/{f=1;next} /^  [^[:space:]#]/{f=0} f&&/^    enabled:/{print $2; exit}' "$MT_CFG")
        [ -n "$_v" ] && MT_WEB_ENABLED=$_v
        _v=$(awk '/^    upstream:/{f=1;next} /^    [^[:space:]#]/{f=0} f&&/^      address:/{print $2; exit}' "$MT_CFG")
        [ -n "$_v" ] && MT_UPSTREAM_ADDR=$(printf '%s' "$_v" | tr -d '"')
        _v=$(awk '/^    upstream:/{f=1;next} /^    [^[:space:]#]/{f=0} f&&/^      port:/{print $2; exit}' "$MT_CFG")
        is_num "$_v" && MT_UPSTREAM_PORT=$_v
        _v=$(awk '/^      chainPrefix:/{print $2; exit}' "$MT_CFG")
        [ -n "$_v" ] && MT_CHAIN=$(printf '%s' "$_v" | tr -d '"')
        _v=$(awk '/^        tablePrefix:/{print $2; exit}' "$MT_CFG")
        [ -n "$_v" ] && MT_IPSET_PREFIX=$(printf '%s' "$_v" | tr -d '"')
        _v=$(awk '/^      disableRemap53:/{print $2; exit}' "$MT_CFG")
        [ -n "$_v" ] && MT_REMAP=$_v
        MT_LINK=$(awk '/^  link:/{l=1;next} /^  [^[:space:]#]/{l=0} l&&/^[[:space:]]*-/{sub(/^[[:space:]]*-[[:space:]]*/,"");print}' "$MT_CFG" | tr '\n' ' ')
    fi
    info "MT config source: $MT_CFG_SRC"
    info "DNS proxy: port $MT_DNS_PORT -> upstream $MT_UPSTREAM_ADDR:$MT_UPSTREAM_PORT"
    info "Web UI: port $MT_WEB_PORT (enabled: $MT_WEB_ENABLED)"
    info "Link interfaces: ${MT_LINK:-<none>}; iptables chain prefix: $MT_CHAIN; ipset prefix: $MT_IPSET_PREFIX; remap53 disabled: $MT_REMAP"

        # Layer 2: listeners (only meaningful when the process runs)
        _dns_listening=0
        if [ "$MT_PROCS" -eq 0 ]; then
            info "magitrickled is not running - listener, function and netfilter checks are informational only"
        else
            port_listening "$MT_DNS_PORT"
            _tcp=$PL_RC
            udp_listening "$MT_DNS_PORT"
            _udp=$UL_RC
            if [ "$_tcp" = "0" ] || [ "$_udp" = "0" ]; then
                ok "DNS proxy port $MT_DNS_PORT is listening"
                _dns_listening=1
            elif [ "$_tcp" = "2" ] || [ "$_udp" = "2" ]; then
                info "Cannot verify the DNS listener (no netstat/ss and no /proc/net)"
            else
                warn "magitrickled is running but DNS proxy port $MT_DNS_PORT is not listening"
            fi

            # Layer 3: function (a real DNS query through the proxy);
            # skipped when the listener is down - a failing query on a
            # closed port would blame the wrong component
            if [ "$_dns_listening" -ne 1 ]; then
                info "Functional DNS check skipped: DNS port $MT_DNS_PORT is not listening"
            elif command -v dig >/dev/null 2>&1; then
                run_with_timeout 6 dig +time=2 +tries=1 +short @127.0.0.1 -p "$MT_DNS_PORT" example.com
                if [ "$RUN_RC" -eq 0 ] && [ -n "$RUN_OUT" ]; then
                    ok "Functional DNS query via 127.0.0.1:$MT_DNS_PORT works"
                else
                    fail "Functional DNS query via 127.0.0.1:$MT_DNS_PORT failed (process and listener are up, but no answer)"
                    port_listening 53
                    udp_listening 53
                    if [ "$PL_RC" -ne 0 ] && [ "$UL_RC" -ne 0 ]; then
                        info "MT upstream $MT_UPSTREAM_ADDR:53 is not listening - MagiTrickle has nowhere to forward queries; the failure is upstream-side, not the MagiTrickle process itself"
                    fi
                fi
            else
                info "Functional DNS check skipped: no dig available (busybox nslookup cannot target custom ports)"
            fi

        # netfilter facts (read-only; presence checks only)
        if [ "$MT_REMAP" = "true" ]; then
            info "disableRemap53=true - port 53 remap is intentionally off"
        elif command -v iptables >/dev/null 2>&1; then
            MT_REMAP_N=$(iptables -t nat -S 2>/dev/null | grep -c "DNAT.*:$MT_DNS_PORT\b") || MT_REMAP_N=0
            if [ "$MT_REMAP_N" -gt 0 ]; then
                ok "Port 53 remap rules found in nat (DNAT -> :$MT_DNS_PORT): $MT_REMAP_N"
            else
                warn "No port-53 remap rules found in nat - DNS interception is inactive (clients bypass MagiTrickle)"
            fi
        else
            info "iptables not available - remap rules not checked"
        fi
        if command -v ipset >/dev/null 2>&1; then
            MT_IPSET_N=$(ipset list -name 2>/dev/null | grep -c "^$MT_IPSET_PREFIX") || MT_IPSET_N=0
            info "ipset tables with prefix $MT_IPSET_PREFIX: $MT_IPSET_N"
        else
            info "ipset not available - ipset tables not checked"
        fi
    fi

    # Web UI / API liveness (HTTP code only, body is discarded)
    if [ "$MT_WEB_ENABLED" != "false" ] && [ "$MT_PROCS" -gt 0 ]; then
        port_listening "$MT_WEB_PORT"
        if [ "$PL_RC" -eq 0 ]; then
            MT_HTTP=""
            if command -v curl >/dev/null 2>&1; then
                MT_HTTP=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 5 "http://127.0.0.1:$MT_WEB_PORT/auth" 2>/dev/null) || MT_HTTP=""
            elif command -v wget >/dev/null 2>&1; then
                wget -q -T 5 -O /dev/null "http://127.0.0.1:$MT_WEB_PORT/auth" 2>/dev/null && MT_HTTP="200"
            fi
            case "$MT_HTTP" in
                ''|*[!0-9]*) info "Web API HTTP probe unavailable (no client or empty reply)" ;;
                200|401)     ok "Web API answers (HTTP $MT_HTTP; 401 is expected with auth enabled)" ;;
                *)           info "Web API answered HTTP $MT_HTTP" ;;
            esac
        else
            info "Web UI port $MT_WEB_PORT is not listening (web UI disabled or bound elsewhere)"
        fi
    fi

    # Relation to Mihomo - facts only; no causal claims are made
    info "Relation to Mihomo (facts only): mihomo processes: $MIHOMO_PROCS; mihomo version: ${BIN_VER:-unknown}; MT upstream: $MT_UPSTREAM_ADDR:$MT_UPSTREAM_PORT (Keenetic DNS)"
    MT_TUN_STACK=$(awk '/^tun:/{t=1;next} /^[^[:space:]#]/{t=0} t&&/^[[:space:]]*stack:/{print $2; exit}' "$CONFIG" 2>/dev/null)
    if [ -n "$MT_TUN_STACK" ]; then
        info "Mihomo tun.stack: $MT_TUN_STACK"
    fi
    if [ -d "/sys/class/net/mitun0" ]; then
        info "mitun0 interface is present"
    else
        info "mitun0 interface is not present"
    fi
    info "No causal link between Mihomo state (incl. TUN stack) and MagiTrickle state is claimed by this report."

    # Logs: MagiTrickle writes zerolog output to stdout, which is
    # lost at daemonization - there is no log file by default.
    MT_LOG_FOUND=0
    for _lf in "$OPT_ROOT/var/log/magitrickled.log" "$OPT_ROOT/var/log/magitrickle.log"; do
        if [ -f "$_lf" ]; then
            MT_LOG_FOUND=1
            MT_LOG_LINES=$(wc -l < "$_lf" 2>/dev/null)
            MT_LOG_ERRS=$(grep -ciE 'error|fatal' "$_lf" 2>/dev/null) || true
            is_num "$MT_LOG_LINES" || MT_LOG_LINES=0
            is_num "$MT_LOG_ERRS" || MT_LOG_ERRS=0
            info "MT log file: $_lf ($MT_LOG_LINES lines, $MT_LOG_ERRS error/fatal-class lines) - contents are never printed"
        fi
    done
    if [ "$MT_LOG_FOUND" -eq 0 ]; then
        info "MagiTrickle logs are not persisted to a file (zerolog writes to stdout, lost at daemonization) - nothing to analyze"
    fi
fi

# =========================================================
hdr "7. Keenetic proxy bridge (ProxyN)"
# =========================================================

if ! command -v ndmc >/dev/null 2>&1; then
    info "ndmc not available - Proxy bridge checks skipped (not a Keenetic shell?)"
else
    # One validated running-config snapshot for every decision below
    # (same semantics as install.sh: UNKNOWN is never treated as
    # NOT_FOUND, and nothing is ever modified here).
    _rc_att=0
    RC_DUMP=""
    while [ "$_rc_att" -lt 2 ]; do
        RC_DUMP=$(ndmc -c "show running-config" 2>/dev/null | tr -d '\r')
        if printf '%s\n' "$RC_DUMP" | grep -q '^interface '; then
            break
        fi
        _rc_att=$((_rc_att+1))
        [ "$_rc_att" -lt 2 ] && sleep 2
    done

    if ! printf '%s\n' "$RC_DUMP" | grep -q '^interface '; then
        warn "Cannot read/validate running-config - proxy state UNKNOWN, nothing is assumed (transient ndmc problem?)"
    else
        proxy_is_project() {
            printf '%s\n' "$RC_DUMP" | awk -v iface="$1" -v num="$2" '
                $0 == "interface " iface {pdesc=0; pup=0; inblk=1; next}
                inblk && /^!/ {if (pdesc && pup) found=1; inblk=0; next}
                inblk && $0 ~ "^ *description \"?mihomo t2s" num "\"? *$" {pdesc=1}
                inblk && /^ *proxy upstream 127\.0\.0\.1 7890 *$/ {pup=1}
                END {if (inblk && pdesc && pup) found=1; exit !found}
            '
        }

        PROJECT_PROXY=""
        FOREIGN_PROXIES=""
        _n=0
        while [ "$_n" -lt "$MAX_PROXY_PROBE" ]; do
            if printf '%s\n' "$RC_DUMP" | grep -qx "interface Proxy$_n"; then
                if proxy_is_project "Proxy$_n" "$_n"; then
                    if [ -z "$PROJECT_PROXY" ]; then
                        PROJECT_PROXY="Proxy$_n"
                        ok "Project proxy Proxy$_n: description \"mihomo t2s$_n\" -> upstream 127.0.0.1:$CONTRACT_PORT"
                    else
                        info "Second project proxy Proxy$_n present (install.sh uses the lowest-numbered one)"
                    fi
                else
                    FOREIGN_PROXIES="$FOREIGN_PROXIES Proxy$_n"
                fi
            fi
            _n=$((_n+1))
        done

        if [ -z "$PROJECT_PROXY" ]; then
            if [ -n "$FOREIGN_PROXIES" ]; then
                info "No project-managed ProxyN marker found; existing Proxy interface(s):$FOREIGN_PROXIES are left untouched and their upstream is not inferred"
            else
                fail "No Proxy interfaces found at all - Keenetic has no bridge into Mihomo (install.sh creates Proxy0 / first free ProxyN)"
            fi
        elif [ -n "$FOREIGN_PROXIES" ]; then
            info "Foreign Proxy interface(s) present:$FOREIGN_PROXIES - not project-managed, reported only"
        fi

        # bypass_wa is a user-owned failover policy. Its health contract is
        # intentionally weaker than the installer-owned ProxyN contract:
        # the policy must exist and contain at least one permitted interface.
        # Permit order and the selected interface(s) are user routing choices,
        # so the doctor must not require the project ProxyN to be first,
        # present, or exclusive.
        _pol_state=$(printf '%s\n' "$RC_DUMP" | awk '
            /^ip policy / {pdesc=0; ppermit=0; inblk=1; next}
            inblk && /^ *description bypass_wa *$/ {pdesc=1}
            inblk && /^ *permit global [A-Za-z0-9_-]+ *$/ {ppermit=1}
            /^!/ {if (inblk && pdesc) {if (ppermit) st="nonempty"; else st="empty"} inblk=0}
            END {if (inblk && pdesc) {if (ppermit) st="nonempty"; else st="empty"}; print st""}
        ')
        case "$_pol_state" in
            nonempty) ok "bypass_wa policy exists and has permitted interface(s); permit order is user-defined" ;;
            empty)    warn "bypass_wa policy exists but has no interface permit - failover policy has no exit route" ;;
            *)        warn "bypass_wa policy not found - expected failover policy is absent" ;;
        esac

        if printf '%s\n' "$RC_DUMP" | grep -q "intercept enable"; then
            DNS_INTERCEPT_RUNTIME=ok
            ok "DNS transit interception enabled (dns-proxy intercept enable)"
        else
            DNS_INTERCEPT_RUNTIME=missing
            if [ "$DOC_DNS_FILTER_COMPONENT" != "missing" ]; then
                warn "DNS transit interception not found - transit port-53 DNS bypasses Keenetic's resolver (install.sh enables it; MagiTrickle coverage may suffer)"
            fi
        fi
    fi
fi

case "$DOC_DNS_FILTER_COMPONENT:$DNS_INTERCEPT_RUNTIME" in
    missing:ok)
        warn "Supported-profile component missing: dns-filter; runtime DNS interception is currently active on this legacy installation"
        ;;
    missing:missing)
        fail "Supported-profile component missing and runtime DNS interception is not active: dns-filter"
        ;;
    missing:unknown)
        warn "Supported-profile component missing: dns-filter; runtime DNS-interception capability is unverified because running-config could not be validated"
        ;;
esac

# Runtime proof for the project VoIP bypass path. A policy/chain name alone is
# not sufficient: field A/B/C testing on KN-1010 / KeeneticOS 5.1.6 showed
# that removing opkg-kmod-netfilter after reboot leaves PREROUTING attached to
# an empty _CUST_BYPASS_WA_ chain because xt_multiport is unavailable.
_BYPASS_HOOK="$OPT_ROOT/etc/ndm/netfilter.d/020-bypass_wa.sh"
_bypass_component_hint=""
[ "$DOC_NETFILTER_COMPONENT" = "missing" ] && _bypass_component_hint="; show version does not report opkg-kmod-netfilter"
if [ ! -f "$_BYPASS_HOOK" ]; then
    fail "bypass_wa hook missing ($_BYPASS_HOOK)"
elif [ ! -x "$_BYPASS_HOOK" ]; then
    fail "bypass_wa hook is not executable ($_BYPASS_HOOK)"
else
    ok "bypass_wa hook present and executable"
fi

if ! command -v iptables >/dev/null 2>&1; then
    BYPASS_NETFILTER_RUNTIME=failed
    fail "bypass_wa Netfilter verification unavailable: iptables not found$_bypass_component_hint"
else
    _bypass_ports="1400,3478,3482"
    _bypass_pre=$(iptables -t mangle -S PREROUTING 2>/dev/null)
    _bypass_pre_rc=$?
    _bypass_chain=$(iptables -t mangle -S _CUST_BYPASS_WA_ 2>/dev/null)
    _bypass_chain_rc=$?

    if [ "$_bypass_chain_rc" -ne 0 ]; then
        BYPASS_NETFILTER_RUNTIME=failed
        fail "bypass_wa Netfilter chain missing: _CUST_BYPASS_WA_$_bypass_component_hint"
    else
        _bypass_missing=""
        if [ "$_bypass_pre_rc" -ne 0 ] || ! printf '%s\n' "$_bypass_pre" | grep -Fq -- "-j _CUST_BYPASS_WA_"; then
            _bypass_missing="$_bypass_missing PREROUTING-link"
        fi
        if ! printf '%s\n' "$_bypass_chain" | grep -F -- "-p udp -m multiport --dports $_bypass_ports -j MARK " >/dev/null 2>&1; then
            _bypass_missing="$_bypass_missing multiport-MARK"
        fi
        if ! printf '%s\n' "$_bypass_chain" | grep -F -- "-p udp -m multiport --dports $_bypass_ports -j CONNMARK " >/dev/null 2>&1; then
            _bypass_missing="$_bypass_missing multiport-CONNMARK"
        fi
        if ! printf '%s\n' "$_bypass_chain" | grep -Fq -- "-p udp -m multiport --dports $_bypass_ports -j RETURN"; then
            _bypass_missing="$_bypass_missing multiport-RETURN"
        fi

        if [ -z "$_bypass_missing" ]; then
            BYPASS_NETFILTER_RUNTIME=ok
            ok "bypass_wa Netfilter rules present (PREROUTING + UDP multiport MARK/CONNMARK/RETURN)"
        else
            BYPASS_NETFILTER_RUNTIME=failed
            fail "bypass_wa Netfilter rules incomplete: missing$_bypass_missing$_bypass_component_hint"
        fi
    fi
fi

case "$DOC_NETFILTER_COMPONENT:$BYPASS_NETFILTER_RUNTIME" in
    missing:ok)
        warn "Supported-profile component missing: opkg-kmod-netfilter; runtime bypass_wa Netfilter capability is currently verified on this legacy installation"
        ;;
    missing:unknown)
        warn "Supported-profile component missing: opkg-kmod-netfilter; runtime bypass_wa Netfilter capability is unverified"
        ;;
esac

# =========================================================
hdr "8. Watchdog"
# =========================================================

WD_CANON=0
if [ -f "$WATCHDOG_BIN" ] && grep -q "MIHOMO WATCHDOG SCRIPT" "$WATCHDOG_BIN" 2>/dev/null; then
    WD_CANON=1
    if [ -x "$WATCHDOG_BIN" ]; then
        ok "Canonical watchdog present ($WATCHDOG_BIN)"
    else
        warn "Canonical watchdog present but not executable ($WATCHDOG_BIN)"
    fi
fi

if [ -f "$WATCHDOG_CRON" ]; then
    if grep -q "^exec $WATCHDOG_BIN" "$WATCHDOG_CRON" 2>/dev/null; then
        ok "Cron wrapper points at the canonical watchdog ($WATCHDOG_CRON)"
    elif grep -q "MIHOMO WATCHDOG SCRIPT" "$WATCHDOG_CRON" 2>/dev/null; then
        warn "Legacy watchdog layout (full script in cron.5mins) - works, but update-watchdog.sh migrates it to the canonical layout"
    else
        warn "Unknown file at $WATCHDOG_CRON - not a project wrapper"
    fi
else
    if [ "$WD_CANON" -eq 1 ]; then
        warn "Canonical watchdog present but the cron wrapper is missing ($WATCHDOG_CRON) - nothing schedules it"
    else
        warn "Watchdog not installed (neither $WATCHDOG_BIN nor a legacy cron layout found) - self-healing absent; install.sh installs it"
    fi
fi

if grep -q "cron.5mins" "$CRONTAB_FILE" 2>/dev/null || grep -q "mihomo_watchdog" "$CRONTAB_FILE" 2>/dev/null; then
    ok "Watchdog scheduled in $CRONTAB_FILE"
else
    warn "Watchdog not scheduled in $CRONTAB_FILE (no cron.5mins/mihomo_watchdog entry)"
fi

# Historical updater generations stored the legacy full-script backup inside
# cron.5mins. If it retained its executable bit, BusyBox/run-parts can execute
# it as a second watchdog beside the canonical wrapper.
if [ -e "$WATCHDOG_LEGACY_BAK_OLD" ]; then
    if [ -x "$WATCHDOG_LEGACY_BAK_OLD" ]; then
        warn "Executable legacy watchdog backup remains inside cron.5mins ($WATCHDOG_LEGACY_BAK_OLD) - it may run as a second watchdog; run update-watchdog.sh to move/de-exec it"
    else
        info "Legacy watchdog backup remains inside cron.5mins but is non-executable ($WATCHDOG_LEGACY_BAK_OLD)"
    fi
fi

# Watchdog log content is analyzed in section 8b only: raw log
# lines are never printed anywhere in this doctor.
if [ -f /tmp/mihomo_watchdog.restart ]; then
    info "Restart state file present - the watchdog has restarted Mihomo at least once (last epoch: $(cat /tmp/mihomo_watchdog.restart 2>/dev/null))"
fi

# =========================================================
hdr "8b. Watchdog history (read-only log analysis)"
# =========================================================
# Ground truth from mihomo-watchdog.sh: every log line is
#   "%Y-%m-%d %H:%M:%S <message>" appended to the log. Healthy checks run
# every 5 minutes but the routine success heartbeat is intentionally
# throttled to at most once every 20 minutes:
#   "[OK] All good | WAN=primary (<target>)"
#   "[OK] All good | WAN=whitelist (<target>)"
# Problems/restarts are always logged immediately. A problem resets the
# heartbeat throttle so the next healthy run is recorded at once, preserving
# the recovery marker. Older logs may also contain "[WAN] Connectivity OK"
# and "[WAN] Primary targets unavailable..." lines; they remain parseable.
# [RESTART] is written BEFORE the restart; recovery is confirmed by a later
# "[OK] All good..." entry. Since 2026-09 the watchdog also writes
# "[RESTART-OK]"/"[RESTART-FAIL]" and a fresh-log "[INIT]" marker.
# Analysis prints categories, counts and timestamps only - never
# raw log lines.

WD_STAB="OK"
WD_STAB_WHY=""
if [ ! -e "$WATCHDOG_LOG" ]; then
    if [ "$WD_CANON" -eq 1 ] || [ -f "$WATCHDOG_CRON" ]; then
        warn "Watchdog log not found ($WATCHDOG_LOG) - the watchdog has not run/logged yet, or the tmpfs log was lost on reboot"
    else
        info "Watchdog log not found ($WATCHDOG_LOG) - nothing to analyze (watchdog is not installed)"
    fi
elif [ ! -r "$WATCHDOG_LOG" ]; then
    warn "Watchdog log exists but is not readable ($WATCHDOG_LOG)"
else
    WD_STATS=$(tr -d '\r' < "$WATCHDOG_LOG" | awk '
        {
            total++
            if (length($0) > 20 && $1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ && $2 ~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/) {
                ts = $1 " " $2
                msg = substr($0, 21)
            } else { bad++; next }
            if (first == "") first = ts
            last = ts
            if (msg ~ /^\[OK\]/) {
                ok++; lastok = ts
                if (msg ~ /WAN=whitelist/) wanwl++
            }
            else if (msg ~ /^\[RESTART\]/) {
                restart++
                lastprob = ts; lastprobk = "restart"
                if (msg ~ /Mihomo port unreachable/) r_port++
                else if (msg ~ /Proxy tunnel check failed/) r_tunnel++
                else r_other++
                pb[substr(ts, 1, 13)]++
                pe[pen++] = "restart " ts
            }
            else if (msg ~ /^\[RATE-LIMIT\]/) {
                ratelimit++
                lastprob = ts; lastprobk = "rate-limited"
                if (msg ~ /Mihomo port unreachable/) l_port++
                else if (msg ~ /Proxy tunnel check failed/) l_tunnel++
                else l_other++
                pb[substr(ts, 1, 13)]++
                pe[pen++] = "rate-limited " ts
            }
            else if (msg ~ /^\[WARN\] WAN unreachable/) wanout++
            else if (msg ~ /^\[WAN\] Primary targets unavailable/) wanwl++
            else if (msg ~ /^\[RESTART-OK\]/) { rok++; lastrOK = ts }
            else if (msg ~ /^\[RESTART-FAIL\]/) { rfail++; lastrFAIL = ts }
            else if (msg ~ /^\[INIT\]/) init++
        }
        END {
            print "total=" total + 0
            print "bad=" bad + 0
            print "first=" first
            print "last=" last
            print "ok=" ok + 0
            print "lastok=" lastok
            print "restart=" restart + 0
            print "r_port=" r_port + 0
            print "r_tunnel=" r_tunnel + 0
            print "r_other=" r_other + 0
            print "ratelimit=" ratelimit + 0
            print "l_port=" l_port + 0
            print "l_tunnel=" l_tunnel + 0
            print "l_other=" l_other + 0
            print "wanout=" wanout + 0
            print "wanwl=" wanwl + 0
            print "rok=" rok + 0
            print "rfail=" rfail + 0
            print "init=" init + 0
            print "lastrOK=" lastrOK
            print "lastrFAIL=" lastrFAIL
            print "lastprob=" lastprob
            print "lastprobk=" lastprobk
            print "pen=" pen + 0
            max = 0; mk = ""
            for (k in pb) if (pb[k] > max) { max = pb[k]; mk = k }
            print "seriesmax=" max + 0
            print "serieskey=" mk
            for (i = 0; i < pen && i < 100; i++) print "pevent=" pe[i]
        }
    ')

    WD_TOTAL=0; WD_BAD=0; WD_OK=0; WD_RESTART=0; WD_RL=0
    WD_R_PORT=0; WD_R_TUNNEL=0; WD_R_OTHER=0
    WD_L_PORT=0; WD_L_TUNNEL=0; WD_L_OTHER=0
    WD_WANOUT=0; WD_WANWL=0; WD_PEN=0; WD_SERIESMAX=0
    WD_FIRST=""; WD_LAST=""; WD_LASTOK=""
    WD_LASTPROB=""; WD_LASTPROBK=""; WD_SERIESKEY=""; WD_PEVENTS=""
    WD_ROK=0; WD_RFAIL=0; WD_INIT=0; WD_LASTROK=""; WD_LASTRFAIL=""
    WD_RECOVERY_CONFIRMED=0

    while IFS= read -r _line; do
        _k=${_line%%=*}
        _v=${_line#*=}
        case "$_k" in
            total)      WD_TOTAL=$_v ;;
            bad)        WD_BAD=$_v ;;
            first)      WD_FIRST=$_v ;;
            last)       WD_LAST=$_v ;;
            ok)         WD_OK=$_v ;;
            lastok)     WD_LASTOK=$_v ;;
            restart)    WD_RESTART=$_v ;;
            r_port)     WD_R_PORT=$_v ;;
            r_tunnel)   WD_R_TUNNEL=$_v ;;
            r_other)    WD_R_OTHER=$_v ;;
            ratelimit)  WD_RL=$_v ;;
            l_port)     WD_L_PORT=$_v ;;
            l_tunnel)   WD_L_TUNNEL=$_v ;;
            l_other)    WD_L_OTHER=$_v ;;
            wanout)     WD_WANOUT=$_v ;;
            wanwl)      WD_WANWL=$_v ;;
            lastprob)   WD_LASTPROB=$_v ;;
            lastprobk)  WD_LASTPROBK=$_v ;;
            pen)        WD_PEN=$_v ;;
            seriesmax)  WD_SERIESMAX=$_v ;;
            serieskey)  WD_SERIESKEY=$_v ;;
            pevent)     WD_PEVENTS="$WD_PEVENTS $_v" ;;
            rok)        WD_ROK=$_v ;;
            rfail)      WD_RFAIL=$_v ;;
            init)       WD_INIT=$_v ;;
            lastrOK)    WD_LASTROK=$_v ;;
            lastrFAIL)  WD_LASTRFAIL=$_v ;;
        esac
    done <<_WDEOF
$WD_STATS
_WDEOF

    # Normalize counters (awk output is numeric by construction; the
    # guard only protects against a future format drift).
    for _n in WD_TOTAL WD_BAD WD_OK WD_RESTART WD_R_PORT WD_R_TUNNEL \
              WD_R_OTHER WD_RL WD_L_PORT WD_L_TUNNEL WD_L_OTHER \
              WD_WANOUT WD_WANWL WD_PEN WD_SERIESMAX; do
        eval "_v=\$$_n"
        case "$_v" in
            ''|*[!0-9]*) eval "$_n=0" ;;
        esac
    done

    if [ "$WD_TOTAL" -eq 0 ]; then
        warn "Watchdog log is empty - the watchdog has not logged anything yet (tmpfs log is lost on reboot)"
    else
        if [ "$WD_BAD" -gt 0 ]; then
            info "$WD_BAD of $WD_TOTAL line(s) did not match the expected '<timestamp> <message>' format and were skipped"
        fi
        if [ -n "$WD_FIRST" ] && [ -n "$WD_LAST" ]; then
            info "Available history: $WD_FIRST -> $WD_LAST (rotation keeps ~300-500 lines; tmpfs: lost on reboot)"
        fi
        if [ "$WD_INIT" -gt 0 ]; then
            info "Log generation marker ([INIT]) on record: $WD_INIT - the visible history starts at a fresh generation (boot or first run), not at an arbitrary rotation point"
        fi

        if [ -n "$WD_LAST" ]; then
            _now=$(date +%s)
            _last_e=$(date -d "$WD_LAST" +%s 2>/dev/null)
            case "$_last_e" in ''|*[!0-9]*) _last_e="" ;; esac
            if [ -z "$_last_e" ]; then
                info "Last entry: $WD_LAST (age cannot be determined)"
            else
                _age=$((_now - _last_e))
                if [ "$_age" -lt 0 ]; then
                    info "Last entry: $WD_LAST (timestamp is in the future - clock skew between log and this run?)"
                elif [ "$_age" -gt 1800 ]; then
                    warn "Log last updated $((_age / 60)) min ago (checks run every 5 min; healthy heartbeats are rate-limited to 20 min) - the watchdog may not be running or logging is broken"
                    info "Recommendation: if the log keeps aging, check cron scheduling and the watchdog installation (sections 8, cron)"
                else
                    info "Last entry: $WD_LAST ($((_age / 60)) min ago)"
                fi
            fi
        fi
        info "Healthy heartbeats ([OK] All good) on record: $WD_OK"

        if [ "$WD_RESTART" -eq 0 ] && [ "$WD_RL" -eq 0 ]; then
            ok "No restarts or problem detections in the available history"
        else
            info "Problem events on record: $WD_RESTART restart(s), $WD_RL rate-limited run(s) (problem detected, restart suppressed by cooldown)"
            if [ $((WD_R_PORT + WD_L_PORT)) -gt 0 ]; then
                info "Category 'Mihomo port unreachable': $((WD_R_PORT + WD_L_PORT)) event(s)"
            fi
            if [ $((WD_R_TUNNEL + WD_L_TUNNEL)) -gt 0 ]; then
                info "Category 'Proxy tunnel check failed': $((WD_R_TUNNEL + WD_L_TUNNEL)) event(s)"
            fi
            if [ $((WD_R_OTHER + WD_L_OTHER)) -gt 0 ]; then
                info "Events with an unrecognized reason string: $((WD_R_OTHER + WD_L_OTHER))"
            fi
            if [ -n "$WD_LASTPROB" ]; then
                info "Last problem event: $WD_LASTPROB ($WD_LASTPROBK)"
            fi
            if [ "$WD_ROK" -gt 0 ]; then
                _msg="Same-run restart verification ([RESTART-OK]) on record: $WD_ROK"
                [ -n "$WD_LASTROK" ] && _msg="$_msg, last at $WD_LASTROK"
                info "$_msg"
            fi
            if [ "$WD_RFAIL" -gt 0 ]; then
                warn "Restart outcome failures ([RESTART-FAIL]) on record: $WD_RFAIL - a restart did not bring the process up$([ -n "$WD_LASTRFAIL" ] && printf ', last at %s' "$WD_LASTRFAIL")"
                WD_STAB="WARN"; WD_STAB_WHY="restart outcome failure on record"
            fi

            if [ -n "$WD_LASTOK" ]; then
                _e_ok=$(date -d "$WD_LASTOK" +%s 2>/dev/null)
                _e_prob=$(date -d "$WD_LASTPROB" +%s 2>/dev/null)
                case "$_e_ok" in ''|*[!0-9]*) _e_ok="" ;; esac
                case "$_e_prob" in ''|*[!0-9]*) _e_prob="" ;; esac
                if [ -n "$_e_ok" ] && [ -n "$_e_prob" ]; then
                    if [ "$_e_ok" -gt "$_e_prob" ]; then
                        info "Last healthy check after the last problem: $WD_LASTOK - recovered as of that check"
                        WD_RECOVERY_CONFIRMED=1
                    else
                        warn "No healthy check recorded after the last problem event ($WD_LASTPROB)"
                        WD_STAB="WARN"; WD_STAB_WHY="no confirmed recovery after the last problem"
                    fi
                else
                    info "Cannot compare the last healthy check and the last problem (unparseable timestamps)"
                fi
            else
                warn "No '[OK] All good' entry found at all - no confirmed healthy run in the available history"
                WD_STAB="WARN"; WD_STAB_WHY="no confirmed healthy run on record"
            fi

            if [ "$WD_SERIESMAX" -ge 3 ]; then
                warn "Repeated failures: $WD_SERIESMAX problem events within the same clock hour ($WD_SERIESKEY:00)"
                WD_STAB="WARN"; WD_STAB_WHY="repeated problem events within one hour"
            fi
        fi

        # Recent interventions: last 24h from this run's clock. Severity is
        # intentionally calm: one ordinary restart with confirmed recovery is
        # INFO. Repeated interventions (2+) or any rate-limited problem are WARN.
        WD_RECENT=0; WD_RECENT_RESTART=0; WD_RECENT_RL=0; WD_RECENT_UNKNOWN=0
        _now=$(date +%s)
        set -- $WD_PEVENTS
        while [ $# -ge 3 ]; do
            _etype=$1
            _ts="$2 $3"; shift 3
            _e=$(date -d "$_ts" +%s 2>/dev/null)
            case "$_e" in ''|*[!0-9]*)
                WD_RECENT_UNKNOWN=$((WD_RECENT_UNKNOWN + 1))
                continue
                ;;
            esac
            if [ $((_now - _e)) -ge 0 ] && [ $((_now - _e)) -lt 86400 ]; then
                WD_RECENT=$((WD_RECENT + 1))
                case "$_etype" in
                    restart)      WD_RECENT_RESTART=$((WD_RECENT_RESTART + 1)) ;;
                    rate-limited) WD_RECENT_RL=$((WD_RECENT_RL + 1)) ;;
                esac
            fi
        done
        if [ "$WD_RECENT_RL" -gt 0 ]; then
            warn "Watchdog interventions in the last 24h: $WD_RECENT problem event(s), including $WD_RECENT_RL rate-limited detection(s) during restart cooldown"
            WD_STAB="WARN"; WD_STAB_WHY="rate-limited watchdog problem detection in the last 24h"
        elif [ "$WD_RECENT" -ge "$WATCHDOG_RECENT_WARN_THRESHOLD" ]; then
            warn "Watchdog interventions in the last 24h: $WD_RECENT problem event(s) - repeated recent interventions exceed the project INFO threshold of one"
            WD_STAB="WARN"; WD_STAB_WHY="repeated watchdog interventions in the last 24h"
        elif [ "$WD_RECENT" -eq 1 ]; then
            if [ "$WD_RECOVERY_CONFIRMED" -eq 1 ]; then
                info "Watchdog interventions in the last 24h: 1 isolated restart, followed by a healthy check - informational only"
            else
                info "Watchdog interventions in the last 24h: 1 isolated restart - count alone is informational; recovery state is evaluated separately above"
            fi
        elif [ "$WD_PEN" -gt 0 ] && [ "$WD_RECENT_UNKNOWN" -eq "$WD_PEN" ]; then
            info "Problem events exist in history but their age cannot be determined (unparseable timestamps)"
        elif [ "$WD_PEN" -gt 0 ]; then
            ok "No watchdog interventions in the last 24h (older events on record: $WD_PEN)"
        fi

        # WAN problems are deliberately separated from Mihomo problems
        if [ "$WD_WANOUT" -gt 0 ]; then
            info "WAN full-outage runs on record: $WD_WANOUT (the watchdog deliberately does NOT restart Mihomo when WAN is down)"
        fi
        if [ "$WD_WANWL" -gt 0 ]; then
            info "Whitelist-fallback heartbeats/events on record: $WD_WANWL - a sign of a restricted network, not of a Mihomo fault"
        fi

        # Verdict: current process state is not enough on its own
        if [ "$WD_STAB" = "WARN" ]; then
            if [ "$MIHOMO_PROCS" -gt 0 ]; then
                warn "Historical stability: WARN - Mihomo is running now, but there was $WD_STAB_WHY; the current running state does not by itself prove stability"
            else
                warn "Historical stability: WARN - $WD_STAB_WHY (and the service is currently stopped)"
            fi
        else
            if [ "$WD_RECENT" -eq 1 ] && [ "$WD_RECOVERY_CONFIRMED" -eq 1 ]; then
                ok "Historical stability: OK - one isolated watchdog restart in the last 24h was followed by a healthy check; no repeated/rate-limited pattern is present"
            elif [ "$WD_PEN" -gt 0 ]; then
                ok "Historical stability: OK - no warning-level recent intervention pattern (older or isolated events may be on record; service currently $( [ "$MIHOMO_PROCS" -gt 0 ] && echo running || echo stopped))"
            else
                ok "Historical stability: OK - no watchdog interventions on record (service currently $( [ "$MIHOMO_PROCS" -gt 0 ] && echo running || echo stopped))"
            fi
        fi

        # Recommendations: facts above, interpretation here, never a root cause
        if [ $((WD_R_TUNNEL + WD_L_TUNNEL)) -gt 0 ] && [ $((WD_R_TUNNEL + WD_L_TUNNEL)) -ge $((WD_R_PORT + WD_L_PORT)) ]; then
            info "Recommendation: repeated 'Proxy tunnel check failed' events can have several causes (upstream server availability, DPI filtering, WAN quality) - the log does not identify which one; check the config/runtime separately"
        fi
        if [ $((WD_R_PORT + WD_L_PORT)) -gt 0 ] && [ $((WD_R_PORT + WD_L_PORT)) -gt $((WD_R_TUNNEL + WD_L_TUNNEL)) ]; then
            info "Recommendation: 'Mihomo port unreachable' means the watchdog found port $CONTRACT_PORT closed - the log does not show why (process exit, missing port in config, startup failure); compare with sections 3-6 above"
        fi
    fi
fi

# =========================================================
hdr "9. Network"
# =========================================================

if command -v nslookup >/dev/null 2>&1; then
    if nslookup github.com >/dev/null 2>&1; then
        ok "DNS resolution works (github.com)"
    else
        warn "DNS resolution FAILED (github.com) - network-level problem, separate from any local Mihomo state"
    fi
else
    info "nslookup unavailable - DNS check skipped"
fi

fetch_url "https://api.github.com/repos/$ENTWARE_REPO/releases/tags/latest"
if [ "$FETCH_RC" -ne 0 ] || [ -z "$FETCH_OUT" ]; then
    fetch_url "https://api.github.com/repos/$ENTWARE_REPO/releases/latest"
fi
if [ "$FETCH_RC" -eq 127 ]; then
    warn "No curl/wget - GitHub checks skipped (installs and updates would fail)"
    NET_GITHUB=0
elif [ -n "$FETCH_OUT" ]; then
    if printf '%s\n' "$FETCH_OUT" | grep -q '"API rate limit'; then
        warn "GitHub API rate-limited (unauthenticated limit) - package availability check skipped, try again later"
        NET_GITHUB=0
    else
        ok "GitHub API reachable - $ENTWARE_REPO release fetched"
        RELEASE_JSON=$FETCH_OUT
    fi
else
    warn "GitHub unreachable - install.sh and update-mihomo.sh cannot fetch packages (a running Mihomo keeps working)"
    NET_GITHUB=0
fi

fetch_url "$PROJECT_RAW_BASE/README.md"
if [ "$FETCH_RC" -eq 127 ]; then
    info "raw.githubusercontent.com check skipped (no curl/wget)"
elif [ -n "$FETCH_OUT" ]; then
    ok "raw.githubusercontent.com reachable (script delivery path for install.sh/update-watchdog.sh)"
else
    warn "raw.githubusercontent.com unreachable - curl|sh delivery of install.sh and updaters would fail"
fi

# =========================================================
hdr "10. entware-go package availability"
# =========================================================

if [ "$NET_GITHUB" -eq 0 ]; then
    info "Package availability check skipped (GitHub fetch failed above)"
elif [ -z "$IPK_SUFFIX" ]; then
    info "Package availability check skipped (architecture unknown)"
else
    FOUND_NAME=""
    if command -v jq >/dev/null 2>&1; then
        FOUND_NAME=$(printf '%s\n' "$RELEASE_JSON" | jq -r --arg suffix "$IPK_SUFFIX" '
            .assets[]?
            | select(.name | startswith("mihomo_") and endswith("_" + $suffix + ".ipk") and (contains("nohf") | not))
            | .name
        ' 2>/dev/null | head -n 1)
    fi
    if [ -z "$FOUND_NAME" ] || [ "$FOUND_NAME" = "null" ]; then
        FOUND_URL=$(printf '%s\n' "$RELEASE_JSON" \
            | grep -o '"browser_download_url": *"[^"]*mihomo_[^"]*_'${IPK_SUFFIX}'\.ipk"' \
            | grep -v "nohf" \
            | head -n 1 | sed 's/.*": *"//;s/"$//')
        [ -n "$FOUND_URL" ] && FOUND_NAME=$(basename "$FOUND_URL")
    fi

    case "$FOUND_NAME" in
        mihomo_*_${IPK_SUFFIX}.ipk) : ;;
        *) FOUND_NAME="" ;;
    esac
    case "$FOUND_NAME" in
        *nohf*) FOUND_NAME="" ;;
    esac

    if [ -n "$FOUND_NAME" ]; then
        ok "Package for $IPK_SUFFIX available in $ENTWARE_REPO:latest - $FOUND_NAME"
        AVAIL_VER=${FOUND_NAME#mihomo_}
        AVAIL_VER=${AVAIL_VER%_${IPK_SUFFIX}.ipk}
        case "$AVAIL_VER" in
            *-*)
                _rel=${AVAIL_VER##*-}
                case "$_rel" in
                    ''|*[!0-9]*) AVAIL_VER="" ;;
                    *) AVAIL_VER=${AVAIL_VER%-"$_rel"} ;;
                esac
                ;;
            *) AVAIL_VER="" ;;
        esac
        if [ -n "$BIN_VER" ] && [ -n "$AVAIL_VER" ]; then
            _cmp=$(ver_compare "$AVAIL_VER" "$BIN_VER")
            case "$_cmp" in
                gt) info "Update available on entware-go:latest: $BIN_VER -> $AVAIL_VER" ;;
                eq) info "Installed version matches entware-go:latest ($BIN_VER)" ;;
                lt) info "Available version ($AVAIL_VER) is older than installed ($BIN_VER) - update-mihomo.sh will skip (no automatic downgrade)" ;;
                *)  info "Versions cannot be reliably ordered ($AVAIL_VER vs $BIN_VER) - update-mihomo.sh will skip (downgrade protection)" ;;
            esac
        else
            info "Installed version unknown - availability comparison skipped"
        fi
    else
        NOHF_ONLY=$(printf '%s\n' "$RELEASE_JSON" | grep -o '"name": *"mihomo_nohf_[^"]*_'${IPK_SUFFIX}'\.ipk"' | head -n 1)
        warn "No mihomo package for suffix $IPK_SUFFIX in $ENTWARE_REPO:latest - the GitHub install/update path fails for this arch (install.sh Entware-feed fallback may still install an older version)"
        if [ -n "$NOHF_ONLY" ]; then
            info "Only a nohf variant exists for this suffix - it is deliberately never selected (softfloat build)"
        fi
    fi
fi

# =========================================================
# Summary
# =========================================================
echo
info "Doctor is read-only: no files, services or settings were changed."
print_human_result
echo
echo "=== Mihomo Doctor Summary ==="
printf 'OK:   %d\n' "$N_OK"
printf 'WARN: %d\n' "$N_WARN"
printf 'FAIL: %d\n' "$N_FAIL"
printf 'INFO: %d\n' "$N_INFO"
echo
if [ "$N_FAIL" -gt 0 ]; then
    echo "Overall status: FAIL"
    exit 2
elif [ "$N_WARN" -gt 0 ]; then
    echo "Overall status: WARN"
    exit 1
else
    echo "Overall status: OK"
    exit 0
fi
