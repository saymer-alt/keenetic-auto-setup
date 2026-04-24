markdown
# 🛡️ Keenetic Auto-Setup Suite

**One-command automation toolkit for Keenetic routers.**

Transforms a stock router into a smart gateway with VPN, intelligent routing and system optimizations.

---

## ✨ Features

* 🔒 **Modern VPN stack** — Mihomo (Clash Meta) with VLESS / Reality
* 🧠 **Smart routing** — split tunneling via MagiTrickle
* 📞 **VoIP stabilization** — fixes Telegram / WhatsApp call issues
* 💾 **Flash protection (optional)** — RAM-based tmpfs (S00ubifs)
* 💽 **Disk mode support** — optimized for SSD / USB / NVMe setups
* 🌐 **Bypass ISP restrictions** during setup and operation
* ⚡ **Fast deployment** (~2–3 minutes)

---

## 🚀 Installation

### Quick (non-interactive mode)
> ⚠️ Nano editor will **NOT** open in this mode.

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/deploy.sh | sh
```

### Full (recommended, with editor)

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/deploy.sh -o deploy.sh
sh deploy.sh
```

---

## 💽 Installation Modes

### RAM mode (default)
Recommended for routers using **internal storage**. Uses tmpfs to reduce flash wear.
```bash
sh deploy.sh
```

### Disk mode (external storage)
Recommended for USB flash, SSD, or NVMe. Disables tmpfs to preserve RAM.
```bash
sh deploy.sh disk
```

---

## ⚙️ Requirements

* Keenetic router with Entware installed
* SSH access & Internet connection
* Mihomo config (generate here): [spatiumstas.github.io/web4core/](https://spatiumstas.github.io/web4core/)

---

## 📂 Project Structure

```text
.
├── deploy.sh          # Main installer (supports ram/disk modes)
├── S00ubifs           # RAM tmpfs service (optional)
├── 020-bypass_wa.sh   # VoIP traffic marking
└── README.md          # Documentation
```

---

## 🧰 Useful Commands

**Edit Mihomo config:**
```bash
nano /opt/etc/mihomo/config.yaml
```

**Service management:**
```bash
/opt/etc/init.d/S99mihomo restart
/opt/etc/init.d/S99mihomo status
```

**Reset config:**
```bash
> /opt/etc/mihomo/config.yaml
```

---

## 📊 Diagnostics

After installation, the script verifies:
* **tmpfs status** (if enabled)
* **Mihomo & MagiTrickle** service health
* **Internet connectivity** (`curl`)
* **JSON parsing** (`jq`)

---

## 🌍 Russian Description (RU)

Скрипт автоматической настройки роутеров Keenetic «под ключ».
Настраивает VPN (Mihomo), маршрутизацию, переносит логи в RAM (опционально) и исправляет проблемы со звонками.

**Поддерживает два режима:**
* **RAM** (по умолчанию) — для внутренней памяти.
* **Disk** — для внешних накопителей (USB/SSD).

---

## 📄 License
This project is licensed under the MIT License.
