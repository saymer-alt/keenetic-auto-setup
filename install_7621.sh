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

# -----------------------------
# CHECK ENV
# -----------------------------
if ! command -v opkg >/dev/null 2>&1; then
    echo "[ERROR] Entware (opkg) not found!"
    exit 1
fi

# -----------------------------
# BASE
# -----------------------------
opkg update
opkg install curl cron

# -----------------------------
# TMPFS
# -----------------------------
if [ "$MODE" = "ram" ]; then
    log "Installing S00ubifs..."

    retry curl -L --insecure \
        https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/S00ubifs \
        -o /opt/etc/init.d/S00ubifs && \
    chmod +x /opt/etc/init.d/S00ubifs && \
    /opt/etc/init.d/S00ubifs start || \
    log "S00ubifs failed"
fi

# -----------------------------
# MIHOMO
# -----------------------------
ARCH="mipsel"

log "Installing Mihomo..."

BASE_URL="http://sw.ext.io/ent/$ARCH"

LATEST=$(curl -s "$BASE_URL/" | \
    grep -o "mihomo_.*_${ARCH}.*\.ipk" | \
    sort -V | tail -1)

if [ -n "$LATEST" ]; then
    if ! retry curl -L --insecure "$BASE_URL/$LATEST" -o "$TMP_DIR/mihomo.ipk"; then
        log "Dynamic failed → fallback"
        LATEST=""
    fi
fi

if [ -z "$LATEST" ]; then
    retry curl -L --insecure \
    "https://github.com/saymer-alt/keenetic-auto-setup/releases/download/mihomo/mihomo_${MIHOMO_VERSION}_mipsel-3.4.ipk" \
    -o "$TMP_DIR/mihomo.ipk" || {
        echo "[ERROR] Mihomo download failed"
        exit 1
    }
fi

opkg install "$TMP_DIR/mihomo.ipk" || {
    echo "[ERROR] Mihomo install failed"
    exit 1
}

# -----------------------------
# Proxy0
# -----------------------------
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

# -----------------------------
# WATCHDOG
# -----------------------------
log "Installing watchdog..."

mkdir -p /opt/etc/cron.5mins
mkdir -p /opt/var/log

retry curl -L --insecure \
  https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo_watchdog.sh \
  -o /opt/etc/cron.5mins/mihomo_watchdog || {
    log "watchdog download failed"
}

chmod +x /opt/etc/cron.5mins/mihomo_watchdog

touch /opt/var/log/mihomo_watchdog.log
chmod 666 /opt/var/log/mihomo_watchdog.log

# добавляем в cron (без дублей)
grep -q "mihomo_watchdog" /opt/etc/crontab 2>/dev/null || \
echo "*/5 * * * * root /bin/sh /opt/etc/cron.5mins/mihomo_watchdog" >> /opt/etc/crontab

[ -f /opt/etc/init.d/S10cron ] && /opt/etc/init.d/S10cron restart

# -----------------------------
# RESTART
# -----------------------------
/opt/etc/init.d/S99mihomo restart

echo "[OK] Done"
