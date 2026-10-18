#!/bin/sh
# SPDX-License-Identifier: MIT
#
# NC-1812/Hopper field proof of Netfilter readiness.
# READ ONLY: does not reload firewall, modify iptables, alter OPKG feeds,
# restart services or modify KeeneticOS policies. Output can be attached
# to an issue before/after install or a vendor-supported firewall rewrite.
set -u
PATH=/opt/sbin:/opt/bin:/sbin:/bin:/usr/sbin:/usr/bin:$PATH

say() { printf '%s\n' "$1"; }
hdr() { printf '\n=== %s ===\n' "$1"; }
probe() {
    _np_name=$1
    shift
    "$@" 2>&1
    _np_rc=$?
    say "[INFO] $_np_name exit code: $_np_rc"
    return 0
}

say "=== KAS Netfilter FIELD PROBE v1 (READ-ONLY; no changes made) ==="
say "[INFO] Capture both first-install and later results for comparison."
date 2>&1 || true
uname -r 2>&1 || true

hdr "Existing init services (existence only; DO NOT run)"
probe "Keenetic /etc/init.d/netfilter" ls -ld /etc/init.d/netfilter
probe "Entware /opt/etc/init.d/netfilter" ls -ld /opt/etc/init.d/netfilter

hdr "Installed project hook"
probe "bypass hook" ls -l /opt/etc/ndm/netfilter.d/020-bypass_wa.sh

hdr "Kernel support"
if command -v lsmod >/dev/null 2>&1; then
    lsmod 2>&1 | grep -E '(^|[[:space:]])xt_multiport([[:space:]]|$)' || say "[INFO] xt_multiport not visible in lsmod (or lsmod unavailable)"
else
    say "[INFO] lsmod unavailable"
fi

hdr "Live bypass policy (read-only KeeneticOS)"
if command -v ndmc >/dev/null 2>&1; then
    # Extract only policy name/description and mark, not full routing data.
    ndmc -c 'show ip policy' 2>&1 |
        awk '/policy, name = /{p=$0; next} /mark:/{if(p ~ /bypass_wa/) {print p; print $0}; p=""}'
else
    say "[INFO] ndmc unavailable; policy mark not probed"
fi

hdr "Live IPv4 mangle/PREROUTING"
if command -v iptables >/dev/null 2>&1; then
    probe "iptables PREROUTING" iptables -t mangle -S PREROUTING
else
    say "[INFO] iptables unavailable; cannot prove rules"
fi

hdr "Live IPv4 mangle/_CUST_BYPASS_WA_"
if command -v iptables >/dev/null 2>&1; then
    probe "iptables bypass chain" iptables -t mangle -S _CUST_BYPASS_WA_
else
    say "[INFO] iptables unavailable; cannot prove rules"
fi
say ""
say "[INFO] Interpretation: existing hook != chain exists != correct MARK/CONNMARK/RETURN != confirmed VoIP route."
say "[INFO] A failed iptables query is NOT proof that Xtables-addons is needed. Compare rc/stderr and system state."
say "[INFO] No router configuration, service or firewall changes were made."
