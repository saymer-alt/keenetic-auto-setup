# 🛡️ Keenetic Auto-Setup Suite

**One-command automation toolkit for Keenetic routers.**
Transforms a stock router into a high-performance smart gateway with VPN, intelligent routing and system optimizations.

---

## ✨ Features

* 🔒 **Modern VPN stack** — Mihomo (Clash Meta) with VLESS / Reality support
* 🧠 **Smart routing** — split tunneling via MagiTrickle
* 📞 **VoIP stabilization** — fixes Telegram / WhatsApp call issues
* 💾 **Flash protection** — RAM-based tmpfs (S00ubifs) reduces storage wear
* 🌐 **Bypass ISP restrictions**
* ⚡ **Fast deployment** (~2–3 minutes)

---

## 🚀 Installation

Connect to your router via SSH and run:

### Option 1 (recommended)

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/deploy.sh | sh
```

### Option 2 (if curl is not installed)

```bash
wget -O- https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/deploy.sh | sh
```

> During installation, the **nano editor will open**.
> Paste your Mihomo config, save (**Ctrl+O → Enter**) and exit (**Ctrl+X**).

---

## ⚙️ Requirements

* Keenetic router
* Entware installed
* Internet access
* SSH access
* Mihomo config (generate here):
  👉 https://spatiumstas.github.io/web4core/

---

## 📂 Project Structure

```
.
├── deploy.sh
├── S00ubifs
├── 020-bypass_wa.sh
└── README.md
```

---

## 🛠 What the script does

1. Installs required tools (`curl`, `jq`, `nano`)
2. Enables `bypass_wa` policy
3. Starts RAM tmpfs service (`S00ubifs`)
4. Installs Mihomo (auto-detect CPU)
5. Creates `Proxy0` interface
6. Opens nano for config input
7. Installs MagiTrickle
8. Adds VoIP rules
9. Restarts services
10. Runs diagnostics

---

## 📊 Diagnostics

Checks after install:

* tmpfs status
* Mihomo status
* MagiTrickle status
* Internet access (`curl`)
* JSON parsing (`jq`)

---

## ❗ Notes

* Does **not overwrite Mihomo config**
* Safe to re-run
* Designed for multiple routers

---

## ⚠️ Disclaimer

This project is provided "as is".
Use at your own risk.

---

## 🌍 Russian Description

Скрипт автоматической настройки роутеров Keenetic.
Настраивает VPN (Mihomo), маршрутизацию, RAM-диск и исправляет звонки в мессенджерах.

---

## 📄 License

MIT License
