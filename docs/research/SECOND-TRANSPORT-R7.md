# Исследование №7 — Выбор второго независимого транспорта для Keenetic MultiTransport

**Статус:** R&D / DESIGN ONLY. Draft PR, ничего не сливается, никуда не устанавливается.
**Дата:** 2026-10-22. Режим: read-only source audit + локальные синтетические сборки без сети.
**Связанные обсуждения:** #139 (центральный), #142 (OpenFlux), #162 (MAX TURN/WebRTC), #141 (CSQTT), PR #175 (Contract v0), PR #181 (MT-002), PR #171 (feasibility/MVP).
**Метод:** аудиты по фиксированным ревизиям с file:line-ссылками; оценки строго в шкале VERIFIED / SOURCE_CONFIRMED / CLAIMED / UNKNOWN / UNSUPPORTED. RSS-чисел без измерений нет — везде `RSS UNKNOWN`.

## 0. Зафиксированные ревизии

| Репозиторий | Ревизия | Дата |
|---|---|---|
| p1neappleXpress/OpenFlux — тег v0.13.0 | `4f9c786cdd1d9fcd0c133e2e0fec0c5a12522610` | 2026-10-16 |
| p1neappleXpress/OpenFlux — ветка main | `edcf77a` | 2026-10-13 |
| saymer-alt/OpenFlux — main (наш форк) | `edcf77a` | 2026-10-13 |
| saymer-alt/swinter-ios | `dc58e18` | 2026-04-14 |
| saymer-alt/swinter-android | `713496d` | 2026-04-14 |
| saymer-alt/maxcalls | `cdcba2d` | 2026-01-31 |
| amurcanov/csqtt | `d02da9b` | 2026-10-20 |
| danusha2345/csqtt-android (OpenWrt v2.1.17-2, тег openwrt-v2.1.17-r2) | `5c3cf03` | 2026-10-10 |
| saymer-alt/csqtt | `71712b0` | 2026-10-03 |
| luminescq/focsq | `9ad3bfb` | 2026-10-01 |

Отставание форка: `saymer-alt/OpenFlux` main **идентичен** upstream main (`edcf77a`), но **отстаёт от тега v0.13.0 на 287 коммитов** (+17801/−750 строк, 157 файлов). Upstream сам не пушил main после релиза: main старше собственного тега v0.13.0. В форке пока только `main`, ветки `experimental/keenetic-arm64` нет.

**Локальные синтетические проверки (без сети к устройствам/сервисам), Go 1.27.0 host:**
1. `CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags="-s -w"` @ `4f9c786` — **успех**, ELF 28 311 712 байт (~27 MiB). → ARM64-сборка = VERIFIED.
2. Сборка windows/amd64 + запуск `--help` и разбор флагов — успех; негативные проверки: `--transport=direct` в classic-режиме отклоняется («Unknown transport type: direct» — direct доступен только в Session-режиме `--transports`), без `--encryption-key-file` при `--transports`/direct — чистый отказ с ошибкой чтения ключа. Ничего не слушало, никуда не подключалось.

---

## 1. Executive summary

**Кандидат №1 (рекомендация): OpenFlux v0.13.0 (`4f9c786`) как второй KAS-провайдер — CONDITIONAL GO.**

Основание — не «больше carriers», а конкретные инженерные факты:

