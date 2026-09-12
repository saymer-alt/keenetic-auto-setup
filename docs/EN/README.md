# Keenetic Auto Setup

A set of POSIX scripts that turns a Keenetic router running Entware into a self-maintaining gateway: Mihomo (Clash Meta) as the proxy core, MagiTrickle for DNS-based split routing, automatic VoIP bypass, and a watchdog that restarts Mihomo by itself when it breaks.

The Russian [README.md](../../README.md) is the primary entry point and the primary documentation language. The English deep-dive guide is [docs/HOWTO.md](../HOWTO.md); most documents below are marked (RU).

## What it is

After installation the router runs:

| Component | Role |
| --- | --- |
| **Mihomo** (Clash Meta) | the proxy core: rule-based routing of outbound traffic (VLESS/Reality, subscriptions, groups). Controlled by `/opt/etc/mihomo/config.yaml` |
| **Keenetic proxy interface** (`ProxyN`) | the Keenetic → Mihomo bridge: a SOCKS5 connection to `127.0.0.1:7890` |
| **MagiTrickle** | DNS-based split routing: decides per domain which traffic goes where |
| **bypass_wa** | a policy + firewall hook: VoIP traffic (Telegram/WhatsApp/WebRTC, UDP 1400/3478/3482) goes through the project proxy interface, bypassing DNS classification |
| **Watchdog** | cron every 5 minutes: checks WAN, port 7890 and the end-to-end tunnel; restarts Mihomo only when Mihomo is actually the broken part |
| **S00ubifs** (`ram` mode) | moves `/opt/tmp`, `/opt/var/log`, `/opt/var/run` into tmpfs, sparing the flash storage |

Requirements: a Keenetic router with Entware already installed, internet access, SSH. At least 256 MB of RAM — 128 MB devices are not supported, tmpfs destabilizes them ([docs/09-limitations.md](../09-limitations.md), RU). Architectures: aarch64, armv7, mipsel, mips.

## Installation

SSH into the router. Install to internal memory (default):

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/install.sh | sh
```

Install to a USB/SSD drive — add the `disk` argument:

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/install.sh | sh -s -- disk
```

- `ram` mode (default) enables the tmpfs flash protection; `disk` disables it (for installs onto a drive);
- the installer does not install Entware — Entware is expected to be already set up ([docs/HOWTO.md](../HOWTO.md), section 2);
- re-running the installer is idempotent: installed components are skipped, user settings are never overwritten ([docs/HOWTO.md](../HOWTO.md), section 3.3).

## What the installer does

