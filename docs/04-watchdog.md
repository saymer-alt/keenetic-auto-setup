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
PROXY_RETRY_DELAY=3
MIN_RESTART_INTERVAL=300
LOG_MAX_LINES=500
LOG_KEEP_LINES=300
HEALTHY_LOG_INTERVAL=1200
LOCK_DIR="/tmp/mihomo_watchdog.lock.d"
HEALTHY_STATE="/tmp/mihomo_watchdog.healthy"
INCIDENT_STATE="/tmp/mihomo_watchdog.incidents"
DIAG_WINDOW_SECS=1800
DIAG_FAIL_THRESHOLD=2
DIAG_MIN_INTERVAL=900
DIAG_MAX_REQUESTS=4
DIAG_SOCKS_TARGET_ALT="https://www.cloudflare.com"
MIHOMO_CONTROLLER_URL=""
```

---

## Что именно проверяется

Все WAN-проверки идут напрямую, без Mihomo: у каждой прямой проверки явно
указан `--noproxy '*'`, поэтому переменные
окружения `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY` не могут перенаправить
роутерный WAN-зонд через прокси (уточнение #328).

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
* один неуспешный probe **не считается достаточным основанием для рестарта**

После первого FAIL watchdog ждёт `PROXY_RETRY_DELAY=3` секунды и повторяет тот же
сквозной probe один раз:

```text
первый FAIL
    ↓
пауза 3 с
    ↓
повторный probe
    ├─ OK   → ничего не рестартовать
    └─ FAIL → рестарт
```

Это защищает от подтверждённого в поле false-positive сценария, когда WAN жив,
Mihomo до этого работал, но один SOCKS5h-запрос не уложился в 5 секунд или попал
в кратковременный сбой DNS/TLS/outbound failover. Устойчивая неисправность не
маскируется: второй подряд FAIL приводит к рестарту в том же запуске watchdog.

---

## Когда происходит рестарт

```bash
если:
  WAN подтверждён
  И (порт недоступен ИЛИ два tunnel-probe подряд не прошли)
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

* `/tmp/mihomo_watchdog.lock.d` исключает перекрытие cron-итераций; владелец
  определяется по PID + process starttime, включая запуск через stdin
* непосредственно перед restart watchdog неблокирующе получает общий
  `/tmp/mihomo-lifecycle.lock.d`; при maintenance/неопределённом state пишет SKIP
* обычный умерший владелец восстанавливается; metadata `.guard` после аварии
  внутри короткой critical section требует безопасного ручного recovery
* trap удаляет только собственные lock/marker и завершает работу при сигнале