1. **Официальная linux/arm64 сборка без CGO** — VERIFIED локально (п.0); headless-режим `--inbound=socks5` является дефолтом на Linux (main.go:270,671-675), TUN не нужен.
2. **Нативный loopback SOCKS5 с TCP CONNECT и UDP ASSOCIATE** (socks5/socks5.go:226-234) — единственный из кандидатов с UDP «из коробки» без второго процесса.
3. **Собственная exit-сторона без чужой инфраструктуры**: `direct` (AES-256-GCM TCP) и `phpbox` (self-hosted PHP), режимы l3/l4 — уровень независимости L3 (см. §6).
4. **Строгий запрет legacy**: `--negotiate` исключает classic-fallback на обеих сторонах (PROTOCOL_NEGOTIATION.md:145-163, classic_compat.go:11-23).
5. **Совместимость с Provider Contract v0 (PR #175)**: роль/статусы/пробы ложатся на схему без изменения контракта (§11).

Условия GO (без них физический тест не начинать): синхронизация форка на `4f9c786`, CI-безопасность по решению #142, измерение RSS на NC-4210, явная обработка локального DNS-резолва (§8), pin `127.0.0.1:1083` вместо дефолтного `:1080`.

**Кандидат №2 (резерв): MAX-TURN провайдер на Go-библиотеке swinter `vpnlib`** (Unlicense/public domain) — MAX-аутентификация (api.oneme.ru:443, msgpack, opcode 78) + DTLS/TURN (vendored из vk-turn-proxy, MIT) + wireguard-go; SOCKS5-фасад достраивается по паттерну wireproxy/wiresocks. CONDITIONAL/DEFER: требует MAX-аккаунта (SMS+2FA), «фантомного» звонка реальному пользователю, `InsecureSkipVerify` под российский CA, и остаётся инфраструктурой компании VK (MAX — продукт VK), т.е. L1-независимость.

**NO-GO / DEFER:** WhiteTransport runtime (подтверждено ранее, #139); CSQTT — технологический резерв VK-транспорта (PolyForm Noncommercial 1.0.0, та же VK-инфраструктура, MIPSel не заявлен, нужен свой CSQTT-сервер); FOCSQ (форк csqtt без LICENSE-файла, десктопный TUN); OpenFlux `oneme`/`telemost` как первые carriers на роутере (аккаунт MAX / CPU-heavy VP8-кодирование соответственно) — допускаются позже как дополнительные lanes, не как основа.

---

## 2. Новые находки относительно прежних исследований (#139/#142/#162/#141, PR #171)

1. **Удаление Session bonding в 0.13.0** (коммит `57174c1`; CHANGELOG 0.13.0 «Removed»): `--bonding`/`Bonding = yes` игнорируются, носители объединяются StripedTransport-группами (`transport/registry/group.go`, `mixed.go`, `--transport=mixed`). Старые материалы (#142, PR #171) описывали bonding — это устарело.
2. **Двойной лимит 256 у SOCKS5**: ранее учитывался только «256 UDP-потоков»; фактически есть и жёсткий лимит 256 одновременных клиентских соединений (socks5.go:153, новые соединения молча закрываются), и 256 destination на UDP-ассоциацию (socks5.go:406-409).
3. **Локальный DNS-резолв на клиенте** (tunnel/tunnel.go:382-395): в `--inbound=socks5` домен из SOCKS-запроса резолвится системным резолвером роутера, до туннеля. Прежние формулировки «DNS через туннель» для OpenFlux неверны; IPv6 при этом отказывается явно («IPv6 not supported», tunnel.go:413-419) — leak через v6 закрыт отказом, а не туннелированием.
4. **L4-exit и upstream-proxy**: TCP выхода может идти через внешний SOCKS5 (`--upstream-proxy`, tunnel/upstream.go), но **UDP всегда выходит с самого exit-хоста напрямую** (upstream.go:20-21, 103-108) — новая для нас семантика, важная для threat model.
5. **Telemost-носитель требует `--inbound=socks5`** (main.go:905-906: под TUN не работает) — и это полный WebRTC-клиент: WS-сигналинг + 2 PeerConnection, байты внутри VP8/H264-кадров, генерируемых из canvas (yandex/telemost.go:1-6, canvas_*.go) — CPU-затратный класс, для MIPSel/слабых ARM64 в первый этап не рекомендуем.
6. **Профиль LowMemory существует** (registry.go:36-38, 69, 234): MaxQueueSize 512 вместо 1024 + SlimVolgaConfig — прецедент встраивания низкоресурсного профиля, но ориентирован на телефоны (iOS Network Extension), не на 256/512 MB роутеры, RSS-данных нет.
7. **phpbox** — self-hosted exit на одном PHP-файле (long-poll GET вниз + короткие POST вверх, token+session; phpbox/client.go:12-19): дешёвая L3-exit-опция без VPS-демона.
8. **Script-носители (.flux/.js) исполняются goja внутри бинарника** с ed25519-пиннингом pubkey и каналами обновлений stable/nightly (transport/script/) — расширяемость есть, но на роутере первого этапа отключаемо и не нужно.
9. **Swinter — это public-domain (Unlicense) Go-библиотека `vpnlib`** с MAX-аутентификацией, DTLS/TURN и wireguard-go (swinter-ios golib/go.mod), т.е. юридически чистый донор для MAX-провайдера; Android-вариант пока имеет только SMS/binary-TCP источник креденшелов, WebRTC-путь только в iOS (swinter-android README).
10. **maxcalls** (cdcba2d) — отдельная reverse-engineered Go-библиотека call-API MAX (WS-аутентификация OneMe, HTTP calls API, signaling) — альтернативный источник креденшелов/сигналинга для MAX-провайдера.
11. **CSQTT подтверждённо использует VK calls API** (vk_js_calls.rs:223 `messages.getCallToken`, :359 `calls.forceFinish`; auth.rs:471/487 `calls.getAnonymousToken` на api.vk.ru + slider captcha) — вопрос «повышает ли CSQTT независимость от WDTT» закрыт: **нет**, это вторая реализация того же VK-транспорта.
12. **SOCKS5-режим CSQTT — не нативный Rust-код клиента**: в android-форке это MODE_SOCKS5 (Constants.kt:103) поверх внешних `hev-socks5-server`/`hev-socks5-tunnel` + `csqtt-cascade` (app/src/main/assets/deploy.sh:863,877), т.е. двух- и трёхпроцессная схема.
13. **FOCSQ** (luminescq/focsq, `9ad3bfb`) — десктопный Flutter+Rust форк csqtt (Wintun/Netlink TUN, `udp_batch.rs` — QUIC/批量 TURN), **без собственного LICENSE-файла** в корне — юридически непригоден для включения; только как справка о существовании QUIC-варианта.
14. **Феномен «тихого main»**: у upstream OpenFlux тег релиза опережает main на 287 коммитов — пинноваться надо на тег/коммит, не на ветку.

---

## 3. Source audit OpenFlux v0.13.0 (`4f9c786`)

### 3.1 Архитектура клиента и exit-ноды

Два процесса-роли в одном бинарнике: `--role=client` и `--role=exit` (main.go:269). Client: inbound `tun|socks5` (на Linux дефолт socks5), поверх Session-слоя носители. Exit: `--mode=l3` (kernel TUN, root, полный IP-выход с UDP/NAT/ICMP) или `--mode=l4` (gVisor TCP-эндпоинты, работает без root, TCP опционально через `--upstream-proxy` SOCKS5, UDP напрямую с хоста; tunnel/exit.go:20-31, upstream.go). Exit обслуживает **ровно одного активного клиента** на общий секрет: захват сессии только через свежий challenge (PROTOCOL_NEGOTIATION.md:70-79).

Exit-сторона также распространяется как «node» (deploy/node-install.sh, пин node-v1.6.0 на релизы upstream), но для KAS достаточно прямого `--role=exit` без wizard.

### 3.2 SOCKS5 TCP CONNECT и UDP ASSOCIATE

`socks5/socks5.go`: CONNECT (0x01) и UDP ASSOCIATE (0x03), BIND → 0x07 (строки 226-234). Опциональный RFC1929-auth с constant-time сравнением (285-313), по умолчанию auth выключен. Жёсткие пределы: 256 клиентских соединений всего (153), 256 UDP-destination на ассоциацию (406-409), idle-deadline потока 2 мин (425/442/455), буферы 64 KiB. Ассоциация: bind-IP наследует IP листенера (334-339), адрес клиента пиннится по IP+порту (353-357, 381-390), адрес ассоциации не резолвится локальным DNS (329-333). Паника обработчика изолируется на соединение (171-175).

### 3.3 Headless ARM64 без GUI и TUN

Флаги GUI отсутствуют; мобильные панели — отдельные приложения (mobile/, ios-app/), в бинарник не входят. `--inbound=socks5` — дефолт вне macOS (main.go:671-675). Сборка: build_all.sh:50 (`CGO_ENABLED=0`), цели linux/amd64+arm64 (92-93). Все тяжёлые зависимости (gVisor netstack, pion/webrtc, goja) — чистый Go. VERIFIED локальной сборкой (п.0). GUI-библиотек нет; `--share`/`--ipc-socket` — опциональны.

### 3.4 Session, Registry, Transport, StripedTransport

- `transport.Transport` — интерфейс Start/Stop/Send/Receive/IsConnected/Stats (transport.go:21-28); BaseTransport даёт reconnect-конфиг: MaxReconnectAttempts 999999, ReconnectDelay 0, multiplier 1.1, MaxQueueSize 1024, KeepAlive 10s (53-61).
- `Session` (session.go): mutually-authenticated envelope-слой; носители упорядочены по priority (insertByPriority, 356), маршрутизация «данные и control — по старшему живому», потоки хэшируются только по живым носителям одного приоритета (PROTOCOL_NEGOTIATION.md:100-106, session.go:908-940, 1086). Replay-window 4096, дедупликация, без ack/retransmission (146-148, 1566-1607).
- `Registry` (registry/registry.go) — единая фабрика типов `["yandex","vyandex","boards","mailru","cupsonline","avito","telemost","bitrix24","oneme","direct","script"]` (44); same-type группы ссылок через `,`/`|` → один StripedTransport (group.go), разнотипные → внешний stripe (`--transport=mixed`, mixed.go).
- `StripedTransport` (striped.go, 1760 строк) — lanes с per-lane RTO/CoDel/окнами, health-deadline, SetBatchHint.

### 3.5 Приоритеты, failover, reconnect, cleanup

Приоритеты задаются в `--transports "direct:100,mailru:50,cupsonline:40"`. Носитель, чей Start упал (например captcha), ретраится экспоненциально 1→30 с и подключается позже; liveness: LinkPing каждые 10 c тишины, «живой» = услышан ≤30 c; смерть exit-сервера → тайм-аут линка → сброс сессии и новый handshake под новым challenge, носители продолжают ретраи (PROTOCOL_NEGOTIATION.md:92-106, 81-84). direct: dialLoop с backoff 200 ms→15 s (direct.go:281-330); cleanup UDP-потоков — 2-минутные дедлайны; MaxSessionAge у Volga ротирует WS по возрасту.

### 3.6 Изменения после удаления bonding

Коммит `57174c1` (в диапазоне main..v0.13.0). Вместо bonding-пары: same-type stripes (group.go: несколько ссылок одного типа = одна полоса), mixed-страйп разнотипных (mixed.go), make-before-break ротация Mail.ru (CHANGELOG 0.13.0). Существующие `.conf` с `Bonding = yes` не падают — флаг игнорируется с логом (CHANGELOG «Removed»). Сетевой выбор выхода носителя — `Network =`/netbind остался.

### 3.7 Шифрование, negotiation, ключи, запрет legacy

Session-слой: envelope внутри AEAD, взаимные 256-bit challenge, роли client/exit, capabilities bitmap (IPv4, TCP, UDP, ICMP-errors; бит wire-v3 отозван и отвергается), лимит пакета 1280..65000 (PROTOCOL_NEGOTIATION.md:33-55). Ключ: статический общий секрет, scrypt с публичной солью `SHA-256("OpenFlux encrypted transport v1\0" + context)`; **forward secrecy, ротация и защита после компрометации секрета явно НЕ заявлены** (175-206). KDF-context выводится по правилам (session-context → --url → старший носитель → `http://#`) с alternate-перебором.

Запрет legacy: `--negotiate` — строго, без classic-fallback на обеих сторонах; Session-сконфигурированный exit вообще не отвечает classic-клиентам (dropped+logged) (145-163; classic_compat.go:11-23). Дополнительно classic-режим клиента не умеет `direct` вовсе (проверено п.0: «Unknown transport type: direct») — собственный exit по построению требует Session/ключа.

### 3.8 Поведение при потере exit

Client: тайм-аут тишины по всем носителям → дроп сессии → повторный handshake (как у перезапущенного exit); прямые reconnect-циклы носителей продолжаются; после ответа exit возможна бесшовная замена пира только через свежий challenge (replay старого трафика замену не даёт). Exit: никогда не инициирует; перезапуск exit ничего не знает о старой сессии.

### 3.9 Отключение direct и обходных WAN-маршрутов

Термин `direct` в OpenFlux — это **носитель к собственному exit**, а не fallback на WAN. Автоматических обходных маршрутов в коде клиента не обнаружено: носители dial'ят через netbind (выбор интерфейса по TransportConfig.Network), без изменений таблицы маршрутов процесса; fakedns.go работает только в TUN-режиме. Гарантия «без direct» достигается конфигурацией: профиль без `direct:`-элемента и без `--direct-dial`; StrictDirect в registry даёт ошибку вместо тихого старта (registry.go:50-53). Оговорка (неснижаемый остаток): локальный DNS-резолв клиента идёт мимо туннеля (§8), т.е. «ни одного пакета мимо туннеля» для доменных соединений без дополнительной DNS-политики роутера не выполняется.

### 3.10 Потенциально неограниченные очереди, goroutine, UDP flows

Найденные пределы: pre-batch очередь на носитель MaxQueueSize 1024 кадров (LowMemory 512); batch-очередь 256 записей ≈ ≤16 MiB на носитель (batched.go:22); SOCKS5 256 conns / 256 UDP flows, буферы 64 KiB; direct — bounded queue с дропом и счётчиком (direct.go:199-224). «Бесконечное» одно: reconnect-счётчик (999999) — это счётчик, не очередь. Неограниченного роста очередей/goroutine не найдено; риск RAM — не утечка, а **сумма легальных пиков**: ~16 MiB × активных носителей + gVisor-стек + pion (если oneme/telemost) + goja (если script). Оценка RSS — UNKNOWN до измерений.

### 3.11 Носители (carriers) — сводка

| Носитель | Инфраструктура/оператор | Полезная нагрузка | TCP/UDP до exit | Аккаунт/CAPTCHA | Headless | Подтверждённость |
|---|---|---|---|---|---|---|
| yandex (Документы) | Яндекс (docs.yandex.ru) | WS coediting, cursor-поле | IP-пакеты поверх WS/TCP | без аккаунта; SmartCaptcha: внутренний PoW-солвер (captcha.go:21,121), при отказе — ручная сдача cookies через AuthRequired/loopback-proxy (NEGOT.md:127-143) | да | SOURCE_CONFIRMED (код+тесты); E2E upstream CLAIMED |
| vyandex (Volga) | Яндекс (volga.yandex.ru) | HTTP-relay+WS, батчи | IP-пакеты | **требует cookies логина** (--yandex-cookies-file) | да | SOURCE_CONFIRMED |
| boards | Яндекс (boards.yandex.ru) | WS белой доски | IP-пакеты | без аккаунта | да | SOURCE_CONFIRMED |
| mailru | Mail.ru (docs.datacloudmail.ru) | cursor-поле coediting; батч ≤500 KB; сервер режет соединение после ~дюжины сообщений → make-before-break ротация | IP-пакеты | **без аккаунта**, публичный документ | да | SOURCE_CONFIRMED |
| cupsonline | cups.online (interview.cups.online/live-coding) | комнаты-«интервью», стрипы RTO/CoDel | IP-пакеты | без аккаунта; комнаты создаёт exit (CUPS_ROOMS=8 по умолчанию) | да | SOURCE_CONFIRMED |
| avito | Avito (code.avito.ru) | ShareDB-комнаты | IP-пакеты | **требует cookies** аккаунта | да | SOURCE_CONFIRMED |
| bitrix24 | Bitrix24 (`*.bitrix24.ru`) | чат-сообщения base64 + polling | IP-пакеты | **требует cookies портала** (PHPSESSID+kernel+sessid) | да (polling) | SOURCE_CONFIRMED |
| telemost | Яндекс (telemost.yandex.ru) | WS-сигналинг + 2 WebRTC PeerConnection, байты в VP8/H264 canvas-кадрах | IP-пакеты в видео | без аккаунта (вход по ссылке) | да, **только inbound=socks5** (main.go:905-906); CPU-тяжёлый | SOURCE_CONFIRMED |
| oneme | MAX / OneMe (VK) | WS JSON (MaxPacket) + pion/webrtc v4 DataChannel | IP-пакеты | **MAX token+uid** (аккаунт) | да | SOURCE_CONFIRMED |
| direct | свой сервер | length-prefixed TCP ≤65535, AES-256-GCM обязателен | IP-пакеты | без аккаунта, только ключ | да | SOURCE_CONFIRMED |
| phpbox | свой сервер (PHP) | long-poll GET + POST, token+session | IP-пакеты (в т.ч. поверх другого носителя) | без аккаунта, token | да | SOURCE_CONFIRMED |
| script (.flux/.js) | определяется скриптом | goja внутри процесса | IP-пакеты | зависит от скрипта; ed25519-pin pubkey | да | SOURCE_CONFIRMED |

**Зависимости внутри семейств Яндекса**: yandex/vyandex/boards/telemost — четыре носителя одного оператора; отказ/блокировка на стороне Яндекса бьёт по всем четырём. mailru — отдельная компания; cups.online, Avito, Bitrix24 — отдельные; direct/phpbox — свои. Группа «независимых носителей» первого этапа: **direct + mailru + cupsonline** (три разных юрлица/инфраструктуры, ни один не требует аккаунта).

---

## 4. MAX TURN (Swinter) vs MAX WebRTC DataChannel (oneme/maxcalls)

Общее: обе технологии — инфраструктура MAX (OneMe), продукт компании VK; «независимость от VK» у обеих только инфраструктурная (другие релеи/серверы, другой протокольный след), не корпоративная. Технологии **не взаимозаменяемы**.

### B1. MAX TURN + DTLS + WireGuard (swinter)

- Аутентификация: нативный бинарный протокол MAX — TLS к api.oneme.ru:443, 10-байтный заголовок + MessagePack (max_creds.go:22-26), логин сохранённым token (получается один раз по SMS+2FA через приложение/сервис), вызов opcode 78 «звонок» целевому пользователю → из ответа извлекаются TURN- креденшелы → немедленный сброс («краткий фантомный звонок», README). `deviceType=ANDROID` обязателен — WEB блокирует SMS.
- Туннель: pion/dtls v3 self-signed + pion/turn v5 Allocate → локальный UDP-«провод» для wireguard-go (turn.go:612 startTurnProxy, oneTurnConnection:416). Паттерн и часть кода vendored из cacggghp/vk-turn-proxy (MIT) — **тот же upstream, что у WDTT** (turn.go:5-8), т.е. B1 технологически — «WDTT с другим источником креденшелов».
- Server-side: свой VPS: vk-turn-proxy-server (UDP:56000, приём DTLS от TURN) → WireGuard (51820/udp); setup-server.sh + SERVER.md. То есть exit-сторона полноценная и своя.
- Клиентская сторона: VPN/TUN-ориентированная (tun2socks.go на gVisor, dns_proxy.go, обвязки per-OS). **Готового headless-бинарника с loopback SOCKS5 нет** — для KAS потребуется новый тонкий binary: max_creds+turn+wg (всё уже есть в vpnlib как библиотека) + SOCKS5-фасад (паттерн wireproxy/wiresocks, MIT, wireguard-go+netstack). Объём работ: средний, всё public-domain/MIT.
- Риски/требования: аккаунт MAX (SMS, 2FA), фантомные звонки живому пользователю (ToS/этика — отдельное owner-решение), `InsecureSkipVerify: true` под российский CA (max_creds.go:46) — для KAS-провайдера придётся заменить на pinned CA, иначе блокер по политике секретов; креденшелы короткоживущие, re-auth on demand.

### B2. MAX WebRTC DataChannel (OpenFlux oneme; maxcalls)

- OpenFlux-носитель `oneme`: MaxPacket JSON поверх WebSocket (max_data.go:23-33), из сигналинга приходят Turn/Stun IceServer и WebRTCConfig{tkn,wse} (34-45), далее pion/webrtc v4 DataChannel (max_transport.go). Требует MAX token+uid. Cookies не нужны (socks5.go коммент «Ignored for … oneme»).
- maxcalls (cdcba2d) — библиотека того же call-API (WS-аутентификация, HTTP calls, signaling) без транспортной обвязки; годится как будущий источник сигналинга, сам по себе транспортом не является.
- Сравнение с B1: B2 не требует второго VPS-компонента при использовании внутри OpenFlux (exit — обычный OpenFlux-exit), но требует аккаунта MAX и держит живой звонок/сессию; B1 даёт полный WG-туннель на свой VPS и не зависит от API-логики звонков после получения креденшелов.

### Вывод по B

- Проще для ARM64 Keenetic: **B2 как носитель внутри уже рекомендуемого OpenFlux** (нулевая дополнительная разработка); B1 — отдельная разработка провайдера.
- Ближе к самостоятельному headless-бинарнику: **B1** (vpnlib уже Go-библиотека, не хватает CLI+SOCKS5-фасада).
- Локальный SOCKS5 без системного TUN: B1 — только через достройку (wireproxy-паттерн); B2 — да, средствами OpenFlux inbound=socks5.
- Выходная сторона: B1 — свой VPS (vk-turn-proxy + WG); B2 — OpenFlux-exit (свой VPS тоже).
- Готовность исходников: B1 — библиотека+скрипты сервера (полный цикл, но клиентские обвязки мобильные); B2 — полный client/exit в OpenFlux.
- Данные аккаунта: у обеих — постоянный токен MAX; хранение только в owner-файле 0600, в логи не печатать (прецедент политики — WDTT #40/#41); утечка токена = компрометация аккаунта.
- RAM/CPU: RSS UNKNOWN у обеих; B2 тащит pion/webrtc (тяжелее), B1 — wireguard-go+pion/dtls/turn (средне).

**Рекомендация по B:** MAX-WebRTC (B2) — как опциональный носитель OpenFlux позже; MAX-TURN (B1) — Кандидат №2 (резервный самостоятельный провайдер), после owner-решения по аккаунтам/ToS и замены InsecureSkipVerify.

---

## 5. Актуальное состояние CSQTT

- Ревизии: amurcanov/csqtt `d02da9b` (2026-10-20, активный), danusha2345/csqtt-android `5c3cf03` (OpenWrt-пакет 2.1.17-2), saymer-alt/csqtt `71712b0` (форк-зеркало).
- VK-зависимость: подтверждена в коде клиента (vk_js_calls.rs:223/359, auth.rs:21/471/487 — api.vk.ru/api.vk.me, slider captcha). **Второго независимого провайдера не даёт.**
- Rust SOCKS5 TCP-only: в актуальном клиенте нативного SOCKS5-прослушивателя нет (grep по rust-client пуст); SOCKS-режим существует в android-форке как композиция с внешними hev-socks5-server/tunnel + csqtt-cascade (deploy.sh:863,877; Constants.kt:103) — 2–3 процесса. Вариант (A) «native --socks5 TCP-only + CSQPX2» относится к более ранним ревизиям/веткам; в текущем дереве основная точка входа — TUN (tun.rs).
- ARM64 Entware: сборка aarch64-unknown-linux-musl описана (cargo-zigbuild, Rust 1.97.1, openwrt/README.md); целевые архитектуры x86_64/aarch64/armv7; **MIPS/MIPSel прямо не заявлены** — потребуется самостоятельная сборка Rust-std под target. procd/UCI/firewall-обвязка OpenWrt на Keenetic как есть не ставится (несовместимо, подтверждает #139).
- Своя серверная сторона обязательна (rust-server: dataplane/tproxy/tun_device/web_panel); с ONYX18/qWDTT-профилем несовместим (уже зафиксировано в #139).
- Лицензия: **PolyForm Noncommercial 1.0.0** во всех трёх репозиториях + явный запрет коммерческого использования в README. Для KAS-распространения это фундаментальное ограничение (проверять с owner отдельно, если когда-либо понадобится).
- Одно- vs двухпроцессный клиент: базово один процесс (TUN-клиент), SOCKS-варианты — минимум два процесса (hev-socks5). RAM: RSS UNKNOWN; источник риска — tokio-рантайм + worker-пулы (cpu_task.rs, worker.rs).
- **Вердикт: DEFER. Технологический резерв реализации VK-транспорта** (вторая независимая кодовая база того же класса) — не второй провайдер по независимости.

---

## 6. Матрица независимости инфраструктур

Уровни: **L0** — VK-calls TURN (та же инфраструктура, что у WDTT); **L1** — MAX/OneMe (другая инфраструктура, та же компания VK); **L2** — сторонние операторы (Яндекс, Mail.ru, cups, Avito, Bitrix24); **L3** — собственная инфраструктура (свой VPS).

| Кандидат | Уровень | Обоснование |
|---|---|---|
| WDTT | L0 | VK TURN обязателен — SOURCE_CONFIRMED |
| CSQTT | L0 | VK calls API + captcha — SOURCE_CONFIRMED (§5) |
| MAX TURN (B1) | L1 | MAX-релеи; компания VK — SOURCE_CONFIRMED |
| MAX WebRTC (B2) | L1 | MAX сигналинг/STUN/TURN — SOURCE_CONFIRMED |
| OpenFlux (oneme-first) | L1 | тот же MAX — SOURCE_CONFIRMED |
| OpenFlux (yandex/vyandex/boards/telemost) | L2 | оператор Яндекс; 4 носителя = одна точка отказа оператора |
| OpenFlux (mailru / cupsonline / avito / bitrix24) | L2 | четыре разных оператора; mailru/cups — без аккаунта |
| OpenFlux (direct / phpbox) | **L3** | только свой VPS, сторонние сервисы не участвуют |
| Свой TURN (coturn) + DTLS-клиент | **L3** | полный самоконтроль релеев (теоретическая опция, кода под KAS нет) |

Ключевой вывод: **только OpenFlux одним бинарником покрывает L3+L2+L1 одновременно** и позволяет строить профиль с разными юрлицами-операторами (direct+mailru+cupsonline), что и есть измеримая устойчивость к блокировкам/отказам одной инфраструктуры. WDTT+CSQTT дублируют друг друга (L0), MAX-варианты дублируют компанию (L1).

---

## 7. Матрица технических возможностей

| Критерий | WDTT | OpenFlux v0.13.0 | MAX TURN (B1) | MAX WebRTC (B2) | CSQTT |
|---|---|---|---|---|---|
| Независимость от VK (инфраструктура) | UNSUPPORTED | SOURCE_CONFIRMED (direct/mailru/cups и др.) | SOURCE_CONFIRMED (MAX-релеи) | SOURCE_CONFIRMED (MAX) | UNSUPPORTED |
| Независимость от других внешних сервисов | SOURCE_CONFIRMED (свой exit) | SOURCE_CONFIRMED (direct/phpbox-профиль) | SOURCE_CONFIRMED (свой VPS) | CLAIMED (OpenFlux-exit, сигналинг MAX) | SOURCE_CONFIRMED (свой rust-server) |
| ARM64 Linux | VERIFIED (owner-сборки, PR #34/#42) | VERIFIED (локальная сборка, §0) | UNKNOWN (библиотека Go, CLI не собран) | VERIFIED (через OpenFlux, §0) | SOURCE_CONFIRMED (aarch64 musl, cargo-zigbuild) |
| MIPSel | VERIFIED (owner) | UNKNOWN (вне build-матрицы; gVisor чистый Go, но не проверено) | UNKNOWN | = OpenFlux | UNSUPPORTED (прямо не заявлен) |
| Headless | VERIFIED (owner-lab) | SOURCE_CONFIRMED (socks5-inbound дефолт Linux) | UNKNOWN (нужен новый CLI-бинарник) | SOURCE_CONFIRMED (внутри OpenFlux) | SOURCE_CONFIRMED (TUN-клиент) |
| SOCKS TCP | VERIFIED | SOURCE_CONFIRMED (CONNECT, лимит 256 conns) | UNSUPPORTED (нет; tun2socks только) | SOURCE_CONFIRMED (= OpenFlux) | CLAIMED (hev-socks5 композит) |
| SOCKS UDP | VERIFIED (IPv4-only) | SOURCE_CONFIRMED (ASSOCIATE, 256 flows, 2-min idle) | UNSUPPORTED (нужна достройка) | SOURCE_CONFIRMED (= OpenFlux) | UNSUPPORTED в SOCKS-режиме (TUN даёт UDP) |
| Локальный loopback bind | VERIFIED (конфиг) | SOURCE_CONFIRMED (bind=IP листенера; дефолт :1080 надо переопределять) | UNKNOWN | SOURCE_CONFIRMED | UNKNOWN (hev-socks5 конфиг) |
| Собственная exit-сторона | VERIFIED | SOURCE_CONFIRMED (direct AES-256-GCM / phpbox / l3 / l4) | SOURCE_CONFIRMED (vk-turn-proxy+WG) | SOURCE_CONFIRMED (OpenFlux-exit) | SOURCE_CONFIRMED (rust-server) |
| Наличие client/server | VERIFIED | SOURCE_CONFIRMED (обе роли, E2E-тесты в репо) | SOURCE_CONFIRMED (vpnlib + server-скрипты) | SOURCE_CONFIRMED | SOURCE_CONFIRMED |
| Шифрование | SOURCE_CONFIRMED (DTLS+WRAP/RTP-AEAD+WG) | SOURCE_CONFIRMED (AES-256-GCM, scrypt; **без forward secrecy** — заявлено в доках) | SOURCE_CONFIRMED (DTLS+WG) | SOURCE_CONFIRMED (DTLS/SRTP WebRTC) | SOURCE_CONFIRMED (обфускация WRAP/SRTP-режимы) |
| Требования аккаунта | VERIFIED (VK-ссылка/токен) | по носителю: 0 для direct/mailru/cups; cookies для avito/bitrix/vyandex; MAX для oneme | SOURCE_CONFIRMED (MAX SMS+2FA) | SOURCE_CONFIRMED (MAX token+uid) | VERIFIED (VK) |
| CAPTCHA/ручная авторизация | VERIFIED (VK, ручная) | SOURCE_CONFIRMED (SmartCaptcha PoW-солвер + ручной fallback через AuthRequired) | UNSUPPORTED для MAX (SMS); vendored VK-slider для legacy-пути | UNSUPPORTED для MAX | SOURCE_CONFIRMED (VK slider) |
| Защита от direct fallback | SOURCE_CONFIRMED (fail-closed) | SOURCE_CONFIRMED (носители только из профиля; classic не умеет direct; локальный DNS — оговорка §8) | SOURCE_CONFIRMED (WG-пир один) | SOURCE_CONFIRMED | SOURCE_CONFIRMED |
| Потребление RAM | VERIFIED (WDTT #25: VmHWM 111–135 MB owner-lab; PR #34 ~26 MiB smoke) | **RSS UNKNOWN** (пики: batch ≤16 MiB/носитель, MaxQueueSize 1024 кадров, gVisor, pion при oneme/telemost, goja при script) | **RSS UNKNOWN** (wg+pion) | **RSS UNKNOWN** (pion/webrtc) | **RSS UNKNOWN** (tokio, worker-пулы) |
| Зависимости | Go, gVisor netstack | Go: gVisor, pion/webrtc v4, goja, websocket, compress/lz4; CGO=0 | Go: wireguard-go, amneziawg-go, pion dtls/turn, gvisor, sing/vless/vmess/hysteria2 (можно сузить) | pion/webrtc v4 (внутри OpenFlux) | Rust: tokio, vendored primp; server отдельно |
| Лицензия | private/owner | **GPL-3.0** (NOTICE/COPYRIGHT сохранены) — только отдельный процесс | **Unlicense** (public domain) | = OpenFlux (GPL-3.0) | **PolyForm Noncommercial 1.0.0** |
| Готовность к физическому тесту | VERIFIED (PR #34/#42, ожидает owner-приёмки) | CONDITIONAL: fork→4f9c786, CI, RSS-замер | RESERVE: нужен CLI+SOCKS5-фасад | CONDITIONAL (как носитель OpenFlux) | DEFER |

Не переносить: RAM-цифры WDTT на OpenFlux нельзя (другой рантайм и стек); размер ELF (27 MiB stripped) ≠ RSS.

---

## 8. Threat model и риски

1. **DNS-частичность (OpenFlux, существенно):** домены из SOCKS CONNECT резолвятся локально на роутере (tunnel.go:382-395) → DNS-запросы идут по локальной политике роутера, а не через туннель. При интеграции: (a) документировать как свойство провайдера; (b) в лабе сверить, что DNS-политика Keenetic/Mihomo направляет резолв туда, куда ожидает owner; (c) опционально — future RFE upstream на remote-resolution. IPv6 — отказ, а не fallback (хорошо).
2. **L4-exit UDP-байпас:** если exit работает в l4 с `--upstream-proxy`, UDP не следует в прокси, а выходит с хоста exit (upstream.go:103-108). Для собственного VPS это норма; для схем «скрыть IP exit за другим прокси» — неожиданность. В KAS-документации фиксируем: l3-предпочтительно.
3. **Статический секрет без FS (OpenFlux):** компрометация ключа = пассивная расшифровка всего периода использования. Смена ключа = ротация на обеих сторонах вручную. Хранение: owner-файл 0600 рядом с конфигом; в статус/логи не печатать; `--sensitive` никогда не включать (включает логирование ключевого материала и plaintext-кадров, main.go:332).
4. **Дефолты, небезопасные для роутера:** `--socks5 :1080` слушает все интерфейсы и без auth (по умолчанию). Обязательно: `--socks5=127.0.0.1:1083` (+ RFC1929 auth, если Proxy Client поддерживает) — иначе открытый прокси в LAN.
5. **Один клиент на exit-секрет:** два клиента с одним секретом «перехватывают» сессию друг у друга (PROTOCOL_NEGOTIATION.md:70-79). На практике — один exit на устройство; в лабе не шарить секреты.
6. **HTTP-прокси проверки капчи** поднимается на loopback без auth на время прохождения проверки (NEGOT.md:139-143) — точечный локальный риск, приемлем на роутере, но фиксируем.
7. **256-лимиты SOCKS5:** молчаливое закрытие 257-го соединения (socks5.go:153-156) может выглядеть как «прокси врёт»; для Keenetic Proxy Client-фан-аута держать лимиты в doctor-проверках.
8. **CAPTCHA-контур Яндекса:** PoW-солвер может переставать работать при изменении антиабьюза; при отказе требуется интерактивная сдача cookies с IP exit (браузером человека) — не автоматизируем, фиксируем как регламент.
9. **Аккаунтные носители (avito/bitrix24/vyandex/oneme):** cookies/токены = доступ к личным кабинетам; хранить только в owner-файлах, в acceptance-фикстурах — только синтетика (правило WDTT-практики). oneme/telemost на первом этапе не включать (аккаунт MAX; CPU canvas-кодирования).
10. **GPL-3.0 OpenFlux:** только отдельный процесс, без линковки в KAS; сохранение LICENSE/NOTICE в форке; не перелицензировать (решение #142 уже это фиксирует).
11. **Swinter-специфика (если Кандидат №2 когда-либо стартует):** `InsecureSkipVerify` к api.oneme.ru (max_creds.go:46) — блокер, замена на pinned CA обязательна; фантомные звонки — этика/ToS, только owner-GO; токен MAX в файле 0600.
12. **CSQTT:** PolyForm Noncommercial ограничивает распространение; VK-инфраструктура = нет выигрыша в устойчивости; не рассматривать как независимого провайдера.

---

## 9. Прогнозные ограничения Keenetic (без вымышленных RSS)

Целевые классы: NC-4210 (ARM64) — первичная платформа; KN-1012 (512 MB, совместный KAS+транспорт с Mihomo) — важная цель; KN-1010 (256 MB) — не обязателен для первой версии.

Источники расхода памяти OpenFlux (все — SOURCE_CONFIRMED кодом, пики не измерены):

- batch-очередь: ≤256 записей × ≤65000 B ≈ ≤16 MiB на носитель в худшем случае (batched.go:22, max-packet 65000); pre-batch MaxQueueSize 1024 кадров (512 LowMemory).
- gVisor netstack (клиент socks5-режима и l4-exit): константа + на коннект.
- pion/webrtc — только если включены oneme/telemost; goja — только при script-носителях. На первом этапе не включаем → эти блоки в RSS не попадают (linker выбрасывает недостижимый код не всегда — проверять фактический бинарник).
- goroutines: единицы-десятки на носитель (чтение WS, writer, keepalive) — на 256-лимитах SOCKS5 умножается осторожно.
- UDP: 64 KiB-буферы × ≤256 flows на ассоциацию — теоретический максимум десятки MiB; практический — по числу реальных flows.

Правило KAS «KAS+WDTT ≥512 MB» (#137) на OpenFlux **не переносится автоматически**: admission-порог для openflux-провайдера выставится после измерений (admission_min_mb + measured=false до лабы — по схеме PR #175). Для 27 MiB stripped ELF ожидаемый RSS-порядок — «сотни МБ невозможны, десятки МБ реалистичны», но это гипотеза для проверки, не факт.

MIPSel: вне build-матрицы upstream; теоретически чистый Go собирается под mipsle, но gVisor/pion на big-endian-независимом mipsle не проверены никем → статус UNKNOWN, в первый этап не берём.

---

## 10. Выбор победителя (GO/NO-GO)

**Кандидат №1 — OpenFlux v0.13.0 (`4f9c786`), профиль direct + mailru + cupsonline, --negotiate: CONDITIONAL GO.**

Аргументы (по критериям §8 задания):

1. Реальная независимость от VK: да — профиль без VK/MAX-носителей (L3+L2, §6).
2. Headless SOCKS5 для Keenetic: да, дефолтный режим Linux, TUN не нужен.
3. Совместимый собственный exit-сервер: да — direct (AES-256-GCM) или phpbox, l3/l4.
4. Безопасность/утечки: IPv6 fail-closed; нет обходных WAN-маршрутов; обязательные условия — pin 127.0.0.1:1083, DNS-оговорка §8.1, --negotiate.
5. Шансы на 512 MB рядом с Mihomo: правдоподобны, но **не доказаны** — до физической приёмки RSS UNKNOWN; 256 MB-цель откладываем.
6. Обязательный браузер/постоянная CAPTCHA: нет (для direct/mailru/cups); SmartCaptcha Яндекса — только при использовании yandex-носителя и не автоматизирована.
7. Поддержка/обновления: единый бинарник, registry-фабрика, активный upstream (минус — «тихий main», пиннуемся на теги).
8. Лицензия: GPL-3.0 — процессная изоляция и сохранение атрибутики; распространение допустимо.

Условия, без которых GO не превращается в работу: (a) sync форка на `4f9c786` и только теги; (b) CI-безопасность форка по плану #142; (c) owner GO на лабораторные измерения RSS (NC-4210); (d) запрет oneme/telemost/script на первом этапе.

**Кандидат №2 (резерв) — MAX-TURN провайдер на swinter vpnlib: CONDITIONAL / DEFER.** Юридически чистая база (Unlicense), знакомая WDTT-архитектура (тот же vk-turn-proxy паттерн), но: L1-независимость, аккаунт MAX, фантомные звонки, InsecureSkipVerify-блокер, достройка CLI+SOCKS5. Инициировать только после owner-решения по MAX-аккаунтам.

**NO-GO / DEFER:**
- WhiteTransport как runtime первого MVP — подтверждаем прежний NO-GO (новых оснований нет).
- CSQTT — DEFER: PolyForm NC + VK + MIPSel UNSUPPORTED + свой сервер; хранить как технологический резерв второй реализации VK-транспорта.
- FOCSQ — NO-GO: нет LICENSE, десктопный TUN-фокус, непроверенный форк.
- oneme/telemost как первые носители на роутере — DEFER (аккаунт MAX / CPU).

---

## 11. Архитектура будущего KAS-провайдера (концепция, без реализации MT-003)

`KAS → Transport Provider (openflux) → локальный SOCKS5 127.0.0.1:1083 → Keenetic Proxy Client` (MultiTransport Contract v0, PR #175; адаптер по образцу PR #125; **прим.: 1083 — предварительный пример, реальный конфликт портов проверяется через MT-002 validator перед фиксацией**).

**Процессы.** На роутере один процесс `openflux` (Entware, opt-in): `--role=client --inbound=socks5 --socks5=127.0.0.1:1083 --negotiate --transports "direct:100,mailru:50,cupsonline:40" --encryption-key-file <owner-key> --url-file <owner-url>`. На сервере (свой VPS) — `openflux --role=exit --mode=l3` (или l4 без root), отдельный секрет на устройство.

**Loopback.** Явный bind `127.0.0.1:1083` (никогда дефолт `:1080`); проверка занятости через существующие KAS-пробы + отрицательный fixture MT-002 «два провайдера на одном bind».

**PID ownership.** Полностью переиспользуется механизм PR #125: owned_running() (starttime+exe+argv-сверка), gates SHA256/ELF-arch; pid_verified=true в status.json пишется только после этой сверки (не как самостоятельное доказательство).

**TCP/UDP readiness — раздельно.** Проба 1: TCP CONNECT через 127.0.0.1:1083 на синтетический endpoint exit'а. Проба 2: UDP ASSOCIATE + эхо-датаграмма через тот же loopback. Две отдельные capability-отметки в acceptance/status (по семантике PR #175: UNKNOWN/NOT_TESTED/FAIL/PASS), отсутствие TCP ≠ «UDP работает».

**Блокировка direct-fallback и обходных путей.** Профиль без лишних носителей; `--negotiate` (нет classic); direct только как свой exit по явному `--transports`; DNS — зафиксированное свойство «резолв локальный» + политика DNS роутера/ Mihomo остаётся как есть (KAS ничего в DNS/маршрутах не меняет); IPv6 отказывается сам.

**Stop/restart/rollback.** Supervisor PR #125: старт/стоп по PID-identity, health по status-файлу провайдера, rollback = предыдущий pinned-бинарник + предыдущий owner-конфиг; OpenFlux-специфика: exit может держать старую сессию 20 с (handshake-дедлайн) — в restart-регламенте пауза >20 c перед повторным коннектом при смене ключа.

**Конфиги и секреты.** owner-файлы 0600: encryption-key (общий секрет), url-file (документ-ссылки mailru/room-list), ключ exit'а отдельно на VPS; cookies-файлы (если когда-нибудь vyandex/avito) — только owner-вводом, в acceptance только синтетика; никаких секретов в stdout/логах (правило как в WDTT #40/#41; `--sensitive` запрещён).

**Watchdog.** Новый не нужен: keepalive/liveness внутри Session (LinkPing/30 s), retry-политики внутри носителей; supervisor решает только «процесс жив и тот ли это процесс» (PR #125). Отдельный второй watchdog запрещён архитектурой variant A.

**Contract v0 mapping.** manifest.json: provider_id `openflux`, build/code PRESENT после CI-сборки; resource_requirements: admission_min_mb — заполняется после лабы (measured=false сейчас, admission_source: pending-RSS-measurement). acceptance.json: полевые записи по носителям (artifact_sha256+device+profile+duration). status.json: живое состояние (verdict/loopbackBind/pid).

---

## 12. Конкретный план следующих задач (малые шаги, каждый с owner-гейтами)

1. **Sync форка:** смержить upstream `4f9c786` (или rebase на тег) в `saymer-alt/OpenFlux`, создать `experimental/keenetic-arm64`, protections по решению #142. Без изменений кода.
2. **CI-безопасность форка:** аудит унаследованных workflow (по факту из #142: ci.yml/nightly.yml/node-install.yml/node-release.yml/release.yml) → docs/ci-safety-audit.md + Draft PR с read-only lint/test (contents:read), Actions остаются выключенными.
3. **Сборочный канон:** зафиксировать в форке CI-only job `linux/arm64 CGO_ENABLED=0 go build` (артефакт не публикуется, размер пишется в лог). База сравнения: 28 311 712 B @ `4f9c786` (этот отчёт, §0).
4. **MT-001 манифест openflux:** manifest.json по схеме PR #175 (provider_id `openflux`, capabilities, resource_requirements с measured=false) + валидные/невалидные фикстуры + прогон offline-validator PR #181.
5. **Offline-негативы:** скрипт-чеклист синтетических проверок без сети: отказ classic-режима для direct; отказ без ключа; отказ --sensitive-профиля (grep по wrapper-скрипту); pin 127.0.0.1 в шаблоне конфига.
6. **Exit-лаба doc:** one-pager по l3 vs l4 (включая факт UDP-байпаса upstream-proxy) + регламент развёртывания exit на VPS (только документ, без выполнения — нужен owner GO).
7. **RSS-протокол лабы NC-4210:** пошаговый план измерений (VmHWM/RRSS профиля direct+mailru+cups, 30 мин, синтетический трафик), критерии admission для KN-1012. Выполняется только после owner GO.
8. **MT-002 multi-provider bundle:** пример bundles/wdtt+openflux (разные loopback-порты) + fixture конфликта портов 1083/1080 — расширяет validator-набор без кода validator'а.
9. **Документ решения по DNS:** свойство «локальный резолв» + варианты политики DNS Keenetic при включённом провайдере (без изменений на рабочих системах).
10. **(Отложено до GO)** Кандидат №2 pre-study: минимальный CLI-скелет MAX-TURN провайдера на vpnlib (без аккаунтных вызовов; компиляция + синтетика) — только после owner-решения по MAX-аккаунтам/ToS и pinned-CA плану.

---

## Приложение A. Точные ссылки на код (v0.13.0 `4f9c786`, если не указано иное)

- main.go:269-343 (роли/флаги), :270 (inbound дефолт), :323 (`:1080`), :332 (`--sensitive`), :671-675 (выбор inbound), :905-906 (telemost⇒socks5)
- socks5/socks5.go:153 (256 conns), :191-211 (auth), :226-234 (CONNECT/ASSOC), :285-313 (RFC1929), :315-469 (UDP assoc), :329-339, :353-357, :381-390, :406-409, :425
- tunnel/tunnel.go:343 (DialTCP), :382-395 (локальный резолв), :398-419 (DialUDP/IPv6-отказ); tunnel/exit.go:20-31; tunnel/upstream.go:18-21, :103-108
- transport/transport.go:21-28, :53-61; transport/session.go:356, :908-940, :1086, :1498-1499, :1566-1607; transport/batched.go:22; transport/direct.go:27-76, :199-224, :281-330
- transport/registry/registry.go:36-44, :50-53, :69, :234; registry/group.go, mixed.go; classic_compat.go:11-23
- transport/yandex/captcha.go:21,35,121; yandex/telemost.go:1-6; cupsonline/cupsonline.go:30-32,1469; avito/avito.go:28,555; bitrix24/bitrix24.go:1-8; mailru/mailru.go:1-5; oneme/max_data.go:23-45; phpbox/client.go:12-19
- PROTOCOL_NEGOTIATION.md:17-31 (слои), :33-55 (envelope), :70-79 (один клиент), :81-106 (liveness), :145-163 (classic), :175-194 (KDF), :198-206 (нет FS)
- build_all.sh:50,92-93; CHANGELOG.md 0.13.0; коммит `57174c1` (bonding removed)
- swinter-ios@dc58e18: golib/vpnlib/max_creds.go:22-26,46; turn.go:5-8,416,612; tun2socks.go:38; server/SERVER.md; golib/go.mod (Unlicense LICENSE в корне)
- csqtt@d02da9b: rust-client/vk_js_calls.rs:223,359; auth.rs:21,471,487; csqtt-android@5c3cf03: openwrt/README.md, app/.../Constants.kt:103, app/src/main/assets/deploy.sh:863,877
- focsq@9ad3bfb: отсутствие LICENSE в корне; backend/tun_linux.rs, udp_batch.rs

## Приложение B. Что выполнено в рамках этого исследования (честно)

- Прочитаны и зафиксированы исходники 11 репозиториев/тегов (§0); аудиты A–D выполнены по коду с file:line.
- Локальные синтетические проверки: arm64/arm-сборки, smoke `--help`, негативные разборы флагов (§0) — **без единого сетевого подключения** к Keenetic/VPS/VK/MAX/Яндексу и без установки чего-либо.
- Не выполнено (и не разрешено): любые реальные сессии, аккаунтные действия, измерения RSS, изменения WDTT/OpenFlux/KAS-кода, merge/release. PR остаётся Draft.
