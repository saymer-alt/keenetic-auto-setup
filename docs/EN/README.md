# 🛡️ Keenetic Auto-Setup Suite

Automated installation of Mihomo and supporting components on Keenetic + Entware.

[Русский](../../README.md)

---

## 0. Prerequisites

- Keenetic with Entware / OPKG
- Shell access
- Internet access
- KeeneticOS: **Proxy client** (`proxy`), **Cloud-based content filtering and ad blocking** (`dns-filter`), **Kernel modules for Netfilter** (`opkg-kmod-netfilter`), and at least one secure-DNS component — `dns-tls` **or** `dns-https`
- If `/opt` is on external USB/NVMe storage: **EXT4 only**; KeeneticOS components `ext` and `ext-utils` are required
- For the normal internal-`/opt` profile the project uses **S00ubifs**: `/opt/tmp`, `/opt/var/log`, and `/opt/var/run` are moved to `tmpfs` (RAM), reducing continuous writes to internal flash while configs and packages stay persistent

If Entware is not installed yet and `/opt` will be placed on USB/SSD → [prepare external EXT4 storage and install Entware](ENTWARE_EXTERNAL_STORAGE.md).

Full requirements → [KeeneticOS components and prerequisites](../COMPONENTS.md) · [RAM / storage / limitations](../09-limitations.md) · [S00ubifs flash-write reduction and RAM mode](../06-s00ubifs.md)

## 1. Installation

### 🚀 Simple path — recommended for most users

You do not need to choose `ram` or `disk` manually. `setup.sh` detects where `/opt` lives, selects the normal profile, and delegates to the canonical `install.sh`. EXT4, KeeneticOS component, RAM/swap, and other safety gates remain enforced by the canonical installer.

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/setup.sh | sh
```

If `curl` stalls **before setup/Doctor prints anything** during the TLS handshake to `raw.githubusercontent.com`, use the compatibility retry below (certificate verification remains enabled):

```bash
curl -4 -fSsL --connect-timeout 5 --max-time 20 --curves X25519 https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/setup.sh | sh
```

Normal TLS remains the primary path. `X25519` is only a compatibility fallback for paths where the larger OpenSSL 3.5 ClientHello is dropped; once the project downloader is running it tries normal TLS → X25519 → wget/API fallback.

If `/opt` cannot be classified safely, the wrapper stops instead of guessing and points to the advanced installation path.

> **512 MB-class note:** bare 512 MB physical RAM is no longer a supported project baseline. A new install requires active KeeneticOS zRAM **or** verified external storage-backed swap; with neither present the installer stops with ERROR and Doctor reports FAIL. There is no access-point exception.

Advanced/manual installation, explicit `ram|disk` selection, offline/SCP delivery, and storage overrides are documented separately.

Details → [installation](../03-install.md)

## 2. Mihomo configuration

After installation, `setup.sh` automatically continues into **Mihomo Config Import** and shows the [Mihomo Unified Generator](https://saymer-alt.github.io/link-generators/).

1. Build the configuration in the generator.
2. Copy the **entire YAML**, starting with `mixed-port: 7890`.
3. Return to SSH and paste the YAML in one piece.
4. Press **Ctrl+D once** to finish input and start validation/install.

The importer runs real `mihomo -t` validation, preserves the one-Mihomo invariant, saves the previous config as `config.yaml.bak`, commits atomically, and rolls back automatically if Mihomo fails to start or port 7890 does not become ready.

If you do not want to import a config yet, type `s` at the importer prompt and run it later.

After importing a full generated `config.yaml`, the two main web interfaces are:

```text
MetaCubeXD:   http://192.168.1.1:9090/ui/
MagiTrickle:  http://192.168.1.1:8080/
```

If Config Import is skipped with `s`, the minimal bootstrap config keeps only the required `mixed-port: 7890`; `external-controller`/MetaCubeXD is not configured yet, so port 9090 is **not expected** to listen. MagiTrickle on 8080 remains available independently.

> **MagiTrickle itself is installed automatically, but your user `.mtrickle` configuration is not.** `setup.sh`/`install.sh` add the repository, install the MagiTrickle package, start the service, and configure the required system integration. Exported groups, rules, interfaces, and other user settings from a `.mtrickle` file are intentionally not imported by the installer. After a clean install, open MagiTrickle at `http://<router-IP>:8080/` and import your saved configuration manually if you need to restore it.

Practical example: [real MagiTrickle field sample — 8 groups / 287 rules](MAGITRICKLE_FIELD_LISTS.md). It is a dated user export, not an official or universal service-domain list.

For the first MetaCubeXD open after importing the full config, use the base `/ui/` path rather than `#/overview` or another hash route. If your router uses a different LAN IP, replace `192.168.1.1` in both links.

