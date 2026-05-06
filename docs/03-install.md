# 03 — установка (подробно)

Что делает install.sh на самом деле.

Если quick-start — это «вставил и поехал», то здесь:

> **что именно происходит и где может сломаться**

---

## Общий процесс

```id="flow1"
1. Подготовка (opkg, пакеты)
2. Настройка системы (policy, Proxy0)
3. Установка Mihomo
4. Установка MagiTrickle
5. Установка bypass_wa
6. Установка S00ubifs (RAM режим)
7. Установка watchdog
8. Диагностика
```

---

## 1. Базовые пакеты

```bash id="step1"
opkg update
opkg install curl jq nano
```

### Зачем

* `curl` — скачивание всего
* `jq` — парсинг JSON (версии, API)
* `nano` — редактирование конфигов

### Если ломается

* DNS → смотри `/opt/etc/resolv.conf`
* время → SSL может падать

---

## 2. Настройка bypass_wa policy

```bash id="step2"
ndmc -c "ip policy bypass_wa"
```

### Зачем

Создаётся отдельная политика маршрутизации:

> весь помеченный VoIP-трафик → напрямую в VPN

Без неё:

* звонки будут идти через Mihomo
* лаги / обрывы

---

## 3. Установка S00ubifs (RAM режим)

Файл:

```id="path1"
/opt/etc/init.d/S00ubifs
```

### Что делает

* монтирует:

  * `/opt/tmp`
  * `/opt/var/log`
  * `/opt/var/run`
* в RAM (tmpfs)

### Зачем

* убрать постоянные записи на флешку
* продлить срок жизни накопителя

---

## 4. Определение архитектуры

```bash id="step4"
opkg print-architecture
```

Результат:

* `aarch64-3.10`
* `mipsel-3.4`

Скрипт берёт:

```id="arch"
aarch64 / mipsel
```

### Зачем

Чтобы скачать правильный пакет Mihomo.

---

## 5. Установка Mihomo

```id="step5"
mihomo_*.ipk
```

### Как происходит

1. Пытается получить последнюю версию
2. Скачивает пакет
3. Устанавливает через `opkg`

### Где лежит

```bash id="path2"
/opt/etc/mihomo/
/opt/bin/mihomo
```

### После установки

Создаётся сервис:

```bash id="svc1"
/opt/etc/init.d/S99mihomo
```

---

## 6. Настройка Proxy0

```bash id="step6"
ndmc -c "..."
```

### Что делает

* создаёт прокси:

```id="proxy"
127.0.0.1:7890
```

* подключает его к Keenetic

### Зачем

Это мост:

> Keenetic → Mihomo

---

## 7. Установка MagiTrickle

```bash id="step7"
opkg install magitrickle
```

### Что делает

* маршрутизация по доменам
* интеграция с DNS

### После установки

```bash id="svc2"
/opt/etc/init.d/S??magitrickle
```

---

## 8. Установка bypass_wa

Файл:

```bash id="path3"
/opt/etc/ndm/netfilter.d/020-bypass_wa.sh
```

### Что делает

* добавляет iptables правила
* маркирует VoIP UDP трафик
* отправляет его в policy bypass_wa

### Важно

> выполняется НЕ один раз, а каждый раз при пересборке netfilter

---

## 9. Установка watchdog

Файл:

```bash id="path4"
/opt/etc/cron.5mins/mihomo_watchdog
```

И запись в cron:

```bash id="cron"
*/5 * * * * root /bin/sh /opt/etc/cron.5mins/mihomo_watchdog
```

### Что делает

* проверяет:

  * процесс mihomo
  * WAN
  * прокси
* при проблеме → рестарт

---

## 10. Запуск сервисов

```bash id="step10"
/opt/etc/init.d/S99mihomo start
/opt/etc/init.d/S10cron start
```

---

## 11. Диагностика

Скрипт проверяет:

* смонтирован ли tmpfs
* запущен ли Mihomo
* работает ли MagiTrickle
* есть ли watchdog
* есть ли bypass_wa

Если всё ок:

```id="ok"
[OK] Done
```

---

## Где чаще всего ломается

### 1. DNS

```bash id="dbg1"
cat /opt/etc/resolv.conf
```

---

### 2. Время

```bash id="dbg2"
date
```

Если время кривое → SSL не работает

---

### 3. Mihomo не запускается

```bash id="dbg3"
/opt/etc/init.d/S99mihomo status
```

→ почти всегда `config.yaml`

---

### 4. Cron

```bash id="dbg4"
cat /opt/etc/crontab
```

Должно быть:

```id="cronok"
*/5 * * * * root /bin/sh /opt/etc/cron.5mins/mihomo_watchdog
```

---

### 5. Entware

```bash id="dbg5"
which opkg
```

Если пусто — `/opt` не подключён

---

## Разница install.sh и install_7621.sh

Коротко:

|              | install.sh  | install_7621.sh |
| ------------ | ----------- | --------------- |
| CPU          | ARM / новые | MT7621          |
| SSL          | нормальный  | `--insecure`    |
| стабильность | высокая     | компромисс      |

Подробнее:
→ `07-install-scripts.md`

---

## Главное

Этот скрипт не просто «ставит пакеты».

Он:

* собирает сетевую архитектуру
* настраивает маршрутизацию
* добавляет самовосстановление

---

Если что-то пошло не так:

→ `08-troubleshooting.md`
