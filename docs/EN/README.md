# 🛡️ Keenetic Auto-Setup Suite

Automated installation and operation of network and supporting tools on Keenetic, with protection of internal storage from unnecessary wear.

[Русский README](../../README.md)

---

## 0. Prerequisites

- Keenetic with Entware / OPKG installed
- 256 MB+ RAM is the supported/recommended profile; 128 MB-class devices are allowed as best-effort/experimental with no stability guarantee (the installer warns; prefer `disk` to `ram`)
- The KeeneticOS **Proxy client / Клиент прокси** component — required: without it the Proxy* interfaces do not exist and the installer cannot create the project ProxyN
- **Cloud-based content filtering and ad blocking / Фильтрация контента и блокировка рекламы при помощи облачных сервисов** — required for the supported DNS profile because the project needs `dns-proxy intercept enable`; this does not require selecting a cloud filtering provider for clients
- Router DoT and/or DoH are strongly recommended for upstream DNS: port-53 interception solves a different problem and does not itself protect Keenetic's upstream resolver traffic from ISP interference
- Entware shell access (SSH is the usual method, but the KeeneticOS SSH server component is not a project runtime dependency)
- Internet access

## 1. Installation

### Router internal storage — recommended

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/install.sh | sh
```

### External storage — recommended USB HDD / NVMe

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/install.sh | sh -s -- disk
```

Wait for the installation to finish.

Details → [Installation](../03-install.md).

## 2. Mihomo configuration

Generate a configuration with:

[**Mihomo Unified Generator**](https://github.com/saymer-alt/link-generators)

Open the configuration file:

```bash
nano /opt/etc/mihomo/config.yaml
```

Clear the file (`Ctrl+K`) and paste the generated configuration.

Save: `Ctrl+O` → `Enter`  
Exit: `Ctrl+X`

If the generated configuration includes TUN, Mihomo creates the `mitun0` interface; it is recommended to use it in MagiTrickle as the interface for redirection. The bootstrap config itself contains only `mixed-port: 7890`.

Details → [Mihomo](../encyclopedia/10-mihomo-eto.md) · [MagiTrickle and routing](../01-architecture.md) · [first UI access](../encyclopedia/12-pervyj-vhod-v-ui.md).

## 3. Check and start

If Mihomo is already running, **do not run `mihomo -t` in parallel**: on some Keenetic devices a second Mihomo process causes SIGSEGV. For a safe read-only check of the installed stack, use the Doctor:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo-doctor.sh | sh
```

After changing the configuration, restart the service:

```bash
/opt/etc/init.d/S99mihomo restart
```

Check status:

```bash
/opt/etc/init.d/S99mihomo status
```

Mihomo proxy:

`127.0.0.1:7890`

Full installation check — the read-only Doctor (changes nothing and restarts nothing; the whole output can be pasted for support):

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo-doctor.sh | sh
```

Details → [Troubleshooting](../08-troubleshooting.md).

## 4. Mihomo UI

After installing a configuration with Web UI:

```text
http://192.168.1.1:9090/ui/
```

Replace `192.168.1.1` with your router's IP address.

Details → [first UI access](../encyclopedia/12-pervyj-vhod-v-ui.md).

## 5. Updates

### Mihomo

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/update-mihomo.sh | sh
```

Force update:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/update-mihomo.sh | sh -s -- --force
```

Details → [update and rollback](../HOWTO_RU.md).

### Watchdog

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/update-watchdog.sh | sh
```

Details and logs → [Watchdog](../04-watchdog.md).

## 6. Documentation

### Quick start and installation

- [Introduction](../00-intro.md)
- [Quick start](../02-quick-start.md)
- [Installation](../03-install.md)
- [Guide](../HOWTO_RU.md)

### System

- [System map](../encyclopedia/00-karta-sistemy.md)
- [Architecture](../01-architecture.md)
- [Glossary](../encyclopedia/01-slovar.md)
- [Limitations](../09-limitations.md)
- [Roadmap](../10-roadmap.md)

### Mihomo

- [What is Mihomo](../encyclopedia/10-mihomo-eto.md)
- [MetaCubeX](../encyclopedia/11-metacubex-eto.md)
- [127.0.0.1 and the router IP](../encyclopedia/13-127-0-0-1-i-ip-routera.md)
- [DNS and Fake-IP](../encyclopedia/26-dns-i-fake-ip.md)
- [Ports and config.yaml](../encyclopedia/27-porty-i-config-yaml.md)
- [Proxies](../encyclopedia/28-proxies.md)
- [Proxy groups](../encyclopedia/29-proxy-groups.md)
- [Rules](../encyclopedia/30-rules.md)
- [TUN](../encyclopedia/31-tun.md)

### Service mechanisms

- [Watchdog](../04-watchdog.md)
- [bypass_wa](../05-bypass-wa.md)
- [S00ubifs](../06-s00ubifs.md)
- [Troubleshooting](../08-troubleshooting.md)

### Additional

- [Installation details](../07-install.md)
- [CHANGELOG](../../CHANGELOG.md)
- [License](../../LICENSE)
