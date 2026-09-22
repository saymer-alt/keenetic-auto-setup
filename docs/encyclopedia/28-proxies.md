# Proxies — исходящие серверы

Вопрос этой статьи: **«Что такое `proxies` в config.yaml и что происходит, когда я
подставляю туда свои серверы?»**

`proxies` — это **выходы** ядра (outbound'ы, термин — в
[словаре](01-slovar.md)): список серверов, через которые Mihomo умеет отправлять
трафик. Всё, что «внутри него может находиться» (модель из
[10-mihomo-eto.md](10-mihomo-eto.md)), живёт именно здесь.

---

## Скелет outbound: четыре обязательных поля

По официальной документации у каждого прокси обязательно:

| Поле | Смысл |
| --- | --- |
| `name` | уникальное имя узла — под ним его видят группы и правила |
| `type` | тип протокола |
| `server` | адрес сервера (домен или IP) |
| `port` | порт сервера |

Плюс общие необязательные поля (например, `udp` — разрешить ли UDP через прокси,
по умолчанию `false`; `ip-version`; привязка `interface-name` — о её смысле см.
[../../ARCHITECTURE.md](../../ARCHITECTURE.md), «interface в MetaCubeX ≠ выбор WAN»).

---

## Пример из нашего placeholder

В placeholder-конфиге секция `proxies` **пуста** — в ней закомментирован полный
пример VLESS + Reality (**Проверено в проекте**):

```yaml
proxies:
  # Example VLESS + TCP + Reality.
  # Replace all placeholder values.
  # - name: example-vless-reality
  #   type: vless
  #   server: example.com
  #   port: 443
  #   uuid: 00000000-0000-0000-0000-000000000000
  #   udp: true
  #
  #   tls: true
  #   network: tcp
  #   servername: www.example.com
  #   flow: xtls-rprx-vision
  #   packet-encoding: xudp
  #   client-fingerprint: chrome
  #   skip-cert-verify: false
  #
  #   reality-opts:
  #     public-key: "REPLACE_WITH_REALITY_PUBLIC_KEY"
  #     short-id: "REPLACE_WITH_SHORT_ID"
```

На его примере видна структура: четыре обязательных поля сверху, дальше —
специфичные для протокола (`uuid`, `flow`, `reality-opts`…). Не пытайтесь
запоминать их: у каждого типа свой набор, и собирать конфиг руками не нужно —
[link-generators](https://github.com/saymer-alt/link-generators) собирает его из
ваших ссылок и подписок.

---

## Какие бывают типы

По официальной документации ядро поддерживает **20+ типов** outbound'ов; среди
часто встречающихся на практике: `vless`, `vmess`, `trojan`, `ss` (Shadowsocks),
`hysteria2`, `tuic`, `wireguard`, `http`, `socks5`. Полный актуальный список и
параметры каждого — в [официальной документации](https://wiki.metacubex.one/ru/config/proxies/);
эта статья сознательно не каталог протоколов.

Кроме пользовательских серверов, в ядре есть **встроенные** выходы: `DIRECT`
(напрямую, без прокси) — вы уже видели его в правилах; упомянутый в группах
`REJECT` (запретить соединение).

---

## Заметка про WireGuard/AWG

У outbound'а типа `wireguard` есть собственные настройки IP stack. Они относятся
**только к этому outbound'у**, а не к TUN (разбор TUN и его stack —
[31-tun.md](31-tun.md)):

```yaml
ip-stack:
  mode: auto          # auto / gvisor / mips; mips = Mihomo IP Stack, не CPU-архитектура
  congestion-controller: cubic   # для Mihomo IP Stack: cubic / reno / bbr / bbr3
```

Полный набор параметров — в [официальной документации](https://wiki.metacubex.one/ru/config/proxies/).

Из истории совместимости: в Mihomo 1.19.31 исправлены `RandomPaddingAddition` и
`DisableCookies` для AmneziaWG v3 — это исправление работы существовавшего режима,
а не его появление.

---

## Узел ≠ группа

- **Узел (proxy)** — один конкретный сервер с параметрами подключения.
- **Группа (proxy-group)** — контейнер над узлами (и/или другими группами) с
  правилом выбора: вручную или автоматически. Разбор —
  [29-proxy-groups.md](29-proxy-groups.md).

Правила маршрутизации обычно ссылаются на **группу**, а не на отдельный узел —
поэтому смену сервера можно делать переключением в группе, не трогая правила.

---

## Что происходит, когда вы подставляете свои прокси

1. Заменяете секцию `proxies` (целиком или добавляете узлы) в своём
   `config.yaml`.
2. Имена узлов должны совпадать с теми, на которые ссылаются ваши `proxy-groups` и
   `rules` — переименовали узел, обновите группы/правила.
3. Если нужна исполняемая проверка конфига, сначала останавливаете сервис: `/opt/etc/init.d/S99mihomo stop`, затем `mihomo -d /opt/etc/mihomo -t`. Не запускайте второй Mihomo параллельно с работающим демоном.
4. Запускаете сервис: `/opt/etc/init.d/S99mihomo start`. Для обычной read-only проверки работающей установки используйте `mihomo-doctor.sh`.

При этом **ничего снаружи не меняется**: вход `7890`, интерфейс Proxy0, MagiTrickle,
watchdog — всё продолжает работать как работало. Меняется только то, куда ядро
отправляет трафик после своих правил — модель «поменяли конфиг Mihomo — поменяли всю
исходящую инфраструктуру, а Keenetic этого не заметил» из
[10-mihomo-eto.md](10-mihomo-eto.md).

Один нюанс доменных имён серверов: если ваш узел задан **доменом**, ядро резолвит
его через `proxy-server-nameserver` из DNS-блока —
[26-dns-i-fake-ip.md](26-dns-i-fake-ip.md).

---

## Чего в нашем placeholder нет

`proxy-providers` (получение набора серверов из HTTP/file/inline источника,
обновление и отдельный health-check) — возможность ядра, но в bootstrap проекта она
не настроена. Подробный разбор: [42-proxy-providers.md](42-proxy-providers.md).

---

## Куда идти дальше

- [29-proxy-groups.md](29-proxy-groups.md) — группы поверх узлов.
- [30-rules.md](30-rules.md) — как трафик направляется в узел/группу.
- [27-porty-i-config-yaml.md](27-porty-i-config-yaml.md) — входы ядра и общий
  уровень конфига.
- [10-mihomo-eto.md](10-mihomo-eto.md) — общая модель ядра.
