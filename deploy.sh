#!/bin/sh
# --- Keenetic Automated Security & Optimization Suite ---
# Author: saymer-alt
# Infrastructure: Entware, Mihomo, MagiTrickle, RAM-disk
# --------------------------------------------------------

REPO_URL="https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main"

echo "--- [PHASE 0]: INITIALIZING ENVIRONMENT ---"
# Pre-configure policy routing for OPKG to bypass ISP blocks immediately
ndmc -c "policy bypass_wa opkg enable"
ndmc -c "system configuration save"
opkg update
opkg install curl jq ca-certificates ca-bundle nano wget-nossl
echo "Core tools installed: curl, jq, nano."

echo "--- [PHASE 1]: STORAGE OPTIMIZATION ---"
# Download and install RAM-disk management script
curl -fSsL "$REPO_URL/S00ubifs" -o /opt/etc/init.d/S00ubifs
chmod 0755 /opt/etc/init.d/S00ubifs
/opt/etc/init.d/S00ubifs start
echo "RAM-disk (S00ubifs) deployed and started."

echo "--- [PHASE 2]: MIHOMO CORE INSTALLATION ---"
# Checking accessibility of the external repository
if ! curl -Is https://sw.ext.io/ent/ | grep -q "200 OK"; then
    echo "!!! WARNING: sw.ext.io is unreachable (possibly blocked by ISP/RCN) !!!"
    echo "Please ensure your bypass_wa policy has a working VPN tunnel."
else
    # Auto-detect architecture and install latest Mihomo
    ARCH=$(opkg print-architecture | awk '/^arch/ && $2~/^(mips|mipsel|aarch64)/{sub(/[-_].*/,"",$2);print $2;exit}')
    DOWNLOAD_URL="https://sw.ext.io/ent/$ARCH"
    PACKAGE=$(curl -fsSL $DOWNLOAD_URL/ | grep -o "mihomo_.*_${ARCH}.*\.ipk" | sort -V | tail -1)
    
    echo "Downloading $PACKAGE for $ARCH..."
    curl -fsSL "$DOWNLOAD_URL/$PACKAGE" -o /tmp/m.ipk
    opkg install /tmp/m.ipk
    
    # Configure Keenetic Proxy Interface
    for cmd in "" "proxy protocol socks5" "proxy socks5-udp" "proxy upstream 127.0.0.1 7890" "description mihomo" "ip global auto" "up"; do
        ndmc -c "interface Proxy0 $cmd"
    done
    ndmc -c "system configuration save"
fi

echo "--- [PHASE 3]: CONFIGURATION INTERFACE ---"
echo "Opening NANO editor for Mihomo config..."
echo "PASTE YOUR CONFIG NOW, THEN PRESS CTRL+O (Save) and CTRL+X (Exit)"
sleep 3
mkdir -p /opt/etc/mihomo
nano /opt/etc/mihomo/config.yaml

echo "--- [PHASE 4]: NETWORK VOIP & BYPASS RULES ---"
# Deploying netfilter rules for WhatsApp/Telegram/VoIP
mkdir -p /opt/etc/ndm/netfilter.d
curl -fSsL "$REPO_URL/020-bypass_wa.sh" -o /opt/etc/ndm/netfilter.d/020-bypass_wa.sh
chmod 0755 /opt/etc/ndm/netfilter.d/020-bypass_wa.sh
echo "Netfilter traffic redirection rules deployed."

echo "--- [PHASE 5]: MAGITRICKLE SERVICE ---"
wget -qO- http://bin.magitrickle.dev/packages/add_repo.sh | sh
opkg update && opkg install magitrickle
/opt/etc/init.d/S99magitrickle start
echo "MagiTrickle installed and started."

echo "--- [PHASE 6]: FINAL RESTART & SYSTEM DIAGNOSTIC ---"
/opt/etc/init.d/S99mihomo restart
sleep 2

echo "================ SYSTEM STATUS REPORT ================"
# 1. Check RAM-Disk Status
/opt/etc/init.d/S00ubifs status | grep -q "mounted" && echo "[OK] RAM-Disk: Mounted" || echo "[FAIL] RAM-Disk: Not found"

# 2. Check Netfilter Rules
[ -f /opt/etc/ndm/netfilter.d/020-bypass_wa.sh ] && echo "[OK] VoIP Rules: Deployed" || echo "[FAIL] VoIP Rules: Missing"

# 3. Check Mihomo Service
/opt/etc/init.d/S99mihomo status | grep -q "alive" && echo "[OK] Mihomo: Running" || echo "[FAIL] Mihomo: Stopped"

# 4. Check MagiTrickle Service
/opt/etc/init.d/S99magitrickle status | grep -q "alive" && echo "[OK] MagiTrickle: Running" || echo "[FAIL] MagiTrickle: Stopped"

# 5. JSON/Connectivity Probe
echo "Testing JSON Intelligence & Connectivity..."
IP_TEST=$(curl -kfsS https://ipinfo.io | jq -r '.ip' 2>/dev/null)
if [ -n "$IP_TEST" ]; then
    echo "[OK] Internet Check: Access Granted (IP: $IP_TEST)"
else
    echo "[!] Internet Check: No Response (Check your config/VPN)"
fi
echo "======================================================"
echo "Setup finished. Secret Instruction executed."
