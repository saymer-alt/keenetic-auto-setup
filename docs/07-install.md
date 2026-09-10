# install.sh и install_7621.sh

Как работает установка и какой скрипт использовать.

---

## Быстрый выбор

👉 Если не хочешь читать:

| Ситуация | Скрипт |
|----------|--------|
| Любая поддерживаемая архитектура (aarch64 / armv7 / mipsel / mips) | install.sh |
| MT7621, если install.sh не проходит | install_7621.sh |

---

## Как понять, что у тебя

```bash
opkg print-architecture | awk '/^arch/{print $2}'
```

Примеры:
- `aarch64-3.10` → install.sh (основной путь)
- `mipsel-3.4` → тоже начните с install.sh; если на вашем MT7621 он не проходит → install_7621.sh

---

## Общая логика установки

install.sh делает всё:

1. opkg update
2. Установка базовых пакетов
3. Создание bypass_wa
4. Установка S00ubifs
5. Установка Mihomo
6. Настройка Proxy0
7. Установка MagiTrickle
8. Установка watchdog
9. Финальная проверка (порт 7890)

install_7621.sh — сокращённая версия:

* базовые пакеты: только `curl` и `cron`
* S00ubifs + Mihomo + Proxy0 + watchdog
* ❌ НЕ ставит MagiTrickle
* ❌ НЕ создаёт policy bypass_wa
* ❌ НЕ ставит 020-bypass_wa.sh (VoIP-обход)

---

## install.sh (основной)

### Для кого

- Keenetic Giga / Ultra / Hero / Viva и другие совместимые
- aarch64 / armv7 (также mipsel/mips — mipsel-путь давно не проходил повторное тестирование)
- 256MB+ RAM

---

### Что делает лучше

#### 1. Нормальный HTTPS

```bash
curl -fSsL https://...
````

✔ проверка сертификатов
✔ безопасная загрузка

---

#### 2. Автоопределение архитектуры

```bash id="o4u3s9"
ARCH=$(opkg print-architecture | awk '/^arch/ && $2~/^(mips|mipsel|aarch64|arm)/{
    sub(/[-_].*/,"",$2); print $2; exit
}')
```

---

#### 3. Получение последней версии Mihomo

Пакет берётся из релизов `saymer-alt/entware-go`:

```bash id="a2l9re"
https://api.github.com/repos/saymer-alt/entware-go/releases/latest
```

✔ всегда свежая версия
✔ без хардкода

---

#### 4. Fallback

Если GitHub API не отвечает или jq не нашёл пакет:

👉 grep по JSON → повторный запрос → парсинг HTML-страницы релизов

---

## install_7621.sh (для MT7621)

### Для кого

* MT7621 / MT7628
* совместимые старые Keenetic
* когда универсальный install.sh не проходит (например, ошибки SSL)

---

### Наблюдаемая проблема этих роутеров

👉 TLS-сбои при скачивании («curl: (60)» и друзья); подтверждены ли они свойством платформы — нет

---

### Поэтому используется

```bash id="y3h8ka"
curl --insecure
```

---

### Что это значит

* TLS есть
* НО сертификаты не проверяются

---

### Риски

⚠ MITM-атака теоретически возможна

---

### Почему это осознанный трейдофф

* скачивание только с известных источников
* если универсальный install.sh на устройстве проходит — используйте его; install_7621.sh — запасной путь

---

## Ключевые отличия

|             | install.sh | install_7621.sh |
| ----------- | ---------- | --------------- |
| TLS         | строгий    | insecure        |
| Архитектура | авто       | mipsel          |
| Состав      | полный (MagiTrickle, bypass_wa, VoIP) | только Mihomo + Proxy0 + S00ubifs + watchdog |
| Fallback    | есть       | минимальный     |
| Надёжность  | высокая    | компромисс      |

---

## Самая частая проблема №1 — DNS

### Симптом

```bash
curl: (6) Could not resolve host
```

---

### Причина

👉 DNS не работает в Entware

---

### Решение

```bash id="r8y5dp"
echo "nameserver 1.1.1.1" > /opt/etc/resolv.conf
echo "nameserver 8.8.8.8" >> /opt/etc/resolv.conf
```

---

## Самая частая проблема №2 — время

### Симптом

* SSL ошибки
* opkg не качает

---

### Причина

👉 неправильное время

---

### Решение

```bash id="p6n3vk"
ntpd -q -p pool.ntp.org
```

---

## Самая частая проблема №3 — DoH/DNS

👉 твой реальный кейс

---

### Симптом

* всё установилось
* но ничего не работает
* прокси не выходит в интернет

---

### Причина

👉 кривые DoH серверы

---

### Решение

Использовать нормальные:

* [https://cloudflare-dns.com/dns-query](https://cloudflare-dns.com/dns-query)
* [https://dns.google/dns-query](https://dns.google/dns-query)
* [https://dns.quad9.net/dns-query](https://dns.quad9.net/dns-query)

---

## Самая частая проблема №4 — 128MB роутеры

### Симптом

* установка проходит
* потом всё ломается

---

### Причина

👉 не хватает RAM

---

### Решение

❌ не использовать

---

## После установки (обязательно)

### 1. Добавить config.yaml

```bash id="t5k2ds"
nano /opt/etc/mihomo/config.yaml
```

---

### 2. Перезапустить

```bash id="z1x7lw"
/opt/etc/init.d/S99mihomo restart
```

---

### 3. Проверить

```bash id="d2k9wr"
/opt/etc/init.d/S99mihomo status
```

---

### 4. Проверить прокси

```bash id="m8p4sd"
curl -x socks5://127.0.0.1:7890 https://ipinfo.io
```

---

## Важно

👉 Без config.yaml всё "установилось", но ничего не работает

---

## Диагностика из install.sh

В конце скрипт перезапускает Mihomo и проверяет, что порт 7890 слушает (`netstat`/`ss`).

👉 если порт слушает — установка успешна

⚠️ Полная диагностика (tmpfs, MagiTrickle, bypass) отдельно не выполняется — см. `08-troubleshooting.md`

---

## Когда переустанавливать

* сломался Entware
* кривой DNS
* экспериментировал и всё развалилось

---

## Итог

install.sh:

✔ нормальная установка
✔ безопасная
✔ для любых поддерживаемых архитектур

---

install_7621.sh:

✔ работает на MT7621, где install.sh не проходит
⚠ компромисс по безопасности (--insecure)
⚠ запасной путь, а не основной

---

## Коротко

👉 любой поддерживаемый роутер → начните с install.sh
👉 MT7621, если install.sh не проходит → install_7621.sh
👉 128MB → даже не начинай
