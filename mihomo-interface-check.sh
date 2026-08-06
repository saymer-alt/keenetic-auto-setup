#!/bin/sh
#
# mihomo-interface-check.sh
#
# Show network interfaces suitable for Mihomo interface-name option.
# Designed for Keenetic NDMS + Entware/BusyBox.
#
# Read-only diagnostic script.
#

echo "======================================"
echo " Mihomo interface-name check"
echo "======================================"
echo

# Get default route interface
DEFAULT_IFACE=$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}')

if [ -n "$DEFAULT_IFACE" ]; then
    echo "Default route interface: $DEFAULT_IFACE"
else
    echo "Default route interface: not found"
fi

echo
echo "======================================"
echo " Candidate interfaces"
echo "======================================"
echo


# Interfaces interesting for Mihomo
for IFACE in $(ip link 2>/dev/null | grep -E '^[0-9]+:' | awk -F': ' '{print $2}' | sed 's/@.*//')
do

    case "$IFACE" in
        eth*|ppp*|wg*|nwg*|vpn*)
            ;;

        *)
            continue
            ;;
    esac


    echo "--------------------------------------"

    if [ "$IFACE" = "$DEFAULT_IFACE" ]; then
        echo "Interface: $IFACE  [DEFAULT ROUTE]"
    else
        echo "Interface: $IFACE"
    fi


    # Link info
    ip link show "$IFACE" 2>/dev/null | head -1


    # Address
    ADDR=$(ip addr show "$IFACE" 2>/dev/null | \
        grep -m1 "inet " | \
        awk '{print $2}')

    if [ -n "$ADDR" ]; then
        echo "Address:   $ADDR"
    else
        echo "Address:   none"
    fi


    # MTU
    MTU=$(ip link show "$IFACE" 2>/dev/null | \
        grep -o "mtu [0-9]*" | \
        awk '{print $2}')

    if [ -n "$MTU" ]; then
        echo "MTU:       $MTU"
    fi


    echo
    echo "Mihomo:"
    echo "interface-name: $IFACE"

done


echo
echo "======================================"
echo "Finished"
echo "======================================"
