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
# DNS TRANSIT INTERCEPTION
# ---------------------------
# Clients' classic (port 53) DNS must go through Keenetic's DNS proxy so
# MagiTrickle sees every query and can classify routes. Enabling transit
# interception redirects queries addressed straight to external resolvers
# into the system DNS profile instead of letting them bypass the router.
# This is not a DoH/DoT protection: encrypted DNS is not affected.
log "Configuring DNS transit interception..."

if ndmc -c "show running-config" 2>/dev/null | grep -q "intercept enable"; then
    log "DNS transit interception already enabled, skipping"
else
    ndmc -c "dns-proxy intercept enable" >/dev/null 2>&1 || warn "Failed to enable DNS transit interception"
    ndmc -c "system configuration save" >/dev/null 2>&1
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
# Internal Keenetic id stays Proxy0/Proxy1/... — only the human-readable
# description is set, mapped to MagiTrickle's t2s numbering (ProxyN -> t2sN).
PROXY_IFACE="Proxy0"
PROXY_DESC="mihomo t2s${PROXY_IFACE#Proxy}"

log "Configuring Proxy0..."

if ! ndmc -c "show interface ${PROXY_IFACE}" >/dev/null 2>&1; then
    ndmc -c "interface ${PROXY_IFACE}" >/dev/null 2>&1
    ndmc -c "interface ${PROXY_IFACE} proxy protocol socks5" >/dev/null 2>&1
    ndmc -c "interface ${PROXY_IFACE} proxy socks5-udp" >/dev/null 2>&1
    ndmc -c "interface ${PROXY_IFACE} proxy upstream 127.0.0.1 7890" >/dev/null 2>&1
    ndmc -c "interface ${PROXY_IFACE} description \"${PROXY_DESC}\"" >/dev/null 2>&1 || warn "Failed to set ProxyN description"
    ndmc -c "interface ${PROXY_IFACE} ip global auto" >/dev/null 2>&1
    ndmc -c "interface ${PROXY_IFACE} up" >/dev/null 2>&1
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

# ---------------------------
# POST-INSTALL SELF-CHECK
# ---------------------------
# Validates what this installer promises to install. Missing config.yaml on a
# fresh router is expected (added at the configuration stage): that is WARN,
# not FAIL, and port 7890 is only checked when a config exists.
FAILS=0
WARNS=0

check_ok()   { echo "[ok] $1"; }
check_warn() { echo "[WARN] $1"; WARNS=$((WARNS+1)); }
check_fail() { echo "[FAIL] $1"; FAILS=$((FAILS+1)); }

CONFIG="/opt/etc/mihomo/config.yaml"

# Mihomo binary + version
if [ -x /opt/bin/mihomo ] || command -v mihomo >/dev/null 2>&1; then
    MIHOMO_BIN=$(command -v mihomo 2>/dev/null || echo "/opt/bin/mihomo")
    if ${MIHOMO_BIN} -v >/dev/null 2>&1; then
        check_ok "Mihomo binary: $(${MIHOMO_BIN} -v 2>/dev/null | head -1)"
    else
        check_fail "Mihomo binary exists but 'mihomo -v' failed"
    fi
else
    check_fail "Mihomo binary not found (/opt/bin/mihomo)"
fi

# Mihomo init script
if [ -x /opt/etc/init.d/S99mihomo ]; then
    check_ok "Mihomo init script present"
else
    check_fail "Mihomo init script /opt/etc/init.d/S99mihomo missing"
fi

# Proxy0 + description (checked in running-config: deterministic text output)
if ndmc -c "show interface Proxy0" >/dev/null 2>&1; then
    check_ok "Proxy0 interface present"
    if ndmc -c "show running-config" 2>/dev/null | grep -q "mihomo t2s0"; then
        check_ok "Proxy0 description: mihomo t2s0"
    else
        check_fail "Proxy0 description is not 'mihomo t2s0'"
    fi
else
    check_fail "Proxy0 interface missing"
fi

