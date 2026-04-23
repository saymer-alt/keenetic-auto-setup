# Keenetic Auto Setup

Automated setup script for Keenetic routers.
Transforms a stock router into a fully configured smart gateway with VPN, traffic routing and system optimizations.

---

## ✨ Features

* 🧠 **Smart routing (split-tunnel)** via MagiTrickle
* 🔒 **Modern VPN stack** (Mihomo with VLESS/Reality support)
* 📞 **Fixes VoIP issues** (Telegram / WhatsApp calls stability)
* 💾 **Flash wear protection** (logs and temp files moved to RAM)
* 🌐 **Bypass ISP restrictions** (updates and package installation)
* ⚡ **Fast deployment** (full setup in ~2 minutes)

---

## 🚀 Installation

Connect to your router via SSH and run:

```bash
curl -sL https://raw.githubusercontent.com/USERNAME/keenetic-auto-setup/main/install.sh | sh
```

---

## 📂 Project Structure

```
.
├── install.sh          # Main installation script
├── configs/            # Configuration files
│   ├── mihomo.yaml
│   └── magitrickle.conf
├── files/              # Additional resources (geoip, etc.)
└── README.md
```

---

## ⚙️ Requirements

* Keenetic router with Entware installed
* Internet access
* SSH access enabled

---

## 🛠 What the script does

1. Moves logs and temp files to RAM to reduce flash wear
2. Installs and configures Mihomo proxy engine
3. Creates virtual interface (`Proxy0`)
4. Applies routing rules for selective traffic tunneling
5. Fixes VoIP traffic handling
6. Ensures access to blocked resources for updates

---

## ⚠️ Disclaimer

This project is provided "as is".
Use at your own risk. Make backups before applying.

---

## 📌 Notes

* Designed for personal and small-scale deployments
* Tested on multiple Keenetic devices
* Configuration can be customized via `configs/` directory

---

## 🌍 Russian description (RU)

Скрипт автоматической настройки роутеров Keenetic “под ключ”.
Настраивает VPN, маршрутизацию, оптимизации и фиксит проблемы со звонками.

---

## 📄 License

MIT License
