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

# Load multiport module if not already loaded
if ! lsmod | grep -q '^xt_multiport'; then
    modprobe xt_multiport 2>/dev/null || \
    insmod /lib/modules/$(uname -r)/xt_multiport.ko 2>/dev/null
fi

# Exit for IPv6 or non-mangle table
[ "$type" = "ip6tables" ] && exit 0
[ "$table" != "mangle" ] && exit 0

# Create chain if it doesn't exist, otherwise flush it
iptables -w -t mangle -N "$chain" 2>/dev/null || \
iptables -w -t mangle -F "$chain" || true

# Get mark ID from Keenetic policy (bypass_wa)
mark_id_=$(curl -kfsS http://localhost:79/rci/show/ip/policy | \
jq -r '.[] | select(.description == "bypass_wa") | .mark')

# Fallback mark if not found
[ -z "$mark_id_" ] && mark_id_=1

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
