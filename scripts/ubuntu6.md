#!/bin/bash
# Скрипт для максимально скрытного сервера с mieru

# 1. Отключение телеметрии
echo "==> Отключение телеметрии..."
systemctl disable --now ubuntu-advantage.service 2>/dev/null
ubuntu-report -f send no
apt purge -y ubuntu-report popularity-contest apport whoopsie 2>/dev/null
sed -i 's/ENABLED=1/ENABLED=0/' /etc/default/motd-news

# 2. Настройка UFW (жесткие правила)
echo "==> Настройка фаервола..."
ufw --force reset
ufw default deny incoming
ufw default deny outgoing

# Разрешить loopback
ufw allow out on lo
ufw allow in on lo

# Базовые исходящие
ufw allow out on ens3 to any port 53 proto udp comment 'DNS'
ufw allow out on ens3 to any port 443 proto tcp comment 'HTTPS'
ufw allow out on ens3 to any port 80 proto tcp comment 'HTTP'
ufw allow out on ens3 to any port 123 proto udp comment 'NTP'

# Для mieru (замени порт)
ufw allow in on ens3 to any port 12345 proto udp comment 'Mieru'
ufw allow out on ens3 to any port 12345 proto udp comment 'Mieru'

# SSH только с твоего IP (замени)
# ufw allow in on ens3 from ТВОЙ_IP to any port 2222 proto tcp comment 'SSH'

ufw --force enable

# 3. Sysctl для скрытности
echo "==> Настройка sysctl..."
cat >> /etc/sysctl.conf << 'EOF'
# Скрытность
net.ipv4.icmp_echo_ignore_all = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.disable_ipv6 = 1

# Защита
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300

# BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

sysctl -p

echo "✅ Сервер оптимизирован для скрытной работы с mieru!"

## ⚠️ Важные замечания

1. DNS: Если DNS не работает — добавь 8.8.8.8 в /etc/resolv.conf
2. Обновления: С таким жестким UFW apt update будет работать только если разрешен порт 80 и 443
3. Тестирование: Перед применением жестких правил UFW оставь вторую SSH-сессию открытой!
4. Mieru порт: Замени 12345 на фактический порт, который будет слушать mieru

## 🎯 Итоговая конфигурация

С этими настройками твой сервер будет:
- ❌ Не отвечать на ping
- ❌ Не принимать соединения на закрытые порты (даже RST)
- ❌ Не отправлять лишний трафик наружу
- ✅ Отвечать только на mieru-протокол (который выглядит как случайный шум)
- ✅ Иметь минимальную поверхность атаки

Это именно то, что нужно для максимальной скрытности! 🔒
