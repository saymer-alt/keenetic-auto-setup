#!/bin/sh
# FI-WD — mihomo-watchdog.sh restart safety under fault injection.
#
# Faults injected: stale cooldown + repeated cron runs (loop safety),
# corrupted state files, unverified init digest, missing curl tool, curl
# timeout, busy maintenance marker, busy legacy lifecycle lock.
#
# Every case checks a clear oracle: exit code + state files + absence of
# unwanted side effects (restart counts, init invocations, probe budgets).
#
# Environment: WSL2 Ubuntu Linux, dash / BusyBox ash. LOCAL_MOCK.
# FIELD and EMULATOR are NOT_TESTED by design (no router access).

QA_SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$QA_SELF_DIR/lib.sh"
set -u

# KAS_QA_MUTANT: path to a mutated verbatim copy (mutation runner only).
WATCHDOG_SRC=${KAS_QA_MUTANT:-$QA_REPO_ROOT/mihomo-watchdog.sh}
[ -f "$WATCHDOG_SRC" ] || { echo "BLOCKED fi-wd: mihomo-watchdog.sh not found"; exit 2; }

qa_new_lab || { echo "BLOCKED fi-wd: cannot create lab"; exit 2; }
qa_min_bins || { echo "BLOCKED fi-wd: cannot build minimal bins"; exit 2; }
qa_wd_init_paths "$WATCHDOG_SRC"
qa_wd_stage || { echo "BLOCKED fi-wd: cannot stage watchdog lab"; exit 2; }

SHELL_NAMES=${KAS_QA_SHELLS:-dash,busybox}
NOW=$(date +%s)

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

init_calls() {
    _n=$(grep -c 'call:' "$QA_LAB/init-calls.log" 2>/dev/null)
    _n=${_n:-0}
    printf '%s\n' "$_n"
}

# ---------------------------------------------------------------------------
# FI-WD-1: restart rate limiting across repeated cron-style runs
# ---------------------------------------------------------------------------
cb_fi_1() {
    _name=$1
    _spec=$(shell_spec "$_name")
    qa_wd_reset_state
    # Stale cooldown from a run long ago -> first failure may restart.
    printf '%s\n' $((NOW - 400)) > "$QA_LAB/tmp/mihomo_watchdog.restart"
    _out=$(qa_wd_run "$_spec" up down ok 2>&1)
    _rc=$?
    qa_check_rc "$_name run1: watchdog exits 0" "$_rc"
    qa_check_eq "$_name run1: exactly one [RESTART] fired" \
        "$(qa_read_log | grep -cF '[RESTART] Mihomo port unreachable')" "1"
    qa_check_present "$_name run1: restart verified via new process identity" \
        "$(qa_read_log | grep -cF '[RESTART-VERIFIED] New Mihomo process identity observed')"
    qa_check_eq "$_name run1: fixture init restart invoked once" "$(init_calls)" "1"
    # Two immediate re-runs must be rate-limited: NO further restarts.
    _n=2
    while [ "$_n" -le 3 ]; do
        _out=$(qa_wd_run "$_spec" up down ok 2>&1)
        _rc=$?
        qa_check_rc "$_name run$_n: watchdog exits 0" "$_rc"
        qa_check_present "$_name run$_n: [RATE-LIMIT] blocks the restart" \
            "$(qa_read_log | grep -cF '[RATE-LIMIT] [RESTART-SKIPPED] Restart blocked')"
        _n=$((_n + 1))
    done
    _total=$(qa_read_log | grep -cF '[RESTART] Mihomo port unreachable')
    qa_check_eq "$_name: total restarts across 3 runs == 1 (no restart loop)" "$_total" "1"
    _calls=$(init_calls)
    qa_check_eq "$_name: fixture init invoked exactly once in total" "$_calls" "1"
    _conf=$(qa_wd_incident_field port_failure 2)
    qa_check_eq "$_name: port_failure confirmed counter == 3" "$_conf" "3"
    _diag=$(qa_read_log | grep -cF '[DIAG-TRIGGER] port_failure')
    qa_check_eq "$_name: L2 port diagnostics fired at most once (cooldown)" "$_diag" "1"
    [ -f "$QA_LAB/tmp/mihomo_watchdog.healthy" ] && \
        qa_fail "$_name: HEALTHY_STATE must stay absent while the port is down"
    qa_diag "$_name: restart loop safety holds under repeated cron runs"
}

case_fi_1() {
    qa_case "FI-WD-1/restart-rate-limit-no-loop" || return 0
    for_each_shell cb_fi_1 || return 1
    qa_pass
}

