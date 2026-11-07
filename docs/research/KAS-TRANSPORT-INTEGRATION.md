# Архитектура будущих необязательных модулей KAS

[Индекс](README.md) · [Основной отчёт](WDTT-CSQTT-WG-OBFUSCATOR-2026.md) · [Матрица](TRANSPORT-COMPATIBILITY-MATRIX.md) · [Сборки](TRANSPORT-BUILD-PLAN.md) · [Интеграция](KAS-TRANSPORT-INTEGRATION.md) · [Тесты](TRANSPORT-TEST-PLAN.md)

**Только проектирование.** В этом исследовании не добавлены installers/init/hooks/production YAML. Статус всех схем — **LIKELY по коду**, end-to-end acceptance Keenetic/VPS **UNVERIFIED**. Основной PoC B, затем E; A ограничен TCP; C/D требуют самостоятельного TUN owner.

## 1. Контракты, которые сохраняются

| Контракт KAS | Обязательство нового модуля | Код |
|---|---|---|
| Один Mihomo, mixed-port7890 | Не запускать второй экземпляр, не занимать7890 | [K4] [K9] |
| mitun0, auto-route:false, существующий stack | Не создавать/переименовывать mitun0; existing tun no-op, не навязывать всем gvisor | [K6] |
| ProxyN socks5+socks5-udp, loopback7890, description ownership | Не заменять transport SOCKS1080 вместо canonical Mihomo; foreign ProxyN untouched | [K4] |
| MagiTrickle / DNS interception | Не создавать конкурирующий DNS redirect, не снимать существующий | [K3] [K5] |
| S00ubifs / EXT4 / RAM profile | Не менять mounts/tmpfs/swap и не писать постоянно во внутреннюю flash | [K1] [K2] [K10] |
| Lifecycle/config-import/update rollback | Один lock protocol, same-filesystem stage/commit, old state restoration | [K9] [K11] [K12] |
| Watchdog whitelist/direct WAN/cooldown | Не рестартовать Mihomo из-за NEEDS_AUTH внешнего transport; отдельный диагноз | [K7] |
| Существующие netfilter hooks | Не flush chains, не занимать чужие marks/tables; учитывать PREROUTING≠OUTPUT | [K8] |

Текущий bootstrap YAML сам не обеспечивает универсальный fail-closed. Защита выбранного optional tunnel — отдельный scope с packet tests, не объявление свойства всего KAS. Административный LAN/SSH доступ и исходная policy должны сохраняться при любой неудаче.

## 2. A — WDTT SOCKS5 перед Mihomo

```text
LAN → NDMS policy → ProxyN/Mihomo7890 → SOCKS outbound127.0.0.1:1080
 → wt-client -mode socks (свой WG userspace stack)
 → DTLS/WRAP/RTP → VK TURN → VPS WDTT/WG → Internet
```

Изменения будущего KAS: optional wt-client module, один local TCP SOCKS outbound, отдельная health диагностика, выбор policy. `udp:false` отражает действительность; пользователь должен видеть ограничение UDP до выбора. TCP CONNECT поддерживается, UDP ASSOCIATE возвращает unsupported. QUIC, UDP-DNS и WebRTC UDP не пройдут этим SOCKS; поведение fallback зависит от приложения. Дополнительный WG/gVisor stack расходует ресурсы наряду с Mihomo. **Не выбирать A универсальным основным вариантом.** [W7] [S1]

## 3. B — WG-outbound Mihomo → локальный endpoint WDTT

```text
LAN traffic → существующие Keenetic policy/MagiTrickle
 → ProxyN7890 и/или mitun0 → существующий Mihomo
 → WireGuard outbound → lo UDP127.0.0.1:9000 wt-client vpn
 → outer sessions WAN → VK TURN relay → свой VPS WDTT
 → WG peer → routing/NAT → Internet
```

