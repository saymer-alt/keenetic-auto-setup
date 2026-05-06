# 02 — быстрый старт

Поднять всё за несколько минут.

Без углубления. Просто чтобы заработало.

---

## ⚠️ Перед началом

Проверь:

* у тебя **256+ MB RAM**
* есть доступ по SSH (`root`)
* установлен Entware (`/opt` существует)

Если нет — сначала настрой это.

---

## 🚀 Установка

### Современные роутеры (ARM)

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/install.sh | sh
```

---

### Старые роутеры (MT7621)

Если предыдущая команда падает (SSL / curl ошибки):

```bash
curl -k -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/install_7621.sh | sh
```

---

## 🧩 После установки (обязательно)

### 1. Добавить конфиг Mihomo

```bash
nano /opt/etc/mihomo/config.yaml
```

Минимальный пример:

```yaml
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info

proxies:
  - name: "server"
    type: vless
    server: "YOUR_SERVER"
    port: 443
    uuid: "YOUR_UUID"
    tls: true

proxy-groups:
  - name: "Proxy"
    type: select
    proxies:
      - "server"

rules:
  - GEOIP,private,DIRECT
  - MATCH,Proxy
```

---

### 2. Перезапустить Mihomo

```bash
/opt/etc/init.d/S99mihomo restart
```

---

### 3. Проверить, что всё работает

```bash
/opt/etc/init.d/S99mihomo status
```

Должно быть:

```id="ok1"
alive
```

---

### 4. Проверить прокси

```bash
curl -x socks5://127.0.0.1:7890 https://ipinfo.io
```

Если виден внешний IP — всё ок.

---

## 🐶 Проверка watchdog

Через 5 минут:

```bash
cat /opt/var/log/mihomo_watchdog.log
```

Должно быть:

```id="ok2"
OK
```

---

## 📞 Проверка VoIP

Сделай звонок в Telegram / WhatsApp.

Если:

* не лагает
* соединяется быстро

→ bypass_wa работает

---

## ❗ Типичные ошибки

### Mihomo не стартует

```bash
/opt/etc/init.d/S99mihomo status
```

→ почти всегда проблема в `config.yaml`

---

### `proxy fail [000/000]`

→ прокси не отвечает

Проверь:

* сервер
* порт
* UUID

---

### Ничего не открывается

Проверь DNS:

```bash
cat /opt/etc/resolv.conf
```

Если пусто:

```bash
echo "nameserver 1.1.1.1" > /opt/etc/resolv.conf
```

---

## 💡 Важно

* Без `config.yaml` ничего работать не будет
* Watchdog чинит только Mihomo, не сервер
* Первый запуск лучше делать с доступом к роутеру

---

## Дальше

Если всё заработало:

→ смотри `03-install.md` (что именно поставилось)
→ или `08-troubleshooting.md`, если что-то сломалось
