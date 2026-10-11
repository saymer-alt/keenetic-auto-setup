# Эксперименты, измерения и критерии допуска

[Индекс](README.md) · [Основной отчёт](WDTT-CSQTT-WG-OBFUSCATOR-2026.md) · [Матрица](TRANSPORT-COMPATIBILITY-MATRIX.md) · [Сборки](TRANSPORT-BUILD-PLAN.md) · [Интеграция](KAS-TRANSPORT-INTEGRATION.md) · [Тесты](TRANSPORT-TEST-PLAN.md)

Снимок 2026-10-11. В разделе1 перечислены **выполненные лабораторные проверки**. Все hardware/VK/throughput/acceptance действия следующих разделов — **план**, не состоявшийся запуск. Работа на реальном Keenetic/VPS требует отдельного разрешения владельца; это исследование его не использует.

## 1. Что уже проверено

Среда: Windows PowerShell/Python, Go1.27.0; WSL Linux с gcc15/readelf и qemu user для ARM64/MIPS/MIPSel. Rust1.97.1 rustc/cargo/std установлен только в lab prefix из official archives по SHA256 manifest. Musl cross toolchains20250520 проверены по sidecars. Команды/versions/source pins — [build plan](TRANSPORT-BUILD-PLAN.md); результаты/ELF/log tails — [evidence JSON](TRANSPORT-RESEARCH-EVIDENCE.json). Сборки не публиковались, реальные ключи/VK accounts не использовались.

| Компонент | Target | Build exit | Bytes | SHA256 |
|---|---|---|---|---|
| wt-client | amd64 | 0 | 16,740,476 | `8f6a65a9e617a65fe96edd8daeea999844919ce56ff410be3210c5d3b7599218` |
| wt-client | arm64 | 0 | 15,597,692 | `79b0056ce192a8d86ca36649c22588d6c39086375030519787e1d993c172d609` |
| wt-client | mipsle | 0 | 18,022,555 | `70ebfce7aa854d91965854d80fa80475003014192dd4924014db595f154032db` |
| wt-client | mips | 0 | 18,022,555 | `87ab1d771ea061b6fe24c86110dd6fbebece73b703f51e96562274d264286de4` |
| wg-obfuscator | amd64 | 0 | 1,215,968 | `23ca46fbd489b315c6179868621a623f65f2110aecda76f4be55137712bc6813` |
| wg-obfuscator | arm64 | 0 | 133,080 | `5768b185b4ed5856f4c865b24a5b686d18df860269849268c522867a478a517d` |
| wg-obfuscator | mipsel | 0 | 187,308 | `3ef72e4c66bf618a5cf4a8879889497eb2ad9529944385c76ecb8e14501098ad` |
| wg-obfuscator | mips | 0 | 187,180 | `cb795c62b1ce087f3976d276ad10a207414297759f881b2d938c049ea452477f` |
| WDTT repeat-client | amd64 | 0 | 16,740,476 | `8f6a65a9e617a65fe96edd8daeea999844919ce56ff410be3210c5d3b7599218` |
| WDTT server | amd64 | 0 | 9,252,988 | `118c5e70f3cc42f164437caf4364feb2411d936749646340785a588f34e735a2` |
| CSQTT client | amd64 GNU | 0 | 10,366,208 | `736a410a8f094a21f8273fcbdb8595e66c340d7032ceeecbff72dfd0a1550d34` |
| CSQTT client vanilla | arm64 musl | 101 | — | `—` |
| CSQTT client + lab ABI patch | arm64 musl | 0 | 8592288 | `d9beeb126f785cf40a1bd63db7460a1082dae2619093ee3ac8a05c4c55a55bca` |

