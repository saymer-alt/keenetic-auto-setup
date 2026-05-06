#!/bin/sh

echo "=== Keenetic Auto Setup (7621) ==="

MODE="${1:-ram}"
TMP_DIR="/tmp"
MIHOMO_VERSION="1.19.23-1"

log() { echo "[7621] $1"; }

retry() {
    for i in 1 2 3; do
        "$@" && return 0
        sleep 2
    done
    return 1
}

opkg update || {
    echo "[ERROR] opkg update failed"
    exit 1
}

pkg_install() {
    opkg list-installed | grep -q "^$1 " || opkg install "$1"
}

pkg_install curl
pkg_install cron

# TMPFS
if [ "$MODE" = "ram" ]; then
    retry curl -L --insecure https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/S00ubifs \
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
    if ! retry curl -L --insecure "$BASE_URL/$LATEST" -o "$TMP_DIR/mihomo.ipk"; then
        LATEST=""
    fi
fi

if [ -z "$LATEST" ]; then
    retry curl -L --insecure \
    "https://github.com/saymer-alt/keenetic-auto-setup/releases/download/mihomo/mihomo_${MIHOMO_VERSION}_mipsel-3.4.ipk" \
    -o "$TMP_DIR/mihomo.ipk" || exit 1
fi

opkg install "$TMP_DIR/mihomo.ipk" || {
    echo "[ERROR] Mihomo install failed"
    exit 1
}

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
    ndmc -c "$i $x" >/dev/null 2>&1
done

ndmc -c "system configuration save"

# WATCHDOG
mkdir -p /opt/etc/cron.5mins

retry curl -L --insecure https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo_watchdog.sh \
  -o /opt/etc/cron.5mins/mihomo_watchdog

chmod +x /opt/etc/cron.5mins/mihomo_watchdog

mkdir -p /opt/var/log
touch /opt/var/log/mihomo_watchdog.log
chmod 666 /opt/var/log/mihomo_watchdog.log

if grep -q "cron.5mins" /opt/etc/crontab 2>/dev/null; then
    log "Using run-parts"
else
    grep -q "mihomo_watchdog" /opt/etc/crontab 2>/dev/null || \
    echo "*/5 * * * * root /bin/sh /opt/etc/cron.5mins/mihomo_watchdog" >> /opt/etc/crontab
fi

/opt/etc/init.d/S10cron restart

/opt/etc/init.d/S99mihomo restart

echo "[OK] Done"
