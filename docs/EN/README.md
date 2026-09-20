# 🛡️ Keenetic Auto-Setup Suite

Automated installation of Mihomo and supporting components on Keenetic + Entware.

[Русский](../../README.md)

---

## 0. Prerequisites

- Keenetic with Entware / OPKG
- Shell access
- Internet access

Full requirements → [components and prerequisites](../COMPONENTS.md) · [RAM / storage / limitations](../09-limitations.md)

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

Details → [installation](../03-install.md) · [full HOWTO](../HOWTO.md)

## 2. Mihomo configuration

Generator → [Mihomo Unified Generator](https://github.com/saymer-alt/link-generators)

```bash
nano /opt/etc/mihomo/config.yaml
```

Details → [Mihomo](../encyclopedia/10-mihomo-eto.md) · [architecture and routing](../01-architecture.md)

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

Diagnostics → [Troubleshooting](../08-troubleshooting.md)

## 4. Updates

Mihomo:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/update-mihomo.sh | sh
```

Details → [Mihomo update](../HOWTO.md)

Watchdog:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/update-watchdog.sh | sh
```

Details → [Watchdog](../04-watchdog.md)

## 5. Additional commands

MIPS TUN migration:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/migrate-mihomo-mips.sh | sh
```

Details → [MIPS / update HOWTO](../HOWTO.md)

Linux interface check:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo-interface-check.sh | sh
```

Details → [interface-name](../../ARCHITECTURE.md)

Current proxy / failover-failback:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo-proxy-selection-watch.sh | sh
```

Details → [Proxy Selection Watch](../11-proxy-selection-watch.md)

## 6. Project scripts

| Script | Documentation |
| --- | --- |
| [`install.sh`](../../install.sh) | [Installation](../03-install.md) |
| [`migrate-mihomo-mips.sh`](../../migrate-mihomo-mips.sh) | [HOWTO](../HOWTO.md) |
| [`mihomo-doctor.sh`](../../mihomo-doctor.sh) | [Diagnostics](../08-troubleshooting.md) |
| [`mihomo-interface-check.sh`](../../mihomo-interface-check.sh) | [Architecture](../../ARCHITECTURE.md) |
| [`mihomo-proxy-selection-watch.sh`](../../mihomo-proxy-selection-watch.sh) | [Proxy Selection Watch](../11-proxy-selection-watch.md) |
| [`update-mihomo.sh`](../../update-mihomo.sh) | [HOWTO](../HOWTO.md) |
| [`update-watchdog.sh`](../../update-watchdog.sh) | [Watchdog](../04-watchdog.md) |
| [`mihomo-watchdog.sh`](../../mihomo-watchdog.sh) | [Watchdog](../04-watchdog.md) |
| [`020-bypass-wa.sh`](../../020-bypass-wa.sh) | [bypass_wa](../05-bypass-wa.md) |
| [`S00ubifs`](../../S00ubifs) | [S00ubifs](../06-s00ubifs.md) |
| [`tests/contracts.sh`](../../tests/contracts.sh) | [Testing strategy](../TESTING_STRATEGY.md) |

## 7. Documentation

- [Quick start](../02-quick-start.md)
- [Installation](../03-install.md)
- [HOWTO](../HOWTO.md)
- [Architecture](../01-architecture.md)
- [Diagnostics](../08-troubleshooting.md)
- [Limitations](../09-limitations.md)
- [Roadmap](../10-roadmap.md)
- [CHANGELOG](../../CHANGELOG.md)
- [License](../../LICENSE)
