# WDTT / CSQTT / WG-obfuscator для Keenetic Auto-Setup

Дата снимка: **2026-10-11**, Europe/Moscow. [Индекс](README.md) · [Основной отчёт](WDTT-CSQTT-WG-OBFUSCATOR-2026.md) · [Матрица](TRANSPORT-COMPATIBILITY-MATRIX.md) · [Сборки](TRANSPORT-BUILD-PLAN.md) · [Интеграция](KAS-TRANSPORT-INTEGRATION.md) · [Тесты](TRANSPORT-TEST-PLAN.md)

## 1. Решение для владельца

**Первым проверять WDTT в WG-режиме с локальным UDP endpoint перед существующим WireGuard-outbound Mihomo (вариант B).** Самостоятельная сборка hoaxisr `wt-client` уже подтверждена для Linux AMD64, ARM64, MIPSel и MIPS softfloat. Вход в standalone-код не требует запущенного AWG Manager: пустой управляющий socket оставляет ручной режим; библиотека `awgmproto` остаётся зависимостью сборки. Выдаваемая сервером конфигурация — обычный WireGuard. Преобразование в YAML технически прямое; совместимость настоящей клиент-серверной пары и Keenetic ещё **UNVERIFIED**. [W1] [W5] [W15] [M1]

**WG-obfuscator — небольшой дополнительный эксперимент**, полезный для маскировки существующего WG без замены его криптографии. Это прямой UDP до своего сервера со STUN-подобной оболочкой, **не VK TURN** и не способ получить доступ к заблокированному IP через разрешённый VK. Сборки четырёх архитектур и локальный синтетический forwarding подтверждены, эффективность против DPI и преимущество перед AWG 3.1 — **UNVERIFIED**. [O3] [O4] [O5] [M1]

**CSQTT ARM64 заслуживает ограниченного исследования**, поскольку текущий клиент использует Tokio/epoll, а не обязательный io_uring. Однако native C-криптография, Rust target/stdlib и PolyForm Noncommercial не позволяют объявить его готовым универсальным пакетом KAS. MIPS требует отдельного порта/сборочного исследования, а RAW требует владельца TUN и проверки криптографического протокола. Утверждение «RAW быстрее и безопаснее WG» не подтверждено измерениями либо независимым аудитом. [C1] [C3] [C6] [C13]

Практический результат CSQTT: AMD64 GNU build прошёл; vanilla ARM64/musl выявил три ABI-ошибки, а изолированная копия с минимальной правкой этих мест собрана в **static AArch64 ELF8,592,288 B**, SHA256 `d9beeb126f785cf40a1bd63db7460a1082dae2619093ee3ac8a05c4c55a55bca`. QEMU исполнил CLI parser; kernel/TUN/VK runtime не проверен. Нативные crypto deps не потребовали замены backend. Upstream и рабочие компоненты KAS не исправлялись; diff сохраняется только как исследовательский артефакт. [C14] [C19]

Отказаться от обязательных панелей, второго Mihomo, SOCKS5 WDTT как универсального UDP-egress, переноса серверных инсталляторов на роутер и автоматической публикации непроверенных обновлений. Экспериментальная сборка не означает принятие лицензионной совместимости к распространению.

## 2. Метод, границы и актуальность

Проверены Git checkout, go.mod/go.sum, Cargo.toml/Cargo.lock, runtime entrypoints, TURN allocation, конфигурационный обмен, fd/TUN paths, C forwarding, Actions, установщики, лицензии, последние commits/releases/issues. Сетевые обращения исследования: GitHub, официальные исходники/пакеты компиляторов и registry зависимостей. Настоящие VK credentials, accounts, tunnel endpoints и приватные конфигурации не использовались. Производительность, RAM/RSS под трафиком, DPI и маршрутизация Keenetic не измерялись.

В таблице дата **коммита**, а не обещание активности автора; release tags могут быть новее исходников и не совпадать с default branch. Все ссылки ниже фиксируют SHA. API `NOASSERTION` не означает отсутствия лицензии: проверялся текст файлов.