**CONFIRMED кодовый контракт:** сервер выдаёт стандартный WG `.conf`; Mihomo уже реализует userspace WireGuard client bind. Отдельный `wireguard-go`, wg-quick или native WG интерфейс на клиенте не требуется. `.conf` нельзя вставить в YAML как строку: parser переводит поля. Выданные ключи, адрес и MTU нужны реальному peer, тестовые значения ниже не соединяются. [W15] [M1] [M2] [M3]

| Выдача WDTT | Поле Mihomo | Обработка |
|---|---|---|
| Interface.PrivateKey | private-key | base64, secret0600; не журналировать |
| Interface.Address | ip / ipv6 | ip без CIDR для соответствующего option; upstream parser contract проверить; generator сейчас IPv4 |
| Interface.MTU | mtu | Не копировать вслепую, test PMTU и conservative initial lab value |
| Interface.DNS | DNS policy KAS отдельно | Не превращает автоматически main DNS в защищённый resolver |
| Peer.PublicKey | public-key | Пин peer key; смена требует transaction |
| Peer.PresharedKey если есть | pre-shared-key | Optional; hoaxisr обычная выдача его не обещает |
| Peer.Endpoint127.0.0.1:port | server127.0.0.1 + port | Не подставлять VPS вместо local transport endpoint |
| Peer.AllowedIPs | allowed-ips | Соответствие маршрутам; IPv6 допускается только после отдельного acceptance |
| PersistentKeepalive | persistent-keepalive | Согласовать с TURN session/idle budget |

Пример **формы**, с placeholders вместо ключей:

```yaml
proxies:
  - name: WDTT-LAB
    type: wireguard
    server: 127.0.0.1
    port: 9000
    ip: 10.66.0.2
    private-key: REPLACE_WITH_LAB_PRIVATE_KEY
    public-key: REPLACE_WITH_LAB_SERVER_PUBLIC_KEY
    allowed-ips: [0.0.0.0/0]
    persistent-keepalive: 25
    mtu: 1280
    udp: true
```

1280 здесь — начальное **проектное значение теста**, не подтверждённая оптимальная MTU. Такой placeholder YAML не должен проходить validation или ставиться пользователю. Применение только через существующий config transaction с действительными лабораторными keys. [M1] [K11]

### Обновление выдачи

Upstream config handler получает конфигурацию один раз и выводит её в лог; готового безопасного event/reload contract нет. Минимальный будущий patch wt-client: `--secret-file`/secret fd; `--wg-config-out` atomic0600; отключить secret/stdin echo; structured `{generation, config-digest, status}` без ключей; событие при действительно новой конфигурации. Это не изменение KAS на текущем этапе. [W2] [W4]

Координатор сравнивает digest; если keys/IP/MTU не изменились — no-op, без restart/write flash. При изменении: lifecycle maintenance → сохранение old config+module state → validate candidate одним Mihomo → atomic commit → controlled restart → WG/egress test → accept либо rollback. Пока контрольный tunnel не принят, выбранный защищаемый scope остаётся blocked, не DIRECT. Старое соединение может быть невалидно после server rotation: rollback тогда возвращает управляемое состояние blocked и объяснимый статус, а не «успех». [K9] [K11]

### Маршруты, DNS, IPv6, firewall

