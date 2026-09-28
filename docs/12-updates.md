# Обновление и обслуживание

В development B6/C1 process detection работает без `pidof` через `/proc`;
неизвестное состояние запрещает probe/commit/start. После rollback updater
по-прежнему проверяет, что восстановленный canonical executable и `/proc/<pid>/exe` — один и тот же device+inode через `test -ef`, без GNU `stat -c`. Ошибки resource
profile остаются advisory для updater; имя `zram.swap` не делает файл native zRAM.
Подробности и ограничения: [process/swap contract](20-process-swap-detection.md).

Операции обслуживания используют [общий lifecycle lock](19-lifecycle-lock.md).
Не запускайте старые и новые копии инструментов одновременно; при занятом lock
повторите операцию после завершения владельца, не удаляя его state вручную.

Эта страница — короткий пользовательский путь для обновления Mihomo, watchdog и
миграции TUN stack. Подробное устройство updater'ов и дополнительные сценарии остаются
в [HOWTO](HOWTO_RU.md).

## Обновление Mihomo

Основной поддерживаемый путь:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/update-mihomo.sh | sh
```

Принудительно переустановить доступную текущую версию:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/update-mihomo.sh | sh -s -- --force
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
- не перезаписывает пользовательский `config.yaml`; updater меняет бинарник Mihomo, а не пользовательскую конфигурацию;
- не делает автоматический downgrade.

Development C7 проверяет version string целиком до сравнения и требует успешного
exit code candidate `-v`. Malformed/non-orderable версии не разрешают замену;
`--force` допускает повторную установку той же версии, но не downgrade.
Нечитаемая версия после безопасного stop остаётся прежним repair-сценарием;
opkg/project metadata не подменяет runtime truth. Запущенный daemon не пробуется
ради сравнения; решение откладывается до stop. Explicit package/source override
у Mihomo updater отсутствует, downgrade остаётся отдельной ручной операцией.

После обновления:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-doctor.sh | sh
```

Если требуется заменить сам `config.yaml`, используйте `config-import.sh`: он сохраняет предыдущий конфиг как `config.yaml.bak`, валидирует candidate и откатывает замену при неуспешном запуске/проверке порта.

