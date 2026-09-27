# 02 — быстрый старт

Поднять всё за несколько минут.

Без углубления. Просто чтобы заработало.

---

## ⚠️ Перед началом

Проверь:

* **256+ MB RAM — поддерживаемый профиль.** На 256 МБ-классе проект ожидает штатный zRAM **или** внешний storage-backed swap; если нет обоих — WARN, установка продолжается. На **512 МБ-классе один из этих backend обязателен для новой установки**: нет ни zRAM, ни проверенного внешнего swap → ERROR до изменений. При внешнем swap <1× обнаруженной RAM — WARN; 1×..3× — INFO; preferred target ≈3× RAM, максимум 2 ГиБ; >2 ГиБ — ошибка новой установки. zRAM и disk/file swap одновременно по рекомендации производителя не используем. Выше 512 МБ-класса swap/zRAM опциональны. 128 MB-класс остаётся best-effort/experimental при внешнем /opt + внешнем storage-backed swap >=384 МБ.
* есть доступ к shell Entware (обычно SSH; сам компонент KeeneticOS «Сервер SSH» не является runtime-зависимостью проекта)
* установлен Entware (`/opt` существует)
* в KeeneticOS установлены **Клиент прокси** (`proxy`) и хотя бы один secure-DNS компонент: `dns-tls` **или** `dns-https`

Если нет — сначала настрой это.

---

## 🚀 Установка

### Основной путь — `setup.sh`

`setup.sh` сам определяет обычный профиль хранения (`ram`/`disk`), передаёт safety-gates каноническому `install.sh` и после успешной установки запускает безопасный Config Import. После запуска `setup.sh` дочерние project-скрипты скачиваются через устойчивую fallback-цепочку raw/curl → raw/wget → GitHub Contents API.

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/setup.sh | sh
```

Архитектура определяется автоматически: aarch64 / armv7 / mipsel / mips (включая MT7621). Отдельного MT7621-установщика больше нет.

Расширенный ручной путь с явным `ram|disk`, offline/SCP и storage override — в [подробной установке](03-install.md).

---

## 🧩 После установки (обязательно)

### 1. Импортировать конфиг Mihomo

После установки `setup.sh` сразу переходит в безопасный **Mihomo Config Import**. Создайте полный YAML в [Mihomo Unified Generator](https://saymer-alt.github.io/link-generators/), вставьте его в SSH и нажмите **Ctrl+D один раз**. Importer проверяет конфиг реальным `mihomo -t`, соблюдает one-Mihomo invariant, делает backup/atomic commit и откатывается, если сервис или порт 7890 не поднимаются.

Если на этом этапе вы выбрали skip, импорт можно запустить позже через `config-import.sh`. Ручное редактирование `nano /opt/etc/mihomo/config.yaml` остаётся advanced-путём.

Минимальный учебный пример, если нужно понять структуру:

```yaml
mixed-port: 7890
allow-lan: true
mode: rule
log-level: warning

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

### 2. Проверить, что всё работает

После успешного Config Import отдельный ручной `restart` не нужен: importer сам сохраняет исходное состояние сервиса, при работающем Mihomo запускает его с новым конфигом и проверяет порт 7890. Если Mihomo был остановлен до импорта, importer намеренно оставляет его остановленным.

Для обычного fresh-install сценария проверьте состояние:

```bash
/opt/etc/init.d/S99mihomo status
```

Должно быть:

```id="ok1"
alive
```

---

### 3. Проверить прокси

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

Должно быть примерно так:

```id="ok2"
[OK] All good | WAN=primary (...)
```

При работе через whitelist-fallback будет `WAN=whitelist (...)`.

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
