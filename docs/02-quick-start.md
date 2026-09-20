# 02 — быстрый старт

Поднять всё за несколько минут.

Без углубления. Просто чтобы заработало.

---

## ⚠️ Перед началом

Проверь:

* **256+ MB RAM — поддерживаемый профиль** (512 МБ+ — самый запасной, swap опционален). 256 МБ с внутренней памятью требует активного штатного zRAM KeeneticOS; с внешним /opt swap/zRAM опциональны. 128 MB-класс допускается только как best-effort/experimental и только при внешнем /opt + внешнем storage-backed swap >= 384 МБ (512 предпочтительно; zRAM не считается; иначе — остановка на раннем preflight)
* есть доступ к shell Entware (обычно SSH; сам компонент KeeneticOS «Сервер SSH» не является runtime-зависимостью проекта)
* установлен Entware (`/opt` существует)

Если нет — сначала настрой это.

---

## 🚀 Установка

### Основной путь — универсальный `install.sh`

Автоопределение архитектуры: aarch64 / armv7 / mipsel / mips (включая MT7621).

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/install.sh | sh
```

---

### MT7621 / mipsel

Та же команда `install.sh` — отдельного установщика больше нет.

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
[OK] All good
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

### В логе watchdog: `[RESTART] …`

`[RESTART] Mihomo port unreachable` — Mihomo не слушает `7890`;
`[RESTART] Proxy tunnel check failed` — порт жив, туннель не проходит.

Проверь:

* сервер
* порт
* UUID

---

### Ничего не открывается

Проверь DNS:

```bash
ls -l /opt/etc/resolv.conf   # обычно симлинк на /etc/resolv.conf, им управляет KeeneticOS
cat /opt/etc/resolv.conf
```

⚠️ Не перезаписывай файл публичными резолверами вручную — это обход
`dns-proxy intercept` и ломает схему DNS-transit (MagiTrickle). Диагностика
и штатные пути — в [troubleshooting](08-troubleshooting.md).

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
