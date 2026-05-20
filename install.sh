#!/bin/sh

set -e

echo "=== Keenetic Auto Setup ==="

MODE="${1:-ram}"

if [ "$MODE" != "ram" ] && [ "$MODE" != "disk" ]; then
    echo "Usage: sh install.sh [ram|disk]"
    exit 1
fi

echo "[*] Mode: $MODE"

TMP_DIR="/tmp"

log() { echo "[setup] $1"; }
warn() { echo "[WARN] $1"; }
err() { echo "[ERROR] $1"; exit 1; }

retry() {
    for i in 1 2 3; do
        "$@" && return 0
        warn "Retry $i/3 failed for: $*"
        sleep 2
    done
    return 1
}

# Cleanup temp files on any exit
trap 'rm -f "$TMP_DIR/mihomo.ipk"' EXIT INT TERM

# ---------------------------
# CHECK BASE
# ---------------------------
command -v opkg >/dev/null 2>&1 || err "opkg not found"

# ---------------------------
# OPKG UPDATE
# ---------------------------
log "Updating opkg..."
retry opkg update || err "opkg update failed"

# ---------------------------
# BASE PACKAGES (strict install)
# ---------------------------
log "Installing base packages..."

pkg_is_installed() {
    case "$1" in
        curl|jq|nano)
            command -v "$1" >/dev/null 2>&1
            ;;
        *)
            opkg list-installed 2>/dev/null | grep -q "^$1 "
            ;;
    esac
}

pkg_ensure() {
    _pkg="$1"
    if pkg_is_installed "$_pkg"; then
        log "$_pkg already installed"
        return 0
    fi
    log "Installing $_pkg..."
    opkg install "$_pkg" || err "Failed to install $_pkg"
}

pkg_ensure ca-bundle
pkg_ensure curl
pkg_ensure jq
pkg_ensure nano
pkg_ensure cron

command -v jq >/dev/null 2>&1 || err "jq not available after install"

# ---------------------------
# SYSTEM INFO
# ---------------------------
log "Router: $(ndmc -c "show version" 2>/dev/null | grep -Ei 'model|hw id' | head -1 || echo "unknown")"
log "Free space on /opt: $(df -h /opt 2>/dev/null | awk 'NR==2 {print $4}' || echo "unknown")"

# ---------------------------
# bypass_wa policy
# ---------------------------
log "Configuring bypass_wa..."

if ! ndmc -c "show ip policy" 2>/dev/null | grep -w -q "bypass_wa"; then
    ndmc -c "ip policy bypass_wa" >/dev/null 2>&1 || warn "Failed to create bypass_wa policy"
    ndmc -c "ip policy bypass_wa description bypass_wa" >/dev/null 2>&1
fi

# ---------------------------
# TMPFS
# ---------------------------
if [ "$MODE" = "ram" ]; then
    log "Installing S00ubifs..."

    if retry curl -fsSL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/S00ubifs \
        -o /opt/etc/init.d/S00ubifs; then

        chmod +x /opt/etc/init.d/S00ubifs
        /opt/etc/init.d/S00ubifs start || warn "S00ubifs start failed"
    else
        warn "S00ubifs download failed"
    fi
else
    log "Skip S00ubifs (disk mode)"
fi

# ---------------------------
# DETECT ARCH
# ---------------------------
ARCH=$(opkg print-architecture | awk '/^arch/ && $2~/^(mips|mipsel|aarch64|arm)/{
    sub(/[-_].*/,"",$2); print $2; exit
}')

[ -z "$ARCH" ] && err "Cannot detect architecture"

log "Arch: $ARCH"

# ---------------------------
# MIHOMO INSTALL
# ---------------------------
log "Installing Mihomo..."

REPO_OWNER="saymer-alt"
REPO_NAME="entware-go"

case "$ARCH" in
    aarch64*) IPK_SUFFIX="aarch64-3.10" ;;
    armv7*|arm*) IPK_SUFFIX="armv7-3.2" ;;
    mipsel*) IPK_SUFFIX="mipsel-3.4" ;;
    mips*) IPK_SUFFIX="mips-3.4" ;;
    *) err "Unsupported arch: $ARCH" ;;
esac

log "Looking for mihomo ipk (${IPK_SUFFIX}) in ${REPO_OWNER}/${REPO_NAME}..."

API_URL="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
ASSETS_JSON=$(retry curl -fsSL "$API_URL" 2>/dev/null) || ASSETS_JSON=""

DOWNLOAD_URL=""

# Primary: GitHub API + jq (без regex)
if [ -n "$ASSETS_JSON" ]; then
    DOWNLOAD_URL=$(echo "$ASSETS_JSON" | jq -r --arg suffix "$IPK_SUFFIX" '
        .assets[]? 
        | select(.name | startswith("mihomo_") and endswith("_" + $suffix + ".ipk")) 
        | .browser_download_url
    ' 2>/dev/null | head -n 1)
fi

# Fallback 1: grep/sed на API JSON
if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ]; then
    log "jq filter empty, trying grep fallback on API response..."
    if [ -n "$ASSETS_JSON" ]; then
        DOWNLOAD_URL=$(echo "$ASSETS_JSON" | grep -o '"browser_download_url": *"[^"]*mihomo_[^"]*_'${IPK_SUFFIX}'\.ipk"' | head -1 | sed 's/.*": *"//;s/"$//')
    fi
