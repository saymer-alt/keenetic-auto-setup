#!/bin/sh

# =========================================================
# Keenetic Auto Setup Script (LEGACY - MT7621)
# Workaround for broken HTTPS / curl / TLS
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
    log "Updating opkg..."
    opkg update || warn "opkg update failed"

    log "Installing curl..."
    opkg install curl || warn "curl install failed"
}

download_mihomo() {

    # HTTP first (dirty but works)
    URL_HTTP="http://sw.ext.io/ent/mipsel/mihomo_${MIHOMO_VERSION}_mipsel-3.4.ipk"

    # GitHub fallback (may fail)
    URL_GH="https://github.com/saymer-alt/keenetic-auto-setup/releases/download/mihomo/mihomo_${MIHOMO_VERSION}_mipsel-3.4.ipk"

    log "Downloading Mihomo via HTTP..."

    if curl -L --insecure "$URL_HTTP" -o "$TMP_DIR/mihomo.ipk"; then
        log "Downloaded via HTTP"
        return
    fi

    warn "HTTP failed → trying GitHub"

    if curl -L --insecure "$URL_GH" -o "$TMP_DIR/mihomo.ipk"; then
        log "Downloaded via GitHub"
        return
    fi

    error "Download failed"
    exit 1
}

install_mihomo() {
    log "Installing Mihomo..."
    opkg install "$TMP_DIR/mihomo.ipk"

    log "Configuring Proxy0..."

    ndmc -c "interface Proxy0"
    ndmc -c "interface Proxy0 proxy protocol socks5"
    ndmc -c "interface Proxy0 proxy socks5-udp"
    ndmc -c "interface Proxy0 proxy upstream 127.0.0.1 7890"
    ndmc -c "interface Proxy0 description mihomo"
    ndmc -c "interface Proxy0 ip global auto"
    ndmc -c "interface Proxy0 up"

    ndmc -c "system configuration save"
}

post_checks() {
    echo ""
    log "Checks:"
    command -v mihomo >/dev/null && echo "[OK] mihomo" || echo "[FAIL] mihomo"
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
    cleanup
    post_checks

    log "Done"
}

main "$@"
