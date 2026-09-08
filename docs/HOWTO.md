# HOWTO — the complete guide

How to prepare, install, configure and operate Keenetic Auto Setup properly.

README answers *"what is this and how do I start"*; this document answers *"how do I use it right"*. Deep dives on individual components live in `docs/00–10` (Russian) — linked where relevant.

**Русская версия:** [HOWTO_RU.md](HOWTO_RU.md)

---

## Table of contents

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

## 1. Before you start

Check every point — most failed installs trace back to one of these:

| Requirement | How to check | Notes |
| --- | --- | --- |
| Keenetic router with **256 MB RAM or more** | router spec / `free` on the router | **128 MB devices are not supported.** tmpfs destabilizes them — verified in production, not a theoretical warning |
| **Entware installed** (`/opt` exists) | `opkg` command works | See step 2 |
| **SSH access** as root | `ssh root@192.168.1.1` | KeeneticOS: enable SSH in *Management → Network* |
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

- `allow-lan: true` is what lets LAN devices (e.g. a browser with FoxyProxy) use `<router-ip>:7890` directly. With `false`, the proxy answers only on the router itself.
- DoH: fast resolvers are often unstable ones. Sticks with proven endpoints — `https://cloudflare-dns.com/dns-query`, `https://dns.google/dns-query`, `https://dns.quad9.net/dns-query`.
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

Installed by `install.sh` only (not by the 7621 installer).

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
8. Stops the service, backs the old binary up to **`/tmp`** (RAM — not `/opt`), replaces it, verifies version and startup (`pidof`, retried 5×).

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

**A device with a hardcoded external DNS behaves differently / can't reach a specific external DNS server**
DNS transit interception (section 6.1) redirects classic port-53 queries into the router's DNS proxy. That is intended behavior; if a specific device truly needs direct access to its DNS server, revert interception for the whole router using the commands in section 6.1.

---

## 13. MT7621 / mipsel specifics

`install_7621.sh` exists because MT7621 routers ship a TLS stack that can't talk to modern servers ("`curl: (60)` and friends"). It works around that with `--insecure` and an HTTP mirror, which **trades certificate checking for compatibility** — MITM is theoretically possible; the sources are pinned/fixed which keeps the practical risk low, but understand the trade.

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
- Committing to `main` in this repo changes what the next `curl | sh` executes — there is no staging or CI. Treat updates accordingly.

More boundaries and the reasoning behind them: [docs/09-limitations.md](09-limitations.md) (RU).
