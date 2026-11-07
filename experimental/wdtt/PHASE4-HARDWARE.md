# Phase 4: owner-local установка и физическая приёмка

Актуальный сценарий вместо ограничений Phase3: публичные release-gates не меняются; отдельный owner-local `wt-client-owner-test` разрешает техническую установку без ложного APPROVED. Карантинный `wt-client-quarantine` по-прежнему не устанавливается. [Backlog](https://github.com/saymer-alt/entware-go/issues/11), отложенная задача [KAS#126](https://github.com/saymer-alt/keenetic-auto-setup/issues/126).

Ни агент, ни CI не подключаются к роутерам. KN-1010 на работе — только физически изолированный сегмент. KN-4210 — второй свободный стенд; ARMv7 не принимать за ARM64. Домашний production вне scope. Фактические результаты preflight и разрешение владельца нужны до аппаратной установки.

## 1. KN-1010: сначала read-only

Владелец копирует exact-commit preflight в /tmp; не pipe-to-shell:

```sh
sh -n /tmp/wdtt-preflight.sh
sh /tmp/wdtt-preflight.sh
```

Ожидаются `read_only=true`, model/hw_id/OS/kernel, ELF class/endian/machine, opkg arch, RAM/zRAM/swap/storage, процессы/порты/TUN. Для MIPSel: ELF32 LE MIPS и mipsel-3.4. Softfloat подтверждается pinned build metadata и последующим реальным ELF probe; один uname его не доказывает. UNKNOWN не считать PASS. Сопоставить с требованиями KAS: EXT4 + ext/ext-utils для external /opt либо UBIFS + S00ubifs/tmpfs для internal; сверить компоненты и memory backend. Ничего не форматировать и не переключать.

Консервативный текущий WDTT floor сохранён: RAM>=196608KiB, available>=98304KiB; Linux3.4 fallback — только MemFree. <=600000KiB требует native verified zRAM; external swap пока не имеет admission. Если реальный KN-1010 не проходит, зафиксировать результат и сделать отдельное измеренное изменение профиля; не обходить проверку. Запас /opt — ELF+32MiB сверх существующих версий, /tmp tmpfs. Установщик повторно проверяет ресурсы/ABI/SHA/UDP4+UDP6; start повторно проверяет available RAM.

## 2. Проверенный пакет и probe

Получить из защищённого owner-local каталога:

- wt-client-owner-test_ARCH.ipk, соответствующий ELF, provenance-ARCH.json, SHA256SUMS/OWNER-TEST-BUILD.json;
- exact KAS commit в provenance, source/patch/SDK/notices/build report;
- разрешение владельца на этот isolated device после preflight.

Публичные Actions artifacts не содержат этих бинарников. Не брать старый публичный owner/quarantine artifact. Проверять hashes по доверенному owner-local manifest, не по случайному соседнему checksum. Скопировать только нужный ELF и IPK в /tmp, без секретов.

```sh
# Значения заменить на exact filenames и trusted hashes из owner manifest.
printf '%s  %s\n' "$ELF_SHA256" "$ELF" | sha256sum -c - || exit 1
printf '%s  %s\n' "$IPK_SHA256" "$IPK" | sha256sum -c - || exit 1
chmod 700 "$ELF"
"$ELF" -h
opkg print-architecture
```

Ожидается help/exit0 без connection/credentials. illegal instruction/loader error/OOM — STOP, пакет не устанавливать. Снять available RAM/df до и после; help не заменяет измерение working RSS. Не устанавливать отсутствующие инструменты или зависимости автоматически ради обхода admission.

## 3. Установка: только после подтверждения владельцем

Задать PAYLOAD точно из OWNER-TEST-BUILD.json, не выбирать первый найденный каталог. На устройстве должна быть штатная ca-bundle; package dependency проверяет opkg. Не применять --force-*.

```sh
opkg install "$IPK" || exit 1
# opkg размещает только immutable payload и не запускает сервис.
sh "$PAYLOAD/install.sh" --install-owner-test "$PAYLOAD/wt-client" "$ELF_SHA256" mipsel-3.4 19000
```

Для подтверждённого ARM64 заменить только architecture на aarch64-3.10 и использовать соответствующие IPK/ELF/SHA/PAYLOAD. Для ARMv7 нужен отдельный build/change, этот пакет не подходит.

Ожидается INSTALLED_AUTOSTART_DISABLED. Обычный --install остаётся source-gated. Owner-test admission проверяет owner provenance, SDK, SHA бинарника и всех lifecycle scripts; quarantine/ложный APPROVED/подмена scripts не принимаются. Повторная идентичная активация даёт INSTALL_UNCHANGED и сохраняет worker/PID/mtime.

Локальным редактором создать /opt/wdtt-experimental/config.json (0600, каталог0700) по [client template](client.json.template), один worker, account mode, listen127.0.0.1:19000. Credential файл0600 в0700 каталоге; не argv/env/history. Рабочие конфиги других сервисов не использовать. Runtime копируется в /tmp/wdtt-runtime-0, raw logs подавлены.

```sh
sh /opt/etc/init.d/S98wdtt-lab start --manual
sh /opt/etc/init.d/S98wdtt-lab status
sh /opt/etc/init.d/S98wdtt-lab stop
sh /opt/etc/init.d/S98wdtt-lab restart --manual
```

Ожидается RUNNING_NOT_TUNNEL_PROOF либо STOPPED. Status не доказывает handshake/UDP connectivity. Запуск делает exclusive UDP bind; занятый порт не освобождать чужим kill. После остановки убедиться в сохранности конфигурации (sha256sum локально, не содержимое) и WAN/Mihomo baseline.

## 4. Rollback / uninstall / reboot

```sh
sh /opt/etc/init.d/S98wdtt-lab stop
sh /opt/etc/init.d/S98wdtt-lab rollback
sh /opt/etc/init.d/S98wdtt-lab status
# После проверки previous SHA — отдельный start --manual при необходимости.
sh /opt/etc/init.d/S98wdtt-lab uninstall
opkg remove wt-client-owner-test
```

Rollback требует реально существующую previous version; первая установка не имеет previous и корректно отказывает. При upgrade старый worker и конфиг сохранены отдельно от immutable package payload. Rollback отключает Automatic и оставляет previous остановленным. Source commit failure восстанавливает prior selectors/scripts; power-loss/fsync не обещаны. Uninstall lifecycle сначала останавливает собственные worker/supervisor, удаляет только verified собственные файлы; config/credentials/чужие файлы сохраняются. Затем opkg удаляет только собственный payload; сам opkg remove не является заменой lifecycle uninstall. Никогда не rm -rf /opt.

Перезагрузка свободного стенда только отдельным решением владельца. В Manual после reboot WDTT не стартует. Проверить KAS/Mihomo/WAN/DNS baseline, затем новые действующие credentials и ручной запуск. Настоящий reboot требует физического результата; CI моделирует потерю volatile state.

## 5. Automatic — отдельный opt-in

Только после успешных manual/network/stop и настоящего manual reboot acceptance. Запустить manual и проверить его процесс, затем владелец явно подтверждает уже выполненную приёмку:

```sh
sh /opt/etc/init.d/S98wdtt-lab enable-auto --manual-reboot-verified
# Включение планирует Automatic на следующий boot; не запускает второй worker.
sh /opt/etc/init.d/S98wdtt-lab disable-auto
```

Automatic использует существующий Entware init после доступности /opt, ждёт IPv4 default-route до120sec, не меняет маршрут и не обещает Internet readiness. Private supervisor проверяет собственный PID/start-time/shell/script/argv. Не более5 попыток, exponential worker backoff, fatal78 прекращает повторы. Невозможность проверки сети даёт timeout; raw logs/secret argv отсутствуют. Stop выключает текущий supervisor и worker, сохраняя режим для следующего boot; disable-auto оставляет уже работающий worker ручным. Upgrade service/binary требует нового opt-in (marker связан с hashes); rollback снимает marker. Отказ WDTT не перезапускает Mihomo и не меняет routing/DNS/firewall.

## 6. Отдельный Mihomo / сервер

Использовать [wg_to_mihomo.py](wg_to_mihomo.py) на private received wg-turn.conf; отдельный тестовый Mihomo с SOCKS127.0.0.1:17890, без controller/TUN/default-route/DIRECT fallback. Существующий Mihomo/KAS/ProxyN/MagiTrickle не менять. Сначала согласованный disposable relay и synthetic TURN, затем [отдельный настоящий VK TURN](https://github.com/saymer-alt/entware-go/blob/feature/wdtt-build-poc-20261011/wdtt/server/README.md). Агент на VPS не подключается.

```sh
curl --socks5-hostname 127.0.0.1:17890 --connect-timeout 5 --max-time 20 https://example.com/ -o /dev/null
```

WG handshake/counters проверять на test backend без raw dumps/keys. UDP ASSOCIATE — к управляемому echo endpoint с проверкой64/512/1000/1200/1400 bytes, не TCP fallback. [Матрица](TEST-SCENARIOS.md): CPU/RSS/threads idle/load1/5/15min, MTU/loss, expiry/revocation, bounded status, WAN UP/DOWN no-leak/no-recursion. Эти аппаратные/сетевые строки ещё NOT RUN.

## 7. Уже проверено и что ждёт устройства

CI: real native Entware-patched opkg install/repeat/upgrade/remove обоих target IPK в offline-root, без --force-*; SHA/corruption/arch refusal и preservation сторонних файлов. Отдельные native process/filesystem lifecycle fixtures под POSIX sh/BusyBox проверяют manual/Automatic, readiness, backoff/fatal/budget, rollback, config preservation и reboot model. ELF/softfloat/QEMU CLI и local actual client/relay/Mihomo проверяются отдельно.

Нужны владелец и настоящий preflight: KN-1010 CPU/kernel/ABI/RAM/backend/storage, реальный Entware opkg/init, working RSS, UDP endpoint, hardware lifecycle и reboot; KN-4210 ABI и та же методика. Хостовая fixture не объявляется физической приёмкой.
