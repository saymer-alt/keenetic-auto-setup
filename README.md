# 🛡️ Keenetic Auto-Setup Suite

**One-command automation toolkit for Keenetic routers (ARM + MT7621).**

Transforms a stock router into a high-performance smart gateway with VPN, smart routing, VoIP fixes and system optimizations.

---

## ✨ Features

* 🔒 **Modern VPN stack** — Mihomo (Clash Meta) with VLESS / Reality
* 🧠 **Smart routing** — MagiTrickle (split tunneling via DNS)
* 📞 **VoIP stabilization** — fixes Telegram / WhatsApp calls
* 💾 **Flash protection** — tmpfs (`S00ubifs`) reduces flash wear
* 🔄 **Self-healing** — watchdog auto-restarts Mihomo
* 🌐 **Bypass ISP restrictions** during setup and usage
* ⚡ **One-command deployment** (~2–3 minutes)

---

## 🚀 Installation

### 🟢 Modern routers (ARM — recommended)

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/install.sh | sh
```

### 💾 Install to external disk

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/install.sh | sh -s -- disk
```

---

### 🟡 Old routers (MT7621 / mipsel)

Use legacy installer (fixes broken HTTPS / curl):

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/install_7621.sh | sh
```

---

## ⚙️ Modes

| Mode            | Description                          |
| --------------- | ------------------------------------ |
| `ram` (default) | Uses tmpfs → protects internal flash |
| `disk`          | For USB / SSD storage (no tmpfs)     |

---

## 🧩 After Installation (IMPORTANT)

Add your Mihomo config:

```bash
nano /opt/etc/mihomo/config.yaml
```

Then restart:

```bash
/opt/etc/init.d/S99mihomo restart
```

Check:

```bash
/opt/etc/init.d/S99mihomo status
```

---

## 🔄 Watchdog (auto-recovery)

Installed automatically.

Checks every 5 minutes:

* Mihomo process
* proxy availability
* WAN connectivity

If something breaks → auto restart.

Logs:

```bash
cat /opt/var/log/mihomo_watchdog.log
```

---

## 📂 Project Structure

```
.
├── install.sh              # Main installer (ARM)
├── install_7621.sh         # Legacy installer (MT7621)
├── mihomo_watchdog.sh      # Auto-restart watchdog
├── S00ubifs                # tmpfs (flash protection)
├── 020-bypass_wa.sh        # VoIP bypass rules
└── README.md
```

---

## ⚙️ Requirements

* Keenetic router
* Entware installed
* Internet access
* SSH access

---

## 🛠 What the script does

1. Installs base packages (`curl`, `jq`, `nano`)
2. Creates `bypass_wa` policy (safe, non-destructive)
3. (RAM mode) enables tmpfs (`S00ubifs`)
4. Installs Mihomo:

   * tries latest version automatically
   * fallback to GitHub release
5. Configures `Proxy0` interface
6. Installs MagiTrickle
7. Deploys VoIP bypass rules (`020-bypass_wa.sh`)
8. Installs watchdog (auto-restart system)
9. Restarts services
10. Runs diagnostics

---

## 📊 Diagnostics

After install:

* Mihomo status
* MagiTrickle status
* Watchdog presence
* tmpfs status (RAM mode)

---

## 🧰 Useful Commands

### Edit config

```bash
nano /opt/etc/mihomo/config.yaml
```

### Restart Mihomo

```bash
/opt/etc/init.d/S99mihomo restart
```

### Status

```bash
/opt/etc/init.d/S99mihomo status
```

### Watchdog logs

```bash
cat /opt/var/log/mihomo_watchdog.log
```

### Check proxy

```bash
curl --proxy 127.0.0.1:7890 http://google.com/generate_204
```

---

## ❗ Notes

* `nano` does NOT open automatically (non-interactive shell)
* This is expected when using `curl | sh`
* Always edit config manually

---

## ⚠️ Known Issues

### MT7621 (old routers)

* Broken HTTPS / TLS
* curl may fail on modern servers

👉 Use `install_7621.sh`

---

## 🧠 Roadmap (next steps)

* auto-update scripts from GitHub
* centralized router control
* remote monitoring

---

## 🌍 Russian Description (RU)

Скрипт автоматической настройки роутеров Keenetic.

Устанавливает:

* Mihomo (VPN)
* MagiTrickle (маршрутизация)
* watchdog (авто-перезапуск)
* tmpfs (защита флеша)
* обход блокировок и VoIP проблем

Поддерживает:

* ARM (основной)
* MT7621 (legacy режим)

После установки нужно вручную вставить конфиг Mihomo.

---

## 📄 License

MIT License
