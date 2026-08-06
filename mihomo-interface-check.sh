#!/bin/sh

echo "======================================"
echo " Mihomo interface-name check v0.7"
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

    STATE=$(ip link show "$IFACE" 2>/dev/null | grep -o "state [A-Z]*" | awk '{print $2}')

    [ "$STATE" != "UP" ] && return

    IP=$(ip addr show "$IFACE" 2>/dev/null | awk '/inet / {print $2; exit}')

    [ -z "$IP" ] && IP="none"

    MTU=$(ip link show "$IFACE" 2>/dev/null | awk '/mtu/ {print $5}')

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

for i in $(ip link | grep -o "nwg[0-9]*"); do
    show_iface "$i" "WireGuard"
done


echo "======================================"
echo "[PPP VPN]"
echo "======================================"

for i in $(ip link | grep -o "ppp[0-9]*"); do
    show_iface "$i" "PPP tunnel"
done


echo "======================================"
echo "[Ethernet]"
echo "======================================"

for i in $(ip link | awk -F': ' '/^[0-9]+:/ {print $2}' | grep "^eth[0-9]*$"); do
    show_iface "$i" "Ethernet"
done


echo "======================================"
echo " Ready for mihomo config"
echo "======================================"
echo

for i in $(ip link | awk -F': ' '/^[0-9]+:/ {print $2}' | grep -E "^(nwg|ppp|eth[0-9])"); do
    STATE=$(ip link show "$i" | grep -o "state [A-Z]*" | awk '{print $2}')
    [ "$STATE" = "UP" ] && echo " interface-name: $i"
done

echo
echo "======================================"
echo " Finished"
echo "======================================"
