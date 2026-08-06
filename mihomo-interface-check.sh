#!/bin/sh

echo "======================================"
echo " Mihomo interface-name check v0.5"
echo "======================================"
echo

DEFAULT_IF=$(ip route | awk '/default/ {print $5; exit}')

echo "[DEFAULT ROUTE]"
echo " $DEFAULT_IF"
echo


show_iface() {
    IFACE="$1"

    LINK=$(ip link show "$IFACE" 2>/dev/null)

    [ -z "$LINK" ] && return

    FLAGS=$(echo "$LINK" | head -1)

    IP=$(ip addr show "$IFACE" 2>/dev/null | awk '/inet / {print $2; exit}')
    MTU=$(echo "$LINK" | awk '{for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1)}')

    echo "--------------------------------------"
    echo "$IFACE"

    case "$IFACE" in
        eth*)
            echo " Type: Ethernet"
            ;;
        ppp*)
            echo " Type: PPP tunnel"
            ;;
        nwg*)
            echo " Type: WireGuard"
            ;;
        vpn*)
            echo " Type: Keenetic VPN"
            ;;
        *)
            echo " Type: Other"
            ;;
    esac


    echo "$FLAGS" | grep -q "UP" \
        && echo " Status: UP" \
        || echo " Status: DOWN"

    [ -z "$IP" ] && IP="none"

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
echo

for IFACE in $(ip link show | grep -o "nwg[0-9][0-9]*"); do
    show_iface "$IFACE"
done


echo "======================================"
echo "[WAN / Ethernet]"
echo "======================================"
echo

for IFACE in $(ip link show | grep -o "eth[0-9][0-9]*"); do
    show_iface "$IFACE"
done


echo "======================================"
echo "[PPP VPN tunnels]"
echo "======================================"
echo

for IFACE in $(ip link show | grep -o "ppp[0-9][0-9]*"); do
    show_iface "$IFACE"
done


echo "======================================"
echo " Finished"
echo "======================================"
