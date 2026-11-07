# Матрица транспортов, платформ и лицензий

[Индекс](README.md) · [Основной отчёт](WDTT-CSQTT-WG-OBFUSCATOR-2026.md) · [Матрица](TRANSPORT-COMPATIBILITY-MATRIX.md) · [Сборки](TRANSPORT-BUILD-PLAN.md) · [Интеграция](KAS-TRANSPORT-INTEGRATION.md) · [Тесты](TRANSPORT-TEST-PLAN.md)

Снимок 2026-10-11. **CONFIRMED build ≠ CONFIRMED router support**. Полная ревизия каждого компонента и локальные результаты — [evidence JSON](TRANSPORT-RESEARCH-EVIDENCE.json). Текущая модель не обещает пропускную способность или RSS.

## 1. Протокол и режим

| Компонент / режим | Что принимает клиент | Wire к relay / VPS | UDP приложений | Панель обязательна | Статус и предел |
|---|---|---|---|---|---|
| hoaxisr wt-client vpn | WG UDP, loopback endpoint | VK TURN + RTP/WRAP + DTLS, далее WG | Да, через inner WG; live не проверено | Нет; awgmproto compile dependency | CONFIRMED код [W5] [W9] [W15] |
| hoaxisr wt-client socks | SOCKS5 TCP CONNECT | Тот же transport + свой WG netstack | **Нет UDP ASSOCIATE** | Нет | CONFIRMED ограничение [W7] [S1] |
| hoaxisr rawtun | RAW IP / TUN fd | VK TURN + RTP/WRAP, без WG/DTLS | IP UDP возможен, acceptance нет | Нет; нужен свой helper | BLOCKED legacy TUN-delete [W6] [W18] |
| SpaceNeuroX qWDTT | WG/RAW fork-specific | TURN UDP/TCP; direct WRAP по -notls | WG/RAW могут нести IP UDP | Нет Android GUI requirement для Go core | LIKELY standalone, этот fork не собран [Q1] [Q2] |
| CSQTT client2.1.9 | RAW IP UDP или --tun-uds fd | Реальный TURN UDP/TCP/TLS + custom framing/obfs | IP UDP, без SOCKS/WG endpoint | Нет panel requirement; нужен TUN owner | CONFIRMED код; Keenetic UNVERIFIED [C4] [C5] [C6] |
| focsq backend | Отдельный Rust core / desktop integration | CSQTT-derived wire, fork pairing | Требует pair-test | GUI не нужен как требование KAS | UNVERIFIED совместимость [R4] |
| ClusterM wg-obfuscator | WG UDP | **Прямой IPv4 UDP**, XOR/CRC + STUN-like | Да, inner WG | Нет | CONFIRMED build; DPI UNVERIFIED [O3] [O5] |
| Phobos | Native WG + собственный obfuscator fork | Не считать автоматически ClusterM-compatible | По WG | Panel не нужен для выбранного ClusterM PoC | Архитектурный reference [R5] |

TCP CONNECT, TCP TURN и TCP внутри IP-туннеля — три разных свойства. QUIC приложений требует прохода UDP end-to-end; название CSQTT не означает QUIC transport. DNS может идти по TCP, UDP, DoH/DoT; поддержка одного пути не доказывает все остальные. [S1] [Q1] [C1]

## 2. Подтверждение компиляции по архитектуре

| Компонент | AMD64 Linux | AArch64 Linux | MIPSel32 softfloat | MIPS32 BE softfloat | ARMv7 / другие |
|---|---|---|---|---|---|
| wt-client hoaxisr1110a75f | CONFIRMED;16,740,476 B | CONFIRMED;15,597,692 B | CONFIRMED;18,022,555 B | CONFIRMED;18,022,555 B | LIKELY Go; не собирали |
| WDTT server тот же checkout | CONFIRMED;9,252,988 B, отдельный go.mod | UNVERIFIED | UNVERIFIED | UNVERIFIED | Не приоритет |
| wg-obfs7008e0ce | CONFIRMED static glibc;1,215,968 B; NSS caveat | CONFIRMED static musl;133,080 B | CONFIRMED static musl;187,308 B | CONFIRMED static musl;187,180 B | Upstream recipe есть, здесь не собран [O10] |
| qWDTT Go core | LIKELY | LIKELY, APK не ELF proof | LIKELY при CGO0 | LIKELY при CGO0 | APK ABI не подтверждает Entware ABI [Q3] |
| CSQTT client | CONFIRMED GNU/glibc;10,366,208 B | Vanilla BLOCKED; с lab ABI patch CONFIRMED static musl;8,592,288 B | BLOCKED готовый рецепт: std + crypto native target | BLOCKED то же | Серверный armv7 hardfloat recipe не доказывает клиент [C12] [C14] [C19] |
| CSQTT server | Upstream recipe AMD64musl; наша сборка не выполнялась | Upstream recipe есть; reported KN-3811 | Нет подтверждённого рецепта | Нет подтверждённого рецепта | Upstream armv7musleabihf [C12] [I1] |
| ildarmaga wdtt / pwdtt-client | Исходники доступны, здесь не собраны | UNVERIFIED headless core | UNVERIFIED | UNVERIFIED | Desktop Wails не ставить на router |

