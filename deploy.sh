#!/bin/sh

# Базовая ссылка на твой репозиторий
REPO="https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main"

echo "--- START CUSTOM DEPLOY ---"

# 1. Настройка маршрутизации для OPKG (чтобы не заблокировали скачивание)
ndmc -c "policy bypass_wa opkg enable"
opkg update
opkg install curl jq ca-certificates

# 2. Установка RAM-дисков (S00ubifs)
echo "Installing S00ubifs..."
curl -fSsL "$REPO/S00ubifs" -o /opt/etc/init.d/S00ubifs
chmod 0755 /opt/etc/init.d/S00ubifs
/opt/etc/init.d/S00ubifs start

# 3. Настройка правил трафика (020-bypass_wa.sh)
echo "Installing Netfilter rules..."
mkdir -p /opt/etc/ndm/netfilter.d
curl -fSsL "$REPO/020-bypass_wa.sh" -o /opt/etc/ndm/netfilter.d/020-bypass_wa.sh
chmod 0755 /opt/etc/ndm/netfilter.d/020-bypass_wa.sh

# 4. Настройка конфига Mihomo (config.yaml)
echo "Updating Mihomo config..."
mkdir -p /opt/etc/mihomo
curl -fSsL "$REPO/config.yaml" -o /opt/etc/mihomo/config.yaml

# 5. Применяем права и перезапускаем
chmod +x /opt/etc/init.d/S*
/opt/etc/init.d/S99mihomo restart 2>/dev/null

echo "--- DEPLOY FINISHED ---"
