#!/bin/sh

echo "======================================"
echo " Mihomo interface-name check v0.8"
echo "======================================"
echo

DEFAULT_IF=$(ip route | awk '/default/ {print $5; exit}')

echo "[DEFAULT ROUTE]"
echo " ⭐ $DEFAULT_IF"
echo


show_iface()
{
    IFACE="$1"
    TYPE="$2"

    ip link show "$IFACE" >/dev/null 2>&1 || return

    STATE=$(ip link show "$IFACE" | grep -o "state [A-Z]*" | awk '{print $2}')

    [ "$STATE" != "UP" ] && return

    IP=$(ip addr show "$IFACE" | awk '/inet / {print $2; exit}')

    [ -z "$IP" ] && IP="none"

    MTU=$(ip link show "$IFACE" | awk '/mtu/ {print $5}')

    echo "--------------------------------------"
    echo "$IFACE"
    echo " Type: $TYPE"

    [ "$IFACE" = "$DEFAULT_IF" ] && echo " ⭐ Default route"

    echo " IP:   $IP"
    echo " MTU:  $MTU"
    echo
    echo " Mihomo:"
    echo " interface-name: $IFACE"
    echo
}


echo "======================================"
echo "[WireGuard]"
echo "======================================"

for IFACE in $(ip link show | grep -o "nwg[0-9]*"); do
    show_iface "$IFACE" "WireGuard"
done


echo "======================================"
echo "[PPP VPN]"
echo "======================================"

for IFACE in $(ip link show | grep -o "ppp[0-9]*"); do
    show_iface "$IFACE" "PPP tunnel"
done


echo "======================================"
echo "[Ethernet]"
echo "======================================"

for IFACE in $(ip link show | grep -o "eth[0-9]*" | sort -u); do
    show_iface "$IFACE" "Ethernet"
done


echo "======================================"
echo " Ready for mihomo config"
echo "======================================"

echo

for IFACE in $(ip link show | grep -oE "(nwg[0-9]+|ppp[0-9]+|eth[0-9]+)" | sort -u); do

    STATE=$(ip link show "$IFACE" 2>/dev/null | grep -o "state [A-Z]*" | awk '{print $2}')

    if [ "$STATE" = "UP" ]; then
        echo " interface-name: $IFACE"
    fi

done


echo
echo "======================================"
echo " Finished"
echo "======================================"
