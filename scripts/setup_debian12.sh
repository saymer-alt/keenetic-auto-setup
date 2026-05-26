#!/bin/bash
# =============================================
# Debian 12 Hardening для слабого VPS
# 2 ядра Intel / 1 GB RAM / 10 GB SSD
# Root-only, ключи, минимум логов
# =============================================
set -e

echo "=========================================="
echo "  Debian 12 Setup (1GB RAM / 10GB SSD)"
echo "=========================================="

# =============================================
# 1. ОБНОВЛЕНИЕ И МИНИМАЛЬНАЯ БАЗА
# =============================================
# nano вместо vim (по твоему запросу)
apt update && apt upgrade -y
apt install -y curl wget git htop nano net-tools ufw fail2ban chrony

# =============================================
# 2. SWAP 1.5 ГБ (проверенный тобой объём)
# =============================================
echo "Создаём SWAP 1.5 ГБ..."
fallocate -l 1536M /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

echo 'vm.swappiness = 10' >> /etc/sysctl.conf
echo 'vm.overcommit_memory = 1' >> /etc/sysctl.conf

# =============================================
# 3. SSH: ПОРТ 2222, ТОЛЬКО КЛЮЧИ, ROOT-ONLY
# =============================================
sed -i 's/^#*Port .*/Port 2222/' /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

cat >> /etc/ssh/sshd_config << 'EOF'

DebianBanner no
MaxAuthTries 3
LoginGraceTime 20
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

systemctl restart sshd

# =============================================
# 4. UFW: МИНИМАЛЬНЫЙ НАБОР ПОРТОВ
# =============================================
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

ufw allow 2222/tcp comment 'SSH'
ufw allow 443/tcp comment 'TeleMT + 3XUI'
ufw allow 80/tcp comment 'HTTP LE'
ufw allow 2000/tcp comment 'Mieru/Mita'
# ufw allow 39551/udp comment 'AmneziaWG'
ufw --force enable

# =============================================
# 5. SYSCTL: СЕТЬ + СКРЫТНОСТЬ
# =============================================
cat >> /etc/sysctl.conf << 'EOF'

# === Память ===
vm.swappiness = 10
vm.overcommit_memory = 1

# === TCP / BBR ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_forward = 1

# === Буферы (уменьшены для экономии RAM) ===
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.somaxconn = 4096

# === Скрытность ===
net.ipv4.icmp_echo_ignore_all = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1

# === IPv6 off ===
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

sysctl -p

# =============================================
# 6. ЛИМИТЫ ФАЙЛОВЫХ ДЕСКРИПТОРОВ
# =============================================
cat >> /etc/security/limits.conf << 'EOF'
* soft nofile 32768
* hard nofile 32768
root soft nofile 32768
root hard nofile 32768
EOF

# =============================================
# 7. FAIL2BAN: ЗАЩИТА SSH
# =============================================
cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local

cat >> /etc/fail2ban/jail.local << 'EOF'

[sshd]
enabled = true
port = 2222
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600

[recidive]
enabled = true
logpath = /var/log/fail2ban.log
banaction = iptables-allports
bantime = 86400
findtime = 3600
maxretry = 3
EOF

systemctl enable --now fail2ban

# =============================================
# 8. ЖУРНАЛИРОВАНИЕ: ЖЁСТКИЙ ЛИМИТ (КЛЮЧЕВОЕ!)
# =============================================
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-limit.conf << 'EOF'
[Journal]
Storage=persistent
SystemMaxUse=300M
MaxFileSec=1week
MaxRetentionSec=1month
Compress=yes
EOF

cat > /etc/logrotate.d/custom-limit << 'EOF'
/var/log/syslog
/var/log/messages
{
    rotate 3
    daily
    maxsize 50M
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        /bin/kill -HUP $(cat /var/run/rsyslogd.pid 2>/dev/null) 2>/dev/null || true
    endscript
}
EOF

systemctl restart systemd-journald
systemctl restart rsyslog

# =============================================
# 9. ВРЕМЯ (КРИТИЧНО ДЛЯ VPN/TLS)
# =============================================
timedatectl set-timezone Europe/Moscow
systemctl enable --now chrony

# =============================================
# 10. DOCKER
# =============================================
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker

# =============================================
# 11. ОЧИСТКА (ОСВОБОЖДАЕМ МЕСТО)
# =============================================
apt clean
apt autoremove -y

# =============================================
# 12. ФИНАЛЬНАЯ ПРОВЕРКА
# =============================================
echo ""
echo "=========================================="
echo "  ✅ НАСТРОЙКА ЗАВЕРШЕНА"
echo "=========================================="
echo ""
echo "Параметры сервера:"
echo "  SSH:        порт 2222 (только ключи, root)"
echo "  UFW:        активен, входящие закрыты"
echo "  SWAP:       1.5 ГБ (swappiness=10)"
echo "  BBR:        $(sysctl -n net.ipv4.tcp_congestion_control)"
echo "  Ping:       $(sysctl -n net.ipv4.icmp_echo_ignore_all) (1 = игнорируется)"
echo "  Journald:   лимит 300 МБ"
echo "  RAM:        $(free -h | awk '/^Mem:/{print $2}') доступно"
echo "  Disk:       $(df -h / | awk 'NR==2{print $4}') свободно"
echo ""
echo "Следующие шаги:"
echo "  1. reboot (перезагрузка)"
echo "  2. TeleMT -> 3X-UI -> Mieru -> AWG"
echo "  3. Не забудь раскомментировать порт AWG в UFW"
echo ""
echo "⚠️  Проверь SSH на порту 2222 в ДРУГОМ терминале!"
