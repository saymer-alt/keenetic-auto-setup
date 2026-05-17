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

REPO_OWNER="saymer-alt"
REPO_NAME="entware-go"
RELEASE_TAG="latest"

# Map Entware arch to ipk suffix in your repo
case "$ARCH" in
    aarch64)
        IPK_SUFFIX="aarch64-3.10"
        ;;
    arm|armv7)
        IPK_SUFFIX="armv7-3.2"
        ;;
    mipsel)
        IPK_SUFFIX="mipsel-3.4"
        ;;
    mips)
        IPK_SUFFIX="mips-3.4"
        ;;
    *)
        echo "[ERROR] Unsupported arch: $ARCH"
        exit 1
        ;;
esac

log "Looking for mihomo ipk (${IPK_SUFFIX}) in ${REPO_OWNER}/${REPO_NAME}..."

# Fetch release assets via GitHub API
ASSETS_JSON=$(retry curl -fsSL "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/tags/${RELEASE_TAG}" 2>/dev/null) || {
    echo "[ERROR] Failed to fetch release info from GitHub API"
    exit 1
}

# Extract matching asset download URL
DOWNLOAD_URL=$(echo "$ASSETS_JSON" | jq -r --arg suffix "$IPK_SUFFIX" '
    .assets[] | select(.name | test("mihomo_.*_" + $suffix + "\\.ipk$")) | .browser_download_url
' | head -n 1)

if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ]; then
    echo "[ERROR] No mihomo ipk found for arch suffix: ${IPK_SUFFIX}"
    echo "[ERROR] Check https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/tag/${RELEASE_TAG}"
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
