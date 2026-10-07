# 🛡️ Keenetic Auto-Setup Suite

Автоматизированная установка Mihomo и вспомогательных компонентов на Keenetic + Entware.

[English](docs/EN/README.md)

---

## 0. Что должно быть подготовлено

- Keenetic с Entware / OPKG
- Доступ к shell
- Интернет
- KeeneticOS: **Клиент прокси** (`proxy`), **Фильтрация контента и блокировка рекламы при помощи облачных сервисов** (`dns-filter`), **Модули ядра подсистемы Netfilter** (`opkg-kmod-netfilter`) и хотя бы один secure-DNS компонент — `dns-tls` **или** `dns-https`
- Если `/opt` на внешнем USB/NVMe: **только EXT4**; компоненты KeeneticOS `ext` и `ext-utils` обязательны
- Для штатного профиля с внутренним `/opt` проект использует **S00ubifs**: временные каталоги `/opt/tmp`, `/opt/var/log` и `/opt/var/run` переносятся в `tmpfs` (RAM), что уменьшает постоянные записи во внутреннюю флешку; конфиги и пакеты остаются на постоянном хранилище

Если Entware ещё не установлен и `/opt` планируется на USB/SSD → [подготовка внешнего EXT4-накопителя и установка Entware](docs/16-entware-external-storage.md).

Полные требования → [компоненты KeeneticOS и prerequisites](docs/COMPONENTS_RU.md) · [RAM / storage / ограничения](docs/09-limitations.md) · [S00ubifs: защита флешки и RAM-режим](docs/06-s00ubifs.md)

## 1. Установка

Для обычной установки нужен один запуск. `setup.sh` сам определит профиль хранения (`ram`/`disk`), передаст все проверки каноническому installer и после успешной установки **сразу запустит безопасный импорт конфигурации Mihomo**.

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/setup.sh | sh
```

Если `curl` зависает **до первого вывода setup/Doctor** на TLS handshake с `raw.githubusercontent.com`, используйте совместимый повтор (сертификат по-прежнему проверяется):

```bash
curl -4 -fSsL --connect-timeout 5 --max-time 20 --curves X25519 https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/setup.sh | sh
```

Обычный TLS остаётся основным путём. `X25519` — только compatibility fallback для сетей, где увеличенный TLS ClientHello от OpenSSL 3.5 не проходит; после запуска project downloader сам пробует normal TLS → X25519 → wget/API fallback.

Во время установки мастер проверяет storage, RAM/swap и обязательные компоненты KeeneticOS. Если состояние нельзя определить безопасно, установка останавливается вместо угадывания.

> **Важно для 512 МБ-класса:** 512 МБ физической RAM без memory-pressure backend проект больше не считает поддерживаемой базой. Для новой установки обязателен активный KeeneticOS zRAM **или** проверенный внешний storage-backed swap; если нет обоих, installer останавливается с ERROR, а Doctor показывает FAIL. Исключений для режима точки доступа нет.

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

> **MagiTrickle устанавливается автоматически, но ваш пользовательский `.mtrickle`-конфиг — нет.** `setup.sh`/`install.sh` сами добавляют репозиторий, ставят пакет MagiTrickle, запускают сервис и настраивают системную интеграцию. Но сохранённые группы, правила, интерфейсы и другие пользовательские настройки из экспортированного `.mtrickle`-файла installer намеренно не импортирует. После чистой установки откройте MagiTrickle на `http://<IP-роутера>:8080/` и импортируйте свой ранее сохранённый конфиг вручную, если он нужен.

Практический пример: [реальный MagiTrickle field sample — 8 групп / 287 правил](docs/17-magitrickle-field-lists.md). Это датированный пользовательский экспорт, а не официальный или универсальный список доменов.

Для первого входа в MetaCubeXD после импорта полного конфига используйте именно базовый путь `/ui/`, без `#/overview` и других hash-маршрутов. Если у роутера другой LAN-IP, замените `192.168.1.1` на его фактический адрес в обеих ссылках.

