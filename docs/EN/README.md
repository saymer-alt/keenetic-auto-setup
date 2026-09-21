# 🛡️ Keenetic Auto-Setup Suite

Automated installation of Mihomo and supporting components on Keenetic + Entware.

[Русский](../../README.md)

---

## 0. Prerequisites

- Keenetic with Entware / OPKG
- Shell access
- Internet access

Full requirements → [KeeneticOS components and prerequisites](../COMPONENTS.md) · [RAM / storage / limitations](../09-limitations.md)

## 1. Installation

### Router internal storage — proven option

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/install.sh | sh
```

### External storage — USB HDD / NVMe

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/install.sh | sh -s -- disk
```

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
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo-doctor.sh | sh
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
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/update-mihomo.sh | sh
```

Watchdog:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/update-watchdog.sh | sh
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
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/migrate-mihomo-mips.sh | sh
```

Details → [MIPS TUN migration](UPDATES.md#mips-tun-migration)

Linux interface check:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo-interface-check.sh | sh
```

Details → [interface-name and routing](../../ARCHITECTURE.md)

Current proxy / failover-failback:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo-proxy-selection-watch.sh | sh
```

Details → [Proxy Selection Watch](../11-proxy-selection-watch.md)

## 6. Project scripts

| Script | Documentation |
| --- | --- |
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