# ---------------------------------------------------------------------------
# FI-WD-2: corrupted state files must never wedge or crash the watchdog
# ---------------------------------------------------------------------------
cb_fi_2() {
    _name=$1
    _spec=$(shell_spec "$_name")
    qa_wd_reset_state
    # (a) garbage RESTART_STATE: numeric validation treats it as expired and
    # rewrites a numeric cooldown during the restart.
    printf 'garbage!!\n' > "$QA_LAB/tmp/mihomo_watchdog.restart"
    _out=$(qa_wd_run "$_spec" up down ok 2>&1)
    _rc=$?
    qa_check_rc "$_name (a): watchdog exits 0 on corrupted cooldown" "$_rc"
    qa_check_present "$_name (a): restart still fires exactly once" \
        "$(qa_read_log | grep -cF '[RESTART] Mihomo port unreachable')"
    _rs=$(cat "$QA_LAB/tmp/mihomo_watchdog.restart" 2>/dev/null)
    case "$_rs" in
        ''|*[!0-9]*) qa_fail "$_name (a): cooldown must be rewritten numeric, got '$_rs'" ;;
        *) : ;;
    esac
    # (b) garbage HEALTHY_STATE: heartbeat still repaired on the healthy path.
    qa_wd_reset_state
    printf 'junk\n' > "$QA_LAB/tmp/mihomo_watchdog.healthy"
    _out=$(qa_wd_run "$_spec" up up ok 2>&1)
    _rc=$?
    qa_check_rc "$_name (b): watchdog exits 0 on corrupted healthy state" "$_rc"
    _hb=$(cat "$QA_LAB/tmp/mihomo_watchdog.healthy" 2>/dev/null)
    case "$_hb" in
        *" primary") : ;;
        *) qa_fail "$_name (b): healthy heartbeat not repaired, got '$_hb'" ;;
    esac
    # (c) corrupted incident ledger: invalid lines skipped, counters default,
    # the file is repaired on the next save.
    qa_wd_reset_state
    {
        printf 'wan_failure X Y\n'
        printf 'bogus_class 1 1 1 1 1 1 1 1 1 1 1\n'
        printf 'proxy_tunnel_failure 5 1 1 1 1 1 1 1 1\n'
        printf 'port_failure 7 2 1 123 123 123 0 0 0 -\n'
    } > "$QA_LAB/tmp/mihomo_watchdog.incidents"
    _out=$(qa_wd_run "$_spec" up down ok 2>&1)
    _rc=$?
    qa_check_rc "$_name (c): watchdog exits 0 on corrupted incident ledger" "$_rc"
    _lines=$(grep -c . "$QA_LAB/tmp/mihomo_watchdog.incidents")
    qa_check_eq "$_name (c): ledger rewritten with exactly 3 class lines" "$_lines" "3"
    _conf=$(qa_wd_incident_field port_failure 2)
    qa_check_eq "$_name (c): preserved port_failure counter incremented" "$_conf" "8"
    _wan=$(qa_wd_incident_field wan_failure 2)
    qa_check_eq "$_name (c): invalid wan line dropped, counter defaulted" "$_wan" "0"
    qa_diag "$_name: corruption fail-closed contract holds"
}

case_fi_2() {
    qa_case "FI-WD-2/corrupted-state-files" || return 0
    for_each_shell cb_fi_2 || return 1
    qa_pass
}

# ---------------------------------------------------------------------------
# FI-WD-3: unverified init digest -> fail-closed, cooldown NOT consumed
# ---------------------------------------------------------------------------
cb_fi_3() {
    _name=$1
    _spec=$(shell_spec "$_name")
    qa_wd_reset_state
    printf '%s\n' $((NOW - 400)) > "$QA_LAB/tmp/mihomo_watchdog.restart"
    # Tamper with the init fixture: its digest no longer matches the pinned one.
    printf '# tampered\n' >> "$QA_LAB/opt/etc/init.d/S99mihomo"
    _out=$(qa_wd_run "$_spec" up down ok 2>&1)
    _rc=$?
    qa_check_rc "$_name: watchdog exits 0" "$_rc"
    qa_check_present "$_name: unverified init reported" \
        "$(qa_read_log | grep -cF '[RESTART-SKIPPED] Mihomo init unverified:')"
    _total=$(qa_read_log | grep -cF '[RESTART]')
    qa_check_eq "$_name: NO restart with an unverified init" "$_total" "0"
    _rs=$(cat "$QA_LAB/tmp/mihomo_watchdog.restart")
    qa_check_eq "$_name: cooldown NOT consumed on the skip path" "$_rs" "$((NOW - 400))"
    _calls=$(init_calls)
    qa_check_eq "$_name: unverified init never executed" "$_calls" "0"
    # Restore the fixture for the following cases.
    sed -i '/^# tampered$/d' "$QA_LAB/opt/etc/init.d/S99mihomo"
    qa_diag "$_name: init digest guard holds"
}

case_fi_3() {
    qa_case "FI-WD-3/unverified-init-digest-skip" || return 0
    for_each_shell cb_fi_3 || return 1
    qa_pass
}