Подробности → [безопасный импорт config.yaml](docs/13-config-import.md) · [что такое Mihomo](docs/encyclopedia/10-mihomo-eto.md) · [исходники генератора](https://github.com/saymer-alt/link-generators)

## 3. Проверка и запуск

Быстро открыть текущий конфиг для ручной правки:

```bash
nano /opt/etc/mihomo/config.yaml
```

Если нужно полностью заменить конфиг вручную, можно сначала сохранить текущую версию в `.bak`, сразу очистить файл и открыть уже пустой `config.yaml`. Команда готова для копирования в консоль целиком одной строкой:

```bash
cp /opt/etc/mihomo/config.yaml /opt/etc/mihomo/config.yaml.bak && : > /opt/etc/mihomo/config.yaml && nano /opt/etc/mihomo/config.yaml
```

Если backup не нужен, короткий вариант:

```bash
: > /opt/etc/mihomo/config.yaml && nano /opt/etc/mihomo/config.yaml
```

> **Важно:** обе команды обнуляют текущий `config.yaml` до 0 байт до открытия `nano`. Не перезапускайте Mihomo, пока не вставите новый корректный YAML и не сохраните файл.

После ручной правки перезапустите Mihomo и проверьте статус.

Doctor:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-doctor.sh | sh
```
CLI использует единый «светофор»: зелёный — штатный ход/`OK`, голубой (cyan) — `INFO`, жёлтый — `WARN`, красный — `ERROR`/`FAIL`. Цвет — только подсказка: префиксы всегда сохраняются, а при редиректе, `NO_COLOR` или `TERM=dumb` ANSI отключается. Полный контракт: [цвета и статусы CLI](docs/18-output-colors.md).

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

Legacy-конфиг без TUN / `mitun0`:

```bash
# сначала read-only проверка
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/migrate-mihomo-tun.sh | sh -s -- --check
# затем применение
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/migrate-mihomo-tun.sh | sh
```

Мигратор добавляет стандартный project TUN с `device: mitun0` и `auto-route: false`. Для Mihomo >= 1.19.31 выбирается `stack: mips`; для более старой/неподтверждённой версии используется совместимый `gvisor`. Существующий `tun:` он не переписывает.

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

| Скрипт | Назначение / документация |
| --- | --- |
| [`setup.sh`](setup.sh) | [Рекомендуемая установка проекта](docs/14-setup.md) |
| [`install.sh`](install.sh) | [Основной установщик с ручным выбором профиля](docs/03-install.md) |
| [`config-import.sh`](config-import.sh) | [Импорт и безопасная замена `config.yaml`](docs/13-config-import.md) |
| [`migrate-mihomo-tun.sh`](migrate-mihomo-tun.sh) | [Добавить TUN/`mitun0` в legacy-конфиг без секции `tun:`](docs/12-updates.md#legacy-config-добавление-tun--mitun0) |
| [`migrate-mihomo-mips.sh`](migrate-mihomo-mips.sh) | [Перевод TUN-конфига с gVisor на MIPS](docs/12-updates.md#mips-tun-migration) |
| [`mihomo-doctor.sh`](mihomo-doctor.sh) | [Доктор: полная диагностика проекта](docs/08-troubleshooting.md) |
| [`mihomo-interface-check.sh`](mihomo-interface-check.sh) | [Показать Linux-имена WAN/VPN-интерфейсов для `interface-name`](ARCHITECTURE.md) |
| [`mihomo-proxy-selection-watch.sh`](mihomo-proxy-selection-watch.sh) | [Показать, какой сервер Mihomo выбран сейчас](docs/11-proxy-selection-watch.md) |
| [`mihomo-route-check.sh`](mihomo-route-check.sh) | [Проверить доступность конкретного сайта через Mihomo](docs/15-route-check.md) |
| [`update-mihomo.sh`](update-mihomo.sh) | [Обновить ядро Mihomo с проверкой и откатом](docs/12-updates.md#обновление-mihomo) |
| [`update-watchdog.sh`](update-watchdog.sh) | [Обновить механизм watchdog](docs/12-updates.md#обновление-watchdog) |
| [`mihomo-watchdog.sh`](mihomo-watchdog.sh) | [Проверять Mihomo и перезапускать его при подтверждённом сбое](docs/04-watchdog.md) |
| [`020-bypass-wa.sh`](020-bypass-wa.sh) | [Перехватывать VoIP-трафик и передавать его в отдельную политику `bypass_wa`](docs/05-bypass-wa.md) |
| [`S00ubifs`](S00ubifs) | [Перенести временные каталоги Entware в RAM и снизить запись во флешку](docs/06-s00ubifs.md) |

## 7. Справочник

- [Полное HOWTO](docs/HOWTO_RU.md)
- [Энциклопедия / карта системы](docs/encyclopedia/00-karta-sistemy.md)
- [Roadmap](docs/10-roadmap.md)
- [CHANGELOG](CHANGELOG.md)
- [Лицензия](LICENSE)