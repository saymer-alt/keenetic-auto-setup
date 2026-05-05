#!/bin/sh

# =========================================================
# Keenetic Auto Setup Script (MAIN)
# Production-ready installer for modern devices
# =========================================================

set -e

# -----------------------------
# CONFIG
# -----------------------------

TMP_DIR="/tmp"
LOG_TAG="[keenetic-setup]"
MIHOMO_VERSION="1.19.23-1"

# -----------------------------
# LOGGING
# -----------------------------

log() { echo "$LOG_TAG [INFO] $1"; }
warn() { echo "$LOG_TAG [WARN] $1"; }
error() { echo "$LOG_TAG [ERROR] $1"; }

# -----------------------------
# RETRY
# -----------------------------

retry() {
    ATTEMPTS=3
    COUNT=1

    while [ $COUNT -le $ATTEMPTS ]; do
        "$@" && return 0
        warn "Attempt $COUNT failed..."
        COUNT=$((COUNT + 1))
        sleep 2
    done

    return 1
}

# -----------------------------
# DETECT ARCH
# -----------------------------

detect_arch() {
    ARCH=$(opkg print-architecture | awk '/^arch/ && $2~/^(mips|mipsel|aarch64)/{
        sub(/[-_].*/,"",$2); print $2; exit
    }')

    [ -z "$ARCH" ] && error "Cannot detect architecture" && exit 1
    log "Architecture: $ARCH"
}

# -----------------------------
# BASE PACKAGES
# -----------------------------

install_base() {
    log "Updating opkg..."
    retry opkg update

    log "Installing base packages..."
    retry opkg install curl ca-bundle
}

# -----------------------------
# DOWNLOAD MIHOMO
# -----------------------------

download_mihomo() {

    case "$ARCH" in
        aarch64)
            URL_PRIMARY="https://sw.ext.io/ent/aarch64/mihomo_${MIHOMO_VERSION}_aarch64-3.10.ipk"
            URL_FALLBACK="https://github.com/saymer-alt/keenetic-auto-setup/releases/download/mihomo/mihomo_${MIHOMO_VERSION}_aarch64-3.10.ipk"
            ;;
        mipsel)
            URL_PRIMARY="https://sw.ext.io/ent/mipsel/mihomo_${MIHOMO_VERSION}_mipsel-3.4.ipk"
            URL_FALLBACK="https://github.com/saymer-alt/keenetic-auto-setup/releases/download/mihomo/mihomo_${MIHOMO_VERSION}_mipsel-3.4.ipk"
            ;;
        *)
            error "Unsupported arch: $ARCH"
            exit 1
            ;;
    esac

    log "Downloading Mihomo..."

    if retry curl -fL --connect-timeout 10 "$URL_PRIMARY" -o "$TMP_DIR/mihomo.ipk"; then
        log "Primary OK"
    else
        warn "Primary failed → fallback GitHub"

        retry curl -fL --connect-timeout 10 "$URL_FALLBACK" -o "$TMP_DIR/mihomo.ipk" || {
            error "Download failed"
            exit 1
        }
    fi
}

# -----------------------------
# INSTALL MIHOMO
# -----------------------------

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

# -----------------------------
# INSTALL WATCHDOG
# -----------------------------

install_watchdog() {
    log "Installing watchdog..."

    WD_URL="https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo_watchdog.sh"
    WD_PATH="/opt/etc/cron.5mins/mihomo_watchdog"

    retry curl -fL "$WD_URL" -o "$WD_PATH" || {
        error "Failed to download watchdog"
        return
    }

    chmod +x "$WD_PATH"

    touch /opt/var/log/mihomo_watchdog.log
    chmod 666 /opt/var/log/mihomo_watchdog.log

    if ! grep -q "cron.5mins" /opt/etc/crontab 2>/dev/null; then
        warn "Adding cron entry..."
        echo "*/5 * * * * root /opt/bin/run-parts /opt/etc/cron.5mins" >> /opt/etc/crontab
    fi

    /opt/etc/init.d/S10cron restart

    log "Watchdog installed"
}

# -----------------------------
# CHECKS
# -----------------------------

check_bin() {
    command -v "$1" >/dev/null 2>&1 && \
        echo "$LOG_TAG [OK] $1" || \
        echo "$LOG_TAG [FAIL] $1"
}

post_checks() {
    echo ""
    log "Post-checks:"
    echo "------------------------"

    check_bin curl
    check_bin mihomo
    check_bin opkg

    pgrep mihomo >/dev/null 2>&1 && \
        echo "$LOG_TAG [OK] mihomo running" || \
        echo "$LOG_TAG [WARN] mihomo not running"

    echo "------------------------"
}

# -----------------------------
# CLEANUP
# -----------------------------

cleanup() {
    rm -f "$TMP_DIR/mihomo.ipk"
}

# -----------------------------
# MAIN
# -----------------------------

main() {
    log "Start setup"

    detect_arch
    install_base
    download_mihomo
    install_mihomo
    install_watchdog
    cleanup
    post_checks

    log "Done"
}

main "$@"
