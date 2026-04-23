#!/bin/sh

echo "=== Keenetic Auto Setup ==="

### 0. Basic packages
echo "[*] Installing base packages..."
opkg update
opkg install curl jq nano

### 1. Enable bypass_wa policy for opkg
echo "[*] Enabling bypass_wa policy..."
ndmc -c "policy bypass_wa opkg enable" 2>/dev/null
ndmc -c "system configuration save"

### 2. Install tmpfs script (S00ubifs)
echo "[*] Installing tmpfs optimizer..."
curl -fsSL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/S00ubifs \
-o /opt/etc/init.d/S00ubifs

chmod +x /opt/etc/init.d/S00ubifs

### 3. Start tmpfs
/opt/etc/init.d/S00ubifs start

### 4. Install Mihomo
echo "[*] Installing Mihomo..."

A=$(opkg print-architecture | awk '/^arch/ && $2~/^(mips|mipsel|aarch64)/{sub(/[-_].*/,"",$2);print $2;exit}')
U=https://sw.ext.io/ent/$A

# check access
if ! curl -fsSL "$U" >/dev/null; then
  echo "[!] WARNING: Repository not reachable (possibly blocked)"
  echo "[!] Use VPN or bypass to continue"
fi

curl -fsSL "$U/$(curl -fsSL $U/ | grep -o "mihomo_.*_${A}.*\.ipk" | sort -V | tail -1)" \
-o /tmp/mihomo.ipk

opkg install /tmp/mihomo.ipk

### 5. Setup interface
echo "[*] Configuring Proxy0 interface..."

ndmc -c "interface Proxy0"
ndmc -c "interface Proxy0 proxy protocol socks5"
ndmc -c "interface Proxy0 proxy socks5-udp"
ndmc -c "interface Proxy0 proxy upstream 127.0.0.1 7890"
ndmc -c "interface Proxy0 description mihomo"
ndmc -c "interface Proxy0 ip global auto"
ndmc -c "interface Proxy0 up"
ndmc -c "system configuration save"

### 6. Configure Mihomo
echo "[*] Opening config editor..."

mkdir -p /opt/etc/mihomo
nano /opt/etc/mihomo/config.yaml

### 7. Install MagiTrickle
echo "[*] Installing MagiTrickle..."

wget -qO- http://bin.magitrickle.dev/packages/add_repo.sh | sh
opkg update
opkg install magitrickle

/opt/etc/init.d/S99magitrickle start

### 8. Install VoIP bypass
echo "[*] Installing VoIP bypass rules..."

mkdir -p /opt/etc/ndm/netfilter.d

curl -fsSL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/020-bypass_wa.sh \
-o /opt/etc/ndm/netfilter.d/020-bypass_wa.sh

chmod +x /opt/etc/ndm/netfilter.d/020-bypass_wa.sh

### 9. Restart services
echo "[*] Restarting Mihomo..."
/opt/etc/init.d/S99mihomo restart

### 10. Diagnostics
echo ""
echo "=== Diagnostics ==="

echo "[*] tmpfs status:"
/opt/etc/init.d/S00ubifs status

echo "[*] Mihomo status:"
/opt/etc/init.d/S99mihomo status

echo "[*] MagiTrickle status:"
/opt/etc/init.d/S99magitrickle status

echo "[*] curl test:"
curl -I https://ipinfo.io 2>/dev/null | head -n 1

echo "[*] jq test:"
echo '{"test":123}' | jq '.test'

echo ""
echo "[✓] Setup complete"
