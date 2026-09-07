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

Установщик (install.sh) кладёт скрипт сюда:

```bash
/opt/etc/cron.5mins/mihomo_watchdog
```

Запуск:

```bash
*/5 * * * * root /bin/sh /opt/etc/cron.5mins/mihomo_watchdog
```

⚠️ Важно: `update-watchdog.sh` обновляет ДРУГУЮ копию:

```bash
/opt/bin/mihomo_watchdog.sh
```

👉 Перед обновлением проверь, какая копия реально запускается:

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
LOCK_FILE="/tmp/mihomo_watchdog.lock"
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

## Lock-файл

* `/tmp/mihomo_watchdog.lock` не даёт двум копиям работать одновременно
* trap гарантирует удаление при любом выходе

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
[WAN] Connectivity OK via http://cp.cloudflare.com
[WAN] Primary targets unavailable, checking whitelist targets
[WARN] WAN unreachable (primary + whitelist targets failed)
[RATE-LIMIT] Restart blocked (120s < 300s) | Mihomo port unreachable
[RESTART] Proxy tunnel check failed
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

### лог пустой

Причины:

* cron не работает
* запись в crontab указывает на другую копию

Проверка:

```bash
ps | grep cron
grep mihomo_watchdog /opt/etc/crontab
```

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
