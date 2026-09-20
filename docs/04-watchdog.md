# 04 — watchdog

Почему система не требует постоянного ручного перезапуска.

---

## Задача

Не мониторинг ради мониторинга, а:

> **автоматическое восстановление Mihomo при проблемах**

Без участия человека.

---

## Почему не "while true"

Плохой вариант:

```bash
while true; do
  check
  sleep 5
done
```

Проблемы:

* жрёт CPU
* не даёт системе «спать»
* на слабых роутерах → лаги

---

## Решение

```bash
cron → каждые 5 минут → watchdog → завершился
```

* скрипт живёт секунды
* не нагружает систему
* работает предсказуемо

---

## Где находится

Канонический layout (один и тот же и у install.sh, и у update-watchdog.sh):

- полный скрипт: `/opt/bin/mihomo_watchdog.sh`
- thin-обёртка планировщика: `/opt/etc/cron.5mins/mihomo_watchdog`
  (`#!/bin/sh` + `exec /opt/bin/mihomo_watchdog.sh "$@"`)

Запуск — одна управляемая строка в crontab:

```bash
*/5 * * * * root /bin/sh /opt/etc/cron.5mins/mihomo_watchdog
```

`update-watchdog.sh` обновляет ровно этот layout (тот же файл, что ставит
install.sh): он распознаёт исторические управляемые layout'ы (полный скрипт
внутри cron-файла и др.) и мигрирует их в канонический. crontab-строки
обрабатываются так: допускается либо единственная управляемая прямая строка
выше, либо строка run-parts, запускающая каталог `cron.5mins` целиком (то
есть строка crontab с `cron.5mins`, не упоминающая `mihomo_watchdog`);
дубли прямых строк схлопываются в одну; прямая строка удаляется только если
строка run-parts существует; любые другие записи crontab не трогаются.

Проверить, какая схема запуска используется:

```bash
grep mihomo_watchdog /opt/etc/crontab
```

---

## Основные параметры

```bash
WAN_PRIMARY_TARGETS="http://cp.cloudflare.com http://www.google.com"
WAN_WHITELIST_TARGETS="http://gosuslugi.ru http://ya.ru http://mail.ru http://vk.ru http://vk.com"
PROXY="127.0.0.1:7890"
MIN_RESTART_INTERVAL=300
LOG_MAX_LINES=500
LOG_KEEP_LINES=300
LOCK_DIR="/tmp/mihomo_watchdog.lock.d"
```

---

## Что именно проверяется

Все WAN-проверки идут напрямую, без Mihomo.

### 1. WAN (двухступенчатая проверка)

Сначала обычные цели:

* cp.cloudflare.com
* www.google.com

Если недоступны ВСЕ — whitelist:

* gosuslugi.ru
* ya.ru
* mail.ru
* vk.ru / vk.com

Ответил хотя бы один = WAN есть.

Если не ответил никто:

```bash
→ выход без рестарта
```

👉 важно:

> не рестартить Mihomo, если проблема у провайдера

---

### 2. Порт Mihomo

```bash
curl -s --connect-timeout 3 http://127.0.0.1:7890
```

Важно только, что порт принимает TCP-соединения.

Если порт закрыт — Mihomo, скорее всего, упал:

```bash
→ рестарт
```

---

### 3. Сквозной туннель

```bash
curl -x socks5h://127.0.0.1:7890 -m 5 -s https://www.google.com
```

* socks5h — DNS тоже через туннель
* проверяет, что прокси реально пропускает трафик

Если туннель не работает:

```bash
→ рестарт
```

---

## Когда происходит рестарт

```bash
если:
  WAN подтверждён
  И (порт недоступен ИЛИ туннель сломан)
  И прошло > 300 сек с прошлого рестарта

→ /opt/etc/init.d/S99mihomo restart
```

---

## Rate limiting (защита от циклов)

* время последнего рестарта хранится в `/tmp/mihomo_watchdog.restart`
* содержимое файла валидируется (мусор в файле = считаем 0)
* рестарт раньше 300 сек блокируется с записью `[RATE-LIMIT]`

---

## Lock

* атомарный mkdir-lock-каталог `/tmp/mihomo_watchdog.lock.d` (pid/ts-владение +
  claim-симлинк) не даёт двум копиям работать одновременно
* живой держатель блокирует; мёртвый (kill -9) атомарно подхватывается на
  следующем запуске — перезагрузка не нужна
