# 🛡️ Keenetic Auto Setup

**One-command toolkit that turns a Keenetic router into a self-healing smart gateway.**

Modern VPN/proxy stack (Mihomo + VLESS/Reality), DNS-based split tunneling (MagiTrickle), VoIP call stabilization, flash wear protection and a watchdog that repairs the tunnel on its own — installed and configured in one shot, ~2–3 minutes.

**English** · [Русский](#-русская-версия)

---

## Why I built Keenetic Auto Setup

It started with a simple wish: put a working VPN on a Keenetic router once — and stop constantly checking whether the tunnel is still alive. No more "something doesn't open", no more rebooting the router every evening, no more re-configuring things after every server change.

That did not stay simple for long. The more I used it, the clearer it became that the real problem is not "no VPN". It is that an ordinary home router welds routing, VPN and internet access into one rigid chain:

```
Client → Router → ISP → Internet
```

One pipe, one policy, no room to decide *what* goes *where*.

So the project grew into a full network complex, built on one idea: **the Keenetic becomes an independent network node that makes its own routing decisions**. Inside it, MagiTrickle decides which traffic goes where, and Mihomo acts as a router inside the router. Through different interfaces and policies, traffic can be sent directly, through AWG, SSTP, OpenConnect, Proxy0/Mihomo or any other available mechanism. Mihomo itself can hold many servers and whole subscriptions — while Keenetic sees nothing but a local SOCKS5 proxy on `127.0.0.1:7890`.

The key mental model:

> **Mihomo is a router inside the router.**
> Keenetic hands it traffic. What servers, protocols, balancing and failover sit behind that handoff is entirely Mihomo's business — and can be rebuilt without touching Keenetic.

Everything else in this project — the watchdog, the flash protection, the VoIP fixes — exists to make that node *boring*: it routes, it heals itself, and it doesn't need a caretaker.

---

## What it installs

| Component | Role |
| --- | --- |
| **Mihomo** (Clash Meta) | The routing core. Rule-based proxy engine with VLESS/Reality, subscriptions, load balancing. Listens on `127.0.0.1:7890`. |
| **Proxy0** | A Keenetic proxy interface bridging Keenetic → Mihomo (labeled `mihomo t2s0`, matching MagiTrickle's `t2s` numbering). The only bridge between the router and the proxy core. |
| **MagiTrickle** | The decision layer. DNS-based split tunneling: per domain/subnet it decides whether traffic goes direct or through a tunnel/policy. The installer enables Keenetic's DNS transit interception automatically so plain client DNS can't bypass this layer (DoH/DoT are unaffected). |
| **Watchdog** | Self-healing. Every 5 minutes verifies WAN, the proxy port and the end-to-end tunnel; restarts Mihomo only when Mihomo itself is the problem. |
| **bypass_wa** | VoIP fix. Marks Telegram/WhatsApp/WebRTC UDP (ports 1400/3478/3482) and routes it straight through the VPN, bypassing the proxy. |
| **S00ubifs** | Flash protection (RAM mode). Moves `/opt/tmp`, `/opt/var/log`, `/opt/var/run` into tmpfs so Entware stops wearing out the flash. |

---

## Architecture

A classic home network has exactly one path and no decisions:

```
Client → Router → ISP → Internet
```

Keenetic Auto Setup turns the router into a layered node where each level does one job:

```
Client (LAN)
      ↓
Keenetic ── MagiTrickle decides per domain/subnet
      ↓
Mihomo — router inside the router (127.0.0.1:7890)
      ↓
AWG / SSTP / OpenConnect / Proxy0 / MASQUE / …
      ↓
Internet
```

- **Keenetic** provides the platform: policy routing, interfaces, firewall hooks, cron. The toolkit integrates through KeeneticOS itself (`ndmc`/RCI, `netfilter.d`) instead of fighting it.
- **MagiTrickle** is the decision layer. It does not carry traffic; it looks at DNS queries and sends each domain the right way — YouTube through the tunnel, local banking direct, everything else by your rules. For that to hold, the installer enables Keenetic's DNS transit interception automatically: classic (port 53) queries addressed straight to an external resolver are redirected into Keenetic's DNS, where MagiTrickle sees them — `Client → Keenetic DNS → MagiTrickle → routing decision` — instead of silently skipping the decision layer. This covers classic DNS only; browsers using DoH/DoT bypass port 53 regardless.
- **Mihomo** is a full routing engine behind a single local SOCKS5 port: dozens of servers, multiple subscriptions at once, health checks, fallbacks, load balancing. Swap its config and you have swapped the entire egress infrastructure — Keenetic doesn't even notice.
- **Transports are interchangeable.** Entry and exit don't have to match: you can enter through one tunnel type and exit through another. Replace any transport without rebuilding the system.

Not everything goes through the proxy, and that's by design: different traffic types take different paths. VoIP goes around the proxy directly through the VPN (no laggy calls), local resources go direct, everything else follows your rules.

---

## How traffic routing actually works

The one-line model:

```
Client → Keenetic → MagiTrickle (which exit for this traffic?) → Internet
```

- **MagiTrickle is not a VPN.** It never carries traffic; it reads DNS queries, matches domains against your rules and sends each destination toward a chosen exit.
- **Exits are interchangeable.** The two paths into Mihomo: **Proxy0** — a Keenetic proxy interface (SOCKS5), convenient as a destination in per-client/per-segment rules — and **Mihomo's TUN interface** (`mitun0` is the common name for it) — a transparent IP-level path. Direct ISP, AWG, SSTP, OpenConnect and other interfaces are exits too.
- **Classification only sees domains that reach Keenetic's DNS.** That's why the installer keeps clients' DNS on the router (see [DNS and whitelist networks](#dns-and-whitelist-networks) below).
- **If a device builds its own VPN tunnel, Keenetic sees the tunnel — not the sites inside it.** Router-side selective routing can't pick per-site exits for traffic that never appears as individual connections.
- **Mihomo's own interface setting binds its outbound connections — it is not a router-wide WAN switch.** Traffic entering Mihomo via the TUN still leaves through the usual Keenetic routing (the WAN1/WAN2 example is in the HOWTO).

The full story — the three traffic paths, why MagiTrickle/`mitun0`/`ProxyN`/`7890`/DNS interception/Mihomo's interface setting are different levels of one design — is in **[ARCHITECTURE.md](ARCHITECTURE.md)** (RU). The practical walkthrough of the same topics is in [docs/HOWTO.md](docs/HOWTO.md), section "How traffic routing actually works".

---

## DNS and whitelist networks

- In this project, DNS is **part of the routing**: MagiTrickle classifies traffic by domain, so *which resolver Keenetic uses* is configuration, not a detail.
- In whitelist-style networks (where only approved resources are reachable), the DNS choice becomes critical: a resolver can be technically excellent and still be **unreachable from your network**, and operator-side interference with DNS answers is possible.
- The provider's DNS is usually the **most compatible** option in restricted networks — but it can be filtered or substituted, so it is not automatically the preferred choice in an ordinary network.
- Keenetic supports DoH and DoT natively (OS 3.0+). Encrypted upstreams are the better tool **when the chosen service is actually reachable from your network**; in Russian networks Yandex DNS is often a practical compromise, but availability is per-network and nobody can guarantee it for a specific operator.
- Even correct encrypted DNS does not mean the operator cannot affect access to specific resources at other levels.

The full resolver matrix, configuration steps and a dedicated troubleshooting scenario are in [docs/HOWTO.md](docs/HOWTO.md), section 6.2.

---

## Watchdog: it fixes itself

The watchdog runs from cron every 5 minutes and checks, in order:

1. **WAN** — directly, without Mihomo. Primary targets (Cloudflare, Google) first; if all of them fail, a whitelist fallback (gosuslugi.ru, ya.ru, mail.ru, vk.ru/vk.com) distinguishes "restricted network" from "no internet at all".
2. **Proxy port** — is Mihomo accepting connections on `127.0.0.1:7890`?
3. **End-to-end tunnel** — does a real request through `socks5h://` actually reach the internet?

The important principle: **a WAN outage does not mean Mihomo is broken.** If none of the WAN targets respond, the watchdog exits without restarting anything and waits for the ISP. A restart happens only when the network is confirmed up **and** the problem is confirmed to be in Mihomo or its tunnel — with a cooldown between restarts so a flaky upstream can't cause a restart storm.

Logs: `cat /opt/var/log/mihomo_watchdog.log`

---

## Use cases

**Split tunneling for the whole network.** The default scenario: every device behind the router gets per-domain routing without any client software. Install once, add domains to MagiTrickle, done — TVs, phones and laptops don't know a proxy exists.

**Browser-only proxy (FoxyProxy).** Don't want to route anything system-wide on your computer? Point a browser extension at the router's proxy port:

```
Browser → FoxyProxy (SOCKS5) → Keenetic :7890 → Mihomo → Internet
```

Enable `allow-lan: true` in Mihomo's config, set FoxyProxy to `<router-ip>:7890` (SOCKS5), and add patterns for just the sites you want proxied — for example ChatGPT, YouTube, Telegram Web, Gemini, Grok, Copilot, Threads, Instagram. Everything else in the browser — and on the whole computer — goes direct. No VPN client on the PC. Note this path bypasses MagiTrickle (the extension talks to Mihomo directly), so site selection here is done by the extension's patterns plus Mihomo's own rules. It covers web traffic; heavy UDP apps are better served by the network-level routing above.

**WebRTC caveat:** a SOCKS5 proxy covers the browser's ordinary web traffic — it does not automatically put every browser network mechanism on the same path. WebRTC can open its own UDP media path outside the proxy, so in a proxy scenario a site may learn network information that differs from the proxy exit (whether and what it learns depends on the browser, its version and your network). Check your browser's WebRTC settings and verify with a WebRTC test page — browser-specific advice is in the [HOWTO](docs/HOWTO.md). This applies to the browser-only scenario: with whole-network routing through Keenetic, UDP follows the router's policies.

**Stable VoIP behind a proxy.** Telegram/WhatsApp calls die when forced through a TCP proxy. `bypass_wa` marks that UDP and sends it through the VPN directly — calls connect fast and stop dropping.

**Small fleets (10–20 routers).** The watchdog has jitter, rate limiting and lock protection specifically so that a fleet of routers behind one server doesn't stampede it — born from operating ~20 devices.

---

## Supported hardware & modes

| | |
| --- | --- |
| **ARM / aarch64** (recommended) | `install.sh` — full stack: Mihomo, MagiTrickle, bypass_wa, watchdog, tmpfs |
| **MT7621 / mipsel** (legacy) | `install_7621.sh` — reduced stack (no MagiTrickle, no VoIP bypass), works around broken TLS with `--insecure` |
| **RAM** | 256 MB minimum. **128 MB devices are not supported** (tmpfs destabilizes them — verified in production) |
| **Modes** | `ram` (default; tmpfs protects internal flash) · `disk` (USB/SSD storage) |
| **Tested on** | Keenetic KN-1810, KN-3811, KN-1913 |

Not sure which installer you need? Run `opkg print-architecture` on the router: `aarch64-3.10` → `install.sh`, `mipsel-3.4` → `install_7621.sh`.

---

## Quick start

**1. Install** (SSH into the router, Entware required):

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/install.sh | sh
```

Old MT7621 router with broken TLS:

```bash
curl -k -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/install_7621.sh | sh
```

Install to external disk instead of RAM:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/install.sh | sh -s -- disk
```

> DNS transit interception is configured by the installer automatically — there is no manual post-install DNS step. See the architecture section above for why.

**2. Add your Mihomo config** (this step is mandatory — without it nothing will work):

```bash
nano /opt/etc/mihomo/config.yaml
```

A minimal working example:

```yaml
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info

proxies:
  - name: "server"
    type: vless
    server: "YOUR_SERVER"
    port: 443
    uuid: "YOUR_UUID"
    tls: true

proxy-groups:
  - name: "Proxy"
    type: select
    proxies:
      - "server"

rules:
  - GEOIP,private,DIRECT
  - MATCH,Proxy
```

**3. Restart and verify:**

```bash
/opt/etc/init.d/S99mihomo restart
/opt/etc/init.d/S99mihomo status
curl --proxy 127.0.0.1:7890 http://google.com/generate_204   # expect 204
```

**4. Watchdog check** — five minutes after install:

```bash
cat /opt/var/log/mihomo_watchdog.log    # expect "[OK] All good"
```

That's the short version. The complete walkthrough — Entware preparation, MagiTrickle, updates, rollback, diagnostics — is in **[docs/HOWTO.md](docs/HOWTO.md)** (также на русском: [docs/HOWTO_RU.md](docs/HOWTO_RU.md)).

---

## Updating & rollback

Update Mihomo to the latest upstream release without reinstalling anything:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/update-mihomo.sh | sh
```

The updater is built to fail safely: it downloads the new binary to `/tmp`, verifies it runs, tests it against your current `config.yaml`, checks free space, replaces the old binary and restarts the service — **rolling back automatically** at any failed step (architecture mismatch, config incompatibility, no space, service won't start). The backup lives temporarily in RAM (`/tmp`); no permanent backup is kept on `/opt`. Add `--force` to reinstall the same version. On MIPS (MT7621) the updater intentionally refuses to run — there are no official Mihomo binaries for that architecture.

The watchdog copy can be updated separately (`update-watchdog.sh`): sanity-marker check, syntax check, backup, atomic replace. See the [HOWTO](docs/HOWTO.md) for the details and for manual downgrade instructions.

---

## Ecosystem: link-generators

Config preparation lives in a companion project: **[saymer-alt/link-generators](https://github.com/saymer-alt/link-generators)** — a static, fully client-side web app ([saymer-alt.github.io/link-generators](https://saymer-alt.github.io/link-generators/)) with two tools:

- **Mihomo Config Builder** — assembles a ready `config.yaml` for Mihomo from proxy links (vless, vmess, trojan, ss, hysteria2, tuic, anytls, socks5, http and more), HTTP(S) subscriptions and WireGuard/AmneziaWG `.conf`/`.awg` files, with basic structural validation before you copy the result.
- **WARP MASQUE Links** — generates `masque://` link pairs for Cloudflare WARP from bot-provided YAML configs.

Everything runs in your browser: private keys, links and configs are never sent anywhere — the project has no server at all. Generate the config there, paste it into `/opt/etc/mihomo/config.yaml` here.

---

## Documentation

| Document | What's inside |
| --- | --- |
| **[docs/HOWTO.md](docs/HOWTO.md)** / [HOWTO_RU.md](docs/HOWTO_RU.md) | The complete step-by-step guide: preparation → install → config → MagiTrickle → watchdog → updates → troubleshooting |
| [docs/00-intro.md](docs/00-intro.md) | Why this project exists |
| [docs/01-architecture.md](docs/01-architecture.md) | Traffic flows and how decisions are made |
| [docs/02-quick-start.md](docs/02-quick-start.md) | Minimal setup (RU) |
| [docs/03-install.md](docs/03-install.md) | What `install.sh` actually does (RU) |
| [docs/04-watchdog.md](docs/04-watchdog.md) | Watchdog internals (RU) |
| [docs/05-bypass-wa.md](docs/05-bypass-wa.md) | VoIP bypass deep dive (RU) |
| [docs/06-s00ubifs.md](docs/06-s00ubifs.md) | tmpfs profiles and RAM limits (RU) |
| [docs/08-troubleshooting.md](docs/08-troubleshooting.md) | Symptom → cause → fix (RU) |
| [docs/09-limitations.md](docs/09-limitations.md) | Hard limits and honest boundaries (RU) |
| [ARCHITECTURE.md](ARCHITECTURE.md) | **The main architecture document (RU)** — how the routing actually works |
| [CHANGELOG.md](CHANGELOG.md) | Release history |

---

## License

[MIT](LICENSE)

---

# 🛡️ Русская версия

**Один запуск — и Keenetic превращается в самовосстанавливающийся умный шлюз.**

Современный VPN/proxy-стек (Mihomo + VLESS/Reality), DNS-сплит-роутинг (MagiTrickle), стабилизация VoIP-звонков, защита флеш-памяти и watchdog, который сам чинит туннель. Установка и настройка — одна команда, ~2–3 минуты.

[English](#-keenetic-auto-setup) · **Русский**

---

## Зачем я сделал Keenetic Auto Setup

Всё началось с простого желания: один раз поставить на Keenetic рабочий VPN — и перестать постоянно проверять, жив ли туннель. Чтобы не было «что-то не открывается», вечерних перезагрузок роутера и ручных правок конфигов после каждой смены сервера.

Простым это не осталось. Чем дальше, тем понятнее становилось: настоящая проблема не в «отсутствии VPN», а в том, что обычный домашний роутер жёстко сварил маршрутизацию, VPN и выход в интернет в одну цепочку:

```
Клиент → Роутер → Провайдер → Интернет
```

Одна труба, одна политика — и никакой возможности решать, *что* куда отправлять.

Так проект вырос в полноценный сетевой комплекс, построенный на одной идее: **Keenetic становится самостоятельным сетевым узлом, который сам принимает решения о маршрутизации**. Внутри него MagiTrickle решает, какой трафик куда идёт, а Mihomo выступает маршрутизатором внутри маршрутизатора. Через разные интерфейсы и политики трафик можно отправлять напрямую, через AWG, SSTP, OpenConnect, Proxy0/Mihomo и любые другие доступные механизмы. Сам Mihomo может содержать множество серверов и целых подписок — а Keenetic видит лишь локальный SOCKS5-прокси на `127.0.0.1:7890`.

Ключевая мысль всей архитектуры:

> **Mihomo — это маршрутизатор внутри маршрутизатора.**
> Keenetic просто передаёт ему трафик. Какие серверы, протоколы, балансировка и резервирование стоят за этой передачей — целиком забота Mihomo, и это можно перестраивать, не трогая Keenetic.

Всё остальное в проекте — watchdog, защита флешки, VoIP-фиксы — существует, чтобы этот узел был *скучным*: маршрутизирует, лечит себя сам и не требует присмотра.

---

## Что устанавливается

| Компонент | Роль |
| --- | --- |
| **Mihomo** (Clash Meta) | Ядро маршрутизации. Rule-based прокси-движок: VLESS/Reality, подписки, балансировка. Слушает `127.0.0.1:7890`. |
| **Proxy0** | Прокси-интерфейс Keenetic, мост Keenetic → Mihomo (подпись `mihomo t2s0` — в соответствии с нумерацией t2s в MagiTrickle). Единственная точка входа от роутера к прокси-ядру. |
| **MagiTrickle** | Уровень принятия решений. DNS-сплит-роутинг: по домену/подсети решает, куда идёт трафик — напрямую или через туннель/политику. Установщик автоматически включает перехват транзитного DNS на Keenetic, чтобы обычный DNS клиентов не обходил этот уровень (DoH/DoT не затрагиваются). |
| **Watchdog** | Самовосстановление. Каждые 5 минут проверяет WAN, порт прокси и сквозной туннель; перезапускает Mihomo только когда проблема действительно в нём. |
| **bypass_wa** | VoIP-фикс. Помечает UDP Telegram/WhatsApp/WebRTC (порты 1400/3478/3482) и отправляет его напрямую через VPN, минуя прокси. |
| **S00ubifs** | Защита флешки (RAM-режим). Переносит `/opt/tmp`, `/opt/var/log`, `/opt/var/run` в tmpfs, чтобы Entware не убивал флеш-память. |

---

## Архитектура

У классической домашней сети ровно один путь и ноль решений:

```
Клиент → Роутер → Провайдер → Интернет
```

Keenetic Auto Setup превращает роутер в многоуровневый узел, где каждый уровень занимается своим делом:

```
Клиент (LAN)
      ↓
Keenetic ── MagiTrickle решает по доменам/подсетям
      ↓
Mihomo — маршрутизатор внутри маршрутизатора (127.0.0.1:7890)
      ↓
AWG / SSTP / OpenConnect / Proxy0 / MASQUE / …
      ↓
Интернет
```

- **Keenetic** — платформа: policy-роутинг, интерфейсы, хуки firewall, cron. Тулкит интегрируется через механизмы самой KeeneticOS (`ndmc`/RCI, `netfilter.d`), а не борется с ними.
- **MagiTrickle** — уровень принятия решений. Он не передаёт трафик; он смотрит на DNS-запросы и отправляет каждый домен нужным путём: YouTube — через туннель, локальный банк — напрямую, остальное — по вашим правилам. Чтобы это работало, установщик автоматически включает перехват транзитного DNS на Keenetic: классические (порт 53) запросы, адресованные напрямую внешнему резолверу, перенаправляются в DNS Keenetic, где их видит MagiTrickle, — `Клиент → DNS Keenetic → MagiTrickle → решение о маршруте` — вместо тихого обхода уровня принятия решений. Это касается только классического DNS; браузеры с DoH/DoT проходят мимо порта 53 в любом случае.
- **Mihomo** — полноценный движок маршрутизации за одним локальным SOCKS5-портом: десятки серверов, несколько подписок одновременно, health-check'и, резервные маршруты, балансировка. Поменяли его конфиг — поменяли всю исходящую инфраструктуру, а Keenetic этого даже не заметил.
- **Транспорты взаимозаменяемы.** Вход и выход не обязаны совпадать: можно входить одним типом туннеля, а выходить в интернет другим. Любой транспорт заменяется без перестройки всей системы.

Не всё идёт через прокси — так задумано: разные типы трафика идут разными путями. VoIP идёт мимо прокси напрямую через VPN (звонки без лагов), локальные ресурсы — напрямую, остальное — по правилам.

---

## Как на самом деле работает маршрутизация

Модель в одну строку:

```
Клиент → Keenetic → MagiTrickle (какой выход для этого трафика?) → Интернет
```

- **MagiTrickle — не VPN.** Он не передаёт трафик; он читает DNS-запросы, сверяет домены с вашими правилами и направляет каждое назначение к выбранному выходу.
- **Выходы взаимозаменяемы.** Два пути в Mihomo: **Proxy0** — прокси-интерфейс Keenetic (SOCKS5), удобный как точка назначения в правилах для отдельных клиентов/сетей, и **TUN-интерфейс Mihomo** (`mitun0` — распространённое имя для него) — прозрачный путь на уровне IP. Прямой ISP, AWG, SSTP, OpenConnect и другие интерфейсы — тоже выходы.
- **Классификация видит только домены, дошедшие до DNS Keenetic.** Поэтому установщик удерживает DNS клиентов на роутере (см. [DNS и сети с белыми списками](#dns-и-сети-с-белыми-списками) ниже).
- **Если устройство само строит VPN-туннель, Keenetic видит туннель — а не сайты внутри него.** Точечная маршрутизация на роутере не может выбирать посайтовые выходы для трафика, который не появляется в виде отдельных соединений.
- **Настройка интерфейса самого Mihomo привязывает его исходящие соединения — это не переключатель WAN для роутера.** Трафик, вошедший в Mihomo через TUN, дальше выходит через обычную маршрутизацию Keenetic (пример WAN1/WAN2 — в HOWTO).

Полная картина — три пути трафика и почему MagiTrickle/`mitun0`/`ProxyN`/`7890`/DNS-перехват/настройка интерфейса Mihomo являются разными уровнями одного дизайна — в **[ARCHITECTURE.md](ARCHITECTURE.md)**. Практический разбор тех же тем — в [docs/HOWTO_RU.md](docs/HOWTO_RU.md), раздел «Как на самом деле работает маршрутизация».

---

## DNS и сети с белыми списками

- В этом проекте DNS — **часть маршрутизации**: MagiTrickle классифицирует трафик по доменам, поэтому *какой резолвер использует Keenetic* — это конфигурация, а не деталь.
- В сетях с белыми списками (где доступны только разрешённые ресурсы) выбор DNS становится критичным: резолвер может быть технически безупречным и при этом **недоступен из вашей сети**, а вмешательство оператора в DNS-ответы возможно.
- DNS провайдера — обычно **самый совместимый** вариант в ограниченных сетях, но он может подвергаться фильтрации и подмене, поэтому в обычной сети он не обязательно предпочтителен.
- Keenetic нативно поддерживает DoH и DoT (с OS 3.0). Шифрованные upstream'ы — лучший инструмент, **когда выбранный сервис реально доступен из вашей сети**; в российских сетях часто практичным компромиссом оказывается Yandex DNS, но доступность зависит от конкретной сети, и гарантировать её для конкретного оператора нельзя.
- Даже корректный шифрованный DNS не означает, что оператор не может влиять на доступность отдельных ресурсов на других уровнях.

Полная матрица резолверов, настройка и отдельный troubleshooting-сценарий — в [docs/HOWTO_RU.md](docs/HOWTO_RU.md), раздел 6.2.

---

## Watchdog: чинит себя сам

Watchdog запускается из cron каждые 5 минут и проверяет по порядку:

1. **WAN** — напрямую, без Mihomo. Сначала обычные цели (Cloudflare, Google); если недоступны все — whitelist-fallback (gosuslugi.ru, ya.ru, mail.ru, vk.ru/vk.com), который отличает «ограниченная сеть» от «интернета нет вообще».
2. **Порт прокси** — принимает ли Mihomo соединения на `127.0.0.1:7890`?
3. **Сквозной туннель** — доходит ли реальный запрос через `socks5h://` до интернета?

Важный принцип: **отсутствие WAN не означает, что сломан Mihomo.** Если не ответила ни одна WAN-цель, watchdog выходит, ничего не перезапуская, и ждёт провайдера. Рестарт происходит только когда сеть подтверждённо работает, **а** проблема подтверждённо в Mihomo или его туннеле — с cooldown'ом между рестартами, чтобы нестабильный upstream не устроил шторм перезапусков.

Логи: `cat /opt/var/log/mihomo_watchdog.log`

---

## Сценарии использования

**Сплит-роутинг для всей сети.** Сценарий по умолчанию: каждое устройство за роутером получает маршрутизацию по доменам без каких-либо клиентских программ. Установили один раз, добавили домены в MagiTrickle — телевизоры, телефоны и ноутбуки даже не знают, что существует прокси.

**Только браузер через прокси (FoxyProxy).** Не хотите заворачивать что-либо системно на компьютере? Направьте браузерное расширение на прокси-порт роутера:

```
Браузер → FoxyProxy (SOCKS5) → Keenetic :7890 → Mihomo → Интернет
```

Включите `allow-lan: true` в конфиге Mihomo, в FoxyProxy укажите `<ip-роутера>:7890` (SOCKS5) и добавьте шаблоны только для нужных сайтов — например ChatGPT, YouTube, Telegram Web, Gemini, Grok, Copilot, Threads, Instagram. Всё остальное в браузере — и на всём компьютере — ходит напрямую. VPN-клиент на ПК не нужен. Учтите: этот путь идёт мимо MagiTrickle (расширение обращается к Mihomo напрямую), поэтому выбор сайтов здесь делают шаблоны расширения плюс собственные правила Mihomo. Сценарий покрывает веб-трафик; «тяжёлому» UDP лучше подходит сетевой уровень из пункта выше.

**Предупреждение про WebRTC:** SOCKS5 покрывает обычный веб-трафик браузера — это не означает автоматически, что все сетевые механизмы браузера идут тем же путём. WebRTC может открыть собственный UDP-путь мимо прокси, поэтому в прокси-сценарии сайт может узнать о вашей сети информацию, отличающуюся от выхода прокси (что именно он узнает — зависит от браузера, его версии и вашей сети). Проверьте настройки WebRTC вашего браузера и убедитесь с помощью тестовой страницы WebRTC, что ничего нежелательного не раскрывается, — настройки для конкретных браузеров разобраны в [HOWTO](docs/HOWTO_RU.md). Это касается именно браузерного сценария: при маршрутизации всей сети через Keenetic UDP следует политикам роутера.

**Стабильный VoIP за прокси.** Звонки Telegram/WhatsApp умирают, когда их заставляют идти через TCP-прокси. `bypass_wa` помечает этот UDP и отправляет через VPN напрямую — звонки соединяются быстро и не отваливаются.

**Небольшие парки (10–20 роутеров).** В watchdog специально заложены jitter, rate limiting и lock-защита, чтобы парк роутеров за одним сервером не устроил ему шторм, — выросло из эксплуатации ~20 устройств.

---

## Поддерживаемое железо и режимы

| | |
| --- | --- |
| **ARM / aarch64** (рекомендуется) | `install.sh` — полный стек: Mihomo, MagiTrickle, bypass_wa, watchdog, tmpfs |
| **MT7621 / mipsel** (legacy) | `install_7621.sh` — сокращённый стек (без MagiTrickle и VoIP-обхода), обходит сломанный TLS через `--insecure` |
| **RAM** | минимум 256 МБ. **128 МБ не поддерживаются** (tmpfs дестабилизирует систему — проверено в продакшене) |
| **Режимы** | `ram` (по умолчанию; tmpfs защищает внутренний флеш) · `disk` (USB/SSD-накопитель) |
| **Проверено на** | Keenetic KN-1810, KN-3811, KN-1913 |

Не уверены, какой установщик нужен? Выполните на роутере `opkg print-architecture`: `aarch64-3.10` → `install.sh`, `mipsel-3.4` → `install_7621.sh`.

---

## Быстрый старт

**1. Установка** (SSH на роутер, требуется Entware):

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/install.sh | sh
```

Старый MT7621 со сломанным TLS:

```bash
curl -k -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/install_7621.sh | sh
```

Установка на внешний диск вместо RAM:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/install.sh | sh -s -- disk
```

> Перехват транзитного DNS настраивается установщиком автоматически — ручного post-install шага для DNS нет. Почему это важно — в разделе «Архитектура» выше.

**2. Добавьте конфиг Mihomo** (обязательный шаг — без него ничего не заработает):

```bash
nano /opt/etc/mihomo/config.yaml
```

Минимальный рабочий пример:

```yaml
mixed-port: 7890
allow-lan: true
mode: rule
log-level: info

proxies:
  - name: "server"
    type: vless
    server: "YOUR_SERVER"
    port: 443
    uuid: "YOUR_UUID"
    tls: true

proxy-groups:
  - name: "Proxy"
    type: select
    proxies:
      - "server"

rules:
  - GEOIP,private,DIRECT
  - MATCH,Proxy
```

**3. Перезапустите и проверьте:**

```bash
/opt/etc/init.d/S99mihomo restart
/opt/etc/init.d/S99mihomo status
curl --proxy 127.0.0.1:7890 http://google.com/generate_204   # ожидаем 204
```

**4. Проверка watchdog** — через пять минут после установки:

```bash
cat /opt/var/log/mihomo_watchdog.log    # ожидаем "[OK] All good"
```

Это короткая версия. Полное пошаговое руководство — подготовка, Entware, MagiTrickle, обновления, откат, диагностика — в **[docs/HOWTO_RU.md](docs/HOWTO_RU.md)**.

---

## Обновление и откат

Обновите Mihomo до свежего релиза без переустановки всего:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/update-mihomo.sh | sh
```

Updater построен так, чтобы безопасно падать: он скачивает новый бинарник в `/tmp`, проверяет, что тот запускается, тестирует его с вашим текущим `config.yaml`, проверяет свободное место, заменяет старый бинарник и перезапускает сервис — **с автоматическим откатом** на любом сбойном шаге (несовместимая архитектура, конфиг не принят, нет места, сервис не стартует). Backup временно живёт в RAM (`/tmp`); постоянной копии на `/opt` не создаётся. Ключ `--force` переустанавливает ту же версию. На MIPS (MT7621) updater намеренно отказывается работать — официальных бинарников Mihomo под эту архитектуру не существует.

Копию watchdog можно обновить отдельно (`update-watchdog.sh`): проверка sanity-маркера, проверка синтаксиса, backup, атомарная замена. Подробности и ручной даунгрейд — в [HOWTO](docs/HOWTO_RU.md).

---

## Экосистема: link-generators

Подготовка конфигов вынесена в отдельный проект: **[saymer-alt/link-generators](https://github.com/saymer-alt/link-generators)** — статическое полностью клиентское веб-приложение ([saymer-alt.github.io/link-generators](https://saymer-alt.github.io/link-generators/)) с двумя инструментами:

- **Mihomo Config Builder** — собирает готовый `config.yaml` для Mihomo из proxy-ссылок (vless, vmess, trojan, ss, hysteria2, tuic, anytls, socks5, http и других), HTTP(S)-подписок и файлов WireGuard/AmneziaWG (`.conf`/`.awg`), с базовой структурной проверкой перед копированием.
- **WARP MASQUE Links** — генерирует пары ссылок `masque://` для Cloudflare WARP из YAML-конфигов, выданных ботом.

Всё выполняется прямо в браузере: приватные ключи, ссылки и конфиги никуда не отправляются — у проекта вообще нет сервера. Сгенерировали конфиг там — вставили в `/opt/etc/mihomo/config.yaml` здесь.

---

## Документация

| Документ | О чём |
| --- | --- |
| **[docs/HOWTO_RU.md](docs/HOWTO_RU.md)** / [HOWTO.md](docs/HOWTO.md) | Полное пошаговое руководство: подготовка → установка → конфигурация → MagiTrickle → watchdog → обновления → диагностика |
| [docs/00-intro.md](docs/00-intro.md) | Зачем всё это |
| [docs/01-architecture.md](docs/01-architecture.md) | Потоки трафика и принятие решений |
| [docs/02-quick-start.md](docs/02-quick-start.md) | Минимальная установка |
| [docs/03-install.md](docs/03-install.md) | Что именно делает `install.sh` |
| [docs/04-watchdog.md](docs/04-watchdog.md) | Устройство watchdog |
| [docs/05-bypass-wa.md](docs/05-bypass-wa.md) | Подробно про VoIP-обход |
| [docs/06-s00ubifs.md](docs/06-s00ubifs.md) | Профили tmpfs и лимиты RAM |
| [docs/08-troubleshooting.md](docs/08-troubleshooting.md) | Симптом → причина → решение |
| [docs/09-limitations.md](docs/09-limitations.md) | Жёсткие границы проекта |
| [ARCHITECTURE.md](ARCHITECTURE.md) | **Главная архитектурная глава** — как реально устроена маршрутизация |
| [CHANGELOG.md](CHANGELOG.md) | История изменений |

---

## Лицензия

[MIT](LICENSE)
