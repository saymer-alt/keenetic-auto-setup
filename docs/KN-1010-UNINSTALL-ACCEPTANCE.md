# KN-1010 — аппаратная приёмка KAS uninstall

> Сохранённый план **экспериментальной** приёмки #215/#227. По заключительному
> контракту владельца в [#225](https://github.com/saymer-alt/keenetic-auto-setup/issues/225)
> эти фазы не являются обязательным условием обычной деактивации/удаления KAS.
> Развитие архитектуры прекращено. Историческое HARDWARE_READY ниже не означает
> аппаратный PASS или разрешение выполнить C. Начатый PREPARE-fix описан
> [отдельно](KN-1010-PREPARE-RETEST.md); без нового Owner GO аппаратных действий нет.

**HARDWARE_READY для начала этапа A; аппаратная приёмка NOT_TESTED.**
Документ подготовлен без подключения к устройствам. Этап C — **DESTRUCTIVE**,
только после отдельного Owner GO с указанием запасного KN-1010 и результатов A/B.
Titan 4210, домашняя/рабочая сеть, VPS не используются. Это кандидат, не stable.

Испытуемый runtime: KAS `aef221f80904ff1d8dd639c6f85b308b063b749e` (#215 + #227).
Лаборатория: `07e537976a2a6260239b758213a1e73f416f53bd`,
[E2E №5, 19/19 PASS](https://github.com/saymer-alt/router-emulator/actions/runs/40202096816).
План ограничен первым профилем: внешний EXT4 opt, mipsel-3.4, девять ownership
claims. Internal/ram, другой ABI, дополнительный S00ubifs claim — **BLOCKED для C**,
без изменения ledger или расширения удаляторa.

Все действия ниже — инструкция владельцу, сейчас они на роутере не выполнялись.
Работать по проводному локальному каналу с запасным устройством и независимым
доступом к его web UI. Отключить Wi-Fi/маршруты ПК, ведущие к основному роутеру.
Для сетевых тестов нужен отдельно согласованный испытательный uplink; если его
нет, сетевые проверки NOT_TESTED, не PASS. Секретные файлы не прикладывать к PR.

## 0. Зафиксированные исходники на ПК

Подготовленный для этого плана архив `KN-1010-kas-aef221f80904.tar.gz` содержит
весь Git tree aef221f… и SOURCE_COMMIT/SOURCE_SHA256SUMS. Каждый root shell script
сверен с Git blob этого SHA. SHA256 **именно подготовленного архива**:

```text
30bbefacda154db559d1313d570157108f3dca7a9524b5d21fdef58218c8fb87
```

На Windows-ПК в каталоге полученного архива (PowerShell):
Перед передачей подтвердить корпус/web UI запасного KN-1010 и его локальный
канал. Начальные identity-команды A можно выполнить до передачи архива.

```powershell
$Archive = 'KN-1010-kas-aef221f80904.tar.gz'
$Expected = '30bbefacda154db559d1313d570157108f3dca7a9524b5d21fdef58218c8fb87'
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $Archive).Hash.ToLower() -ne $Expected) { throw 'BLOCKED: archive hash' }
# Вписать адрес и порт существующего Entware SSH запасного устройства, не NDMS CLI.
$RouterIP = 'SET_SPARE_KN1010_IP'
$EntwarePort = 0
if ($RouterIP -like 'SET_*' -or $EntwarePort -lt 1) { throw 'BLOCKED: select spare device' }
scp -O -P $EntwarePort $Archive "root@${RouterIP}:/tmp/$Archive"
if ($LASTEXITCODE -ne 0) { throw 'BLOCKED: source transfer' }
```

При недоступном SCP — BLOCKED передачи; не устанавливать пакеты и не включать
службы ради обхода. Альтернативно владелец может построить архив из своего
проверенного Git checkout: `git archive aef221f80904ff1d8dd639c6f85b308b063b749e`.
У заново упакованного архива будет другой hash: сначала независимо сверить каждый
файл с Git tree и утвердить новый hash на ПК. Не доверять checksum, скачанному
из того же изменяемого branch URL. Не смешивать файлы из main/stable/других SHA.
Документация внутри runtime-архива историческая, из aef221f…; для испытания
пользоваться этим новым планом отдельно, а не старыми указаниями из архива.

## A. Диагностика — без удаления и изменения служб

Открыть **Entware root shell** запасного KN-1010. Сначала только чтение:

```sh
id
test "$(id -u)" = 0 || exit 3
uname -a
ndmc -c 'show version'
cat /proc/meminfo
cat /proc/swaps
cat /proc/mounts
opkg print-architecture
opkg list-installed
```

Сверить модель/серийный номер с корпусом и web UI: только запасной **KN-1010**.
`uname -m` может сообщать mips без endian; решающая ABI-проверка — OPKG
`mipsel-3.4` и пакетные метаданные. RAM/swap не угадывать по модели. zRAM вместе
с внешним SWAP — BLOCKED; ничего автоматически не отключать. Этот план не
форматирует и не монтирует носители. Verifier также блокирует symlink opt.

Далее создаются **только приватные файлы исходников/диагностики**; это не чисто
read-only относительно файловой системы. Настройки, службы и пакеты не меняются.
Команды — в одном сеансе; любой ненулевой статус останавливает соответствующий шаг:

```sh
umask 077
export LC_ALL=C
unset KAS_AUDIT_ROOT KAS_SNAPSHOT_ROOT KAS_TXN_FIXTURE_ROOT KAS_TXN_TEST_FAIL_AT
for tool in sh awk sed grep cut tr cmp sha256sum readlink tar mktemp ndmc opkg iptables ip; do
    command -v "$tool" >/dev/null || { echo "BLOCKED: missing $tool"; exit 3; }
done
printf '%s  %s\n' \
  30bbefacda154db559d1313d570157108f3dca7a9524b5d21fdef58218c8fb87 \
  /tmp/KN-1010-kas-aef221f80904.tar.gz | sha256sum -c - || exit 3
test ! -e /opt/kas-hw-candidate || exit 3
test ! -L /opt/kas-hw-candidate || exit 3
mkdir -m 700 /opt/kas-hw-candidate || exit 3
tar -xzf /tmp/KN-1010-kas-aef221f80904.tar.gz -C /opt/kas-hw-candidate || exit 3
KAS_DIR=/opt/kas-hw-candidate/kas-candidate-aef221f80904
export KAS_DIR
cd "$KAS_DIR" || exit 3
test "$(cat SOURCE_COMMIT)" = aef221f80904ff1d8dd639c6f85b308b063b749e || exit 3
sha256sum -c SOURCE_SHA256SUMS > /tmp/kas-source-verify.txt || exit 3
for script in ./*.sh ./S00ubifs; do sh -n "$script" || exit 3; done
RUN=$(mktemp -d /opt/kas-kn1010.XXXXXXXX) || exit 3
chmod 700 "$RUN" || exit 3
export RUN
printf '%s\n' "$RUN"  # записать приватно: нужен после переподключения
ndmc -c 'show version' > "$RUN/version.txt" || exit 3
ndmc -c 'show running-config' > "$RUN/before.running-config" || exit 3
ndmc -c 'show ip policy' > "$RUN/before.ip-policy" || exit 3
iptables-save > "$RUN/before.iptables" || exit 3
ip rule show > "$RUN/before.ip-rule" || exit 3
ip route show table all > "$RUN/before.ip-route" || exit 3
opkg print-architecture > "$RUN/opkg-architecture" || exit 3
opkg list-installed > "$RUN/before.packages" || exit 3
cat /opt/etc/keenetic-auto-setup/ownership.v1 > "$RUN/ownership.v1" || exit 3
ps w > "$RUN/processes.private" || exit 3
cat /opt/etc/crontab > "$RUN/crontab.private" || exit 3
cp -p /opt/etc/init.d/S99mihomo "$RUN/S99mihomo" || exit 3
cp -p /opt/etc/init.d/S99magitrickle "$RUN/S99magitrickle" || exit 3
sha256sum /opt/bin/mihomo /opt/bin/magitrickled /opt/etc/init.d/S99* \
  > "$RUN/runtime-hashes.private" || exit 3
sh "$KAS_DIR/uninstall.sh" --check > "$RUN/check.txt" 2>&1
printf 'check exit=%s\n' "$?"
sh "$KAS_DIR/uninstall.sh" --plan > "$RUN/plan.txt" 2>&1
printf 'plan exit=%s\n' "$?"
sh "$KAS_DIR/uninstall-snapshot.sh" --check || exit 3
```

Если отсутствуют iptables-save/ps/cp или их режимы — остановиться; локальный ash
не доказывает наличие applet на KN. Проверить журнал/план приватно. В этом SHA
есть исторические `not implemented` строки в plan/prepare: см. [23-uninstall.md](23-uninstall.md).
Только перечисленные фиксированные устаревшие сообщения не отражают runtime;
остальные BLOCKED останавливают испытание. UNKNOWN требует независимого
доказательства через строгий gate/инвентарь; SHARED_OR_FOREIGN сохраняется,
а при зависимости от удаляемого ресурса означает BLOCKED C.

Обязательный ручной review: сравнить ledger с каждым ProxyN, всеми policy/bindings,
маршрутами, таблицами Netfilter и DNS в сохранённом running-config. Чужой Proxy на
7890, потребитель policy/chain/feed/package, дополнительная watchdog cron-строка,
изменённый hook или неизвестный launcher — BLOCKED. Ничего не «нормализовать».
YAML не публиковать; сохранить их sha256 и проверить чтение/наличие в этапе B.

### Источники запуска и идентичности

```sh
cat /proc/uptime
cat "$RUN/S99magitrickle"
cat "$RUN/S99mihomo"
printf '%s  %s\n' \
  ea80558c3818302c64b62e7cbdacfe818237af54e7d390ef2ab84d3cea49a81e \
  /opt/etc/init.d/S99magitrickle | sha256sum -c - || exit 3
test ! -f /opt/etc/init.d/rc.func || cp -p /opt/etc/init.d/rc.func "$RUN/rc.func"
ls -l /opt/etc/init.d /opt/etc/cron.* /opt/etc/ndm > "$RUN/launchers.private" 2>&1
cmp -s /opt/bin/mihomo_watchdog.sh "$KAS_DIR/mihomo-watchdog.sh" || exit 3
sed -n '/^# BEGIN MIHOMO LIFECYCLE LOCK/,/^# END MIHOMO LIFECYCLE LOCK/p' \
  "$KAS_DIR/uninstall-transaction.sh" > "$RUN/lifecycle.sh"
sed -n '/^txn_step_services_done() {/,/^# Refuse unproven live processes/p' \
  "$KAS_DIR/uninstall-transaction.sh" > "$RUN/process-guard.sh"
sh -n "$RUN/lifecycle.sh" && sh -n "$RUN/process-guard.sh" || exit 3
# Перечень кандидатов, НЕ доказательство владения; полную argv смотреть только приватно.
for proc in /proc/[0-9]*; do
    test -r "$proc/comm" || continue
    read -r comm < "$proc/comm"
    exe=$(readlink "$proc/exe" 2>/dev/null) || continue
    case "$comm:$exe" in
      mihomo:*|magitrickled:*|*:/opt/bin/mihomo|*:/opt/sbin/mihomo|*:/opt/bin/magitrickled)
        printf '%s %s %s\n' "${proc##*/}" "$comm" "$exe";;
    esac
done
```

Hash выше — архитектурно-независимый KN init из проверенного IPK 0.8.2-1,
не hash бинарника aarch64. Фактический KN init должен быть изучен целиком: где задаётся uptime boundary,
как вызывается startup_loop, откуда исполняется бинарник. Если это иной вариант,
не переносить условие 300 секунд вслепую: BLOCKED до отдельного review.
Инвентарь ps/cron/init/ndm обязателен: argv родителя — наблюдение, не доказательство
происхождения. Если активный экземпляр появился до наблюдаемой установки и
независимых записей запуска нет — **BLOCKED C**. Безопасный вариант — отдельно
согласованный чистый испытательный baseline на запасном носителе с наблюдаемой
установкой; не стирать текущий opt ради получения ledger/provenance.

GO-A: подтверждён запасной KN-1010, внешний EXT4, mipsel-3.4, допустимый swap,
девять настоящих claims, читаемые YAML, понятные зависимости/launchers и исходники.
Это разрешает B, **не** C. В начале приёмки Doctor запускается read-only:

```sh
KEENETIC_AUTO_SETUP_REF=aef221f80904ff1d8dd639c6f85b308b063b749e \
  sh "$KAS_DIR/mihomo-doctor.sh" > "$RUN/doctor-before.private" 2>&1
doctor_status=$?
printf 'Doctor exit=%s\n' "$doctor_status"
test "$doctor_status" = 0 || exit 3
```

Нужны exit 0, WARN 0, FAIL 0, Overall status OK. Пустой watchdog-log — настоящий
WARN/BLOCKED, не PASS. Допустима настоящая штатная проверка watchdog после review
её способности перезапускать службу; никаких фиктивных heartbeat. Повторить Doctor
после реальной проверки, сохранив оба результата. Не публиковать raw log/argv.

## B. Восстановление подготовлено ДО остановки/удаления

1. В web UI запасного устройства сохранить **startup-config и firmware** на ПК:
   «Общие настройки системы → Системные файлы → Сохранить на компьютер».
   Записать версию ОС, режим работы и параметры локального доступа. Сверить
   running-config со startup-config: необъяснённое расхождение — BLOCKED.
   Экспорт running-config не заменяет загружаемый startup-config.
   [Руководство производителя](https://support.keenetic.ua/air/kn-1610/en/52218-saving-the-startup-config-configuration-file.html),
   [восстановление конфигурации](https://support.keenetic.ru/eaeu/launcher/kn-1221/en/22355-restoring-keenetic-router-settings-from-a-backup-configuration-file.html).
2. В Entware shell создать snapshot, вручную взять **точное имя** из PASS-строки:

```sh
sh "$KAS_DIR/uninstall-snapshot.sh" --create || exit 3
SNAP=YYYYMMDD-HHMMSS-PID  # заменить именем только что созданного снимка
export SNAP
sh "$KAS_DIR/uninstall-snapshot-verify.sh" "$SNAP" || exit 3
sh "$KAS_DIR/uninstall-transaction-gate.sh" --check "$SNAP" || exit 3
sh "$KAS_DIR/uninstall-transaction.sh" --prepare "$SNAP" > "$RUN/prepare.private" 2>&1 || exit 3
BACK=/opt/kas-uninstall-backups/$SNAP
export BACK
test -s "$BACK/packages/MANIFEST" && test -s "$BACK/packages/wanted" || exit 3
(cd "$BACK/packages" && sha256sum -c MANIFEST) || exit 3
cat "$BACK/packages/wanted"
opkg list-installed | grep -E '^(mihomo|magitrickle) '
cmp -s /opt/etc/mihomo/config.yaml "$BACK/files/opt/etc/mihomo/config.yaml" || exit 3
cmp -s /opt/var/lib/magitrickle/config.yaml "$BACK/files/opt/var/lib/magitrickle/config.yaml" || exit 3
```

Нужны PASS strict gate и cache, два IPK точных установленных версий, отсутствие
REVIEW cache incomplete. Prepare пишет временные locks/marker и recovery-файлы,
может скачивать IPK; он не является read-only. Он не меняет NDMS/службы/пакеты.
На ПК скопировать **весь** каталог SNAP и RUN через SCP в закрытый recovery-каталог;
конкретные удалённые пути взять из SNAP/RUN, без автоматического выбора latest.

```powershell
$Recovery = 'D:\KN1010-private-recovery'  # приватный локальный диск ПК, не opt
New-Item -ItemType Directory -Force $Recovery | Out-Null
$Snapshot = 'YYYYMMDD-HHMMSS-PID'          # точное имя из B
$RemoteRun = '/opt/kas-kn1010.REPLACE'     # точный путь RUN из A
if ($Snapshot -like '*PID*' -or $RemoteRun -like '*REPLACE*') { throw 'BLOCKED: fill exact paths' }
scp -O -P $EntwarePort -r "root@${RouterIP}:/opt/kas-uninstall-backups/$Snapshot" $Recovery
if ($LASTEXITCODE -ne 0) { throw 'BLOCKED: snapshot export' }
scp -O -P $EntwarePort -r "root@${RouterIP}:$RemoteRun" $Recovery
if ($LASTEXITCODE -ne 0) { throw 'BLOCKED: diagnostics export' }
Get-ChildItem $Recovery -Recurse -File | Get-FileHash -Algorithm SHA256 |
    Export-Csv -NoTypeInformation -LiteralPath "$Recovery\host-hashes.csv"
```

На локальном Linux-ПК/LiveUSB (не VPS), в скопированном snapshot:

```bash
set -euo pipefail
umask 077
cd /PATH/TO/PRIVATE/RECOVERY/SNAPSHOT/packages
sha256sum -c MANIFEST
cat wanted
for ipk in ./*.ipk; do
  printf '\n%s\n' "$ipk"
  tar -xOf "$ipk" ./control.tar.gz | tar -xzOf - ./control
done
```

Проверить Package/Version каждого IPK против wanted и живого OPKG, Architecture
против сохранённого opkg print-architecture (**mipsel**, не aarch64 из QEMU).
Hash MANIFEST доказывает целостность сохранённых bytes, не подлинность их источника.
Для binary-only обновлённого Mihomo пакетный cache может не совпадать с runtime
бинарником: полный образ ниже сохраняет и актуальный бинарник/state. Самого cache
недостаточно для обещания полного восстановления.

3. **Холодная копия всего Entware:** после экспорта выполнить `sync` в Entware.
   В web UI запасного устройства: «Системный монитор → USB-диски и принтеры →
   Безопасное извлечение» **конкретного opt-носителя**, подтвердить и дождаться
   успешного отключения. Это временно останавливает все службы этого USB:
   допустимо только в согласованном окне при известных владельцу потребителях.
   При неизвестном владельце/несогласованной паузе — BLOCKED B/C; safe eject
   нельзя использовать как обход process guard. Если UI не подтверждает
   успешное отключение — STOP, без принудительного umount/kill/power cut.
   Затем выключить запасной стенд и отсоединить уже отключённый носитель.
   [Штатная процедура Keenetic](https://support.keenetic.ru/eaeu/4g/kn-1212/ru/36869-usb-safe-removal.html).
   Не вынимать работающий USB. На локальном Linux-ПК/LiveUSB запретить automount;
   источник и все его разделы должны быть unmounted. Записать by-id/serial/UUID.
   Не предполагать, что выключение питания гарантирует чистую EXT4: ниже только
   non-writing проверка. Любая ошибка/необходимость journal recovery — BLOCKED B,
   без автоматического fsck/repair исходного накопителя. Если штатное отключение
   недоступно — BLOCKED B, не импровизация на месте.
   Значения устройств выбираются по физически подключённому запасному USB,
   не по предположению «sda». В примере INPUT читается, не перезаписывается:

```bash
set -euo pipefail
umask 077
lsblk -o NAME,PATH,TYPE,SIZE,FSTYPE,UUID,SERIAL,MOUNTPOINTS
INPUT=/dev/disk/by-id/SET_EXACT_SPARE_USB_ID
RECOVERY=/PATH/TO/PRIVATE/RECOVERY
case "$INPUT" in /dev/disk/by-id/usb-*) ;; *) echo 'BLOCKED: select USB by-id'; exit 3;; esac
test -b "$INPUT"
test "$(lsblk -dnro TYPE "$INPUT")" = disk
lsblk -nrpo NAME,MOUNTPOINTS "$INPUT"  # все mountpoints пусты, иначе STOP
test "$(lsblk -nrpo MOUNTPOINTS "$INPUT" | tr -d '[:space:]')" = ''
EXT4=$(lsblk -nrpo NAME,FSTYPE "$INPUT" | awk '$2=="ext4" {print $1}')
test -n "$EXT4"
for partition in $EXT4; do sudo e2fsck -fn "$partition" || exit 3; done
BYTES=$(sudo blockdev --getsize64 "$INPUT")
printf '%s\n' "$BYTES" > "$RECOVERY/opt-disk.bytes"
printf '%s\n' "$INPUT" > "$RECOVERY/opt-disk.source-by-id"
test ! -e "$RECOVERY/opt-disk.img"
sudo dd if="$INPUT" of="$RECOVERY/opt-disk.img" bs=4M conv=fsync status=progress
sudo cmp -n "$BYTES" "$INPUT" "$RECOVERY/opt-disk.img"
cd "$RECOVERY"
sha256sum opt-disk.img > opt-disk.img.sha256
sha256sum -c opt-disk.img.sha256
```

Образ целого USB включает разделы, права, OPKG db, пользовательские YAML и shared
пакеты; активные tmpfs/logs дополнительно уже сохранены в RUN. Размер на ПК должен
позволять полный образ. Если opt внутренний либо холодную копию получить нельзя —
BLOCKED C. Вернуть исходный носитель в выключенный стенд и загрузить его. После
этого PID/starttime прежние **недействительны**: повторить наблюдение происхождения
служб, boot-loop и этап B snapshot/prepare (новый SNAP); снова экспортировать новый
SNAP/RUN на ПК. При изменении baseline после образа — обновить холодный backup.

### Recovery при power loss / сломанном OPKG

Сначала сохранить приватно journal, текущее состояние и причины отказа. После
сбоя не выполнять opkg update/install, installer, создание нового snapshot или
prepare поверх прерванной транзакции. Если применим resume — см. C. При BLOCKED
resume использовать **полный холодный образ**, не собирать систему вручную.

До C должен быть доступен второй USB не меньше BYTES и локальный Linux-ПК.
Восстановление образа — отдельное **DESTRUCTIVE RECOVERY / Owner GO**:

```bash
set -euo pipefail
umask 077
cd /PATH/TO/PRIVATE/RECOVERY
sha256sum -c opt-disk.img.sha256
BYTES=$(cat opt-disk.bytes)
OUTPUT=/dev/disk/by-id/SET_EXACT_RECOVERY_USB_ID
case "$OUTPUT" in /dev/disk/by-id/usb-*) ;; *) echo 'BLOCKED: select recovery USB by-id'; exit 3;; esac
SOURCE=$(cat opt-disk.source-by-id)
test "$OUTPUT" != "$SOURCE"
if test -e "$SOURCE" && test "$OUTPUT" -ef "$SOURCE"; then echo 'BLOCKED: source is target'; exit 3; fi
test -b "$OUTPUT"
test "$(lsblk -dnro TYPE "$OUTPUT")" = disk
lsblk -o NAME,PATH,SIZE,SERIAL,MOUNTPOINTS "$OUTPUT"
test "$(lsblk -nrpo MOUNTPOINTS "$OUTPUT" | tr -d '[:space:]')" = ''
test "$(sudo blockdev --getsize64 "$OUTPUT")" -ge "$BYTES"
# Последняя сверка владельцем serial OUTPUT: это именно ВТОРОЙ запасной USB.
sudo dd if=opt-disk.img of="$OUTPUT" bs=4M conv=fsync status=progress
sudo cmp -n "$BYTES" opt-disk.img "$OUTPUT"
sync
```

Подключить только восстановленный носитель к выключенному KN-1010 (не оба с
одинаковыми UUID). Через web UI того же устройства/режима восстановить сохранённый
startup-config; загрузка может перезагрузить роутер. Firmware не менять, если она
не повреждена: это отдельная recovery-операция. Если недоступны web UI/носитель/
учётные данные, C остаётся BLOCKED, а не разрешается «сбросить на месте».
Верификация записи образа обязательна **до C** на запасной USB; исходный не стирать.

GO-B: startup-config/firmware + проверенный полный образ + последний SNAP/RUN/IPK
доступны на ПК независимо от opt; проверены hashes, контрольные копии YAML и
возможность записи/чтения recovery USB; есть web/LAN доступ и credentials.
Это подготовка восстановления, не заявление, что восстановление после аварии
на реальном устройстве уже успешно испытано.

## C. DESTRUCTIVE — только отдельный Owner GO

GO должен явно разрешать удаление/переустановку/reboot **этого** KN-1010 с этими
SHA и SNAP, после A/B. Без GO этот раздел не выполнять. Другие администраторы,
обновления OPKG, изменения NDMS/cron/init на время испытания исключены.
Неизвестный внешний launcher — BLOCKED, не редактирование его настроек.

1. Дождаться окончания **изученного** KN startup_loop. В одном shell:

```sh
tries=0
while :; do
    uptime=$(cut -d. -f1 /proc/uptime) || exit 3
    case "$uptime" in ''|*[!0-9]*) exit 3;; esac
    active=0
    for file in /proc/[0-9]*/cmdline; do
        test -e "$file" || continue
        args=$(tr '\000' '|' < "$file") || { test ! -e "$file" && continue; exit 3; }
        case "$args" in *'S99magitrickle|'*) active=1;; esac
    done
    test "$uptime" -gt 300 && test "$active" = 0 && break
    tries=$((tries+1)); test "$tries" -le 70 || exit 3
    sleep 5
done
```

2. Только после независимого подтверждения владельцем происхождения **обоих**
экземпляров сохранить их текущие идентичности. Подтверждение — журнал наблюдаемого
запуска в изолированном baseline/сеанс владельца, не совпадение имени/пути/argv.
Если его нет — STOP. Файлы identity ниже лишь защищают от смены PID, не доказывают
владение и не являются новой системой учёта процессов.

```sh
. "$RUN/lifecycle.sh"
P_MIHOMO=ENTER_CONFIRMED_PID
P_MAGI=ENTER_CONFIRMED_PID
for pair in "mihomo:$P_MIHOMO" "magitrickled:$P_MAGI"; do
    name=${pair%%:*}; pid=${pair#*:}
    case "$pid" in ''|0|1|*[!0-9]*) exit 3;; esac
    start=$(ml_starttime "$pid") || exit 3
    exe_hash=$(sha256sum "/proc/$pid/exe" | awk '{print $1}') || exit 3
    argv_hash=$(sha256sum "/proc/$pid/cmdline" | awk '{print $1}') || exit 3
    printf '%s %s %s %s\n' "$pid" "$start" "$exe_hash" "$argv_hash" > "$RUN/$name.identity"
done
```

3. Native отказ при живых службах, до сигналов. Должен вернуть 3 именно с
`live service ownership unproven`, без нового journal/lock/marker и изменений
ресурсов. Не принимать произвольную другую ошибку за успешный negative test:

```sh
sh "$KAS_DIR/uninstall.sh" --remove "$SNAP" > "$RUN/live-remove.private" 2>&1
code=$?
test "$code" = 3 || exit 3
grep -Fq 'live service ownership unproven' "$RUN/live-remove.private" || exit 3
test ! -e "$BACK/transaction/journal.v1" || exit 3
test ! -e /tmp/mihomo-lifecycle.lock.d && test ! -e /tmp/mihomo.maintenance || exit 3
sh "$KAS_DIR/uninstall-snapshot-verify.sh" "$SNAP" || exit 3
```

4. Следующий блок выполнить **целиком в одном shell**. Он использует уже
существующие helpers кандидата; не создаёт новый lock-протокол. Только TERM
подтверждённым PID, конечное ожидание, без KILL/повторных сигналов. При drift
или новом процессе — остановка. На успехе/ошибке штатные helpers освобождают
свои locks; чужой busy lock не удаляется. Впишите подтверждение только после A/B/GO:

```sh
export OWNER_CONFIRMED_KAS_ORIGIN=yes  # ТОЛЬКО после независимого доказательства
sh <<'KAS_OWNER_REMOVE'
set -eu
umask 077
test "$OWNER_CONFIRMED_KAS_ORIGIN" = yes || exit 3
cd "$KAS_DIR"
sha256sum -c SOURCE_SHA256SUMS >/dev/null || exit 3
sed -n '/^# BEGIN MIHOMO LIFECYCLE LOCK/,/^# END MIHOMO LIFECYCLE LOCK/p' \
    "$KAS_DIR/uninstall-transaction.sh" | cmp -s - "$RUN/lifecycle.sh" || exit 3
sed -n '/^txn_step_services_done() {/,/^# Refuse unproven live processes/p' \
    "$KAS_DIR/uninstall-transaction.sh" | cmp -s - "$RUN/process-guard.sh" || exit 3
. "$RUN/lifecycle.sh"
root=
fail() { printf 'BLOCKED: %s\n' "$1" >&2; exit 3; }
. "$RUN/process-guard.sh"
held=0
finish() {
    status=$?
    ml_lifecycle_release || status=3
    if test "$held" = 1; then ml_lock_release /tmp/mihomo_watchdog.lock.d || status=3; fi
    trap - EXIT
    exit "$status"
}
trap finish EXIT
trap 'exit 3' INT TERM HUP
# Watchdog takes per-run before lifecycle: same order, nonblocking.
ml_lock_acquire /tmp/mihomo_watchdog.lock.d || exit 3
held=1
ml_lifecycle_acquire || exit 3
verify_identity() {
    name=$1
    read -r pid start exe_hash argv_hash < "$RUN/$name.identity" || return 1
    case "$pid" in ''|0|1|*[!0-9]*) return 1;; esac
    test "$(ml_starttime "$pid")" = "$start" &&
    test "/proc/$pid/exe" -ef "/opt/bin/$name" &&
    test "$(sha256sum "/proc/$pid/exe" | awk '{print $1}')" = "$exe_hash" &&
    test "$(sha256sum "/proc/$pid/cmdline" | awk '{print $1}')" = "$argv_hash" &&
    awk '/^Uid:/ { found=1; if ($2 || $3 || $4 || $5) exit 1 } END { if (!found) exit 1 }' \
        "/proc/$pid/status"
}
verify_identity mihomo && verify_identity magitrickled || exit 3
for daemon in mihomo magitrickled; do
    verify_identity "$daemon" || exit 3
    kill -TERM "$pid" || exit 3
    tries=0
    while test -d "/proc/$pid"; do
        state=$(sed 's/^.*) //' "/proc/$pid/stat" | awk '{print $1}')
        case "$state" in Z|X) break;; esac
        verify_identity "$daemon" || { test ! -d "/proc/$pid" && break; exit 3; }
        tries=$((tries+1)); test "$tries" -le 15 || exit 3
        sleep 1
    done
done
tries=0
until txn_step_services_done; do
    tries=$((tries+1)); test "$tries" -le 5 || exit 3
    sleep 1
done
txn_step_services  # настоящий guard кандидата; неизвестный процесс => BLOCKED
ml_lifecycle_release || exit 3
# Parent keeps per-run; each child can obtain its own lifecycle lock.
sh "$KAS_DIR/uninstall-snapshot-verify.sh" "$SNAP" || exit 3
sh "$KAS_DIR/uninstall-transaction-gate.sh" --check "$SNAP" || exit 3
# Reuse the already exported cache; prepare would rebuild it. Native remove
# revalidates cache and recovery inputs itself. Do not replace B's offline copy.
(cd "$BACK/packages" && sha256sum -c MANIFEST) || exit 3
sh "$KAS_DIR/uninstall.sh" --remove "$SNAP"
KAS_OWNER_REMOVE
```

Если при повторном verify/gate обнаружен drift, новый snapshot/prepare разрешены
только после отдельного разбора и повторения B, **не автоматически в этом блоке**.
Handoff удерживает только per-run lock через child; поэтому deadlock на lifecycle
не требуется. Ни lock/guard/marker, ни journal вручную не удалять.

### После успешного native remove

```sh
test ! -e /tmp/mihomo-lifecycle.lock.d && test ! -e /tmp/mihomo-lifecycle.lock.d.guard || exit 3
test ! -e /tmp/mihomo_watchdog.lock.d && test ! -e /tmp/mihomo_watchdog.lock.d.guard || exit 3
test ! -e /tmp/mihomo.maintenance || exit 3
tail -n 1 "$BACK/transaction/journal.v1" | grep -x complete || exit 3
(cd "$BACK/packages" && sha256sum -c MANIFEST) || exit 3
cmp -s /opt/etc/mihomo/config.yaml "$BACK/files/opt/etc/mihomo/config.yaml" || exit 3
cmp -s /opt/var/lib/magitrickle/config.yaml "$BACK/files/opt/var/lib/magitrickle/config.yaml" || exit 3
opkg list-installed > "$RUN/after.packages" || exit 3
ndmc -c 'show running-config' > "$RUN/after.running-config" || exit 3
ndmc -c 'show ip policy' > "$RUN/after.ip-policy" || exit 3
iptables-save > "$RUN/after.iptables" || exit 3
ip rule show > "$RUN/after.ip-rule" || exit 3
ip route show table all > "$RUN/after.ip-route" || exit 3
for file in /opt/etc/keenetic-auto-setup/ownership.v1 /opt/bin/mihomo_watchdog.sh \
 /opt/etc/cron.5mins/mihomo_watchdog /opt/etc/ndm/netfilter.d/020-bypass_wa.sh \
 /opt/etc/opkg/magitrickle.conf; do
    test ! -e "$file" && test ! -L "$file" || exit 3
done
if grep -Eq '^(mihomo|magitrickle) ' "$RUN/after.packages"; then exit 3; fi
OWNED_PROXY=$(awk -F'|' '$1=="owned" && $2=="proxy" {print $3}' \
    "$BACK/files/opt/etc/keenetic-auto-setup/ownership.v1")
case "$OWNED_PROXY" in Proxy[0-9]) ;; *) exit 3;; esac
if grep -Eq "^interface $OWNED_PROXY$|^ip policy bypass_wa$" "$RUN/after.running-config"; then exit 3; fi
iptables -t mangle -S > "$RUN/after.mangle" || exit 3
if grep -Fq _CUST_BYPASS_WA_ "$RUN/after.mangle"; then exit 3; fi
sh "$KAS_DIR/uninstall.sh" --remove "$SNAP" > "$RUN/idempotent.private" 2>&1 || exit 3
ndmc -c 'show running-config' > "$RUN/idempotent.running-config" || exit 3
opkg list-installed > "$RUN/idempotent.packages" || exit 3
cmp -s "$RUN/after.running-config" "$RUN/idempotent.running-config" || exit 3
cmp -s "$RUN/after.packages" "$RUN/idempotent.packages" || exit 3
```

Идемпотентный повтор должен сообщить already fully removed / already removed,
не повторять мутации. Проверить отсутствие ledger/watchdog/wrapper/hook/feed,
owned ProxyN/policy/chain и двух пакетов. Сравнить before/after по конкретным
блокам: все чужие ProxyN/policy/Netfilter/cron, обычные пакеты и DNS intercept
сохранены. Маршрутные счётчики/адреса могут меняться, это не повод пропустить
неожиданные изменения. Для идемпотентности снять after повторно и сравнить
конфигурации/пакеты; PID и live counters не использовать как стабильный checksum.
На локальном Linux-ПК выполнить `diff -u before.running-config after.running-config`,
`diff -u before.iptables after.iptables`, `diff -u before.ip-route after.ip-route`,
`diff -u before.ip-rule after.ip-rule`. После удаления отдельно скопировать
`/opt/etc/crontab` на ПК и сравнить `diff -u crontab.private crontab-after.private`:
должна исчезнуть только каноническая owned watchdog-строка. Изменения вне заранее
проверенных собственных объектов KAS/MagiTrickle — BLOCKED до разбора, не
автоматическое принятие diff.

```sh
nslookup example.com > "$RUN/dns-after.private" 2>&1 || exit 3
ip route get 1.1.1.1 > "$RUN/route-after.private" 2>&1 || exit 3
curl -I --connect-timeout 5 --max-time 20 https://example.com > "$RUN/http-after.private" 2>&1 || exit 3
```

Проверить также DNS и HTTP с проводного LAN-клиента через адрес запасного KN-1010.
На Windows-ПК сначала проверить, что единственный испытательный default gateway
принадлежит запасному устройству; при другом маршруте результат не засчитывается:

```powershell
Get-NetIPConfiguration
Resolve-DnsName -Name example.com -Server $RouterIP -DnsOnly -ErrorAction Stop
curl.exe -I --connect-timeout 5 --max-time 20 https://example.com
if ($LASTEXITCODE -ne 0) { throw 'BLOCKED: client HTTP' }
```

Ожидается согласованный baseline прямой маршрутизации после снятия KAS, не
сохранение удалённого VPN. Недоступный испытательный WAN — NOT_TESTED, не PASS.

### Переустановка, Doctor и reboot

Только в рамках C GO и после сохранения результатов удаления на ПК:

```sh
cd "$KAS_DIR" || exit 3
sha256sum -c SOURCE_SHA256SUMS >/dev/null || exit 3
KEENETIC_AUTO_SETUP_REF=aef221f80904ff1d8dd639c6f85b308b063b749e \
  sh "$KAS_DIR/install.sh" disk > "$RUN/reinstall.private" 2>&1 || exit 3
KEENETIC_AUTO_SETUP_REF=aef221f80904ff1d8dd639c6f85b308b063b749e \
  sh "$KAS_DIR/mihomo-doctor.sh" > "$RUN/doctor-reinstall.private" 2>&1
doctor_status=$?
printf 'Doctor exit=%s\n' "$doctor_status"
test "$doctor_status" = 0 || exit 3
```

Installer привязывает проектные downloads к полному REF; повторно сверить
watchdog/hook с этим деревом. IPK и add_repo.sh — внешние зависимости, а не
неизменяемый Git tree. Сохранить их версии/URL/hashes и проверить ABI; доступность
feed не обещается. Если источник изменился/недоступен — BLOCKED, не fallback на
случайный бинарник или отключение checks. Старые YAML должны остаться byte-identical;
новые секреты в этот тест не вводить. Doctor WARN остаётся BLOCKED. При пустом
log разрешена реальная штатная проверка watchdog, затем повтор Doctor с сохранением
обоих verdict; здоровые записи не подделывать.

Проверить обе службы, отсутствие дублей, слушающие порты, LAN DNS/HTTP и нужную
маршрутизацию. Затем экспортировать результаты, выполнить reboot через web UI
запасного устройства и повторить A identity/runtime/Doctor/сетевые проверки.
Не выполнять shell reboot до сохранения файлов на ПК. Наблюдаемый новый boot-loop
после reboot — штатен; не начинать ещё одно удаление в рамках этой приёмки.

### Отказ / прерывание

BLOCKED, неизвестный процесс, несовпадение hashes, ошибка OPKG или неожиданный
NDMS/Netfilter state: остановиться, сохранить RUN и весь SNAP/journal на ПК.
Не посылать новые сигналы, не удалять locks/marker, не редактировать журнал.
Плановое отключение питания на первой приёмке **не выполнять**.

После непреднамеренного прерывания: сверить источник SHA, доступ к proc и
отсутствие повторного boot-loop/демонов/конкурентных служб. Возобновление — после
отдельного решения владельца существующей командой
`sh "$KAS_DIR/uninstall-transaction.sh" --remove "$SNAP"`.
У wrapper uninstall.sh есть ранний already-removed no-op; его exit 0 не доказывает
целостность journal после прерывания. Прямой engine нужен именно для resume-аудита,
включая прерывание около удаления ledger. Это существующий режим, не обход guard.
Не запускать fresh snapshot verifier как критерий запрета любого resume: legitimate
частичные изменения делают старое сравнение с live неравным; resume engine имеет
собственный ordered journal/recovery audit. Не готовить новый cache поверх старого.
Если есть busy/stale guard или непонятный marker — BLOCKED и recovery/review,
не ручной rm. При повторном BLOCKED использовать подготовленный offline recovery.

## Чек-лист и порядок интеграции

| Проверка | PASS | FAIL / BLOCKED |
|---|---|---|
| A | Модель/ABI/EXT4/swap/claims/launchers проверены, Doctor OK | Неизвестный owner/consumer, иная платформа/ABI, WARN/FAIL |
| B | Внешние копии, YAML, два IPK, hashes, холодный image и проверенная запись recovery USB | Нет независимого восстановления, иной cache/ABI |
| C remove | Native exit 0 + complete, только owned ресурсы удалены | Любой новый процесс/ошибка/drift |
| Сохранность | YAML и все чужие ресурсы сохранены, DNS/маршруты соответствуют baseline | Неожиданная потеря/изменение |
| Повтор remove | exit 0 + already removed, состояние не изменилось | Повторная мутация/ошибка |
| Cleanup | Нет locks/guards/marker, journal complete, cache intact | Stale/непоследовательный journal |
| Reinstall/reboot | Службы/порты/маршруты/DNS и Doctor OK после обоих шагов | WARN/BLOCKED/FAIL или NOT_TESTED обязательной проверки |
| Unknown/foreign process | Уже проверен Linux fixtures; на устройстве неизвестный процесс означает отказ | Нельзя запускать чужой namesake ради negative test без отдельного GO |
| Resume/power failure | Локальные fixtures PASS; фактическое испытание отдельно NOT_TESTED | Не объявлять проверенным по одному complete journal |

Результаты заносить отдельно: VIRTUAL_PASS, A/B/C hardware PASS/FAIL/BLOCKED/
NOT_TESTED. HARDWARE_READY не равно HARDWARE_PASS и не разрешает stable/release.

Порядок review/merge: **#227 → feature/native-uninstall-transaction (#215)**,
затем совместная ветка **#215 → main** после нужной владельцу натурной приёмки;
**Emulator #31 → main** после review независимо от аппаратного исполнения.
Не делать squash #215 без включения guard #227. Перед merge повторно проверить
base/head и отсутствие потери guard/negative fixtures. Docs-only изменения не
требуют нового QEMU E2E; runtime drift относительно проверенных SHA требует review.
Stable/release — отдельное решение, здесь не выполняются.

Read-only проверка 25.10.2026: #227 основан на #215 и содержит его SHA;
merge-tree с KAS main `d8ead2c3795b52224385254c3e8ff666be99be2b` сохраняет
проверенные runtime/negative fixtures, а также четыре main-only файла.
Emulator main `36a63b66a31e829cb8f3e905c594797669055acd` — предок #31.
Симуляция создаёт только Git tree objects, не merge/commit/ref update веток.

Отдельный integration-риск: в текущем KAS main reusable workflow
`ported-native-e2e.yml` закреплён на Emulator
`94de3b98154dca985e100cd97c4a91e1fd047008`, **не** на проверенном 07e5379….
Перед интеграцией #215 владелец должен отдельно согласовать актуализацию обоих
CI pins (`uses` и `emulator_ref`) до проверенного #31 SHA и проверить итоговый
diff. В задании №6 workflow не меняется и дополнительный E2E не запускается.
Не считать будущий прогон со старым pin проверкой нового handoff.