* Loopback WG endpoint должен идти через `lo`. Не наследовать у этого outbound принудительный physical WAN `interface-name`, если SO_BINDTODEVICE ломает127.0.0.1; не создавать `dialer-proxy` цикл через себя. Внешние wt-client sockets должны идти WAN вне выбранного tunnel scope. Динамические TURN IP/auth/DNS исключения требуют отдельной модели; исключение одного IP VPS недостаточно. [M2] [W8]
* Сохранить Magi DNS interception. Bootstrap resolution VK/relay должен работать до tunnel; application DNS выбранного scope проверять на отсутствие direct53/IPv6 leaks. Поля DNS из WG config не гарантируют этого. [K3] [W15]
* Первый PoC IPv4-only с явной политикой IPv6 для выбранных клиентов, затем dual-stack. Наличие ipv6 option в Mihomo не доказывает IPv6 auth/relay/raw/generator path. Нельзя глобально выключать чужой IPv6 без согласованного scope. [M1] [G2]
* Локальный listener только127.0.0.1; для внешнего TURN не нужно открывать incoming UDP56000 на роутере. UDP56000 — server example, независим от local9000. На VPS открыть только выбранный own server listener, WG backend локально/scoped; это отдельное будущее разрешение.
* При падении wt-client WG handshake/data timeout; Mihomo продолжит работать. Если policy group содержит DIRECT/fallback, возможен direct egress. Требуется выбранный fail-closed group+scope guard, packet verification при kill/port conflict/VK failure. Состояние transport DOWN не должно вызывать loop restarts Mihomo. [K7]

## 4. C — WDTT RAW и OpkgTunN

```text
LAN → NDMS/MagiTrickle policy → новый собственный OpkgTunN
 ↔ /dev/net/tun fd → small KAS helper → wt-client raw mode
 ↔ WRAP/RTP → VK TURN → RAW VPS → routing/NAT
```

Это отдельная data plane, не автоматический outbound Mihomo. Для использования RAW как egress Mihomo понадобится дополнительный router/proxy adapter; прямой WireGuard YAML к RAW-port несовместим. Не делать одновременно двух readers существующего `mitun0`.

AWGM reference показывает OpkgTun allocation и SCM_RIGHTS attach-tun. Можно реализовать свой ограниченный helper: получить free NDMS ID, readback существующих interfaces, создать только доказанно свой объект, проверить kernel mapping, открыть TUN `IFF_TUN|IFF_NO_PI`, передать fd, сохранять ownership manifest, при stop отсоединить только свой fd/interface. Manager daemon не нужен. `ndmc`/RCI/FD протоколы — раздельные границы: AWGM attach-tun JSON protocol не равен CSQTT bare fd socket. [R6] [R7] [W5]

**BLOCKED legacy standalone RAW:** `startRawTUN` предварительно удаляет interface по имени. Минимальная замена — fd-only attach либо open-existing-owned TUN без `ip link del`; добавление/удаление NDMS ведёт helper с exact provenance. Совпадение имени или label OWNED недостаточно. При Unknown/readback failure — отказ, без takeover. [W6] [E6]

Для NDMS регистрации, link state, MTU, gateway/address, policy selection, DHCP/DNS announcement и reboot persistence нужны tests конкретной KeeneticOS/Netcraze версии. На текущем этапе нет подтверждённого RCI schema для всех firmware; нельзя публиковать универсальную команду интерфейса из README manager. MagiTrickle должен видеть зарегистрированный exit и down state, иначе routing может падать в WAN. Privileged helper минимален; client по возможности drop privileges после fd attach.

## 5. D — CSQTT RAW

```text
NDMS policy → отдельный OpkgTunN ↔ own helper
 → Unix socket SCM_RIGHTS → csqtt-client --tun-uds
 → RAW frames/obfs → VK TURN → CSQTT RAW server → Internet
```

`--tun-uds` клиент получает fd, сам NDMS интерфейс не создаёт. Bare UDP `--listen` принимает IP datagrams; ciphertext WireGuard к нему не подходит. Самостоятельное TUN использование **LIKELY**, требует того же owner/helper/MTU/DNS/IPv6 admission что C и дополнительного license/ABI/crypto gate. Повторно использовать идею helper, но не считать wire/API совпадающими. [C5] [C6] [C9]

Интеграция с Mihomo через `interface-name` — лишь возможная отдельная route architecture: необходимо доказать, что outgoing socket/mark/interface routes действительно выбирают нужный exit и outer TURN не зациклен. Нет готового стандартного `type:csqtt` в проверенном Mihomo; изобретать YAML option нельзя. Альтернатива RAW→собственный SOCKS adapter повышает сложность и возвращает вопрос UDP ASSOCIATE. До значимого выигрыша над B такой adapter отложить.

