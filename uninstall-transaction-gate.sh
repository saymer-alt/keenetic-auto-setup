#!/bin/sh
# KAS nine-record uninstall transaction readiness gate.
# READ ONLY. It never stops services, removes files, or mutates KeeneticOS.
set -eu
export LC_ALL=C

[ "$#" -eq 2 ] && [ "$1" = "--check" ] ||
    { echo "Usage: sh uninstall-transaction-gate.sh --check SNAPSHOT_NAME" >&2; exit 2; }
name=$2
fail() { printf '[BLOCKED] %s\n' "$1" >&2; exit 3; }

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd) || fail "cannot locate verifier"
[ -f "$script_dir/uninstall-snapshot-verify.sh" ] ||
    fail "snapshot verifier not found alongside transaction gate"
sh "$script_dir/uninstall-snapshot-verify.sh" "$name" || fail "snapshot absent, stale or unverified"

root=${KAS_SNAPSHOT_ROOT:-}
case "$root" in
    '') ;;
    /*) [ "$root" != "/" ] || fail "bad fixture root" ;;
    *) fail "fixture root must be absolute" ;;
esac
ledger="$root/opt/etc/keenetic-auto-setup/ownership.v1"
[ -f "$ledger" ] && [ ! -L "$ledger" ] || fail "ownership ledger not readable"

# This first transaction profile intentionally covers ONLY the KN-1010 hardware
# fixture: nine claims (8 types) on one canonical Proxy0. Partial, foreign,
# legacy or additional/modified resources require a different owner review.
expected='KAS_OWNERSHIP_V1
owned|policy|bypass_wa
enabled|dns|intercept
owned|package|mihomo
owned|proxy|Proxy0
owned|repository|magitrickle.conf
owned|package|magitrickle
owned|hook|020-bypass_wa.sh
owned|watchdog|binary
owned|watchdog|wrapper'
[ "$(wc -l < "$ledger")" -eq 10 ] || fail "ledger not the hardware-tested nine-claim profile"
for entry in $(printf '%s\n' "$expected" | tail -n +2 | tr '\n' ' '); do
    grep -Fqx "$entry" "$ledger" || fail "required recorded claim missing"
done
[ "$(LC_ALL=C sort -u "$ledger" | wc -l)" -eq 10 ] ||
    fail "duplicate ledger entry"

rc=$(ndmc -c 'show running-config' 2>/dev/null | tr -d '\r') ||
    fail "running-config cannot be read"
printf '%s\n' "$rc" | grep -q '^interface ' ||
    fail "running-config invalid"

# Read the profile as separate blocks. Exit on unexpected contents; do not
# assume an interface name by matching a proxy upstream somewhere else.
proxies=$(printf '%s\n' "$rc" | awk '
    function flush() {
        if (iface != "" && upstream) {
            print iface
        }
        iface=""; upstream=0
    }
    /^interface Proxy[0-9]+[[:space:]]*$/ { flush(); iface=$2; next }
    /^interface / || /^!$/ { flush(); next }
    iface != "" && /^[[:space:]]+proxy upstream 127[.]0[.]0[.]1[[:space:]]+7890[[:space:]]*$/ { upstream=1 }
    END { flush() }
') || fail "proxy scan failed"
[ "$proxies" = Proxy0 ] ||
    fail "unexpected, foreign or missing ProxyN consuming port 7890"

# Reject noncanonical modifications even to a ledger-owned Proxy0. This
# refuses to tear down an interface the user may have repurposed.
proxy_block=$(printf '%s\n' "$rc" | awk '
    /^interface Proxy0$/ { inside=1; next }
    inside && /^!$/ { exit }
    inside { print }
') || fail "cannot inspect owned Proxy0"
[ -n "$proxy_block" ] || fail "owned Proxy0 missing"
seen_upstream=0
seen_socks=0
seen_udp=0
seen_up=0
seen_name=0
while IFS= read -r line; do
    case "$line" in
        '    description "mihomo t2s0"') seen_name=1 ;;
        '    security-level public'|'    ip global 350') ;;
        '    proxy protocol socks5') seen_socks=1 ;;
        '    proxy socks5-udp') seen_udp=1 ;;
        '    proxy upstream 127.0.0.1 7890') seen_upstream=1 ;;
        '    up') seen_up=1 ;;
        *) fail "owned Proxy0 has an unrecognized directive" ;;
    esac
done <<_PROXY
$proxy_block
_PROXY
[ "$seen_name$seen_socks$seen_udp$seen_upstream$seen_up" = 11111 ] ||
    fail "owned Proxy0 no longer matches canonical signature"

# The policy is journal-owned, but only the original simple signature is
# accepted. Any foreign permit, segment, host binding or customization blocks.
[ "$(printf '%s\n' "$rc" | grep -Ec '^ip policy bypass_wa$')" -eq 1 ] ||
    fail "bypass_wa policy absent or duplicated"
policy_block=$(printf '%s\n' "$rc" | awk '
    /^ip policy bypass_wa$/ { inside=1; next }
    inside && /^!$/ { exit }
    inside { print }
')
seen_exit=0
while IFS= read -r line; do
    case "$line" in
        '    description bypass_wa') ;;
        '    permit global Proxy0') seen_exit=1 ;;
        '    no permit global GigabitEthernet1') ;;
        *) fail "bypass_wa policy has an unrecognized/shared directive" ;;
    esac
done <<_POLICY
$policy_block
_POLICY
[ "$seen_exit" -eq 1 ] || fail "bypass_wa does not exclusively permit owned Proxy0"
# A separate user host/network selector may refer to this policy; that is not
# safe to silently remove. Capture references outside the policy block.
if printf '%s\n' "$rc" | awk '
    /^ip policy bypass_wa$/ { inside=1; next }
    inside && /^!$/ { inside=0; next }
    !inside && /bypass_wa/ { found=1 }
    END { exit !found }
'; then
    fail "policy bypass_wa referenced outside its own block"
fi

[ "$(printf '%s\n' "$rc" | grep -Ec '^[[:space:]]+intercept enable$')" -eq 1 ] ||
    fail "KAS-owned DNS intercept was disabled or ambiguous"

mangle=$(iptables -t mangle -S 2>/dev/null) ||
    fail "mangle state unreadable"
printf '%s\n' "$mangle" | grep -Fq -- '-N _CUST_BYPASS_WA_' ||
    fail "KAS mangle chain missing"
printf '%s\n' "$mangle" | grep -Eq '^-A PREROUTING .*_CUST_BYPASS_WA_' ||
    fail "KAS PREROUTING jump missing"

# Backup verification above compares current OPKG and file inventory with the
# snapshot. It does not prove *exclusive* use by unrelated host processes.
printf '[PASS] Nine-claim KAS transaction preflight: canonical Proxy0, bypass_wa and DNS verified\n'
printf '[REVIEW] DNS interception and package consumers can be shared; human approval still required\n'
printf '[INFO] This is read-only; uninstall.sh --remove remains BLOCKED\n'