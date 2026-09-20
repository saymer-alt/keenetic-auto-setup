# 🛡️ Keenetic Auto-Setup Suite

Автоматизированный инструмент для установки сетевых и вспомогательных инструментов на Keenetic, их автономной работы и защиты внутренней памяти от износа.

[English](docs/EN/README.md)

---

## 0. Что должно быть подготовлено

- Keenetic с установленным Entware / OPKG
- RAM и выбор /opt-памяти — раздельные решения:
  - **256 МБ+ RAM — поддерживаемый профиль** (проверен вживую; работа с внутренней памяти Keenetic — проверенный вариант). **512 МБ+ — самый запасной профиль.** Active swap не обязателен: на 256 МБ он даёт дополнительный запас (информирует installer/Doctor), на 512 МБ+ — по желанию.
  - **128 МБ-класс — только best-effort/experimental и только с активным swap**: минимум **384 МБ** активного swap (512 МБ — предпочтительно). Без достаточного активного swap установщик останавливается на раннем preflight, до скачиваний и изменений. **Внимание про zRAM:** авто-размер KeeneticOS zRAM примерно равен физической RAM (~128 МБ), поэтому zRAM сам по себе не закрывает это требование — нужен дополнительный дисковый swap на внешнем носителе (может сосуществовать с zRAM; установщик и Doctor оценивают суммарный активный swap). Swap проект сам никогда не создаёт и не меняет. Стабильность не гарантирована даже со swap; `disk` предпочтительнее `ram`.
- Компонент KeeneticOS «Клиент прокси» (Proxy client) — обязателен: без него не существуют интерфейсы Proxy*, и установщик не сможет создать проектный ProxyN
- Компонент «Фильтрация контента и блокировка рекламы при помощи облачных сервисов» — обязателен для поддерживаемого DNS-профиля: проекту нужен `dns-proxy intercept enable` (это не означает, что нужно выбирать облачный фильтр для клиентов)
- DoT и/или DoH на роутере настоятельно рекомендуются для upstream DNS: перехват port 53 решает другую задачу и сам по себе не защищает запросы Keenetic к резолверу от вмешательства провайдера
- Доступ к shell Entware (SSH — обычный способ, но компонент KeeneticOS «Сервер SSH» не является runtime-зависимостью проекта)
- Интернет

## 1. Установка

### Встроенная память роутера — проверенный вариант

При установке во внутреннюю память рекомендуется включить штатный zRAM KeeneticOS: KeeneticOS имеет встроенный zRAM («Сжатый RAM-диск для системного swap» / Compressed RAM disk for system swap): это swap в сжатой RAM, без записи классического swap-файла во внутреннюю NAND-память. Включается в веб-интерфейсе в системных настройках производительности (путь и формулировки зависят от прошивки/языка). После установки проверьте активный swap через `mihomo-doctor.sh` (он показывает объём и бэкенды: zRAM и/или дисковый swap).

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/install.sh | sh
```

### Внешний носитель — USB HDD / NVMe (больше ресурса и запаса; на 128 МБ-классе — предпочтительно в `disk`-режиме)

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/install.sh | sh -s -- disk
```

Дождаться завершения установки.

Подробности → [установка](docs/03-install.md) · [компоненты и prerequisites](docs/COMPONENTS.md).

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

Если сгенерированная конфигурация включает TUN, Mihomo создаёт интерфейс `mitun0`; его рекомендуется использовать в MagiTrickle как интерфейс для перенаправления. Сам bootstrap содержит только `mixed-port: 7890`.

Подробности → [Mihomo](docs/encyclopedia/10-mihomo-eto.md) · [MagiTrickle и маршрутизация](docs/01-architecture.md) · [первый вход в UI](docs/encyclopedia/12-pervyj-vhod-v-ui.md).

## 3. Проверка и запуск

Если Mihomo уже запущен, **не запускайте `mihomo -t` параллельно**: на части Keenetic второй экземпляр Mihomo приводит к SIGSEGV. Для безопасной read-only проверки установленного стека используйте Doctor:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo-doctor.sh | sh
```

После изменения конфигурации перезапустить сервис:

```bash
/opt/etc/init.d/S99mihomo restart
```

Проверить статус:

```bash
/opt/etc/init.d/S99mihomo status
```

Прокси Mihomo:

`127.0.0.1:7890`

Комплексная проверка установки — read-only Doctor (ничего не меняет и ничего не перезапускает; весь вывод можно целиком отправить разработчику):

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo-doctor.sh | sh
```

Если нужно не проверить здоровье стека, а **увидеть, какой конечный proxy-сервер выбран Mihomo сейчас и когда происходит failover/failback**, используйте необязательный read-only helper `mihomo-proxy-selection-watch.sh`.

Самый понятный вариант для первого запуска:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo-proxy-selection-watch.sh -o /tmp/mihomo-proxy-selection-watch.sh
sh /tmp/mihomo-proxy-selection-watch.sh --help
sh /tmp/mihomo-proxy-selection-watch.sh
sh /tmp/mihomo-proxy-selection-watch.sh --watch 1
```

Он только читает Controller API (`GET /proxies`), ничего не выбирает и не перезапускает. Он **не смотрит маршруты Keenetic**: «route» здесь означает цепочку выбора proxy-групп Mihomo. Для работы Controller должен быть включён; `127.0.0.1:9090` — значение по умолчанию самого helper'а, а не встроенный default Mihomo.

Подробная инструкция, которую можно просто отправить другому пользователю → [Mihomo Proxy Selection Watch](docs/11-proxy-selection-watch.md).  
Общая диагностика → [проверка работы](docs/08-troubleshooting.md) · [полное HOWTO](docs/HOWTO_RU.md).

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
- [Mihomo Proxy Selection Watch — выбранный proxy и failover/failback](docs/11-proxy-selection-watch.md)

### Дополнительно

- [Подробно об установке](docs/07-install.md)
- [CHANGELOG](CHANGELOG.md)
- [Лицензия](LICENSE)