* wt-client `-h` и `-awgm-protocol`: native AMD64 и QEMU ARM64/MIPS/MIPSel exit0. JSON protocol advertises raw/wg + state/attach-tun/detach-tun. Это **startup/CLI**, не network auth или WG handshake.
* Повтор AMD64 wt-client побитово совпал с первым ELF. Два независимых clean builders ещё не проверены.
* WDTT server AMD64 компилируется из root module. Из-за отсутствующего upstream go.sum применён отдельный lab modfile; upstream source не переписан. Server не устанавливался и live pairing не проверялся.
* wg-obfs `--help`: native AMD64 и QEMU три cross targets exit0. Readelf показал правильный machine/endian, static musl cross ELF и MIPS FP ABI Soft float. AMD64 static glibc имеет getaddrinfo/NSS warning, поэтому не заявлен универсальным автономным distribution binary.
* wg-obfs loopback: два native процесса STUN/AUTO + synthetic WG-shaped type1/type2 headers; затем type4 packets32/148/512/1200/1420 B вернулись без изменения. **Нет криптографически валидного WG handshake**, WAN, VK или DPI. Ранние попытки дали два timeout: первая без establishment sequence, следующая уже с synthetic sequence (недостаточно диагностических данных, причина не установлена). Финальный запуск с DEBUG прошёл. Это один подтверждённый forwarding run, не доказательство стабильного harness; startup readiness проверять явно, не полагаться только на sleep. DEBUG допустим здесь только для synthetic data, не real secrets.
* SOCKS точной armon dependency: CONFIRMED: {"connect_reply":0,"scope":"exact armon dependency; loopback TCP only; not VPN test","tcp_equal":true,"udp_associate_reply":7} Это TCP loopback library test, не gVisor/VPN test. Код unsupported UDP ASSOCIATE отдельно подтверждён. [S1]
* CSQTT native AMD64 `cargo build --locked --release --bin client`: exit0,3 dead-code warnings. ELF динамический glibc. `--help` даёт rc2/Usage из-за отключённого upstream Clap help, не fatal loader failure. ARM64: **BLOCKED vanilla ARM64/musl**: udp_batch.rs553/577 flags i32→u32 mismatch и643 private msghdr padding; патч-проба отдельно в evidence. **CONFIRMED lab-only patched build**: static ARM64 musl ELF, QEMU parser startup; реальный TUN/VK/Keenetic UNVERIFIED.
* Два upstream CSQTT tamper tests (узкий фильтр, не полный suite и не независимый crypto audit):

```text
CONFIRMED: running 2 tests
test obfs::tests::video_wire_rejects_every_single_byte_tamper ... ok
test obfs::tests::authenticated_audio_region_rejects_every_single_byte_tamper ... ok

test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 332 filtered out; finished in 0.01s
```

Локальные величины не говорят о RSS, Mbit/s или DPI. Неизмеренные поля: CPU/RSS роутера, softfloat throughput, crypto assurance, настоящая TURN auth/refresh, NDMS registration, packet leak, loss/reorder, MTU under relay, reboot,24h soak. Никакое PASS mock/QEMU не переносится на эти поля.

### Повторение лаборатории

Сохранены наши [рецепты/пробы](lab-recipes/README.md) с оригинальными scope/logs. Воспроизводить в отдельном lab с исходниками под `repos/OWNER__REPO`, artifacts под `lab/`; сначала checkout pinned SHA, затем exact toolchain. Скрипты предназначены для среды исследования, не для роутера. UPSTREAM install.sh/make install не запускать.

```sh
# Native/QEMU CLI
./lab/wdtt/wt-client-linux-amd64 -h
qemu-aarch64 ./lab/wdtt/wt-client-linux-arm64 -awgm-protocol
qemu-mipsel ./lab/wdtt/wt-client-linux-mipsle -h
qemu-mips ./lab/wdtt/wt-client-linux-mips -h
readelf -h -l -A ./lab/obfuscator/wg-obfuscator-linux-mipsel
# CSQTT: отсутствие help contract ожидаемо для текущего manifest
cargo test --locked --release --bin client single_byte_tamper
```

## 2. Поэтапный PoC

