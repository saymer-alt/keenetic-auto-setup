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
- распознаёт установленную базу по каталогу SHA-256 известных managed-релизов
  (тела watchdog тегов v1.8.x + известные legacy-хэши updater'а). Сам маркер
  `MIHOMO WATCHDOG SCRIPT` владением не является: локально отредактированный
  файл может сохранить маркер, поэтому такая база помечается UNRECOGNIZED;
- проверяет исполняемость canonical/wrapper (примитив `ls -ldn`, как в
  updater'е) и активные cron-маршруты (зеркало грамматики
  `wd_normalize_cron`): сломанные права или отсутствие/дубликат
  распознанного маршрута попадают в план ремонта; нераспознанные активные
  маршруты — `REVIEW REQUIRED` (чужое расписание никогда не удаляется);
  no-op «уже актуально» не объявляется при сломанных правах или расписании;
- показывает информационный инвентарь остальных компонентов (Mihomo binary,
  MagiTrickle, netfilter hook, S00ubifs, пользовательский config) без изменений;
- всё, что не удалось достоверно определить (чужой/изменённый файл, symlink,
  обрыв сети), помечается `UNKNOWN` — догадками не подменяется; cron slot с
  нераспознанным содержимым — отдельный статус `REVIEW REQUIRED`;
- ничего не меняет.

Что делает `--apply` (явное действие):

- повторно оценивает состояние, печатает план, при интерактивном запуске
  запрашивает подтверждение; без TTY требуется `--yes`;
- применяет только распознанные KAS-managed части (canonical watchdog и
  cron wrapper) через транзакционный updater; при `UNKNOWN` — отказ без
  каких-либо изменений;
- cron slot с нераспознанным содержимым (`REVIEW REQUIRED`) блокирует apply:
  файл сохраняется без изменений, транзакция не запускается; для обновления
  canonical binary при сохранении такого wrapper используйте штатный
  `update-watchdog.sh` напрямую, затем повторите `--check`;
- **legacy layout поддержан**: полный старый watchdog непосредственно в
  `/opt/etc/cron.5mins/mihomo_watchdog` (canonical отсутствует или
  присутствует), чей SHA-256 **точно совпадает** с известными legacy-версиями
  (зеркало `LEGACY_HASHES` из `update-watchdog.sh`; обе версии сверяются
  регрессией), распознаётся как миграция: apply запускает штатный updater,
  который ставит canonical binary, превращает cron-копию в managed wrapper
  и сохраняет один bounded backup вне cron.5mins. Тела вне точного каталога
  (даже с маркером) остаются `REVIEW REQUIRED` — перезаписи не будет;
- canonical отсутствует, но cron slot содержит managed wrapper — сломанный
  layout (расписание указывает на несуществующий файл): kas-update не
  выдаёт такой repair за update и отказывается с явной причиной; ремонт —
  `install.sh` или прямой запуск `update-watchdog.sh`;
- перезапись установленной базы, не совпадающей ни с одним известным
  managed-релизом (например, локальная кастомизация с сохранённым маркером),
  требует отдельного явного разрешения: `--allow-unrecognized-base` при
  неинтерактивном запуске или отдельного подтверждения с показом SHA-256
  при интерактивном;
- после применения сверяет фактический SHA-256 с оценённым. Любое
  расхождение (в том числе drift канала между двумя загрузками) — это
  **неверифицированное применение**: код выхода `1`, а не успех; повторите
  `--check` для переоценки фактического состояния;
- ремонт прав/расписания (`PLAN_REPAIR`) исполняет штатный updater без
  перезаписи распознанного содержимого (права на canonical/wrapper,
  установка/дедупликация распознанных маршрутов);
- загружаемые shell-скрипты (кандидат watchdog, сам updater, копия
  kas-update для самопроверки) обязаны начинаться со строки `#!/bin/sh`:
  валидный shell-код с маркером, но без шапки, отвергается до запуска;
- повторный запуск идемпотентен: уже актуальное состояние не переписывается.

`kas-update` никогда не трогает: Mihomo binary, `config.yaml`, MagiTrickle,
netfilter, политики маршрутизации, WAN/VPN, Entware-пакеты, KAS Web. Mihomo
и MagiTrickle остаются отдельными явно выбираемыми обновлениями (см. ниже).
Doctor и `config-import.sh` установленных копий не имеют — они исполняются с
GitHub при каждом запуске, поэтому «обновлять» их нечем.

Информационный инвентарь MagiTrickle читает версию из штатного
`opkg list-installed` (формат Entware `magitrickle - 0.8.2-1`; также
распознаётся двухколоночный вариант). Разделитель `-` не считается
версией; непонятный формат помечается `UNKNOWN`, без вмешательства в пакет.
Сбой самой команды `opkg list-installed` — тоже `UNKNOWN`, а не «пакет не
найден».

Самопроверка копии `kas-update.sh` пропускается для исторических тегов
Core `v1.8.0`–`v1.8.7`, в которых такого файла ещё нет. Это устраняет
бесполезные сетевые повторы/предупреждения о 404; сравнение Watchdog с
выбранным тегом по SHA-256 **по-прежнему выполняется**. Для остальных
каналов self-check сохраняет обычную проверку.

Коды выхода `--check`: `0` — актуально или не установлено, `1` — есть план
обновления, `2` — UNKNOWN или REVIEW REQUIRED (чужой cron slot / ошибка
среды). Коды выхода `--apply`: `0` — применено и верифицировано либо
обновлять нечего, `1` — отказ/ошибка/неверифицированный результат (система
не изменена, восстановлена updater'ом, либо требует повторной проверки).

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

### IPK, UPX и свободное место на внутренней UBIFS (FIELD 25.09 и 09.11.2026)

Сводные выводы установки на KN-3811 от 09.11.2026 (включая причинную цепочку fallback, WEB и CI): [FIELD-отчёт](field/2026-11-09-kn-3811-kas-clean-install-findings.md).

**Это уже проверено на реальном оборудовании.** На дачном Keenetic Giga
KN-1012 GSM с внутренней UBIFS `/opt` 25.09.2026 старый неиспользуемый
`/opt/sbin/meta-backup/mihomo` занимал место. После его удаления свободное
пространство выросло примерно с 37,8 до 56,1 МБ. Канонический
`update-mihomo.sh` скачал проектный IPK
`mihomo_1.19.31-2_aarch64-3.10.ipk`, распаковал кандидат, определил
**17 096 КБ** необходимого staging-места (включая резерв), успешно
обновил Mihomo **1.19.30 → 1.19.31** с контролируемой остановкой,
проверкой и возобновлением сервиса. Итоговый Doctor: **33 OK / 0 WARN /
0 FAIL**. Исходная подробная запись:
[полевая приёмка KN-1012 GSM](archaeology/kas-testing-field-evidence-2026-09.md#2026-09-25-kn-1012-gsm-role--internal-ubifs-live-acceptance).

**Почему это сработало:** IPK передаётся в сжатом виде и загружается в
`/tmp` (RAM/tmpfs), а проектный бинарник в `entware-go` дополнительно
упакован **UPX** (ранее подтверждённый ARM64-кандидат — около 12,7 МБ).
UBIFS также умеет сжимать фактически записанные блоки. Важно различать
эти механизмы: одно лишь сжатие внешнего архива IPK не уменьшает размер
распакованного ELF; для preflight решающим был **фактический размер
извлечённого проектного бинарника**, а не размер старого ELF или IPK.
Дополнительные данные о размере UPX и same-version обновлении приведены
[в отдельном FIELD NC-1012](archaeology/kas-testing-field-evidence-2026-09.md#2026-09-25-nc-1012-transactional-binary-state-live-acceptance).
**Профили не смешивать:** NC-1012 в том тесте — внешний EXT4, KN-1012 GSM —
внутренний UBIFS.

В отличие от штатного обновления ядра Mihomo через WebUI/Controller
(которое может скачать крупный upstream ELF), `update-mihomo.sh` и
его Web-обёртка берут IPK из релиза `saymer-alt/entware-go` и
создают на `/opt` соседнюю проверяемую копию нового ELF, пока старый
ещё цел. Скрипт использует `df` и **распакованный** размер кандидата
+ 4 МиБ, затем атомарный commit и rollback. Отказ из-за preflight
означает ограничение **этой конкретной транзакции**, а не доказанное
физическое ENOSPC на NAND. Не отключать safety gate и не заменять
работающий ELF «поверх» ради экономии места.

**Новый FIELD «Охрана 126» / Hopper KN-3811 (09.11.2026):** после
успешной установки из Entware feed `mihomo 1.19.33-1` размер
текущего бинарника около 55 МБ, свободно 48 из 98 МБ на внутренней
UBIFS, Doctor 1.2.19 — **35 OK / 0 WARN / 0 FAIL**.
Его предварительная оценка «~57 МБ» основана на *текущем*
бинарнике и потому не предсказывает размер упакованного
`entware-go`-кандидата. В ходе установки загрузка более нового
проектного IPK с GitHub не удалась и использован feed fallback:
на этом конкретном KN-3811 **новый upgrade-тест не выполнялся**;
результат сентября на KN-1012 GSM переносится лишь как обоснование
возможности, не как гарантированный PASS на KN-3811. Для каждого нового
релиза updater проверяет размер извлечённого кандидата и доступность
места самостоятельно.

Штатный `opkg upgrade` — отдельный механизм; он может заменить
project-managed бинарник фидовым и даже снизить версию (см. #320).
В KAS Web beta.8 блок «Системные показатели» пока не показывает
`/opt`, но Doctor и его WEB-сводка отображают объём; задача #476.
На работающем KN-3811 после успешного Doctor изменений не требуется.

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
