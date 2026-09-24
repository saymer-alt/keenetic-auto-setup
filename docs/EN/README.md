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

Full requirements → [KeeneticOS components and prerequisites](../COMPONENTS.md) · [RAM / storage / limitations](../09-limitations.md)

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

After Mihomo starts successfully, open MetaCubeXD in a browser at:

```text
http://192.168.1.1:9090/ui/
```

For the first open, use the base `/ui/` path rather than `#/overview` or another hash route. If your router uses a different LAN IP, replace `192.168.1.1` with that address.

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

| Script | Documentation |
| --- | --- |
| [`setup.sh`](../../setup.sh) | Recommended wizard: auto-profile → install → safe Config Import |
| [`install.sh`](../../install.sh) | [Installation](../03-install.md) |
| [`config-import.sh`](../../config-import.sh) | [Safe config import](CONFIG_IMPORT.md) |
| [`migrate-mihomo-mips.sh`](../../migrate-mihomo-mips.sh) | [MIPS TUN migration](UPDATES.md#mips-tun-migration) |
| [`mihomo-doctor.sh`](../../mihomo-doctor.sh) | [Diagnostics](../08-troubleshooting.md) |
| [`mihomo-interface-check.sh`](../../mihomo-interface-check.sh) | [Architecture](../../ARCHITECTURE.md) |
| [`mihomo-proxy-selection-watch.sh`](../../mihomo-proxy-selection-watch.sh) | [Proxy Selection Watch](../11-proxy-selection-watch.md) |
| [`update-mihomo.sh`](../../update-mihomo.sh) | [Mihomo update](UPDATES.md#mihomo-update) |
| [`update-watchdog.sh`](../../update-watchdog.sh) | [Watchdog update](UPDATES.md#watchdog-update) |
| [`mihomo-watchdog.sh`](../../mihomo-watchdog.sh) | [Watchdog](../04-watchdog.md) |
| [`020-bypass-wa.sh`](../../020-bypass-wa.sh) | [bypass_wa](../05-bypass-wa.md) |
| [`S00ubifs`](../../S00ubifs) | [S00ubifs](../06-s00ubifs.md) |

## 7. Reference

- [Full HOWTO](../HOWTO.md)
- [Encyclopedia / system map](../encyclopedia/00-karta-sistemy.md)
- [Roadmap](../10-roadmap.md)
- [CHANGELOG](../../CHANGELOG.md)
- [License](../../LICENSE)
