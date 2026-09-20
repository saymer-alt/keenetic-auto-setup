# Подробно об установке (install.sh)

Как работает установка через единый `install.sh` и что он делает на роутере.

---

## Быстрый выбор

👉 Если не хочешь читать:

| Ситуация | Скрипт |
|----------|--------|
| Любая поддерживаемая архитектура (aarch64 / armv7 / mipsel / mips, включая MT7621) | install.sh |
| Режим | по умолчанию `ram` (tmpfs); для внешнего носителя — `sh install.sh disk` |

Установщик один для всех архитектур: команда та же, что в [Quick Start](02-quick-start.md).

---

## Как понять, что у тебя

```bash
opkg print-architecture | awk '/^arch/{print $2}'
```

Примеры:

- `aarch64-3.10` → install.sh
- `armv7-3.2` → install.sh
- `mipsel-3.4` → install.sh
- `mips-3.4` → install.sh

---

## Режимы: ram и disk

- `ram` (по умолчанию) — логи и временные файлы в tmpfs, защита флеш-памяти.
- `disk` — установка с данными на внешнем носителе (USB HDD / NVMe).

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/install.sh | sh
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/install.sh | sh -s -- disk
```

При работе с внутренней памяти рекомендуется штатный zRAM KeeneticOS (сжатый swap в RAM без NAND swap-файла; включается в системных настройках производительности — формулировки зависят от прошивки), после установки активный swap проверяется `mihomo-doctor.sh`. Подробности tmpfs и zRAM — [docs/06](06-s00ubifs.md).

---

## Для кого

- Keenetic Giga / Ultra / Hero / Viva и другие совместимые, включая MT7621
- aarch64 / armv7 / mipsel / mips
- 256MB+ RAM — поддерживаемый профиль (512 МБ+ — самый запасной; active swap не обязателен); 128 МБ-класс — только best-effort/experimental и только с активным swap от 384 МБ (512 МБ предпочтительно), иначе установщик останавливается на раннем preflight (см. [docs/09](09-limitations.md))

---

## Общая логика установки

install.sh делает всё:

0. RAM/swap-префлайт: класс устройства, расположение /opt (по факту монтирования), активный zRAM и внешний storage-backed swap (`/proc/meminfo`, `/proc/swaps`, `/proc/mounts`); на 128 МБ-классе требуются внешний /opt и внешний storage-backed swap >= 384 МБ (512 предпочтительно) — иначе остановка здесь, до скачиваний и изменений; на 256 МБ внутренняя память требует активного zRAM, внешний /opt — swap опционален
1. `opkg update`
2. Базовые пакеты (`ca-bundle`, `curl`, `jq`, `nano`, `cron`)
3. Политика `bypass_wa`
4. Перехват транзитного DNS (`dns-proxy intercept enable`)
5. S00ubifs (только ram-режим)
6. Установка Mihomo
7. Bootstrap `config.yaml` (`mixed-port: 7890`)
8. Выбор проектного Proxy-интерфейса (`Proxy0` или первый свободный `ProxyN`)
9. Привязка `bypass_wa` к проектному Proxy
10. MagiTrickle
11. VoIP-хук `020-bypass_wa.sh`
12. Watchdog
13. Перезапуск Mihomo и финальный self-check

---

## Проверка сертификатов (HTTPS)

Скачивание идёт по HTTPS с проверкой сертификатов:

```bash
curl -fSsL https://...
```

✔ проверка сертификатов
✔ безопасная загрузка

---

## Автоопределение архитектуры

```bash
ARCH=$(opkg print-architecture | awk '/^arch/ && $2~/^(mips|mipsel|aarch64|arm)/{
    sub(/[-_].*/,"",$2); print $2; exit
}')
```

Поддерживаемые суффиксы пакетов: `aarch64-3.10`, `armv7-3.2`, `mipsel-3.4`, `mips-3.4`.

---

## Откуда берётся Mihomo

PRIMARY — актуальный release `saymer-alt/entware-go`:

```bash
https://api.github.com/repos/saymer-alt/entware-go/releases/latest
```

✔ версия из актуального релиза, без хардкода в скрипте

### Fallback-цепочка поиска пакета

Если GitHub API не отвечает или jq не нашёл пакет:

👉 grep по JSON → повторный запрос → парсинг HTML-страницы релизов

### Last resort — Entware feed

Если весь GitHub-путь провалился до успешной установки (asset не найден,
скачивание не удалось, пакет не установился):

👉 `opkg install mihomo` из настроенного Entware feed

Переход печатается WARN'ом. Версия из Entware feed может быть старее сборки GitHub.

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

⚠️ Не перезаписывай `/opt/etc/resolv.conf` публичными резолверами вручную:
файлом управляет KeeneticOS (обычно это симлинк на `/etc/resolv.conf`), а
ручные резолверы обходят `dns-proxy intercept` и ломают DNS-transit
(MagiTrickle). Сначала диагностика — `ls -l /opt/etc/resolv.conf`,
`cat /opt/etc/resolv.conf`, `mihomo-doctor.sh`; штатные пути описаны в
[08-troubleshooting.md](08-troubleshooting.md).

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

```bash
ntpd -q -p pool.ntp.org
```

---

## Самая частая проблема №3 — DoH/DNS

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

Установка разрешена только при внешнем /opt и внешнем storage-backed swap >= 384 МБ (512 предпочтительно; zRAM не считается), и это best-effort. Следить за свободной RAM и не запускать второй Mihomo рядом с daemon. Если система нестабильна — отказаться от `ram`/S00ubifs или перейти на устройство с 256+ МБ.

---

## После установки (обязательно)

### 1. Добавить config.yaml

```bash
nano /opt/etc/mihomo/config.yaml
```

---

### 2. Перезапустить

```bash
/opt/etc/init.d/S99mihomo restart
```

---

### 3. Проверить

```bash
/opt/etc/init.d/S99mihomo status
```

---

### 4. Проверить прокси

```bash
curl -x socks5://127.0.0.1:7890 https://ipinfo.io
```

---

## Важно

👉 Без config.yaml всё "установилось", но ничего не работает

---

## Self-check в конце установки

В конце install.sh выполняет самопроверку и печатает `[ok] / [WARN] / [FAIL]` по каждому
пункту: бинарник Mihomo (исполняемые `-v`/`-t` проверки выполняются только когда демон не запущен; при работающем Mihomo соблюдается правило одного экземпляра), init-скрипт `S99mihomo`, проектный Proxy-интерфейс,
перехват транзитного DNS, bypass-правила, permit в политике `bypass_wa`, watchdog
(бинарник, cron-обёртка, запись в crontab), cron, MagiTrickle, S00ubifs (в ram-режиме),
порт 7890 и свободное место на `/opt`.

- любой `[FAIL]` — установка считается неполной, скрипт завершается с ошибкой;
- `[WARN]` установку не прерывают, но их стоит просмотреть.

---

## Когда переустанавливать

* сломался Entware
* кривой DNS
* экспериментировал и всё развалилось

Повторный запуск безопасен: изменяющие шаги сначала проверяют, существует ли объект
(пакеты, политика, Proxy-интерфейс, запись в crontab) и ничего не задублируют.
Нюанс: mihomo-пакет скачивается при каждом запуске — opkg пропустит ту же версию,
новую установит.

---

## Коротко

👉 любой поддерживаемый роутер (включая MT7621) → install.sh
👉 128MB → можно, но только best-effort; предпочтительнее `disk`
👉 если что-то пошло не так → [08-troubleshooting.md](08-troubleshooting.md)
