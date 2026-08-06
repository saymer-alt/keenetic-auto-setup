#!/bin/sh

echo "======================================"
echo " Mihomo interface-name check v0.6"
echo "======================================"
echo

DEFAULT_IF=$(ip route | awk '/default/ {print $5; exit}')

echo "[DEFAULT ROUTE]"
echo " $DEFAULT_IF"
echo


get_status() {
    ip link show "$1" 2>/dev/null | grep -q "UP" \
        && echo "UP" \
        || echo "DOWN"
}


show_iface() {

    IFACE="$1"

    STATUS=$(get_status "$IFACE")

    IP=$(ip addr show "$IFACE" 2>/dev/null | awk '/inet / {print $2; exit}')
    MTU=$(ip link show "$IFACE" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1)}')

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
        *)
            echo " Type: Other"
            ;;
    esac

    echo " Status: $STATUS"
    echo " IP:   $IP"
    echo " MTU:  $MTU"
    echo
    echo " Mihomo:"
    echo " interface-name: $IFACE"
    echo
}


echo "======================================"
echo "[ACTIVE WireGuard]"
echo "======================================"
echo

for IFACE in $(ip -o link show | awk -F': ' '/nwg[0-9]+/ {print $2}' | cut -d'@' -f1 | sort -u); do
    if [ "$(get_status "$IFACE")" = "UP" ]; then
        show_iface "$IFACE"
    fi
done


echo "======================================"
echo "[DOWN WireGuard]"
echo "======================================"
echo

for IFACE in $(ip -o link show | awk -F': ' '/nwg[0-9]+/ {print $2}' | cut -d'@' -f1 | sort -u); do
    if [ "$(get_status "$IFACE")" = "DOWN" ]; then
        show_iface "$IFACE"
    fi
done


echo "======================================"
echo "[WAN Ethernet]"
echo "======================================"
echo

for IFACE in $(ip -o link show | awk -F': ' '/eth[0-9]+:/ {print $2}' | cut -d'@' -f1 | sort -u); do
    show_iface "$IFACE"
done


echo "======================================"
echo "[PPP VPN tunnels]"
echo "======================================"
echo

for IFACE in $(ip -o link show | awk -F': ' '/ppp[0-9]+:/ {print $2}' | cut -d'@' -f1 | sort -u); do
    show_iface "$IFACE"
done


echo "======================================"
echo " Finished"
echo "======================================"