1. opkg update, then the base packages (`curl`, `jq`, `nano`, `ca-bundle`, `cron`).
2. Creates the `bypass_wa` policy if it does not exist yet.
3. Enables DNS transit interception (`dns-proxy intercept enable`) so that classic client DNS queries reach MagiTrickle. This is not a DoH/DoT countermeasure.
4. In `ram` mode only — installs the S00ubifs tmpfs script.
5. Installs Mihomo from the [saymer-alt/entware-go](https://github.com/saymer-alt/entware-go/releases) package repository.
6. **Bootstrap `config.yaml`**: if no working config exists, a minimal one with `mixed-port: 7890` is created. An existing user config is never modified.
7. **Project proxy interface selection**: the installer finds or creates the project Keenetic proxy interface on its own. If an existing `Proxy0` belongs to a different configuration, it is left untouched and the first free `ProxyN` is used instead.

   > A long-lived router is an archaeological site: `Proxy0` may belong to a past experiment, another pile of scripts, or to someone who also once decided to "just quickly test something". The installer does not guess ownership: if the description and the port do not match the project profile, `Proxy0` is declared foreign and stepped around.

8. **`bypass_wa` binding**: the policy is routed through the selected project proxy interface automatically.
9. Installs MagiTrickle and the VoIP hook `020-bypass_wa.sh`.
10. Installs the watchdog into cron (every 5 minutes).
11. Restarts Mihomo and runs the self-check: `[OK] Done` — finished; `[WARN]` — installed, but see Diagnostics; `[FAIL]` — the installation is incomplete, read the check output.

## Mihomo configuration

Without a working config the proxy does nothing: the bootstrap only brings the contract port up. Replace `/opt/etc/mihomo/config.yaml` with your own:

```bash
nano /opt/etc/mihomo/config.yaml
```

A minimal working example:

```yaml
mixed-port: 7890
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
    proxies: ["server"]

rules:
  - GEOIP,private,DIRECT
  - MATCH,Proxy
```

The config can be assembled in the browser: [saymer-alt/link-generators](https://github.com/saymer-alt/link-generators) — a client-side web application with no server.

**Mihomo listens on the fixed local port `127.0.0.1:7890`.** This is the project contract: it is what Mihomo binds, what the proxy interface points to, and what the watchdog probes. It cannot be changed.

> There is no `--port` flag, and that is not an oversight. `7890` is the one number every component of this project agrees on; a configuration option would simply add a fourth place to get it wrong.

Validate and apply:

```bash
mihomo -t -f /opt/etc/mihomo/config.yaml   # validation without starting
/opt/etc/init.d/S99mihomo restart
/opt/etc/init.d/S99mihomo status
```

The web dashboard (MetaCubeX) is not installed by default; how to enable it: [docs/encyclopedia/12-pervyj-vhod-v-ui.md](../encyclopedia/12-pervyj-vhod-v-ui.md) (RU).

## bypass_wa

Telegram/WhatsApp calls and WebRTC (UDP ports 1400, 3478, 3482) are taken out of MagiTrickle's DNS classification: the firewall hook marks this traffic and the `bypass_wa` policy sends it through the project proxy interface into Mihomo — from there it follows Mihomo's rules.

- the binding is done automatically at install time;
- if you have manually bound `bypass_wa` to your own VPN interface, the installer adds the project proxy to the policy but never removes or reorders your binding;
- mechanism and common problems: [docs/05-bypass-wa.md](../05-bypass-wa.md) (RU).

> Historical note: `bypass_wa` used to be created empty, with instructions to point it at a VPN interface by hand. The installer now does this itself; a manual binding is still allowed and will not be destroyed.

## Verification

```bash
/opt/etc/init.d/S99mihomo status                # the service is running
curl -sS -o /dev/null -w '%{http_code}\n' --proxy 127.0.0.1:7890 http://google.com/generate_204
cat /opt/var/log/mihomo_watchdog.log            # after ~5 minutes: "[OK] All good"
```

The expected response code is `204`: the request has actually passed through the local proxy.

The watchdog checks, in order: WAN reachability directly (Cloudflare/Google; if those all fail — a fallback list of gosuslugi/ya.ru/mail.ru/vk that distinguishes a restricted network from no internet at all), the local port 7890, and an end-to-end request through SOCKS5. If the WAN is down, Mihomo is not restarted: no network ≠ broken Mihomo. A restart happens only with the network confirmed up and the problem confirmed to be in Mihomo, with 300 seconds between restarts. Details: [docs/04-watchdog.md](../04-watchdog.md) (RU).

## Updates

Updating Mihomo to the latest release (ARM; on MIPS it refuses by design — official Mihomo binaries for MIPS do not exist):

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/update-mihomo.sh | sh
```

The script downloads the binary into `/tmp`, verifies it and its compatibility with your `config.yaml`, replaces the binary and restarts the service; any failure triggers an automatic rollback. `--force` reinstalls the same version. A manual procedure for special cases: [mihomo_manual_update_arm.md](../../mihomo_manual_update_arm.md).

The watchdog is updated separately (`update-watchdog.sh`). Note: it updates the copy in `/opt/bin/mihomo_watchdog.sh`, while the installer places it in `/opt/etc/cron.5mins/mihomo_watchdog`. Check which path is actually being executed before updating: `grep mihomo_watchdog /opt/etc/crontab`.

> A classic: you update the copy in `/opt/bin` while cron is happily executing the one in `cron.5mins`. Check the crontab before updating, not after.

## Diagnostics

| What to look at | Command |
| --- | --- |
| Mihomo status | `/opt/etc/init.d/S99mihomo status` |
| Watchdog decisions | `cat /opt/var/log/mihomo_watchdog.log` |
| Config validity | `mihomo -t -f /opt/etc/mihomo/config.yaml` |
| Is 7890 listening | `netstat -tln \| grep 7890` |
| Free space and RAM | `df -h /opt`, `free` |
| Time (a wrong clock breaks SSL) | `date` |
| WAN interfaces for `interface-name` | `sh mihomo-interface-check.sh` |

Typical self-check warnings:

- `Port 7890 not listening` — Mihomo did not start, or the config has no `mixed-port: 7890`;
- `Low free space on /opt` — less than 32 MB free;
- `bypass_wa policy has no interface permit` — the policy has no exit;
- `Mihomo config syntax check failed` — the config does not pass `mihomo -t`.

The full symptom → cause → fix walkthrough: [docs/08-troubleshooting.md](../08-troubleshooting.md) (RU) and [docs/HOWTO.md](../HOWTO.md), sections 11–12.

## Documentation

| Document | What's inside |
| --- | --- |
| [ARCHITECTURE.md](../../ARCHITECTURE.md) (RU) | how the routing actually works: three traffic paths, Keenetic/MagiTrickle/Mihomo roles, scheme boundaries |
| [docs/HOWTO.md](../HOWTO.md) (EN) / [docs/HOWTO_RU.md](../HOWTO_RU.md) (RU) | the complete guide: preparation, install, configuration, MagiTrickle, updates, rollback, diagnostics |
| [docs/encyclopedia/00-karta-sistemy.md](../encyclopedia/00-karta-sistemy.md) (RU) | a Mihomo encyclopedia for beginners: system map, dashboard, DNS/fake-ip, rules, TUN |
| [docs/03-install.md](../03-install.md) (RU) | what install.sh actually does |
| [docs/04-watchdog.md](../04-watchdog.md) (RU) | watchdog internals |
| [docs/05-bypass-wa.md](../05-bypass-wa.md) (RU) | the VoIP bypass in depth |
| [docs/06-s00ubifs.md](../06-s00ubifs.md) (RU) | tmpfs profiles and RAM limits |
| [docs/07-install.md](../07-install.md) (RU) | the installers and their differences |
| [docs/08-troubleshooting.md](../08-troubleshooting.md) (RU) | symptom → cause → fix |
| [docs/09-limitations.md](../09-limitations.md) (RU) | hard limits of the project |
| [docs/10-roadmap.md](../10-roadmap.md) (RU) | roadmap |
| [CHANGELOG.md](../../CHANGELOG.md) | release history |

## Limitations

- **RAM**: 256 MB minimum; 128 MB devices are not supported.
- **Tunnel MTU**: "everything is slow / some sites don't open" is almost always MTU, not routing; working values are 1200–1300 ([docs/09-limitations.md](../09-limitations.md), RU).
- **IPv6** is disabled on purpose: MagiTrickle and the project configs are built around an IPv4 scheme ([ARCHITECTURE.md](../../ARCHITECTURE.md), RU).
- Client **DoH/DoT** bypasses the interception: only classic port-53 DNS is classified.
- **Logs live in RAM** (`ram` mode) and die on reboot — a deliberate trade paid for flash longevity.
- **Not all traffic goes through the proxy**: some traffic always goes direct — that is the foundation of the scheme, not a bug ([ARCHITECTURE.md](../../ARCHITECTURE.md), RU).

## Legacy

`install_7621.sh` is a separate installer for older MT7621/mipsel devices: no MagiTrickle, no VoIP bypass. Installs less, trusts the server more. Use it only if the universal `install.sh` does not pass on your device; the differences are described in [docs/07-install.md](../07-install.md) (RU).

## License

[MIT](../../LICENSE)
