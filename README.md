# 🛡️ Keenetic Auto-Setup Suite

Автоматизированная установка Mihomo и вспомогательных компонентов на Keenetic + Entware.

[English](docs/EN/README.md)

---

## 0. Что должно быть подготовлено

- Keenetic с Entware / OPKG
- Доступ к shell
- Интернет
- KeeneticOS: **Клиент прокси** (`proxy`) и хотя бы один secure-DNS компонент — `dns-tls` **или** `dns-https`
- Если `/opt` на внешнем USB/NVMe: **только EXT4**; компоненты KeeneticOS `ext` и `ext-utils` обязательны

Полные требования → [компоненты KeeneticOS и prerequisites](docs/COMPONENTS_RU.md) · [RAM / storage / ограничения](docs/09-limitations.md)

## 1. Установка

Для обычной установки нужен один запуск. `setup.sh` сам определит профиль хранения (`ram`/`disk`), передаст все проверки каноническому installer и после успешной установки **сразу запустит безопасный импорт конфигурации Mihomo**.

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/setup.sh | sh
```

Во время установки мастер проверяет storage, RAM/swap и обязательные компоненты KeeneticOS. Если состояние нельзя определить безопасно, установка останавливается вместо угадывания.

Расширенные/ручные варианты установки, явный выбор `ram|disk`, offline/SCP-сценарий и storage override вынесены в [подробную документацию по установке](docs/03-install.md).

## 2. Конфигурация Mihomo

После завершения установки `setup.sh` сам откроет этап **Mihomo Config Import** и покажет ссылку на [Mihomo Unified Generator](https://saymer-alt.github.io/link-generators/).

1. Создайте конфигурацию в генераторе.
2. Скопируйте **весь YAML**, начиная с первой строки `mixed-port: 7890`.
3. Вернитесь в SSH и вставьте YAML целиком.
4. Нажмите **Ctrl+D один раз** — это завершает ввод и запускает проверку/установку конфига.

Importer проверяет конфигурацию настоящим `mihomo -t`, соблюдает one-Mihomo invariant, сохраняет предыдущий `config.yaml` как backup, устанавливает новый файл атомарно и автоматически откатывается, если Mihomo не запускается или порт 7890 не поднимается.

Если конфиг пока не нужен, на приглашении importer можно ввести `s` и выполнить импорт позже.

После успешного запуска открыть MetaCubeXD в браузере можно по адресу:

```text
http://192.168.1.1:9090/ui/
```

Для первого входа используйте именно базовый путь `/ui/`, без `#/overview` и других hash-маршрутов. Если у роутера другой LAN-IP, замените `192.168.1.1` на его фактический адрес.

Подробности → [безопасный импорт config.yaml](docs/13-config-import.md) · [что такое Mihomo](docs/encyclopedia/10-mihomo-eto.md) · [исходники генератора](https://github.com/saymer-alt/link-generators)

## 3. Проверка и запуск

Быстро открыть текущий конфиг для ручной правки:

```bash
nano /opt/etc/mihomo/config.yaml
```

После ручной правки перезапустите Mihomo и проверьте статус.

Doctor:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-doctor.sh | sh
```

Перезапуск после ручной правки:

```bash
/opt/etc/init.d/S99mihomo restart
```

Статус:

```bash
/opt/etc/init.d/S99mihomo status
```

Подробности → [диагностика и troubleshooting](docs/08-troubleshooting.md)

## 4. Обновление

Mihomo:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/update-mihomo.sh | sh
```

Watchdog:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/update-watchdog.sh | sh
```

MagiTrickle:

```bash
opkg update && opkg install magitrickle
/opt/etc/init.d/S99magitrickle restart
```

Подробности → [обновление, откат и обслуживание](docs/12-updates.md)

## 5. Дополнительные команды

MIPS TUN migration:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/migrate-mihomo-mips.sh | sh
```

Подробности → [миграция TUN stack](docs/12-updates.md#mips-tun-migration)

Проверка Linux-интерфейсов:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-interface-check.sh | sh
```

Подробности → [interface-name и маршрутизация](ARCHITECTURE.md)

Текущий proxy / failover-failback:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-proxy-selection-watch.sh | sh
```

Подробности → [Proxy Selection Watch](docs/11-proxy-selection-watch.md)

## 6. Скрипты проекта

| Скрипт | Документация |
| --- | --- |
| [`setup.sh`](setup.sh) | Рекомендуемый мастер: автоопределение профиля → установка → безопасный Config Import |
| [`install.sh`](install.sh) | [Установка](docs/03-install.md) |
| [`config-import.sh`](config-import.sh) | [Безопасный импорт config.yaml](docs/13-config-import.md) |
| [`migrate-mihomo-mips.sh`](migrate-mihomo-mips.sh) | [MIPS TUN migration](docs/12-updates.md#mips-tun-migration) |
| [`mihomo-doctor.sh`](mihomo-doctor.sh) | [Диагностика](docs/08-troubleshooting.md) |
| [`mihomo-interface-check.sh`](mihomo-interface-check.sh) | [Архитектура](ARCHITECTURE.md) |
| [`mihomo-proxy-selection-watch.sh`](mihomo-proxy-selection-watch.sh) | [Proxy Selection Watch](docs/11-proxy-selection-watch.md) |
| [`update-mihomo.sh`](update-mihomo.sh) | [Обновление Mihomo](docs/12-updates.md#обновление-mihomo) |
| [`update-watchdog.sh`](update-watchdog.sh) | [Обновление watchdog](docs/12-updates.md#обновление-watchdog) |
| [`mihomo-watchdog.sh`](mihomo-watchdog.sh) | [Watchdog](docs/04-watchdog.md) |
| [`020-bypass-wa.sh`](020-bypass-wa.sh) | [bypass_wa](docs/05-bypass-wa.md) |
| [`S00ubifs`](S00ubifs) | [S00ubifs](docs/06-s00ubifs.md) |

## 7. Справочник

- [Полное HOWTO](docs/HOWTO_RU.md)
- [Энциклопедия / карта системы](docs/encyclopedia/00-karta-sistemy.md)
- [Roadmap](docs/10-roadmap.md)
- [CHANGELOG](CHANGELOG.md)
- [Лицензия](LICENSE)
