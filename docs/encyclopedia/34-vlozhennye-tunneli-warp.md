# Вложенный WARP/WireGuard через ProxyN и Mihomo

Эта схема использует две разные возможности KeeneticOS:

1. **политику подключения** — какой интерфейс получает клиентский трафик;
2. **`Подключаться через` / WireGuard `via`** — через какой нижележащий интерфейс сам WireGuard peer устанавливает соединение с удалённым endpoint.

Это не одно и то же. В нашем продвинутом варианте клиентский трафик отправляется в WARP/WireGuard-интерфейс, а **сам WARP-туннель строится через проектный ProxyN → Mihomo → выбранный proxy/VPS**.

Официальные release notes Keenetic показывают, что это не функция, появившаяся только в KeeneticOS 5.x:

- Proxy Client появился в KeeneticOS 3.9;
- SOCKS5 UDP для Proxy connection появился в ветке KeeneticOS 4.1;
- WireGuard peer `connect via` появился в KeeneticOS 4.1.

Источники:

- [KeeneticOS 3.9: Proxy Client](https://support.keenetic.com/hero/kn-1011/en/26123-keeneticos-3-9.html);
- [KeeneticOS 4.1 release history: WireGuard `connect via` and SOCKS5 UDP for Proxy connections](https://support.keenetic.com/starter/kn-1112/en/32140-keeneticos-4-1.html);
- [Keenetic Proxy Client manual](https://support.keenetic.com/hopper-dsl/kn-3611/en/49443-proxy-client.html).

---

## Схема

Упрощённо:

~~~text
LAN client / segment
        │
        │ policy: use WARP nwgX
        ▼
Keenetic WARP / WireGuard interface
        │
        │ peer: connect via ProxyN (mihomo t2sN)
        ▼
Keenetic ProxyN, SOCKS5 UDP
        │ 127.0.0.1:7890
        ▼
Mihomo
        │ selected GLOBAL/proxy node
        ▼
VPS / remote proxy
        │ carries encrypted WireGuard/WARP UDP
        ▼
Cloudflare WARP ingress
        │ decrypts WARP tunnel
        ▼
Cloudflare egress
        ▼
Internet
~~~

Важная деталь: **VPS здесь не является финальным Internet exit**. Он только переносит наружный WARP/WireGuard-туннель до Cloudflare. Если WARP работает как full tunnel, сайт снаружи видит Cloudflare egress IP, а не IP VPS.

Это и отличает схему от обычного `Client → ProxyN → Mihomo → VPS → Internet`.

---

## Что именно выбирает `Подключаться через`

Для WireGuard Keenetic документирует CLI:

~~~text
interface {name} wireguard peer {key} connect via {via}
~~~

Параметр `via` задаёт **underlying connection для peer**. В web UI это поле «Подключаться через». Тот же механизм можно использовать с обычным WAN, другим VPN-интерфейсом или проектным ProxyN.

В нашем проекте ProxyN создаётся как SOCKS5-интерфейс на `127.0.0.1:7890` и installer включает `proxy socks5-udp`. Для WireGuard это принципиально: WireGuard несёт транспорт по UDP.

Но одного локального `socks5-udp` мало: **выбранный Mihomo outbound тоже должен поддерживать UDP end-to-end**. Если группа переключится на узел без рабочего UDP, WARP handshake/traffic может пропасть при том, что TCP через тот же proxy выглядит здоровым.

---

## Политика подключения и `via` — два разных уровня

Например:

~~~text
Политика WARP:
  client/segment → WARP nwg3

Настройка peer WARP:
  WARP nwg3 → connect via mihomo t2s0
~~~

Первая строка отвечает на вопрос «куда отправлять пользовательский трафик».

Вторая — «через какой интерфейс добираться до WARP endpoint».

Именно сочетание этих двух настроек создаёт вложенную цепочку.

### Fail-closed или fallback: политика решает отдельно

`connect via ProxyN` **не означает**, что клиентский трафик обязательно останется только в WARP при аварии. Это определяет уже Connection Policy.

Keenetic официально описывает политику как набор разрешённых Internet connections с приоритетами: если более приоритетное соединение становится недоступным, система может перейти на следующее разрешённое соединение.

Поэтому для privacy-sensitive WARP-профиля заранее выберите требуемое поведение:

| Цель | Что оставить включённым в policy | Результат при падении WARP |
|---|---|---|
| **fail-closed** | только WARP/WireGuard connection | клиент теряет Internet вместо выхода напрямую |
| **fail-open / резервирование** | WARP + ISP/другой VPN в нужном порядке | Keenetic может перейти на следующий доступный gateway |

Если задача — гарантировать, что устройство **никогда не покажет ISP/VPS exit вместо Cloudflare**, не используйте Default policy с несколькими разрешёнными подключениями: создайте отдельную policy и оставьте там только WARP connection.

И наоборот, если важнее непрерывный Internet, осознанно добавьте backup и примите, что при аварии WARP внешний IP/граница доверия изменятся.

Для VPN connection в policy также должна быть включена опция Keenetic **«Использовать для выхода в Интернет»**; иначе интерфейс не является обычным Internet gateway для этого policy.

### DNS после привязки отдельной policy

У Keenetic есть ещё одна связанная, но отдельная деталь: DNS servers, полученные от connections, применяются с учётом состава policy. Официальная документация говорит, что в policy добавляются DNS servers от включённых в неё connections; вручную добавленный DNS с `Connection = Any` используется всеми policies.

Поэтому симптом «через WARP по IP ходит, а домены перестали резолвиться после переноса клиента в отдельную policy» не надо сразу списывать на Mihomo/WireGuard. Сначала проверьте DNS именно в контексте этой policy и нашу отдельную цепочку DNS interception/upstream.

Это **не повод автоматически переводить DNS на WARP**: в проекте DNS — отдельный слой, описанный в HOWTO/ARCHITECTURE, и менять его надо только понимая bootstrap и loop boundaries.

Официальное описание: [Keenetic — Connection policies](https://support.keenetic.com/carrier/kn-1721/en/17892-connection-policies.html).

Это ещё одна причина не путать два уровня:

~~~text
WireGuard peer connect via ProxyN
    = как WARP добирается до Cloudflare

Connection Policy: only WARP / WARP+backup
    = куда пойдёт клиентский Internet и что будет при отказе
~~~

---

## Mihomo как переключатель географии наружного транспорта

В `config.yaml` Mihomo может иметь десятки или сотни proxy nodes в разных странах. Если ProxyN попадает в группу `GLOBAL`, смена выбранного node меняет **наружный путь, по которому Keenetic строит WARP peer**.

Практически это даёт интересную схему:

~~~text
select Sweden VPS  → WARP tunnel enters Cloudflare from Swedish-side path
select Estonia VPS → WARP tunnel enters Cloudflare from Estonian-side path
...
~~~

При этом **финальный public IP остаётся Cloudflare**, если traffic действительно выходит через WARP.

Но здесь нельзя превращать наблюдаемое поведение в гарантию страны. В актуальном FAQ Cloudflare пишет, что WARP заменяет исходный IP на Cloudflare IP, который представляет **примерное местоположение пользователя**, а выбранный Cloudflare data center не обязан быть физически ближайшим: на него влияют маршрутизация провайдера, доступность площадок и то, какие locations вообще WARP-enabled. Поэтому формулировка проекта такая:

> География выбранного Mihomo/VPS может менять наружный маршрут до Cloudflare и наблюдаемый WARP path, но это не детерминированный country selector и не контракт «VPS в стране X → Cloudflare exit строго в стране X».

Cloudflare: [WARP FAQ](https://developers.cloudflare.com/warp-client/known-issues-and-faq/).

После смены Mihomo node проверяйте новый WireGuard handshake, счётчики RX/TX и внешний IP. Если старый UDP state не переехал сразу, проще переподнять WARP connection, чем угадывать.

### Для WARP лучше отдельная группа Mihomo

Если в подписке десятки или сотни серверов, не каждый из них обязательно одинаково пригоден как **транспорт для WireGuard UDP**.

Обычный `url-test` / latency test Mihomo проверяет HTTP-доступность/задержку и сам по себе **не доказывает**, что через выбранный node нормально проходит SOCKS5 UDP и WARP handshake.

Для этой топологии разумнее иметь отдельную группу, например `WARP-TRANSPORT`:

- включать туда только узлы, на которых UDP реально проверен;
- не смешивать их с TCP-only/сомнительными nodes;
- после автоматического переключения смотреть не только HTTP latency, но и свежесть WireGuard handshake;
- если нужна максимальная предсказуемость, использовать ручной `select` или небольшой проверенный набор, а не всю подписку из сотни узлов.

Так failure domain становится понятнее: «Mihomo node жив по HTTP» и «этот node годится для WARP UDP» — разные утверждения.

---

## Кто что видит

Эта цепочка **меняет границы доверия**, но не создаёт анонимность.

| Участник | Что видит в этой схеме |
|---|---|
| домашний ISP | соединение/транспорт к вашему Mihomo/VPS и метаданные по объёму/времени; не финальный WARP payload в открытом виде |
| VPS / его провайдер | поток к Cloudflare WARP ingress, endpoint, объём и timing; IP-пакеты внутри WireGuard/WARP зашифрованы |
| Cloudflare | завершает WARP-туннель и становится финальным сетевым egress; видит назначения/сетевые метаданные после снятия WARP-обёртки, при этом HTTPS-приложения сохраняют своё собственное шифрование |
| конечный сайт | Cloudflare egress IP вместо IP VPS |

Поэтому корректно говорить не «VPS вообще ничего не видит», а:

> VPS больше не является финальным Internet egress и не получает внутренний WARP-трафик в открытом виде; доверие финального сетевого выхода переносится на Cloudflare.

Насколько Cloudflare для оператора предпочтительнее конкретного VPS-провайдера — это уже **модель доверия**, а не техническое доказательство безопасности. Cloudflare отдельно предупреждает, что WARP не является сервисом анонимности.

---

## MTU: здесь легко перепутать три разные настройки

В нашей системе могут одновременно существовать как минимум три MTU:

1. MTU физического WAN;
2. MTU **Keenetic WireGuard/WARP interface**;
3. `tun.mtu` у Mihomo для `mitun0`.

Для схемы из этой статьи ключевой параметр — **MTU самого WARP/WireGuard connection в Keenetic**.

Если WARP peer идёт через ProxyN → Mihomo, то `tun.mtu` Mihomo вообще может не участвовать: трафик входит в Mihomo через SOCKS5 mixed-port `7890`, а не через `mitun0`.

Поэтому:

~~~text
Keenetic WARP MTU = 1200
≠
Mihomo tun.mtu = 1200
~~~

Это две разные точки цепочки.

### Почему 1200 может работать

Вложенная схема добавляет несколько уровней encapsulation: внутренний IP → WireGuard/WARP → SOCKS5 UDP → Mihomo proxy transport → WAN. Эффективный доступный размер пакета меньше, чем на обычном Ethernet path.

В операторской WARP-схеме **MTU 1200 проверен как рабочее значение**. Это полезный практический anchor, но **не универсальный default для всех Keenetic/WARP/Mihomo**.

Для сравнения: Cloudflare для обычного современного WARP client на Linux сейчас указывает рекомендуемый MTU 1381. У вложенного маршрута overhead больше, поэтому более консервативное значение вроде 1200 может быть оправдано. Источник: [Cloudflare WARP system requirements](https://developers.cloudflare.com/warp-client/get-started/).

Правило проекта:

- не менять MTU «по вере»;
- если сайты подвисают, часть HTTPS/QUIC не работает, а маршрутизация правильная — проверить path MTU;
- для нашей вложенной схемы 1200 — проверенная точка старта;
- 1200–1300 можно использовать как практический диапазон диагностики, но не как универсальную норму.

### TCP MSS adjustment

Опция Keenetic «Подстройка TCP MSS» полезна для TCP внутри туннеля: она уменьшает MSS так, чтобы TCP-сегменты лучше укладывались в эффективный MTU.

Но MSS adjustment **не чинит UDP/QUIC и не заменяет правильный WireGuard MTU**. Сам WireGuard handshake и WARP transport остаются UDP.

### Persistent keepalive

На скриншоте peer использует проверку активности / keepalive `15` секунд. Для вложенной цепочки через NAT + SOCKS5 UDP это может быть полезно: периодический пакет поддерживает UDP/NAT state и быстрее показывает, что path умер.

Но это не универсальная обязательная цифра проекта. Чем меньше интервал, тем больше фонового трафика и wakeups. Если chain стабилен без частого keepalive, нет смысла уменьшать интервал только ради «надёжности».

---

## Endpoint'ы Cloudflare: что можно встретить и что не надо путать

В рабочей операторской конфигурации использовался:

~~~text
engage.cloudflareclient.com:2408
~~~

Это остаётся полезным **проверенным примером**, но проект не считает его вечной константой. Для ручного WireGuard/WARP connection на Keenetic приоритет такой:

1. endpoint из актуальной сгенерированной WARP/WireGuard-конфигурации;
2. уже проверенный у вас FQDN/port;
3. только затем — ручные эксперименты с адресами/портами из официальных диапазонов.

Не выбирайте случайный IP из Cloudflare CIDR только потому, что он «похож на WARP»: разные продукты и tunnel protocols используют разные pools.

### Актуальные официальные диапазоны Cloudflare

Cloudflare сейчас публикует такую карту WARP ingress для **Cloudflare One Client / Zero Trust**:

| Назначение | IPv4 | IPv6 | Основной порт | Fallback |
|---|---|---|---|---|
| WireGuard ingress | `162.159.193.0/24` | `2606:4700:100::/48` | UDP `2408` | UDP `500`, `1701`, `4500` |
| MASQUE ingress | `162.159.197.0/24` | `2606:4700:102::/48` | UDP `443` | UDP `500`, `1701`, `4500`, `4443`, `8443`, `8095`; TCP `443` как отдельный fallback |

Там же Cloudflare отдельно указывает `162.159.192.0/24` как IPv4-range **consumer WARP (1.1.1.1 with WARP)**.

Источник: [Cloudflare One Client with firewall](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/deployment/firewall/).

### Consumer WARP MASQUE: H3 и H2 — это разные transport/address pools

Отдельно от официальной Zero Trust-таблицы выше есть **consumer WARP MASQUE**, который исследует [WARPSCOUT](35-warpscout.md). В текущем upstream WARPSCOUT (`master` commit `b49ef5e8a466164a64d669951521b58944346bc8`) два MASQUE transport'а разведены явно:

| WARPSCOUT | Транспорт | IPv4 pool, который сканирует upstream | IPv6 pool |
|---|---|---|---|
| `-p masque` | **HTTP/3 / QUIC / UDP** | `162.159.198.1`, `162.159.198.2` | `2606:4700:103::1`, `::2`; `2606:4700:104::1`, `::2` |
| `-p masque-h2` | **HTTP/2 / TLS / TCP** | `162.159.198.0/24`, `162.159.199.0/24` | `2606:4700:103::/48`, `2606:4700:104::/48` |

WARPSCOUT проверяет для MASQUE числовые порты `443`, `500`, `1701`, `4500`, `4443`, `8443`, `8095`; для H3 это UDP/QUIC, для H2 — TCP/TLS. Это **upstream knowledge/measurements WARPSCOUT**, а не обещание Cloudflare, что эти consumer pools навсегда останутся такими же.

Источники WARPSCOUT:

- [README_RU.md](https://github.com/vernette/warpscout/blob/b49ef5e8a466164a64d669951521b58944346bc8/README_RU.md);
- [docs/ru/masque.md](https://github.com/vernette/warpscout/blob/b49ef5e8a466164a64d669951521b58944346bc8/docs/ru/masque.md);
- [masque.go](https://github.com/vernette/warpscout/blob/b49ef5e8a466164a64d669951521b58944346bc8/masque.go).

Ещё один важный нюанс: у MASQUE SNI является частью внешнего TLS/QUIC handshake. Upstream WARPSCOUT прямо предупреждает, что SNI, который проходит на H3, может не пройти на H2, поэтому `find-sni` запускается отдельно для нужного transport:

~~~text
warpscout find-sni -p masque
warpscout find-sni -p masque-h2
~~~

### Native WireGuard Keenetic ≠ MASQUE

Не пытайтесь просто вставить MASQUE H2/H3 address в поле **«Адрес и порт пира»** обычного WireGuard connection Keenetic. Это другой протокол.

- native Keenetic WireGuard/AWG connection ждёт WireGuard/AWG peer;
- MASQUE H3/H2 требует MASQUE-capable client;
- WARPSCOUT умеет выдавать MASQUE-конфиг для `usque`, а `-conf-type mihomo` — MASQUE outbound для Mihomo; для H2 upstream генерирует тот же `type: masque`, но с `network: h2`.

То есть для нашей статьи 34 основной router-side path остаётся **WireGuard/WARP via ProxyN**. MASQUE — альтернативная ветка, которую логичнее поднимать внутри Mihomo/отдельного MASQUE-клиента, а не маскировать под WireGuard.

### Почему эту таблицу нельзя копировать вслепую в Keenetic

Наша ручная схема — это не официальный Cloudflare One Client daemon. У штатного клиента есть собственная логика выбора ingress, fallback ports и override endpoint'ов. У обычного WireGuard peer в Keenetic такой логики нет: он подключается к тому endpoint, который записан в конфигурации.

Поэтому:

- не подменяйте consumer WARP endpoint адресом Zero Trust WireGuard pool без причины;
- не переносите MASQUE pool в WireGuard connection — это другой tunnel protocol;
- fallback-порты из Cloudflare One Client docs не являются автоматическими fallback'ами вашего Keenetic peer;
- если хотите сменить port/address вручную, делайте это как отдельный тест и проверяйте handshake.

### `engage.cloudflareclient.com`: важная оговорка

Cloudflare и сейчас документирует `engage.cloudflareclient.com`, но в актуальной Cloudflare One Client документации он фигурирует в **outside-tunnel connectivity checks**. Штатный Cloudflare client может сам направить такой запрос в WARP ingress range, независимо от обычного DNS-ответа.

Ручной Keenetic WireGuard peer этой client-side логики не имеет. Для него FQDN разрешается обычным способом, и именно полученный адрес становится endpoint'ом.

Поэтому наш статус такой:

> `engage.cloudflareclient.com:2408` — подтверждённый рабочий endpoint в операторской конфигурации, но не универсальная гарантия Cloudflare для любой ручной WireGuard-конфигурации.

Если endpoint задан FQDN, DNS должен работать **до** поднятия WARP connection. Не создавайте bootstrap loop, где имя WARP endpoint разрешается только через сам ещё не поднятый WARP.

### Полезные адреса для диагностики — не peer endpoint'ы

В актуальной Cloudflare One Client документации также перечислены:

- `162.159.197.3` / `2606:4700:102::3` — outside-tunnel connectivity check;
- `162.159.197.4` / `2606:4700:102::4` и `connectivity.cloudflareclient.com` — inside-tunnel connectivity check;
- `162.159.137.105` и `162.159.138.105` — IPv4 orchestration API endpoints Cloudflare One Client;
- `api.devices.cloudflare.com` — SNI/API hostname у новых Cloudflare One Client.

Это **не адреса WireGuard peer для нашей ручной consumer WARP-схемы**. Они полезны как карта экосистемы Cloudflare и для диагностики firewall, но не должны попадать в поле «Адрес и порт пира» просто потому, что принадлежат WARP/Cloudflare One.

---

## Самая опасная ошибка — рекурсивный маршрут

Рабочая цепочка должна иметь нижний слой, который не зависит от верхнего:

~~~text
WARP
  ↓ via
ProxyN
  ↓
Mihomo
  ↓
base WAN / independent lower-layer path
  ↓
VPS
  ↓
Cloudflare WARP
~~~

Нельзя допустить:

~~~text
WARP → ProxyN → Mihomo → WARP → ...
~~~

Например, если default route роутера перестроен так, что сам Mihomo начинает dial proxy server через тот же WARP, который строится через Mihomo, получится рекурсивная зависимость.

В multi-WAN схемах проверяйте, через какой реальный Linux/Keenetic interface Mihomo dialer выходит к VPS. При необходимости используйте уже документированный `interface-name` для proxy-outbound dialer — он не имеет отношения к `tun.mtu` и не переключает `mitun0` сам по себе.

---

## Почему не строить три-четыре вложенных туннеля

Технически Keenetic позволяет собирать сложные цепочки интерфейсов, но проект рекомендует **останавливаться на одном proxy-layer + одном дополнительном tunnel-layer**, если нет конкретной причины идти глубже.

Каждый новый слой добавляет:

- latency и jitter;
- encapsulation overhead и MTU-риск;
- ещё один handshake/keepalive;
- ещё одну точку отказа;
- более сложный DNS/bootstrap;
- более трудную диагностику «какой именно слой умер».

Поэтому `Mihomo/VPS → WARP` — осмысленная двухслойная конструкция. `VPN → proxy → VPN → proxy → WARP` без конкретной задачи обычно даёт больше эксплуатационной боли, чем пользы. Это **рекомендация проекта**, а не hard limit KeeneticOS.

### Не путать с WARP-in-WARP

Если оба слоя являются WARP/WireGuard, это уже другая схема. WARPSCOUT `-through` для такого случая регистрирует отдельное outer WARP device/key pair: два вложенных WARP-туннеля не должны использовать один private key.

Если же внешний транспорт — Mieru/VLESS/Hysteria2/обычный VPS proxy, а внутренний слой — MASQUE/WARP через Mihomo `dialer-proxy`, второго WARP key нет: внешний слой вообще не WARP. Подробный разбор и исторические тесты — [35-warpscout.md](35-warpscout.md).

---

## Проверка после настройки

Минимальный acceptance:

1. Убедиться, что проектный ProxyN активен и указывает на `127.0.0.1:7890`.
2. В MetaCubeXD выбрать конкретный Mihomo node и проверить, что он входит в набор с подтверждённым UDP.
3. В WireGuard/WARP peer выбрать `Подключаться через → mihomo t2sN`.
4. Убедиться, что WireGuard peer зелёный, handshake обновляется, RX/TX растут.
5. Назначить WARP interface нужной Connection Policy/клиенту/сегменту и проверить, что список разрешённых connections соответствует вашей модели отказа: только WARP для fail-closed или явно выбранные backup connections для fail-open.
6. Проверить, что WARP connection разрешено «Использовать для выхода в Интернет».
7. Проверить внешний IP: он должен принадлежать Cloudflare, а не VPS, если full-tunnel WARP действительно является финальным выходом.
8. На клиенте через этот policy path открыть `https://www.cloudflare.com/cdn-cgi/trace` и проверить `warp=on`. Cloudflare официально использует этот способ проверки WARP data path.
9. Дополнительно открыть `https://1.1.1.1/help`: страница показывает состояние Cloudflare/1.1.1.1 и обслуживающий Cloudflare data center. Поле/data-center — диагностическая подсказка, а не гарантия страны egress.
10. Переключить Mihomo node и повторить handshake, `warp=on` и public-IP проверку.
11. Если есть «часть сайтов висит» — сначала проверить MTU; 1200 уже является рабочей контрольной точкой для этой вложенной схемы.

Источники проверки: [Cloudflare WARP Linux client — `cdn-cgi/trace`](https://developers.cloudflare.com/warp-client/get-started/linux/) и [Cloudflare 1.1.1.1 — Verify connection](https://developers.cloudflare.com/1.1.1.1/check/).

Не используйте один только public-IP check как доказательство здоровья всех слоёв: отдельно смотрите WARP peer counters, свежесть handshake и выбранный Mihomo node.

### Full-tunnel и IPv6

Для полного IPv4-туннеля у peer обычно есть `AllowedIPs 0.0.0.0/0`. Строка `::/0` означает аналогичное покрытие IPv6, но **сама по себе не включает IPv6 во всём проекте**.

Базовая конфигурация `keenetic-auto-setup` намеренно держит IPv6 выключенным. Поэтому не считайте наличие `::/0` в WARP peer доказательством, что клиентский IPv6 реально идёт через эту цепочку. Если когда-нибудь включите IPv6, отдельно проверяйте:

- IPv6 адресацию клиентов;
- DNS AAAA;
- policy routing;
- отсутствие direct IPv6 path мимо WARP/Mihomo;
- внешний IPv6 адрес.

Полувключённый IPv6 опаснее, чем явно выключенный: часть трафика может пойти по другому пути и создать ложное ощущение «иногда VPN обходится».

### Что не публиковать из WireGuard-конфига

Публичный ключ peer и endpoint обычно не являются секретами уровня private key, но **PrivateKey WireGuard, registration/license/token WARP и любые credentials нельзя коммитить в репозиторий или вставлять в публичные issue/logs**.

---

## Что автоматизирует проект

`keenetic-auto-setup` создаёт пригодный нижний ProxyN:

- SOCKS5;
- `socks5-udp`;
- upstream `127.0.0.1:7890`;
- описание `mihomo t2sN`.

Но проект **не создаёт WARP/WireGuard connection автоматически**, не выбирает его peer endpoint, MTU и policy и не строит вложенную цепочку без решения оператора. Это продвинутая пользовательская топология поверх базового проекта.

---

## Связанные материалы

- [31-tun.md](31-tun.md) — почему `tun.mtu` Mihomo и MTU Keenetic WireGuard — разные параметры.
- [32-kak-sobrat-kartinu.md](32-kak-sobrat-kartinu.md) — вход трафика через ProxyN и TUN.
- [35-warpscout.md](35-warpscout.md) — как читать `NODE`/`SEEN AS`, выбирать colo по endpoint/port и не путать это со страной выхода; отдельный разбор MASQUE H2/H3.
- [../../ARCHITECTURE.md](../../ARCHITECTURE.md) — общая архитектура проекта.
- [../HOWTO_RU.md](../HOWTO_RU.md) — практическая эксплуатация.
