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

Upstream: [docs/ru/warp-in-warp.md](https://github.com/vernette/warpscout/blob/b49ef5e8a466164a64d669951521b58944346bc8/docs/ru/warp-in-warp.md).

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