## 6. E — WG-obfuscator и существующий WG

```text
Mihomo WG → local UDP127.0.0.1:13255 obfuscator(STUN)
 → WAN direct UDP → VPS obfuscator(AUTO/STUN)
 → localhost WG backend → Internet
```

Изменения будущего KAS: optional C binary/module, private config с source-if127.0.0.1/target/key/masking/max-clients, один WG outbound с локальным endpoint, diagnostics/rollback. WG keys и cryptographic peer остаются в WG. `allow-clean` выключен. Outer source/mark/route проверяется отдельно; не занимать fwmark0x88 AMG или неизвестный NDMS mark. `resolve-interval` и SIGHUP есть в текущем HEAD, но DNS failure и IP change acceptance обязательны. [O6] [O9]

Вариант native Keenetic WG вместо Mihomo обоснован Phobos ndmc шаблоном с loopback endpoint. Это отдельный optional mode: нужна доказанная собственность WireguardN, canonical routing policy, no foreign interface adoption; на сервере нужен соответствующий obfuscator. Не устанавливать Phobos panel/s6 ради одного C-процесса. [R5]

E не использует VK TURN и не переживёт IP-block VPS только за счёт STUN wrapper. MTU рассчитывать по PMTU минус все оболочки, dummy максимумам и WG overhead; использовать sweep и capture, не обещать1420 универсально. WG handshake обязателен: C program хранит connection state и не является произвольным stateless UDP echo. [O4] [O7] [O8]

## 7. Предлагаемые модули и владение

Главный installer только предлагает установку по явному выбору; **ничего автоматически не добавляет** всем KAS пользователям. Future modules: `wdtt-client`, `wg-obfuscator`, `csqtt-client` (после gates). GUI/panels не нужны. POSIX sh/BusyBox compatibility обязательна.

| Объект | Проектное расположение / владелец | Правило |
|---|---|---|
| Binary versions | `/opt/libexec/kas-transports/<component>/<version>/` | Immutable hash+manifest; active symlink/rename atomic |
| Secret config | `/opt/etc/kas-transports/<instance>/`0700, files0600 | Без cookies/keys в argv/log/status; argv patch required |
| Init | `/opt/etc/init.d/Sxxkas-transport-<instance>` | Только own executable+manifest PID/starttime; no killall |
| Runtime/locks | `/opt/var/run/kas-transports/` либо verified volatile dir | Не полагаться на unverified symlink/tmpfs; unknown owner→abort |
| Logs | verified tmpfs, max256KiB×2/instance (предлагается) | Rate limit; no TRACE; сохранять bounded redacted crash reason |
| Ownership | persistent manifest UUID+hash+file/interface/rule identity | Имя/PID/description само по себе не доказывает own |
| Optional netfilter | registered unique chain/mark/table | Exact owned rules only, recreate idempotently после NDMS hook |

Порты9000/1080/13255 — upstream/examples, не автоматически выделенный namespace. Проверять IPv4/IPv6 TCP/UDP wildcard binding и identity конкурента. Preflight race закрывается instance lock + exclusive bind, а для SO_REUSEADDR wt-client требуется patch/lease. Ни один installer не должен удалять `free-turn-proxy` потому, что он «мешает» новому. [W14] [O6]

## 8. Supervisor и диагностика

Состояния: `DISABLED → STARTING → WAIT_NETWORK / NEEDS_AUTH / QUOTA / READY / DEGRADED / CONFIG_ERROR / CIRCUIT_OPEN`. Отдельно `process alive`, `local endpoint bound`, `TURN allocated`, `peer authenticated`, `WG handshake`, `egress probe`, `policy guard applied`; PID alone не health.

