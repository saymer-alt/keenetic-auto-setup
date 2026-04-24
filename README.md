````markdown
# 🛡️ Keenetic Auto-Setup Suite

**One-command automation toolkit for Keenetic routers.**

Transforms a stock router into a high-performance smart gateway with VPN, intelligent routing and system optimizations.

---

## ✨ Features

- 🔒 **Modern VPN stack** — Mihomo (Clash Meta) with VLESS / Reality support  
- 🧠 **Smart routing** — split tunneling via MagiTrickle  
- 📞 **VoIP stabilization** — fixes Telegram / WhatsApp call issues  
- 💾 **Flash protection** — RAM-based tmpfs (`S00ubifs`) reduces storage wear  
- 🌐 **Bypass ISP restrictions** during setup and operation  
- ⚡ **One-command deployment** (~2–3 minutes setup)  

---

## 🚀 Installation

Connect to your router via SSH and run:
````

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/deploy.sh | sh
```


---

## 🧩 Next Steps (IMPORTANT)

After installation, you must add your Mihomo config manually:

```bash
nano /opt/etc/mihomo/config.yaml
```

Paste your config, then:

* Save: `Ctrl + O` → Enter
* Exit: `Ctrl + X`

Then restart Mihomo:

```bash
/opt/etc/init.d/S99mihomo restart
```

Check status:

```bash
/opt/etc/init.d/S99mihomo status
```

---

## ⚙️ Modes

By default, installation uses **RAM mode** (recommended for internal storage).

You can also run:

```bash
sh deploy.sh disk
```

### Modes explained:

* `ram` — uses tmpfs (reduces flash wear, recommended for internal storage)
* `disk` — disables tmpfs (recommended for external SSD / USB storage)

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

## ⚙️ Requirements

* Keenetic router
* Entware installed
* Internet access
* SSH access
* Mihomo config (generate here):

👉 [https://spatiumstas.github.io/web4core/](https://spatiumstas.github.io/web4core/)

---

## 🛠 What the script does

1. Installs required packages (`curl`, `jq`, `nano`)
2. Checks `bypass_wa` policy (non-destructive)
3. (RAM mode) mounts `/tmp`, `/var/log`, `/var/run` to RAM
4. Installs Mihomo (auto-detect CPU architecture)
5. Creates and configures `Proxy0` interface
6. Prepares config file
7. Installs and starts MagiTrickle
8. Deploys VoIP bypass rules (`020-bypass_wa.sh`)
9. Restarts services
10. Runs diagnostics

---

## 📊 Diagnostics

After installation, the script verifies:

* tmpfs status
* Mihomo service
* MagiTrickle service
* Internet connectivity (`curl`)
* JSON parsing (`jq`)

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

### Check status

```bash
/opt/etc/init.d/S99mihomo status
```

### Clear config (fast reset)

```bash
> /opt/etc/mihomo/config.yaml
```

### Remove and recreate config

```bash
rm /opt/etc/mihomo/config.yaml && touch /opt/etc/mihomo/config.yaml
```

---

## ❗ Notes

* `nano` does **not open automatically** when running via `curl | sh`
* This is expected behavior (non-interactive shell)
* Edit config manually using commands above

---

## ⚠️ Disclaimer

This project is provided "as is".
Use at your own risk.

---

## 🌍 Russian Description (RU)

Скрипт автоматической настройки роутеров Keenetic «под ключ».

Устанавливает VPN (Mihomo), настраивает маршрутизацию, переносит логи в RAM и исправляет проблемы со звонками в мессенджерах.

После установки требуется вручную вставить конфиг Mihomo через nano.

---

## 📄 License

MIT License
