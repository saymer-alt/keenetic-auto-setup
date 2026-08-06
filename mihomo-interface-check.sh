#!/bin/sh
#
# mihomo-interface-check.sh v1.0.1
# Diagnostic tool for Keenetic NDMS + Entware
# GitHub: https://github.com/saymer-alt/keenetic-auto-setup
#

echo "======================================"
echo " Mihomo interface-name check v1.0.1"
echo "======================================"

# Получаем красивую версию Keenetic OS через ndmc/ndmq
OS_VER=$(ndmc -c "show version" 2>/dev/null | awk '/title:/ {for(i=2;i<=NF;i++) printf "%s ", $i; print ""}')

if [ -z "$OS_VER" ]; then
    OS_VER=$(ndmq -p 'show version' -f json 2>/dev/null | grep -o '"title":"[^"]*"' | cut -d'"' -f4)
fi

if [ -n "$OS_VER" ]; then
    echo " System: $OS_VER"
else
    echo " System: $(uname -sr 2>/dev/null)"
fi
echo

# 1. Находим дефолтный маршрут (Основной провайдер)
DEFAULT_IF=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')

echo "[DEFAULT ROUTE]"
if [ -n "$DEFAULT_IF" ]; then
    echo " ⭐ $DEFAULT_IF (Current Internet route)"
else
    echo " none"
fi
echo

# Глобальная переменная для сбора готовности
READY_IFACES=""

# Функция обработки и вывода интерфейса
show_iface() {
    IFACE="$1"
    TYPE="$2"

    [ -z "$IFACE" ] && return

    # Отрезаем суффиксы VLAN (@eth2 -> eth2)
    REAL_IFACE=$(echo "$IFACE" | sed 's/@.*//')

    # Проверяем существование
    ip link show "$REAL_IFACE" >/dev/null 2>&1 || return

    # Проверяем, поднята ли ссылка (UP / LOWER_UP)
    LINK_INFO=$(ip link show "$REAL_IFACE" 2>/dev/null)
    echo "$LINK_INFO" | grep -qE "(<|,)(UP|LOWER_UP)(,|>)" || return

    # Получаем IPv4 адрес
    IP=$(ip addr show "$REAL_IFACE" 2>/dev/null | awk '/inet / {print $2; exit}')
    
    # Без IP интерфейс пропускаем (Mihomo не сможет залинковаться)
    [ -z "$IP" ] && return

    MTU=$(echo "$LINK_INFO" | awk '/mtu/ {for(i=1;i<=NF;i++) if($i=="mtu"){print $(i+1); exit}}')

    echo "--------------------------------------"
    echo "$REAL_IFACE"
    echo " Type: $TYPE"
    if [ "$REAL_IFACE" = "$DEFAULT_IF" ]; then
        echo " ⭐ Recommended (Current Internet route)"
    fi
    echo " IP:   $IP"
    echo " MTU:  ${MTU:-unknown}"
    echo
    echo " Mihomo:"
    echo " interface-name: $REAL_IFACE"
    echo

    # Сохраняем в итоговый список без повторных вызовов ip link
    case " $READY_IFACES " in
        *" $REAL_IFACE "*) ;;
        *) READY_IFACES="$READY_IFACES $REAL_IFACE" ;;
    esac
}

# Функция для сборки уникальных интерфейсов по маске
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

if [ -n "$READY_IFACES" ]; then
    for i in $READY_IFACES; do
        echo " interface-name: $i"
    done
else
    echo " No active interfaces found."
fi

echo
echo "======================================"
echo " Finished"
echo "======================================"
