# 🛡️ Keenetic Auto-Setup Suite

**One-command automation toolkit for Keenetic routers.**
Transforms a stock router into a high-performance smart gateway with VPN, intelligent routing and system optimizations.

---

## ✨ Features

* 🔒 **Modern VPN stack** — Mihomo (Clash Meta) with VLESS / Reality support
* 🧠 **Smart routing** — split tunneling via MagiTrickle
* 📞 **VoIP stabilization** — fixes Telegram / WhatsApp call issues
* 💾 **Flash protection** — RAM-based tmpfs (S00ubifs) reduces storage wear
* 🌐 **Bypass ISP restrictions** during setup and operation
* ⚡ **One-command deployment** (~2–3 minutes setup)

---

## 🚀 Installation

Connect to your router via SSH and run:

```bash
opkg update
opkg install curl
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/deploy.sh | sh

> During installation, the **nano editor will open**.
> Paste your Mihomo config, then save (**Ctrl+O → Enter**) and exit (**Ctrl+X**).

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
├── deploy.sh            # Main installer (entry point)
├── S00ubifs             # RAM tmpfs service (flash wear protection)
├── 020-bypass_wa.sh     # VoIP traffic marking (Telegram/WhatsApp)
└── README.md
```

---

## 🛠 What the script does

1. Updates package lists and installs required tools (`curl`, `jq`, `nano`)
2. Enables `bypass_wa` policy for Entware traffic
3. Installs and starts RAM tmpfs service (`S00ubifs`)
4. Downloads and installs Mihomo (auto-detects CPU architecture)
5. Creates and configures `Proxy0` interface
6. Opens nano editor for manual config input
7. Installs and starts MagiTrickle
8. Deploys VoIP bypass rules (`020-bypass_wa.sh`)
9. Restarts services
10. Runs diagnostics (services + network + JSON test)

---

## 📊 Diagnostics

After installation, the script verifies:

* tmpfs status
* Mihomo service
* MagiTrickle service
* Internet connectivity (`curl`)
* JSON parsing (`jq`)

---

## ❗ Notes

* Does **not overwrite your Mihomo config automatically**
* Designed for **safe and repeatable deployment**
* Works on multiple Keenetic models with Entware

---

## ⚠️ Disclaimer

This project is provided "as is".
Use at your own risk.

---

## 🌍 Russian Description (RU)

Скрипт автоматической настройки роутеров Keenetic «под ключ».
Устанавливает VPN (Mihomo), настраивает маршрутизацию, переносит логи в RAM и исправляет проблемы со звонками в мессенджерах.
Установка выполняется одной командой через SSH.

---

## 📄 License

MIT License
