#!/bin/sh
# Runtime regression for installer bypass verification. The real installer
# function is sourced with a mocked hook path and read-only command fixtures.
# No router services, policies, packets or tables are changed.
set -eu

ROOT=${1:-.}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kas-netfilter-live.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
MOCK_HOOK="$WORK/hook"
printf '#!/bin/sh\n' > "$MOCK_HOOK"
chmod 755 "$MOCK_HOOK"

sed -n '/^check_bypass_netfilter_runtime() {/,/^}/p' "$ROOT/install.sh" |
    sed 's@_br_hook=/opt/etc/ndm/netfilter.d/020-bypass_wa.sh@_br_hook="$MOCK_HOOK"@' > "$WORK/function.sh"
[ -s "$WORK/function.sh" ] || { echo "[FAIL] could not extract live Netfilter installer check"; exit 1; }
sh -n "$WORK/function.sh" || exit 1
. "$WORK/function.sh"

MOCK_MARK=ffffaab
MOCK_API_FAIL=0
MOCK_CHAIN_FAIL=0
MOCK_CHAIN_DELAY=0
MOCK_PRE_FAIL=0
MOCK_CHAIN_ERR=""

iptables() {
    [ "$1" = "-t" ] && [ "$2" = "mangle" ] && [ "$3" = "-S" ] || return 72
    case "$4" in
        _CUST_BYPASS_WA_)
            if [ "$MOCK_CHAIN_FAIL" -ne 0 ]; then
                [ -z "$MOCK_CHAIN_ERR" ] || printf '%s
' "$MOCK_CHAIN_ERR" >&2
                return 1
            fi
            if [ "$MOCK_CHAIN_DELAY" -gt 0 ]; then
                _mock_round=$(cat "$WORK/chain-attempts" 2>/dev/null || printf 0)
                _mock_round=$((_mock_round + 1))
                printf '%s\n' "$_mock_round" > "$WORK/chain-attempts"
                [ "$_mock_round" -gt "$MOCK_CHAIN_DELAY" ] || return 1
            fi
            printf '%s\n' "$MOCK_CHAIN"
            ;;
        PREROUTING)
            [ "$MOCK_PRE_FAIL" -eq 0 ] || return 2
            printf '%s\n' "$MOCK_PRE"
            ;;
        *) return 71 ;;
    esac
}
curl() {
    [ "$MOCK_API_FAIL" -eq 0 ] || return 1
    printf '%s\n' '[{"description":"bypass_wa","mark":"ffffaab"}]'
}
jq() {
    [ "$MOCK_API_FAIL" -eq 0 ] || return 1
    printf '%s\n' "$MOCK_MARK"
}
RESULT_INFO=0
LAST_INFO=""
LAST_FAIL=""
check_ok() { RESULT_OK=$((RESULT_OK+1)); }
check_info() { RESULT_INFO=$((RESULT_INFO+1)); LAST_INFO="$1"; }
check_fail() { RESULT_FAIL=$((RESULT_FAIL+1)); LAST_FAIL="$1"; }
# Production retries are bounded, but mock tests must not sleep 14 seconds
# for each deliberately missing/incomplete Netfilter snapshot, nor wait 14s
# per expected-failure fixture: test retry counts, not wall time.
sleep() { :; }

MOCK_PRE='-P PREROUTING ACCEPT
-A PREROUTING -m mark --mark 0x0 -j _CUST_BYPASS_WA_'
MOCK_CHAIN='-N _CUST_BYPASS_WA_
-A _CUST_BYPASS_WA_ -p udp -m multiport --dports 1400,3478,3482 -j MARK --set-xmark 0xffffaab/0xffffffff
-A _CUST_BYPASS_WA_ -p udp -m multiport --dports 1400,3478,3482 -j CONNMARK --save-mark --nfmask 0xffffffff --ctmask 0xffffffff
-A _CUST_BYPASS_WA_ -p udp -m multiport --dports 1400,3478,3482 -j RETURN'
ORIGINAL_CHAIN="$MOCK_CHAIN"
ORIGINAL_PRE="$MOCK_PRE"

run_case() {
    label="$1"
    expectation="$2"
    RESULT_OK=0
    RESULT_FAIL=0
    check_bypass_netfilter_runtime
    if [ "$expectation" = pass ]; then
        [ "$RESULT_FAIL" -eq 0 ] && [ "$RESULT_OK" -eq 2 ] || {
            echo "[FAIL] $label: expected PASS, got OK=$RESULT_OK FAIL=$RESULT_FAIL"
            exit 1
        }
    else
        [ "$RESULT_FAIL" -ge 1 ] || {
            echo "[FAIL] $label: false PASS"
            exit 1
        }
    fi
    echo "[OK] $label ($expectation)"
}

run_case "real NC-1812 serialized --set-xmark and full CONNMARK mask" pass
MOCK_CHAIN_DELAY=2
: > "$WORK/chain-attempts"
run_case "transient empty Netfilter chain recovers after two snapshot failures" pass
[ "$(cat "$WORK/chain-attempts")" -eq 3 ] ||
    { echo "[FAIL] Netfilter retry count expected 3"; exit 1; }