| Этап | Эксперимент | Условие завершения | Что блокирует следующий этап |
|---|---|---|---|
| P0 | Source/toolchain/dependency/license pins, secret-output fixes design | Reviewed manifest, synthetic logs no secrets, scoped publication decision | Unknown license/linked incompatibility |
| P1 | wt-client build и standalone control | Четыре ELF/startup, config output0600 без secret log, bounded supervisor | argv/stdin/private-key leak patch absent |
| P2 | B в isolated namespace/VPS+Mihomo | Real WG handshake through pinned WDTT/TURN, TCP+UDP+DNS, no loops | Неподтверждённая совместимость или fail-open |
| P3 | wg-obfs E | True WG through two ends, packet/MTU/loss, native WG optional | STUN mimic не решает нужный network problem |
| P4 | CSQTT ARM64 | Static ELF+native firmware syscalls+license gate+RAW crypto review | libc/crypto/kernel/licensing unresolved |
| P5 | RAW C/D helper | fd attach, NDMS readback, own-only lifecycle, no mitun0 collision | legacy delete/adoption path |
| P6 | KN-1012, затем KN-1010 | Reboot/fault/24h resource matrix | OOM, leaks, admin loss, excessive restart |
| P7 | KAS optional implementation gate | Evidence reviewed, regression+hardware pass, отдельное разрешение | Нет live acceptance либо несовместимый license channel |

B не должен зависеть от завершения RAW/CSQTT. E можно исследовать параллельно как меньший эксперимент, но не объявлять заменой AWG3.1 без сравнительного результата. [W6] [M1] [O3]

## 3. Что можно автоматизировать без реального роутера

1. Exact SHA/tag resolution, go.sum/Cargo.lock freeze, licenses всех linked/vendor/native dependencies, checksums/signature/attestation, immutable source access.
2. Build4 targets, ELF/endian/FPABI/loader/NEEDED, CLI/parser smoke native/QEMU; cross binary must not silently be hardfloat.
3. WDTT GETCONF/AUTH/error/RAW golden fixtures по согласованной паре; wrong password/expired/device mismatch. CSQTT revision2/3/fork mismatch rejection; truncated/reordered/oversized frame cases. Fixtures synthetic-only. [W12] [W13] [C9] [C10]
4. Real WireGuard между isolated network namespaces и локальными transport endpoints; SOCKS CONNECT + explicit UDP ASSOCIATE unsupported control. Local TURN fixture проверяет serialization/reconnect, **не VK whitelist**.
5. Утечки secrets: canary keys/password/cookies/stdin token, stdout/stderr/journal/status/support bundle/argv scan. File modes existing permissive file/symlink attack, umask, crash during atomic output.
6. Foreign file/process/port/interface/rule preservation, bind race (включая SO_REUSEADDR), concurrent install/update/uninstall, stale PID and PID reuse; unknown state→abort. [W14] [E6]
7. Supervisor fake-clock backoff/budget, network unavailable, captcha permanent, auth error, quota; capped logs/low disk and restart policy. Один service failure не должен каскадировать в Mihomo restart loop.
8. Transaction fault injection до/после каждой rename/config/state phase, disk full, checksum bad, interrupted download, vanished upstream asset, moving tag, revoked manifest; verified previous binary/config/service state restored.
9. Generator `.conf`→YAML fields/keys/MTU/endpoint, duplicate local endpoints with distinct peers, no secret URL, no interface-bound loop; реальный Mihomo `-t` без параллельного daemon. [G1] [G2] [K9]

Automation не доказывает фильтрацию оператора, VK account limits, NDMS semantics или пропускную способность embedded CPU. Namespace tests с mock TUN не являются fd/ioctl/RCI acceptance Keenetic.

## 4. План реального стенда

На каждый run записать: модель/ревизия SoC, RAM, uname/kernel/KeeneticOS/Netcraze, Entware arch/feed, внутренний/внешний EXT4, swap/zRAM, питание/температура, ISP/access type, PMTU/WAN IPv4/IPv6, client/server/Mihomo SHA/versions, flags/workers/auth mode, конфиг без secrets. KN-1012(ARM64) и KN-1010(MT7621/MIPSel) из задания — target names, свойства каждого устройства читать фактически. MIPS BE — отдельный доступный стенд, pass KN-1010 на него не переносится. [D1] [E1]