# ---------------------------------------------------------------------------
# FI-WD-4: missing curl tool / curl timeout -> fail-closed WAN path
# ---------------------------------------------------------------------------
cb_fi_4() {
    _name=$1
    _spec=$(shell_spec "$_name")
    # (a) curl missing from PATH entirely.
    qa_wd_reset_state
    rm -f "$QA_LAB/shim/curl"
    _out=$(qa_wd_run "$_spec" up up ok 2>&1)
    _rc=$?
    qa_check_rc "$_name (a): watchdog exits 0 without curl" "$_rc"
    qa_check_present "$_name (a): WAN declared unreachable (probes fail rc=127)" \
        "$(qa_read_log | grep -cF '[WARN] WAN unreachable (primary + whitelist targets failed)')"
    _total=$(qa_read_log | grep -cF '[RESTART]')
    qa_check_eq "$_name (a): NO restart without probe tooling" "$_total" "0"
    [ -f "$QA_LAB/curl.log" ] && qa_fail "$_name (a): no curl shim present, yet curl.log exists"
    [ -f "$QA_LAB/tmp/mihomo_watchdog.healthy" ] && \
        qa_fail "$_name (a): HEALTHY_STATE must be absent when WAN is unprovable"
    qa_wd_write_curl_shim
    # (b) curl hard timeout (rc=28) on every direct target.
    qa_wd_reset_state
    _out=$(qa_wd_run "$_spec" rc28 up ok 2>&1)
    _rc=$?
    qa_check_rc "$_name (b): watchdog exits 0 on probe timeouts" "$_rc"
    qa_check_present "$_name (b): timeout evidence recorded in the FAIL line" \
        "$(qa_read_log | grep -cF '[FAIL] wan confirmed | cycles=1 | curl_rc=28')"
    _total=$(qa_read_log | grep -cF '[RESTART]')
    qa_check_eq "$_name (b): NO restart on WAN timeouts" "$_total" "0"
    qa_diag "$_name: missing/timeout probe tooling stays fail-closed"
}

case_fi_4() {
    qa_case "FI-WD-4/missing-curl-and-timeout" || return 0
    for_each_shell cb_fi_4 || return 1
    qa_pass
}

# ---------------------------------------------------------------------------
# FI-WD-5: busy maintenance marker / busy legacy lifecycle lock
# ---------------------------------------------------------------------------
cb_fi_5() {
    _name=$1
    _spec=$(shell_spec "$_name")
    # (a) maintenance marker owned by a live process (pid 1 is alive).
    qa_wd_reset_state
    printf '1 busy\n' > "$QA_LAB/tmp/mihomo.maintenance"
    _out=$(qa_wd_run "$_spec" up down ok 2>&1)
    _rc=$?
    qa_check_rc "$_name (a): watchdog exits 0" "$_rc"
    qa_check_present "$_name (a): maintenance skip logged" \
        "$(qa_read_log | grep -cF '[SKIP] maintenance in progress - checks skipped')"
    _total=$(qa_read_log | grep -cF '[RESTART]')
    qa_check_eq "$_name (a): zero restarts during maintenance" "$_total" "0"
    [ -f "$QA_LAB/curl.log" ] && qa_fail "$_name (a): zero probes expected during maintenance skip"
    [ -f "$QA_LAB/tmp/mihomo.maintenance" ] || \
        qa_fail "$_name (a): watchdog must not remove a foreign maintenance marker"
    rm -f "$QA_LAB/tmp/mihomo.maintenance"
    # (b) legacy tool lock present -> lifecycle acquire refuses the restart.
    qa_wd_reset_state
    printf '%s\n' $((NOW - 400)) > "$QA_LAB/tmp/mihomo_watchdog.restart"
    printf 'legacy-owner\n' > "$QA_LAB/tmp/mihomo-update.lock"
    _out=$(qa_wd_run "$_spec" up down ok 2>&1)
    _rc=$?
    qa_check_rc "$_name (b): watchdog exits 0" "$_rc"
    qa_check_present "$_name (b): lifecycle-busy skip logged" \
        "$(qa_read_log | grep -cF '[RESTART-SKIPPED] Mihomo lifecycle busy or unverifiable')"
    _total=$(qa_read_log | grep -cF '[RESTART]')
    qa_check_eq "$_name (b): NO restart while a legacy lock exists" "$_total" "0"
    _rs=$(cat "$QA_LAB/tmp/mihomo_watchdog.restart")
    qa_check_eq "$_name (b): cooldown NOT consumed on the busy path" "$_rs" "$((NOW - 400))"
    _calls=$(init_calls)
    qa_check_eq "$_name (b): init never invoked while busy" "$_calls" "0"
    [ -f "$QA_LAB/tmp/mihomo-update.lock" ] || \
        qa_fail "$_name (b): watchdog must not remove foreign legacy locks"
    rm -f "$QA_LAB/tmp/mihomo-update.lock"
    qa_diag "$_name: busy-gate fail-closed contract holds"
}

case_fi_5() {
    qa_case "FI-WD-5/busy-marker-and-lifecycle" || return 0
    for_each_shell cb_fi_5 || return 1
    qa_pass
}

# ---------------------------------------------------------------------------
case_fi_1
case_fi_2
case_fi_3
case_fi_4
case_fi_5

echo "ALL-PASS fi-watchdog-restarts"
exit 0
