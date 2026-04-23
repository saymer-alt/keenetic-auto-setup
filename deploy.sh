#!/bin/sh

echo "=== Keenetic Auto Setup ==="

CONFIG_FILE="/opt/etc/mihomo/config.yaml"

echo "[*] Installing base packages..."
opkg update
opkg install curl jq nano

echo "[*] Checking bypass_wa policy..."
ndmc -c "ip policy bypass_wa" >/dev/null 2>&1 || {
    echo "[!] Policy 'bypass_wa' not found"
    echo "[!] Create it manually in Web UI if needed"
}

echo "[*] Installing tmpfs optimizer..."
curl -fsSL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/S00ubifs \
  -o /opt/etc/init.d/S00ubifs
chmod +x /opt/etc/init.d/S00ubifs
/opt/etc/init.d/S00ubifs start

echo "[*] Installing Mihomo..."
A=$(opkg print-architecture | awk '/^arch/ && $2~/^(mips|mipsel|aarch64)/{sub(/[-_].*/,"",$2);print $2;exit}')
U=https://sw.ext.io/ent/$A
curl -fsSL "$U/$(curl -fsSL $U/ | grep -o "mihomo_.*_${A}.*\.ipk" | sort -V | tail -1)" \
  -o /tmp/m.ipk
opkg install /tmp/m.ipk

echo "[*] Configuring Proxy0..."
i="interface Proxy0"
for x in "" \
"proxy protocol socks5" \
"proxy socks5-udp" \
"proxy upstream 127.0.0.1 7890" \
"description mihomo" \
"ip global auto" \
"up"
do
  ndmc -c "$i $x"
done
ndmc -c "system configuration save"

echo "[*] Config setup..."

if [ -t 0 ] && [ -t 1 ]; then
    echo "[*] Opening nano editor..."
    nano "$CONFIG_FILE"
else
    echo "[!] Non-interactive mode"
    echo "Edit manually:"
    echo "nano $CONFIG_FILE"
fi

echo "[*] Installing MagiTrickle..."
wget -qO- http://bin.magitrickle.dev/packages/add_repo.sh | sh
opkg update
opkg install magitrickle
/opt/etc/init.d/S99magitrickle start

echo "[*] Installing VoIP bypass rules..."
mkdir -p /opt/etc/ndm/netfilter.d
curl -fsSL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/020-bypass_wa.sh \
  -o /opt/etc/ndm/netfilter.d/020-bypass_wa.sh
chmod +x /opt/etc/ndm/netfilter.d/020-bypass_wa.sh

echo "[*] Restarting Mihomo..."
/opt/etc/init.d/S99mihomo restart

echo ""
echo "=== Diagnostics ==="

/opt/etc/init.d/S00ubifs status
/opt/etc/init.d/S99mihomo status
/opt/etc/init.d/S99magitrickle status

echo "[*] curl test:"
curl -I https://ipinfo.io | head -n 1

echo "[*] jq test:"
echo '{"test":123}' | jq '.test'

echo ""
echo "[✓] Setup complete"
