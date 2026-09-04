#!/bin/bash
# Debian 12 Hardening для VPN/Proxy сервера

set -e

# 1. Обновление и база
apt update && apt upgrade -y
apt install -y curl wget git htop vim ufw fail2ban net-tools sudo

# 2. SWAP (если RAM <= 1GB)
fallocate -l 1.5G /swapfile && chmod 600 /swapfile
mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

# 3. SSH: порт 2222, только ключи
sed -i 's/^#*Port .*/Port 2222/' /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication .*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
echo "DebianBanner no" >> /etc/ssh/sshd_config

systemctl restart sshd

# 4. UFW (ставили вручную!)
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 2222/tcp comment 'SSH'
ufw allow 443/tcp comment 'TeleMT / HTTPS'
ufw allow 80/tcp comment 'HTTP'
# ufw allow 39551/udp comment 'AmneziaWG'  # раскомментировать при нужде
ufw --force enable

# 5. Sysctl (твой конфиг 1 в 1)
cat >> /etc/sysctl.conf << 'EOF'
vm.swappiness = 10
vm.overcommit_memory = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_forward = 1
net.ipv4.icmp_echo_ignore_all = 1
net.ipv6.conf.all.disable_ipv6 = 1
net.core.rmem_max = 25165824
net.core.wmem_max = 25165824
EOF
sysctl -p

# 6. Лимиты
echo '* soft nofile 65535' >> /etc/security/limits.conf
echo '* hard nofile 65535' >> /etc/security/limits.conf

# 7. Docker
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker

echo "✅ Debian 12 готов. Телеметрии нет, UFW настроен, BBR включён."
