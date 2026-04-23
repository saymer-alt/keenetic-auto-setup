````markdown
# 🛡️ Keenetic Auto-Setup Suite

**One-command automation toolkit for Keenetic routers.**

Transforms a stock router into a smart gateway with VPN, intelligent routing and system optimizations.

---

## ✨ Features

* 🔒 **Modern VPN stack** — Mihomo (Clash Meta) with VLESS / Reality
* 🧠 **Smart routing** — split tunneling via MagiTrickle
* 📞 **VoIP stabilization** — fixes Telegram / WhatsApp call issues
* 💾 **Flash protection** — RAM-based tmpfs (S00ubifs) reduces storage wear
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

> ⚠️ **Important:**
> Nano editor will NOT open if script is executed via pipe (`curl | sh`).
> Use full installation method for interactive setup.

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
├── deploy.sh            # Main installer (entry point)
├── S00ubifs             # RAM tmpfs service (flash wear protection)
├── 020-bypass_wa.sh     # VoIP traffic marking (Telegram/WhatsApp)
└── README.md
```

---

## 🧰 Useful Commands

### Edit Mihomo config

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

---

## 🧹 Reset config

### Quick clear (truncate file)

```bash
> /opt/etc/mihomo/config.yaml
```

### Full reset (delete and recreate)

```bash
rm /opt/etc/mihomo/config.yaml
touch /opt/etc/mihomo/config.yaml
```

---

## 🧠 tmpfs service management

```bash
/opt/etc/init.d/S00ubifs start
/opt/etc/init.d/S00ubifs stop
/opt/etc/init.d/S00ubifs status
```

---

## 📊 Diagnostics

After installation, the script verifies:

* tmpfs status
* Mihomo service
* MagiTrickle service
* Internet connectivity (`curl`)
* JSON parsing (`jq`)

---

## ⚠️ Notes

* `bypass_wa` policy should be created manually (if used)
* Mihomo config is provided by user
* Script is safe to re-run
* Designed for multi-device deployment

---

## 🌍 Russian Description (RU)

Скрипт автоматической настройки роутеров Keenetic «под ключ».

Устанавливает VPN (Mihomo), настраивает маршрутизацию, переносит логи в RAM и исправляет проблемы со звонками в мессенджерах.

Установка выполняется одной командой через SSH.

---

## 📄 License

MIT License

```
Если хочешь дальше — можно уже делать v2 (логирование, silent режим, автоконфиг), но даже сейчас у тебя уже очень приличный open-source уровень 👍
```
