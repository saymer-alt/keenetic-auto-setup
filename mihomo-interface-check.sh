#!/bin/sh

# mihomo-interface-check.sh v1.0.3
# Diagnostic tool for Keenetic NDMS + Entware
# GitHub: https://github.com/saymer-alt/keenetic-auto-setup


echo "======================================"
echo " Mihomo interface-name check v1.0.3"
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
    # Пробуем получить имя дефолтного интерфейса
    DEF_NAME=$(ndmc -c "show interface $DEFAULT_IF" 2>/dev/null | awk -F': ' '/description:/ {print $2; exit}' | tr -d '\r')
    if [ -n "$DEF_NAME" ]; then
        echo " ⭐ $DEFAULT_IF ($DEF_NAME) - Current Internet route"
    else
        echo " ⭐ $DEFAULT_IF (Current Internet route)"
    fi
else
    echo " none"
fi
echo

# Переменные для сбора итогового списка
SEEN_IFACES=""
READY_BLOCK=""

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

    # Получаем пользовательское имя (description) интерфейса из Keenetic OS
    SYS_NAME=$(ndmc -c "show interface $REAL_IFACE" 2>/dev/null | awk -F': ' '/description:/ {print $2; exit}' | tr -d '\r')

    echo "--------------------------------------"
    if [ -n "$SYS_NAME" ]; then
        echo "$REAL_IFACE ($SYS_NAME)"
    else
        echo "$REAL_IFACE"
    fi
    
    echo " Type: $TYPE"
    if [ "$REAL_IFACE" = "$DEFAULT_IF" ]; then
        echo " ⭐ Recommended (Current Internet route)"
    fi
    echo " IP:   $IP"
    echo " MTU:  ${MTU:-unknown}"
    echo
    echo " Mihomo:"
    if [ -n "$SYS_NAME" ]; then
        echo " interface-name: $REAL_IFACE # $SYS_NAME"
    else
        echo " interface-name: $REAL_IFACE"
    fi
    echo

    # Сохраняем в итоговый список без повторных вызовов
    case " $SEEN_IFACES " in
        *" $REAL_IFACE "*) ;;
        *) 
            SEEN_IFACES="$SEEN_IFACES $REAL_IFACE" 
            if [ -n "$SYS_NAME" ]; then
                READY_BLOCK="${READY_BLOCK}  interface-name: $REAL_IFACE # $SYS_NAME\n"
            else
                READY_BLOCK="${READY_BLOCK}  interface-name: $REAL_IFACE\n"
            fi
            ;;
    esac
}

# Функция для сборки уникальных интерфейсов по маске
get_ifaces() {
    PATTERN="$1"
    ip link 2>/dev/null | awk -F': ' '/^[0-9]+:/ {print $2}' | sed 's/@.*//' | grep -E "$PATTERN" | sort -u
}

echo "======================================"
echo "[LTE / 3G / 4G Modems]"
echo "======================================"
for i in $(get_ifaces "^(lte|usb|wwan|cdc|qmi)[a-zA-Z0-9_-]*"); do
    show_iface "$i" "Cellular Modem"
done

echo "======================================"
echo "[WISP / Wi-Fi Client]"
echo "======================================"
for i in $(get_ifaces "^apcli[a-z0-9]+"); do
    show_iface "$i" "WISP (Wi-Fi WAN)"
done

echo "======================================"
echo "[Ethernet / VLAN WAN]"
echo "======================================"
for i in $(get_ifaces "^(eth|vlan)[0-9]+(\.[0-9]+)?"); do
    show_iface "$i" "Ethernet or VLAN"
done

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
echo " Ready for mihomo config"
echo "======================================"
echo

if [ -n "$READY_BLOCK" ]; then
    printf "%b" "$READY_BLOCK"
else
    echo "  No active interfaces found."
fi

echo
echo "======================================"
echo " Finished"
echo "======================================"
