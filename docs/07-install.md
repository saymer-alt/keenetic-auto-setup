````markdown id="n1u3fs"
# install.sh и install_7621.sh

Как работает установка и какой скрипт использовать.

---

## Быстрый выбор

👉 Если не хочешь читать:

| Архитектура | Скрипт |
|-------------|--------|
| ARM (aarch64) | install.sh |
| MT7621 / старые | install_7621.sh |

---

## Как понять, что у тебя

```bash
opkg print-architecture | awk '/^arch/{print $2}'
``` id="q2l5mx"

Примеры:
- `aarch64-3.10` → современный роутер → install.sh
- `mipsel-3.4` → старый → install_7621.sh

---

## Общая логика установки

Оба скрипта делают одно и то же:

````

1. opkg update
2. Установка базовых пакетов
3. Создание bypass_wa
4. Установка S00ubifs
5. Установка Mihomo
6. Настройка Proxy0
7. Установка MagiTrickle
8. Установка watchdog
9. Диагностика

````id="c9q2bm"

---

## install.sh (основной)

### Для кого

- Keenetic Giga / Ultra / Hero / Viva новые
- ARM (aarch64)
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
ARCH=$(opkg print-architecture | awk '/^arch/ && $2~/^(mips|mipsel|aarch64)/{
    sub(/[-_].*/,"",$2); print $2; exit
}')
```

---

#### 3. Получение последней версии Mihomo

```bash id="a2l9re"
curl https://sw.ext.io/... | grep mihomo
```

✔ всегда свежая версия
✔ без хардкода

---

#### 4. Fallback

Если `sw.ext.io` не отвечает:

👉 скачивание с GitHub

---

## install_7621.sh (legacy)

### Для кого

* MT7621 / MT7628
* старые Keenetic
* проблемы с SSL

---

### Главная проблема этих роутеров

👉 старый OpenSSL / curl

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

### Почему это ок

* скачивание только с известных источников
* альтернативы на этих роутерах нет

---

## Ключевые отличия

|             | install.sh | install_7621.sh |
| ----------- | ---------- | --------------- |
| TLS         | строгий    | insecure        |
| Архитектура | авто       | mipsel          |
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

В конце скрипт проверяет:

* mount points
* mihomo
* magitrickle
* watchdog
* bypass

👉 если здесь OK — установка успешна

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
✔ для современных роутеров

---

install_7621.sh:

✔ работает на старых
⚠ компромисс
⚠ нужен только при проблемах

---

## Коротко

👉 ARM → install.sh
👉 старый роутер → install_7621.sh
👉 128MB → даже не начинай
