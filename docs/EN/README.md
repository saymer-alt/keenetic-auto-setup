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

### Advanced installation

Router internal storage:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/install.sh | sh
```

External USB/NVMe with Entware on EXT4:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/install.sh | sh -s -- disk
```

For external installation, `/opt` must actually use EXT4 and KeeneticOS must provide **Ext filesystem** (`ext`) and **EXT4 filesystem utilities** (`ext-utils`). NTFS/exFAT and other filesystems are outside the supported external-storage profile.

Details → [installation](../03-install.md)

## 2. Mihomo configuration

Open the generator → [Mihomo Unified Generator](https://saymer-alt.github.io/link-generators/)

```bash
nano /opt/etc/mihomo/config.yaml
```

Details → [Mihomo overview](../encyclopedia/10-mihomo-eto.md) · [generator source](https://github.com/saymer-alt/link-generators)

## 3. Check and start

Doctor:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-doctor.sh | sh
```

Restart:

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
| [`setup.sh`](../../setup.sh) | Simple auto-profile wrapper → `install.sh` |
| [`install.sh`](../../install.sh) | [Installation](../03-install.md) |
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
