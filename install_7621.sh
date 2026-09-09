#!/bin/sh

echo "=== Keenetic Auto Setup (7621) ==="

MODE="${1:-ram}"
TMP_DIR="/tmp"
MIHOMO_VERSION="1.19.23-1"

log() { echo "[7621] $1"; }

retry() {
    for i in 1 2 3; do
        "$@" && return 0
        sleep 2
    done
    return 1
}

opkg update || {
    echo "[ERROR] opkg update failed"
    exit 1
}

pkg_install() {
    opkg list-installed | grep -q "^$1 " || opkg install "$1"
}

pkg_install curl
pkg_install cron

# TMPFS
if [ "$MODE" = "ram" ]; then
    retry curl -L --insecure https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/S00ubifs \
        -o /opt/etc/init.d/S00ubifs && \
    chmod +x /opt/etc/init.d/S00ubifs && \
    /opt/etc/init.d/S00ubifs start
fi

ARCH="mipsel"

log "Installing Mihomo..."

BASE_URL="http://sw.ext.io/ent/$ARCH"

LATEST=$(curl -s "$BASE_URL/" | \
    grep -o "mihomo_.*_${ARCH}.*\.ipk" | \
    sort -V | tail -1)

if [ -n "$LATEST" ]; then
    if ! retry curl -L --insecure "$BASE_URL/$LATEST" -o "$TMP_DIR/mihomo.ipk"; then
        LATEST=""
    fi
fi

if [ -z "$LATEST" ]; then
    retry curl -L --insecure \
    "https://github.com/saymer-alt/keenetic-auto-setup/releases/download/mihomo/mihomo_${MIHOMO_VERSION}_mipsel-3.4.ipk" \
    -o "$TMP_DIR/mihomo.ipk" || exit 1
fi

opkg install "$TMP_DIR/mihomo.ipk" || {
    echo "[ERROR] Mihomo install failed"
    exit 1
}

# Proxy0 (internal id stays Proxy0; description maps to MagiTrickle's t2s numbering)
i="interface Proxy0"
for x in "" \
"proxy protocol socks5" \
"proxy socks5-udp" \
"proxy upstream 127.0.0.1 7890" \
"description \"mihomo t2s0\"" \
"ip global auto" \
"up"
do
    ndmc -c "$i $x" >/dev/null 2>&1
done

# DNS transit interception: classic (port 53) DNS from clients must pass
# through the router's DNS proxy instead of bypassing it via external
# resolvers. Not a DoH/DoT protection.
if ! ndmc -c "show running-config" 2>/dev/null | grep -q "intercept enable"; then
    ndmc -c "dns-proxy intercept enable" >/dev/null 2>&1
fi

ndmc -c "system configuration save"

# WATCHDOG
mkdir -p /opt/etc/cron.5mins

retry curl -L --insecure https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo_watchdog.sh \
  -o /opt/etc/cron.5mins/mihomo_watchdog

chmod +x /opt/etc/cron.5mins/mihomo_watchdog

mkdir -p /opt/var/log
touch /opt/var/log/mihomo_watchdog.log
chmod 666 /opt/var/log/mihomo_watchdog.log

if grep -q "cron.5mins" /opt/etc/crontab 2>/dev/null; then
    log "Using run-parts"
else
    grep -q "mihomo_watchdog" /opt/etc/crontab 2>/dev/null || \
    echo "*/5 * * * * root /bin/sh /opt/etc/cron.5mins/mihomo_watchdog" >> /opt/etc/crontab
fi

/opt/etc/init.d/S10cron restart

/opt/etc/init.d/S99mihomo restart

sleep 2

# ---------------------------
# POST-INSTALL SELF-CHECK
# ---------------------------
# Validates what this installer promises to install (7621 subset: no
# MagiTrickle, bypass rules or S00ubifs here). Missing config.yaml on a fresh
# router is expected: WARN, not FAIL; port 7890 only checked when it exists.
FAILS=0
WARNS=0

check_ok()   { echo "[ok] $1"; }
check_warn() { echo "[WARN] $1"; WARNS=$((WARNS+1)); }
check_fail() { echo "[FAIL] $1"; FAILS=$((FAILS+1)); }

CONFIG="/opt/etc/mihomo/config.yaml"

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

if [ -x /opt/etc/init.d/S99mihomo ]; then
    check_ok "Mihomo init script present"
else
    check_fail "Mihomo init script /opt/etc/init.d/S99mihomo missing"
fi

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

if ndmc -c "show running-config" 2>/dev/null | grep -q "intercept enable"; then
    check_ok "DNS transit interception enabled"
else
    check_fail "DNS transit interception (dns-proxy intercept enable) not found"
fi

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

if [ "$FAILS" -gt 0 ]; then
    echo "[FAIL] $FAILS check(s) failed, $WARNS warning(s) — installation incomplete"
    exit 1
fi
if [ "$WARNS" -gt 0 ]; then
    echo "[OK] Done ($WARNS warning(s))"
else
    echo "[OK] Done"
fi
