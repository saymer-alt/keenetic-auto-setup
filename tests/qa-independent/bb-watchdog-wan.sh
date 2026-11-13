#!/bin/sh
# BB-WD — mihomo-watchdog.sh WAN handling, cron-style single invocations.
#
# Black-box oracle over the FULL production script (verbatim, path-remapped,
# init digest pinned to the lab fixture). No network, no router, no Mihomo
# install: curl/pidof/sleep are PATH shims, the init script is a fixture.
#
# Observable properties:
# - WAN down (all primary + whitelist direct targets fail): exit 0, NO
#   restart in any run, HEALTHY_STATE absent, incident ledger counts
#   confirmed wan_failure cycles, no SOCKS probes on the WAN-down path;
# - all checks pass: [OK] All good, HEALTHY_STATE heartbeat written;
# - transient tunnel failure (retry succeeds): no restart, transient
#   counter only.
#
# Environment: WSL2 Ubuntu Linux, dash / BusyBox ash. LOCAL_MOCK.
# FIELD and EMULATOR are NOT_TESTED by design (no router access).

QA_SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$QA_SELF_DIR/lib.sh"
set -u

# KAS_QA_MUTANT: path to a mutated verbatim copy (mutation runner only).
WATCHDOG_SRC=${KAS_QA_MUTANT:-$QA_REPO_ROOT/mihomo-watchdog.sh}
[ -f "$WATCHDOG_SRC" ] || { echo "BLOCKED bb-wd: mihomo-watchdog.sh not found"; exit 2; }

qa_new_lab || { echo "BLOCKED bb-wd: cannot create lab"; exit 2; }
qa_min_bins || { echo "BLOCKED bb-wd: cannot build minimal bins"; exit 2; }

SHELL_NAMES=${KAS_QA_SHELLS:-dash,busybox}
LOGFILE=$QA_LAB/opt/var/log/mihomo_watchdog.log

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
qa_wd_write_curl_shim() {
    # Classifies production probe shapes and answers from the scenario plan.
    # Every invocation is logged (class + rc) for probe-budget assertions.
    qa_write_shim curl <<'EOF'
#!/bin/sh
_kas_log="${KASLAB:?}/curl.log"
_rc=0
_class=other
for _a in "$@"; do
    case "$_a" in
        socks5h://*) _class=tunnel ;;
        http://127.0.0.1:7890) _class=port ;;
        --head) _class=wan ;;
    esac
done
case "$_class" in
    wan)
        # First --head argument after the flag is the target.
        _prev=""
        _t=""
        for _a in "$@"; do
            [ "$_prev" = "--head" ] && _t=$_a
            _prev=$_a
        done
        case "$_t" in
            http://cp.cloudflare.com|http://www.google.com) _grp=primary ;;
            *) _grp=whitelist ;;
        esac
        case "${KAS_WAN:-up}" in
            up)                     _rc=0 ;;
            down)                   _rc=7 ;;
            primary-down-whitelist-up) [ "$_grp" = primary ] && _rc=7 || _rc=0 ;;
            rc28)                   _rc=28 ;;
            *)                      _rc=7 ;;
        esac
        ;;
    port)  case "${KAS_PORT:-up}" in up) _rc=0 ;; down) _rc=7 ;; *) _rc=7 ;; esac ;;
    tunnel)
        case "${KAS_TUNNEL:-ok}" in
            ok)       _rc=0 ;;
            fail)     _rc=7 ;;
            transient)
                _n=$(cat "$KASLAB/tunnel.count" 2>/dev/null || echo 0)
                _n=$((_n + 1))
                echo "$_n" > "$KASLAB/tunnel.count"
                [ "$_n" -eq 1 ] && _rc=7 || _rc=0
                ;;
            *)        _rc=7 ;;
        esac
        ;;
    other) _rc=0 ;;
esac
printf '%s %s\n' "$_class" "$_rc" >> "$_kas_log"
exit "$_rc"
EOF
}

qa_wd_write_sleep_shim() {
    qa_write_shim sleep <<'EOF'
#!/bin/sh
exit 0
EOF
}

qa_wd_write_pidof_shim() {
    qa_write_shim pidof <<'EOF'
#!/bin/sh
if [ -f "${KASLAB:?}/mihomo.pid" ]; then
    cat "$KASLAB/mihomo.pid"
    exit 0
fi
exit 1
EOF
}