VPS disposable, отдельный user/service/ports, own WG peer/keys/namespace, ограниченный журнал; snapshot baseline routes/rules/firewall/sysctl/services и OOB/console. На роутере wired LAN admin + независимый recovery path; новый exit сначала только для одного test client/policy. Не запускать эксперимент через единственный admin tunnel. Production devices в этот план не включены без отдельного решения.

Test cohorts:128/256/512+MB; internal Entware и external EXT4; native zRAM/external swap/none только в рамках разрешённого KAS профиля. 128MB нарушающий prerequisites не тестируется как supported install. Firmware baseline и max CPU/heat записывать, не менять маршрутизацию вне scope. [K1] [K2]

## 5. Производительность без субъективных выводов

Сначала baseline: существующий VLESS/Reality, WG/AWG2/3.1, WARP/MASQUE на той же линии и по возможности VPS. Затем B, E, A как TCP-only control, CSQTT/RAW после gates. Не сравнивать разные VPS/время/MTU и приписывать разницу transport. Наличие доступа при whitelist важнее абсолютной скорости, но тест должен показывать оба свойства.

Предлагаемый run:5 повторов по60s на поток/направление,30s warmup, порядок randomized, idle и concurrent Mihomo load; UDP rates1/5/10/20Mbit/s и выше только при запасе CPU/линии; packets64/256/512/1200B; TCP1/4/8flows, upload/download/duplex. Не считать заданный offered rate достигнутой throughput. Сохранять loss/reorder/jitter/p50/p95/p99RTT, CPU user/sys/softirq, per-core saturation, RSS/PSS/MemAvailable, GC если доступен, majorfaults/swapin/out, drops/sockets/fd/temp/flash writes.

WDTT anonymous n12/24/48; account n1/2/4 только с разрешённым auth, не пытаться обойти VK limits. CSQTT sessions и runtime threads варьировать независимо. Отдельно DTLS/WG vs RAW overhead, WAN RTT/loss profiles0/1/3/5%, reorder, constrained MTU1280…1500 с capture. InnerMTU, outer UDP size и fragmentation фиксировать раздельно; max dummy overhead wg-obfs учесть. [W3] [C4] [O4] [O9]

Пустой шаблон результата:

| Run / SHA / cohort | Protocol / workers / threads | CPU p95 | RSS peak / MemAvailable min | TCP goodput | UDP loss/jitter | RTT p95 | PMTU/fragment | Verdict |
|---|---|---|---|---|---|---|---|---|
| Не выполнено | — | — | — | — | — | — | — | UNVERIFIED |

Никаких чисел скорости или памяти из размеров ELF. Issue #33 CSQTT — anecdotal author/user report, не baseline. [I1]

## 6. Пакетная безопасность и fault matrix

На WAN/router/VPS одновременно capture контрольных TCP/UDP/DNS/IPv6/ICMP flows с уникальным synthetic marker. Protected LAN client не должен появляться прямым source/egress на WAN в обход разрешённой topology. Outer VK/auth/relay sockets и admin traffic заранее перечисляются как разрешённые исключения; нельзя объявлять любой WAN пакет утечкой или, наоборот, blanket-разрешить весь host OUTPUT.