Подробная модель rollback и one-Mihomo invariant описана в
[HOWTO → Обновление Mihomo](HOWTO_RU.md#8-обновление-mihomo).

В development-версии после B3/B4 rollback сначала подтверждает остановку daemon,
копирует backup в stage рядом с canonical binary, проверяет содержимое, права и
версию и возвращает binary через atomic rename. Только затем восстанавливается
project binary-state (или его исходное отсутствие), без изменений opkg database.
Ранее работающий сервис запускается после восстановления обоих файлов; его
`/proc/<pid>/exe` должен ссылаться на тот же device+inode, что и восстановленный binary (`test -ef`). INT/TERM/HUP
после commit/start проходят тот же recovery; повторные сигналы во время него
игнорируются. При ошибке recovery автоматический start не выполняется либо
неверифицированный runtime повторно останавливается; результат — ERROR, backups
сохраняются для ручного восстановления. Если stop невозможен, процесс может
остаться работающим: успех rollback не объявляется. `/tmp` backups исчезают при
reboot; следующий updater не удаляет чужие recovery backups.

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
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-doctor.sh | sh
```

## Обновление watchdog

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/update-watchdog.sh | sh
```

Актуальная схема:

- полный watchdog: `/opt/bin/mihomo_watchdog.sh`;
- cron wrapper: `/opt/etc/cron.5mins/mihomo_watchdog`;
- updater проверяет новую копию до замены и делает same-filesystem atomic replace;
- известные старые managed layouts мигрируются автоматически;
- пользовательский/неизвестный изменённый файл не удаляется молча;
- дубли managed scheduling в crontab нормализуются без удаления посторонних записей.

Подробности → [Watchdog](04-watchdog.md).

Development C2/C3: updater держит общий lifecycle lock, включая stage cleanup.
Canonical watchdog и managed wrapper имеют root:root/0755, backup — 0600 вне
cron.5mins. Ошибка до atomic rename оставляет прежний файл; общий rollback всех
файлов не обещается, каждый committed файл отдельно валиден. Распознанные
пяти-минутные direct/run-parts routes сводятся к одному; комментарии не являются
active routes. Неизвестные active references сохраняются с ERROR для ручной
проверки. Корректный повторный запуск не меняет bytes/inode/mtime managed files.

## Legacy config: добавление TUN / `mitun0`

Для старых `config.yaml`, в которых **вообще нет top-level секции `tun:`**, используется отдельный `migrate-mihomo-tun.sh`. Он не переписывает proxy/rules/DNS и не заменяет существующий TUN.

Read-only проверка:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/migrate-mihomo-tun.sh | sh -s -- --check
```

Применение:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/migrate-mihomo-tun.sh | sh
```

Если `tun:` отсутствует, migrator добавляет стандартный router-профиль генератора:

```yaml
tun:
  enable: true
  device: mitun0
  stack: mips        # Mihomo >= 1.19.31; иначе gvisor
  auto-route: false
  auto-detect-interface: true
```

Политика выбора стека:
- версия Mihomo **>= 1.19.31** → предпочитается `mips`;
- версия старее 1.19.31 → добавляется совместимый `gvisor` и выводится подсказка, что MIPS требует обновления;
- если версия формально подходит, но фактический `mihomo -t` отвергает MIPS, migrator откатывается на `gvisor` и валидирует повторно;
- если сам бинарник нельзя безопасно проверить с остановленным daemon, config не изменяется.

Транзакция соблюдает one-Mihomo invariant: при работающем daemon выполняется контролируемая остановка, создаются per-run rollback и постоянный `config.yaml.pre-tun`, кандидат проходит `mihomo -t`, затем выполняется same-filesystem atomic replace. После возврата ранее работающего сервиса migrator ждёт процесс, contract-port 7890 и реальное появление `/sys/class/net/mitun0`; при провале автоматически возвращается исходный config. Если сервис был остановлен пользователем, он остаётся остановленным.

Если `tun:` уже существует, этот migrator делает no-op и ничего не нормализует. Для существующего `stack: gvisor` → `stack: mips` используется отдельный `migrate-mihomo-mips.sh`.

Development C5 вооружает recovery до commit и до stop: INT/TERM/HUP и ошибочный
EXIT возвращают per-run config через same-filesystem stage/rename и проверяют
восстановление прежнего сервиса. Во время recovery повторные сигналы игнорируются.
Failed recovery сохраняет per-run backup и сообщает ошибку; historical `.pre-tun`
не подменяет текущий snapshot. Power-loss/SIGKILL recovery не гарантируется.

Doctor v1.2.16 проверяет наличие top-level `tun:`: при его отсутствии даёт INFO-подсказку на `migrate-mihomo-tun.sh --check` и объясняет, какой stack будет выбран по известной версии.

## MIPS TUN migration

`migrate-mihomo-mips.sh` нужен только для конфигураций Mihomo с TUN, когда требуется
перевести `stack: gvisor` на `stack: mips` (Mihomo IP Stack).

Сначала безопасная read-only проверка:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/migrate-mihomo-mips.sh | sh -s -- --check
```

Применить миграцию:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/migrate-mihomo-mips.sh | sh
```

Скрипт:

- меняет только значения `stack:`, не переписывая остальной YAML;
- проверяет поддержку фактическим `mihomo -t`, а не только номером версии;
- соблюдает one-Mihomo invariant и при необходимости делает контролируемую остановку;
- сохраняет `config.yaml.pre-mips` как исторический backup первой миграции;
- для текущей транзакции сохраняет отдельный `.config.yaml.mips-backup.<pid>` рядом
  с config; rollback возвращает именно этот snapshot через stage + atomic rename
  с сохранением permissions, даже если commit candidate не состоялся;
- автоматически откатывается при провале проверки, запуска или contract-port;
- повторный запуск идемпотентен;
- WireGuard `ip-stack` не затрагивает.

Per-run snapshot удаляется после успеха или успешного восстановления; при ошибке
recovery сохраняется, а скрипт печатает его путь. Historical `.pre-mips` никогда
не подменяет snapshot текущего запуска. Эти изменения ещё требуют hardware acceptance
и не означают продвижение development-ветки в `stable`.

Если TUN в конфиге нет, текущий migrator ничего не добавляет: он **не создаёт `tun:`/`mitun0` с нуля**, а только переводит уже существующий `stack: gvisor` в `stack: mips`. Doctor v1.2.16 выводит INFO-подсказку, когда видит `stack: gvisor` и известная версия Mihomo соответствует документированному минимуму 1.19.31; это только предварительная готовность, окончательный feature-gate выполняет сам migrator через `mihomo -t`.

## После обслуживания

Для общей проверки стека используйте Doctor:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-doctor.sh | sh
```

Если обновление прошло нештатно, дальше идите в
[диагностику](08-troubleshooting.md), а не заменяйте бинарники вручную.

---

Формат `[OK]/[INFO]/[WARN]/[ERROR]/[FAIL]` и единая цветовая семантика updater'ов описаны в [18 — цвета и статусы CLI](18-output-colors.md).
