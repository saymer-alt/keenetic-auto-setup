#!/bin/sh

echo "[*] Keenetic Auto Setup"

# install dependencies
opkg update
opkg install curl jq

# create dirs
mkdir -p /opt/etc/mihomo
mkdir -p /opt/etc/init.d

# download scripts
cd /opt/etc/init.d

curl -O https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/020-bypass_wa.sh
curl -O https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/tmpfs.sh

# set permissions
chmod +x 020-bypass_wa.sh
chmod +x tmpfs.sh

echo "[✓] Scripts installed"
echo "[!] Now configure Mihomo manually"
