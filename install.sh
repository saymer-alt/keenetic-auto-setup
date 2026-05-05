#!/bin/sh

echo "=== Keenetic Auto Setup ==="

MODE="${1:-ram}"

if [ "$MODE" != "ram" ] && [ "$MODE" != "disk" ]; then
    echo "Usage: sh install.sh [ram|disk]"
    exit 1
fi

echo "[*] Mode: $MODE"

TMP_DIR="/tmp"
MIHOMO_VERSION="1.19.23-1"

log() { echo "[setup] $1"; }

retry() {
    for i in 1 2 3; do
        "$@" && return 0
        sleep 2
    done
    return 1
}

# -----------------------------
# BASE PACKAGES
# -----------------------------
log "Installing base packages..."
opkg update
opkg install curl jq nano

# -----------------------------
# bypass_wa policy
# -----------------------------
log "Configuring bypass_wa..."

if ! ndmc -c "show ip policy" | grep -w -q "bypass_wa"; then
    ndmc -c "ip policy bypass_wa"
    ndmc -c "ip policy bypass_wa description bypass_wa"
fi

# -----------------------------
# TMPFS (RAM only)
# -----------------------------
if [ "$MODE" = "ram" ]; then
    log "Installing S00ubifs..."

    if curl -fsSL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/S00ubifs \
        -o /opt/etc/init.d/S00ubifs; then

        chmod +x /opt/etc/init.d/S00ubifs
        /opt/etc/init.d/S00ubifs start
    else
        log "S00ubifs download failed"
    fi
else
    log "Skip S00ubifs"
fi

# -----------------------------
# DETECT ARCH
# -----------------------------
ARCH=$(opkg print-architecture | awk '/^arch/ && $2~/^(mips|mipsel|aarch64)/{
    sub(/[-_].*/,"",$2); print $2; exit
}')

log "Arch: $ARCH"

# -----------------------------
# MIHOMO INSTALL
# -----------------------------
log "Installing Mihomo..."

BASE_URL="https://sw.ext.io/ent/$ARCH"

LATEST=$(curl -fsSL "$BASE_URL/" 2>/dev/null | \
    grep -o "mihomo_.*_${ARCH}.*\.ipk" | \
    sort -V | tail -1)

if [ -n "$LATEST" ]; then
    log "Latest: $LATEST"

    if ! retry curl -fL "$BASE_URL/$LATEST" -o "$TMP_DIR/mihomo.ipk"; then
        log "Dynamic failed → fallback"
        LATEST=""
    fi
fi

if [ -z "$LATEST" ]; then
    log "Fallback version..."

    case "$ARCH" in
        aarch64)
            URL="https://github.com/saymer-alt/keenetic-auto-setup/releases/download/mihomo/mihomo_${MIHOMO_VERSION}_aarch64-3.10.ipk"
            ;;
        mipsel)
            URL="https://github.com/saymer-alt/keenetic-auto-setup/releases/download/mihomo/mihomo_${MIHOMO_VERSION}_mipsel-3.4.ipk"
            ;;
    esac

    retry curl -fL "$URL" -o "$TMP_DIR/mihomo.ipk" || {
        echo "[ERROR] Mihomo download failed"
        exit 1
    }
fi

opkg install "$TMP_DIR/mihomo.ipk"

# -----------------------------
# Proxy0
# -----------------------------
log "Configuring Proxy0..."

IFACE="interface Proxy0"
for CMD in "" \
"proxy protocol socks5" \
"proxy socks5-udp" \
"proxy upstream 127.0.0.1 7890" \
"description mihomo" \
"ip global auto" \
"up"
do
    ndmc -c "$IFACE $CMD" >/dev/null 2>&1
done

ndmc -c "system configuration save"

# -----------------------------
# MAGITRICKLE
# -----------------------------
log "Installing MagiTrickle..."

wget -qO- http://bin.magitrickle.dev/packages/add_repo.sh | sh
opkg update
opkg install magitrickle
/opt/etc/init.d/S99magitrickle start

# -----------------------------
# BYPASS RULES
# -----------------------------
log "Installing bypass rules..."

mkdir -p /opt/etc/ndm/netfilter.d

curl -fsSL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/020-bypass_wa.sh \
  -o /opt/etc/ndm/netfilter.d/020-bypass_wa.sh

chmod +x /opt/etc/ndm/netfilter.d/020-bypass_wa.sh

# -----------------------------
# WATCHDOG (run-parts ONLY)
# -----------------------------
log "Installing watchdog..."

opkg install cron

mkdir -p /opt/etc/cron.5mins

if curl -fsSL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo_watchdog.sh \
  -o /opt/etc/cron.5mins/mihomo_watchdog; then

    chmod +x /opt/etc/cron.5mins/mihomo_watchdog

    touch /opt/var/log/mihomo_watchdog.log
    chmod 666 /opt/var/log/mihomo_watchdog.log

    [ -f /opt/etc/init.d/S10cron ] && /opt/etc/init.d/S10cron restart

else
    log "Watchdog download failed"
fi

# -----------------------------
# RESTART
# -----------------------------
/opt/etc/init.d/S99mihomo restart

# -----------------------------
# DIAGNOSTICS
# -----------------------------
echo ""
echo "=== Diagnostics ==="

[ "$MODE" = "ram" ] && /opt/etc/init.d/S00ubifs status || echo "[tmpfs] skip"
echo "[mihomo]" && /opt/etc/init.d/S99mihomo status
echo "[magitrickle]" && /opt/etc/init.d/S99magitrickle status
echo "[watchdog]" && ls /opt/etc/cron.5mins/mihomo_watchdog 2>/dev/null || echo "missing"
echo "[bypass]" && ls /opt/etc/ndm/netfilter.d/020-bypass_wa.sh

echo "[OK] Done"