fi

# Fallback 2: повторный API fetch + grep (если первый был пустым)
if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ]; then
    log "API failed, trying direct API grep..."
    ASSETS_JSON=$(curl -fsSL "$API_URL" 2>/dev/null) || ASSETS_JSON=""
    if [ -n "$ASSETS_JSON" ]; then
        DOWNLOAD_URL=$(echo "$ASSETS_JSON" | grep -o '"browser_download_url": *"[^"]*mihomo_[^"]*_'${IPK_SUFFIX}'\.ipk"' | head -1 | sed 's/.*": *"//;s/"$//')
    fi
fi

# Fallback 3: HTML scraping
if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ]; then
    log "Trying HTML scraping..."
    HTML_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest"
    REL_PATH=$(curl -fsSL "$HTML_URL" 2>/dev/null | \
        grep -oE 'href="[^"]*releases/download/[^"]*mihomo_[^"]*_'${IPK_SUFFIX}'\.ipk"' | \
        head -n 1 | cut -d'"' -f2)
    if [ -n "$REL_PATH" ]; then
        DOWNLOAD_URL="https://github.com${REL_PATH}"
    fi
fi

[ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ] && \
    err "No mihomo ipk found for arch suffix: ${IPK_SUFFIX}. Check https://github.com/${REPO_OWNER}/${REPO_NAME}/releases"

log "Found: $(basename "$DOWNLOAD_URL")"
log "Downloading..."

retry curl -fL "$DOWNLOAD_URL" -o "$TMP_DIR/mihomo.ipk" || err "Failed to download mihomo ipk"

log "Installing package..."
opkg install "$TMP_DIR/mihomo.ipk" || err "Mihomo install failed"

rm -f "$TMP_DIR/mihomo.ipk"

MIHOMO_BIN=$(command -v mihomo 2>/dev/null || echo "/opt/bin/mihomo")
log "Mihomo version: $(${MIHOMO_BIN} -v 2>/dev/null | head -1 || echo "unknown")"

# ---------------------------
# Proxy0
# ---------------------------
log "Configuring Proxy0..."

if ! ndmc -c "show interface Proxy0" >/dev/null 2>&1; then
    ndmc -c "interface Proxy0" >/dev/null 2>&1
    ndmc -c "interface Proxy0 proxy protocol socks5" >/dev/null 2>&1
    ndmc -c "interface Proxy0 proxy socks5-udp" >/dev/null 2>&1
    ndmc -c "interface Proxy0 proxy upstream 127.0.0.1 7890" >/dev/null 2>&1
    ndmc -c "interface Proxy0 description mihomo" >/dev/null 2>&1
    ndmc -c "interface Proxy0 ip global auto" >/dev/null 2>&1
    ndmc -c "interface Proxy0 up" >/dev/null 2>&1
    ndmc -c "system configuration save" >/dev/null 2>&1
else
    log "Proxy0 already exists, skipping creation"
fi

# ---------------------------
# MAGITRICKLE
# ---------------------------
log "Installing MagiTrickle..."

curl -fsSL https://bin.magitrickle.dev/packages/add_repo.sh 2>/dev/null | sh || \
    wget -qO- http://bin.magitrickle.dev/packages/add_repo.sh | sh || \
    warn "MagiTrickle repo add failed"

opkg update || warn "opkg update after magitrickle failed"
pkg_ensure magitrickle || warn "MagiTrickle install failed"

if [ -x /opt/etc/init.d/S99magitrickle ]; then
    /opt/etc/init.d/S99magitrickle start || warn "MagiTrickle start failed"
fi

# ---------------------------
# BYPASS RULES
# ---------------------------
log "Installing bypass rules..."

mkdir -p /opt/etc/ndm/netfilter.d

if retry curl -fsSL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/020-bypass_wa.sh \
    -o /opt/etc/ndm/netfilter.d/020-bypass_wa.sh; then

    chmod +x /opt/etc/ndm/netfilter.d/020-bypass_wa.sh
else
    warn "bypass download failed"
fi

# ---------------------------
# WATCHDOG
# ---------------------------
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

    /opt/etc/init.d/S10cron restart || warn "Cron restart failed"
else
    warn "Watchdog download failed"
fi

# ---------------------------
# RESTART
# ---------------------------
if [ -x /opt/etc/init.d/S99mihomo ]; then
    /opt/etc/init.d/S99mihomo restart || warn "Mihomo restart failed"
else
    warn "S99mihomo not found, cannot restart"
fi

sleep 2
if command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | grep -q 7890 || warn "Mihomo may not be running (port 7890 not listening)"
elif command -v ss >/dev/null 2>&1; then
    ss -tln 2>/dev/null | grep -q 7890 || warn "Mihomo may not be running (port 7890 not listening)"
fi

echo "[OK] Done"
