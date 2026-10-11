# Phase 3: ARM и KN-1010, 11–12 октября 2026

**Сейчас разрешённый следующий шаг — read-only preflight. Установка WDTT не допущена.** Ни агент, ни CI не подключались к роутерам/VPS. Домашний Keenetic — production, вне этих испытаний.

## Что изменилось

Preflight снова обходит реальные `/proc/[0-9]*` и `/sys/class/net/*`: глобальный `set -f` удалён, отключение glob ограничено разбором ELF bytes. Fixtures ARM64, MIPSel и MIPS под POSIX sh/BusyBox проверяют процессы, TUN, version/components wrapping, RAM, swap, deepest `/opt` FS, ELF class/endian/machine, opkg architecture и порты. Это тест парсеров, не сведения о конкретном устройстве.

Новый `service.sh` — opt-in прототип отдельного Entware lifecycle, `/opt/wdtt-experimental`; init `S98wdtt-lab`. Shipped `INSTALL_ADMITTED=no` не имеет env/CLI bypass. Оператор **не должен менять этот флаг вручную**. Он изменяется только проверенным source commit после закрытия gates. `install.sh --install` делегирует тому же закрытому admission.

Проверки перед установкой: source SHA/toolchain/provenance, ELF ARM64/MIPSel + фактический Entware userspace/opkg/uname, SHA256, GOMIPS=softfloat для MIPSel, RAM, `/opt` space/FS, `/tmp` tmpfs, UDP4/UDP6 порт. SHA из произвольного соседнего файла не является доверенным источником: сверять с проверенным собственным build и полным manifest. Карантинный IPK не принимается как install-ready provenance.

Консервативный floor данного прототипа: MemTotal >=196608KiB, MemAvailable >=98304KiB; если ядро3.4 не имеет MemAvailable, используется только MemFree.128MB-class здесь отвергается. Для <=600000KiB RAM требуется верифицированная native zRAM по block-device/sysfs identity. External swap ещё не имеет admission в этом экспериментальном профиле; он не создаётся и не переключается. EXT4 либо UBIFS с действующим S00ubifs и тремя tmpfs mounts; дополнительный owner gate ext/ext-utils/фактического storage profile остаётся обязательным. Запас `/opt`: размер новой ELF +32MiB при сохранении уже занятых предыдущих версий. Эти floors не заменяют измерения RSS на устройстве.

Конфигурация владельца — `/opt/wdtt-experimental/config.json`,0600, каталог0700. При ручном старте копируется в private `/tmp/wdtt-runtime-UID/config.json`. Received WG config/status/exit/retry находятся в `/tmp`; нет сырых логов или постоянного flash log. STDOUT/STDERR child — `/dev/null`; фиксированные state files ограниченного размера. Указанный `creds_file` также должен быть0600 в0700 каталоге. Имена файлов не должны содержать секреты.

Start/stop/status/restart/rollback/uninstall сверяют PID start-time, executable inode, digest и точные безопасные argv. Пять ручных попыток с exponential backoff, fatal78 блокирует повторы до новой установки. Автоматического restart loop нет. Повторная идентичная установка сохраняет текущий worker/PID, inode/mtime scripts и selectors. Upgrade выбирает новый versioned worker после preflight и остановки старого; автозапуска нет. Rollback атомарно выбирает previous и оставляет worker остановленным. Uninstall удаляет только подтверждённые собственные worker/scripts/state; operator config, WG output, неизвестные файлы остаются. Никогда не вызывает `rm -rf /opt` или `killall`.

Локальный native C fixture проверяет это под двумя shell, включая failed checksum/staging, repeat install, foreign PID, fatal/backoff и очистку временного состояния как модель reboot. Production gate в private test-copy заменяется только синтетическим admission; это **не проверка ARM/MIPS init или настоящей перезагрузки Keenetic**. Power-loss/fsync и реальные BusyBox/platform differences остаются acceptance gates.

## Готовые команды диагностики KN-1010

Сначала физически выделить отдельный сегмент, без связи с рабочей маршрутизацией/доступом сотрудников. Не отключать работающий сегмент ради теста. Скопировать проверенный [preflight.sh](preflight.sh) из точного commit PR#125 в `/tmp/wdtt-preflight.sh` владельцем; не использовать pipe-to-shell.

```sh
sh -n /tmp/wdtt-preflight.sh
sh /tmp/wdtt-preflight.sh
```

Ожидается `WDTT_PREFLIGHT_V1 read_only=true secrets=false`, точные model/hw_id/OS/kernel, `machine`, opkg arch, ELF class/endian/machine, RAM/swap, `/opt` space/FS, process names, UDP/TCP ports в hex и TUN. Для MIPSel кандидат: ELF class1, endian1, machine bytes8,0 и `mipsel-3.4`; это сверяется с реальным результатом, а не подставляется по модели. Float ABI не устанавливается одним uname/ELF e_machine: требуется build metadata GOMIPS=softfloat и затем аппаратный CLI probe.

