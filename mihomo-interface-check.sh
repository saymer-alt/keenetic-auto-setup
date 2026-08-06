#!/bin/sh

echo "======================================"
echo " Mihomo interface-name check v0.4"
echo "======================================"
echo

# Default route
DEFAULT_IF=$(ip route | awk '/default/ {print $5; exit}')

echo "[DEFAULT ROUTE]"
echo " $DEFAULT_IF"
echo

echo "======================================"
echo " Mihomo interface candidates"
echo "======================================"
echo


show_iface() {
    IFACE="$1"

    INFO=$(ip addr show "$IFACE" 2>/dev/null)

    IP=$(echo "$INFO" | awk '/inet / {print $2; exit}')
    MTU=$(ip link show "$IFACE" | awk '/mtu/ {print $5}')
    STATE=$(ip link show "$IFACE" | awk '/state/ {print $9}')

    [ -z "$STATE" ] && STATE="DOWN"
    [ -z "$IP" ] && IP="none"

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

    echo " Status: $STATE"
    echo " IP:   $IP"
    echo " MTU:  $MTU"
    echo

    echo " Mihomo:"
    echo " interface-name: $IFACE"
    echo
}


echo "[Recommended WireGuard]"
echo

for IFACE in $(ip link | grep -o "nwg[0-9]*"); do
    show_iface "$IFACE"
done


echo "======================================"
echo "[WAN / Ethernet]"
echo "======================================"
echo

for IFACE in $(ip link | grep -o "eth[0-9]*" | sort -u); do
    show_iface "$IFACE"
done


echo "======================================"
echo "[PPP VPN tunnels]"
echo "======================================"
echo

for IFACE in $(ip link | grep -o "ppp[0-9]*" | sort -u); do
    show_iface "$IFACE"
done


echo "======================================"
echo " Finished"
echo "======================================"
