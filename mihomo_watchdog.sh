#!/bin/sh

echo "=== Keenetic Auto Setup (7621) ==="

MODE="${1:-ram}"
TMP_DIR="/tmp"
MIHOMO_VERSION="1.19.23-1"

log() { echo "[7621] $1"; }

opkg update
opkg install curl cron

# TMPFS
if [ "$MODE" = "ram" ]; then
    curl -L --insecure https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/S00ubifs \
        -o /opt/etc/init.d/S00ubifs && \
    chmod +x /opt/etc/init.d/S00ubifs && \
    /opt/etc/init.d/S00ubifs start
fi

ARCH="mipsel"

log "Installing Mihomo..."

BASE_URL="http://sw.ext.io/ent/$ARCH"

LATEST=$(curl -s "$BASE_URL/" | \
    grep -o "mihomo_.*_${ARCH}.*\.ipk" | \
    sort -V | tail -1)

if [ -n "$LATEST" ]; then
    if ! curl -L --insecure "$BASE_URL/$LATEST" -o "$TMP_DIR/mihomo.ipk"; then
        LATEST=""
    fi
fi

if [ -z "$LATEST" ]; then
    curl -L --insecure \
    "https://github.com/saymer-alt/keenetic-auto-setup/releases/download/mihomo/mihomo_${MIHOMO_VERSION}_mipsel-3.4.ipk" \
    -o "$TMP_DIR/mihomo.ipk" || exit 1
fi

opkg install "$TMP_DIR/mihomo.ipk"

# Proxy0
i="interface Proxy0"
for x in "" \
"proxy protocol socks5" \
"proxy socks5-udp" \
"proxy upstream 127.0.0.1 7890" \
"description mihomo" \
"ip global auto" \
"up"
do
    ndmc -c "$i $x"
done

ndmc -c "system configuration save"

# WATCHDOG (run-parts)
mkdir -p /opt/etc/cron.5mins

curl -L --insecure https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo_watchdog.sh \
  -o /opt/etc/cron.5mins/mihomo_watchdog

chmod +x /opt/etc/cron.5mins/mihomo_watchdog

touch /opt/var/log/mihomo_watchdog.log
chmod 666 /opt/var/log/mihomo_watchdog.log

[ -f /opt/etc/init.d/S10cron ] && /opt/etc/init.d/S10cron restart

/opt/etc/init.d/S99mihomo restart

echo "[OK] Done"
