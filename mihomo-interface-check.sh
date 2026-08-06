#!/bin/sh

echo "======================================"
echo " Mihomo interface-name check v0.9"
echo "======================================"
echo

# 1. Находим дефолтный маршрут
DEFAULT_IF=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')

echo "[DEFAULT ROUTE]"
if [ -n "$DEFAULT_IF" ]; then
    echo " ⭐ $DEFAULT_IF"
else
    echo " none"
fi
echo

# Функция обработки и вывода интерфейса
show_iface() {
    IFACE="$1"
    TYPE="$2"

    [ -z "$IFACE" ] && return

    # Отрезаем @ifname (например eth2.1@eth2 -> eth2.1)
    REAL_IFACE=$(echo "$IFACE" | sed 's/@.*//')

    # Проверяем существование
    ip link show "$REAL_IFACE" >/dev/null 2>&1 || return

    # Проверяем, подняты ли ссылки (UP / LOWER_UP)
    LINK_INFO=$(ip link show "$REAL_IFACE" 2>/dev/null)
    echo "$LINK_INFO" | grep -qE "(<|,)(UP|LOWER_UP)(,|>)" || return

    # Получаем IP адрес (только IPv4)
    IP=$(ip addr show "$REAL_IFACE" 2>/dev/null | awk '/inet / {print $2; exit}')
    
    # Если нет IP - пропускаем, т.к. Mihomo не сможет выходить через интерфейс без IP
    [ -z "$IP" ] && return

    MTU=$(echo "$LINK_INFO" | awk '/mtu/ {for(i=1;i<=NF;i++) if($i=="mtu"){print $(i+1); exit}}')

    echo "--------------------------------------"
    echo "$REAL_IFACE"
    echo " Type: $TYPE"
    [ "$REAL_IFACE" = "$DEFAULT_IF" ] && echo " ⭐ Default route"
    echo " IP:   $IP"
    echo " MTU:  ${MTU:-unknown}"
    echo
    echo " Mihomo:"
    echo " interface-name: $REAL_IFACE"
    echo
}

# Вспомогательная функция для сборки списка уникальных интерфейсов по маске
get_ifaces() {
    PATTERN="$1"
    ip link 2>/dev/null | awk -F': ' '/^[0-9]+:/ {print $2}' | sed 's/@.*//' | grep -E "$PATTERN" | sort -u
}

echo "======================================"
echo "[WireGuard]"
echo "======================================"
for i in $(get_ifaces "^(nwg|wg)[0-9]+"); do
    show_iface "$i" "WireGuard"
done

echo "======================================"
echo "[PPP VPN]"
echo "======================================"
for i in $(get_ifaces "^ppp[0-9]+"); do
    show_iface "$i" "PPP tunnel"
done

echo "======================================"
echo "[Ethernet / WAN]"
echo "======================================"
for i in $(get_ifaces "^eth[0-9]+$"); do
    show_iface "$i" "Ethernet"
done

echo "======================================"
echo " Ready for mihomo config"
echo "======================================"
echo

for i in $(get_ifaces "^(nwg|wg|ppp|eth)[0-9]+$"); do
    IP=$(ip addr show "$i" 2>/dev/null | awk '/inet / {print $2; exit}')
    LINK_INFO=$(ip link show "$i" 2>/dev/null)
    
    if [ -n "$IP" ] && echo "$LINK_INFO" | grep -qE "(<|,)(UP|LOWER_UP)(,|>)"; then
        echo " interface-name: $i"
    fi
done

echo
echo "======================================"
echo " Finished"
echo "======================================"
