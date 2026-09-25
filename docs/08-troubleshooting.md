# Troubleshooting

Если что-то не работает — смотри сюда.

Формат:
👉 Симптом → Причина → Решение

Порядок диагностики:

1. **Сначала read-only**: `mihomo-doctor.sh` — он не меняет ничего и выдаёт
   сводное состояние стека (Mihomo, порт 7890, ProxyN/bypass_wa, watchdog,
   RAM, пакет). Если проблема относится к одному конкретному домену/IP, после
   Doctor используйте [`mihomo-route-check.sh`](15-route-check.md).
2. **Потом supported-пути**: `update-mihomo.sh` / `update-watchdog.sh` /
   повторный `install.sh` — штатные инструменты, которые сами обеспечивают
   атомарность и откат.
3. **Ручные мутации — только когда это специально обосновано** (правка
   собственного `config.yaml`, перезапуск сервиса). Не «чинить» систему
   разовыми sed/chmod/echo-рецептами — они и были причиной части проблем.

---

## 🔴 Mihomo

---

### ❌ Mihomo не стартует

#### Симптом

```bash
/opt/etc/init.d/S99mihomo status
# dead
````

---

#### Причина

* нет config.yaml
* конфиг с ошибкой

---

#### Решение

```bash
ls -la /opt/etc/mihomo/config.yaml
```

Если конфига нет вообще — bootstrap обязателен и создаётся установщиком:
повтори `install.sh` (он пишет минимальный `mixed-port: 7890` и фейл-фаст,
если записать не смог). Если конфиг есть, но с ошибкой — правь свой
`config.yaml` (`nano /opt/etc/mihomo/config.yaml`), потом:

```bash
/opt/etc/init.d/S99mihomo restart
```

---

### ❌ proxy fail [000/000]

---

#### Причина

* mihomo не слушает порт
* процесс завис

---

#### Проверка

```bash
netstat -ln | grep 7890
```

---

#### Решение

```bash
/opt/etc/init.d/S99mihomo restart
```

---

### ❌ proxy fail [502/502]

---

#### Причина

👉 upstream (сервер) недоступен

---

#### Проверка

```bash
curl -x socks5://127.0.0.1:7890 https://ipinfo.io
```

---

#### Решение

* проверить сервер в config.yaml
* проверить интернет

---

## 🟡 Watchdog

---

### ❌ watchdog не работает

---

#### Проверка

```bash
cat /opt/var/log/mihomo_watchdog.log
```

---

#### Причина

* cron не запущен
* нет записи в crontab

---

#### Проверка cron

```bash
grep mihomo_watchdog /opt/etc/crontab
```

Норма — **либо** единственная управляемая прямая строка:

```bash
*/5 * * * * root /bin/sh /opt/etc/cron.5mins/mihomo_watchdog
```

**либо** строка run-parts, запускающая каталог `cron.5mins` целиком (строка
с `cron.5mins`, не упоминающая `mihomo_watchdog`). Обе схемы штатные; если
есть обе — direct-строка лишняя, но это тоже нормализует
`update-watchdog.sh`.

---

#### Решение

Если запись нет/кривая — supported-путь:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/update-watchdog.sh | sh
```

Если сам cron-демон не запущен:

```bash
/opt/etc/init.d/S10cron restart
```

---

### ❌ watchdog запускается дважды (дубли логов)

---

#### Симптом

```
OK
OK
OK
```

---

#### Причина

👉 в crontab несколько строк, запускающих watchdog (например, прямая строка
плюс run-parts для `cron.5mins`, или два дубля прямой строки)

---

#### Решение

