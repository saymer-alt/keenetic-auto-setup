## 📄 `docs/08-troubleshooting.md`

````markdown id="u8k3xq"
# Troubleshooting

Если что-то не работает — смотри сюда.

Формат:
👉 Симптом → Причина → Решение

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
nano /opt/etc/mihomo/config.yaml
```

Потом:

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
cat /opt/etc/crontab
```

Должно быть:

```bash
*/5 * * * * root /bin/sh /opt/etc/cron.5mins/mihomo_watchdog
```

---

#### Решение

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

👉 дубли в crontab

---

#### Решение

```bash
sed -i '/mihomo_watchdog/d' /opt/etc/crontab
```

и добавить одну строку вручную

---

### ❌ лог не пишется

---

#### Причина

* нет файла
* нет прав

---

#### Решение

```bash
touch /opt/var/log/mihomo_watchdog.log
chmod 666 /opt/var/log/mihomo_watchdog.log
```

---

## 🔵 Сеть / Интернет

---

### ❌ curl: (6) Could not resolve host

---

#### Причина

👉 DNS сломан

---

#### Решение

```bash
echo "nameserver 1.1.1.1" > /opt/etc/resolv.conf
echo "nameserver 8.8.8.8" >> /opt/etc/resolv.conf
```

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

❌ если 128MB — не использовать

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

```

---