Предлагаемый restart budget: ≤5 starts/15min, backoff5/15/30/60/120s с jitter, затем CIRCUIT_OPEN до explicit retry/config change. Port conflict, bad secret, unsupported target, foreign ownership — CONFIG_ERROR без restart. CAPTCHA требует пользователя/разрешённого auth flow, не million-retry. QUOTA ждёт отдельного cooldown; upstream internal retry не должен умножаться внешним per-second supervisor. Эти числа — проектные критерии, не existing behavior. [W16] [C11]

Doctor остаётся read-only: version/SHA/target/locks/ports/NDMS mapping/last state/worker count/memory/log budget/route counters; секреты и full config исключить. Network-active probe должен быть явно отмечен и ограничен, не отправлять приватные данные произвольному HTTP endpoint. Watchdog Mihomo различает own failure и dependency-down: maint marker/known transport state подавляет ненужный restart только на ограниченное время; не скрывать реальную неисправность core. [K7] [K13]

На VPS future systemd unit: bounded StartLimitIntervalSec/StartLimitBurst, nonzero RestartSec/backoff, permanent bind failure не autorestart; journal rate/cap budget, ограниченные capabilities и dedicated user после проверки TUN needs. Это проект, unit не создавался. На Entware аналогичную политику реализует собственный supervisor, а не копия systemctl installer. [O2]

## 9. Update, rollback, reboot, uninstall

Download/verify/signature/license/arch/free-space выполняются пока старая версия работает. Stage на той же filesystem, сохранить verified previous version+config+manifest. Координатор получает transport и Mihomo lifecycle locks в **одном документированном порядке**, не удерживает lock ожидая конкурирующий daemon. Preflight без второго Mihomo; stop только own service; atomic active switch; старт/health/policy gate; accept либо restore old binary+config+service state. Maintenance marker всегда снимается trap/recovery, но guard остаётся при неподтверждённом protected egress. Crash между каждой фазой проверяется. [K9] [K12]

Reboot: дождаться mount `/opt`, resource backend и сети; start transport/auth, только после readiness активировать its policy. Сбой auth после reboot не должен блокировать LAN admin. Если startup неизвестен — диагностируемая деградация, no busy loop и no direct leak выбранного protected scope.

Uninstall: отключить только own policy references, восстановить записанные prior values если они всё ещё равны поставленным нами; остановить только process с matching exe/inode/starttime; удалить только manifest-owned files/rules/interfaces. Foreign modifications retain+report. Не удалять Mihomo, MagiTrickle, mitun0, S00ubifs, ProxyN чужого владельца, другие WDTT units; no global firewall flush/systemctl wildcard. Backup/rollback не заменяет provenance допуска. [E6] [K4]

## 10. link-generators / web4core

**Первый B/E PoC — без новых URI/UI:** получить синтетическую/лабораторную WG `.conf` безопасно, импортировать существующим parser, endpoint loopback, проверить с реальным Mihomo. Source parser/builder уже есть; browser не запускает transport. [G1] [G2]

Будущие изменения после hardware gate: local-service profile с instance ID/endpoint, запрет неверного physical interface binding/recursive chain, явный TCP-only label для A, local availability warning, compatibility manifest version. Endpoint/device binding выполняет KAS, browser не хранит VK cookies/password и не отправляет private keys в telemetry. Не экспортировать credentials в публичный URL. Не терять keys/MTU/AllowedIPs при dedup; протестировать два local endpoints с разными peers и одинаковым127.0.0.1. [G1] [G2]

Реализация в source web4core с его AGENTS/build/test workflow, затем regenerated runtime в link-generators; handwritten generated bundle запрещён. IPv6 contract, custom wdtt:// import и auth UX — отдельный scope после доказанной сетевой схемы, не условия первого PoC. [G3]

## Первичные источники

