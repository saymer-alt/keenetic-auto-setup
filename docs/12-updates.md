# Обновление и обслуживание

B6/C1 process detection работает без обязательного `pidof` через `/proc`;
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

## Единая точка входа: kas-update

`kas-update.sh` — единая команда обслуживания уже установленного KAS Core:
сначала посмотреть, потом явно применить (issue #390). Внутри `--apply` не
копирует логику замены, а запускает штатный транзакционный
`update-watchdog.sh` с канала: проверка кандидата, гигиена backup, atomic
rename и cron-нормализация остаются в нём.

Для старых установок, где локального `kas-update` ещё нет, первоначальный
запуск — через GitHub:

```bash
curl -fSsL -o /tmp/kas-update.sh https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/kas-update.sh && sh -n /tmp/kas-update.sh && sh /tmp/kas-update.sh --check
```

Затем явное применение:

```bash
sh /tmp/kas-update.sh --apply
```

Что делает `--check` (строго read-only):

- определяет фактическое состояние установленной пары watchdog: canonical
  `/opt/bin/mihomo_watchdog.sh` + cron wrapper `/opt/etc/cron.5mins/mihomo_watchdog`;
- сравнивает SHA-256 установленного файла с версией на канале
  (`KEENETIC_AUTO_SETUP_REF`, по умолчанию `stable`). Версий у script-installed
  KAS Core на устройстве нет — только содержимое; фиктивные номера не выводятся;
- показывает информационный инвентарь остальных компонентов (Mihomo binary,
  MagiTrickle, netfilter hook, S00ubifs, пользовательский config) без изменений;
- всё, что не удалось достоверно определить (чужой/изменённый файл, symlink,
  обрыв сети), помечается `UNKNOWN` — догадками не подменяется;
- ничего не меняет.

Что делает `--apply` (явное действие):

- повторно оценивает состояние, печатает план, при интерактивном запуске
  запрашивает подтверждение; без TTY требуется `--yes`;
- применяет только распознанные KAS-managed части (canonical watchdog и
  cron wrapper) через транзакционный updater; при `UNKNOWN` — отказ без
  каких-либо изменений;
- после применения проверяет фактический SHA-256 и сообщает результат;
- повторный запуск идемпотентен: уже актуальное состояние не переписывается.

`kas-update` никогда не трогает: Mihomo binary, `config.yaml`, MagiTrickle,
netfilter, политики маршрутизации, WAN/VPN, Entware-пакеты, KAS Web. Mihomo
и MagiTrickle остаются отдельными явно выбираемыми обновлениями (см. ниже).
Doctor и `config-import.sh` установленных копий не имеют — они исполняются с
GitHub при каждом запуске, поэтому «обновлять» их нечем.

Коды выхода `--check`: `0` — актуально или не установлено, `1` — есть план
обновления, `2` — UNKNOWN/ошибка среды. Коды выхода `--apply`: `0` — применено
или обновлять нечего, `1` — отказ/ошибка (система не изменена либо её
восстановлением занимался транзакционный updater).

Статус: kas-update добавляется через основной репозиторий; команда с URL
`stable` станет доступной пользователям после перехода среза в `stable`
(политика веток — issue #369). До тех пор на работающих установках
продолжают действовать отдельные штатные команды ниже. Будущий `kas-core.ipk`
(issue #295, [план](kas-core-ipk-plan-20261030.md)) станет способом доставки,
`kas-update` сохранится как CLI-интерфейс проверки и активации.

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
- metadata/release lookup остаются с коротким 20-секундным лимитом, а сам `.ipk` получает отдельное bounded transfer window 180 секунд на попытку, чтобы большой asset не считался сетевой ошибкой только из-за медленного GitHub/CDN пути;
- заменяет бинарник транзакционно, сохраняя rollback-копию;
- при неудаче восстанавливает предыдущий бинарник;
- возвращает сервис в исходное состояние: работал до обновления → запускается снова,
  был остановлен оператором → остаётся остановленным;
- не перезаписывает пользовательский `config.yaml`; updater меняет бинарник Mihomo, а не пользовательскую конфигурацию;
- не делает автоматический downgrade.

C7 проверяет version string целиком до сравнения и требует успешного
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

Текущий B3/B4 rollback сначала подтверждает остановку daemon,
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

## OPKG-база и project-managed бинарник (issue #320)

\`update-mihomo.sh\` заменяет **только** бинарник и сознательно не пишет в OPKG-базу. Если фид также предоставляет пакет \`mihomo\`, база остаётся со старой версией, и последующий штатный \`opkg upgrade\` может заменить более новый project-managed ELF более старым фидовым (механизм воспроизведён offline закреплённым официальным opkg; тест \`tests/test_opkg_downgrade_repro.py\`). После обновления updater сравнивает метаданные OPKG с установленной версией и печатает \`[WARN]\` при расхождении — проверьте \`opkg list-installed | grep mihomo\` перед массовыми \`opkg upgrade\`. Updater ничего не держит (no hold/flag) и не меняет репозитории; решение — за оператором. Предупреждение — **диагностика, а не защита**: обычный \`opkg upgrade\` по-прежнему может снизить версию, проблема #320 не считается полностью устранённой; полное решение (например, синхронизация OPKG-метаданных или kas-core.ipk) — отдельная работа.

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

Doctor v1.2.17 проверяет наличие top-level `tun:`: при его отсутствии даёт INFO-подсказку на `migrate-mihomo-tun.sh --check` и объясняет, какой stack будет выбран по известной версии.

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
не подменяет snapshot текущего запуска. Обычный gvisor → mips transaction уже проходил
live-проверки на Keenetic; преднамеренный hard-power/SIGKILL в момент commit остаётся
задокументированным residual fault-class и не симулируется на production-роутере.

Если TUN в конфиге нет, `migrate-mihomo-mips.sh` ничего не добавляет: он **не создаёт `tun:`/`mitun0` с нуля**, а только переводит уже существующий `stack: gvisor` в `stack: mips`. Для legacy-конфига без `tun:` используется отдельный `migrate-mihomo-tun.sh`. Doctor v1.2.17 даёт INFO-подсказку для обоих legacy-состояний; окончательный feature-gate всё равно выполняет соответствующий migrator через реальный `mihomo -t`.

## После обслуживания

Для общей проверки стека используйте Doctor:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-doctor.sh | sh
```

Если обновление прошло нештатно, дальше идите в
[диагностику](08-troubleshooting.md), а не заменяйте бинарники вручную.

---

Формат `[OK]/[INFO]/[WARN]/[ERROR]/[FAIL]` и единая цветовая семантика updater'ов описаны в [18 — цвета и статусы CLI](18-output-colors.md).
