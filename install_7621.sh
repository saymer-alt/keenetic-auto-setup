#!/bin/sh

# =========================================================
# Keenetic Auto Setup Script (LEGACY - MT7621)
# =========================================================

set -e

TMP_DIR="/tmp"
LOG_TAG="[keenetic-7621]"
MIHOMO_VERSION="1.19.23-1"

log() { echo "$LOG_TAG [INFO] $1"; }
warn() { echo "$LOG_TAG [WARN] $1"; }
error() { echo "$LOG_TAG [ERROR] $1"; }

detect_arch() {
    ARCH=$(opkg print-architecture | awk '/^arch/ && $2~/^(mips|mipsel)/{
        sub(/[-_].*/,"",$2); print $2; exit
    }')

    [ -z "$ARCH" ] && error "Cannot detect arch" && exit 1
    log "Architecture: $ARCH"
}

install_base() {
    opkg update || warn "opkg update failed"
    opkg install curl || warn "curl install failed"
}

download_mihomo() {

    URL_HTTP="http://sw.ext.io/ent/mipsel/mihomo_${MIHOMO_VERSION}_mipsel-3.4.ipk"
    URL_GH="https://github.com/saymer-alt/keenetic-auto-setup/releases/download/mihomo/mihomo_${MIHOMO_VERSION}_mipsel-3.4.ipk"

    log "Downloading Mihomo (HTTP)..."

    if curl -L --insecure "$URL_HTTP" -o "$TMP_DIR/mihomo.ipk"; then
        log "HTTP OK"
        return
    fi

    warn "HTTP failed → GitHub"

    if curl -L --insecure "$URL_GH" -o "$TMP_DIR/mihomo.ipk"; then
        log "GitHub OK"
        return
    fi

    error "Download failed"
    exit 1
}

install_mihomo() {
    opkg install "$TMP_DIR/mihomo.ipk"

    ndmc -c "interface Proxy0"
    ndmc -c "interface Proxy0 proxy protocol socks5"
    ndmc -c "interface Proxy0 proxy socks5-udp"
    ndmc -c "interface Proxy0 proxy upstream 127.0.0.1 7890"
    ndmc -c "interface Proxy0 description mihomo"
    ndmc -c "interface Proxy0 ip global auto"
    ndmc -c "interface Proxy0 up"

    ndmc -c "system configuration save"
}

install_watchdog() {
    WD_URL="https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo_watchdog.sh"
    WD_PATH="/opt/etc/cron.5mins/mihomo_watchdog"

    curl -L --insecure "$WD_URL" -o "$WD_PATH" || return

    chmod +x "$WD_PATH"

    touch /opt/var/log/mihomo_watchdog.log
    chmod 666 /opt/var/log/mihomo_watchdog.log

    grep -q "cron.5mins" /opt/etc/crontab 2>/dev/null || \
        echo "*/5 * * * * root /opt/bin/run-parts /opt/etc/cron.5mins" >> /opt/etc/crontab

    /opt/etc/init.d/S10cron restart
}

cleanup() {
    rm -f "$TMP_DIR/mihomo.ipk"
}

main() {
    log "Start LEGACY setup"

    detect_arch
    install_base
    download_mihomo
    install_mihomo
    install_watchdog
    cleanup

    log "Done"
}

main "$@"