* trap чистит временные файлы при любом выходе

---

## Jitter (разнос по времени)

```bash
sleep $(( $(date +%s) % 25 ))
```

---

## Зачем это нужно

Если у тебя:

* 10–20 роутеров
* один сервер

Без jitter:

```bash
все одновременно → запрос → пик нагрузки
```

С jitter:

```bash
запросы распределены на 0–25 сек
```

---

## Почему не RANDOM

BusyBox:

* может не иметь RANDOM
* или всегда возвращает 0

👉 `date +%s` работает везде

---

## Логирование

Файл:

```bash
/opt/var/log/mihomo_watchdog.log
```

Реальные строки:

```bash
[INIT] log generation started (fresh tmpfs after boot or first run)
[WAN] Connectivity OK via http://cp.cloudflare.com
[WAN] Primary targets unavailable, checking whitelist targets
[WARN] WAN unreachable (primary + whitelist targets failed)
[RATE-LIMIT] Restart blocked (120s < 300s) | Mihomo port unreachable
[RESTART] Proxy tunnel check failed
[RESTART-OK] process is running after restart
[RESTART-FAIL] process did not come up within 10s after restart
[OK] All good
```

---

## Ротация логов

```bash
tail -n 300
```

Если лог > 500 строк:
→ остаётся последние 300

---

## Почему не logrotate

* лишняя зависимость
* не везде есть
* сложнее поддержка

---

## Ручной запуск (очень важно)

```bash
sh -x /opt/etc/cron.5mins/mihomo_watchdog
```

Показывает:

* jitter
* выбор WAN-цели
* решения (рестарт / rate-limit / выход)

👉 основной инструмент дебага

⚠️ При запуске вне установки убедись, что `/opt/var/log` существует (каталог создаёт install.sh)

---

## Частые проблемы

### `[WARN] WAN unreachable`

Причина:

* интернет реально пропал (не ответили ни основные, ни whitelist-цели)

👉 watchdog ПРАВИЛЬНО ничего не делает

---

### `[RESTART] Mihomo port unreachable`

Причина:

* Mihomo не слушает порт 7890 — упал или не стартовал

---

### `[RESTART] Proxy tunnel check failed`

Причина:

* порт открыт, но туннель не работает
* часто проблема на стороне VPN-сервера или в config.yaml

---

### `[RATE-LIMIT] Restart blocked`

Причина:

* рестарт уже был меньше 300 сек назад

👉 это защита от цикла, а не ошибка

---

### `[INIT] log generation started`

Причина:

* лог-файла не было на старте watchdog — свежий tmpfs после reboot или первый запуск

👉 якорь генерации: вся история выше этой строки относится к текущему аптайму

---

### `[RESTART-OK] process is running after restart`

Причина:

* рестарт выполнен и процесс подтверждён той же проверкой в течение 10 сек

👉 нормальное подтверждение восстановления; следующая запись `[OK] All good` остаётся полной проверкой

---

### `[RESTART-FAIL] process did not come up within 10s after restart`

Причина:

* рестарт не подтвердился за 10 сек — Mihomo не поднялся (config, окружение, ресурсы)

👉 смотреть раздел типовых проблем; watchdog продолжит проверки по расписанию

---

### лог пустой

Причины:

* cron не работает
* crontab не содержит ни управляемой прямой строки, ни строки run-parts
  для `cron.5mins` (например, после ручной правки crontab)

Проверка:

```bash
ps | grep cron
grep mihomo_watchdog /opt/etc/crontab
```

Чинить так (supported path): `curl -fSsL
https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/update-watchdog.sh | sh` —
он нормализует планирование в канонический layout (и мигрирует исторические
управляемые layout'ы).

---

## Важные ограничения

* watchdog чинит **только Mihomo**
* не чинит:

  * VPN сервер
  * DNS
  * провайдера
* при полном отказе WAN — не рестартит (осознанно)

---

## Что можно менять

```bash
WAN_PRIMARY_TARGETS=...
WAN_WHITELIST_TARGETS=...
PROXY=127.0.0.1:7890
MIN_RESTART_INTERVAL=300
```

---

## Что НЕ трогать

* порядок проверок
* lock-файл
* jitter
* логика «нет WAN → нет рестарта»

---

## Главное

Watchdog — это:

> **не мониторинг, а механизм самовосстановления**

который отличает «сломался Mihomo» от «сломался интернет»

---

Если что-то не работает:

→ `08-troubleshooting.md`
