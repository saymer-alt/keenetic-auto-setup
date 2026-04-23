```markdown
# 🛡️ Keenetic Auto-Setup Suite

**Automated security & performance orchestration for Keenetic routers.** Transform your stock router into a high-performance smart gateway with VLESS/Reality support, intelligent routing, and system optimizations.

---

## ✨ Features

* 🔒 **Next-Gen VPN Stack**: Automated deployment of `Mihomo` (Clash Meta) with VLESS, Reality, and ShadowTLS support.
* 🧠 **Intelligent Traffic Management**: Split-tunneling via `MagiTrickle` for seamless access to global and local resources.
* 📞 **VoIP Stabilization**: Specialized Netfilter rules to fix Telegram and WhatsApp call drops under restrictive ISP environments.
* 💾 **Hardware Longevity**: Advanced RAM-disk implementation (`S00ubifs`) to prevent flash memory wear by offloading logs and temporary files.
* 🚀 **DPI Evasion**: Built-in logic to bypass ISP-level blocks during the installation process itself.
* 📊 **Live Diagnostics**: Integrated post-deployment health check for all services and connectivity.

---

## 🚀 Installation

1. Connect to your router via SSH (ensure Entware is installed).
2. Run the master deployment script:

```bash
curl -fSsL [https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/deploy.sh](https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/deploy.sh) | sh
```

*Note: During installation, the `nano` editor will open. Paste your Mihomo/Clash configuration there, save (Ctrl+O, Enter), and exit (Ctrl+X).*

---

## 📂 Project Structure

```text
.
├── deploy.sh          # Master orchestration & diagnostic script
├── S00ubifs           # RAM-disk management service
├── 020-bypass_wa.sh   # Netfilter rules for VoIP & policy marking
└── README.md          # Documentation
```

---

## ⚙️ Requirements

* Keenetic router with **Entware** installed on USB or internal storage.
* A pre-configured **Mihomo (Clash) YAML** (use any online generator).
* SSH access enabled.

---

## 🛠️ What the script does

1.  **Environment Check**: Validates `opkg` reachability and enables `bypass_wa` policy routing for the installer.
2.  **Storage Setup**: Mounts `/tmp`, `/var/log`, and `/var/run` to RAM.
3.  **Core Install**: Detects CPU architecture and installs the matching `Mihomo` binary from mirrors.
4.  **Network Integration**: Creates a `Proxy0` virtual interface and binds it to the proxy engine.
5.  **User Interaction**: Provides an interactive `nano` session for secure configuration entry.
6.  **Rule Injection**: Injects packet marking rules for UDP/VoIP traffic.
7.  **Final Audit**: Runs a diagnostic suite to verify service health and JSON parsing (`jq`).

---

## ⚠️ Disclaimer

This project is provided "as is" for educational purposes. Use at your own risk. The author is not responsible for any network instability or hardware issues.

---

## 🌍 Russian Description (RU)

Скрипт автоматической настройки роутеров Keenetic «под ключ». 
Настраивает VPN (Mihomo), обход блокировок, оптимизирует работу с памятью (RAM-disk) и исправляет проблемы со звонками в мессенджерах. Включает систему авто-диагностики после установки.

---

## 📄 License

MIT License
```
