# Keenetic Auto Setup

Automated toolkit for configuring Keenetic routers with VPN, smart routing and system optimizations.

---

## ✨ Features

* 🧠 Smart routing (split-tunneling via MagiTrickle)
* 🔒 Modern VPN stack (Mihomo with VLESS / Reality)
* 📞 VoIP fixes (Telegram / WhatsApp calls stability)
* 💾 Flash wear protection (logs moved to RAM via tmpfs)
* 🌐 Bypass ISP restrictions
* ⚡ Fast deployment (~2 minutes)

---

## 🚀 Installation

Connect to your router via SSH and run:

```bash
curl -sL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/install.sh | sh
```

---

## ⚙️ Requirements

* Keenetic router
* Entware installed
* Internet access
* SSH access

---

## 📂 Project Structure

```
.
├── install.sh              # Main installer (entry point)
├── 020-bypass_wa.sh        # VoIP traffic fixer (WhatsApp/Telegram)
├── tmpfs.sh                # RAM tmpfs optimizer
├── configs/                # Configuration files
└── README.md
```

---

## 🛠 Configuration

VPN configuration is not included by default.

You can generate a ready-to-use config here:

👉 https://spatiumstas.github.io/web4core/

After generating:

1. Copy the config
2. Open router via SSH
3. Edit file:

```bash
nano /opt/etc/mihomo/config.yaml
```

4. Paste your config and save

---

## 🧠 How it works

* tmpfs script moves logs and temp files to RAM
* Mihomo provides VPN connectivity
* MagiTrickle routes selected traffic via tunnel
* iptables script marks VoIP traffic for stable calls

---

## ❗ Notes

* Designed for personal and small-scale deployments
* Tested on multiple Keenetic routers
* Requires basic SSH access

---

## ⚠️ Disclaimer

This project is provided "as is".
Use at your own risk.

---

## 📄 License

MIT License
