#!/bin/sh
# Read-only. No files, package updates, routes, DNS or firewall mutations.
# Intentionally never reads running-config, process argv, environ or WG configs.
# Globbing is required for the /proc and /sys discovery loops below.
export LC_ALL=C
network=no
case ${1-} in
    '') ;;
    --network) network=yes ;;
    *) printf '%s\n' 'usage: sh preflight.sh [--network]'; exit 2 ;;
esac
printf '%s\n' 'WDTT_PREFLIGHT_V1 read_only=true secrets=false'
printf 'kernel='; uname -r
printf 'machine='; uname -m
printf 'word_bits='; if command -v getconf >/dev/null 2>&1; then getconf LONG_BIT 2>/dev/null || echo UNKNOWN; else echo UNKNOWN; fi
printf 'cpu='; awk -F: '/^(system type|model name|Hardware)[ \t]*:/ {gsub(/^[ \t]+/,"",$2); print $2; found=1; exit} END {if(!found)print "UNKNOWN"}' /proc/cpuinfo 2>/dev/null
if command -v ndmc >/dev/null 2>&1; then
    ndmc -c 'show version' 2>/dev/null | awk '
    /^[ \t]*(model|hw_id|release|version):/ {if($2 ~ /^[A-Za-z0-9._-]+$/) print "keenetic_" $1 " " $2}
    /^[ \t]*components:/ {incomp=1; sub(/^.*components:[ \t]*/, ""); comp=$0; next}
    incomp && /^[ \t]*[A-Za-z_]+:/ {incomp=0}
    incomp {gsub(/^[ \t]+|[ \t]+$/, ""); comp=comp $0}
    END {gsub(/[ \t\r\n]/,"",comp); if(comp ~ /^[a-z0-9,+-]+$/) print "components=" comp; else print "components=UNKNOWN"}'
else printf '%s\n' 'keenetic_version=UNKNOWN ndmc_unavailable'; fi
awk '/^(MemTotal|MemAvailable|MemFree|Buffers|Cached|SwapTotal|SwapFree):/ {print "memory_" $1 " " $2 " " $3}' /proc/meminfo
awk 'NR>1 {count++; total+=$3; if($1 ~ /\/zram[0-9]+$/)zram++} END {printf "swap_entries=%d swap_kib=%d zram_name_candidates=%d (identity_unverified)\n",count,total,zram}' /proc/swaps
if [ -d /opt ]; then
    df -Pk /opt 2>/dev/null | awk 'NR==2 {print "opt_available_kib=" $4}'
    awk '$2=="/opt" || index("/opt/",$2"/")==1 {if(length($2)>n){n=length($2);fs=$3;mp=$2}} END {if(n)print "opt_mount=" mp " fs=" fs;else print "opt_mount=UNKNOWN"}' /proc/mounts
else echo 'opt=ABSENT'; fi
awk '$2=="/opt/tmp" || $2=="/opt/var/log" || $2=="/opt/var/run" {print "runtime_mount=" $2 " fs=" $3}' /proc/mounts
if [ -x /opt/etc/init.d/S00ubifs ]; then echo 'S00ubifs=EXECUTABLE presence_not_health'; else echo 'S00ubifs=ABSENT_OR_DISABLED'; fi
if command -v opkg >/dev/null 2>&1; then
    opkg print-architecture 2>/dev/null | awk '$1=="arch" && $2 ~ /^[A-Za-z0-9_.-]+$/ {print "entware_" $0}'
    opkg list-installed 2>/dev/null | awk '$1 ~ /^(busybox|libc|opkg|mihomo|wireguard-go|mtr|magitrickle|ca-bundle|ca-certificates)$/ && $3 ~ /^[A-Za-z0-9_.+~-]+$/ {print "package=" $1 " version=" $3}'
else echo 'entware_abi=UNKNOWN opkg_unavailable'; fi
# ELF bytes identify the installed userspace, not merely uname CPU capability.
if command -v od >/dev/null 2>&1; then
    for exe in /opt/bin/opkg /opt/bin/busybox /opt/sbin/opkg; do
        [ -f "$exe" ] || continue
        bytes=$(od -An -tu1 -N20 "$exe" 2>/dev/null)
        set -f
        set -- $bytes
        set +f
        if [ "${1-}" = 127 ] && [ "${2-}" = 69 ] && [ "${3-}" = 76 ] && [ "${4-}" = 70 ]; then
            printf 'entware_elf_class=%s endian=%s machine_bytes=%s,%s\n' "${5-}" "${6-}" "${19-}" "${20-}"
            break
        fi
    done
else echo 'entware_elf=UNKNOWN od_unavailable'; fi
for d in /proc/[0-9]*; do
    [ -r "$d/comm" ] || continue
    IFS= read -r comm < "$d/comm" || continue
    case $comm in mihomo|wt-client|wireguard-go|xray|sing-box|openvpn|awg*|wg-obfuscator|magitrickle*) printf 'vpn_process=%s pid=%s\n' "$comm" "${d##*/}";; esac
done
for proto in tcp tcp6 udp udp6; do
    [ -r "/proc/net/$proto" ] || continue
    awk -v p="$proto" 'NR>1 && (p ~ /^udp/ || $4=="0A") {split($2,a,":"); print "port_" p "_hex=" a[2]}' "/proc/net/$proto"
done
for d in /sys/class/net/*; do
    [ -r "$d/tun_flags" ] && printf 'tun=%s\n' "${d##*/}"
done
if [ -c /dev/net/tun ]; then echo 'tun_device=PRESENT'; else echo 'tun_device=ABSENT'; fi
if command -v ip >/dev/null 2>&1; then
    ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev")print "default4_dev=" $(i+1)}'
    ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="dev")print "default6_dev=" $(i+1)}'
else echo 'default_route=UNKNOWN ip_unavailable'; fi
if [ "$network" = yes ]; then
    # Fixed public target only; never send private config or query the Controller.
    if command -v timeout >/dev/null 2>&1 && command -v nslookup >/dev/null 2>&1; then
        if timeout 10 nslookup example.com >/dev/null 2>&1; then echo 'dns_probe=PASS'; else echo 'dns_probe=FAIL'; fi
    else echo 'dns_probe=UNKNOWN missing_timeout_or_nslookup'; fi
    if command -v curl >/dev/null 2>&1; then
        if curl -4 -fsS --connect-timeout 5 --max-time 10 https://example.com/ -o /dev/null 2>/dev/null; then echo 'https4_probe=PASS'; else echo 'https4_probe=FAIL'; fi
    else echo 'https4_probe=UNKNOWN curl_unavailable'; fi
else echo 'network_probes=NOT_RUN use_--network_only_on_approved_isolated_test_device'; fi
echo 'hardware_acceptance=NOT_PERFORMED'