Если стенд действительно изолирован и владелец согласен на активные probes:

```sh
sh /tmp/wdtt-preflight.sh --network
```

Это fixed public DNS/HTTPS probes, без установки или сетевой конфигурации. По умолчанию они не выполняются. Sanitized результат передать без running-config, keys, passwords, cookies, argv/environ или raw packet captures. `UNKNOWN` требует уточнения. No process/TUN rows теперь означают отсутствие обнаружения, а не отключённый glob.

## ARM 11 октября

Предпочтителен свободный KN-4210, подключённый отдельно. Тот же preflight. ARM64 допускается только по фактическим aarch64 ELF/userspace/opkg evidence; ARMv7 не может запускать ARM64 пакет. При несовпадении выбрать другой реально aarch64 ARM либо отдельно подготовить ARMv7 build. Занятый домашний роутер не использовать.

## Последовательность после закрытия gates

1. Зафиксировать preflight + exact source/patch/SDK/binary/IPK hashes и разрешение владельца на **это устройство**.
2. Получить approved собственный `wt-client-lab`, не `wt-client-quarantine`. Сверить package SHA, Entware architecture, source/patch locks, notices и corresponding source. До этого даже `opkg install` запрещён.
3. До подключения выполнить только совпадающий ELF `-h`: help и exit0, без network credentials. QEMU результат этого не заменяет. Проверить свободный local UDP19000 и SOCKS17890; занятый порт не освобождать чужим stop/kill.
4. После отдельного допуска install-ready IPK размещает immutable payload; opt-in `install.sh --install BINARY VERIFIED_BINARY_SHA ENTWARE_ARCH 19000` проверяет его provenance и создаёт отдельные worker/init. Сейчас эта команда возвращает78 и не устанавливает; placeholders не являются готовым допуском.
5. Создать private config локально редактором; секреты не в argv/env/history. Первый клиент account mode, один worker, свежие owner VK credentials. Anonymous12 workers и нагрузочные прогоны пока не первый сценарий.
6. Ручной start. Полученный private wg-turn.conf конвертировать на Linux/WSL компьютере. Отдельный тестовый Mihomo, SOCKS127.0.0.1:17890, без TUN/controller/default-route/DIRECT fallback. Существующий Mihomo/KAS/MagiTrickle/ProxyN не менять.
7. Проверить реальный WG handshake/counters, TCP, DNS, UDP64/512/1000/1200/1400, MTU/потери, CPU/RSS/threads/flash, bounded status. WAN capture должен показать отсутствие прямого тестового destination и рекурсивного направления VK/TURN/VPS/DNS обратно в туннель. IPv6 отдельный NOT RUN gate, не вывод о всей LAN.
8. Stop, rollback, uninstall; затем только отдельно разрешённая reboot-проверка свободного стенда. При reboot init start без --manual ничего не запускает. Существующий WAN/KAS baseline должен сохраниться. Повторный ручной старт требует проверки expiry и новых credentials.

## Команды lifecycle только для уже допущенной установки

Эти команды не устанавливают пакет и сейчас не предлагаются к выполнению на роутере. После отдельного разрешения и успешного install:

```sh
sh /opt/etc/init.d/S98wdtt-lab start --manual
sh /opt/etc/init.d/S98wdtt-lab status
sh /opt/etc/init.d/S98wdtt-lab stop
sh /opt/etc/init.d/S98wdtt-lab restart --manual
sh /opt/etc/init.d/S98wdtt-lab rollback
# После проверки digest previous — отдельный ручной start, если нужен.
sh /opt/etc/init.d/S98wdtt-lab uninstall
```

`RUNNING_NOT_TUNNEL_PROOF` означает только подтверждённый процесс, не соединение. После uninstall IPK payload/package-manager metadata не удаляются этим сервисом: это отдельный собственный пакет `wt-client-lab`, его удаление через opkg требует проверки владельцем; operator secrets остаются. Не удалять каталоги рекурсивно ради уборки.

## Что безопасно проверить 12 октября

На KN-1010: изоляция сегмента, read-only preflight, фактический ABI/kernel/RAM/storage/components/ports/TUN и active probes по выбору. Если лицензионный и security gates всё ещё открыты — не выдавать/не ставить пакет, не запускать WDTT или тестовый Mihomo. На собственном Linux компьютере доступны сборки, synthetic TURN/Mihomo acceptance и quarantined IPK format tests, без VK или подключения к роутеру. Точная матрица ресурсов устройств остаётся UNKNOWN до полученного вывода.

Статус пакетов и server candidate — [entware-go PR#10](https://github.com/saymer-alt/entware-go/pull/10); [общая матрица приёмки](TEST-SCENARIOS.md). Главный license blocker — fhttp и полный scope/corresponding-source approval; package SHA и green CI его не закрывают.
