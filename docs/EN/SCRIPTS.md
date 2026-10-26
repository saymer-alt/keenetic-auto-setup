# Keenetic Auto-Setup scripts

Full list of scripts and detailed guides. The [README](README.md) stays concise for installation and everyday usage.

**Normal installation:** `bootstrap.sh` → `setup.sh` → `install.sh` → `config-import.sh` (optional interactive import after installation).

## Script inventory

| Script | Purpose / documentation |
| --- | --- |
| [`uninstall-packages.sh`](../../uninstall-packages.sh) | [Stop Mihomo/MagiTrickle via native Entware init.d, then remove their packages through OPKG; YAML preserved, KeeneticOS routing/DNS/Netfilter retained](../23-uninstall.md) |
| [`uninstall.sh`](../../uninstall.sh) | [Read-only `--check`/`--plan` preflight; `--remove`/`--purge` are blocked](../23-uninstall.md) |
| [`bootstrap.sh`](../../bootstrap.sh) | [Initial KAS launcher: fetches and validates `setup.sh` with GitHub fallbacks before starting the wizard](SETUP.md#why-bootstrapsh-exists) |
| [`setup.sh`](../../setup.sh) | [Setup wizard: detects `ram`/`disk`, delegates to `install.sh`, offers configuration import](SETUP.md) |
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


For the launcher chain, see [setup wizard](SETUP.md) and the [advanced installation guide](../03-install.md).
