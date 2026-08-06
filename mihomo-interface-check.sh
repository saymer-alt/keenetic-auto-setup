#!/bin/sh

echo "======================================"
echo " Mihomo interface-name check v0.3"
echo "======================================"
echo

DEFAULT_IF=$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}')

echo "[DEFAULT ROUTE]"
echo " $DEFAULT_IF"

echo
echo "======================================"
echo " Available Mihomo interfaces"
echo "======================================"

show_interface()
{
    IFACE="$1"
    TYPE="$2"

    # Проверяем наличие интерфейса
    ip link show "$IFACE" >/dev/null 2>&1 || return

    # Проверяем UP
    ip link show "$IFACE" | grep -q "UP" || return

    INFO=$(ip addr show "$IFACE" 2>/dev/null)

    IP=$(echo "$INFO" | awk '/inet / {print $2; exit}')

    # Нет IPv4 - пропускаем
    [ -z "$IP" ] && return

    MTU=$(ip link show "$IFACE" | awk '/mtu/ {for(i=1;i<=NF;i++) if($i=="mtu"){print $(i+1); exit}}')

    echo
    echo "--------------------------------------"
    echo "$IFACE"
    echo " Type: $TYPE"
    echo " IP:   $IP"
    echo " MTU:  $MTU"
    echo
    echo " Mihomo:"
    echo " interface-name: $IFACE"
}


echo
echo "[WAN / Ethernet]"

for IF in $(ip link | awk -F': ' '/^[0-9]+:/ {print $2}' | sed 's/@.*//')
do
    case "$IF" in
        eth*)
            show_interface "$IF" "Ethernet"
            ;;
    esac
done


echo
echo "[PPP tunnels]"

for IF in $(ip link | awk -F': ' '/^[0-9]+:/ {print $2}' | sed 's/@.*//')
do
    case "$IF" in
        ppp*)
            show_interface "$IF" "PPP tunnel"
            ;;
    esac
done


echo
echo "[WireGuard]"

for IF in $(ip link | awk -F': ' '/^[0-9]+:/ {print $2}' | sed 's/@.*//')
do
    case "$IF" in
        nwg*|wg*)
            show_interface "$IF" "WireGuard"
            ;;
    esac
done


echo
echo "======================================"
echo " Finished"
echo "======================================"
