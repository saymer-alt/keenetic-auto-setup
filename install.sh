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
# CHECK BASE
# -----------------------------
command -v opkg >/dev/null 2>&1 || {
    echo "[ERROR] opkg not found"
    exit 1
}

# -----------------------------
# BASE PACKAGES
# -----------------------------
log "Installing base packages..."

opkg update || {
    echo "[ERROR] opkg update failed"
    exit 1
}

pkg_install() {
    opkg list-installed | grep -q "^$1 " || opkg install "$1"
}

pkg_install curl
pkg_install jq
pkg_install nano
pkg_install cron

command -v jq >/dev/null || {
    echo "[ERROR] jq not installed"
    exit 1
}

# -----------------------------
# bypass_wa policy
# -----------------------------
log "Configuring bypass_wa..."

if ! ndmc -c "show ip policy" | grep -w -q "bypass_wa"; then
    ndmc -c "ip policy bypass_wa"
    ndmc -c "ip policy bypass_wa description bypass_wa"
fi

# -----------------------------
# TMPFS
# -----------------------------
if [ "$MODE" = "ram" ]; then
    log "Installing S00ubifs..."

    if retry curl -fsSL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/S00ubifs \
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

[ -z "$ARCH" ] && {
    echo "[ERROR] Cannot detect architecture"
    exit 1
}

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
        *)
            echo "[ERROR] Unsupported arch: $ARCH"
            exit 1
            ;;
    esac

    retry curl -fL "$URL" -o "$TMP_DIR/mihomo.ipk" || {
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

curl -fsSL https://bin.magitrickle.dev/packages/add_repo.sh 2>/dev/null | sh || \
wget -qO- http://bin.magitrickle.dev/packages/add_repo.sh | sh

opkg update
pkg_install magitrickle

/opt/etc/init.d/S99magitrickle start

# -----------------------------
# BYPASS RULES
# -----------------------------
log "Installing bypass rules..."

mkdir -p /opt/etc/ndm/netfilter.d

if retry curl -fsSL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/020-bypass_wa.sh \
  -o /opt/etc/ndm/netfilter.d/020-bypass_wa.sh; then

    chmod +x /opt/etc/ndm/netfilter.d/020-bypass_wa.sh
else
    log "bypass download failed"
fi

# -----------------------------
# WATCHDOG
# -----------------------------
log "Installing watchdog..."

mkdir -p /opt/etc/cron.5mins

if retry curl -fsSL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo_watchdog.sh \
  -o /opt/etc/cron.5mins/mihomo_watchdog; then

    chmod +x /opt/etc/cron.5mins/mihomo_watchdog

    mkdir -p /opt/var/log
    touch /opt/var/log/mihomo_watchdog.log
    chmod 666 /opt/var/log/mihomo_watchdog.log

    if grep -q "cron.5mins" /opt/etc/crontab 2>/dev/null; then
        log "Using run-parts"
    else
        log "Fallback to crontab"
        grep -q "mihomo_watchdog" /opt/etc/crontab 2>/dev/null || \
        echo "*/5 * * * * root /bin/sh /opt/etc/cron.5mins/mihomo_watchdog" >> /opt/etc/crontab
    fi

    /opt/etc/init.d/S10cron restart
else
    log "Watchdog download failed"
fi

# -----------------------------
# RESTART
# -----------------------------
/opt/etc/init.d/S99mihomo restart

sleep 2
netstat -tln 2>/dev/null | grep -q 7890 || \
echo "[WARN] Mihomo may not be running"

# -----------------------------
# DONE
# -----------------------------
echo "[OK] Done"
