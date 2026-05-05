#!/bin/sh

# =========================================================
# Keenetic Auto Setup Script
# Author: Saymer
# Description: Automated installation of required packages
#              and Mihomo on Keenetic routers
# =========================================================

set -e

# -----------------------------
# CONFIGURATION
# -----------------------------

REPO="https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main"
TMP_DIR="/tmp"
LOG_TAG="[keenetic-setup]"

# Mihomo version (manual control)
MIHOMO_VERSION="1.19.23-1"

# -----------------------------
# LOGGING FUNCTIONS
# -----------------------------

log() {
    echo "$LOG_TAG [INFO] $1"
}

warn() {
    echo "$LOG_TAG [WARN] $1"
}

error() {
    echo "$LOG_TAG [ERROR] $1"
}

# -----------------------------
# DETECT ARCHITECTURE
# -----------------------------

detect_arch() {
    ARCH=$(opkg print-architecture | awk '/^arch/ && $2~/^(mips|mipsel|aarch64)/{
        sub(/[-_].*/,"",$2); print $2; exit
    }')

    if [ -z "$ARCH" ]; then
        error "Failed to detect architecture"
        exit 1
    fi

    log "Detected architecture: $ARCH"
}

# -----------------------------
# INSTALL BASE PACKAGES
# -----------------------------

install_base() {
    log "Updating package lists..."
    opkg update

    log "Installing base packages..."
    opkg install curl ca-bundle

    log "Base packages installed"
}

# -----------------------------
# DOWNLOAD MIHOMO
# -----------------------------

download_mihomo() {

    case "$ARCH" in
        aarch64)
            URL_PRIMARY="https://sw.ext.io/ent/aarch64/mihomo_${MIHOMO_VERSION}_aarch64-3.10.ipk"
            URL_FALLBACK="https://github.com/saymer-alt/keenetic-auto-setup/releases/download/mihomo/mihomo_${MIHOMO_VERSION}_aarch64.ipk"
            ;;
        mipsel)
            URL_PRIMARY="https://sw.ext.io/ent/mipsel/mihomo_${MIHOMO_VERSION}_mipsel-3.4.ipk"
            URL_FALLBACK="https://github.com/saymer-alt/keenetic-auto-setup/releases/download/mihomo/mihomo_${MIHOMO_VERSION}_mipsel.ipk"
            ;;
        *)
            error "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac

    log "Downloading Mihomo (primary source)..."

    if curl -fL --connect-timeout 10 "$URL_PRIMARY" -o "$TMP_DIR/mihomo.ipk"; then
        log "Downloaded Mihomo from primary source"
    else
        warn "Primary download failed, trying fallback..."

        if curl -fL --connect-timeout 10 "$URL_FALLBACK" -o "$TMP_DIR/mihomo.ipk"; then
            log "Downloaded Mihomo from fallback (GitHub)"
        else
            error "Failed to download Mihomo"
            exit 1
        fi
    fi
}

# -----------------------------
# INSTALL MIHOMO
# -----------------------------

install_mihomo() {
    log "Installing Mihomo package..."
    opkg install "$TMP_DIR/mihomo.ipk"

    log "Configuring interface Proxy0..."

    ndmc -c "interface Proxy0"
    ndmc -c "interface Proxy0 proxy protocol socks5"
    ndmc -c "interface Proxy0 proxy socks5-udp"
    ndmc -c "interface Proxy0 proxy upstream 127.0.0.1 7890"
    ndmc -c "interface Proxy0 description mihomo"
    ndmc -c "interface Proxy0 ip global auto"
    ndmc -c "interface Proxy0 up"

    ndmc -c "system configuration save"

    log "Mihomo installed and interface configured"
}

# -----------------------------
# POST-INSTALL CHECKS
# -----------------------------

check_bin() {
    command -v "$1" >/dev/null 2>&1 && \
        echo "$LOG_TAG [OK] $1" || \
        echo "$LOG_TAG [FAIL] $1"
}

post_checks() {
    echo ""
    log "Running post-install checks..."
    echo "--------------------------------"

    check_bin curl
    check_bin mihomo
    check_bin opkg

    if pgrep mihomo >/dev/null 2>&1; then
        echo "$LOG_TAG [OK] mihomo running"
    else
        echo "$LOG_TAG [WARN] mihomo not running"
    fi

    echo "--------------------------------"
}

# -----------------------------
# CLEANUP
# -----------------------------

cleanup() {
    log "Cleaning up temporary files..."
    rm -f "$TMP_DIR/mihomo.ipk"
}

# -----------------------------
# MAIN EXECUTION
# -----------------------------

main() {
    log "Starting Keenetic setup..."

    detect_arch
    install_base
    download_mihomo
    install_mihomo
    cleanup
    post_checks

    log "Setup completed"
}

main "$@"
