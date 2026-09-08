# HOWTO — the complete guide

How to prepare, install, configure and operate Keenetic Auto Setup properly.

README answers *"what is this and how do I start"*; this document answers *"how do I use it right"*. Deep dives on individual components live in `docs/00–10` (Russian) — linked where relevant.

**Русская версия:** [HOWTO_RU.md](HOWTO_RU.md)

---

## Table of contents

- [How traffic routing actually works](#how-traffic-routing-actually-works)
1. [Before you start](#1-before-you-start)
2. [Preparing Keenetic and Entware](#2-preparing-keenetic-and-entware)
3. [Installation](#3-installation)
4. [RAM vs disk mode](#4-ram-vs-disk-mode)
5. [Configuring Mihomo](#5-configuring-mihomo)
6. [MagiTrickle](#6-magitrickle)
7. [Watchdog in operation](#7-watchdog-in-operation)
8. [Updating Mihomo](#8-updating-mihomo)
9. [Updating the watchdog](#9-updating-the-watchdog)
10. [Rollback](#10-rollback)
11. [Diagnostics quick reference](#11-diagnostics-quick-reference)
12. [Troubleshooting](#12-troubleshooting)
13. [MT7621 / mipsel specifics](#13-mt7621--mipsel-specifics)
14. [Known limits](#14-known-limits)

---

## How traffic routing actually works

Everything else in this document — DNS settings, watchdog, Mihomo, warnings — only makes sense once the underlying model is clear. Read this before installing; the rest of the guide assumes it.

### The mental model

```
Client → Keenetic → MagiTrickle (which exit for this traffic?) → Internet
```

- **Keenetic** is the platform: interfaces, connection policies, firewall, DNS.
- **MagiTrickle is not a VPN and does not carry traffic.** It is the decision layer: it intercepts DNS on the interfaces it is configured for, remembers which IPs belong to which domains, and applies policy routing so that traffic to a matched destination leaves through the exit *you* chose for it. Per its documentation it works by substituting the DNS on selected interfaces and mapping answers to domains; routing is done with firewall marks and policy rules — nothing is tunneled by MagiTrickle itself.
- **Exits are interchangeable.** Direct ISP, AWG, SSTP, OpenConnect, WireGuard, Mihomo — all are just destinations a policy can point at. This is the whole point of the project: swap an exit without rebuilding the system.

The full picture:

```text
Client
  │
  ├── DNS → Keenetic DNS → MagiTrickle
  │                          (classification)
  └── traffic → Keenetic
                    │
             MagiTrickle decision
                    │
          ┌─────────┼─────────┐
          ▼         ▼         ▼
        DIRECT     mitun0    Proxy0
                     │         │
                     ▼         ▼
                   Mihomo    Mihomo
                     │
              proxy outbounds
                     │
                     ▼
                  Internet
```

### Five things that are easy to confuse

- **Whole-network VPN** — everything goes into one tunnel. Simple, all-or-nothing.
- **Selective (per-site) routing** — each destination goes its own way. This project's model.
- **DNS classification** — how the system knows which site is which: by watching DNS queries and mapping domains to IPs.
- **A VPN tunnel** — one possible *exit* (a transport), not the routing itself.
- **Mihomo** — a routing engine living behind one of the exits. Not "the VPN": it can hold many servers, subscriptions and balancing policies, and Keenetic sees it as a single local destination.

### MagiTrickle 101

MagiTrickle sits on the router, watches DNS, and decides per domain which exit interface the traffic should use. It is not a VPN and not the proxy itself — it is the decision maker; the interface a decision points at does the actual carrying.

Its official model (from the [MagiTrickle documentation](https://magitrickle.dev/)) is simple:

- **Group** — a named container that binds a set of domains to one exit. It can be toggled on/off and reordered ("VPN", "Direct", "Torrents" — whatever you name it).
- **Interface** — a per-group setting: the Keenetic interface the group's traffic leaves through (Proxy0, mitun0, a VPN interface, ...).
- **Rule** — a domain matcher inside the group. Each rule has a **Type** and a **Condition**: the type defines *how* to match (namespace = domain plus all subdomains, wildcard, exact domain, regular expression), the condition is *what* to match (`youtube.com`).

So the decision pipeline for one site looks like:

```text
youtube.com
     ↓
  Rule   (type: namespace, condition: youtube.com)
     ↓
  Group "VPN"  (interface: mitun0)
     ↓
  mitun0 → Mihomo
```

Again: MagiTrickle does not carry this traffic and does not proxy it — it decides where it must go. Everything else in this document is about keeping that decision informed and the exits healthy.

**DNS and the interfaces MagiTrickle watches.** All of the above only works for domains MagiTrickle actually sees — which is exactly why the next subsection is about keeping clients' DNS on the router. MagiTrickle's config declares where it substitutes DNS:

```yaml
link:
  - br0
  - br1
```

Per the official docs, `link` is the list of interfaces on which MagiTrickle performs the DNS substitution — by default `br0` and `br1`, the Entware-side names of the router's bridges (`br0` is the home segment). In practice:

```text
192.168.1.0/24 (home)  → br0 → MagiTrickle intercepts DNS → classification works
192.168.2.0/24 (new)   → brX → not in the list → no DNS substitution → no classification
```

So when you create an additional LAN/Wi-Fi segment, remember: MagiTrickle must be pointed at that interface too — add it to `link:` in its config or adjust the interface list in its web UI. DoH/DoT remain a separate case (see the next subsection): encrypted client DNS never touches the substitution point at all.

This is deliberately not a full MagiTrickle manual — for the complete UI, rule-type and config reference, use the [official documentation](https://magitrickle.dev/).

### Why clients must use the router's DNS

The decision layer classifies by domain, and it only sees domains that pass through the DNS it watches. So the client's plain DNS should go through Keenetic:

```
Client → Keenetic DNS → MagiTrickle → routing decision
```

If a device sends its queries straight to an external resolver, part of the DNS path bypasses the controlled point, and selective routing for that device becomes guesswork. That is why the installer enables DNS transit interception (section 6.1). Two things it is *not*: it is not a ban on any particular public DNS — the router itself can happily use the upstream you choose (section 6.2) — and it is not a DoH/DoT protection, since encrypted client-side DNS bypasses port 53 regardless.

### Why a VPN client on the device defeats router routing

The router can route a client's traffic while that traffic reaches the router as ordinary traffic — individual connections it can see and classify:

```
without client VPN:
  Client ── site A / site B / site C ──> Keenetic+MagiTrickle ── per-site decision ──> DIRECT / mitun0 / Mihomo
```

If the client establishes its own VPN tunnel, the picture changes:

```
with client VPN:
  Client ══ [ one encrypted tunnel: A+B+C inside ] ══> Keenetic ── sees the tunnel, not the sites ──> tunnel exit
```

In the usual client-VPN model the device encrypts and encapsulates its traffic into a single stream toward the VPN endpoint. Keenetic then sees (mostly) that stream, not the individual sites inside it — so MagiTrickle cannot make per-site decisions about traffic that never appears as individual connections. Details vary by VPN type and client settings, but this is the model to keep in mind: router-side selective routing and client-side VPNs solve the same problem at different places, and the router only controls what reaches it as plain traffic.

### Two ways into Mihomo: the proxy interface (ProxyN) and mitun0

The project ships the first path and supports the second:

- **The Mihomo proxy interface** — a Keenetic *proxy interface* (SOCKS5 to `127.0.0.1:7890`), created and configured by the installer. On a clean router it gets the ID `Proxy0`; if that ID is taken, Keenetic assigns the next free one (`Proxy1`, `Proxy2`, ...) — hence the general name `ProxyN`. Its human-readable label follows the same number (`mihomo t2s0`, `mihomo t2s1`, ...). Because it is a first-class Keenetic interface, it can be used as a destination in connection policies — per client or per segment. This is the historical path and remains the convenient "explicit destination point" in Keenetic rules.
- **Mihomo's TUN interface** — the transparent, IP-level path. Mihomo creates a TUN device whose name is set in Mihomo's own config (`tun` settings, `device-name` parameter); `mitun0` is the name commonly used for it in Keenetic setups. Keenetic sees it as a regular interface, so it can likewise be pointed at by policies. Traffic entering the TUN is plain IP traffic that Mihomo then routes by its own rules. This path is configured in Mihomo's `config.yaml`, not by the installer.

In short: `mitun0` fits best as the primary transparent path for IP traffic; Proxy0 fits best as a separate destination that Keenetic rules can reference directly. Both end up inside the same Mihomo.

### Mihomo basics

Mihomo is the exit engine. It receives traffic from the two entrances above and then acts according to its own `config.yaml`:

```text
MagiTrickle
     ↓
  mitun0
     ↓
  Mihomo ── rules ──> VLESS / WireGuard(AWG) / other proxies
```

```text
Browser
   ↓
FoxyProxy
   ↓
Keenetic :7890
   ↓
Mihomo
```

What you need to understand for this project:

- **Mihomo accepts traffic** from both entrances: the TUN (`mitun0`) for transparent IP traffic, and the mixed port `7890` for proxy-based clients (FoxyProxy in the browser, Proxy0 on the Keenetic side, or anything speaking SOCKS5/HTTP to the router).
- **An outbound is simply one of the destinations configured in Mihomo** — the entries in its `proxies`/`proxy-groups` (for example VLESS/Reality servers, WireGuard-style tunnels, SOCKS or HTTP relays). "Route via Mihomo" always means "Mihomo picks one of its outbounds per its own rules".
- **Why `mitun0` exists** — so that plain IP traffic can enter Mihomo transparently, without per-application proxy settings (section above).
- **Why Proxy0 remains** — because Keenetic rules can reference it directly; it is the natural destination for proxy-based policies on specific clients or segments.
- **Mihomo's config is its own domain.** This project installs and watches Mihomo, but does not attempt to replace its documentation — for proxies, groups, rules and TUN options use the [official Mihomo wiki](https://wiki.metacubex.one/) (TUN specifics: [inbound/tun](https://wiki.metacubex.one/en/config/inbound/tun/)). To *generate* a config from your links/subscriptions, see [link-generators](https://github.com/saymer-alt/link-generators).

### Mihomo's interface setting ≠ Keenetic routing

Three different concepts are easy to merge into one — keep them apart:

1. **Mihomo interface** — the Linux interface Mihomo binds its **own outbound connections** to (`interface-name` in the config / MetaCubeX settings; per official docs: *"mihomo's traffic outbound interface"*). Our `mihomo-interface-check.sh` exists exactly to pick this: it lists usable WAN interfaces and prints ready `interface-name:` lines.
2. **Mihomo inbound** — where clients connect to Mihomo: the mixed port `7890`, or the TUN (`mitun0`).
3. **Keenetic routing** — the kernel-level default gateway / policies that decide where traffic actually leaves the router once it is handed to the routing tables.

The practical consequence (typical behavior on a dual-WAN router — verify on your own setup):

```text
WAN1 = ISP A (default gateway)      WAN2 = ISP B
Mihomo interface-name = WAN2

Client → 127.0.0.1:7890 → Mihomo → selected proxy → dials bound to WAN2   ✅ exits via ISP B
Client → mitun0 → Mihomo (TUN) → traffic handed to kernel routing → default gateway   ✅ exits via ISP A
```

In other words: **the MetaCubeX interface setting is not a WAN selector for the router.** It binds Mihomo's own outbound sockets — notably the connections to your proxy servers. Traffic that enters through `mitun0` is subject to Mihomo's rules like any other inbound, and whatever leaves it as unbound/plain traffic follows the usual Keenetic routing tables — i.e. the default gateway (ISP A above). Related TUN options to know about: `auto-route` (pulls traffic into the TUN) and `auto-detect-interface` (auto-detects the outbound interface — the docs explicitly recommend setting the interface manually on devices attached to several outbound interfaces at once). If you need per-path WAN selection for TUN traffic, that is a Keenetic policy-routing job, not a MetaCubeX checkbox.

### Mihomo runs fine without a web UI

Mihomo is the network daemon; MetaCubeX-style dashboards (metacubexd, yacd, zashboard) are only control/monitoring interfaces on top of its REST API (`external-controller`, by default bound to `127.0.0.1:9090`). The daemon works perfectly with no dashboard at all — and this project's default installation sets up exactly that: the daemon, no web UI on the router.

- A dashboard can live **on the router** (`external-ui`: static page files served by Mihomo's API at `/ui`) — disk space, not a separate process.
- Or **on another device entirely**: public dashboards (e.g. metacubexd's hosted pages) can connect to the router's API remotely — the router then hosts nothing but the daemon.
- Either way, the UI is optional tooling, not a part of Mihomo that must be installed.

**Security:** the controller API can change Mihomo's runtime behavior — do not expose it to the WAN. Keep the default localhost binding or LAN-only, always set `secret:`, and for remote management reach the API through a VPN or an SSH tunnel (`ssh -L 9090:127.0.0.1:9090 root@router`) instead of opening the port.

### Separate Wi-Fi/LAN segments as a practical use case

KeeneticOS lets you create additional network segments — extra guest Wi-Fi networks (per band) and wired segments, each with its own subnet and DHCP — and bind them to connection policies. The exact number of segments available depends on the model and OS version; check your web UI's *Segments* page rather than any fixed figure. A illustrative layout (an example, not a required configuration):

```
Wi-Fi 1 (Home)  → ISP direct
Wi-Fi 2         → Proxy0 → Mihomo
Wi-Fi 3         → mitun0 → Mihomo (TUN)
```

One important nuance: **creating a segment does not automatically put it under MagiTrickle.** MagiTrickle intercepts DNS on the interfaces listed in its configuration — by default `br0` and `br1` (the Entware-side names of the router's bridges; `br0` is the home segment). A newly created segment has its own interface name, so:

```
192.168.1.0/24 (br0)  → MagiTrickle works
192.168.2.0/24 (brX)  → new segment — not covered automatically
                        → add it to MagiTrickle's config (`link:` list) or enable it in the MagiTrickle web UI
```

### Advanced notes: tunnels through Mihomo, and WARP colo

- **Chaining a router-side tunnel through Mihomo.** Keenetic can build its own tunnels (AWG, SSTP, OpenConnect, WireGuard). An advanced setup can route such a tunnel's traffic through a Mihomo proxy — the chain then exits with the public IP/country of the remote proxy. Nested tunnels make MTU especially important: the right value is specific to each chain (one of our WARP-based schemes runs happily at 1200 — that is an example, not a recommendation). See the MTU item in [Troubleshooting](#12-troubleshooting).
- **WARP / MASQUE and Cloudflare colo.** Changing the Cloudflare colo does **not** change your exit country or public IP by itself — colo and exit-IP geolocation are different things. In practice, though, a different colo can improve how some services (e.g. Telegram or YouTube) behave even when the exit IP stays the same. So colo has practical value, but it is not a way to "pick an exit country". For exploring which colos are reachable/selectable there is [vernette/warpscout](https://github.com/vernette/warpscout) — a research tool; see its own docs.

### DNS ≠ routing

- DNS answers the question: *"which IP belongs to this domain?"*
- Routing answers the question: *"where do I send traffic to that destination?"*

They are related — in this project, routing decisions are *driven* by DNS classification — but they are different jobs done by different components. This is why DNS problems masquerade as routing problems (section 6.2, [Troubleshooting](#12-troubleshooting)), and why fixing DNS often fixes "broken routing" without touching Mihomo.

### "Everything through VPN" vs selective routing

```
Ordinary VPN:   everything ──────────────> VPN

This project:   site A  → DIRECT
                site B  → mitun0 (Mihomo TUN)
                site C  → Mihomo (Proxy0)
                VoIP    → bypass_wa → VPN directly
                local   → DIRECT
```

### How the individual warnings fit this model

- **Clients' DNS must stay on the router** — section 6.1 (the classification depends on it).
- **Which upstream Keenetic resolves through** — section 6.2 (especially in whitelist networks).
- **Browser-only proxying has a WebRTC blind spot** — section 5.1 (the browser's own UDP path bypasses all of the above).
- **Client-side VPNs hide traffic from the router** — this section.
- **When "routing is broken", start with DNS** — [Troubleshooting](#12-troubleshooting), whitelist scenario.

---

## 1. Before you start

Check every point — most failed installs trace back to one of these:

| Requirement | How to check | Notes |
| --- | --- | --- |
| Keenetic router with **256 MB RAM or more** | router spec / `free` on the router | **128 MB devices are not supported.** tmpfs destabilizes them — verified in production, not a theoretical warning |
| **Entware installed** (`/opt` exists) | `opkg` command works | See step 2 |
| **SSH access** as root | `ssh root@192.168.1.1` | KeeneticOS: install the *SSH server* component (*General System Settings → Component options*); it enables automatically after installation |
| **Internet reachable from the router** | `opkg update` succeeds | DNS and correct time are the usual blockers (see [Troubleshooting](#12-troubleshooting)) |

Tested on: KN-1810, KN-3811, KN-1913 (see [CHANGELOG](../CHANGELOG.md)).

Which installer do you need?

```bash
opkg print-architecture | awk '/^arch/{print $2}'
```

- `aarch64-3.10` (or `armv7-3.2`) → **`install.sh`** (full stack)
- `mipsel-3.4` → **`install_7621.sh`** (legacy, reduced stack — see [section 13](#13-mt7621--mipsel-specifics))

---

## 2. Preparing Keenetic and Entware

The toolkit installs *into* Entware — it does not install Entware itself.

1. In KeeneticOS, enable the OPKG/Entware component (*General settings → Opkg / Entware* or via the *KeeneticOS components* menu, depending on firmware version) and select a storage location: internal storage (on models that support it) or a USB drive formatted as ext4.
2. Reboot when the component asks.
3. Verify from SSH:

```bash
ls /opt                    # Entware root must exist
opkg update                # must end without errors
date                       # wrong time → SSL errors later
```

If `opkg update` fails: fix DNS (`cat /opt/etc/resolv.conf`, try `echo "nameserver 1.1.1.1" > /opt/etc/resolv.conf`) and time (`ntpd -q -p pool.ntp.org`) first — these are the two most common causes.

---

## 3. Installation

### 3.1 The command

**Modern routers (ARM, recommended):**

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/install.sh | sh
```

**Old routers (MT7621/mipsel)** — use the legacy installer, it works around broken TLS:

```bash
curl -k -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/install_7621.sh | sh
```

### 3.2 What `install.sh` actually does

In order:

1. `opkg update`, then installs `ca-bundle`, `curl`, `jq`, `nano`, `cron` (skips what's already there).
2. Creates the `bypass_wa` routing policy (only if it doesn't exist).
3. Enables Keenetic **DNS transit interception** (`dns-proxy intercept enable`, then `system configuration save` — applied only if not already on): classic port-53 queries from LAN clients addressed straight to external resolvers are redirected into the router's DNS proxy, where MagiTrickle sees them (details in [section 6.1](#6-magitrickle)). This is part of the automatic installation — no manual post-install DNS step. Classic DNS only; DoH/DoT are not affected.
4. **RAM mode only:** downloads `S00ubifs` to `/opt/etc/init.d/` and starts it (tmpfs for `/opt/tmp`, `/opt/var/log`, `/opt/var/run`).
5. Detects the architecture and downloads the matching **mihomo `.ipk`** from the releases of [`saymer-alt/entware-go`](https://github.com/saymer-alt/entware-go) (GitHub API with three fallbacks: jq → grep on JSON → repeated request → HTML scraping).
6. **Creates the Proxy0 interface** — the only bridge Keenetic → Mihomo — pointing at `127.0.0.1:7890` (SOCKS5, UDP enabled), human-readable name `mihomo t2s0`, and saves the config.
7. Installs **MagiTrickle** (adds its package repo, installs, starts).
8. Installs the VoIP bypass hook `020-bypass_wa.sh` into `/opt/etc/ndm/netfilter.d/`.
9. Installs the **watchdog** into `/opt/etc/cron.5mins/` and wires it into cron (a run-parts `cron.5mins` entry is reused if present; otherwise a direct crontab line is added).
10. Restarts `S99mihomo` and checks that port `7890` is listening.

### 3.3 Is it safe to re-run?

The installer is written to be idempotent: every modifying step first checks whether the object already exists (packages, policy, Proxy0, crontab entry). Re-running it will not duplicate things.

One caveat: the mihomo `.ipk` is downloaded on every run — `opkg` will simply skip it if the same version is already installed.

Another caveat: **if Proxy0 already exists, its configuration is left untouched** (including the human-readable description). That branch is deliberately hands-off: the installer never rewrites persistent router config that already works.

The same applies to DNS transit interception: the installer checks the current state first and enables it (saving the config) only when it wasn't enabled. If you deliberately keep DNS transit open on a specific router, remove that block from the installer before re-running it — a re-run would turn it back on.

### 3.4 Expected result

```text
[setup] ...
[OK] Done
```

A `WARN ... port 7890 not listening` at the end almost always means `config.yaml` is missing or invalid — proceed to section 5.

---

## 4. RAM vs disk mode

`install.sh [ram|disk]`, default `ram`.

| | `ram` (default) | `disk` |
| --- | --- | --- |
| Logs, tmp, run-pid files | tmpfs (RAM) via `S00ubifs` | stay on storage |
| Flash wear | minimized | normal Entware wear |
| Data after reboot | logs are gone (by design) | preserved |
| Best for | internal flash, long-term 24/7 | low-RAM devices, when persistent logs matter |

`S00ubifs` adapts tmpfs sizes to available RAM (profiles for <40 MB, <80 MB, ≥80 MB free). Details: [docs/06-s00ubifs.md](06-s00ubifs.md).

If you chose wrong: re-running the installer with the other mode is safe (steps already done are skipped), but remove the mode's leftovers yourself — e.g. `/opt/etc/init.d/S00ubifs` when switching to `disk`.

---

## 5. Configuring Mihomo

Nothing works until a valid config exists. **After installation this step is mandatory.**

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

Notes:

- `allow-lan: true` exists **for LAN clients, not for the router**: Keenetic itself reaches Mihomo over `127.0.0.1` regardless of this setting. What it changes is that port `7890` becomes reachable from your LAN — which is the point for `browser/FoxyProxy → router:7890`, other LAN/Wi-Fi clients, or a remote home/office network. The security boundary stays with you: this is not a reason to open `7890` to the WAN — keep the firewall closed on it, and be even more careful with Mihomo's controller API/dashboard.
- DoH: fast resolvers are often unstable ones. Sticks with proven endpoints — `https://cloudflare-dns.com/dns-query`, `https://dns.google/dns-query`, `https://dns.quad9.net/dns-query`. Note this is **Mihomo's own DNS inside the tunnel** — a different layer from Keenetic's upstream resolvers; see section 6.2 for the Keenetic side and whitelist networks.
- Outbound interface binding: run the bundled helper to get ready `interface-name:` lines for your WAN interfaces:

```bash
sh mihomo-interface-check.sh    # or curl it from the repo on the router
```

Apply and verify:

```bash
/opt/etc/init.d/S99mihomo restart
/opt/etc/init.d/S99mihomo status      # expect: alive
curl -x socks5://127.0.0.1:7890 https://ipinfo.io   # expect the proxy exit IP
```

You can also syntax-check a config without restarting:

```bash
mihomo -d /opt/etc/mihomo -t
```

Generating a config from your links/subscriptions instead of writing YAML by hand: [saymer-alt/link-generators](https://github.com/saymer-alt/link-generators) (runs fully client-side in the browser).

### 5.1 Browser-only proxy (FoxyProxy) and WebRTC

The browser scenario from the README's use cases: enable `allow-lan: true`, point a browser extension like FoxyProxy at `<router-ip>:7890` (SOCKS5), and add patterns for the sites you want proxied. That covers the browser's ordinary web traffic.

**WebRTC is a separate mechanism — treat it separately.** WebRTC establishes its own media paths (ICE/STUN) largely independently of the browser's proxy settings; browsers generally do not send WebRTC through a SOCKS5 proxy. So in a proxy scenario a site performing WebRTC/STUN checks may see network information that differs from the proxy exit — for example the public address as observed by a STUN server. Whether and what is exposed depends on the browser, its version and your network: modern browsers hide local LAN addresses behind mDNS names by default, but the reflexive (public) candidate behavior varies, and no single statement holds for every browser. This is not a guaranteed leak, and it is also not guaranteed protection — verify on your setup.

What to do, per browser (mechanisms differ — none of these is universal):

- **Chromium-based (Chrome, Edge, ...):** no built-in per-user toggle; use an extension that controls WebRTC IP handling (uBlock Origin has a WebRTC protection setting; "WebRTC Network Limiter"-type extensions set the same browser policy).
- **Firefox:** `about:config` — `media.peerconnection.ice.default_address_only` and `media.peerconnection.ice.no_host` (limits ICE candidates), or disable WebRTC entirely with `media.peerconnection.enabled = false` if you don't need browser calls.
- **Safari:** no comparable built-in toggle — options are limited; if WebRTC isolation matters to you, treat Safari separately.

Verify afterwards with a WebRTC test page (e.g. browserleaks.com/webrtc) with the proxy enabled: the addresses the page reports should not contradict your expectations for the scenario.

Scope note: this warning applies **only to the browser-only proxy scenario**. With whole-network routing through Keenetic (the default setup), UDP — including WebRTC — follows the router's routing policies like any other traffic, and no browser-side WebRTC hardening is required by this project.

---

## 6. MagiTrickle

Installed by `install.sh` only (not by the 7621 installer). What Groups, Rules and Interfaces are — see *MagiTrickle 101* in the routing-model section at the top of this guide; this section is about operation.

MagiTrickle is the decision layer: it watches DNS queries and, per domain/subnet, chooses the route — direct or through a tunnel/policy such as Proxy0. It does not carry traffic itself; Keenetic's policy routing does that on MagiTrickle's instructions.

Practical picture after installation:

- Domains you route to the proxy go `LAN → Proxy0 → Mihomo → your servers → Internet`. In MagiTrickle/Keenetic the proxy interface shows up under its `t2s` numbering — the installer labels Proxy0 as **`mihomo t2s0`** so the mapping is obvious at a glance.
- Everything not matched goes direct.
- VoIP UDP (1400/3478/3482) never reaches Mihomo anyway — the `bypass_wa` netfilter hook marks it into the `bypass_wa` policy straight to the VPN interface.

For the web UI and rule management of MagiTrickle itself, see the upstream project's documentation (`bin.magitrickle.dev`), which is outside this repository.

### 6.1 DNS transit interception (installer-managed)

MagiTrickle can only decide for the domains it sees. The intended chain is:

```
Client → Keenetic DNS → MagiTrickle → routing decision
```

If a device sends its queries straight to an external resolver (a hardcoded `8.8.8.8`, an app with its own DNS), that traffic skips the decision layer entirely and the device's routing silently falls out of your rules. KeeneticOS has a matching feature: **transit DNS interception** (the web-UI setting sometimes labeled "transit DNS requests"; CLI `dns-proxy intercept enable`, off by default). Enabled, it redirects classic port-53 queries addressed to external servers into the router's DNS proxy, where MagiTrickle sees them.

The installer does this automatically — it is **part of the installation, not a manual post-install step**. It checks the current state first (`intercept enable` present in the running config), applies the command only when needed, and saves the persistent config only when something changed. Present on KeeneticOS 3.06+ (briefly absent in 3.08); on failure the installer warns and continues.

Boundaries, so nobody expects the wrong thing:

- This is **classic DNS only** — it is **not** DoH/DoT protection. A browser with "secure DNS" (DoH) enabled tunnels queries over HTTPS and bypasses port 53 regardless; that is a client-side setting.
- Devices with hardcoded external resolvers keep working — their queries are answered by the router's DNS proxy through its configured upstreams. The rare exception: something that must reach a *specific* external DNS server directly over port 53 (unusual split-DNS/AD or DNSSEC tooling). If you have that, revert per-router:

```
(config)> dns-proxy
(config-dnspx)> no intercept enable
(config-dnspx)> exit
(config)> system configuration save
```

… and remove the interception block from the installer for that router, since a re-run would enable it again. Everything else about your DNS setup (DoH/DoT upstreams in Mihomo's config, the router's own resolvers, DHCP-issued DNS) is left untouched.

Verify on the router:

```bash
ndmc -c "show running-config" | grep "intercept enable"   # expect one line in the dns-proxy block
```

Functional check from a client: a lookup with an explicitly set external resolver (`nslookup example.com 8.8.8.8`) should still succeed — answered via the router.

### 6.2 Choosing upstream DNS (and whitelist networks)

Section 6.1 controls *where clients send their DNS*. This section is the next layer: *where Keenetic itself resolves* — the upstream resolvers of the router's DNS proxy, the ones MagiTrickle's classification effectively depends on.

```
1. Control the client DNS path      → section 6.1 (transit interception)
2. Choose a suitable upstream DNS   → this section
3. In whitelist networks, verify the chosen DNS is actually reachable
4. Verify the result via diagnostics → sections 6.1, 11, 12
```

**Why DNS is part of the routing.** MagiTrickle decides per domain, and it only sees the domains that reach it. If the upstream resolver is unreachable, slow, filtered or returns unexpected answers, classification breaks even though MagiTrickle, Mihomo and the tunnel are perfectly healthy. In a whitelist-style network this is the most common failure point — and it looks exactly like "the router is broken".

**The whitelist problem.** In such a network you cannot pick a resolver by "which one is best". A service can support DoH and DoT, be documented everywhere, and still be unreachable from your network because its endpoints simply aren't on the whitelist. Also, the operator may interfere with DNS answers themselves (filtering, substitution, special addresses for blocked domains). So the real criteria are: is the service reachable from this network, and are the answers trustworthy — with "best" coming last.

**What Keenetic supports** (official [DoH/DoT documentation](https://support.netcraze.ru/air/nc-1613/en/31543-dot-and-doh-proxy-servers-for-dns-requests-encryption.html)):

- Native DoT and DoH upstreams since OS 3.0; requires the *DNS-over-TLS proxy* / *DNS-over-HTTPS proxy* system components.
- Web UI: *Internet safety → DNS configuration* — add a server by IP or FQDN plus the TLS domain (specifying the TLS domain prevents hijacking); connection interface can be pinned. Up to 8 DoT/DoH servers; when several are set, the resolver prioritizes them by measured response time. When DoT/DoH is configured, ISP-provided and manually registered plain DNS servers are not used.
- CLI equivalents: `dns-proxy tls upstream <address> <tls-domain>` (e.g. `dns-proxy tls upstream 1.1.1.1 cloudflare-dns.com`) and `dns-proxy https upstream <url>` (e.g. `dns-proxy https upstream https://dns.comss.one/dns-query`).
- Alternatively, OS 3.8+ has built-in public DNS filter profiles (AdGuard, Cloudflare, OpenDNS, Quad9, Yandex.DNS and others) that enable encrypted DNS without manual setup — note those are *filtering profiles*, check the filtering level before using one.

**The resolvers worth knowing** — all natively configurable in Keenetic:

| DNS | DoH | DoT | Keenetic | Whitelist / restrictions | Notes |
| --- | --- | --- | --- | --- | --- |
| Provider (ISP) DNS | — | — | always present (ISP/DHCP) | **Most compatible** with restricted networks (practical observation) | Can be filtered or substituted by the operator; not automatically the preferred choice in an unrestricted network |
| Yandex DNS `77.88.8.8` | `https://common.dot.dns.yandex.net/dns-query` | `common.dot.dns.yandex.net` | native DoT/DoH; also a built-in *Yandex.DNS* filter profile (OS 3.8+) | RU-hosted — a realistic candidate for restricted networks; availability depends on the specific network/operator | Official page [dns.yandex.com](https://dns.yandex.com/); tiers Basic / Safe / Family (`safe.` / `family.dot.dns.yandex.net`) |
| Cloudflare `1.1.1.1` | `https://cloudflare-dns.com/dns-query` | `cloudflare-dns.com` | native (used in Keenetic's own examples) | Foreign resolver — endpoint reachability in RU restricted networks is frequently degraded (widely reported) | Also the default DoH recommendation for Mihomo's *own* DNS (a different layer, section 5) |
| Google `8.8.8.8` | `https://dns.google/dns-query` | `dns.google` | native (used in Keenetic's own examples) | Same as Cloudflare | — |
| Quad9 `9.9.9.9` | `https://dns.quad9.net/dns-query` | `dns.quad9.net` | native (used in Keenetic's own examples) | Same as Cloudflare | Filters malware domains by default |
| AdGuard `94.140.14.14` | `https://dns.adguard-dns.com/dns-query` | `dns.adguard-dns.com` | native (used in Keenetic's own examples + filter profile) | Foreign; same caveats; ad/tracker filtering is on by default — `unfiltered.adguard-dns.com` for none | — |
| Comss.one | `https://dns.comss.one/dns-query` | `dns.comss.one` (also `dns.east.comss.one`) | native — listed in Keenetic's own DoH examples | RU-focused service; a community-practical option, availability per-network | Third-party RU service — whether to trust it is your call |

Availability of foreign resolvers in Russian restricted networks: widely reported, per-network, and changes over time (encrypted-DNS blocking across major ISPs has been publicly documented — see Human Rights Watch, *Disrupted, Throttled, and Blocked*, July 2025; OONI measurements). Treat every row above as "check in your network", not as a guarantee for any operator.

**The substitution warning.** Even your own DoH/DoT upstream does not automatically mean untampered results. The operator can affect access at other levels — routing/IP blackholing, DPI — and in restricted networks DNS answers for some domains may differ from what you expect (special addresses, NXDOMAIN, timeouts) regardless of which resolver you configured. This is a practical limitation of any single-router setup, not a defect of this project; there is no DNS setting that fixes IP-level blocking.

**Practical defaults:**

- Ordinary, unrestricted network: a set of 2–4 DoT/DoH servers from different providers (Keenetic prioritizes by response time), e.g. Cloudflare + Google + Quad9. Provider DNS works too, but leaves you exposed to operator filtering.
- Whitelist/restricted network: start from the provider DNS or Yandex DNS (most likely to be reachable), add one foreign DoT/DoH only if verified reachable, and re-check after every network/operator change.

Verify availability from *this* network, not from the internet:

```bash
ndmc -c "show dns-proxy"          # per-server stats: R.Sent / A.Rcvd per upstream
nslookup ya.ru 77.88.8.8          # plain DNS reachability of a candidate
```

An upstream whose `R.Sent` keeps growing while `A.Rcvd` stays at zero is unreachable from this network — swap it. A full step-by-step failure scenario lives in [Troubleshooting](#12-troubleshooting).

---

## 7. Watchdog in operation

### 7.1 What it checks, in order

Every 5 minutes (cron), with a 0–24 s random jitter (busybox-safe, `date +%s % 25` — no `$RANDOM`):

1. **WAN, directly and without Mihomo.** Primary targets: `cp.cloudflare.com`, `www.google.com`. If *all* of them fail, a whitelist fallback runs: `gosuslugi.ru`, `ya.ru`, `mail.ru`, `vk.ru`, `vk.com`. Any single response = WAN is up. No response at all → the watchdog exits **without restarting anything** — a dead WAN does not mean Mihomo is broken.
2. **Proxy port** — `127.0.0.1:7890` must accept TCP connections. Closed port → Mihomo probably crashed → restart.
3. **End-to-end tunnel** — a real request through `socks5h://127.0.0.1:7890` (DNS resolved through the tunnel) to google must succeed. Port open but tunnel dead → restart.

Restart rate limit: minimum 300 s between restarts, tracked in `/tmp/mihomo_watchdog.restart` with content validation. Lock file `/tmp/mihomo_watchdog.lock` prevents overlapping runs.

### 7.2 Reading the log

```bash
cat /opt/var/log/mihomo_watchdog.log
```

Typical lines and what they mean:

| Log line | Meaning |
| --- | --- |
| `[WAN] Connectivity OK via http://...` | WAN confirmed, checks continue |
| `[WAN] Primary targets unavailable, checking whitelist targets` | normal in restricted networks |
| `[WARN] WAN unreachable (primary + whitelist targets failed)` | no internet — watchdog correctly does nothing |
| `[RESTART] Mihomo port unreachable` | Mihomo crashed / didn't start — restarted |
| `[RESTART] Proxy tunnel check failed` | port open, tunnel dead — often the VPN server or config |
| `[RATE-LIMIT] Restart blocked (Ns < 300s)` | anti-loop protection working, not an error |
| `[OK] All good` | everything healthy |

Log rotation is built in: over 500 lines → trimmed to the last 300. Logs live in tmpfs (RAM mode) and are lost on reboot — by design.

### 7.3 Which copy actually runs?

Two copies can exist on a router — **check which one your crontab really executes** before updating:

```bash
grep mihomo_watchdog /opt/etc/crontab
```

- `install.sh` puts it in `/opt/etc/cron.5mins/mihomo_watchdog` (run-parts or direct line)
- `update-watchdog.sh` updates `/opt/bin/mihomo_watchdog.sh` (a different path!)

### 7.4 Manual debug run

```bash
sh -x /opt/etc/cron.5mins/mihomo_watchdog
```

Shows jitter, WAN target selection and every decision. Make sure `/opt/var/log` exists when running standalone (the installer creates it). Never edit the check order, lock logic, jitter or the "no WAN → no restart" rule — see [docs/04-watchdog.md](04-watchdog.md).

---

## 8. Updating Mihomo

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/update-mihomo.sh | sh
# or locally on the router:
sh update-mihomo.sh [--force]
```

What it does, step by step:

1. Lock file prevents parallel updates.
2. RAM gate: aborts on devices with less than 256 MB (protects against OOM).
3. Architecture check: aarch64 → `linux-arm64`, armv7 → `linux-armv7`. **MIPS/mipsel → refuses on purpose** (no official Mihomo binaries exist for it).
4. Fetches the latest release tag from `MetaCubeX/mihomo` (GitHub API, web-redirect fallback).
5. Compares with the installed version; same version → exit (unless `--force`).
6. Downloads the `.gz` binary to `/tmp` (curl, wget fallback), decompresses, runs `binary -v` (architecture sanity), then a **config test against your live `config.yaml`**.
7. Space check on the target filesystem (4 MB margin; stale `.backup/.old/.bak` files near the binary are cleaned; if space is still tight the service is stopped first to release "ghost" blocks).
8. Backs the old binary up to **`/tmp`** (RAM — not `/opt`), stops the service, replaces the binary, verifies version and startup (`pidof`, retried 5×).

**Automatic rollback** triggers on any failed step: binary test, config test, space, replace, version mismatch, service start. The previous binary is restored and the service is started again. A failed update should leave you exactly where you were.

Notes:

- The `/tmp` backup is removed after success — there is **no permanent backup on `/opt`**. For a manual downgrade, download the specific release binary yourself (see section 10).
- The updater looks for the binary via `find /opt -name mihomo | head -1` — if you keep several copies around, the choice is undefined; keep one.
- Prefer updating through this script over hand-editing: the hand-rolled procedure still exists for special cases in [mihomo_manual_update_arm.md](../mihomo_manual_update_arm.md) (RU).

---

## 9. Updating the watchdog

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/update-watchdog.sh | sh
```

The updater: downloads to a temp file → checks it is non-empty → checks the `MIHOMO WATCHDOG SCRIPT` sanity marker → `sh -n` syntax check → backs up the current copy to `/opt/var/log/mihomo_watchdog.sh.bak.<timestamp>` → atomic `mv` into place.

**Path caveat (important):** it updates `/opt/bin/mihomo_watchdog.sh`, while `install.sh` deploys to `/opt/etc/cron.5mins/mihomo_watchdog`. Before updating, verify which copy your crontab actually runs (section 7.3) — otherwise you update a file that is never executed.

---

## 10. Rollback

**Automatic (Mihomo updater).** Built into `update-mihomo.sh` at every critical step — nothing to do, the previous binary comes back on its own.

**Manual downgrade of Mihomo (ARM).** Since no permanent backup is kept:

1. Pick the version on [github.com/MetaCubeX/mihomo/releases](https://github.com/MetaCubeX/mihomo/releases).
2. On the router:

```bash
cd /tmp
wget https://github.com/MetaCubeX/mihomo/releases/download/vX.Y.Z/mihomo-linux-arm64-vX.Y.Z.gz
gzip -d mihomo-linux-arm64-vX.Y.Z.gz && chmod +x mihomo-linux-arm64-vX.Y.Z
./mihomo-linux-arm64-vX.Y.Z -v                       # must print a version
which mihomo                                          # e.g. /opt/bin/mihomo
/opt/etc/init.d/S99mihomo stop
mv /tmp/mihomo-linux-arm64-vX.Y.Z "$(which mihomo)"
/opt/etc/init.d/S99mihomo start
```

3. Verify: `mihomo -v`, `ps | grep mihomo`, then the proxy curl from section 5.

**Manual restore of the watchdog** (if `update-watchdog.sh` went wrong): the previous copy is in `/opt/var/log/mihomo_watchdog.sh.bak.<timestamp>` — `cp` it back to the path your crontab runs.

---

## 11. Diagnostics quick reference

| Question | Command | Healthy answer |
| --- | --- | --- |
| Mihomo alive? | `/opt/etc/init.d/S99mihomo status` | `alive` |
| Mihomo RAM usage? | `grep VmRSS /proc/$(pidof mihomo)/status` | measure before/after changes — no fixed norm |
| Proxy forwards traffic? | `curl -x socks5://127.0.0.1:7890 https://ipinfo.io` | exit IP of your server |
| Watchdog running? | `cat /opt/var/log/mihomo_watchdog.log` | recent `[OK] All good` |
| Cron entry present? | `grep mihomo_watchdog /opt/etc/crontab` | exactly one line |
| Cron daemon? | `ps | grep cron` | cron process present |
| VoIP hook applied? | `iptables -t mangle -L \| grep _CUST_BYPASS_WA_` | chain exists; counters grow during a call |
| tmpfs mounted? (ram mode) | `mount \| grep tmpfs` | `/opt/tmp`, `/opt/var/log`, `/opt/var/run` |
| Which WAN interfaces can Mihomo bind? | `sh mihomo-interface-check.sh` | ready `interface-name:` block |
| DNS transit interception on? | `ndmc -c "show running-config" \| grep intercept` | `intercept enable` in the `dns-proxy` block |
| Free space / RAM | `df -h /opt`, `free` | — |
| Time correct? | `date` | wrong time → SSL errors everywhere |

### A quick MT smoke test

After installing or changing routing, a one-minute check beats deep diagnostics. Create a MagiTrickle group named `MT TEST` containing a few test sites — commonly `2ip.ru`, `2ip.io`, `speedtest.net` — and route it through the exit you are testing (e.g. mitun0). Opening those pages then verifies several levels at once: the rule matches (the client really falls under the group), interception/routing works, traffic actually leaves through the expected exit, the public IP you see is the expected one, and speedtest confirms real data transfer. This is a smoke test, not an exhaustive diagnosis of the whole stack — it just fails fast and shows where to dig next.

### A universal step-by-step flow

When something does not work, walk the path in order — each step narrows the search:

1. Does the internet work on Keenetic itself? (WAN state — the watchdog log shows it, section 7)
2. Does the client's DNS arrive where expected? (transit interception on — section 6.1)
3. Does MagiTrickle see the query? (the client's segment must be covered by its interface list — MagiTrickle 101)
4. Does the right rule fire? (group/rule match in the MagiTrickle UI)
5. Does the traffic land in the expected exit — ProxyN or mitun0?
6. Does Mihomo accept the connection? (port `7890`/TUN alive — table above)
7. Is the correct outbound selected? (Mihomo rules/dashboard)
8. Does Mihomo's outbound use the expected Linux interface? (`interface-name` — remember: not a WAN switch)
9. What is the actual public IP? (2ip/ipinfo through the path)
10. Correct IP but the service still misbehaves? → DNS, MTU, IPv6 (only if you enabled it), TLS, or the service itself.

This is a mental model with checkpoints, not a per-component manual — where each component lives is covered by MagiTrickle 101 / Mihomo basics (top of this guide) and sections 5–7.

---

## 12. Troubleshooting

Symptom → cause → fix.

**`opkg update` fails / `curl: (6) Could not resolve host`**
DNS in Entware is broken. `echo "nameserver 1.1.1.1" > /opt/etc/resolv.conf` (and `8.8.8.8` as a second line), retry.

**SSL errors on downloads (`curl: (60)`, opkg certificate errors)**
Wrong clock. `ntpd -q -p pool.ntp.org`, check `date`, retry. Classic on routers that just booted.

**Internet works, proxy doesn't (esp. `proxy fail [502/...]`)**
Unstable/broken DoH servers in `config.yaml`. Switch to cloudflare-dns / dns.google / quad9. Also check the server itself: `curl -x socks5://127.0.0.1:7890 https://ipinfo.io`.

**`proxy fail [000/000]` / Mihomo won't start**
Almost always `config.yaml` — missing or invalid. `mihomo -d /opt/etc/mihomo -t` prints the real error; run `mihomo -d /opt/etc/mihomo` in foreground to see startup logs.

**"Everything installed but nothing opens"**
No `config.yaml` (step 5), or DNS on clients. Also check the router's own DNS still works — never "test" by changing default route/DNS config casually.

**Watchdog log empty**
Cron not running, or the crontab line points to a different copy of the script (section 7.3). Check `ps | grep cron` and `grep mihomo_watchdog /opt/etc/crontab`.

**Watchdog runs twice (duplicate log lines)**
Duplicate lines in `/opt/etc/crontab` — easy to create by hand-editing. Remove all `mihomo_watchdog` lines, re-add one, restart cron (`/opt/etc/init.d/S10cron restart`).

**`[RATE-LIMIT] Restart blocked` in the log**
Not an error — the 300 s anti-loop protection doing its job.

**Slow browsing / some sites broken, everything else fine**
Classic MTU symptom on tunnels. Set tunnel MTU to 1200–1300 (1500 breaks under many ISPs' DPI/PPPoE). This is an MTU problem, not a routing problem.

**VoIP still broken**
Check the hook: `iptables -t mangle -L _CUST_BYPASS_WA_ -v -n` — counters must grow during a call, and the `bypass_wa` policy must point to a working VPN interface. Rebuild firewall or reboot to re-trigger the netfilter hook. Not covered on MT7621 installs (section 13).

**Router became unstable after install**
Almost always a 128 MB device. The toolkit is not supported there; tmpfs pushes such systems over the edge. Use `disk` mode at most — or better hardware.

**Logs disappeared after reboot**
By design in `ram` mode (tmpfs). Persist them yourself if needed, or use `disk` mode.

**IPv6 behaves oddly (only if you enabled IPv6 yourself)**
The base configuration keeps IPv6 **off on purpose** — MagiTrickle ships with IPv6 disabled and configs generated by link-generators use `ipv6: false` — so the base scheme stays predictable. If you turned IPv6 on, re-check routing, DNS and that nothing bypasses the intended IPv4 path; after that, ordinary IPv6 diagnostics apply.

**A device with a hardcoded external DNS behaves differently / can't reach a specific external DNS server**
DNS transit interception (section 6.1) redirects classic port-53 queries into the router's DNS proxy. That is intended behavior; if a specific device truly needs direct access to its DNS server, revert interception for the whole router using the commands in section 6.1.

**Whitelist network: routing works, but some domains resolve wrongly or stop opening**
The classic trap — do not start with Mihomo. In a whitelist network this pattern is usually DNS-level, above MT/Mihomo. Diagnose in this order:

1. **Which DNS is actually in use.** Router upstreams: `ndmc -c "show ip name-server"` plus any DoT/DoH entries in the running config (`grep "tls upstream\|https upstream"`). Client side: transit interception on? (section 6.1) — if off, some devices may bypass your DNS entirely.
2. **Is the chosen DNS reachable from this network?** Whitelist networks can make even DoH/DoT-capable services unreachable. Query a candidate directly (`nslookup ya.ru 77.88.8.8`), then check per-upstream statistics in `show dns-proxy`: an upstream with growing `R.Sent` and zero `A.Rcvd` is dead from this network — replace it (section 6.2).
3. **What does the DNS return?** Resolve the problem domain via several resolvers and compare answers. Identical wrong/blocked answers across resolvers point at network-level filtering, not at your resolver choice.
4. **Is the provider DNS in play?** If no DoT/DoH is configured, Keenetic uses ISP servers — operator filtering/substitution applies to everything above them.
5. **DoH/DoT state:** are the *DNS-over-TLS/HTTPS proxy* components installed and servers configured (*Internet safety → DNS configuration*)? Are the TLS domains specified (unspecified domain = hijackable)?
6. **Does the DNS endpoint itself pass the whitelist?** Try resolving and reaching the DoH/DoT hostname through this network; if it fails, switch upstream to the provider DNS or Yandex DNS and re-test.
7. **Only now** look at MT/Mihomo: watchdog log (section 7), MagiTrickle rules, tunnel check (`curl -x socks5://127.0.0.1:7890 https://ipinfo.io`).

---

## 13. MT7621 / mipsel specifics

`install_7621.sh` exists because MT7621 routers ship a TLS stack that can't talk to modern servers ("`curl: (60)` and friends"). It works around that with `--insecure` and an HTTP mirror, which **trades certificate checking for compatibility** — MITM is theoretically possible; downloads come only from fixed, known sources and the fallback package is version-pinned, which keeps the practical risk low, but understand the trade.

Differences from `install.sh`:

| | install.sh | install_7621.sh |
| --- | --- | --- |
| Architecture | auto (aarch64/armv7) | mipsel |
| TLS | verified | `--insecure` + HTTP mirror |
| MagiTrickle | ✅ | ❌ not installed |
| bypass_wa (VoIP) | ✅ | ❌ not installed |
| Mihomo source | `saymer-alt/entware-go` releases (latest) | HTTP mirror, fallback to a pinned `mihomo_1.19.23-1` ipk from this repo's `mihomo` tag |
| Watchdog / Proxy0 / S00ubifs | ✅ | ✅ |

Mihomo on MIPS: there are **no official Mihomo binaries** for mipsel — `update-mihomo.sh` intentionally refuses to run there. Do not "fix" it by dropping in random builds; use the opkg package or build manually ([docs/09](09-limitations.md)).

Without MagiTrickle, routing on MT7621 is all-or-nothing (per-interface policies configured in KeeneticOS manually); without `bypass_wa`, VoIP calls ride through the proxy and will be as good (or bad) as your proxy handles UDP.

---

## 14. Known limits

- **128 MB RAM: not supported.** Not a recommendation — a production-verified failure mode.
- **The watchdog fixes Mihomo only.** It won't fix a dead VPN server, ISP outage, DNS or config mistakes.
- **Mihomo UDP handling has limits** — that's exactly why VoIP goes around it.
- **Entware is not a full Linux.** BusyBox quirks (`$RANDOM`, `pidof`, `ss`, `run-parts`), trimmed packages — keep that in mind before "modernizing" the scripts.
- **Logs in RAM vanish on reboot** — the flash-protection trade.
- **IPv6 is disabled on purpose** in the base configuration — for predictability, not by accident. Enabling it is an advanced change with its own verification (see Troubleshooting).
- **Docker is not part of this stack.** Mihomo on Keenetic is managed by its init script (`/opt/etc/init.d/S99mihomo`) — the watchdog and the updater use the same. `docker restart mihomo`-style commands belong to other environments.
- Committing to `main` in this repo changes what the next `curl | sh` executes — there is no staging or CI. Treat updates accordingly.

More boundaries and the reasoning behind them: [docs/09-limitations.md](09-limitations.md) (RU).
