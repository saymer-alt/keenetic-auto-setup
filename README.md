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
- Для штатного профиля с внутренним `/opt` проект использует **S00ubifs**: временные каталоги `/opt/tmp`, `/opt/var/log` и `/opt/var/run` переносятся в `tmpfs` (RAM), что уменьшает постоянные записи во внутреннюю флешку; конфиги и пакеты остаются на постоянном хранилище

Полные требования → [компоненты KeeneticOS и prerequisites](docs/COMPONENTS_RU.md) · [RAM / storage / ограничения](docs/09-limitations.md) · [S00ubifs: защита флешки и RAM-режим](docs/06-s00ubifs.md)

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

После импорта полноценного `config.yaml` из генератора доступны два основных веб-интерфейса:

```text
MetaCubeXD:   http://192.168.1.1:9090/ui/
MagiTrickle:  http://192.168.1.1:8080/
```

Если на этапе Config Import выбрать `s`, остаётся минимальный bootstrap-конфиг с `mixed-port: 7890`: Mihomo работает, но `external-controller`/MetaCubeXD ещё не настроены, поэтому порт 9090 в этом состоянии **не должен** слушать. MagiTrickle на 8080 доступен независимо.

Для первого входа в MetaCubeXD после импорта полного конфига используйте именно базовый путь `/ui/`, без `#/overview` и других hash-маршрутов. Если у роутера другой LAN-IP, замените `192.168.1.1` на его фактический адрес в обеих ссылках.

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

Точечная read-only проверка одного домена/IP через цепочку ProxyN → Mihomo:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-route-check.sh -o /tmp/mihomo-route-check.sh && \
sh /tmp/mihomo-route-check.sh example.com
```

Helper показывает DNS, проектный ProxyN, порт 7890, текущий выбор Mihomo и делает SOCKS5h-пробу к указанной цели. Он не меняет маршрутизацию и отдельно предупреждает, что успешная SOCKS-проба не доказывает выбор политики конкретным LAN-клиентом.

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

Обновление Mihomo не перезаписывает пользовательский `/opt/etc/mihomo/config.yaml`. Безопасный Config Import перед заменой конфига сохраняет `config.yaml.bak` и автоматически откатывается при неуспешной проверке/запуске.

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

### Advanced / risk zone

Обычная эксплуатация не требует ручного изменения `iptables`, ProxyN, policy routing, DNS или storage override. Эти действия считаются advanced/risk-zone операциями: ошибка может затронуть весь LAN или закрыть доступ к роутеру. Для диагностики сначала используйте Doctor и read-only helpers; ручные изменения делайте только когда понятна конкретная зависимость и есть путь отката.

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
| [`setup.sh`](setup.sh) | [Рекомендуемый мастер: автоопределение профиля → установка → безопасный Config Import](docs/14-setup.md) |
| [`install.sh`](install.sh) | [Установка](docs/03-install.md) |
| [`config-import.sh`](config-import.sh) | [Безопасный импорт config.yaml](docs/13-config-import.md) |
| [`migrate-mihomo-mips.sh`](migrate-mihomo-mips.sh) | [MIPS TUN migration](docs/12-updates.md#mips-tun-migration) |
| [`mihomo-doctor.sh`](mihomo-doctor.sh) | [Диагностика](docs/08-troubleshooting.md) |
| [`mihomo-interface-check.sh`](mihomo-interface-check.sh) | [Архитектура](ARCHITECTURE.md) |
| [`mihomo-proxy-selection-watch.sh`](mihomo-proxy-selection-watch.sh) | [Proxy Selection Watch](docs/11-proxy-selection-watch.md) |
| [`mihomo-route-check.sh`](mihomo-route-check.sh) | [Точечная read-only диагностика домена/IP через ProxyN → Mihomo](docs/15-route-check.md) |
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