Подробности, handover со старых копий и ограничения:
[19 — взаимное исключение операций](19-lifecycle-lock.md).

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
[OK] All good | WAN=primary (http://cp.cloudflare.com)
[OK] All good | WAN=whitelist (http://ya.ru)
[WARN] WAN unreachable (primary + whitelist targets failed)
[RATE-LIMIT] Restart blocked (120s < 300s) | Mihomo port unreachable
[INFO] Proxy tunnel first probe failed; retry succeeded - no restart
[RESTART] Proxy tunnel check failed
[RESTART-OK] process is running after restart
[RESTART-FAIL] process did not come up within 10s after restart
[FAIL] proxy_tunnel confirmed | cycles=2 | curl_rc=28 | elapsed_ms=5000
[DIAG-TRIGGER] proxy_tunnel | confirmed_cycles=2 window=1800s | reason=repeated_confirmed_failure
[DIAG] socks_primary=timeout(rc=28) | socks_alt=ok(rc=0) | controller=not_configured | requests=2
[DIAG-SKIP] proxy_tunnel_failure | diagnostic cooldown (640s < 900s)
[DIAG-SUMMARY] tunnel=FAIL | wan=primary | mihomo=running | port=up | socks_primary=timeout | socks_alt=ok | cause=single_target_or_route_suspected | confidence=LOW | action=review_rules
[INFO] Full Network Doctor: run manually for deeper evidence (kas-network-doctor.sh)
[INFO] post-restart tunnel recheck: SOCKS recovered (correlation only; next cycle re-verifies)
```

Watchdog по-прежнему выполняет проверки каждые 5 минут, но штатный healthy-heartbeat
`[OK] All good ...` записывается не чаще одного раза в 20 минут. Это убирает
основной шум. Любой WAN failure, restart или rate-limit сбрасывает heartbeat,
поэтому **следующий успешный полный цикл логируется сразу**. Смена успешного WAN-пути
`primary ↔ whitelist` тоже логируется сразу, не ожидая 20-минутного heartbeat-интервала,
поэтому fallback/failback виден в момент переключения.
Следующий успешный `[OK] All good ...` остаётся маркером восстановления для Doctor.
Старые строки `[WAN] Connectivity OK ...` и
`[WAN] Primary targets unavailable ...` Doctor продолжает понимать.

---

## Инцидентная диагностика (Watchdog 2.0, только наблюдаемость)

Добавлена в рамках [#328](https://github.com/saymer-alt/keenetic-auto-setup/issues/328).
**Политика рестартов не изменилась**: решения о рестарте принимаются там же и по тем же
условиям, что и раньше. Изменение recovery-политики — отдельный этап после owner GO.

### Уровни

* **L0 HEALTHY** — прежние дешёвые проверки, без новых фоновых процессов. Счётчики в tmpfs.
* **L1 FIRST CONFIRMED FAIL** — при каждом подтверждённом сбое (порт не отвечает; две
  подряд неудачи SOCKS-пробы; полное отсутствие WAN) перед рестартом пишется короткая
  строка `[FAIL] <класс> confirmed | cycles=N | curl_rc=.. | elapsed_ms=..` из уже
  собранных данных запросов. Никаких дополнительных запросов на этом уровне.
* **L2 REPEATED INCIDENT** — только при повторении подтверждённых сбоев
  (`DIAG_FAIL_THRESHOLD=2` циклов в окне `DIAG_WINDOW_SECS=1800`) и при активном сбое
  сейчас: одно ограниченное read-only диагностическое событие по классу ошибки с
  собственным cooldown `DIAG_MIN_INTERVAL=900`, бюджетом `DIAG_MAX_REQUESTS=4` запросов
  и дедупликацией одинаковых выводов. Маркеры: `[DIAG-TRIGGER]`, `[DIAG]`,
  `[DIAG-SKIP]`, `[DIAG-SUMMARY]`.
* **L3 MANUAL DEEP DIVE** — полный `kas-network-doctor.sh` запускается только вручную;
  Watchdog лишь подсказывает это в логе, когда L2 не дал ответа.

### Классы ошибок (учёт раздельный)

`wan_failure`, `proxy_tunnel_failure`, `port_failure` — по строке на класс в
`/tmp/mihomo_watchdog.incidents` (tmpfs; перезагрузка = новое окно по дизайну):

* два FAIL curl в одном cron-цикле = **один** подтверждённый `proxy_tunnel_failure`;
* transient (первая проба FAIL, retry PASS) — отдельный информационный счётчик,
  подтверждённым циклом не считается;
* `WAN_UNREACHABLE` не трогает историю туннеля: состояние туннеля в этот момент
  UNKNOWN, а не «сломан»;
* успешная соответствующая проверка сбрасывает счётчик подряд идущих сбоев, но окно
  повторов сохраняется до истечения времени.

### Чего диагностика НЕ делает

* не меняет решения о рестарте, cooldown и locks;
* не запускает полный Network Doctor автоматически и не создаёт второго демона;
* при локальном сбое (процесс/порт) не тратит запросы на внешние DNS/TLS-цели;
  при отсутствующем WAN не тратит бюджет на SOCKS-пробы и не выдаёт ложную гипотезу
  о неисправности Mihomo;
* не печатает URL, stderr curl, адреса серверов, ключи и выбранные узлы: в логе только
  фиксированные категории (`dns`/`connect_refused`/`timeout`/`tls`/...), коды curl и
  латентности; `curl_rc` сам по себе не объявляется доказанной причиной;
* Controller API опрашивается только если оператор явно задал `MIHOMO_CONTROLLER_URL`
  (bind может быть на LAN-адрес, а не localhost); по умолчанию — `not_configured`;
* успешный `socks_alt=ok` не доказывает работоспособность пользовательского трафика:
  цели могут иметь разные Mihomo rules/DIRECT; в `cause` используется честная степень
  уверенности (`LOW`/`UNKNOWN`), а `CONFIRMED` не проставляется без независимого
  подтверждения;
* `[RESTART-OK]` подтверждает процесс; строка `post-restart tunnel recheck` отдельно
  фиксирует `SOCKS recovered / still failing / unknown` — это корреляция, а не
  доказательство, что рестарт починил upstream.

### Расход ресурсов

* L0: без изменений (те же запросы, что и раньше); строки состояния пишутся в tmpfs.
* L1: ноль дополнительных запросов.
* L2: максимум `DIAG_MAX_REQUESTS` запросов на событие, не чаще одного события на
  класс в `DIAG_MIN_INTERVAL`, одинаковые выводы дедуплицируются; при нехватке бюджета
  пишется честный `unknown`, а не догадка.
* Новых обязательных зависимостей нет: латентность берётся из `/proc/uptime`, при
  его недоступности — `elapsed_ms=unknown`.

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

### `[INFO] Proxy tunnel first probe failed; retry succeeded - no restart`

Причина:

* первый сквозной SOCKS5h probe не прошёл;
* повторный probe через 3 секунды прошёл успешно;
* Mihomo **не перезапускался** — кратковременный сетевой выброс подтверждён как transient.

---

### `[RESTART] Proxy tunnel check failed`

Причина:

* порт открыт, но **два сквозных tunnel-probe подряд** не прошли;
* это уже подтверждённая неисправность end-to-end пути, а не одиночный выброс;
* часто проблема на стороне выбранного outbound/VPN-сервера или в config.yaml.

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

👉 нормальное подтверждение рестарта; следующий успешный полный цикл принудительно пишет `[OK] All good ...`, не ожидая 20-минутного heartbeat-интервала

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
https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/update-watchdog.sh | sh` —
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
PROXY_RETRY_DELAY=3
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
