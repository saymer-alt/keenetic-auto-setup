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
- [KeeneticOS 4.1: WireGuard underlying connection / `via`](https://support.keenetic.com/hero/kn-1012/en/36576-keeneticos-4-1.html);
- [KeeneticOS 4.1: SOCKS5 UDP for Proxy connection](https://support.keenetic.com/starter/kn-1112/en/32140-keeneticos-4-1.html);
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

Но здесь нельзя превращать наблюдаемое поведение в гарантию страны. Cloudflare прямо пишет, что consumer WARP не предназначен для выбора/подмены страны, а конкретный Cloudflare data center зависит от сетевой маршрутизации. Поэтому формулировка проекта такая:

> География выбранного Mihomo/VPS часто влияет на то, где Cloudflare примет туннель и какой egress получится на практике, но WARP не является контрактным country selector.

Cloudflare: [WARP modes](https://developers.cloudflare.com/warp-client/warp-modes/) и [WARP FAQ](https://developers.cloudflare.com/warp-client/known-issues-and-faq/).

После смены Mihomo node проверяйте новый WireGuard handshake, счётчики RX/TX и внешний IP. Если старый UDP state не переехал сразу, проще переподнять WARP connection, чем угадывать.

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

---

## Endpoint `engage.cloudflareclient.com:2408`

В рабочей операторской конфигурации использовался endpoint вида:

~~~text
engage.cloudflareclient.com:2408
~~~

Cloudflare и сейчас документирует `engage.cloudflareclient.com` среди WARP connectivity endpoints, а UDP/2408 входит в набор WARP ingress ports: [Cloudflare One Client with firewall](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/deployment/firewall/).

Но проект **не закрепляет этот hostname/port как вечную константу**. Используйте endpoint из актуальной WARP/WireGuard-конфигурации: Cloudflare может менять preferred protocol, addresses и ingress behavior.

Если endpoint задан FQDN, DNS должен работать **до** поднятия этого WARP connection. Не создавайте bootstrap loop, где имя WARP endpoint можно разрешить только через сам ещё не поднятый WARP.

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

---

## Проверка после настройки

Минимальный acceptance:

1. Убедиться, что проектный ProxyN активен и указывает на `127.0.0.1:7890`.
2. В MetaCubeXD выбрать конкретный Mihomo node и проверить, что он поддерживает UDP.
3. В WireGuard/WARP peer выбрать `Подключаться через → mihomo t2sN`.
4. Убедиться, что WireGuard peer зелёный, handshake обновляется, RX/TX растут.
5. Назначить WARP interface нужной Connection Policy/клиенту/сегменту.
6. Проверить внешний IP: он должен принадлежать Cloudflare, а не VPS, если full-tunnel WARP действительно является финальным выходом.
7. Переключить Mihomo node и повторить handshake/IP-проверку.
8. Если есть «часть сайтов висит» — сначала проверить MTU; 1200 уже является рабочей контрольной точкой для этой вложенной схемы.

Не используйте один только public-IP check как доказательство здоровья всех слоёв: отдельно смотрите WARP peer counters и выбранный Mihomo node.

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
- [../../ARCHITECTURE.md](../../ARCHITECTURE.md) — общая архитектура проекта.
- [../HOWTO_RU.md](../HOWTO_RU.md) — практическая эксплуатация.
