#!/bin/sh

# SPDX-License-Identifier: MIT

# VoIP bypass helper for Keenetic
# Marks WhatsApp/Telegram UDP traffic and routes it via a specific policy
# Prevents call drops and improves VoIP stability

# Paths for iptables and utilities
PATH=/opt/sbin:/opt/bin:/bin:/sbin:/usr/sbin:$PATH

# Target UDP ports (VoIP)
ports="1400,3478,3482"

# Custom chain name
chain="_CUST_BYPASS_WA_"

# Load multiport module if not already loaded.
# KeeneticOS component opkg-kmod-netfilter provides xt_multiport for this path;
# the separate Xtables-addons component is not required by this script.
if ! lsmod | grep -q '^xt_multiport'; then
    modprobe xt_multiport 2>/dev/null || \
    insmod /lib/modules/$(uname -r)/xt_multiport.ko 2>/dev/null
fi

# Exit for IPv6 or non-mangle table
[ "$type" = "ip6tables" ] && exit 0
[ "$table" != "mangle" ] && exit 0

# Resolve the actual Keenetic policy mark BEFORE touching live Netfilter state.
# Mark values are hexadecimal in the Keenetic API (e.g. ffffaab).
# Never substitute a guessed mark: that could silently route VoIP elsewhere.
if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' '[ERROR] bypass_wa: curl/jq unavailable; refusing to change Netfilter rules' >&2
    exit 1
fi
if ! policy_json_=$(curl -fSs --connect-timeout 3 --max-time 5 http://localhost:79/rci/show/ip/policy); then
    printf '%s\n' '[ERROR] bypass_wa: Keenetic policy API unavailable; refusing to change Netfilter rules' >&2
    exit 1
fi
if ! mark_id_=$(printf '%s\n' "$policy_json_" | \
    jq -er '[.[] | select(.description == "bypass_wa") | .mark] | if length == 1 then .[0] else empty end' 2>/dev/null); then
    printf '%s\n' '[ERROR] bypass_wa: unable to identify exactly one policy mark; refusing to change Netfilter rules' >&2
    exit 1
fi
case "$mark_id_" in
    ''|*[!0123456789abcdefABCDEF]*)
        printf '%s\n' '[ERROR] bypass_wa: invalid hexadecimal policy mark; refusing to change Netfilter rules' >&2
        exit 1
        ;;
esac

# Create chain if it doesn't exist, otherwise flush it.
# Keep the original hook application behavior until the runtime-safe
# apply/rollback protocol is validated in field testing.
iptables -w -t mangle -N "$chain" 2>/dev/null || \
iptables -w -t mangle -F "$chain" || true

# Attach chain to PREROUTING if not already present
iptables -w -t mangle -C PREROUTING -m mark --mark 0x0 -j "$chain" >/dev/null 2>&1 || \
iptables -w -t mangle -A PREROUTING -m mark --mark 0x0 -j "$chain" || true

# Mark matching UDP traffic
iptables -w -t mangle -C "$chain" -p udp -m multiport --dports $ports \
-j MARK --set-mark 0x$mark_id_ >/dev/null 2>&1 || \
iptables -w -t mangle -A "$chain" -p udp -m multiport --dports $ports \
-j MARK --set-mark 0x$mark_id_ || true

# Save mark to connection tracking
iptables -w -t mangle -C "$chain" -p udp -m multiport --dports $ports \
-j CONNMARK --save-mark >/dev/null 2>&1 || \
iptables -w -t mangle -A "$chain" -p udp -m multiport --dports $ports \
-j CONNMARK --save-mark || true

# Return from chain
iptables -w -t mangle -C "$chain" -p udp -m multiport --dports $ports \
-j RETURN >/dev/null 2>&1 || \
iptables -w -t mangle -A "$chain" -p udp -m multiport --dports $ports \
-j RETURN || true

exit 0
