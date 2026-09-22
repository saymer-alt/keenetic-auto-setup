# WARPSCOUT: как выбирать Cloudflare colo и не путать его со страной выхода

[WARPSCOUT](https://github.com/vernette/warpscout) — отдельный исследовательский инструмент для Cloudflare WARP. Его главная ценность в нашей схеме не в «смене страны», а в том, что он показывает **какой Cloudflare edge/colo реально обслуживает конкретный endpoint и port**.

Эта статья сверена с русской документацией upstream и исходниками `vernette/warpscout` на commit:

~~~text
b49ef5e8a466164a64d669951521b58944346bc8
~~~

Основной источник: [README_RU.md](https://github.com/vernette/warpscout/blob/b49ef5e8a466164a64d669951521b58944346bc8/README_RU.md).

---

## Главное, на чём легко запутаться: `NODE` ≠ `SEEN AS`

WARPSCOUT показывает несколько разных географических сущностей:

| Поле | Что означает |
|---|---|
| `NODE` | Cloudflare colo/edge, через который реально проходит туннель: например `FRA`, `ARN`, `HEL`, `DME` |
| `NODE LOCATION` | город/страна этого Cloudflare узла |
| `SEEN AS` | страна, которой внешний сервис видит WARP egress |
| `ENDPOINT PING` | задержка до самого endpoint; ещё не говорит о качестве трафика внутри туннеля |
| `TUN PING` | задержка уже **внутри** WARP-туннеля |
| `LOSS` | потери внутри туннеля |

Это ключевая идея:

~~~text
NODE / colo        = где Cloudflare обработал туннель
SEEN AS / exit geo = какую страну видят сайты
~~~

Они могут **не совпадать**. Upstream приводит именно такой пример: WARP может идти через Франкфурт, а сайты всё равно видеть выход как другую страну.

Поэтому фраза «я выбрал ARN/FRA/HEL» сама по себе не означает «я получил шведский/немецкий/финский public IP».

---

## Что WARPSCOUT реально позволяет менять

Для обычного WireGuard/AmneziaWG WARP у Cloudflare много endpoint addresses. Anycast/BGP и конкретный destination `IP:port` могут привести один и тот же WARP account на разные edge nodes.

Именно поэтому WARPSCOUT перебирает endpoints и проверяет **реальный `NODE` через поднятый туннель**, а не делает вывод по GeoIP самого endpoint.

Очень показательный факт из release `v0.16.0`: один и тот же IP на разных WARP ports может попасть на разные colos. Для этого появился:

~~~text
warpscout scan -p awg -P -sweep-ports open
~~~

или полный перебор известных портов:

~~~text
warpscout scan -p awg -P -sweep-ports all
~~~

То есть объект выбора — не просто «адрес Cloudflare», а фактически **endpoint + port + текущий маршрут из вашей точки выхода**.

---

## Почему это полезно именно в нашей цепочке через Mihomo/VPS

В статье [34-vlozhennye-tunneli-warp.md](34-vlozhennye-tunneli-warp.md) WARP peer строится так:

~~~text
Keenetic WARP
  ↓ connect via
ProxyN → Mihomo → selected VPS/proxy
  ↓
Cloudflare WARP endpoint
~~~

Значит, с точки зрения Cloudflare источник наружного WARP transport — **не домашний ISP как таковой, а путь через выбранный Mihomo/VPS**.

Поэтому для оценки colo полезнее:

1. запускать WARPSCOUT прямо на соответствующем VPS; или
2. запускать его через максимально похожий egress path;
3. затем переносить найденный endpoint/port в свою WARP-конфигурацию и перепроверять уже на Keenetic.

Скан с домашнего ПК напрямую через ISP может показать другую картину colos, потому что BGP/path до Cloudflare будет другим.

---

## Базовый workflow

### 1. Зарегистрировать WARP account

~~~sh
warpscout register
~~~

### 2. Для фильтрующей сети начать с AWG

Upstream README рекомендует:

~~~sh
warpscout scan -p awg -P
~~~

`-P` важен: он проверяет туннель серией пакетов и отделяет endpoints, которые только успевают подняться, а затем рвутся (`torn down`).

### 3. Посмотреть разные colos

Например:

~~~sh
warpscout scan -p awg -P -node HEL,ARN
warpscout scan -p awg -P -exclude-node DME
~~~

### 4. Выбрать лучший endpoint

~~~sh
warpscout scan -p awg -P -exclude-node DME -best
~~~

### 5. Если важен именно port/colo mapping

~~~sh
warpscout scan -p awg -P -sweep-ports open
~~~

Это полезнее простого ping: соседние endpoints или один IP на разных ports могут увести туннель в разные nodes.

---

## Важная ловушка: `-country` — это страна NODE, не `SEEN AS`

В upstream WARPSCOUT фильтры `-node` и `-country` относятся к **Cloudflare node/colo**.

Например:

~~~sh
warpscout scan -p awg -P -country SE,DE
~~~

означает «оставить endpoints, чьи Cloudflare nodes находятся в Швеции/Германии», а не «гарантировать, что сайты увидят шведский/немецкий exit IP».

Если задача — выбрать именно colo обработки трафика, это как раз нужный фильтр. Если задача — геолокация public IP, смотрите `SEEN AS` отдельно.

---

## MASQUE: H3 и H2

WARPSCOUT поддерживает два MASQUE transport'а:

| Режим | WARPSCOUT | Снаружи | IPv4 pool в текущем upstream | IPv6 pool |
|---|---|---|---|---|
| MASQUE H3 | `-p masque` | QUIC / UDP / HTTP/3 | `162.159.198.1`, `162.159.198.2` | `2606:4700:103::1`, `::2`; `2606:4700:104::1`, `::2` |
| MASQUE H2 | `-p masque-h2` | TLS / TCP / HTTP/2 | `162.159.198.0/24`, `162.159.199.0/24` | `2606:4700:103::/48`, `2606:4700:104::/48` |

Порты, которые текущий upstream перебирает для MASQUE:

~~~text
443, 500, 1701, 4500, 4443, 8443, 8095
~~~

Для H3 это UDP, для H2 — TCP.

Источники:

- [docs/ru/masque.md](https://github.com/vernette/warpscout/blob/b49ef5e8a466164a64d669951521b58944346bc8/docs/ru/masque.md);
- [masque.go](https://github.com/vernette/warpscout/blob/b49ef5e8a466164a64d669951521b58944346bc8/masque.go).

### Почему H2 и H3 нужны отдельно

H3/QUIC и H2/TCP выглядят для сети очень по-разному. Если UDP/QUIC режется, H2 может пройти как обычный TLS/TCP path.

WARPSCOUT прямо предупреждает: SNI, который проходит для H3, не обязан работать для H2. Поэтому:

~~~sh
warpscout find-sni -p masque
warpscout find-sni -p masque-h2
~~~

ищут SNI **отдельно**.

### Но MASQUE ведёт себя иначе в отношении colo

Это важное отличие от WG/AWG. По текущей документации WARPSCOUT:

> все endpoints одного MASQUE scan выходят через одну и ту же node; node зависит от вашей сети, а не от выбранного MASQUE address.

Именно поэтому WARPSCOUT отклоняет `-node`, `-country`, `-exclude-node`, `-exclude-country` для `masque`/`masque-h2`.

То есть для **выбора colo** WARPSCOUT особенно интересен с WireGuard/AWG pools. Для MASQUE H2/H3 скан в первую очередь отвечает на другие вопросы: какой transport/address/SNI/port проходит и насколько стабильно.

---

## MASQUE не вставляется в WireGuard peer Keenetic

Эти два режима нельзя смешивать:

~~~text
Keenetic WireGuard peer
    ≠
MASQUE H2/H3 endpoint
~~~

Если вы используете native WireGuard connection в Keenetic, берите WireGuard/AWG-compatible endpoint.

Для MASQUE нужен MASQUE-capable client. WARPSCOUT умеет:

~~~sh
warpscout scan -p masque -conf usque.json
warpscout scan -p masque-h2 -conf usque.json
warpscout scan -p masque -conf warp.yaml -conf-type mihomo
warpscout scan -p masque-h2 -conf warp.yaml -conf-type mihomo
~~~

По upstream docs H2 для Mihomo генерируется как `type: masque` с `network: h2`.

---

## `WARP-in-WARP` — отдельная история

У WARPSCOUT есть `-through`, который запускает внутренний scan **изнутри другого WARP tunnel**.

Это уже не обычный выбор endpoint/colo. В такой вложенной схеме источник внутреннего WARP для Cloudflare меняется на outer WARP path, и `SEEN AS` может измениться вслед за ним.

Поэтому не смешивайте две идеи:

1. **обычный endpoint/port selection** — выбираем удобный `NODE`/colo, `SEEN AS` может остаться прежним;
2. **WARP-in-WARP / `-through`** — отдельная вложенная топология, где меняется сама точка, из которой строится внутренний туннель.

### Два WARP-слоя — два разных key/device

Upstream WARPSCOUT специально регистрирует **второе WireGuard-устройство для внешнего туннеля**: Cloudflare не принимает вложенные WARP-туннели, если они используют один и тот же private key. Поэтому outer и inner WARP в `-through` — две разные WARP identity/key pair.

Это важно отличать от другой схемы:

~~~text
Mieru / VLESS / Hysteria2 / другой VPS transport
                 ↓ dialer-proxy
             MASQUE WARP
~~~

Здесь внешний слой **не WARP**, поэтому второй WARP private key не нужен. Mihomo официально поддерживает `dialer-proxy` у MASQUE outbound. Например, обсуждавшийся нами шаблон выглядел как `dialer-proxy: "Estonia Mieru"`: это означает «строить MASQUE через внешний Mieru proxy», а не «вложить второй WARP». Сам этот конкретный transport-chain не помечаем как live-tested, пока он не подтверждён отдельным acceptance.

Официальная конфигурация Mihomo MASQUE: [Mihomo Docs — MASQUE](https://wiki.metacubex.one/ru/config/proxies/masque/).

Upstream WARPSCOUT: [docs/ru/warp-in-warp.md](https://github.com/vernette/warpscout/blob/b49ef5e8a466164a64d669951521b58944346bc8/docs/ru/warp-in-warp.md).

---

## Наши полевые наблюдения 2026: почему здесь столько оговорок

Этот раздел — **история операторских тестов проекта**, а не текущая спецификация Cloudflare. Он полезен именно тем, что показывает, как быстро можно сделать неправильный вывод, если смешать endpoint, colo и exit geography.

### 24–25 июня: H3 и H2 выглядели намного уже/шире соответственно

В июньских тестах MASQUE H3/QUIC стабильно удавалось поднять только на:

~~~text
162.159.198.2:443
162.159.199.2:443
~~~

а H2 проходил на разных протестированных адресах из `162.159.198.*` / `162.159.199.*` и на ports:

~~~text
443, 500, 1701, 4500, 4443, 8443, 8095
~~~

Это **не надо копировать как актуальный hardcoded pool**. Уже текущий WARPSCOUT в сентябре описывает H3 иначе (`162.159.198.1/.2` плюс IPv6 addresses), а H2 сканирует целые `/24`. Именно поэтому документация выше говорит: consumer endpoint pools и фактическая доступность — предмет повторного скана, а не вечная таблица.

### 25 июня: одна технология, разные провайдеры — разные Cloudflare paths

В одном и том же периоде операторские наблюдения давали разные точки обработки в зависимости от исходной сети: домашний 2КОМ/Алмател — Riga, рабочая сеть — Domodedovo, Tele2 — Finland, Megafon — Germany.

Тогда мы ещё не всегда строго разделяли `NODE` и `SEEN AS`, поэтому эти записи нельзя ретроспективно превращать в точную таблицу exit-country. Но они хорошо подтверждают главный вывод: **BGP/path исходной сети реально влияет на то, куда Cloudflare принимает WARP**, и один endpoint сам по себе не гарантирует один colo.

### 19 августа: `colo=FRA`, но `loc=CH`

В реальном Cloudflare trace одновременно наблюдалось:

~~~text
colo=FRA
loc=CH
warp=on
http=http/3
~~~

Это практически идеальный пример различия:

~~~text
FRA = Cloudflare colo / место обработки
CH  = география, с которой виден WARP egress
~~~

То есть даже хороший иностранный colo не надо автоматически читать как «та же страна выхода».

### 19 августа: перебор endpoint'ов не всегда меняет node

Был и обратный результат: прямые MASQUE/AWG тесты с заменой endpoint IP/port продолжали приходить в DME. Это важный контрпример к идее «достаточно подобрать другой Cloudflare IP — и colo обязательно сменится». Если текущий network path жёстко ведёт в один edge, адресный перебор может не помочь.

---

## Практический паттерн Mihomo: H3 + H2 одновременно

У нас реально использовался паттерн, где оба MASQUE transport'а существуют одновременно:

~~~yaml
proxies:
  - name: WARP-MASQUE-QUIC
    type: masque
    server: <current-h3-endpoint>
    port: 443
    private-key: <private-key>
    public-key: <public-key>
    ip: 172.16.0.2/32
    mtu: 1280
    sni: <current-working-sni>
    udp: true

  - name: WARP-MASQUE-H2-443
    type: masque
    server: <current-h2-endpoint>
    port: 443
    private-key: <private-key>
    public-key: <public-key>
    ip: 172.16.0.2/32
    mtu: 1280
    sni: <current-working-sni>
    udp: true
    network: h2
~~~

`type: masque`, `ip`, `mtu`, `sni`, `network: h2` и `dialer-proxy` соответствуют текущей официальной схеме Mihomo MASQUE. Endpoint и SNI в примере намеренно не зафиксированы: их надо брать из актуального скана/acceptance. В полевых конфигах июня–августа 2026 у нас использовался `sni: 4pda.to`, но это историческое наблюдение, а не вечный рекомендуемый SNI.

Поверх этих двух proxies у нас был `Fastest_MASQUE` как `url-test` между QUIC и H2. Один из реально использовавшихся вариантов имел (исторический health-check URL сохранён как часть полевого примера):

~~~yaml
proxy-groups:
  - name: Fastest_MASQUE
    type: url-test
    proxies:
      - WARP-MASQUE-QUIC
      - WARP-MASQUE-H2-443
    url: https://google.com/generate_204
    interval: 300
    tolerance: 50
    expected-status: 204
~~~

Смысл паттерна — не «H3 всегда быстрее H2», а держать оба транспорта и позволять Mihomo выбирать живой/быстрый вариант. Но важно помнить ограничение: HTTP `url-test` проверяет HTTP-доступность/задержку, а не весь спектр проблем внутри конкретного WARP transport. После серьёзного изменения endpoint/SNI всё равно нужен фактический traffic check. Для нового конфига текущая документация Mihomo показывает `https://www.gstatic.com/generate_204` как типичный URL health-check; исторический `https://google.com/generate_204` выше не является проектным стандартом.

Официальная схема полей: [Mihomo Docs — MASQUE](https://wiki.metacubex.one/ru/config/proxies/masque/).

---

## Почему в нашем проекте обычно не нужен отдельный `usque` daemon

Upstream WARPSCOUT умеет выдавать native MASQUE config для `usque`, и это нормальный самостоятельный вариант. Но в нашем стеке MASQUE уже умеет **сам Mihomo** — с H3/H2, routing/groups, `dialer-proxy`, TUN/rules/DNS-интеграцией.

Поэтому для `keenetic-auto-setup`/наших Mihomo-схем более естественный экспорт:

~~~sh
warpscout scan -p masque -conf warp.yaml -conf-type mihomo
warpscout scan -p masque-h2 -conf warp.yaml -conf-type mihomo
~~~

`usque` остаётся полезным upstream-клиентом и эталонной точкой сравнения, но не является обязательной зависимостью проекта.

---

## Что смотреть при выборе endpoint

Не выбирайте строку только по `ENDPOINT PING`.

Для реального использования полезнее смотреть в таком порядке:

1. endpoint не `torn down`;
2. `LOSS = 0%` или приемлемые потери внутри tunnel;
3. `TUN PING`, а не только ping до адреса;
4. нужный `NODE`/colo;
5. при необходимости `SPEED`;
6. после переноса в Keenetic — реальный handshake/RX/TX и application traffic.

Для speed phase:

~~~sh
warpscout scan -p awg -P -speed
~~~

или выбор по скорости из протестированного набора:

~~~sh
warpscout scan -p awg -P -best -best-by speed
~~~

---

## Что важно помнить

- WARPSCOUT — внешний исследовательский инструмент, не часть `keenetic-auto-setup` и не dependency installer'а.
- Endpoint/port→colo mapping не надо считать вечным: Cloudflare/BGP routing может меняться, поэтому проблемный path лучше пересканировать.
- `NODE` отвечает на вопрос **«где Cloudflare обработал tunnel»**, а `SEEN AS` — **«какую страну видит внешний сервис»**.
- В нашей WARP-over-Mihomo схеме скан на выбранном VPS обычно информативнее прямого скана из домашней сети.
- MASQUE H3 и H2 имеют разные transport/address pools; работающий H3 SNI не гарантирует H2.
- Для native Keenetic WireGuard не подставляйте MASQUE endpoint.

---

## Связанные материалы

- [34-vlozhennye-tunneli-warp.md](34-vlozhennye-tunneli-warp.md) — WARP/WireGuard через ProxyN → Mihomo → VPS.
- [31-tun.md](31-tun.md) — TUN Mihomo и почему его MTU не равен MTU Keenetic WireGuard.
- [../../ARCHITECTURE.md](../../ARCHITECTURE.md) — общая архитектура.
- Upstream WARPSCOUT: [README_RU.md](https://github.com/vernette/warpscout/blob/master/README_RU.md).