Размеры измерены на лабораторных ELF; это **дисковый размер**, не RAM и не рекомендуемый free-space минимум. Для обновления нужны old+new+rollback+download overhead. Времена компиляции не являются benchmark транспорта.

Уточнение CSQTT ARM64: **BLOCKED vanilla ARM64/musl**: udp_batch.rs553/577 flags i32→u32 mismatch и643 private msghdr padding; патч-проба отдельно в evidence. **CONFIRMED lab-only patched build**: static ARM64 musl ELF, QEMU parser startup; реальный TUN/VK/Keenetic UNVERIFIED.

## 3. ABI и ядро

| Путь | Userspace / toolchain | Требования ядра | Что ещё проверить |
|---|---|---|---|
| wt-client B | Go1.27.0, module go1.26, CGO0; без glibc/musl loader | Go Linux runtime (официально ≥3.2 для Go≥1.24), futex/epoll, UDP sockets | Конкретный uname/NDMS, entropy, mips32r1, softfloat, DNS, clock, socket opts [W1] [D1] |
| wt-client A | То же + userspace WG/gVisor | Не нужен kernel WG для SOCKS netstack | RSS с Mihomo, нет SOCKS UDP [W7] |
| wt-client C | То же + TUN/ioctl + NDMS helper | /dev/net/tun, IFF_TUN/IFF_NO_PI, fd passing | Mapping OpkgTunN↔opkgtunN, ownership/adoption, no delete [W6] [R6] [R7] |
| wg-obfs E | C libc/pthread; ARM/MIPS static musl, no CGO | epoll/socket IPv4; SO_BINDTODEVICE/SO_MARK при выборе | Не всем socket failure соответствуют fatal errors; controlled routes needed [O1] [O6] |
| CSQTT D client | Rust1.97.1, libc/nix, AWS-LC C/asm, primp native deps | Tokio epoll/futex, recvmmsg/sendmmsg, entropy, Unix SCM_RIGHTS, TUN from helper | `ENOSYS`, EINVAL, EAGAIN, EINTR, 32-bit time64; ABI test exact firmware [C1] [C6] [C14] |
| CSQTT server | Отдельный crate, SQLite/snmalloc/TUN/network setup | Не выводить из него client минимум | Не устанавливать server на роутер по ошибке [C2] [C3] |

Entware feed `aarch64-3.10`/`mipsel-3.4` — имя ABI/feed, **не измеренное uname**. KN-1012 и KN-1010 — целевые модели из задания; actual CPU, RAM, storage, NDMS/kernel фиксируются перед натурным тестом. MIPS BE — отдельная платформа, не автоматически вариант KN-1010. QEMU user smoke подтверждает ELF startup, не firmware runtime; Go отдельно предупреждает о неполноте QEMU support. [E1] [D1]

Для Rust MIPS нет достаточного `rustup target add` + success promise: tier3/stdlib и C crypto support должны быть проверены для конкретного target/compiler. Возможные пути — custom std build, иной допустимый crypto backend, downstream patch; каждый меняет объём и security review. На этом этапе не заявлена принципиальная невозможность MIPS. [D2] [C1]

## 4. RAM/storage: решение о допуске, не выдуманные измерения

| Профиль | wg-obfs + существующий Mihomo | WDTT B + Mihomo | WDTT A | CSQTT / RAW |
|---|---|---|---|---|
| 128 MB | Только отдельный lab после всех KAS prerequisites; лёгкий ELF не гарантирует RSS | Отложить default admission; минимум12 anonymous workers, Go+Mihomo | Отложить: второй WG/netstack, TCP-only | Отложить до resource/port gates |
| 256 MB | Приоритетный optional PoC с измерением memory pressure | PoC после ARM64/512 reference; n12 anonymous против n24 | Только TCP control case | ARM64 research, не default |
| 512 MB и выше | Первый функциональный reference | Первый reference B;128/256 не наследуют pass | Сравнительный TCP-only тест | ARM64 отдельная ветка исследования |

Все ячейки **UNVERIFIED по реальному RSS/CPU**. Ограничения KAS128/256/512, внешнего EXT4 и swap сохраняются; увеличение swap не лечит перегрузку CPU/GC либо потерю UDP. zRAM потребляет CPU, swap на flash создаёт write amplification. Измерять MemAvailable, RSS/PSS если доступно, vmstat, major faults, OOM, FD/sockets, CPU throttling, drops, flash writes и рост логов. [K1] [K2] [K10] [W3]

