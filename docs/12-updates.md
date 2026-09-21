# Обновление и обслуживание

Эта страница — короткий пользовательский путь для обновления Mihomo, watchdog и
миграции TUN stack. Подробное устройство updater'ов и дополнительные сценарии остаются
в [HOWTO](HOWTO_RU.md).

## Обновление Mihomo

Основной поддерживаемый путь:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/update-mihomo.sh | sh
```

Принудительно переустановить доступную текущую версию:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/update-mihomo.sh | sh -s -- --force
```

Что делает updater:

- определяет Entware-архитектуру через `opkg print-architecture`;
- берёт готовый архитектурный `.ipk` Mihomo из release `latest` репозитория
  `saymer-alt/entware-go`;
- не выбирает `nohf`-варианты;
- не запускает второй Mihomo рядом с работающим daemon;
- заранее скачивает и проверяет candidate, затем делает короткий контролируемый stop;
- заменяет бинарник транзакционно, сохраняя rollback-копию;
- при неудаче восстанавливает предыдущий бинарник;
- возвращает сервис в исходное состояние: работал до обновления → запускается снова,
  был остановлен оператором → остаётся остановленным;
- не перезаписывает пользовательский `config.yaml`;
- не делает автоматический downgrade.

После обновления:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo-doctor.sh | sh
```

Подробная модель rollback и one-Mihomo invariant описана в
[HOWTO → Обновление Mihomo](HOWTO_RU.md#8-обновление-mihomo).

## Обновление MagiTrickle

MagiTrickle обновляется штатным Entware/opkg-путём из уже подключённого пакета
MagiTrickle:

```bash
opkg update && opkg install magitrickle
/opt/etc/init.d/S99magitrickle restart
```

Повторный `install.sh` намеренно не используется как автообновлятор уже установленного
MagiTrickle: installer обеспечивает наличие пакета и сервиса, а обновление существующей
установки остаётся явной maintenance-операцией.

Проверить установленную версию:

```bash
opkg list-installed | grep '^magitrickle '
```

После обновления можно запустить Doctor:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo-doctor.sh | sh
```

## Обновление watchdog

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/update-watchdog.sh | sh
```

Актуальная схема:

- полный watchdog: `/opt/bin/mihomo_watchdog.sh`;
- cron wrapper: `/opt/etc/cron.5mins/mihomo_watchdog`;
- updater проверяет новую копию до замены и делает same-filesystem atomic replace;
- известные старые managed layouts мигрируются автоматически;
- пользовательский/неизвестный изменённый файл не удаляется молча;
- дубли managed scheduling в crontab нормализуются без удаления посторонних записей.

Подробности → [Watchdog](04-watchdog.md).

## MIPS TUN migration

`migrate-mihomo-mips.sh` нужен только для конфигураций Mihomo с TUN, когда требуется
перевести `stack: gvisor` на `stack: mips` (Mihomo IP Stack).

Сначала безопасная read-only проверка:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/migrate-mihomo-mips.sh | sh -s -- --check
```

Применить миграцию:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/migrate-mihomo-mips.sh | sh
```

Скрипт:

- меняет только значения `stack:`, не переписывая остальной YAML;
- проверяет поддержку фактическим `mihomo -t`, а не только номером версии;
- соблюдает one-Mihomo invariant и при необходимости делает контролируемую остановку;
- сохраняет `config.yaml.pre-mips` как backup для возврата;
- автоматически откатывается при провале проверки, запуска или contract-port;
- повторный запуск идемпотентен;
- WireGuard `ip-stack` не затрагивает.

Если TUN в конфиге нет, миграция не нужна.

## После обслуживания

Для общей проверки стека используйте Doctor:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo-doctor.sh | sh
```

Если обновление прошло нештатно, дальше идите в
[диагностику](08-troubleshooting.md), а не заменяйте бинарники вручную.
