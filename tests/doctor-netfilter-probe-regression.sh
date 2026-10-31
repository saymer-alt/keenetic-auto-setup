#!/bin/sh
# Focused Doctor regression for the section-7 Netfilter read probe (issue #310
# review of PR #312): PREROUTING and _CUST_BYPASS_WA_ must be read together as
# one read-only pair, so a transient failure of one read (e.g. a busy xtables
# lock) cannot fail the whole section after the other read recovered.
# Persistent read failure stays FAIL and is classified (busy vs unknown);
# a definitively absent chain is not retried.
#
# The real production block is extracted from mihomo-doctor.sh between its
# BEGIN/END DOCTOR BYPASS NETFILTER PROBE v1 markers and executed with a
# mocked iptables only. No router, firewall, policy or table is touched.
set -eu

ROOT=${1:-.}
DOCTOR="$ROOT/mihomo-doctor.sh"
TMP="${TMPDIR:-/tmp}/keenetic-doctor-probe.$$"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP"

fail_test() { echo "[FAIL] $1" >&2; exit 1; }
pass() { echo "[OK] $1"; }

awk '
    /# BEGIN DOCTOR BYPASS NETFILTER PROBE v1/ {copy=1}
    copy {print}
    /# END DOCTOR BYPASS NETFILTER PROBE v1/ {exit}
' "$DOCTOR" > "$TMP/probe.sh"

[ -s "$TMP/probe.sh" ] || fail_test "could not extract the Doctor Netfilter probe block"
grep -q '_bypass_max_attempts' "$TMP/probe.sh" ||
    fail_test "extracted block is missing the bounded retry"
sh -n "$TMP/probe.sh" || fail_test "extracted probe block is not valid shell"

MOCK_PRE='-P PREROUTING ACCEPT
-A PREROUTING -m mark --mark 0x0 -j _CUST_BYPASS_WA_'
MOCK_CHAIN='-N _CUST_BYPASS_WA_
-A _CUST_BYPASS_WA_ -p udp -m multiport --dports 1400,3478,3482 -j MARK --set-xmark 0xffffaab/0xffffffff
-A _CUST_BYPASS_WA_ -p udp -m multiport --dports 1400,3478,3482 -j CONNMARK --save-mark --nfmask 0xffffffff --ctmask 0xffffffff
-A _CUST_BYPASS_WA_ -p udp -m multiport --dports 1400,3478,3482 -j RETURN'
BUSY_ERR="iptables: Resource temporarily unavailable."
ABSENT_ERR="iptables: No chain/target/match by that name."

PRE_BUSY_FLAG="$TMP/pre-busy-once"
MOCK_PRE_BUSY_MODE=never
MOCK_CHAIN_MODE=ok

iptables() {
    [ "$1" = "-t" ] && [ "$2" = "mangle" ] && [ "$3" = "-S" ] || return 70
    case "$4" in
        PREROUTING)
            # Counters cannot be used here: the production probe reads chains
            # via command substitution, so a mock counter would increment in
            # a child shell and never reach the test. A consumed flag file
            # models "busy on the first read(s)" from the parent filesystem.
            case "$MOCK_PRE_BUSY_MODE" in
                always)
                    printf '%s\n' "$BUSY_ERR" >&2
                    return 1
                    ;;
                once)
                    if [ -f "$PRE_BUSY_FLAG" ]; then
                        rm -f "$PRE_BUSY_FLAG"
                        printf '%s\n' "$BUSY_ERR" >&2
                        return 1
                    fi
                    ;;
            esac
            printf '%s\n' "$MOCK_PRE"
            ;;
        _CUST_BYPASS_WA_)
            case "$MOCK_CHAIN_MODE" in
                absent)
                    printf '%s\n' "$ABSENT_ERR" >&2
                    return 1
                    ;;
                busy)
                    printf '%s\n' "$BUSY_ERR" >&2
                    return 1
                    ;;
            esac
            printf '%s\n' "$MOCK_CHAIN"
            ;;
        *)
            return 71
            ;;
    esac
}

# run_case <label> <pre_busy_mode> <chain_mode> <want_fail_re> <want_sleeps>
# Asserts the expectations for one probe scenario.
run_case() {
    _label=$1
    _pre_busy_mode=$2
    _chain_mode=$3
    _want_fail_re=$4
    _want_sleeps=$5
    _out=$(
        set +e
        N_OK=0
        N_FAIL=0
        SLEEPS=0
        LAST_FAIL=""
        ok()   { N_OK=$((N_OK + 1)); }
        fail() { N_FAIL=$((N_FAIL + 1)); LAST_FAIL="$1"; }
        sleep() { SLEEPS=$((SLEEPS + 1)); }
        _bypass_component_hint=""
        MOCK_PRE_BUSY_MODE=$_pre_busy_mode
        MOCK_CHAIN_MODE=$_chain_mode
        rm -f "$PRE_BUSY_FLAG"
        [ "$_pre_busy_mode" = once ] && : > "$PRE_BUSY_FLAG"
        . "$TMP/probe.sh"
        printf 'RESULT %s %s %s' "$N_FAIL" "$SLEEPS" "$LAST_FAIL"
    )
    _fails=$(printf '%s\n' "$_out" | awk '{print $2}')
    _sleeps=$(printf '%s\n' "$_out" | awk '{print $3}')
    _msg=$(printf '%s\n' "$_out" | cut -d' ' -f4-)
    if [ "$_want_fail_re" = "-" ]; then
        [ "$_fails" -eq 0 ] || fail_test "$_label: expected success, got $_fails failure(s): $_msg"
    else
        [ "$_fails" -ge 1 ] || fail_test "$_label: expected a failure, got none"
        printf '%s\n' "$_msg" | grep -Eq "$_want_fail_re" ||
            fail_test "$_label: failure message does not match '$_want_fail_re': $_msg"
    fi
    [ "$_sleeps" -eq "$_want_sleeps" ] ||
        fail_test "$_label: expected $_want_sleeps sleep(s), got $_sleeps"
    echo "[OK] $_label"
}

# 1) Happy path: both reads succeed on the first round, no retry.
run_case "both chains readable on the first round" never ok "-" 0

# 2) THE REVIEW CASE: the first PREROUTING read is transiently busy while the
#    chain read recovered. The pair must be re-probed together and the section
#    must end OK. (RED on main: PREROUTING was read once, before the retry
#    loop, and failed the section as a missing link.)
run_case "transient PREROUTING read failure recovers with the pair re-probe" once ok "-" 1

# 3) Persistent PREROUTING busy stays a FAIL and is classified as busy —
#    not reported as a missing PREROUTING link.
run_case "persistent PREROUTING busy is a classified FAIL" always ok "PREROUTING unreadable.*busy" 2

# 4) A definitively absent chain is not retried even when PREROUTING read is
#    transiently busy: the first round already has a definitive answer.
run_case "absent chain answers definitively without retries" once absent "chain absent" 0

# 5) Persistent chain busy keeps the existing classified chain failure.
run_case "persistent chain busy keeps the classified chain failure" never busy "chain unreadable.*busy" 2

pass "Doctor Netfilter pair-probe regression passed"