Предлагаемые acceptance budgets и 24h soak — в [тестовом плане](TRANSPORT-TEST-PLAN.md). Бинарники постоянно хранятся в `/opt`; runtime/logs на ограниченном volatile storage; secret config persist0600. S00ubifs mount sizes не менять без отдельного измерения. После reboot порядок Entware→Mihomo→transport→route activation проверяется, старт сети не равен valid TURN/auth.

## 5. Лицензионная матрица публикации

Это технический анализ текстов лицензий и состава, не разрешение правообладателя. Публичный GitHub не снимает ограничений. Существование чужих Releases не доказывает их соблюдение.

| Компонент | Проверенный текст | Публичные standalone binaries | Gate для KAS |
|---|---|---|---|
| amurcanov/hoaxisr/SpaceNeuroX WDTT | GPLv3; у отдельных ildarmaga/pwdtt есть GPLv3-or-later preamble | Допустимо при соблюдении применимой GPL, notices, exact corresponding source/build scripts/patches | Dependency inventory, точный SPDX-or-later по файлам, immutable source access [L1] [L6] |
| ClusterM wg-obfuscator | GPLv3 | То же + vendored uthash/mini_argp и libc/toolchain notices | Не копировать C в MIT shell; распространять отдельным компонентом [L2] |
| Phobos panel | AGPLv3; обфускатор отдельного происхождения | AGPL требует также source offer для modified network interaction | Panel не включать; при reuse внимательно scope/copyleft [L3] |
| AWG Manager | MIT manager / awgmproto; WDTT deps GPL отдельно | MIT не перелицензирует вызываемый GPL бинарник | Библиотечная зависимость допустима после full inventory; daemon не нужен [L4] [W1] |
| SWG Panel | MIT panel, forks сохраняют свои лицензии | MIT не покрывает GPL/PolyForm transport code | Только reference, не runtime dependency [L5] [R9] |
| CSQTT | PolyForm Noncommercial1.0.0 + Required Notice | Лицензия разрешает distribution для разрешённых целей с сохранением terms/notices; это **не GPL/MIT и не unrestricted commercial use** | BLOCKED общий production/public channel до подтверждённого permitted-use policy либо отдельной коммерческой лицензии; private noncommercial research остаётся в scope [C13] |
| focsq | backend PolyForm headers/Cargo, общий root license не найден | Нельзя объявить весь GUI/core свободно распространяемым без scoped provenance | BLOCKED binary channel до проверки всех частей [R4] |
| Retired mihomo-auto-build | MIT recipe, GPL3 Mihomo + linked GPL2-only dependency issue | Новый source bundle не устраняет incompatibility автоматически | Не реанимировать; транспорты проверять отдельно [E3] [E4] |

Отдельный процесс/CLI позволяет не включать transport code в исходники MIT KAS; это архитектурная граница, не универсальное юридическое освобождение. В каждом release хранить полный manifest лицензий прямых/транзитивных deps и vendored native libraries, exact source archives, patch series, recipe, hashes, compiler versions. Link-only на исчезающий upstream недостаточен для надёжной source availability. Компоненты с неизвестной лицензией не считать public domain. [E4] [C13]

## Первичные источники

