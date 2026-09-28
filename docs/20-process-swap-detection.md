# Process discovery и тип swap backend

Изменения B6/C1 относятся к development; promotion в stable требует отдельного
решения и hardware acceptance.

## B6: контракт состояния процесса

`mp_state` возвращает `0 = running`, `1 = stopped`, `2 = unknown`.
`MP_PIDS` содержит обнаруженные PID, а не догадку по доступности порта.
Отсутствие `pidof` не доказывает остановку Mihomo.

При доступном `pidof` непустой числовой список PID означает running, стандартный
exit 1 — stopped; ошибка команды или некорректный ответ — unknown. Без `pidof`
проверяется `/proc`: executable с точным basename `mihomo` (включая неканонические
копии), canonical path `/opt/sbin/mihomo` или `/opt/bin/mihomo`, либо совпадение
inode с canonical binary. Суффикс ` (deleted)` не скрывает живой процесс.
Подстроки в argv/comm не являются доказательством identity. Несколько Mihomo —
running, никогда stopped; Doctor сообщает дубликаты.

Если executable живого userspace-процесса недоступен, результат unknown.
Исчезнувшие PID, zombie и kernel threads с флагом PF_KTHREAD не исполняют ELF.
Неполный/restricted proc view, включая hidepid, не позволяет доказать отсутствие.
Unreadable cmdline не мешает достаточному executable evidence.

Stop подтверждается только stopped; start/restore — только running. Перед ELF
probe и commit требуется stopped. При unknown mutator прекращает опасный шаг;
Doctor пропускает probe и сообщает ограниченную наблюдаемость; watchdog пишет
SKIP до restart. Порт 7890 остаётся отдельным свидетельством готовности.

Общий lifecycle lock B1/B2 остаётся неизменным: detector не сериализует процессы.
Doctor повторяет наблюдение внутри краткой reservation. B4 после rollback
дополнительно требует единственный PID и точное совпадение device/inode
`/proc/<pid>/exe` с восстановленным canonical binary. Generic running эту
проверку не заменяет.

## Inventory исходной базы a0f9a45

| Consumer | Назначение | Прежний detector | Без pidof / consequence |
|---|---|---|---|
| install.sh | version/config probes; service action | conservative `mihomo_running` | probes пропускались, но unknown считался running: ложное подтверждение и возможный restart |
| update-mihomo.sh | prior state, stop, deferred ELF, commit, start/restore | command-v + pidof, прямые pidof | prior running терялся; deferred probe мог идти рядом с daemon; start verification пропускалась |
| update-mihomo.sh | B4 rollback stop / exact runtime | required pidof + stat exe inode | rollback fail-closed, но без fallback; строгий inode contract сохранён |
| migrate-mihomo-mips.sh | apply stop/probe/restore; start confirmation | command-v + pidof | stop gate пропускался, ELF мог выполняться рядом с daemon; start мог объявляться успешным без проверки |
| migrate-mihomo-mips.sh | read-only check | command-v + pidof + lifecycle | probe безопасно пропускался; теперь доступен при доказанном stopped через proc |
| migrate-mihomo-tun.sh | apply stop/start/restore, check | required pidof / command-v | apply отказывал; check пропускал probe; теперь тот же safety contract с fallback |
| config-import.sh | stop/start/restore | required pidof | apply отказывал; теперь fallback и явное stop confirmation при rollback |
| mihomo-doctor.sh | observation, executable probes | pidof либо argv0 из proc cmdline | unreadable cmdline мог давать нулевой count и разрешать ELF; теперь unknown |
| mihomo-doctor.sh, updater, migrations | canonical binary resolver | PID + proc exe | без pidof выбирался файловый PATH fallback; теперь PID доступны через общий detector |
| mihomo-watchdog.sh | restart outcome | optional pidof | outcome не проверялся; теперь unknown также запрещает сам restart под late lifecycle lock |
| setup.sh | bootstrap | process probes отсутствуют | делегирует installer/import; отдельный detector не добавлен |
| update-watchdog.sh | доставка watchdog | Mihomo process probes отсутствуют | не управляет daemon; lifecycle helper не изменён |
| прочие production helpers | read-only API/interface/route и netfilter/tmpfs | нет Mihomo process lifecycle decisions | не изменены; Doctor magitrickled probe относится к другому daemon |

Init status и pgrep не служили источниками Mihomo safety decisions. Существующие
tests pin stop/restore, lifecycle exclusion и B4 inode verification; их assertions
сохранены, fixtures дополняются новым helper и реальным форматом PID output.

## C1: identity zRAM

Единый embedded `swap_is_zram` используется installer, Doctor и updater.
Нужны все признаки: active swap type `partition`, canonicalized basename
`zram` + непустой числовой индекс, фактический block-device тип из stat и
совпадающий major:minor в `/sys/class/block/zramN/dev`.
Symlink допускается, если canonical target удовлетворяет этим требованиям.
Недоступный/противоречивый sysfs или device metadata означает unverified,
а не native zRAM. В частности, один лишь путь `/dev/zram0` недостаточен.

`/tmp/mnt/disk/zram.swap`, `/opt/my-zram-file` и mountpoint с `zram` остаются
storage-backed, если mount классифицирован как external. Размер >2 ГиБ не
обходит cap. 128 MB требует external swap >=384 MB: такой файл засчитывается,
native zRAM — нет. 256 MB без backend остаётся WARN; 512 MB без доказанного
backend — installer ERROR / Doctor FAIL. Updater сохраняет advisory-only policy.
Coexistence native zRAM + external swap остаётся WARN. Пороги 1x/3x/2 GiB не меняются.

Parser сохраняет существующий формат `/proc/swaps`: escaped `\040` остаётся
escaped и сопоставляется с таким же mount path; deleted entries учитываются
отдельно. Расширение grammar и существующей storage verification вне C1 не
выполнялось. Недоступные storage sources используют прежнюю mount/active-size
модель, но имя с `zram` больше не меняет тип.

## Границы гарантий

Наблюдение `/proc` не является атомарным snapshot. Протокол исключает другие
project tools, но не ручные старты, внешний supervisor, иной PID namespace или
намеренно замаскированный executable. Доступный pidof сохраняет свою штатную
семантику. Hardware acceptance на Keenetic/Entware ещё не выполнен; power-loss
и SIGKILL recovery не расширялись. WAN/proxy/cooldown watchdog не изменены.