| Fault | Проверка | Pass |
|---|---|---|
| kill/STOP wdtt или obfs | LAN TCP/UDP/DNS/IPv6/ICMP, policy state | Нет direct leakage; LAN admin доступен, DOWN отличим от Mihomo failure |
| Drop TURN / auth / quota / captcha | refresh/retry/restart/logs | Бюджеты соблюдены, корректное NEEDS_AUTH/QUOTA, no secret log |
| Occupy UDP56000 на VPS / local9000/13255 | два own/foreign процесса, wildcard+v6 | Новый отказ без удаления конкурента; no restart flood |
| WAN flap, DNS change, VPS DDNS | readiness/resolve/WG handshake | Bounded recovery, no route loop, точное время зафиксировано |
| Wrong key/password/device/generation | protocol rejection | No success state / silent fallback / permissive downgrade |
| MTU blackhole, ICMP filtered | largeUDP/TCPPMTUD, segmentation/capture | Нет неконтролируемой fragmentation; documented maximum workingMTU |
| Clock skew, entropy shortage | auth/TLS/crypto init | Диагностируемый отказ, не обход verification |
| Reboot / /opt late mount / low RAM | init order/readiness/old config | No corrupt config, OOM/flash flood, admin loss |
| Update incompatible server/client | health/commit/rollback/guard | Old pair restored либо explicit blocked state, no false success |
| Foreign modified file/interface/chain | uninstall/reinstall/adoption | Byte-for-byte foreign preservation; owned changes exact and reversible |

UDP56000 million-restart инцидент — из пользовательского задания; журнал/units для независимого расследования не предоставлены. Его нельзя включать в verified local reproductions. Fault test воспроизводит класс ошибки, а не доказывает точную первопричину того инцидента.

## 7. Предлагаемые критерии перехода к реализации

**Hard gates:** zero plaintext secrets в проверенных sinks, zero unauthorized foreign writes/deletes, zero protected-scope direct packets в failure tests, one Mihomo, unchanged original policy outside scope, valid source/license inventory, checksum/signature pin, rollback после каждого fault, admin LAN recovery, no permanent restart loop.

**Измеряемые проектные бюджеты** (ещё не достигнутые результаты): ≤5 starts/15min; logs≤512KiB/instance; functional smoke≥30min; throughput profile≥1h; soak≥24h с WANflap/keyrotation/refresh. На заранее выбранной рабочей нагрузке MemAvailable не ниже `max(32MiB,25% RAM)` для reference cohort, CPU p95<85%, нет OOM или устойчивого swap thrash. Если128MB не выдерживает бюджет, module не допускается туда, даже если KAS base prerequisites выполнены. Числа могут быть согласованно изменены **до** измерений, не задним числом для красивого PASS.

Target goodput/minimum usable rate задаётся по потребности владельца и baseline до run; новый transport может иметь смысл при меньшей скорости, если открывает недоступный иначе путь. RAW выбирается только при доказанном значимом выигрыше на сопоставимой нагрузке и закрытом crypto/ownership gate; «вроде быстрее» недостаточно.

После gates — отдельное разрешение на минимальную optional реализацию KAS; точный PR commit review + соответствующие regression tests + повтор hardware affected cohorts. Build release/publication/stable promotion — последующие раздельные действия, этот отчёт их не разрешает.

## 8. Приоритетный backlog

Оценки — инженерный порядок величины активной работы, не обещание сроков; VK/лицензия/доступ к железу — внешние зависимости.

| Приоритет | Работа | Сложность / оценка | Зависимость / результат |
|---|---|---|---|
| P0 | Зафиксировать source/toolchains, license inventory, co-pinned WDTT pair | M,2–4дня | До публикации; build-only manifest |
| P0 | wt-client redaction/secret-fd/atomic config events/exclusive UDP ownership | M,2–4дня | До real secrets / B PoC; отдельный reviewed patch |
| P1 | B namespace/VPS/Mihomo end-to-end + fail-closed packet tests | M–L,3–7дней | P0 + разрешённый disposable VPS/VK auth |
| P1 | wg-obfs E realWG/MTU/UDP/DPI comparison | S–M,1–3дня | Сборки уже есть; отдельный согласованный стенд |
| P1 | KN-1012 reference + KN-1010 resource/softfloat acceptance | L,5–10дней+24hsoak/cohort | B/E pass; hardware access |
| P2 | Minimal KAS optional module lifecycle/Doctor/update/uninstall | L,5–10дней | Предыдущие hard gates + отдельное разрешение внедрения |
| P2 | link-generators local-service profile, source/runtime tests | M,2–4дня | B/E hardware contract; PoC возможен без UI изменений |
| P2 | CSQTT ARM64 ABI+license+crypto review | L,1–2недели, license gate внешний | Не блокирует B/E, no default shipment |
| P3 | RAW OpkgTun/SCM_RIGHTS helper C/D + NDMS policies | XL,2–4недели | Ownership/API/crypto acceptance; legacy TUN delete устранён |
| P3 | CSQTT MIPS custom target/native crypto feasibility | XL,оценка после первого toolchain spike | Не обещать порт; возможен отказ при несоразмерной цене |

