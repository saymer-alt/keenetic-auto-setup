#!/bin/sh

echo "=== Keenetic Auto Setup ==="

# Mode selection
MODE="${1:-ram}"

if [ "$MODE" != "ram" ] && [ "$MODE" != "disk" ]; then
    echo "Usage: sh deploy.sh [ram|disk]"
    exit 1
fi

echo "[*] Mode: $MODE"

CONFIG_FILE="/opt/etc/mihomo/config.yaml"

echo "[*] Installing base packages..."
opkg update
opkg install curl jq nano

# =========================
# bypass_wa policy
# =========================
echo "[*] Configuring bypass_wa policy..."

if ndmc -c "show ip policy" | grep -w -q "bypass_wa"; then
    echo "[OK] Policy 'bypass_wa' already exists. Skipping creation."
else
    echo "[+] Creating policy 'bypass_wa'..."
    ndmc -c "ip policy bypass_wa"
    ndmc -c "ip policy bypass_wa description bypass_wa"
    echo "[OK] Policy 'bypass_wa' created."
fi

# =========================
# TMPFS optimizer (RAM mode only)
# =========================
if [ "$MODE" = "ram" ]; then
    echo "[*] Installing tmpfs optimizer..."

    curl -fsSL "https://cdn.jsdelivr.net/gh/saymer-alt/keenetic-auto-setup@main/S00ubifs" \
      -o /opt/etc/init.d/S00ubifs

    if [ -f /opt/etc/init.d/S00ubifs ]; then
        chmod +x /opt/etc/init.d/S00ubifs
        /opt/etc/init.d/S00ubifs start
    else
        echo "[WARN] Failed to download S00ubifs. Skipping tmpfs setup."
    fi
else
    echo "[*] Skipping tmpfs (disk mode)"
fi

# =========================
# Mihomo install
# =========================
echo "[*] Installing Mihomo..."

ARCH=$(opkg print-architecture | awk '/^arch/ && $2~/^(mips|mipsel|aarch64)/{sub(/[-_].*/,"",$2);print $2;exit}')
REPO_URL="https://sw.ext.io/ent/$ARCH"

LATEST=$(curl -fsSL "$REPO_URL/" | grep -o "mihomo_.*_${ARCH}.*\.ipk" | sort -V | tail -1)

if [ -n "$LATEST" ]; then
    curl -fsSL "$REPO_URL/$LATEST" -o /tmp/mihomo.ipk
    if [ -f /tmp/mihomo.ipk ]; then
        opkg install /tmp/mihomo.ipk
    else
        echo "[WARN] Failed to download Mihomo package. Skipping."
    fi
else
    echo "[WARN] Could not find Mihomo package for architecture '$ARCH'. Skipping."
fi

# =========================
# Proxy0 interface
# =========================
echo "[*] Configuring Proxy0..."

if ndmc -c "show interface" | grep -w -q "Proxy0"; then
    echo "[OK] Interface Proxy0 already exists. Updating parameters..."
else
    echo "[+] Creating interface Proxy0..."
fi

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

# =========================
# Config editing
# =========================
echo "[*] Config setup..."

if [ -t 0 ] && [ -t 1 ]; then
    echo "[*] Opening nano editor..."
    nano "$CONFIG_FILE"
else
    echo "[!] Non-interactive mode"
    echo "Edit manually:"
    echo "nano $CONFIG_FILE"
fi

# =========================
# MagiTrickle
# =========================
echo "[*] Installing MagiTrickle..."

wget -qO- http://bin.magitrickle.dev/packages/add_repo.sh | sh
opkg update
opkg install magitrickle

if [ -f /opt/etc/init.d/S99magitrickle ]; then
    /opt/etc/init.d/S99magitrickle start
else
    echo "[WARN] MagiTrickle init script not found."
fi

# =========================
# VoIP bypass rules
# =========================
echo "[*] Installing VoIP bypass rules..."

mkdir -p /opt/etc/ndm/netfilter.d

curl -fsSL "https://cdn.jsdelivr.net/gh/saymer-alt/keenetic-auto-setup@main/020-bypass_wa.sh" \
  -o /opt/etc/ndm/netfilter.d/020-bypass_wa.sh

if [ -f /opt/etc/ndm/netfilter.d/020-bypass_wa.sh ]; then
    chmod +x /opt/etc/ndm/netfilter.d/020-bypass_wa.sh
else
    echo "[WARN] Failed to download 020-bypass_wa.sh. Skipping."
fi

# =========================
# Restart services
# =========================
echo "[*] Restarting Mihomo..."
if [ -f /opt/etc/init.d/S99mihomo ]; then
    /opt/etc/init.d/S99mihomo restart
else
    echo "[WARN] Mihomo init script not found. Skipping restart."
fi

# =========================
# Diagnostics
# =========================
echo ""
echo "=== Diagnostics ==="

echo "[*] tmpfs status:"
if [ "$MODE" = "ram" ]; then
    if [ -f /opt/etc/init.d/S00ubifs ]; then
        /opt/etc/init.d/S00ubifs status
    else
        echo "Not installed"
    fi
else
    echo "Skipped (disk mode)"
fi

echo "[*] Mihomo status:"
if [ -f /opt/etc/init.d/S99mihomo ]; then
    /opt/etc/init.d/S99mihomo status
else
    echo "Not installed"
fi

echo "[*] MagiTrickle status:"
if [ -f /opt/etc/init.d/S99magitrickle ]; then
    /opt/etc/init.d/S99magitrickle status
else
    echo "Not installed"
fi

echo "[*] curl test:"
curl -I -s https://ipinfo.io | head -n 1

echo "[*] jq test:"
echo '{"test":123}' | jq '.test'

echo ""
echo "[OK] Setup complete"