[C11]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-client/turn_core.rs#L330-L355
[C5]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-client/dispatcher.rs#L445-L480
[C6]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-client/tun.rs#L1-L110
[C9]: https://github.com/amurcanov/csqtt/blob/71712b07dbabe16fa43f5a248dc69e1ab9f3a270/rust-client/protocol.rs#L1-L65
[E6]: https://github.com/saymer-alt/vps-gateway-bootstrap/blob/1e41c29c1f35a9b092472d9b2bfc43fcbfbd0872/tools/fileexperiment/main.go#L1-L21
[G1]: https://github.com/saymer-alt/web4core/blob/fea3cede102ca69137975b31a20317a4c42e052b/src/core/wireguard.js#L3-L300
[G2]: https://github.com/saymer-alt/web4core/blob/fea3cede102ca69137975b31a20317a4c42e052b/src/core/mihomo.js#L688-L745
[G3]: https://github.com/saymer-alt/link-generators/blob/857da9ef723e97b1cfa01fd8ac5607880bfcb826/AGENTS.md#L1-L65
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
[M2]: https://github.com/MetaCubeX/mihomo/blob/88dcbf7f1614a67c3b36b848ee3592dfa92ada36/adapter/outbound/wireguard.go#L351-L383
[M3]: https://github.com/MetaCubeX/mihomo/blob/88dcbf7f1614a67c3b36b848ee3592dfa92ada36/adapter/outbound/wireguard.go#L396-L444
[O2]: https://github.com/ClusterM/wg-obfuscator/blob/7008e0ce1ea71a39ce4b50ec9c10d2ce50e9183f/Makefile#L100-L124
[O4]: https://github.com/ClusterM/wg-obfuscator/blob/7008e0ce1ea71a39ce4b50ec9c10d2ce50e9183f/masking_stun.c#L1-L30
[O6]: https://github.com/ClusterM/wg-obfuscator/blob/7008e0ce1ea71a39ce4b50ec9c10d2ce50e9183f/config.c#L14-L88
[O7]: https://github.com/ClusterM/wg-obfuscator/blob/7008e0ce1ea71a39ce4b50ec9c10d2ce50e9183f/wg-obfuscator.c#L1035-L1120
[O8]: https://github.com/ClusterM/wg-obfuscator/blob/7008e0ce1ea71a39ce4b50ec9c10d2ce50e9183f/wg-obfuscator.c#L1195-L1248
[O9]: https://github.com/ClusterM/wg-obfuscator/blob/7008e0ce1ea71a39ce4b50ec9c10d2ce50e9183f/wg-obfuscator.h#L27-L40
[R5]: https://github.com/Ground-Zerro/Phobos/blob/9c2901849af2aeda82d7171369db796ead0bb874/src/server/phobos/templates/router-configure-wireguard.sh#L25-L70
[R6]: https://github.com/hoaxisr/awg-manager/blob/38899601091f67aaa105165a07cdd98117802046/awgmproto/fd_linux.go#L1-L100
[R7]: https://github.com/hoaxisr/awg-manager/blob/38899601091f67aaa105165a07cdd98117802046/internal/opkgtun/opkgtun.go#L1-L100
[S1]: https://github.com/armon/go-socks5/blob/e75332964ef5/request.go#L235-L250
[W14]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/listen.go#L1-L24
[W15]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/server.go#L1719-L1735
[W16]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/group.go#L160-L245
[W2]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/main.go#L138-L190
[W4]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/main.go#L380-L425
[W5]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/awgm_control.go#L150-L175
[W6]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/raw_tun.go#L247-L283
[W7]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/socks5.go#L20-L126
[W8]: https://github.com/hoaxisr/proxy-turn-vk-android/blob/1110a75f76e42c23149b8e24f9182c1ff179e515/go_client/session.go#L130-L155


> Уточнения Phase 2 от 2026-10-11: сборки только entware-go/gh-action-build; предпочтительный свободный стенд KN-4210 после подключения и read-only preflight. ABI, ядро и RAM не предполагаются. KN-1010 испытывается отдельно от рабочей сети. Домашний Keenetic — production, эксперименты запрещены. Политика и матрица: [Phase 2](PHASE2-HARDWARE-AND-GATES.md). Результаты QEMU остаются лабораторными.