**Рекомендация:** первым B; малый E PoC полезен параллельно. CSQTT ARM64 исследовать ограниченно, RAW и CSQTT MIPS отложить. Отказаться от обязательных панелей, universal TCP-only SOCKS, переноса чужого server installer на роутер и автоматического release/latest обновления без compatibility gate.

## Первичные источники

[C10]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/shared/wire_protocol.rs#L1-L6
[C4]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-client/main.rs#L78-L165
[C9]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-client/protocol.rs#L1-L65
[D1]: https://go.dev/wiki/MinimumRequirements
[E1]: https://github.com/saymer-alt/entware-go/blob/2c44dd44d14ffaa1a0a29f2008507e1b392ae597/go_env.mk#L1-L85
[E6]: https://github.com/saymer-alt/vps-gateway-bootstrap/blob/1e41c29c1f35a9b092472d9b2bfc43fcbfbd0872/tools/fileexperiment/main.go#L1-L21
[G1]: https://github.com/saymer-alt/web4core/blob/fea3cede102ca69137975b31a20317a4c42e052b/src/core/wireguard.js#L3-L300
[G2]: https://github.com/saymer-alt/web4core/blob/fea3cede102ca69137975b31a20317a4c42e052b/src/core/mihomo.js#L688-L745
[I1]: https://github.com/amurcanov/csqtt/issues/33
[K1]: https://github.com/saymer-alt/keenetic-auto-setup/blob/ac959105509c56a5b4bfb080a64bf825880eb09b/install.sh#L375-L407
[K2]: https://github.com/saymer-alt/keenetic-auto-setup/blob/ac959105509c56a5b4bfb080a64bf825880eb09b/install.sh#L601-L700
[K9]: https://github.com/saymer-alt/keenetic-auto-setup/blob/ac959105509c56a5b4bfb080a64bf825880eb09b/AGENTS.md#L40-L76
[M1]: https://github.com/MetaCubeX/mihomo/blob/88dcbf7f1614a67c3b36b848ee3592dfa92ada36/adapter/outbound/wireguard.go#L69-L145
[O3]: https://github.com/ClusterM/wg-obfuscator/blob/7008e0ce1ea71a39ce4b50ec9c10d2ce50e9183f/obfuscation.c#L90-L130
[O4]: https://github.com/ClusterM/wg-obfuscator/blob/7008e0ce1ea71a39ce4b50ec9c10d2ce50e9183f/masking_stun.c#L1-L30
[O9]: https://github.com/ClusterM/wg-obfuscator/blob/7008e0ce1ea71a39ce4b50ec9c10d2ce50e9183f/wg-obfuscator.h#L27-L40
[S1]: https://github.com/armon/go-socks5/blob/e75332964ef5/request.go#L235-L250
[W12]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/protocol.go#L1-L57
[W13]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/protocol_raw.go#L1-L60
[W14]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/listen.go#L1-L24
[W3]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/main.go#L240-L265
[W6]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/raw_tun.go#L247-L283


> Уточнения Phase 2 от 2026-10-11: сборки только entware-go/gh-action-build; предпочтительный свободный стенд KN-4210 после подключения и read-only preflight. ABI, ядро и RAM не предполагаются. KN-1010 испытывается отдельно от рабочей сети. Домашний Keenetic — production, эксперименты запрещены. Политика и матрица: [Phase 2](PHASE2-HARDWARE-AND-GATES.md). Результаты QEMU остаются лабораторными.