| Репозиторий | Точная ревизия | Дата коммита | Ветка / состояние |
|---|---|---|---|
| amurcanov/csqtt | [71712b07dbab](https://github.com/amurcanov/csqtt/commit/71712b07dbabe16fa43f5a248dc69e1ab9f3a270) | 2026-10-03T04:20:28+03:00 | main; не archived |
| amurcanov/proxy-turn-vk-android | [f4f83bd5d221](https://github.com/amurcanov/proxy-turn-vk-android/commit/f4f83bd5d22162ba25dd91ff1d1dc97ca9dd8fda) | 2026-09-12T01:25:50+03:00 | main; archived |
| ClusterM/wg-obfuscator | [7008e0ce1ea7](https://github.com/ClusterM/wg-obfuscator/commit/7008e0ce1ea71a39ce4b50ec9c10d2ce50e9183f) | 2026-10-09T10:23:20+02:00 | master; не archived |
| Ground-Zerro/Phobos | [9c2901849af2](https://github.com/Ground-Zerro/Phobos/commit/9c2901849af2aeda82d7171369db796ead0bb874) | 2026-08-11T23:57:38+11:00 | main; не archived |
| hoaxisr/awg-manager | [38899601091f](https://github.com/hoaxisr/awg-manager/commit/38899601091f67aaa105165a07cdd98117802046) | 2026-10-09T16:14:37+02:00 | develop; не archived |
| hoaxisr/proxy-turn-vk-android | [1110a75f76e4](https://github.com/hoaxisr/proxy-turn-vk-android/commit/1110a75f76e42c23149b8e24f9182c1ff179e515) | 2026-08-19T14:48:06Z | awg-client; не archived |
| ildarmaga/wdtt | [ef697994bc7a](https://github.com/ildarmaga/wdtt/commit/ef697994bc7ac650b81623484933d930c5cd766b) | 2026-08-12T10:24:42+06:00 | main; не archived |
| kkvoru/wdtt-server-entware | [a61fdcfe206b](https://github.com/kkvoru/wdtt-server-entware/commit/a61fdcfe206b9e00b89005e1c5c86f3e2d71abac) | 2026-06-16T15:33:50+05:00 | main; не archived |
| luminescq/focsq | [9ad3bfb36e7e](https://github.com/luminescq/focsq/commit/9ad3bfb36e7ed5717b3ee2766e53a59ddf2fbad5) | 2026-10-01T04:19:56+03:00 | main; не archived |
| SanityProtocol/swg-panel | [e58d2a96ac88](https://github.com/SanityProtocol/swg-panel/commit/e58d2a96ac88f06cfb349de542ab4c9b8eb6f747) | 2026-09-29T06:16:25+03:00 | main; не archived |
| saymer-alt/amnezia-mihomo-gateway | [bcfa9f43b919](https://github.com/saymer-alt/amnezia-mihomo-gateway/commit/bcfa9f43b919e852086b0fffa281e98403235331) | 2026-10-10T17:13:11+03:00 | main; не archived |
| saymer-alt/entware-go | [2c44dd44d14f](https://github.com/saymer-alt/entware-go/commit/2c44dd44d14ffaa1a0a29f2008507e1b392ae597) | 2026-10-10T17:48:12+03:00 | gh-action-build; не archived |
| saymer-alt/keenetic-auto-setup | [ac959105509c](https://github.com/saymer-alt/keenetic-auto-setup/commit/ac959105509c56a5b4bfb080a64bf825880eb09b) | 2026-10-10T23:21:21+03:00 | main; не archived |
| saymer-alt/keenetic-knowledge-base | [d77be9510740](https://github.com/saymer-alt/keenetic-knowledge-base/commit/d77be9510740a24505aaa359da0f65a79b8ad2aa) | 2026-10-11T11:25:27+03:00 | main; не archived |
| saymer-alt/link-generators | [857da9ef723e](https://github.com/saymer-alt/link-generators/commit/857da9ef723e97b1cfa01fd8ac5607880bfcb826) | 2026-10-11T15:23:50+03:00 | main; не archived |
| saymer-alt/mihomo-auto-build | [f3fef398e023](https://github.com/saymer-alt/mihomo-auto-build/commit/f3fef398e023b2700e315093ac788b21c21342e7) | 2026-10-11T14:04:50+03:00 | main; не archived |
| saymer-alt/vps-gateway-bootstrap | [1e41c29c1f35](https://github.com/saymer-alt/vps-gateway-bootstrap/commit/1e41c29c1f35a9b092472d9b2bfc43fcbfbd0872) | 2026-10-11T01:53:30+03:00 | main; не archived |
| SpaceNeuroX/proxy-turn-vk-android | [a296c57eaba6](https://github.com/SpaceNeuroX/proxy-turn-vk-android/commit/a296c57eaba69bb9479a24f9157856490890e47d) | 2026-09-13T12:18:03+02:00 | master; не archived |


### Расхождения, влияющие на выбор исходников

* Оригинальный `amurcanov/proxy-turn-vk-android` архивирован. Исходники клиента и Linux-сервера находятся под `app/src/main/assets/android-client` и `linux-server`, а не в корне. Кодовый control request здесь также GETCONF:/AUTH:, но наличие общего префикса не доказывает совместимость всех modes. Рецепт kkvoru ожидает корневой `server.go` и клонирует движущуюся ветку: его применение к текущему оригиналу **BLOCKED** до исправления пути/пина. Старые готовые MIPS-релизы этого не опровергают. [R1] [R14] [R2]
* У hoaxisr default branch `awg-client`; release клиента `awgm-client-v1.4.0-3` и сервера `awgm-server-v1.4.0-5` — разные серии. Наши сборки относятся к SHA `1110a75f76e42c23149b8e24f9182c1ff179e515`, не объявлены побитовой реконструкцией релизов. Сервер из этого checkout компилируется; протокольная совместимость с release-сервером требует отдельного теста.
* qWDTT SpaceNeuroX `v1.4.4`: `-notls`, `-turn-tcp`, `-tun-fd-sock` присутствуют здесь; переносить эти флаги на hoaxisr нельзя. `-notls` — отдельный wire-режим с серверной поддержкой, а не универсальный переключатель ускорения WDTT. [Q1] [Q2]
* `ildarmaga/wdtt`: release `v1.5.76` от 7 октября при HEAD от 12 августа; версия артефакта сама по себе не идентифицирует новый код. В дереве есть сервер, panel и SQLite-зависимости; сборка серверного монолита не доказывает необходимость panel на KAS. [R3] [R10]
* CSQTT HEAD `71712b07…` и tag `v2.1.9` → `446293aa2e873ac5323ef6fd2316d9b81d966c11`: локальный `git diff v2.1.9 HEAD` показал только четыре строки README. Runtime-исходники совпадают, опубликованные бинарники побитово не сверялись. Старое описание io_uring противоречит текущему BUILD_NOTES и коду; выбираем исходники. [C3] [R9]
* `focsq` — отдельная реализация core/GUI, не готовая взаимозаменяемая версия CSQTT. HEAD исправляет frame-unaware IP filtering; зафиксировать wire revision и совместимый сервер обязательно. В backend есть PolyForm-пометки, отсутствие общего корневого LICENSE не превращает проект в MIT. [R4]
* Дополнительно обнаружены `ildarmaga/pwdtt-client` (Wails desktop, GPL-пометки, отдельный Go core), `Ivan4537/WDTT-Plus` (активный Go fork), `danusha2345/csqtt-vpn` и `csqtt-android`. Для первых двух просмотрены структура/манифесты, для последних — API/README, **не полноценный аудит wire-кода**. csqtt-vpn описывает собственный bundled core 2.1.15 и credentials-stdin: это кандидат, не доказанная совместимость upstream 2.1.9. `XXcipherX/proxy-turn-vk-android` вернул GitHub 404: доступность **UNVERIFIED**, не делаем вывод о причине.

## 3. Фактическая архитектура своих проектов

### Keenetic Auto-Setup

**CONFIRMED.** KAS уже владеет жизненным циклом одного Mihomo, mixed-port 7890, интерфейсом `mitun0`, контрактом ProxyN `socks5 + socks5-udp + 127.0.0.1:7890` и MagiTrickle как отдельным компонентом. Bootstrap YAML минимален (`mixed-port`); его нельзя трактовать как готовый kill switch. При отсутствии top-level TUN мигратор выбирает stack `mips` для Mihomo ≥1.19.31, иначе `gvisor`; существующий TUN не переписывает. `auto-route:false` сохраняется. Установка MagiTrickle использует свой helper/package, а не встроенную копию. [K4] [K5] [K6]

Обновление/импорт должны сохранять lifecycle lock, same-filesystem commit, предыдущий бинарник/конфиг, один процесс для validate и rollback. Doctor проверяет состояние read-only. Новый transport installer должен использовать согласованный контракт, не запускать второй Mihomo ради `-t`. [K9] [K11] [K12] [K13]

DNS interception включается и проверяется отдельно. `020-bypass-wa.sh` работает в IPv4 mangle PREROUTING на портах 1400/3478/3482: это не host OUTPUT, поэтому нельзя объявить, что локальные TURN-сокеты wdtt автоматически обходят будущую политику. Watchdog проверяет direct WAN/whitelist и proxy; сбой выбранного WDTT может выглядеть как отказ proxy и инициировать перезапуск Mihomo. Нужен отдельный статус внешнего транспорта при сохранении текущего cooldown. [K3] [K7] [K8]

Ресурсный профиль: новые 128 MB installs требуют внешнего Entware и внешнего swap ≥384 MB; внешний `/opt` EXT4-only; класс 256 MB без memory backend даёт WARN; 512 MB требует native zRAM либо проверенный внешний swap; внешний swap >2 GiB отвергается. Это **условия текущего KAS**, не доказательство, что добавление WDTT помещается. S00ubifs защищает внутреннюю flash через tmpfs; нельзя молча увеличивать tmpfs под transport logs. [K1] [K2] [K10]

### Сборки, генератор и VPS

`entware-go` уже использует архитектурное отображение Entware → Go (`mipsel` → `mipsle`), CGO=0 и GOMIPS=softfloat; GitHub Actions разрешает актуальную версию Mihomo. В Makefile ещё исходная 1.19.30, а rolling `latest` содержит 1.19.32-2: версия рецепта и payload должны учитываться отдельно. Это полезный опыт, но новый transport manifest должен фиксировать SHA и компилятор, не скачивать произвольный `latest`. [E1] [E2]

`mihomo-auto-build` выведен из эксплуатации, release-write workflow отключены. Обнаружен фактически связанный путь Mihomo → OpenVPN → GPL-2.0-only go-lzo при GPL-3.0 Mihomo; наличие source archive само по себе не решает несовместимость лицензий. Не возобновлять исторический builder и не наследовать его MIT как лицензию upstream бинарника. Для transport binaries нужна собственная проверка транзитивных зависимостей. [E3] [E4]

`link-generators` использует генерируемый web4core runtime; parser WireGuard `.conf` и builder Mihomo уже дают основу для B/E. Парсер работает в source-repo web4core, его generated bundle вручную не редактировать. Сейчас contract builder — IPv4 WireGuard; IPv6 нельзя обещать по наличию поля в Mihomo. Внешний процесс не запускается браузерным YAML. [G1] [G2] [G3]

`amnezia-mihomo-gateway` — другая VPS/Docker топология. В актуальном installer есть отдельный `AMG_FAILSECURE`, исключение fwmark 0x88 и source-side terminal reject; переносить его table/mark/iptables на NDMS не следует. У `vps-gateway-bootstrap` file experiment сейчас planning-only: legacy OWNED не устанавливал происхождение файла, mutation отключена. Это прямой урок для uninstall/adoption нового модуля. Knowledge base служит каталогом источников, а не подтверждением протокола. [E5] [E6] [E7]

## 4. WDTT: реальные слои и контроль

### WG transport

```text
LAN TCP/UDP → Keenetic policy / ProxyN или mitun0 → Mihomo WireGuard
 → зашифрованный WG UDP → 127.0.0.1:9000 wt-client
 → DTLS session → RTP + WRAP → настоящий VK TURN allocation
 → свой VPS WDTT → WG server → IP forwarding/NAT → Internet
```

**CONFIRMED по коду, live UNVERIFIED.** Клиент получает TURN username/password через VK auth path, делает настоящий Pion TURN Allocate, создаёт relay UDP-путь к `peer`, оборачивает DTLS в RTP/WRAP. Это реальная инфраструктура TURN; не требуется, чтобы WG VPS был разрешён напрямую у провайдера, но доступность auth API, DNS, relay, Allocate/permissions и лимиты VK остаются обязательны. Доступная главная страница VK не проверяет эти условия. [W8] [W9] [W19] [W20]

В классическом пути DTLS использует ECDHE_ECDSA_AES128GCM, MTU 1100, `InsecureSkipVerify:true`; сертификат сервера не закреплён. WRAP выводит ключ HKDF-SHA256 из пароля с фиксированным domain salt `WDTT-WRAP-v1` и применяет ChaCha20-Poly1305 в RTP-оболочке. HKDF здесь не memory-hard password KDF: нужен высокоэнтропийный секрет. Shared PSK подтверждает владение секретом, не независимую публичную идентичность сервера. Полный аудит nonce lifecycle, replay window, downgrade и PFS для всей композиции не проведён. Inner WG даёт свой стандартный защищённый туннель, но WG config выдаёт тот же сервер по этому control path. [W9] [W10] [W11] [W12]

Control: `GETCONF:localPort|deviceID|password`, ответы включают `wrong_password`, `expired`, `device_mismatch`; затем AUTH. Сервер формирует обычный `.conf` с PrivateKey, Address, DNS, MTU, PublicKey, AllowedIPs, Endpoint=127.0.0.1:localPort и PersistentKeepalive. VPS генерирует клиентский private key и потому не является стороной, от которой этот ключ скрыт. Для первого PoC использовать собственный доверенный VPS; key-management улучшение с генерацией на клиенте — отдельное изменение wire/API. [W12] [W15]

### Standalone и режимы

У hoaxisr доступны `-mode vpn|socks|rawtun`, `-listen`, `-peer`, `-vk`, `-password`, `-device-id`, `-vk-auth`, `-vk-creds-file`, `-go-dns`, `-n`, `-obfs audio|video`. Совместимые alias находятся в отдельном файле. При пустом AWGM socket `awgmSetup` оставляет ручной запуск; `-awgm-protocol` лишь печатает JSON описания attach-tun API. Его успешный запуск не доказывает VPN или регистрацию интерфейса. [W2] [W5] [W17]

Безопасный пример формы команды (секреты только синтетические, порт не закреплён как новый стандарт KAS):

```sh
wt-client -mode vpn -listen 127.0.0.1:9000 \
  -peer 192.0.2.10:56000 -vk LAB_CALL_HASH \
  -device-id kas-lab -password LAB_RANDOM_SECRET -n 12
```

Этот пример **не production-рецепт**: текущий CLI оставляет пароль в argv, stdout содержит WG private key. До реального PoC нужен локальный patch: secret-file/fd вместо argv; redaction на месте логирования; atomic output WG config без stdout и structured event при смене config. Для временной изолированной лаборатории возможен защищённый process environment/user namespace, но это не заменяет исправление в распространяемом пакете. [W2] [W4]

SOCKS mode создаёт собственный gVisor/netstack WireGuard и TCP SOCKS listener. `armon/go-socks5` обрабатывает CONNECT, а UDP ASSOCIATE возвращает command-not-supported. Поэтому A годится для TCP, но не для QUIC/UDP DNS/WebRTC UDP; `udp:true` в Mihomo не добавляет удалённую реализацию. TCP fallback конкретного приложения — не полноценная UDP-поддержка. IPv4-only netstack дополнительно ограничивает A. [W7] [S1]

RAW path использует `GETCONF_RAW`, IP/DNS/MTU и RTP/WRAP без inner WG и DTLS; для него нельзя переносить гарантии Noise handshake WG. В standalone `startRawTUN` вызывает `ip link del name` перед созданием: коллизия с чужим TUN приводит к его удалению. Это **BLOCKED для прямой установки C** без изменения владения. AWGM attach-tun fd-path технически позволяет написать маленький свой helper, не запускать manager. [W6] [W13] [W18] [R6]

### VK credentials, reconnect, ресурсы

Анонимный VKCalls path выполняет цепочку VK/OK calls запросов и извлекает turn_server.username/credential/urls. Локальный cache считает credentials пригодными 10min минус60s safety margin; это клиентская политика, не гарантия времени жизни на стороне VK. При expiry/auth failure worker повторяет получение. Account mode не реализует самостоятельный browser login: читает pre-injected/file credentials либо печатает VK_AUTH_REQUIRED и до5min ждёт TURN_CREDS. Для долгой standalone account-сессии нужен ограниченный внешний broker/auth UX либо ручное обновление; один creds-file не доказывает вечный refresh. Android WebView/captcha callbacks без UI могут оказаться NEEDS_AUTH, а не полностью unattended режимом. [W19] [W20] [W21] [W22] [W23]

Анонимный режим hoaxisr имеет минимум 12 workers, округление до кратности 12 и максимум 108; account режим 1–4. `-n 1` не является способом получить один anonymous worker. Default 24 и каждая TURN/DTLS session увеличивают сокеты, buffers и работу GC; линейную зависимость RSS утверждать нельзя. Обновление credentials и повторные workers есть; auth-fatal прекращает попытки, quota/retry имеют внутренние задержки. Это не заменяет outer supervisor с бюджетом restart. [W3] [W16]

Полученная WG config обрабатывается только один раз; upstream печатает все строки и пишет `wg-turn.conf` с 0600. `os.WriteFile(...,0600)` не исправляет права уже существующего файла. STDIN логируется до разбора CAPTCHA_RESULT/TURN_CREDS — возможна утечка токенов. Нужны directory0700, umask077, явный chmod, atomic write, redaction и согласованное обновление Mihomo при ротации ключей/IP. Нельзя просто наблюдать mtime файла и на каждый раз запускать второй daemon. [W2] [W4]

Keepalive TURN/WG, DTLS MTU, RAW MTU и MTU inner WG — разные величины. Потери UDP не исчезают от 12/24 workers; inner TCP повторяет данные, inner UDP теряет их. Round-robin/reordering и предложение смены scheduler в открытом PR не дают права обещать ускорение. Нужны отдельные испытания p95 RTT, loss, reorder и per-flow fairness. [W9] [W15] [I4]

## 5. qWDTT и другие WDTT forks

qWDTT SpaceNeuroX сохраняет происхождение WDTT, но добавляет TCP TURN и direct WRAP/noTLS modes, Android fd socket и другую orchestration. `-turn-tcp` описывает транспорт **к TURN**, не SOCKS UDP ASSOCIATE. `-notls` убирает один слой DTLS при согласованном direct listener сервера; оставшийся WRAP — пользовательская композиция AEAD, не автоматическая эквивалентность WG. Fork-specific feature flags и auth handshake должны быть частью manifest совместимости. По issue #46 есть сообщение об отсутствии reconnect, это сигнал тесту, а не воспроизведённая здесь неисправность. [Q1] [Q2] [I2]

Оригинал amurcanov, hoaxisr, SpaceNeuroX, ildarmaga и WDTT-Plus не образуют доказанную универсальную клиент-серверную матрицу. В собранном root server hoaxisr текущей default branch handler обслуживает GETCONF:/AUTH:, GETCONF_RAW:/RAWCONF: не найден; клиентский rawtun поэтому нельзя считать совместимым с этим server только по успешной компиляции. SpaceNeuroX имеет отдельный RAW handler. Для C нужен отдельно проверенный RAW-capable server pin. Нельзя смешивать latest APK, server binary из другого fork и `wt-client` по одному названию WDTT. Начальная пара должна собираться из согласованных исходников, с golden GETCONF/AUTH/RAW fixtures; test upgrade N→N+1 и rollback N обязательны. [W12] [W13] [W24] [Q2] [Q4]

SWG использует pinned upstream SHA и patch series; это полезный reference для build provenance, но его patch не переносится без license/compatibility review. У ildarmaga server config действительно читает panel.db и задаёт localhost admin API; это серверная связность, не обязательный client panel на Keenetic. [R11] [R13]

## 6. CSQTT: клиент, сервер, wire revision

**CONFIRMED.** Текущий CSQTT — Rust RAW IP транспорт с настоящим VK TURN, RTP/SRTP/WRAP, собственными control/framing/FEC/scheduler. В inspected client нет полноценного WireGuard endpoint и SOCKS5 server; UDP `--listen` принимает RAW IP datagrams, а `--tun-uds` получает TUN fd через Unix socket/SCM_RIGHTS. Подключать к нему WireGuard-outbound Mihomo по аналогии с B нельзя: данные другого уровня. Название QTT не доказывает QUIC, QUIC не найден как используемый слой в манифесте/пути TURN. [C1] [C5] [C6] [C9] [C10] [C11]

Клиент требует Rust 1.97.1, edition2024, Tokio1.53.1, aws-lc-rs1.18.0, libc/nix, primp browser TLS. Сервер добавляет bundled SQLite/snmalloc/tun/axum и собственную сетевую/DB lifecycle; эти зависимости **не переносим на клиента**. Серверный BUILD_NOTES описывает current-thread Tokio/epoll и bounded pools; клиент отдельно создаёт multi-thread Tokio runtime, применяет AsyncFd и recvmmsg/sendmmsg. Ни client, ни актуальный server runtime нельзя отвергать лишь по старому io_uring требованию. Но это не доказывает поддержку любого ядра 3.x: нужны syscall, futex, entropy, TLS и TUN-fd runtime probes на конкретной прошивке. [C1] [C2] [C3] [C4] [C14] [C15] [R9]

Аудио/видео режимы используют SRTP-подобные AES-CTR/HMAC-SHA1 и ChaCha20-Poly1305 paths; salt `CSQTT-WRAP-v1` отличается от WDTT. `GETCONF` включает generation/salt/worker/count и `CSQTT-WIRE-3`; общий module описывает revision3/legacy2. Один пароль не делает WDTT и CSQTT wire-совместимыми. Серверная user/device/generation проверка не заменяет независимый аудит crypto/replay/identity. RAW снимает inner WG, поэтому это также отдельный security gate. [C7] [C8] [C16] [C9] [C10]

`--workers` и `-n` имеют отдельные значения: sessions до126, runtime threads1–4. Нельзя сопоставлять их напрямую с WDTT `-n`. TURN UDP/TCP/TLS — разные пути: TCP/TLS могут пройти иной фильтр, но добавляют head-of-line blocking; численной оценки без тестов нет. Credentials refresh реализован в TURN core; VK API/captcha всё равно external failure domain. [C4] [C11]

Сообщение issue #33 об ARM64 сервере на KN-3811, 1–3% и 20–30 ms — **заявление пользователя**, не наш benchmark и не доказательство клиента KN-1012. SQLite/FORWARD/NAT из ответа относятся к серверной установке. Файл `focsq` backend и SWG patches показывают, почему необходимо фиксировать именно client/server wire tree; desktop frontend KAS не нужен. [I1] [R4] [R9]

Актуальные issue #41/#42 сообщают об обрывах через7–60+s; гипотеза пользователя о распознавании VK не подтверждена здесь. Issue #40 описывает frame-unaware IP filter regression, а focsq HEAD отдельно исправляет этот класс. Ни закрытый PR, ни сходная версия не гарантируют наличие нужного исправления в выбранном checkout: учитывать exact tree и тест flow-frame→IP→TUN. Эти сообщения обосновывают failure/soak gate, а не доказанный диагноз операторского DPI. [I5] [I6] [I7]

**Подтверждённый compile blocker:** vanilla ARM64/musl build с pinned Cargo.lock доходит до client crate и падает в udp_batch.rs553/577 (`flags`: i32 вместо musl u32) и643 (private padding fields libc::msghdr). AWS-LC и compression dependencies скомпилировались; это конкретная ABI-ошибка клиента, не io_uring, нехватка CMake или доказанная неподдержка ARM64 crypto. Лабораторная probe копия и минимальный patch рассматриваются отдельно в тестовом плане. Upstream/KAS code не исправлялся. [C14] [C19]

**Вывод по порту:** для ARM64 подтверждён небольшой compile port (два flags cast и zero-init C header), без замены native crypto; не требуется заранее закладывать полную перепись клиента. TUN helper, firmware syscall/IO и crypto/лицензионные gates всё ещё нужны. MIPS BLOCKED для готового рецепта: требуется Rust tier/stdlib, softfloat target, aws-lc/native crypto support и старое ядро. Это препятствие текущей подтверждённости, не доказанная принципиальная невозможность. Лицензионный допуск к общему публичному KAS channel остаётся отдельным. [C1] [D2] [C13]

## 7. WG-obfuscator: что он добавляет

```text
Mihomo WG / native Keenetic WG → 127.0.0.1:13255 C obfuscator
 → прямой IPv4 UDP, XOR/CRC обфускация + STUN-like Data Indication
 → C obfuscator VPS → localhost:WG-port → WG peer → Internet
```

Код — C, libc/pthread, vendored uthash/mini_argp, epoll на Linux. Шесть C units собираются без Go/Rust/gVisor. XOR с CRC-derived stream не является шифрованием/аутентификацией; безопасность полезной нагрузки должна оставаться у WireGuard. STUN wrapper добавляет 24 bytes, плюс собственная обфускация/dummy и WG/UDP/IP overhead. `masking=STUN/AUTO/NONE`, `allow-clean` отдельный opt-in; для испытания не включать permissive clean fallback. [O1] [O3] [O4] [O5] [O6] [O9]

В коде нет VK credential exchange/TURN Allocate. Провайдер видит прямой VPS IP/UDP, даже если пакет похож на STUN. VK при таком маршруте не участвует. Внешние sockets AF_INET — IPv4; inner WG IPv6 возможен лишь при поддержке обеих сторон/маршрутов, а генератор KAS сейчас сохраняет IPv4 contract. Issue IPv6 — отдельный сигнал, не замена чтению AF_INET. [O5] [O6] [I3] [G2]

Вопрос issue #48 о маскировке через VK также не является реализацией VK TURN в ClusterM. Доказательство — отсутствие credential/Allocate path и наличие локального STUN-like packet wrapper, не название issue. [I8] [O5]

Default source-if=0.0.0.0, поэтому клиент обязан явно слушать loopback. Max clients1024 и buffers не равны нулевой памяти; на клиенте ограничить число по измерениям. Текущий HEAD поддерживает периодический resolve/SIGHUP — старые DDNS complaints не доказывают отсутствие этой функции сейчас. `fwmark`/interface bind требуют отдельного fail-closed контроля: лог-предупреждение не гарантирует применение политики. [O6] [O9]

Native WG Keenetic технически обоснован шаблоном Phobos с loopback endpoint/ndmc; но Phobos — AGPL panel + отдельный fork obfuscator/s6. В его C config есть дополнительные mode=wireguard/socks5 и masking=MEDIA/TLS, отсутствующие в выбранном ClusterM CLI; результаты и ограничения ClusterM нельзя механически переносить на fork. Его установщик не нужен для E, wire-совместимость fork не предполагается. `make install` ClusterM вызывает systemctl и не подходит Entware: брать только staging binary и писать свой POSIX init после допуска. [R5] [R12] [O2]

## 8. Кто видит данные

| Сторона | WDTT/CSQTT через VK TURN | WG-obfuscator напрямую |
|---|---|---|
| Оператор клиента | IP relay/VK auth/DNS, время, объём, паттерны; содержимое защищено выбранными слоями | VPS IP/порт, время/объём, STUN-like паттерн; WG ciphertext |
| VK/relay | IP клиента, аккаунт/call/credentials, peer VPS, allocations, время/объём; inner payload ciphertext при корректной crypto | Не участвует, если нет другого VK обращения |
| Владелец своего VPS | Auth/device metadata и расшифрованный IP-egress; TLS приложения остаётся end-to-end; WDTT выдаёт WG private key | WG endpoint и расшифрованный IP-egress на WG server |
| Сайт назначения | Egress VPS, application identifiers/cookies; туннель не скрывает browser fingerprint | То же |

Это **вывод из топологии и слоёв**, не пакетный capture и не обещание неразличимости. RTP/DTLS/WebRTC-похожесть не гарантирует обход DPI, корреляции либо active probing. Нет независимого crypto audit этих custom WRAP paths. [W8] [W9] [W10] [W15] [C7] [C11] [O3]

## 9. Сопоставление с действующей инфраструктурой

| Технология | Новая возможность кандидата | Что уже покрыто / предел |
|---|---|---|
| VLESS/Reality | WDTT/CSQTT меняют доступный сетевой путь на VK relay | Не замена зрелому прямому egress, key/auth/security модель другая |
| WG / AWG2/3.1 | WG-obfs оборачивает стандартный WG без смены keys/outbound | Не доказано превосходство над AWG; Mihomo уже содержит AWG3 fields |
| Mihomo TUN / ProxyN | B/E повторно используют текущую data plane | RAW потребует отдельного владельца OpkgTun и NDMS policy |
| WARP/MASQUE | VK relay — иной endpoint/operator failure domain | Нет универсальной взаимозаменяемости WARP egress и своего VPS; UDP filtering проверять |
| MagiTrickle / fallback | Возможность явно выбрать новый optional outbound | DNS interception и policy не должны зависеть от наличия panel |

Назначение WDTT — дополнительный путь при конкретных блокировках, а не автоматическое ускорение VPN. WG-obfs — меньший PoC с умеренной новой функцией. CSQTT RAW потенциально убирает WG/DTLS overhead, но выигрыш и security equivalence **UNVERIFIED**. Сравнивать на одной линии, VPS, ядре, MTU и нагрузке. [M1] [K4] [K5] [C5]

## 10. Эксплуатационные риски и решение

Разделение findings: private-key/stdin echo — подтверждённые HIGH риски раскрытия в дополнительных log sinks; standalone RAW interface-delete — подтверждённый HIGH риск удаления чужого интерфейса при коллизии; musl ABI — подтверждённый MEDIUM build blocker. Уверенность высокая по указанным code/build paths, но реальные incident/exploit на роутере не воспроизводились. SOCKS UDP unsupported — ограничение режима, не новая ошибка upstream; доступность VK/DPI/RSS — непроверенные production свойства. Минимальные изменения и regression cases указаны в строках ниже и тестовом плане.

| Риск / доказательство | Конкретная защита будущего модуля | Статус |
|---|---|---|
| UDP56000 уже занят vk-turn-proxy/free-turn-proxy; описанный владельцем million-restart случай | Scan TCP/UDP+exe identity; общий instance lock; bind failure=configuration error, stop без autoretry; не останавливать конкурента | Случай из задания, journal не получен; защита проектная |
| SO_REUSEADDR wt-client ослабляет простую port preflight гарантию | Удалить reuse в локальном UDP path либо обеспечить exclusive ownership lease; race-test между bind и start | CONFIRMED code [W14] |
| Restart loop / log flash wear | Бюджет5 attempts/15min, backoff5/15/30/60/120s, circuit-open; logs tmpfs256KiB×2, rate-limit; auth/captcha/port не перезапускать | LIKELY дизайн |
| WG private key/STDIN tokens/argv password | Patch logging и secret-file/fd,0700 dirs/0600 files, redacted Doctor/support bundle, no TRACE | CONFIRMED [W2] [W4] |
| RAW удаляет чужой TUN | Запрет legacy ip-link-del path; NDMS ownership record+fd attach helper; foreign/unknown→abort | CONFIRMED [W6] |
| Substituted binary / disappeared release | Pinned source/toolchain, signed manifest, hash check, local last-known-good/source archives, verify before stop | LIKELY дизайн |
| Client/server wire drift / key rotation | Co-pinned compatibility record, stage/validate/probe/commit/rollback обоих endpoints; no silent downgrade | CONFIRMED drift surface [C9] [Q2] |
| VK outage / captcha / rate limits | Distinct NEEDS_AUTH/QUOTA state, no credentials in browser, bounded refresh, explicit alternate configured policy | CONFIRMED auth paths [W2] [W16] |
| Routing loop / direct leak / SSH loss | Loopback endpoint via lo, WAN outer-socket exclusions, scoped policy guard, LAN admin exception, packet acceptance inclIPv6 before rollout | UNVERIFIED live |
| Firewall/NAT/uninstall чужих объектов | Own chain/mark/table registry and exact match manifest; no flush/killall/systemctl wildcard; foreign content refusal | Design based on [E6] [R8] |
| PolyForm / copyleft / bundled deps | Per-component license+NOTICE+corresponding source; independent process boundary; licensing gate before publication | [C13] [E4] |

Подробные A–E схемы, транзакции, KAS неизменяемые контракты и изменение генератора вынесены в [архитектуру интеграции](KAS-TRANSPORT-INTEGRATION.md). Числа сборок, SHA256, условия runtime-проб и неисследованные свойства — в [тестовом плане](TRANSPORT-TEST-PLAN.md). Лицензии и платформы — в [матрице](TRANSPORT-COMPATIBILITY-MATRIX.md).

## Первичные источники

[C1]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-client/Cargo.toml#L1-L67
[C10]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/shared/wire_protocol.rs#L1-L6
[C11]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-client/turn_core.rs#L330-L355
[C13]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/LICENSE#L1-L84
[C14]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-client/udp_batch.rs#L525-L580
[C15]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-client/dispatcher.rs#L625-L655
[C16]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-client/obfs.rs#L175-L275
[C19]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-client/udp_batch.rs#L641-L654
[C2]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-server/Cargo.toml#L1-L66
[C3]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-server/BUILD_NOTES.md#L1-L14
[C4]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-client/main.rs#L78-L165
[C5]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-client/dispatcher.rs#L445-L480
[C6]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-client/tun.rs#L1-L110
[C7]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-client/wrap.rs#L1-L65
[C8]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-client/obfs.rs#L1-L55
[C9]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-client/protocol.rs#L1-L65
[D2]: https://doc.rust-lang.org/rustc/platform-support.html
[E1]: https://github.com/saymer-alt/entware-go/blob/2c44dd44d14ffaa1a0a29f2008507e1b392ae597/go_env.mk#L1-L85
[E2]: https://github.com/saymer-alt/entware-go/blob/2c44dd44d14ffaa1a0a29f2008507e1b392ae597/.github/workflows/build-mihomo.yml#L97-L129
[E3]: https://github.com/saymer-alt/mihomo-auto-build/blob/f3fef398e023b2700e315093ac788b21c21342e7/README.md#L1-L35
[E4]: https://github.com/saymer-alt/mihomo-auto-build/blob/f3fef398e023b2700e315093ac788b21c21342e7/docs/GPL-SOURCE-AUDIT-2026-10-11.md#L36-L72
[E5]: https://github.com/saymer-alt/amnezia-mihomo-gateway/blob/bcfa9f43b919e852086b0fffa281e98403235331/install.sh#L589-L610
[E6]: https://github.com/saymer-alt/vps-gateway-bootstrap/blob/1e41c29c1f35a9b092472d9b2bfc43fcbfbd0872/tools/fileexperiment/main.go#L1-L21
[E7]: https://github.com/saymer-alt/keenetic-knowledge-base/blob/d77be9510740a24505aaa359da0f65a79b8ad2aa/catalog/techno-bypass/topics/vpn-protocols.md#L75-L95
[G1]: https://github.com/saymer-alt/web4core/blob/fea3cede102ca69137975b31a20317a4c42e052b/src/core/wireguard.js#L3-L300
[G2]: https://github.com/saymer-alt/web4core/blob/fea3cede102ca69137975b31a20317a4c42e052b/src/core/mihomo.js#L688-L745
[G3]: https://github.com/saymer-alt/link-generators/blob/857da9ef723e97b1cfa01fd8ac5607880bfcb826/AGENTS.md#L1-L65
[I1]: https://github.com/amurcanov/csqtt/issues/33
[I2]: https://github.com/SpaceNeuroX/proxy-turn-vk-android/issues/46
[I3]: https://github.com/ClusterM/wg-obfuscator/issues/54
[I4]: https://github.com/hoaxisr/proxy-turn-vk-android/pull/1
[I5]: https://github.com/amurcanov/csqtt/issues/42
[I6]: https://github.com/amurcanov/csqtt/issues/41
[I7]: https://github.com/amurcanov/csqtt/issues/40
[I8]: https://github.com/ClusterM/wg-obfuscator/issues/48
[K1]: https://github.com/saymer-alt/keenetic-auto-setup/blob/ac959105509c56a5b4bfb080a64bf825880eb09b/install.sh#L375-L407
[K10]: https://github.com/saymer-alt/keenetic-auto-setup/blob/ac959105509c56a5b4bfb080a64bf825880eb09b/S00ubifs#L1-L100
[K11]: https://github.com/saymer-alt/keenetic-auto-setup/blob/ac959105509c56a5b4bfb080a64bf825880eb09b/config-import.sh#L1-L85
[K12]: https://github.com/saymer-alt/keenetic-auto-setup/blob/ac959105509c56a5b4bfb080a64bf825880eb09b/update-mihomo.sh#L1-L95
[K13]: https://github.com/saymer-alt/keenetic-auto-setup/blob/ac959105509c56a5b4bfb080a64bf825880eb09b/mihomo-doctor.sh#L1-L85
[K2]: https://github.com/saymer-alt/keenetic-auto-setup/blob/ac959105509c56a5b4bfb080a64bf825880eb09b/install.sh#L601-L700
[K3]: https://github.com/saymer-alt/keenetic-auto-setup/blob/ac959105509c56a5b4bfb080a64bf825880eb09b/install.sh#L1124-L1140
[K4]: https://github.com/saymer-alt/keenetic-auto-setup/blob/ac959105509c56a5b4bfb080a64bf825880eb09b/install.sh#L1450-L1588
[K5]: https://github.com/saymer-alt/keenetic-auto-setup/blob/ac959105509c56a5b4bfb080a64bf825880eb09b/install.sh#L1793-L1823
[K6]: https://github.com/saymer-alt/keenetic-auto-setup/blob/ac959105509c56a5b4bfb080a64bf825880eb09b/migrate-mihomo-tun.sh#L405-L415
[K7]: https://github.com/saymer-alt/keenetic-auto-setup/blob/ac959105509c56a5b4bfb080a64bf825880eb09b/mihomo-watchdog.sh#L531-L634
[K8]: https://github.com/saymer-alt/keenetic-auto-setup/blob/ac959105509c56a5b4bfb080a64bf825880eb09b/020-bypass-wa.sh#L12-L43
[K9]: https://github.com/saymer-alt/keenetic-auto-setup/blob/ac959105509c56a5b4bfb080a64bf825880eb09b/AGENTS.md#L40-L76
[M1]: https://github.com/MetaCubeX/mihomo/blob/88dcbf7f1614a67c3b36b848ee3592dfa92ada36/adapter/outbound/wireguard.go#L69-L145
[O1]: https://github.com/ClusterM/wg-obfuscator/blob/7008e0ce1ea71a39ce4b50ec9c10d2ce50e9183f/Makefile#L1-L65
[O2]: https://github.com/ClusterM/wg-obfuscator/blob/7008e0ce1ea71a39ce4b50ec9c10d2ce50e9183f/Makefile#L100-L124
[O3]: https://github.com/ClusterM/wg-obfuscator/blob/7008e0ce1ea71a39ce4b50ec9c10d2ce50e9183f/obfuscation.c#L90-L130
[O4]: https://github.com/ClusterM/wg-obfuscator/blob/7008e0ce1ea71a39ce4b50ec9c10d2ce50e9183f/masking_stun.c#L1-L30
[O5]: https://github.com/ClusterM/wg-obfuscator/blob/7008e0ce1ea71a39ce4b50ec9c10d2ce50e9183f/masking_stun.c#L120-L155
[O6]: https://github.com/ClusterM/wg-obfuscator/blob/7008e0ce1ea71a39ce4b50ec9c10d2ce50e9183f/config.c#L14-L88
[O9]: https://github.com/ClusterM/wg-obfuscator/blob/7008e0ce1ea71a39ce4b50ec9c10d2ce50e9183f/wg-obfuscator.h#L27-L40
[Q1]: https://github.com/SpaceNeuroX/proxy-turn-vk-android/blob/a296c57eaba69bb9479a24f9157856490890e47d/go_client/main.go#L160-L190
[Q2]: https://github.com/SpaceNeuroX/proxy-turn-vk-android/blob/a296c57eaba69bb9479a24f9157856490890e47d/go_client/session.go#L275-L325
[Q4]: https://github.com/SpaceNeuroX/proxy-turn-vk-android/blob/a296c57eaba69bb9479a24f9157856490890e47d/server/raw.go#L309-L342
[R1]: https://github.com/amurcanov/proxy-turn-vk-android/blob/f4f83bd5d22162ba25dd91ff1d1dc97ca9dd8fda/app/src/main/assets/android-client/go.mod#L1-L25
[R10]: https://github.com/ildarmaga/wdtt/blob/ef697994bc7ac650b81623484933d930c5cd766b/server/go.mod#L1-L29
[R11]: https://github.com/SanityProtocol/swg-panel/blob/e58d2a96ac88f06cfb349de542ab4c9b8eb6f747/forks/wdtt/build.sh#L1-L37
[R12]: https://github.com/Ground-Zerro/Phobos/blob/9c2901849af2aeda82d7171369db796ead0bb874/src/phobos-obfuscator/config.c#L45-L85
[R13]: https://github.com/ildarmaga/wdtt/blob/ef697994bc7ac650b81623484933d930c5cd766b/server/config.go#L41-L106
[R14]: https://github.com/amurcanov/proxy-turn-vk-android/blob/f4f83bd5d22162ba25dd91ff1d1dc97ca9dd8fda/app/src/main/assets/android-client/protocol.go#L1-L46
[R2]: https://github.com/kkvoru/wdtt-server-entware/blob/a61fdcfe206b9e00b89005e1c5c86f3e2d71abac/build_server.bat#L15-L40
[R3]: https://github.com/ildarmaga/wdtt/blob/ef697994bc7ac650b81623484933d930c5cd766b/go.mod#L1-L36
[R4]: https://github.com/luminescq/focsq/blob/9ad3bfb36e7ed5717b3ee2766e53a59ddf2fbad5/backend/Cargo.toml#L1-L65
[R5]: https://github.com/Ground-Zerro/Phobos/blob/9c2901849af2aeda82d7171369db796ead0bb874/src/server/phobos/templates/router-configure-wireguard.sh#L25-L70
[R6]: https://github.com/hoaxisr/awg-manager/blob/38899601091f67aaa105165a07cdd98117802046/awgmproto/fd_linux.go#L1-L100
[R8]: https://github.com/hoaxisr/awg-manager/blob/38899601091f67aaa105165a07cdd98117802046/internal/proxyrt/roles/netres/wdtt.go#L11-L60
[R9]: https://github.com/SanityProtocol/swg-panel/blob/e58d2a96ac88f06cfb349de542ab4c9b8eb6f747/forks/csqtt/README.md#L182-L200
[S1]: https://github.com/armon/go-socks5/blob/e75332964ef5/request.go#L235-L250
[W1]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/go.mod#L1-L41
[W10]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/wrap.go#L1-L33
[W11]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/obfs.go#L1-L115
[W12]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/protocol.go#L1-L57
[W13]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/protocol_raw.go#L1-L60
[W14]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/listen.go#L1-L24
[W15]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/server.go#L1719-L1735
[W16]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/group.go#L160-L245
[W17]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/flags_compat.go#L1-L32
[W18]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/raw_session.go#L1-L95
[W19]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/creds_vkcalls.go#L130-L160
[W2]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/main.go#L138-L190
[W20]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/creds_vkcalls.go#L270-L299
[W21]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/creds.go#L112-L122
[W22]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/creds.go#L231-L267
[W23]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/vk_account.go#L188-L213
[W24]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/server.go#L2040-L2145
[W3]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/main.go#L240-L265
[W4]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/main.go#L380-L425
[W5]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/awgm_control.go#L150-L175
[W6]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/raw_tun.go#L247-L283
[W7]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/socks5.go#L20-L126
[W8]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/session.go#L130-L155
[W9]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/session.go#L200-L290


> Уточнения Phase 2 от 2026-10-11: сборки только entware-go/gh-action-build; предпочтительный свободный стенд KN-4210 после подключения и read-only preflight. ABI, ядро и RAM не предполагаются. KN-1010 испытывается отдельно от рабочей сети. Домашний Keenetic — production, эксперименты запрещены. Политика и матрица: [Phase 2](PHASE2-HARDWARE-AND-GATES.md). Результаты QEMU остаются лабораторными.
