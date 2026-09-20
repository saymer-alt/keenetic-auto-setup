# 🛡️ Keenetic Auto-Setup Suite

Автоматизированная установка Mihomo и вспомогательных компонентов на Keenetic + Entware.

[English](docs/EN/README.md)

---

## 0. Что должно быть подготовлено

- Keenetic с Entware / OPKG
- Доступ к shell
- Интернет

Полные требования → [компоненты и prerequisites](docs/COMPONENTS.md) · [RAM / storage / ограничения](docs/09-limitations.md)

## 1. Установка

### Встроенная память роутера — проверенный вариант

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/install.sh | sh
```

### Внешний носитель — USB HDD / NVMe

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/install.sh | sh -s -- disk
```

Подробности → [установка](docs/03-install.md) · [полное HOWTO](docs/HOWTO_RU.md)

## 2. Конфигурация Mihomo

Генератор → [Mihomo Unified Generator](https://github.com/saymer-alt/link-generators)

```bash
nano /opt/etc/mihomo/config.yaml
```

Подробности → [Mihomo](docs/encyclopedia/10-mihomo-eto.md) · [архитектура и маршрутизация](docs/01-architecture.md)

## 3. Проверка и запуск

Doctor:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo-doctor.sh | sh
```

Перезапуск:

```bash
/opt/etc/init.d/S99mihomo restart
```

Статус:

```bash
/opt/etc/init.d/S99mihomo status
```

Диагностика → [Troubleshooting](docs/08-troubleshooting.md)

## 4. Обновление

Mihomo:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/update-mihomo.sh | sh
```

Подробности → [обновление Mihomo](docs/HOWTO_RU.md)

Watchdog:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/update-watchdog.sh | sh
```

Подробности → [Watchdog](docs/04-watchdog.md)

## 5. Дополнительные команды

MIPS TUN migration:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/migrate-mihomo-mips.sh | sh
```

Подробности → [MIPS / update HOWTO](docs/HOWTO_RU.md)

Проверка Linux-интерфейсов:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo-interface-check.sh | sh
```

Подробности → [interface-name](ARCHITECTURE.md)

Текущий proxy / failover-failback:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo-proxy-selection-watch.sh | sh
```

Подробности → [Proxy Selection Watch](docs/11-proxy-selection-watch.md)

## 6. Скрипты проекта

| Скрипт | Документация |
| --- | --- |
| [`install.sh`](install.sh) | [Установка](docs/03-install.md) |
| [`migrate-mihomo-mips.sh`](migrate-mihomo-mips.sh) | [HOWTO](docs/HOWTO_RU.md) |
| [`mihomo-doctor.sh`](mihomo-doctor.sh) | [Диагностика](docs/08-troubleshooting.md) |
| [`mihomo-interface-check.sh`](mihomo-interface-check.sh) | [Архитектура](ARCHITECTURE.md) |
| [`mihomo-proxy-selection-watch.sh`](mihomo-proxy-selection-watch.sh) | [Proxy Selection Watch](docs/11-proxy-selection-watch.md) |
| [`update-mihomo.sh`](update-mihomo.sh) | [HOWTO](docs/HOWTO_RU.md) |
| [`update-watchdog.sh`](update-watchdog.sh) | [Watchdog](docs/04-watchdog.md) |
| [`mihomo-watchdog.sh`](mihomo-watchdog.sh) | [Watchdog](docs/04-watchdog.md) |
| [`020-bypass-wa.sh`](020-bypass-wa.sh) | [bypass_wa](docs/05-bypass-wa.md) |
| [`S00ubifs`](S00ubifs) | [S00ubifs](docs/06-s00ubifs.md) |
| [`tests/contracts.sh`](tests/contracts.sh) | [Стратегия тестирования](docs/TESTING_STRATEGY.md) |

## 7. Документация

- [Быстрый старт](docs/02-quick-start.md)
- [Установка](docs/03-install.md)
- [HOWTO](docs/HOWTO_RU.md)
- [Архитектура](docs/01-architecture.md)
- [Диагностика](docs/08-troubleshooting.md)
- [Ограничения](docs/09-limitations.md)
- [Roadmap](docs/10-roadmap.md)
- [CHANGELOG](CHANGELOG.md)
- [Лицензия](LICENSE)