MOCK_CHAIN_DELAY=0
MOCK_CHAIN=$(printf '%s\n' "$ORIGINAL_CHAIN" | sed 's@--set-xmark 0xffffaab/0xffffffff@--set-mark 0xffffaab@;s@ --nfmask 0xffffffff --ctmask 0xffffffff@@')
run_case "legacy canonical --set-mark and CONNMARK defaults" pass
MOCK_CHAIN="$ORIGINAL_CHAIN"

MOCK_MARK=abcd123
run_case "wrong actual Keenetic policy mark" fail
MOCK_MARK=ffffaab

MOCK_CHAIN=$(printf '%s\n' "$ORIGINAL_CHAIN" | sed 's@0xffffaab/0xffffffff@0xffffaab/0x0000ffff@')
run_case "partial masked MARK (not full policy mark)" fail
MOCK_CHAIN="$ORIGINAL_CHAIN"

MOCK_CHAIN=$(printf '%s\n' "$ORIGINAL_CHAIN" | sed 's@--nfmask 0xffffffff@--nfmask 0x0000ffff@')
run_case "partial masked CONNMARK" fail
MOCK_CHAIN="$ORIGINAL_CHAIN"

MOCK_CHAIN=$(printf '%s\n' "$ORIGINAL_CHAIN" | grep -v ' -j RETURN')
run_case "missing RETURN" fail
MOCK_CHAIN="$ORIGINAL_CHAIN"

MOCK_CHAIN=$(printf '%s\n' "$ORIGINAL_CHAIN" | awk '
    / -j MARK / {saved=$0; next}
    / -j CONNMARK / {print; print saved; next}
    {print}
')
run_case "wrong MARK and CONNMARK order" fail
MOCK_CHAIN="$ORIGINAL_CHAIN"

MOCK_CHAIN=$(printf '%s\n%s\n' "$ORIGINAL_CHAIN" '-A _CUST_BYPASS_WA_ -p udp -j ACCEPT')
run_case "unexpected extra bypass chain action" fail
MOCK_CHAIN="$ORIGINAL_CHAIN"

MOCK_PRE='-P PREROUTING ACCEPT'
run_case "no PREROUTING attachment" fail
MOCK_PRE="$ORIGINAL_PRE"

MOCK_PRE=$(printf '%s\n%s\n' "$ORIGINAL_PRE" '-A PREROUTING -m mark --mark 0x0 -j _CUST_BYPASS_WA_')
run_case "duplicate PREROUTING attachment" fail
MOCK_PRE="$ORIGINAL_PRE"

MOCK_CHAIN_FAIL=1
run_case "iptables chain query error" fail
MOCK_CHAIN_FAIL=0

MOCK_PRE_FAIL=1
run_case "iptables PREROUTING query error" fail
MOCK_PRE_FAIL=0

MOCK_API_FAIL=1
run_case "policy API failure" fail
MOCK_API_FAIL=0

# Issue #310 diagnostics: a nonzero chain answer must be classified from its
# captured stderr, not collapsed into one generic fault.
run_fault_case() {
    _fc_label="$1"
    _fc_err="$2"
    _fc_expect_fault="$3"
    _fc_expect_advice="$4"
    RESULT_OK=0
    RESULT_FAIL=0
    RESULT_INFO=0
    LAST_FAIL=""
    LAST_INFO=""
    MOCK_CHAIN_FAIL=1
    MOCK_CHAIN_ERR="$_fc_err"
    check_bypass_netfilter_runtime
    MOCK_CHAIN_FAIL=0
    MOCK_CHAIN_ERR=""
    [ "$RESULT_FAIL" -ge 1 ] || { echo "[FAIL] $_fc_label: false PASS"; exit 1; }
    printf '%s
' "$LAST_FAIL" | grep -Fq "$_fc_expect_fault" ||
        { echo "[FAIL] $_fc_label: expected fault missing, got: $LAST_FAIL"; exit 1; }
    printf '%s
' "$LAST_INFO" | grep -Fq "$_fc_expect_advice" ||
        { echo "[FAIL] $_fc_label: expected advice missing, got: $LAST_INFO"; exit 1; }
    echo "[OK] $_fc_label"
}
run_fault_case "chain absence classified from iptables stderr"     "iptables: No chain/target/match by that name."     "chain absent (netfilter hook has not applied yet)"     "KeeneticOS has not rebuilt the firewall since hook delivery. Safe next step: wait about 10 minutes and re-run mihomo-doctor.sh; one router reboot also applies the hook. Do not run iptables commands manually."
run_fault_case "xtables lock contention classified"     "iptables: Resource temporarily unavailable."     "iptables busy (firewall rebuild or xtables lock in progress)"     "a firewall rebuild is holding iptables right now. Safe next step: re-run mihomo-doctor.sh in a few minutes."
run_fault_case "unknown iptables read error keeps the generic fault and contract wording"     "iptables: unknown error simulation"     "chain cannot be inspected"     "iptables returned an unexpected read error. Safe next step: re-run mihomo-doctor.sh and keep its output if the problem persists."

echo "[OK] Netfilter live rules runtime regression passed"