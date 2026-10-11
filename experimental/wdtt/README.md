# WDTT: изолированный эксперимент, допуск закрыт

Основная установка KAS не вызывает эти файлы. Домашний роутер — production: установка и сетевые изменения запрещены. Удалённые подключения не выполнялись. Исследование сохранено в [PR #124](https://github.com/saymer-alt/keenetic-auto-setup/pull/124).

Предпочтительный первый стенд — свободный KN-4210 после подключения в отдельную сеть. Модель со слов владельца не определяет ABI. Сначала read-only preflight; если это ARMv7, ARM64 ELF запрещён. Выбрать дополнительный aarch64 роутер или отдельно согласовать ARMv7 сборку. KN-1010 — следующий отдельный MIPSel стенд, отсоединённый от рабочей инфраструктуры.

## Действия владельца: сначала диагностика

Команды выполняются владельцем локально на отдельно разрешённом тестовом устройстве после копирования проверенного файла. Никакого pipe-to-shell, opkg update/install или подключения к домашнему роутеру.

```sh
sh -n ./preflight.sh
sh ./preflight.sh
# Опционально, только на разрешённом тестовом стенде:
sh ./preflight.sh --network
```

Ожидается заголовок `WDTT_PREFLIGHT_V1`, kernel/machine, Entware architecture и ELF class/endian/machine, RAM/swap, /opt, компоненты, VPN process names, порты в hex и TUN. `UNKNOWN` означает отсутствие доказательств; не заменять предположением. Вывод не содержит process argv, environ, running-config, WG конфиги или opkg repository URLs. Перед передачей проверить локальные названия/адреса и удалить ненужные данные. Активные DNS/HTTPS probes отключены по умолчанию. Скрипт ничего не записывает; он не является нагрузочным тестом.

| Стенд | Фактический ABI/ядро/RAM | Следующий шаг |
|---|---|---|
| KN-4210 | UNKNOWN | Подключить изолированно, preflight |
| KN-1010 | UNKNOWN | Отсоединить рабочую сеть, отдельный preflight |
| Другие ARM | UNKNOWN | Сообщить точную модель и preflight |
| Домашний | Не обследован | Только отдельно согласованная read-only диагностика |

## Gate перед установкой

Сейчас готовый IPK не выпускается. Не закрыты notice/scope fhttp, production/server review и реальная VK пара. Локальная TURN/WRAP/DTLS/WG/Mihomo пара уже прошла TCP, tunnel DNS, UDP 64–1400 байт, handshake/counters и transport-down failure. AUTH-патч проверен на реальном обработчике; это не полный аудит сервера. Лабораторный бинарник — vpn-only, секреты в 0600 JSON внутри 0700 каталога, STDIN закрыт, upstream stdout/stderr отключены, вместо них фиксированный status. Диагностика потеряна сознательно до аудита безопасного структурированного вывода. Это не production исправление всего upstream.

`install.sh` сейчас только admission guard с `--plan`: возвращает 78 при попытке установки и ничего не меняет. Отдельный `sandbox-lifecycle.sh` реализует install/start/stop/status/restart/rollback/uninstall **только** внутри private `/tmp/wdtt-sandbox-*`. Проверяет checksum, атомарно выбирает versioned binary, сохраняет previous, отказывает при чужом PID/inode/start-time/argv и symlink, сохраняет unknown files и operator secrets. Он не устанавливается в Entware init.d. Полный router admission/Entware init/reboot transaction пока **не реализованы и не проверены**. Не выдавать sandbox за готовый установщик.

Sandbox не перезапускает процесс автоматически: ручные старты ограничены пятью попытками с exponential backoff, код78 блокирует повтор до новой установки. Child stdout/stderr направлены в /dev/null, status и exit-code имеют фиксированный размер. Это отдельная локальная проверка файлов/процессов, не доказательство совместимости BusyBox на конкретном Keenetic. Тест: `python3 tests/wdtt-sandbox.py` на Linux с gcc и BusyBox. Запускать sandbox на роутере не предлагается.

## После закрытия gates: ARM64 сценарий

1. Сверить preflight: фактический aarch64 userspace + Entware architecture, kernel, /opt EXT4 либо внутренний UBIFS с действующим S00ubifs. Применить существующие KAS resource gates из docs/06; ничего не создавать/расширять в swap автоматически. При нехватке памяти выбрать другой стенд.
2. Получить собственный бинарник и SHA256 из проверенной CI provenance. Проверить ELF class64/endian little/machine183, отсутствие PT_INTERP, исходный SHA + patch/overlay/go.sum/toolchain hashes. QEMU `-h` не доказывает пригодность устройства.
3. Владелец отдельно разрешает установку. Только отдельный каталог и ручной сервис; автозапуск после reboot отключён. Секреты создать локально редактором с umask077; не вводить в argv, export, историю shell, Git или отчёты.
4. Существующий Mihomo/KAS/ProxyN/MagiTrickle не изменять. Подготовленный outbound проверять на копии конфига офлайн. Для первого натурного теста использовать выделенный чистый тестовый Mihomo; не запускать второй рядом с KAS daemon. Для изменения единственного тестового Mihomo нужна отдельная разрешённая транзакция с backup/rollback.
5. Первое приложение подключать явно через SOCKS 127.0.0.1:17890. Не создавать default route, policy route, TUN или DNS interception. Никакого DIRECT fallback для тестового приложения: транспорт down должен дать ошибку приложения, а независимый WAN baseline должен сохраняться.
6. Сохранить результаты из [матрицы испытаний](TEST-SCENARIOS.md). Только после успешной ARM приёмки переходить к MIPSel.

## MIPSel softfloat сценарий

Отдельная сеть и собственный preflight KN-1010. Требуются ELF32 little-endian machine8, Go build settings GOMIPS=softfloat, Entware mipsel ABI; uname mips сам по себе не различает endian. Не использовать ARM64/MIPS big-endian файл. Оценивать RAM/CPU/flash отдельно, особенно при 12 anonymous workers. MIPS BE имеет лишь лабораторный CLI gate, аппаратного стенда пока нет. Шаги маршрутизации, rollback и приёмки те же, результаты не объединять с ARM.

## Сервер

Кандидат — root server и go_client одного upstream SHA `1110a75f76e42c23149b8e24f9182c1ff179e515` с лабораторными security/AUTH patches, не произвольные awgm-client/server release tags. Локальный стенд запускает реальный patched handleConn, WRAP/DTLS, Pion TURN и userspace WireGuard, но не серверный main и не VK. Main, NAT/TUN, Telegram и HTTP control API в стенде не исполняются.

Upstream main изменяет ip_forward, NAT/FORWARD, удаляет wg-интерфейс и запускает HTTP API TCP на том же listen endpoint, что DTLS UDP (по умолчанию 56000); секретные флаги password/bot-token есть в argv. Поэтому готовой команды запуска на VPS сейчас нет. Подготовленный вариант — только одноразовая VM без рабочих Xray/3X-UI/AWG, отдельная сеть, отдельные 0700 конфиги, UDP56000 доступен только тестовому relay path, внутренний WG port только loopback, TCP API и Telegram выключены/изолированы. Перед исполнением нужны server file-secret/permission/auth patch и namespace/VM тесты. Не запускать upstream installer на VPS владельца.

## Stop, rollback, reboot

В текущем состоянии установщик не изменяет устройство, поэтому rollback не требуется. Проект сервиса расположен отдельно и проверяется в sandbox; он не включается в init.d на реальном устройстве до закрытия gates. Нет изменений routes/DNS/Mihomo, значит восстановление этих подсистем не выполняется и их работа проверяется независимым baseline.

Sandbox rollback возвращает previous binary selection атомарно и оставляет сервис остановленным; owner запускает его явно. Не перезаписывает бинарник работающего процесса. Uninstall сверяет version digest, удаляет только собственные worker-файлы и state; operator config и неизвестные файлы остаются. Перенос этих механизмов в Entware потребует отдельного admission/reboot/fault review. После reboot ручной старт и новые TURN credentials, пока не доказано безопасное unattended refresh.

## Офлайн конвертация WG-конфига

`wg_to_mihomo.py` запускается на отдельном Linux/WSL компьютере с Python3, не требует установки Python на Keenetic. Вход — реально полученный wg-turn.conf, режим0600 внутри каталога0700; выход — новый private JSON (допустимая YAML форма), существующий файл никогда не перезаписывается.

```sh
python3 ./wg_to_mihomo.py /absolute/private/wg-turn.conf /absolute/private/mihomo-lab.json --port 19000
```

Порт обязан совпасть с локальным endpoint wt-client. Конвертер допускает одного IPv4 peer, отвергает PostUp/команды, повторные секции, нелокальный endpoint и IPv6. `remote-dns-resolve: true` и DNS из выдачи сервера направляют DNS через WG outbound; просто включить SOCKS5h недостаточно. Нет TUN, controller, DIRECT fallback, allow-lan или изменения системного DNS. WireGuard параметры подтверждены кодом [Mihomo v1.19.32](https://github.com/MetaCubeX/mihomo/blob/88dcbf7f1614a67c3b36b848ee3592dfa92ada36/adapter/outbound/wireguard.go#L69-L100).
