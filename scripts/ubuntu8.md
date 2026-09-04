Отлично! Давай создадим универсальный скрипт оптимизации, который можно применить на всех трёх серверах. Он будет автоматически определять текущие настройки и применять только нужные изменения.

## 🚀 Универсальный скрипт оптимизации для серверов с Mihomo

### Шаг 1: Создай скрипт на сервере

sudo nano /root/optimize_mihomo.sh

### Шаг 2: Скопируй этот код

#!/bin/bash

# ============================================
# Скрипт оптимизации сервера для Mihomo/Mieru
# Ubuntu 24.04
# ============================================

set -e

echo "========================================="
echo "🔧 Оптимизация сервера для Mihomo/Mieru"
echo "========================================="

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 1. Проверка и исправление UFW (самое важное!)
echo -e "\n${YELLOW}[1/6] Проверка UFW...${NC}"
if ufw status | grep -q "Status: active"; then
    CURRENT_OUT=$(sudo ufw status verbose | grep "Default:" | awk '{print $4}')
    if [ "$CURRENT_OUT" = "deny" ]; then
        echo -e "${RED}Обнаружен deny outgoing! Исправляем...${NC}"
        sudo ufw default allow outgoing
        sudo ufw reload
        echo -e "${GREEN}✓ Исправлено: allow outgoing${NC}"
    else
        echo -e "${GREEN}✓ Уже правильно: allow outgoing${NC}"
    fi
else
    echo -e "${YELLOW}⚠️ UFW не активен. Пропускаем...${NC}"
fi

# 2. Отключение телеметрии Ubuntu
echo -e "\n${YELLOW}[2/6] Отключение телеметрии...${NC}"
sudo systemctl disable --now ubuntu-advantage.service 2>/dev/null || true
sudo ubuntu-report -f send no 2>/dev/null || true
sudo apt purge -y ubuntu-report popularity-contest whoopsie 2>/dev/null || true
sudo sed -i 's/ENABLED=1/ENABLED=0/' /etc/default/motd-news 2>/dev/null || true
echo -e "${GREEN}✓ Телеметрия отключена${NC}"

# 3. Отключение IPv6 (если не отключён)
echo -e "\n${YELLOW}[3/6] Настройка IPv6...${NC}"
if sysctl net.ipv6.conf.all.disable_ipv6 | grep -q "= 0"; then
    sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1
    sudo sysctl -w net.ipv6.conf.default.disable_ipv6=1
    sudo sysctl -w net.ipv6.conf.lo.disable_ipv6=1
    echo -e "${GREEN}✓ IPv6 отключён${NC}"
else
    echo -e "${GREEN}✓ IPv6 уже отключён${NC}"
fi

# 4. Отключение ответа на ping (для скрытности)
echo -e "\n${YELLOW}[4/6] Настройка ping...${NC}"
if sysctl net.ipv4.icmp_echo_ignore_all | grep -q "= 0"; then
    sudo sysctl -w net.ipv4.icmp_echo_ignore_all=1
    echo -e "${GREEN}✓ Ping запрещён (сервер невидим)${NC}"
else
    echo -e "${GREEN}✓ Ping уже запрещён${NC}"
fi

# Сохраняем настройки sysctl
sudo sysctl -p 2>/dev/null || true

# 5. Оптимизация сети для mieru
echo -e "\n${YELLOW}[5/6] Сетевые оптимизации...${NC}"
cat >> /etc/sysctl.conf << 'EOF'

# Оптимизации для mieru/mihomo
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_notsent_lowat = 16384
EOF

sudo sysctl -p 2>/dev/null || true
echo -e "${GREEN}✓ Сетевые оптимизации добавлены${NC}"

# 6. Проверка и настройка SSH (опционально - ограничение по IP)
echo -e "\n${YELLOW}[6/6] Безопасность SSH...${NC}"
