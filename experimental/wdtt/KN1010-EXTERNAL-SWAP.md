# KN-1010: внешний SWAP, повторная диагностика

Статус: **INSTALL_BLOCKED**. Запуск MIPSel ELF с exit 0 и совпадение SHA256
скачанного IPK уже подтверждены владельцем; пересборка и повторное исследование
архитектуры не требуются. Это не измерение памяти рабочего WDTT.

По данным владельца: MemTotal 254472 КиБ, MemAvailable около 70 МиБ,
SWAP 479996 КиБ, Used 0; Mihomo RSS около 71 МиБ, MagiTrickle около 14 МиБ.
Текущий WDTT floor 98304 КиБ (96 МиБ) доступной RAM не выполнен:
при 71680 КиБ дефицит 26624 КиБ (26 МиБ). Swap примерно 1.89x RAM,
но его ёмкость не добавляется к MemAvailable и не доказывает приемлемую задержку.

`preflight.sh --kn1010-external-swap` — новый **диагностический** профиль,
не обход установщика. Он показывает memory floor, единственную активную swap
partition `/dev/sda1`, совпадение major/minor с sysfs, признаки USB в sysfs,
RSS/VmSwap существующих процессов, счётчики swap/major faults и доступные PSI.
Отсутствующие доказательства остаются UNVERIFIED/UNKNOWN. Совпадение этих
проверок не разрешает установку: результат всегда `candidate_install=BLOCKED`.
Выход 0 означает завершение read-only диагностики, а не допуск.

ELF-чтение preflight использует `dd` и базовый `od -b`; расширенные
`od -A/-t/-N` не требуются. Octal bytes явно преобразуются в decimal через awk.
Короткий или неверный заголовок даёт UNKNOWN. Это исправление переносимости,
не новое доказательство softfloat. Полная сборка BusyBox 1.37 поддерживает и
старые опции; версия сама по себе не определяет конфигурацию vendor applet.

## Команды владельцу

Использовать проверенную новую копию preflight в `/tmp/wdtt-preflight.sh`.
Ссылку на закреплённый commit и SHA256 выдаёт итоговый отчёт изменения.
Не использовать старый файл из уже скачанного IPK как новую диагностику.

```sh
sh /tmp/wdtt-preflight.sh --kn1010-external-swap
```

Ожидается MIPSel `entware_elf_class=1 endian=1 machine_bytes=8,0` и
`candidate_memory_gate=BLOCKED` при прежних 70 МиБ. При достаточной RAM
печатается только `FLOOR_MET_NOT_ADMISSION`. `candidate_swap_block_identity=matched`
и `candidate_swap_external_evidence=usb_sysfs_path` — дополнительные признаки,
не разрешение на install. Строка `candidate_install=BLOCKED` обязательна.

Далее 5 минут наблюдения в обычной нагрузке, без запуска WDTT, без отключения
Mihomo/MagiTrickle и без искусственного pressure/stress. Команды ничего не пишут
на роутер и не читают argv/environ/config; вывод сохранить в журнал терминала
на компьютере владельца:

```sh
i=0
while [ "$i" -lt 30 ]; do
    printf '\nSAMPLE %s\n' "$i"
    date -u
    awk '/^(MemTotal|MemAvailable|MemFree|SwapTotal|SwapFree):/ {print}' /proc/meminfo
    awk '/^(pswpin|pswpout|pgmajfault|oom_kill) / {print}' /proc/vmstat
    cat /proc/loadavg
    awk '$3=="sda" || $3=="sda1" {print}' /proc/diskstats
    for d in /proc/[0-9]*; do
        [ -r "$d/comm" ] || continue
        IFS= read -r name < "$d/comm" || continue
        case "$name" in
            mihomo|magitrickle*|wt-client)
                printf 'process=%s pid=%s\n' "$name" "${d##*/}"
                awk '/^(VmRSS|VmSwap|Threads):/ {print}' "$d/status" 2>/dev/null
                ;;
        esac
    done
    i=$((i+1))
    [ "$i" -ge 30 ] || sleep 10
done
```

Дельты pswpin/pswpout — страницы, pgmajfault — события; не выдавать их за
байты/секунду без размера страницы и интервала. `/proc/diskstats` — общий I/O
диска, не изолированная задержка swap. Нулевой swap I/O на idle не является
нагрузочной проверкой. PSI на старом ядре может отсутствовать.

## Что ещё нужно для допуска

1. Подтверждённая block/sysfs/USB identity `/dev/sda1`, одна активная partition
   без смешивания zRAM и disk swap; фактические `/opt` EXT4, `ext`/`ext-utils`,
   свободное место и `/tmp` tmpfs. Preflight уже выводит эти сведения.
2. Минимальная MemAvailable, максимальные RSS/VmSwap Mihomo/MagiTrickle,
   динамика swap/major faults и I/O в характерной рабочей нагрузке. Если RAM
   остаётся ниже 96 МиБ, действующий floor сохраняет блокировку. Не выполнять
   drop_caches, swapoff/swapon или принудительное освобождение RAM для PASS.
3. Для отдельного решения о снижении floor нужны измерения пикового RSS и
   задержек **реального MIPSel WDTT с одним account worker**, reconnect/stop,
   при сохранении нагрузки Mihomo. Получить их на отдельном допущенном MIPSel
   стенде с достаточной RAM; запуск на этом заблокированном роутере не разрешён
   данной диагностикой. QEMU и `-h` не заменяют измерения рабочего клиента.
4. Затем отдельно реализовать и проверить ограниченный external-swap admission
   в install **и** start с повторной проверкой identity/ресурсов, мониторингом и
   остановкой только своего WDTT при выходе за измеренный бюджет. Здесь такого
   допуска нет; глобальные RAM/zRAM/provenance guards не изменены.

Не запускать `opkg install`, не патчить admission в скачанном IPK, не менять
закреплённые lifecycle hashes в provenance и не использовать `--force-*`.
Существующие service.sh/init.d/install.sh, автозапуск, маршруты и production
скрипты не меняются. Ручная аппаратная установка остаётся следующим отдельно
допущенным этапом после устранения перечисленных blockers.