qa_wd_write_fixture_init() {
    # Pinned package-init + rc.func dispatch; restart behavior in impl.
    _digest=$(qa_write_pinned_init "$QA_LAB/opt/etc/init.d/S99mihomo") || return 1
    printf '%s\n' "$_digest"
    cat > "$QA_LAB/opt/etc/init.d/fixture-impl.sh" <<'EOF'
#!/bin/sh
_pidfile="${KASLAB:?}/mihomo.pid"
echo "call:$1" >> "${KASLAB:?}/init-calls.log"
case "$1" in
    start|restart)
        if [ -f "$_pidfile" ]; then
            kill "$(cat "$_pidfile")" 2>/dev/null
            rm -f "$_pidfile"
        fi
        if [ -f "${KASLAB:?}/restart-fail" ]; then
            echo "start failed" >&2
            exit 1
        fi
        if [ -f "${KASLAB:?}/no-daemon" ]; then
            # Init returns success WITHOUT a daemon (async-start contract).
            echo started
            exit 0
        fi
        "${KASLAB:?}/opt/bin/mihomo" -c 'while :; do sleep 1; done' &
        echo $! > "$_pidfile"
        echo started
        exit 0
        ;;
    stop)
        if [ -f "$_pidfile" ]; then
            kill "$(cat "$_pidfile")" 2>/dev/null
            rm -f "$_pidfile"
        fi
        exit 0
        ;;
esac
exit 0
EOF
    chmod 0755 "$QA_LAB/opt/etc/init.d/fixture-impl.sh" || return 1
}

qa_wd_stage() {
    qa_stage_production "$WATCHDOG_SRC" "$QA_LAB/watchdog.sh" || return 1
    _digest=$(qa_wd_write_fixture_init) || return 1
    qa_pin_digest "$QA_LAB/watchdog.sh" "$_digest" || return 1
    qa_wd_write_curl_shim || return 1
    qa_wd_write_sleep_shim || return 1
    qa_wd_write_pidof_shim || return 1
    return 0
}

qa_wd_run() {
    # One cron-style watchdog invocation.
    # $1 = shell spec, $2 = wan plan, $3 = port plan, $4 = tunnel plan
    _spec=$1
    _wan=$2
    _port=$3
    _tun=$4
    _old_ifs=$IFS
    IFS='|'
    # shellcheck disable=SC2086
    set -- $_spec
    IFS=$_old_ifs
    _cmd=$1
    shift
    KASLAB="$QA_LAB" PATH="$(qa_harness_path)" \
        KAS_WAN="$_wan" KAS_PORT="$_port" KAS_TUNNEL="$_tun" \
        "$_cmd" "$@" "$QA_LAB/watchdog.sh"
}

wd_reset_state() {
    # Clean per-invocation state between shell runs (lab scripts persist).
    rm -f "$LOGFILE" "$QA_LAB/curl.log" "$QA_LAB/tunnel.count" \
          "$QA_LAB/mihomo.pid" "$QA_LAB/init-calls.log" \
          "$QA_LAB"/tmp/mihomo_watchdog.restart \
          "$QA_LAB"/tmp/mihomo_watchdog.healthy \
          "$QA_LAB"/tmp/mihomo_watchdog.incidents 2>/dev/null
    rm -rf "$QA_LAB/tmp/mihomo_watchdog.lock.d" \
           "$QA_LAB/tmp/mihomo-lifecycle.lock.d" 2>/dev/null
    return 0
}

wd_incident_field() {
    # wd_incident_field <class> <field-index 2..11>
    awk -v c="$1" -v f="$2" '$1 == c { print $f }' "$QA_LAB/tmp/mihomo_watchdog.incidents" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

# --- BB-WD-1: WAN down across three consecutive runs ------------------------
cb_wd_1() {
    _name=$1
    _spec=$(shell_spec "$_name")
    wd_reset_state
    _n=1
    while [ "$_n" -le 3 ]; do
        _out=$(qa_wd_run "$_spec" down up ok 2>&1)
        _rc=$?
        qa_check_rc "$_name run$_n: watchdog exits 0 (cron tool must not fail)" "$_rc"
        _restarts=$(qa_read_log | grep -cF '[RESTART]' || true)
        qa_check_eq "$_name run$_n: zero restarts while WAN is down" "$_restarts" "0"
        if [ "$_n" -eq 1 ]; then
            qa_check_present "$_name run1: [WARN] WAN unreachable logged" \
                "$(qa_read_log | grep -cF '[WARN] WAN unreachable (primary + whitelist targets failed)')"
            qa_check_present "$_name run1: [FAIL] wan confirmed evidence line" \
                "$(qa_read_log | grep -cF '[FAIL] wan confirmed | cycles=1')"
        fi
        [ -f "$QA_LAB/tmp/mihomo_watchdog.healthy" ] && \
            qa_fail "$_name run$_n: HEALTHY_STATE must be absent after WAN failure"
        _conf=$(wd_incident_field wan_failure 2)
        qa_check_eq "$_name run$_n: wan_failure confirmed counter == $_n" "$_conf" "$_n"
        _tun=$(grep -c '^tunnel ' "$QA_LAB/curl.log" 2>/dev/null); _tun=${_tun:-0}
        qa_check_eq "$_name run$_n: no SOCKS probes on the WAN-down path" "$_tun" "0"
        qa_diag "$_name run$_n: no-restart-under-WAN-failure holds"
        _n=$((_n + 1))
    done
    # Third run must also stay inside the restart-free state and keep the
    # diagnostics gated (L2 fired at most once so far, cooldown honored).
    _diag=$(qa_read_log | grep -cF '[DIAG-TRIGGER] wan_failure' || true)
    qa_check_eq "$_name: L2 wan diagnostics triggered at most once in 3 runs" "$_diag" "1"
    _all=$(qa_read_log | grep -cF '[RESTART]' || true)
    qa_check_eq "$_name: total restarts across 3 runs == 0" "$_all" "0"
}

case_bb_wd_1() {
    qa_case "BB-WD-1/watchdog-wan-down-no-restart" || return 0
    qa_wd_stage || qa_fail "cannot stage watchdog lab"
    for_each_shell cb_wd_1 || return 1
    qa_pass
}

# --- BB-WD-2: WAN up, port up, tunnel ok -> healthy --------------------------
cb_wd_2() {
    _name=$1
    _spec=$(shell_spec "$_name")
    wd_reset_state
    _out=$(qa_wd_run "$_spec" up up ok 2>&1)
    _rc=$?
    qa_check_rc "$_name: watchdog exits 0" "$_rc"
    qa_check_present "$_name: [OK] All good logged with primary WAN path" \
        "$(qa_read_log | grep -cF '[OK] All good | WAN=primary (http://cp.cloudflare.com)')"
    _restarts=$(qa_read_log | grep -cF '[RESTART]' || true)
    qa_check_eq "$_name: zero restarts on healthy path" "$_restarts" "0"
    [ -f "$QA_LAB/tmp/mihomo_watchdog.healthy" ] || \
        qa_fail "$_name: HEALTHY_STATE heartbeat must exist after healthy run"
    _hb=$(cat "$QA_LAB/tmp/mihomo_watchdog.healthy")
    case "$_hb" in
        *" primary") : ;;
        *) qa_fail "$_name: HEALTHY_STATE must record '<epoch> primary', got '$_hb'" ;;
    esac
    _probes=$(grep -c . "$QA_LAB/curl.log" 2>/dev/null); _probes=${_probes:-0}
    qa_check_eq "$_name: exactly 3 probes on the healthy path (wan+port+tunnel)" "$_probes" "3"
    qa_diag "$_name: healthy path records heartbeat"
}

