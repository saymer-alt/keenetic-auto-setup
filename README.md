````markdown
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

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/deploy.sh | sh
````

### Full (recommended, with editor)

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/deploy.sh -o deploy.sh
sh deploy.sh
```

> ⚠️ Nano editor will NOT open if script is executed via pipe (`curl | sh`)

---

## 💽 Installation Modes

### RAM mode (default)

Recommended for routers using **internal storage**.
Uses tmpfs to reduce flash wear.

```bash
sh deploy.sh
```

---

### Disk mode (external storage)

Recommended when Entware is installed on:

* USB flash
* SSD
* NVMe (via USB adapter)

Disables tmpfs to preserve RAM.

```bash
sh deploy.sh disk
```

---

## ⚙️ Requirements

* Keenetic router
* Entware installed
* SSH access
* Internet connection
* Mihomo config (generate here):
  👉 [https://spatiumstas.github.io/web4core/](https://spatiumstas.github.io/web4core/)

---

## 📂 Project Structure

```
.
├── deploy.sh            # Main installer (supports ram/disk modes)
├── S00ubifs             # RAM tmpfs service (optional)
├── 020-bypass_wa.sh     # VoIP traffic marking
└── README.md
```

---

## 🧰 Useful Commands

### Edit Mihomo config

```bash
nano /opt/etc/mihomo/config.yaml
```

---

### Restart Mihomo

```bash
/opt/etc/init.d/S99mihomo restart
```

---

### Check status

```bash
/opt/etc/init.d/S99mihomo status
```

---

## 🧹 Reset config

### Quick clear

```bash
> /opt/etc/mihomo/config.yaml
```

---

### Full reset

```bash
rm /opt/etc/mihomo/config.yaml
touch /opt/etc/mihomo/config.yaml
```

---

## 🧠 tmpfs service (RAM mode only)

```bash
/opt/etc/init.d/S00ubifs start
/opt/etc/init.d/S00ubifs stop
/opt/etc/init.d/S00ubifs status
```

---

## 📊 Diagnostics

After installation, the script verifies:

* tmpfs status (if enabled)
* Mihomo service
* MagiTrickle service
* Internet connectivity (`curl`)
* JSON parsing (`jq`)

---

## ⚠️ Notes

* `bypass_wa` policy may need to be created manually (optional)
* Mihomo config is provided by user
* Script is safe to re-run
* Designed for multi-device deployment
* Interactive editor works only in full install mode

---

## 🌍 Russian Description (RU)

Скрипт автоматической настройки роутеров Keenetic «под ключ».

Устанавливает VPN (Mihomo), настраивает маршрутизацию, переносит логи в RAM (опционально) и исправляет проблемы со звонками в мессенджерах.

Поддерживает два режима:

* RAM (по умолчанию)
* Disk (для внешних накопителей)

---

## 📄 License

MIT License