Не вычищай crontab вручную через `sed -i '/mihomo_watchdog/d'` — это
удаляет и чужие/нужные записи. Supported-путь нормализует планирование сам:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/update-watchdog.sh | sh
```

Он схлопывает дубли управляемой прямой строки в одну и убирает прямую
строку только тогда, когда есть run-parts-маршрут; посторонние записи
crontab не трогаются.

---

### ❌ лог не пишется

---

#### Причина

* watchdog ни разу не запускался (cron/планирование — см. выше)
* файл был удалён вручную

---

#### Решение

Лог создаётся самим watchdog'ом при первом запуске (первая строка —
`[INIT] log generation started`); руками файл создавать не нужно. Права
`chmod 666` не нужны и не должны ставиться: watchdog выполняется от root
и пишет в лог сам.

Порядок: проверь планирование (раздел выше) → если планирование в порядке,
но лога нет — `mihomo-doctor.sh` покажет состояние watchdog-раскладки
(canonical/wrapper/legacy).

---

## 🔵 Сеть / Интернет

---

### ❌ curl: (6) Could not resolve host

---

#### Причина

👉 DNS на роутере/в Entware сломан (или пустой `/opt/etc/resolv.conf`)

---

#### Диагностика (read-only)

```bash
ls -l /opt/etc/resolv.conf        # на Entware это обычно симлинк на /etc/resolv.conf
cat /opt/etc/resolv.conf
/opt/bin/mihomo-doctor.sh         # сетевые проверки: DNS, GitHub, raw
```

---

#### Решение

⚠️ Не перезаписывай `/opt/etc/resolv.conf` публичными резолверами
(`echo "nameserver 1.1.1.1" > ...`): файл на Keenetic управляется
KeeneticOS (обычно это симлинк на `/etc/resolv.conf`), а ручные публичные
резолверы обходят `dns-proxy intercept` и ломают схему DNS-transit, на
которой держится MagiTrickle.

Штатный путь: убедись, что DNS-transit включён и применился (это делает
install.sh, состояние показывает Doctor); если DNS сломан на уровне
роутера — чини сначала KeeneticOS/провайдерский DNS, потом повторяй
`install.sh` (он сам проверит `dns-proxy intercept enable` по
running-config).

---

### ❌ Интернет есть, но прокси не работает

---

#### Причина

👉 кривые DoH сервера (реальный кейс)

---

#### Решение

Использовать нормальные:

* [https://cloudflare-dns.com/dns-query](https://cloudflare-dns.com/dns-query)
* [https://dns.google/dns-query](https://dns.google/dns-query)
* [https://dns.quad9.net/dns-query](https://dns.quad9.net/dns-query)

---

### ❌ WAN unreachable, skip

---

#### Причина

👉 нет интернета

---

#### Важно

👉 watchdog ПРАВИЛЬНО не рестартует Mihomo

---

#### Решение

* проверить кабель
* проверить провайдера

---

## 🟣 bypass_wa (VoIP)

---

### ❌ Telegram / WhatsApp звонки не работают

---

#### Причина

* bypass_wa не применился
* нет правил iptables

---

#### Проверка

```bash
iptables -t mangle -L | grep _CUST_BYPASS_WA_
```

---

#### Решение

```bash
/etc/init.d/netfilter restart
```

или reboot

---

### ❌ правила есть, но не работают

---

#### Проверка

```bash
iptables -t mangle -L _CUST_BYPASS_WA_ -v -n
```

👉 счётчики должны расти

---

#### Если нет

👉 трафик не попадает

---

## 🟠 Entware / opkg

---

### ❌ opkg update не работает

---

#### Причина

* DNS
* время

---

#### Решение

```bash
ntpd -q -p pool.ntp.org
opkg update
```

---

### ❌ wget: bad address

---

#### Причина

👉 DNS или сеть

---

#### Решение

см. DNS выше

---

## 🟤 Свободное место на /opt

Doctor не использует фиксированный порог вроде «меньше 32 МБ = проблема». На небольшом
внутреннем Entware-разделе это даёт ложные WARN даже при нормальном запасе.

Вместо этого Doctor:

- показывает фактический свободный объём и процент;
- берёт размер текущего Mihomo binary;
- добавляет тот же safety margin 4 МБ, что использует `update-mihomo.sh`;
- WARN выдаётся только если текущего свободного места уже не хватает для такой staging-оценки.

Это **предварительная оценка**, а не гарантия будущего обновления: сам
`update-mihomo.sh` перед заменой считает размер именно скачанного candidate и при
нехватке места останавливается до изменения установленного бинарника.

---

## 🔴 RAM / S00ubifs

---

### ❌ всё работает криво после установки

---

#### Причина

👉 не хватает RAM

---

#### Проверка

```bash
free
```

---

#### Решение

Если 128MB — это best-effort профиль, требующий внешнего /opt и внешнего storage-backed swap >=384 МБ (project-specific floor; zRAM не считается): проверь `free` или сразу `mihomo-doctor.sh` — он показывает класс /opt, объём, свободный остаток и backend'ы. Для 256 МБ достаточно **одного** backend: zRAM или внешнего storage-backed swap, независимо от места /opt. Если используется disk/file swap, zRAM по рекомендации производителя должен быть отключён. На 512 МБ+ отсутствие swap/zRAM само по себе нормально. Не запускай второй Mihomo; проект swap и носители сам не создаёт/не монтирует.

---

### ❌ tmpfs не смонтирован

---

#### Проверка

```bash
mount | grep tmpfs
```

---

#### Решение

```bash
/opt/etc/init.d/S00ubifs restart
```

---

## 🟤 Диагностика (быстро)

---

### Mihomo жив?

```bash
/opt/etc/init.d/S99mihomo status
```

---

### Прокси работает?

```bash
curl -x socks5://127.0.0.1:7890 https://ipinfo.io
```

---

### Watchdog работает?

```bash
cat /opt/var/log/mihomo_watchdog.log
```

---

### Какой proxy-сервер реально выбран сейчас?

Если в конфиге есть группы `Selector`, `URLTest`, `Fallback`, `LoadBalance`, `Relay` или вложенные группы, вручную разбирать `now` в Controller API неудобно. Необязательный `mihomo-proxy-selection-watch.sh` проходит цепочку групп и показывает конечный leaf-сервер:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-proxy-selection-watch.sh | sh
```

Для наблюдения за переключениями:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-proxy-selection-watch.sh | sh -s -- --watch 1
```

Пример:

```text
GLOBAL -> Primary -> Sweden-1
CURRENT SERVER: Sweden-1
```

В режиме `--watch` выводятся только изменения с временем, поэтому по ним удобно видеть failover и failback. Helper строго read-only: его единственный API-запрос — `GET /proxies`; он не выбирает узлы, не запускает delay-test и ничего не перезапускает. Нужны `curl` и `jq`, а Controller Mihomo должен быть включён. Если используется `secret`, передайте его через `-s SECRET` или `MIHOMO_API_SECRET`.

Это **не замена Doctor**: Doctor отвечает «здоров ли стек», proxy-selection-watch — «какой конечный proxy выбран сейчас и когда выбор изменился». Полная инструкция с вариантами запуска, `-g`, `-u` и secret: [Mihomo Proxy Selection Watch](11-proxy-selection-watch.md).

---

### Cron есть?

```bash
grep mihomo /opt/etc/crontab
```

---

### bypass_wa есть?

```bash
iptables -t mangle -L | grep _CUST_BYPASS_WA_
```

---

## 🧠 Главная идея

Если что-то сломалось:

1. Проверить Mihomo
2. Проверить DNS
3. Проверить watchdog
4. Проверить bypass
5. Проверить RAM

👉 90% проблем найдутся здесь