case_bb_wd_2() {
    qa_case "BB-WD-2/watchdog-all-good-heartbeat" || return 0
    qa_wd_stage || qa_fail "cannot stage watchdog lab"
    for_each_shell cb_wd_2 || return 1
    qa_pass
}

# --- BB-WD-3: tunnel transient (first probe fails, retry succeeds) -----------
cb_wd_3() {
    _name=$1
    _spec=$(shell_spec "$_name")
    wd_reset_state
    _out=$(qa_wd_run "$_spec" up up transient 2>&1)
    _rc=$?
    qa_check_rc "$_name: watchdog exits 0" "$_rc"
    qa_check_present "$_name: transient retry info logged" \
        "$(qa_read_log | grep -cF '[INFO] Proxy tunnel first probe failed; retry succeeded - no restart')"
    _restarts=$(qa_read_log | grep -cF '[RESTART]' || true)
    qa_check_eq "$_name: transient failure never restarts" "$_restarts" "0"
    _conf=$(wd_incident_field proxy_tunnel_failure 2)
    qa_check_eq "$_name: no confirmed tunnel cycle" "$_conf" "0"
    _trans=$(wd_incident_field proxy_tunnel_failure 8)
    qa_check_eq "$_name: transient counter recorded once" "$_trans" "1"
    _tun=$(grep -c '^tunnel ' "$QA_LAB/curl.log" 2>/dev/null); _tun=${_tun:-0}
    qa_check_eq "$_name: exactly two tunnel probes (confirming retry)" "$_tun" "2"
    _hb=$(cat "$QA_LAB/tmp/mihomo_watchdog.healthy" 2>/dev/null)
    case "$_hb" in
        *" primary") : ;;
        *) qa_fail "$_name: healthy heartbeat must be written after transient recovery, got '$_hb'" ;;
    esac
    qa_diag "$_name: confirming-retry contract holds"
}

case_bb_wd_3() {
    qa_case "BB-WD-3/watchdog-tunnel-transient" || return 0
    qa_wd_stage || qa_fail "cannot stage watchdog lab"
    for_each_shell cb_wd_3 || return 1
    qa_pass
}

# ---------------------------------------------------------------------------
shell_spec() {
    case "$1" in
        dash)    printf '/usr/bin/dash' ;;
        busybox) printf '/usr/bin/busybox|ash' ;;
        bash)    printf '/usr/bin/bash' ;;
        *)       printf '%s' "$1" ;;
    esac
}

for_each_shell() {
    _cb=$1
    _s=$SHELL_NAMES
    while [ -n "$_s" ]; do
        _name=${_s%%,*}
        [ "$_name" = "$_s" ] && _s="" || _s=${_s#*,}
        "$_cb" "$_name" || return 1
    done
}

# ---------------------------------------------------------------------------

# BB-WD-1 runs 3 invocations per shell; isolate state per shell by re-staging
# between shells is unnecessary: counters grow monotonically 1..3 per shell.
case_bb_wd_1
case_bb_wd_2
case_bb_wd_3

echo "ALL-PASS bb-watchdog-wan"
exit 0
