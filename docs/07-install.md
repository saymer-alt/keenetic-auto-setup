# 07 — внутреннее устройство install.sh

Эта страница описывает **техническую реализацию** единого installer'а. Для обычной
установки используйте [03-install.md](03-install.md); здесь нет второго quick-start.

## Граница ответственности

`install.sh` поддерживает aarch64 / armv7 / mipsel / mips и два режима хранения:

- `ram` — проект включает `S00ubifs` для tmpfs runtime-каталогов;
- `disk` — внешний persistent `/opt`, `S00ubifs` не ставится.

Перед installer-managed загрузками и изменениями выполняются два read-only gate:

1. resource-profile (`/proc/meminfo`, `/proc/swaps`, `/proc/mounts`);
2. обязательные компоненты KeeneticOS: `proxy`, `dns-filter`,
   `opkg-kmod-netfilter`.

Подробные требования: [COMPONENTS_RU.md](COMPONENTS_RU.md).

## Архитектура Entware

Installer читает `opkg print-architecture` и выбирает один из поддерживаемых package
suffix:

| Архитектура | Package suffix |
|---|---|
| aarch64 | `aarch64-3.10` |
| armv7 | `armv7-3.2` |
| mipsel | `mipsel-3.4` |
| mips | `mips-3.4` |

Один и тот же `install.sh` используется и на MT7621/mipsel; отдельного installer'а
для MT7621 больше нет.

## Источник Mihomo и fallback

Основной источник — готовый архитектурный `.ipk` из release `latest` репозитория
`saymer-alt/entware-go`.

Порядок:

1. GitHub API;
2. резервный разбор ответа/страницы release;
3. скачивание найденного asset;
4. `opkg install <downloaded.ipk>`;
5. если весь GitHub-путь не дал успешной установки — last resort
   `opkg install mihomo` из настроенного Entware feed.

Переход к Entware feed всегда виден как WARN: версия там может отставать от
`entware-go:latest`.

## Bootstrap config.yaml

Project contract endpoint — `127.0.0.1:7890`.

На чистой установке installer гарантирует минимальный bootstrap:

```yaml
mixed-port: 7890
```

Существующий пользовательский `config.yaml` не переписывается. Нетронутый пакетный
placeholder может быть заменён bootstrap'ом; актуальный `entware-go` пакет сам также
содержит `mixed-port: 7890`.

## ProxyN и bypass_wa

Проектный Proxy-интерфейс определяется **двумя** признаками:

- description `mihomo t2sN`;
- upstream `127.0.0.1:7890`.

Если проектного интерфейса нет, используется свободный `ProxyN`; чужой `Proxy0`
не перезаписывается.

Политика `bypass_wa` получает `permit global <ProjectProxyN>`, при этом существующие
ручные permits не удаляются и не переупорядочиваются.

## DNS interception

Поддерживаемый профиль требует `dns-proxy intercept enable`.

Installer сначала читает состояние, при необходимости включает его и сразу проверяет
running-config. Отсутствие read-back считается ошибкой совместимости, а не успешной
установкой.

## MagiTrickle

Installer добавляет upstream repository MagiTrickle, обновляет metadata и гарантирует
наличие пакета. Если MagiTrickle уже установлен, повторный install не используется как
скрытый package-updater.

Явное обновление существующей установки описано в [12-updates.md](12-updates.md).

## Watchdog

Канонический layout:

- `/opt/bin/mihomo_watchdog.sh` — полный script;
- `/opt/etc/cron.5mins/mihomo_watchdog` — thin wrapper.

На чистой установке watchdog проходит marker + `sh -n`, затем staged copy делается
на filesystem назначения и фиксируется atomic rename. Исторические layouts мигрирует
`update-watchdog.sh`, а не installer.

## Финальный self-check

После restart Mihomo installer проверяет ProxyN, DNS interception, bypass, watchdog,
cron, MagiTrickle, `S00ubifs` в `ram`-режиме, contract port `7890` и свободное
место на `/opt`.

Правило одного Mihomo универсально: если daemon уже работает, self-check не запускает
второй экземпляр через `mihomo -v` или `mihomo -t`.

После старта contract port проверяется сразу, затем с bounded retry до 5 секунд.
Это устраняет ложный startup WARN на более медленном MT7621, не скрывая реальный отказ.

## Повторный запуск

Installer проектируется идемпотентным: существующий project ProxyN переиспользуется,
DNS interception не дублируется, project-managed layouts распознаются, пользовательский
Mihomo config не переписывается.

Installer не является универсальным updater'ом. Для обновления Mihomo, MagiTrickle и
watchdog используйте [12-updates.md](12-updates.md).

## Диагностика

- [03-install.md](03-install.md) — пользовательская установка;
- [08-troubleshooting.md](08-troubleshooting.md) — диагностика;
- `mihomo-doctor.sh` — read-only проверка установленного стека.