[C1]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-client/Cargo.toml#L1-L67
[C12]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-server/build_linux.sh#L1-L85
[C13]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/LICENSE#L1-L84
[C14]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-client/udp_batch.rs#L525-L580
[C19]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-client/udp_batch.rs#L641-L654
[C2]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-server/Cargo.toml#L1-L66
[C3]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-server/BUILD_NOTES.md#L1-L14
[C4]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-client/main.rs#L78-L165
[C5]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-client/dispatcher.rs#L445-L480
[C6]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-client/tun.rs#L1-L110
[D1]: https://go.dev/wiki/MinimumRequirements
[D2]: https://doc.rust-lang.org/rustc/platform-support.html
[E1]: https://github.com/saymer-alt/entware-go/blob/2c44dd44d14ffaa1a0a29f2008507e1b392ae597/go_env.mk#L1-L85
[E3]: https://github.com/saymer-alt/mihomo-auto-build/blob/f3fef398e023b2700e315093ac788b21c21342e7/README.md#L1-L35
[E4]: https://github.com/saymer-alt/mihomo-auto-build/blob/f3fef398e023b2700e315093ac788b21c21342e7/docs/GPL-SOURCE-AUDIT-2026-10-11.md#L36-L72
[I1]: https://github.com/amurcanov/csqtt/issues/33
[K1]: https://github.com/saymer-alt/keenetic-auto-setup/blob/ac959105509c56a5b4bfb080a64bf825880eb09b/install.sh#L375-L407
[K10]: https://github.com/saymer-alt/keenetic-auto-setup/blob/ac959105509c56a5b4bfb080a64bf825880eb09b/S00ubifs#L1-L100
[K2]: https://github.com/saymer-alt/keenetic-auto-setup/blob/ac959105509c56a5b4bfb080a64bf825880eb09b/install.sh#L601-L700
[L1]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/LICENSE#L1-L30
[L2]: https://github.com/ClusterM/wg-obfuscator/blob/7008e0ce1ea71a39ce4b50ec9c10d2ce50e9183f/LICENSE#L1-L30
[L3]: https://github.com/Ground-Zerro/Phobos/blob/9c2901849af2aeda82d7171369db796ead0bb874/LICENSE#L1-L30
[L4]: https://github.com/hoaxisr/awg-manager/blob/38899601091f67aaa105165a07cdd98117802046/LICENSE#L1-L21
[L5]: https://github.com/SanityProtocol/swg-panel/blob/e58d2a96ac88f06cfb349de542ab4c9b8eb6f747/LICENSE#L1-L21
[L6]: https://github.com/SpaceNeuroX/proxy-turn-vk-android/blob/a296c57eaba69bb9479a24f9157856490890e47d/LICENSE#L1-L30
[O1]: https://github.com/ClusterM/wg-obfuscator/blob/7008e0ce1ea71a39ce4b50ec9c10d2ce50e9183f/Makefile#L1-L65
[O10]: https://github.com/ClusterM/wg-obfuscator/blob/7008e0ce1ea71a39ce4b50ec9c10d2ce50e9183f/.github/workflows/build.yml#L64-L140
[O3]: https://github.com/ClusterM/wg-obfuscator/blob/7008e0ce1ea71a39ce4b50ec9c10d2ce50e9183f/obfuscation.c#L90-L130
[O5]: https://github.com/ClusterM/wg-obfuscator/blob/7008e0ce1ea71a39ce4b50ec9c10d2ce50e9183f/masking_stun.c#L120-L155
[O6]: https://github.com/ClusterM/wg-obfuscator/blob/7008e0ce1ea71a39ce4b50ec9c10d2ce50e9183f/config.c#L14-L88
[Q1]: https://github.com/SpaceNeuroX/proxy-turn-vk-android/blob/a296c57eaba69bb9479a24f9157856490890e47d/go_client/main.go#L160-L190
[Q2]: https://github.com/SpaceNeuroX/proxy-turn-vk-android/blob/a296c57eaba69bb9479a24f9157856490890e47d/go_client/session.go#L275-L325
[Q3]: https://github.com/SpaceNeuroX/proxy-turn-vk-android/blob/a296c57eaba69bb9479a24f9157856490890e47d/go_client/go.mod#L1-L30
[R4]: https://github.com/luminescq/focsq/blob/9ad3bfb36e7ed5717b3ee2766e53a59ddf2fbad5/backend/Cargo.toml#L1-L65
[R5]: https://github.com/Ground-Zerro/Phobos/blob/9c2901849af2aeda82d7171369db796ead0bb874/src/server/phobos/templates/router-configure-wireguard.sh#L25-L70
[R6]: https://github.com/hoaxisr/awg-manager/blob/38899601091f67aaa105165a07cdd98117802046/awgmproto/fd_linux.go#L1-L100
[R7]: https://github.com/hoaxisr/awg-manager/blob/38899601091f67aaa105165a07cdd98117802046/internal/opkgtun/opkgtun.go#L1-L100
[R9]: https://github.com/SanityProtocol/swg-panel/blob/e58d2a96ac88f06cfb349de542ab4c9b8eb6f747/forks/csqtt/README.md#L182-L200
[S1]: https://github.com/armon/go-socks5/blob/e75332964ef5/request.go#L235-L250
[W1]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/go.mod#L1-L41
[W15]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/server.go#L1719-L1735
[W18]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/raw_session.go#L1-L95
[W3]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/main.go#L240-L265
[W5]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/awgm_control.go#L150-L175
[W6]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/raw_tun.go#L247-L283
[W7]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/socks5.go#L20-L126
[W9]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/session.go#L200-L290


> Уточнения Phase 2 от 2026-10-11: сборки только entware-go/gh-action-build; предпочтительный свободный стенд KN-4210 после подключения и read-only preflight. ABI, ядро и RAM не предполагаются. KN-1010 испытывается отдельно от рабочей сети. Домашний Keenetic — production, эксперименты запрещены. Политика и матрица: [Phase 2](PHASE2-HARDWARE-AND-GATES.md). Результаты QEMU остаются лабораторными.
