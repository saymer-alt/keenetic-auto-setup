# 🛡️ Keenetic Auto-Setup Suite

Automated installation of Mihomo and supporting components on Keenetic + Entware.

[Русский](../../README.md)

---

## 0. Prerequisites

- Keenetic with Entware / OPKG
- Shell access
- Internet access
- KeeneticOS: **Proxy client** (`proxy`) and at least one secure-DNS component — `dns-tls` **or** `dns-https`
- If `/opt` is on external USB/NVMe storage: **EXT4 only**; KeeneticOS components `ext` and `ext-utils` are required
- For the normal internal-`/opt` profile the project uses **S00ubifs**: `/opt/tmp`, `/opt/var/log`, and `/opt/var/run` are moved to `tmpfs` (RAM), reducing continuous writes to internal flash while configs and packages stay persistent

Full requirements → [KeeneticOS components and prerequisites](../COMPONENTS.md) · [RAM / storage / limitations](../09-limitations.md) · [S00ubifs flash-write reduction and RAM mode](../06-s00ubifs.md)

## 1. Installation

### 🚀 Simple path — recommended for most users

You do not need to choose `ram` or `disk` manually. `setup.sh` detects where `/opt` lives, selects the normal profile, and delegates to the canonical `install.sh`. EXT4, KeeneticOS component, RAM/swap, and other safety gates remain enforced by the canonical installer.

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/setup.sh | sh
```

If `/opt` cannot be classified safely, the wrapper stops instead of guessing and points to the advanced installation path.

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
| [`setup.sh`](../../setup.sh) | [Quick installation and initial setup](SETUP.md) |
| [`install.sh`](../../install.sh) | [Advanced installation with explicit profile selection](../03-install.md) |
| [`config-import.sh`](../../config-import.sh) | [Safe Mihomo configuration replacement](CONFIG_IMPORT.md) |
| [`migrate-mihomo-mips.sh`](../../migrate-mihomo-mips.sh) | [Move TUN to the MIPS stack](UPDATES.md#mips-tun-migration) |
| [`mihomo-doctor.sh`](../../mihomo-doctor.sh) | [Full system health check](../08-troubleshooting.md) |
| [`mihomo-interface-check.sh`](../../mihomo-interface-check.sh) | [Check interfaces for `interface-name`](../../ARCHITECTURE.md) |
| [`mihomo-proxy-selection-watch.sh`](../../mihomo-proxy-selection-watch.sh) | [Inspect the current proxy selection](../11-proxy-selection-watch.md) |
| [`mihomo-route-check.sh`](../../mihomo-route-check.sh) | [Check the path to a specific domain/IP](ROUTE_CHECK.md) |
| [`update-mihomo.sh`](../../update-mihomo.sh) | [Safe Mihomo update with rollback](UPDATES.md#mihomo-update) |
| [`update-watchdog.sh`](../../update-watchdog.sh) | [Safe watchdog update](UPDATES.md#watchdog-update) |
| [`mihomo-watchdog.sh`](../../mihomo-watchdog.sh) | [Automatic Mihomo health monitoring and recovery](../04-watchdog.md) |
| [`020-bypass-wa.sh`](../../020-bypass-wa.sh) | [Bypass Mihomo for VoIP/calls](../05-bypass-wa.md) |
| [`S00ubifs`](../../S00ubifs) | [Reduce writes to internal flash](../06-s00ubifs.md) |

## 7. Reference

- [Full HOWTO](../HOWTO.md)
- [Encyclopedia / system map](../encyclopedia/00-karta-sistemy.md)
- [Roadmap](../10-roadmap.md)
- [CHANGELOG](../../CHANGELOG.md)
- [License](../../LICENSE)
