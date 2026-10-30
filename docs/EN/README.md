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

**2. Edit the Mihomo configuration**

```bash
nano /opt/etc/mihomo/config.yaml
```

**3. Back up, empty the config and open nano**

⚠️ The file is emptied **before nano opens**. The original is copied to `config.yaml.bak` (overwrites an existing `.bak`).

```bash
cp /opt/etc/mihomo/config.yaml /opt/etc/mihomo/config.yaml.bak && : > /opt/etc/mihomo/config.yaml && nano /opt/etc/mihomo/config.yaml
```

**4. Empty config without a backup and open nano**

⚠️ **Danger:** this discards the existing `config.yaml`. Do not restart Mihomo until a working YAML has been saved.

```bash
: > /opt/etc/mihomo/config.yaml && nano /opt/etc/mihomo/config.yaml
```

**5. Safely import YAML instead (recommended)**

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/config-import.sh | sh
```

**6. Inspect the setup — Doctor**

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-doctor.sh | sh
```

**7. Restart Mihomo**

```bash
/opt/etc/init.d/S99mihomo restart
```

**8. Check Mihomo status**

```bash
/opt/etc/init.d/S99mihomo status
```

**9. Update Mihomo**

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/update-mihomo.sh | sh
```

**10. Remove only Mihomo and MagiTrickle packages (no /opt formatting)**

~~~sh
curl -fSsL -o /tmp/kas-remove-packages.sh https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/uninstall-packages.sh && sh /tmp/kas-remove-packages.sh
~~~

**Minimal native-service removal, NOT full KeeneticOS rollback.** Disables the KAS cron watchdog, disables native autostart and calls the two Entware init.d stop scripts before `opkg remove`. Checks that both daemons stopped. YAML is preserved by default using copies under `/opt/var/kas-yaml.*` and missing files restored. Use `--purge-config` to explicitly remove YAML after packages, or `--cleanup` to additionally remove recorded KAS MagiTrickle feed and Netfilter hook files. KeeneticOS ProxyN, policy, DNS interception and live Netfilter rules are NOT modified; review routing separately (`sh uninstall.sh --plan`). Verified by full Router Emulator QEMU E2E and on the KN-1010 test router, including repeat removal and reboot. No IPK rollback cache or drive formatting.

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

## KAS Control Center — web management panel (Beta)

**KAS Control Center** is a separate **optional** web component for an already installed KAS. The script-based KAS installer above remains the primary way to install the core; the panel does not replace or reinstall it. It manages the Mihomo YAML through the canonical KAS importer, Doctor diagnostics, subscription exclude filters, and its own updates. KAS stays fully functional without it.

> ⚠️ **Beta.** No automatic rollback. Panel availability is defined by your routing and firewall: the panel listens on the home bridge only and is never published to the WAN, but if you forward ports or expose it through an unauthenticated proxy, you accept that risk. A password over plain HTTP is not encrypted — use the panel on a trusted home LAN only.

**Requirements:** Keenetic/Netcraze router with Entware installed, a working KAS (Mihomo), and a home bridge `br0` with a single private IPv4 address.

**Architectures:** `aarch64-3.10`, `armv7-3.2`, `mipsel-3.4`, `mips-3.4` — must match your Entware architecture (`opkg print-architecture`).

**Download and install** (aarch64 example):

```sh
curl -fSsL -o /tmp/kas-control-center.ipk \
  https://github.com/saymer-alt/keenetic-auto-setup/releases/download/v0.1.0-beta.2/kas-control-center_0.1.0.beta.2-1_aarch64-3.10.ipk
opkg install /tmp/kas-control-center.ipk
sh /opt/etc/init.d/S98kas-control-center start
```

The panel starts **only after an explicit start**. It binds only the private IPv4 of `br0` on TCP port **18081** (example: `http://192.168.1.1:18081`) and refuses to start if `br0` is absent or ambiguous.

**Views:** Overview (component versions, Mihomo/MagiTrickle/panel updates), Subscriptions (server list and exclude filters), Configuration (YAML upload/paste via the canonical importer), Diagnostics (RU/EN Doctor summary), Settings (port, login mode, panel password, optional home-subnet-only access).

**Update channels:** in the "KAS panel update" card choose **Beta (experimental)** or **Stable**, then run the manual version check and confirm. Changing the channel never installs anything; there is no background auto-update. The Stable channel is published separately; until then the panel reports honestly that it is not available.

**Uninstall:** `opkg remove kas-control-center` (KAS settings and YAML are preserved; the core is untouched).

**Limitations and recovery:** no automatic rollback. If an update does not complete, do not power off; check the error code in the panel and run `/opt/bin/kas-control-center -recover-panel-update` over SSH if needed, or reinstall a verified IPK. See [web/control-center/LAN.md](../web/control-center/LAN.md) for advanced access options and [web/control-center/PANEL_UPDATE.md](../web/control-center/PANEL_UPDATE.md) for the update system details.

## 7. Reference

- [Full HOWTO](../HOWTO.md)
- [Encyclopedia / system map](../encyclopedia/00-karta-sistemy.md)
- [Roadmap](../10-roadmap.md)
- [CHANGELOG](../../CHANGELOG.md)
- [License](../../LICENSE)