Details → [safe config import](CONFIG_IMPORT.md) · [Mihomo overview](../encyclopedia/10-mihomo-eto.md) · [generator source](https://github.com/saymer-alt/link-generators)

## 3. Check and start

Quick manual edit of the current config:

```bash
nano /opt/etc/mihomo/config.yaml
```

After a manual edit, restart Mihomo and check its status.

Doctor:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-doctor.sh | sh
```

The CLI uses one traffic-light palette: green for normal progress/`OK`, cyan for `INFO`, yellow for `WARN`, and red for `ERROR`/`FAIL`. Color is supplemental: prefixes remain present, and ANSI is disabled for redirects, `NO_COLOR`, or `TERM=dumb`. See [terminal output colors](OUTPUT_COLORS.md).

Focused read-only check for one domain/IP through ProxyN → Mihomo:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-route-check.sh -o /tmp/mihomo-route-check.sh && \
sh /tmp/mihomo-route-check.sh example.com
```

The helper shows DNS, project ProxyN evidence, port 7890, the current Mihomo selection and a SOCKS5h probe. It does not change routing and does not claim that a successful SOCKS probe proves a specific LAN client's Keenetic/MagiTrickle policy.

Restart after a manual edit:

```bash
/opt/etc/init.d/S99mihomo restart
```

Status:

```bash
/opt/etc/init.d/S99mihomo status
```

Details → [diagnostics and troubleshooting](../08-troubleshooting.md)

## 4. Updates

Updating Mihomo does not overwrite the user `/opt/etc/mihomo/config.yaml`. Safe Config Import keeps `config.yaml.bak` and automatically rolls back if validation or startup fails.

Mihomo:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/update-mihomo.sh | sh
```

Watchdog:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/update-watchdog.sh | sh
```

MagiTrickle:

```bash
opkg update && opkg install magitrickle
/opt/etc/init.d/S99magitrickle restart
```

Details → [updates, rollback and maintenance](UPDATES.md)

## 5. Additional commands

### Advanced / risk zone

Normal operation does not require manual edits to `iptables`, ProxyN, policy routing, DNS, or storage overrides. Treat these as advanced/risk-zone operations: a mistake can affect the whole LAN or lock you out of the router. Start with Doctor and read-only helpers and make manual changes only with a concrete dependency and rollback path.

Legacy config without TUN / `mitun0`:

```bash
# read-only preview first
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/migrate-mihomo-tun.sh | sh -s -- --check
# then apply
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/migrate-mihomo-tun.sh | sh
```

The migrator adds the project-standard TUN with `device: mitun0` and `auto-route: false`. Mihomo >= 1.19.31 gets `stack: mips`; older/unconfirmed versions use compatibility `gvisor`. An existing `tun:` block is never rewritten.

MIPS TUN migration:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/migrate-mihomo-mips.sh | sh
```

Details → [MIPS TUN migration](UPDATES.md#mips-tun-migration)

Linux interface check:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-interface-check.sh | sh
```

Details → [interface-name and routing](../../ARCHITECTURE.md)

Current proxy / failover-failback:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-proxy-selection-watch.sh | sh
```

Details → [Proxy Selection Watch](../11-proxy-selection-watch.md)

## 6. Project scripts

| Script | Purpose / documentation |
| --- | --- |
| [`setup.sh`](../../setup.sh) | [Recommended project installation](SETUP.md) |
| [`install.sh`](../../install.sh) | [Canonical installer with explicit profile selection](../03-install.md) |
| [`config-import.sh`](../../config-import.sh) | [Import and safely replace `config.yaml`](CONFIG_IMPORT.md) |
| [`migrate-mihomo-tun.sh`](../../migrate-mihomo-tun.sh) | [Add TUN/`mitun0` to a legacy config with no `tun:` block](UPDATES.md#legacy-config-add-tun--mitun0) |
| [`migrate-mihomo-mips.sh`](../../migrate-mihomo-mips.sh) | [Migrate the TUN config from gVisor to MIPS](UPDATES.md#mips-tun-migration) |
| [`mihomo-doctor.sh`](../../mihomo-doctor.sh) | [Doctor: full project diagnostics](../08-troubleshooting.md) |
| [`mihomo-interface-check.sh`](../../mihomo-interface-check.sh) | [Show Linux WAN/VPN interface names for `interface-name`](../../ARCHITECTURE.md) |
| [`mihomo-proxy-selection-watch.sh`](../../mihomo-proxy-selection-watch.sh) | [Show which Mihomo server is selected now](../11-proxy-selection-watch.md) |
| [`mihomo-route-check.sh`](../../mihomo-route-check.sh) | [Check whether a specific site is reachable through Mihomo](ROUTE_CHECK.md) |
| [`update-mihomo.sh`](../../update-mihomo.sh) | [Update the Mihomo core with validation and rollback](UPDATES.md#mihomo-update) |
| [`update-watchdog.sh`](../../update-watchdog.sh) | [Update the watchdog mechanism](UPDATES.md#watchdog-update) |
| [`mihomo-watchdog.sh`](../../mihomo-watchdog.sh) | [Check Mihomo and restart it only on a confirmed failure](../04-watchdog.md) |
| [`020-bypass-wa.sh`](../../020-bypass-wa.sh) | [Intercept VoIP traffic and send it to the separate `bypass_wa` policy](../05-bypass-wa.md) |
| [`S00ubifs`](../../S00ubifs) | [Move Entware runtime directories to RAM and reduce flash writes](../06-s00ubifs.md) |

## 7. Reference

- [Full HOWTO](../HOWTO.md)
- [Encyclopedia / system map](../encyclopedia/00-karta-sistemy.md)
- [Roadmap](../10-roadmap.md)
- [CHANGELOG](../../CHANGELOG.md)
- [License](../../LICENSE)
