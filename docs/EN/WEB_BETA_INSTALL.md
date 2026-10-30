> **Status:** documentation for the planned `v0.1.0-beta.2` release; the Release download URLs work only after publication. Before publication, use only exact source-pinned CI artifacts for owner-approved pilot testing.

# KAS Control Center — web panel installation and operation (beta.2)

**KAS Control Center** is a separate **optional** web component for an already installed KAS. The [script-based KAS installer](../../README.md) remains the primary way to install the core; the panel does not replace or reinstall it. It manages the Mihomo YAML through the canonical KAS importer, Doctor diagnostics, subscription exclude filters, and its own updates. KAS stays fully functional without it.

> ⚠️ **Beta.** No automatic rollback. Panel availability is defined by your routing and firewall: the panel listens on the management bridge IPv4 address only and is never published to the WAN, but if you forward ports or expose it through an unauthenticated proxy, you accept that risk. A password over plain HTTP is not encrypted — use the panel on a trusted management network only.

**Requirements:** Keenetic/Netcraze router with Entware installed, a working KAS (Mihomo), and a management bridge `br0` (not necessarily a home network) with a single private IPv4 address.

**Architectures:** `aarch64-3.10`, `armv7-3.2`, `mipsel-3.4`, `mips-3.4` (**KN-1010 uses MIPSel, not ARM64**) — must match your Entware architecture (`opkg print-architecture`).

**Download and install** (aarch64 example):

```sh
cd /tmp
curl -fSsLO https://github.com/saymer-alt/keenetic-auto-setup/releases/download/v0.1.0-beta.2/kas-control-center_0.1.0.beta.2-1_aarch64-3.10.ipk
curl -fSsLO https://github.com/saymer-alt/keenetic-auto-setup/releases/download/v0.1.0-beta.2/SHA256SUMS
grep '  kas-control-center_0.1.0.beta.2-1_aarch64-3.10.ipk
```

The checksum must report OK before installation; do not use force flags. If GitHub downloads fail on the router, transfer the exact verified assets via SCP/SFTP from your PC. An existing saved port (e.g. 18081) survives upgrades.

The panel starts **only after an explicit start**. It binds only the private IPv4 of `br0` on TCP port **8081** (example: `http://192.168.1.1:8081`) and refuses to start if `br0` is absent or ambiguous.

**Views:** Overview (component versions, Mihomo/MagiTrickle/panel updates), Subscriptions (server list and exclude filters), Configuration (YAML upload/paste via the canonical importer), Diagnostics (RU/EN Doctor summary), Settings (port, login mode, panel password, optional home-subnet-only access).

**Update channels:** in the "KAS panel update" card choose **Beta (experimental)** or **Stable**, then run the manual version check and confirm. Changing the channel never installs anything; there is no background auto-update. The Stable channel is published separately; until then the panel reports honestly that it is not available.

**Uninstall:** `opkg remove kas-control-center` (KAS settings and YAML are preserved; the core is untouched).

**Limitations and recovery:** no automatic rollback. If an update does not complete, do not power off; check the error code in the panel and run `/opt/bin/kas-control-center -recover-panel-update` over SSH if needed, or reinstall a verified IPK. See [web/control-center/LAN.md](../../web/control-center/LAN.md) for advanced access options and [web/control-center/PANEL_UPDATE.md](../../web/control-center/PANEL_UPDATE.md) for the update system details.

 SHA256SUMS | sha256sum -c -
opkg install ./kas-control-center_0.1.0.beta.2-1_aarch64-3.10.ipk
sh /opt/etc/init.d/S98kas-control-center start
sh /opt/etc/init.d/S98kas-control-center status
```

The panel starts **only after an explicit start**. It binds only the private IPv4 of `br0` on TCP port **8081** (example: `http://192.168.1.1:8081`) and refuses to start if `br0` is absent or ambiguous.

**Views:** Overview (component versions, Mihomo/MagiTrickle/panel updates), Subscriptions (server list and exclude filters), Configuration (YAML upload/paste via the canonical importer), Diagnostics (RU/EN Doctor summary), Settings (port, login mode, panel password, optional home-subnet-only access).

**Update channels:** in the "KAS panel update" card choose **Beta (experimental)** or **Stable**, then run the manual version check and confirm. Changing the channel never installs anything; there is no background auto-update. The Stable channel is published separately; until then the panel reports honestly that it is not available.

**Uninstall:** `opkg remove kas-control-center` (KAS settings and YAML are preserved; the core is untouched).

**Limitations and recovery:** no automatic rollback. If an update does not complete, do not power off; check the error code in the panel and run `/opt/bin/kas-control-center -recover-panel-update` over SSH if needed, or reinstall a verified IPK. See [web/control-center/LAN.md](../../web/control-center/LAN.md) for advanced access options and [web/control-center/PANEL_UPDATE.md](../../web/control-center/PANEL_UPDATE.md) for the update system details.

