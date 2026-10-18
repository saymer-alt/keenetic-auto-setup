# 🛡️ Keenetic Auto-Setup Suite

**Mihomo + MagiTrickle for Keenetic with Entware:** setup, safe config import, watchdog and diagnostics. This project does not provide VPN servers; bring your own server or subscription.

[Русский](../../README.md)

## 🚀 Installation

You need **Entware/OPKG, SSH and Internet access**. Install the KeeneticOS components `proxy`, `dns-filter`, `opkg-kmod-netfilter` and either `dns-tls` **or** `dns-https`. [Component guide](../COMPONENTS.md) · [External EXT4/Entware preparation](ENTWARE_EXTERNAL_STORAGE.md).

Copy the complete command:

```sh
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/setup.sh | sh
```

`setup.sh` detects internal/external storage, enforces prerequisites and then starts the config importer. **You do not have to select `ram` or `disk` manually.**

If the download stalls **before any installer output**, use the TLS compatibility retry:

```sh
curl -4 -fSsL --connect-timeout 5 --max-time 20 --curves X25519 https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/setup.sh | sh
```

Other problems → [detailed installation](../03-install.md) · [troubleshooting](../08-troubleshooting.md).

## 📋 After installation: configure Mihomo

1. Generate your YAML at [Mihomo Config Builder](https://saymer-alt.github.io/link-generators/) — it must specify `mixed-port: 7890`.
2. Paste the **complete YAML** into **Mihomo Config Import** and press **Ctrl+D once**.
3. If you have no config yet, type **`s` and Enter** to skip without changing the existing configuration.

The importer validates YAML and backs up the previous config for rollback. [Safe import and file import](CONFIG_IMPORT.md).

After importing a full YAML config, open MetaCubeXD at `http://<router-IP>:9090/ui/`. MagiTrickle is at `http://<router-IP>:8080/`. **If you entered `s`, MetaCubeXD is not configured yet**; your personal `.mtrickle` export must also be imported separately.

## 🛠 Common commands

**Check the installation — read-only Doctor:**

```sh
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-doctor.sh | sh
```

**Import or replace YAML later:**

```sh
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/config-import.sh | sh
```

**Update Mihomo** (with validation and rollback):

```sh
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/update-mihomo.sh | sh
```

Other useful commands:

| Task | Command or guide |
| --- | --- |
| Edit the current config | `nano /opt/etc/mihomo/config.yaml` |
| Mihomo status | `/opt/etc/init.d/S99mihomo status` |
| Restart after manual edit | `/opt/etc/init.d/S99mihomo restart` |
| Update watchdog | [`update-watchdog.sh`](UPDATES.md) |
| Test a particular site | [Route Check](ROUTE_CHECK.md) |
| See the selected proxy | [`mihomo-proxy-selection-watch.sh`](../11-proxy-selection-watch.md) |

**Do not erase `config.yaml` without a backup.** Prefer the safe Config Import for full replacement. Details → [HOWTO](../HOWTO.md).

## ⚠️ Important prerequisites

- **Native zRAM and external storage-backed SWAP must never be active together**, at any RAM size. Installer = ERROR, Doctor = FAIL, Updater = ERROR; no override is supported.
- With **512 MB RAM**, either active native zRAM **or** verified external swap is required — never both. External `/opt` requires **EXT4** and KeeneticOS `ext`/`ext-utils` components.
- The installer does not supply a VPN server or import your personal `.mtrickle` export. Back up the router settings before making changes on a production device.

[Requirements and limitations](../09-limitations.md) · [Safety constitution](../CONSTITUTION.md) · [Internal flash protection / S00ubifs](../06-s00ubifs.md).

## 📚 Detailed documentation

[Installation](../03-install.md) · [Updates and rollback](UPDATES.md) · [Troubleshooting](../08-troubleshooting.md) · [Architecture](../../ARCHITECTURE.md) · [Full HOWTO](../HOWTO.md) · [Quick start](../02-quick-start.md) · [CHANGELOG](../../CHANGELOG.md) · [License](../../LICENSE)
