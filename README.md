# 🛡️ Keenetic Auto-Setup Suite

Автоматизированный инструмент для установки сетевых и вспомогательных инструментов на Keenetic, их автономной работы и защиты внутренней памяти от износа.

[English](docs/EN/README.md)

---

## 0. Что должно быть подготовлено

- Keenetic с установленным Entware / OPKG
- SSH-доступ
- Интернет

## 1. Установка

### Встроенная память роутера — рекомендуется

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/install.sh | sh
```

### Внешний носитель — рекомендуется USB HDD / NVMe

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/install.sh | sh -s -- disk
```

Дождаться завершения установки.

Подробности → [установка](docs/03-install.md).

## 2. Конфигурация Mihomo

Сгенерировать конфигурацию:

[**Mihomo Unified Generator**](https://github.com/saymer-alt/link-generators)

Открыть конфигурацию:

```bash
nano /opt/etc/mihomo/config.yaml
```

Очистить файл (`Ctrl+K`), вставить конфигурацию.

Сохранить: `Ctrl+O` → `Enter`  
Выйти: `Ctrl+X`

Сгенерированная конфигурация создаёт интерфейс `mitun0`. Его рекомендуется использовать при настройке MagiTrickle.

Подробности → [Mihomo](docs/encyclopedia/10-mihomo-eto.md) · [MagiTrickle и маршрутизация](docs/01-architecture.md) · [первый вход в UI](docs/encyclopedia/12-pervyj-vhod-v-ui.md).

## 3. Проверка и запуск

Проверить конфигурацию:

```bash
mihomo -t -f /opt/etc/mihomo/config.yaml
```

Запустить:

```bash
/opt/etc/init.d/S99mihomo restart
```

Проверить статус:

```bash
/opt/etc/init.d/S99mihomo status
```

Прокси Mihomo:

`127.0.0.1:7890`

Подробности → [проверка работы](docs/08-troubleshooting.md).

## 4. Управление Mihomo

После установки конфигурации с Web UI:

```text
http://192.168.1.1:9090/ui/
```

`192.168.1.1` заменить на IP роутера.

Подробности → [первый вход в UI](docs/encyclopedia/12-pervyj-vhod-v-ui.md).

## 5. Обновление

### Mihomo

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/update-mihomo.sh | sh
```

Принудительное обновление:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/update-mihomo.sh | sh -s -- --force
```

Подробности → [обновление и откат](docs/HOWTO_RU.md).

### Watchdog

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/update-watchdog.sh | sh
```

Подробности и логи → [Watchdog](docs/04-watchdog.md).

## 6. Документация

### Быстрый старт и установка

- [Введение](docs/00-intro.md)
- [Быстрый старт](docs/02-quick-start.md)
- [Установка](docs/03-install.md)
- [Руководство](docs/HOWTO_RU.md)

### Система

- [Карта системы](docs/encyclopedia/00-karta-sistemy.md)
- [Архитектура](docs/01-architecture.md)
- [Словарь](docs/encyclopedia/01-slovar.md)
- [Ограничения](docs/09-limitations.md)
- [Roadmap](docs/10-roadmap.md)

### Mihomo

- [Что такое Mihomo](docs/encyclopedia/10-mihomo-eto.md)
- [MetaCubeX](docs/encyclopedia/11-metacubex-eto.md)
- [127.0.0.1 и IP роутера](docs/encyclopedia/13-127-0-0-1-i-ip-routera.md)
- [DNS и Fake-IP](docs/encyclopedia/26-dns-i-fake-ip.md)
- [Порты и config.yaml](docs/encyclopedia/27-porty-i-config-yaml.md)
- [Прокси](docs/encyclopedia/28-proxies.md)
- [Группы прокси](docs/encyclopedia/29-proxy-groups.md)
- [Правила](docs/encyclopedia/30-rules.md)
- [TUN](docs/encyclopedia/31-tun.md)

### Сервисные механизмы

- [Watchdog](docs/04-watchdog.md)
- [bypass_wa](docs/05-bypass-wa.md)
- [S00ubifs](docs/06-s00ubifs.md)
- [Диагностика](docs/08-troubleshooting.md)

### Дополнительно

- [Второй установщик](docs/07-install.md)
- [CHANGELOG](CHANGELOG.md)
- [Лицензия](LICENSE)