# DNS transit interception
if ndmc -c "show running-config" 2>/dev/null | grep -q "intercept enable"; then
    check_ok "DNS transit interception enabled"
else
    check_fail "DNS transit interception (dns-proxy intercept enable) not found"
fi

# Bypass rules
if [ -x /opt/etc/ndm/netfilter.d/020-bypass_wa.sh ]; then
    check_ok "bypass rules: 020-bypass_wa.sh present"
else
    check_fail "bypass rules: /opt/etc/ndm/netfilter.d/020-bypass_wa.sh missing or not executable"
fi

# Watchdog + cron registration
if [ -x /opt/etc/cron.5mins/mihomo_watchdog ]; then
    check_ok "watchdog present"
else
    check_fail "watchdog /opt/etc/cron.5mins/mihomo_watchdog missing or not executable"
fi
if grep -q "cron.5mins" /opt/etc/crontab 2>/dev/null || grep -q "mihomo_watchdog" /opt/etc/crontab 2>/dev/null; then
    check_ok "watchdog scheduled in crontab"
else
    check_fail "watchdog not scheduled (no cron.5mins/mihomo_watchdog entry in /opt/etc/crontab)"
fi

# Cron
if [ -x /opt/etc/init.d/S10cron ]; then
    check_ok "cron init script present"
    if ps 2>/dev/null | grep -q "[c]ron"; then
        check_ok "cron is running"
    else
        check_warn "cron process not visible in ps (init script present)"
    fi
else
    check_fail "cron init script /opt/etc/init.d/S10cron missing"
fi

# MagiTrickle
if opkg list-installed 2>/dev/null | grep -q "^magitrickle "; then
    check_ok "MagiTrickle installed"
    if [ -x /opt/etc/init.d/S99magitrickle ]; then
        check_ok "MagiTrickle init script present"
    else
        check_warn "MagiTrickle init script /opt/etc/init.d/S99magitrickle missing"
    fi
else
    check_fail "MagiTrickle package not installed"
fi

# S00ubifs (ram mode only)
if [ "$MODE" = "ram" ]; then
    if [ -x /opt/etc/init.d/S00ubifs ]; then
        check_ok "S00ubifs present (ram mode)"
    else
        check_fail "S00ubifs missing (ram mode)"
    fi
fi

# Config.yaml: absence on a fresh router is expected; port 7890 only matters
# when a config exists.
if [ -f "$CONFIG" ]; then
    if ${MIHOMO_BIN} -t -d /opt/etc/mihomo -f "$CONFIG" >/dev/null 2>&1; then
        check_ok "Mihomo config syntax valid"
    else
        check_warn "Mihomo config syntax check (mihomo -t) failed"
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -tln 2>/dev/null | grep -q 7890 || check_warn "Port 7890 not listening (config exists)"
    elif command -v ss >/dev/null 2>&1; then
        ss -tln 2>/dev/null | grep -q 7890 || check_warn "Port 7890 not listening (config exists)"
    fi
else
    check_warn "config.yaml not found — expected on a fresh router; add it at the configuration stage (7890 stays down until then)"
fi

# Free space on /opt (critical low)
AVAIL_KB=$(df -k /opt 2>/dev/null | awk 'NR==2 {print $4}')
case "$AVAIL_KB" in
    ''|*[!0-9]*)
        check_warn "Cannot determine free space on /opt"
        ;;
    *)
        if [ "$AVAIL_KB" -lt 32768 ]; then
            check_warn "Low free space on /opt: ${AVAIL_KB} KB"
        else
            check_ok "Free space on /opt: ${AVAIL_KB} KB"
        fi
        ;;
esac

# Verdict
if [ "$FAILS" -gt 0 ]; then
    echo "[FAIL] $FAILS check(s) failed, $WARNS warning(s) — installation incomplete"
    exit 1
fi
if [ "$WARNS" -gt 0 ]; then
    echo "[OK] Done ($WARNS warning(s))"
else
    echo "[OK] Done"
fi
