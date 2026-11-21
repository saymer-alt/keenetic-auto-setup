# 🛡️ Keenetic Auto-Setup Suite — Mihomo + MagiTrickle

Automated installation and integration of **[Mihomo](https://github.com/MetaCubeX/mihomo) + [MagiTrickle](https://magitrickle.dev/)** on Keenetic with Entware. **Mihomo** provides proxy connections and routes to your servers; **MagiTrickle** manages DNS/domain-based traffic groups and routing decisions. Both are essential parts of this setup.

[Русский](../../README.md)

**Quick links:** [Common commands](#common-commands) · [Install](#1-installation) · [Configure](#2-mihomo-configuration) · [Check](#3-check-and-start) · [Update](#4-updates) · [More commands](#5-additional-commands)

---

## Common commands

Frequently used SSH commands in one place. **Copy one block at a time.** More details are in the sections below.

**1. Install KAS (Mihomo + MagiTrickle)**

```bash
opkg update && opkg install curl && curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/bootstrap.sh | sh
```

GitHub unreachable? Mirror alternative:

```bash
curl -fSsL https://gitlab.com/saymer-alt/keenetic-auto-setup/-/raw/stable/bootstrap.sh | sh
```

**2. Open the Mihomo config**

```bash
nano -I /opt/etc/mihomo/config.yaml
```

`-I` skips the faulty `nanorc` (`Error expanding /usr/share/nano/*.nanorc`); plain: `nano /opt/etc/mihomo/config.yaml`. To replace the whole YAML prefer the safe import (command №5); do not clear the working file.

**3. Back up and open nano (no clearing)**

⚠️ An existing `config.yaml.bak` is overwritten; the working YAML is not emptied.

```bash
cp -p /opt/etc/mihomo/config.yaml /opt/etc/mihomo/config.yaml.bak && nano -I /opt/etc/mihomo/config.yaml
```

**4. Check the Mihomo init script name**

Fresh Entware installs `S28mihomo`, older builds `S99mihomo`. If both exist, stop and run Doctor.

```sh
ls -l /opt/etc/init.d/S28mihomo /opt/etc/init.d/S99mihomo 2>/dev/null
```

**5. Safely import YAML instead (recommended)**

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/bootstrap.sh | sh -s -- --script config-import.sh
```

Stages `config-import.sh` privately with three fallback sources and verifies it before running (issue #255).

**6. Inspect the setup — Doctor**

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-doctor.sh | sh
```

**7. Restart Mihomo**

New Entware packages (`S28mihomo`):
```sh
/opt/etc/init.d/S28mihomo restart
```

Older packages (`S99mihomo`):
```sh
/opt/etc/init.d/S99mihomo restart
```

**8. Check Mihomo status**

New packages (`S28mihomo`):
```sh
/opt/etc/init.d/S28mihomo status
```

Older packages (`S99mihomo`):
```sh
/opt/etc/init.d/S99mihomo status
```

**Run only the matching command** (see #4). If both init scripts exist, run Doctor first.

**9. Update Mihomo**

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/update-mihomo.sh | sh
```

---

## 0. Prerequisites

- Keenetic with Entware, SSH access and Internet.
- KeeneticOS components: `proxy`, `dns-filter`, `opkg-kmod-netfilter`, plus `dns-tls` **or** `dns-https`.
- External `/opt`: **EXT4 only**, with `ext` and `ext-utils` installed.

[Install Entware on USB/SSD](ENTWARE_EXTERNAL_STORAGE.md) · [All component/RAM requirements](../COMPONENTS.md) · [Fix `opkg update` failures](../22-entware-feed-fallback.md)

## 1. Installation

**Copy and run the full command in Keenetic SSH:**

```bash
opkg update && opkg install curl && curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/bootstrap.sh | sh
```

`bootstrap.sh` starts the `setup.sh` wizard, which detects `ram`/`disk`, delegates installation to `install.sh`, and offers safe config import. [How the stages work](SETUP.md).

> **Important:** KeeneticOS zRAM and external SWAP must not be active together: **Installer — ERROR, Doctor — FAIL, Updater — ERROR**. The 512 MB RAM class requires active zRAM **or** external swap. [Resource limits](../09-limitations.md) · [Safety contract](../CONSTITUTION.md).

[Advanced installation, fallback downloads, offline/SCP](../03-install.md)

## 2. Mihomo configuration

After installation, **Mihomo Config Import** opens:

1. Build a full YAML in the [Mihomo Unified Generator](https://saymer-alt.github.io/link-generators/).
2. Paste the full config into SSH and press **Ctrl+D once**.
3. To skip, type **`s` and Enter**. Import later with command 5 in [Common commands](#common-commands).

The importer validates YAML with Mihomo, makes a backup and rolls back failed changes. **Saved MagiTrickle `.mtrickle` settings require a separate manual import** through its web UI.

After importing a full config (replace the IP with your router address):

```text
MetaCubeXD:  http://192.168.1.1:9090/ui/
MagiTrickle: http://192.168.1.1:8080/
```

If import is skipped, MetaCubeXD on port 9090 is not configured yet. [Config import guide](CONFIG_IMPORT.md) · [MagiTrickle docs](https://magitrickle.dev/) · [Generator](https://github.com/saymer-alt/link-generators)

## 3. Check and start

Editing, Doctor, restarting and status commands are listed above under [Common commands](#common-commands).

For a specific destination via ProxyN → Mihomo: [mihomo-route-check.sh](ROUTE_CHECK.md).

[Troubleshooting](../08-troubleshooting.md) · [CLI colors and status](OUTPUT_COLORS.md)

## 4. Updates

- **Mihomo:** command 9 in [Common commands](#common-commands). Your `config.yaml` is preserved.
- **Watchdog:** [update-watchdog.sh](UPDATES.md).
- **MagiTrickle:** `opkg update && opkg install magitrickle`.

[Updates and rollback](UPDATES.md)

## 5. Additional commands

Advanced or higher-risk actions are documented separately rather than duplicated in the quick-start page:

- [TUN and MIPS migration](UPDATES.md)
- [Interface names and routing](../../ARCHITECTURE.md)
- [Selected proxy / failover-failback](../11-proxy-selection-watch.md) — `mihomo-proxy-selection-watch.sh`
- [Manual ProxyN, DNS and policy-routing operations](../HOWTO.md)

## 6. Project scripts

`bootstrap.sh` → `setup.sh` → `install.sh` → `config-import.sh` — normal installation sequence.

**[Full script inventory and documentation](SCRIPTS.md)**

## 7. Uninstall

Stop Mihomo and MagiTrickle via their native Entware init scripts, disable the KAS watchdog, and remove both packages **without formatting /opt**:

```sh
curl -fSsL -o /tmp/kas-remove-packages.sh https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/uninstall-packages.sh && sh /tmp/kas-remove-packages.sh
```

Verified in QEMU and on a KN-1010 test router (removal, repeat, reboot). User YAML configurations are preserved by default. **This is partial removal:** KeeneticOS ProxyN, DNS interception, routing policies and active Netfilter rules remain. Traffic routed through removed Mihomo may stop working. Optional `--cleanup` and `--purge-config` are not required for standard removal.

## 8. Reference

- [Full HOWTO](../HOWTO.md)
- [Encyclopedia / system map](../encyclopedia/00-karta-sistemy.md)
- [Roadmap](../10-roadmap.md)
- [CHANGELOG](../../CHANGELOG.md)
- [License](../../LICENSE)
