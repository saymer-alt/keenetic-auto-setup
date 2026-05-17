#!/bin/sh

echo "=== Keenetic Auto Setup ==="

MODE="${1:-ram}"

if [ "$MODE" != "ram" ] && [ "$MODE" != "disk" ]; then
    echo "Usage: sh install.sh [ram|disk]"
    exit 1
fi

echo "[*] Mode: $MODE"

TMP_DIR="/tmp"

log() { echo "[setup] $1"; }

retry() {
    for i in 1 2 3; do
        "$@" && return 0
        sleep 2
    done
    return 1
}

# Cleanup temp files on any exit, including Ctrl+C
trap 'rm -f "$TMP_DIR/mihomo.ipk"' EXIT INT TERM

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

# Faster than opkg list-installed | grep
pkg_install() {
    opkg status "$1" >/dev/null 2>&1 || opkg install "$1"
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
# SYSTEM INFO
# -----------------------------
log "Router: $(ndmc -c "show version" 2>/dev/null | grep -Ei 'model|hw id' | head -1 || echo "unknown")"
log "Free space on /opt: $(df -h /opt 2>/dev/null | awk 'NR==2 {print $4}' || echo "unknown")"

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
ARCH=$(opkg print-architecture | awk '/^arch/ && $2~/^(mips|mipsel|aarch64|arm)/{
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

REPO_OWNER="saymer-alt"
REPO_NAME="entware-go"

# Map Entware arch to ipk suffix in your repo
case "$ARCH" in
    aarch64*)
        IPK_SUFFIX="aarch64-3.10"
        ;;
    armv7*|arm*)
        IPK_SUFFIX="armv7-3.2"
        ;;
    mipsel*)
        IPK_SUFFIX="mipsel-3.4"
        ;;
    mips*)
        IPK_SUFFIX="mips-3.4"
        ;;
    *)
        echo "[ERROR] Unsupported arch: $ARCH"
        exit 1
        ;;
esac

log "Looking for mihomo ipk (${IPK_SUFFIX}) in ${REPO_OWNER}/${REPO_NAME}..."

# --- Primary: GitHub API (correct endpoint, no /tags/) ---
API_URL="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
ASSETS_JSON=$(retry curl -fsSL "$API_URL" 2>/dev/null) || ASSETS_JSON=""

DOWNLOAD_URL=""
if [ -n "$ASSETS_JSON" ]; then
    DOWNLOAD_URL=$(echo "$ASSETS_JSON" | jq -r --arg suffix "$IPK_SUFFIX" '
        .assets[] | select(.name | test("mihomo_.*_" + $suffix + "\\.ipk$")) | .browser_download_url
    ' 2>/dev/null | head -n 1)
fi

# --- Fallback: HTML page parsing (bypasses API rate limits) ---
# NOTE: GitHub HTML layout may change in future; this is a best-effort fallback.
if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ]; then
    log "API unavailable or rate limited, trying HTML fallback..."
    HTML_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest"
    REL_PATH=$(curl -fsSL "$HTML_URL" 2>/dev/null | \
        grep -oE 'href="[^"]*releases/download/[^"]*mihomo_.*_'${IPK_SUFFIX}'\.ipk"' | \
        head -n 1 | cut -d'"' -f2)

    if [ -n "$REL_PATH" ]; then
        DOWNLOAD_URL="https://github.com${REL_PATH}"
    fi
fi

if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ]; then
    echo "[ERROR] No mihomo ipk found for arch suffix: ${IPK_SUFFIX}"
    echo "[ERROR] Check https://github.com/${REPO_OWNER}/${REPO_NAME}/releases"
    exit 1
fi

log "Found: $(basename "$DOWNLOAD_URL")"
log "Downloading..."

retry curl -fL "$DOWNLOAD_URL" -o "$TMP_DIR/mihomo.ipk" || {
    echo "[ERROR] Failed to download mihomo ipk"
    exit 1
}

log "Installing package..."
opkg install "$TMP_DIR/mihomo.ipk" || {
    echo "[ERROR] Mihomo install failed"
    exit 1
}

rm -f "$TMP_DIR/mihomo.ipk"

# Safe version check (binary may not be in PATH immediately after install)
MIHOMO_BIN=$(command -v mihomo 2>/dev/null || echo "/opt/bin/mihomo")
log "Mihomo version: $(${MIHOMO_BIN} -v 2>/dev/null | head -1 || echo "unknown")"

# -----------------------------
# Proxy0
# -----------------------------
log "Configuring Proxy0..."

if ! ndmc -c "show interface Proxy0" >/dev/null 2>&1; then
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
else
    log "Proxy0 already exists, skipping creation"
fi

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
