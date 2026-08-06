#!/bin/sh

echo "======================================"
echo " Mihomo interface-name check v0.2"
echo "======================================"
echo

# Default route
DEFAULT_IF=$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}')

echo "[DEFAULT ROUTE]"
if [ -n "$DEFAULT_IF" ]; then
    echo " $DEFAULT_IF"
else
    echo " none"
fi

echo
echo "======================================"
echo " Available interfaces"
echo "======================================"

show_interface() {
    IFACE="$1"

    # Skip empty
    [ -z "$IFACE" ] && return

    # Skip unwanted interfaces
    case "$IFACE" in
        lo|br*|mitun*|dummy*|tunl*|ip6tnl*|sit*|gre*|gretap*|ethoip*|\
        ra*|apcli*|eth*.1|eth*.2|eth*.3|eth*.4|\
        vpn*)
            return
            ;;
    esac

    # Interface exists?
    ip link show "$IFACE" >/dev/null 2>&1 || return

    INFO=$(ip addr show "$IFACE" 2>/dev/null)

    IP=$(echo "$INFO" | awk '/inet / {print $2; exit}')
    MTU=$(ip link show "$IFACE" | awk '/mtu/ {for(i=1;i<=NF;i++) if($i=="mtu"){print $(i+1); exit}}')

    TYPE=""

    case "$IFACE" in
        ppp*)
            TYPE="PPP tunnel"
            ;;
        nwg*|wg*)
            TYPE="WireGuard"
            ;;
        eth*)
            TYPE="Ethernet"
            ;;
        *)
            TYPE="Other"
            ;;
    esac

    echo
    echo "--------------------------------------"
    echo "$IFACE"
    echo " Type: $TYPE"

    if [ -n "$IP" ]; then
        echo " IP:   $IP"
    else
        echo " IP:   none"
    fi

    echo " MTU:  ${MTU:-unknown}"

    echo
    echo " Mihomo:"
    echo " interface-name: $IFACE"
}


echo
echo "[Ethernet/WAN]"
for IF in $(ip link | awk -F': ' '/^[0-9]+:/ {print $2}' | sed 's/@.*//'); do
    case "$IF" in
        eth*)
            show_interface "$IF"
            ;;
    esac
done


echo
echo "[PPP]"
for IF in $(ip link | awk -F': ' '/^[0-9]+:/ {print $2}' | sed 's/@.*//'); do
    case "$IF" in
        ppp*)
            show_interface "$IF"
            ;;
    esac
done


echo
echo "[WireGuard]"
for IF in $(ip link | awk -F': ' '/^[0-9]+:/ {print $2}' | sed 's/@.*//'); do
    case "$IF" in
        nwg*|wg*)
            show_interface "$IF"
            ;;
    esac
done


echo
echo "======================================"
echo " Finished"
echo "======================================"
