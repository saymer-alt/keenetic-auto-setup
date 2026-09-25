# KeeneticOS / Entware prerequisites

[Русская версия](COMPONENTS_RU.md)

This document is the install-time capability contract for `keenetic-auto-setup`.
It deliberately separates **required KeeneticOS components**, **required capabilities**,
and **optional user choices**. Do not turn every feature seen on a working router into a
project prerequisite.

## Required before install

| Item | Class | Why the project needs it | How failure is detected |
|---|---|---|---|
| Entware / OPKG mounted at `/opt` | required platform prerequisite | packages, init scripts, cron, Mihomo and MagiTrickle live under `/opt`; when `/opt` is external, the project-supported profile is EXT4 only | `install.sh` checks `opkg`, the `/opt` storage class and its actual filesystem from `/proc/mounts`; a new install on external non-EXT4 is rejected |
| KeeneticOS **Proxy client / Клиент прокси** (`proxy`) | required KeeneticOS component | provides the `ProxyN` interface used as the Keenetic → Mihomo bridge | early read-only `show version` component preflight; Proxy creation read-back remains a safety net |
| KeeneticOS **Cloud-based content filtering and ad blocking / Фильтрация контента и блокировка рекламы при помощи облачных сервисов** (`dns-filter`) | required KeeneticOS component for the current supported DNS-interception profile | supplies the DNS-filter/interception component family used by the mandatory `dns-proxy intercept enable` profile | early read-only `show version` component preflight; the later `dns-proxy intercept enable` + read-back remains the capability safety net |
| KeeneticOS **Kernel modules for Netfilter / Модули ядра подсистемы Netfilter** (`opkg-kmod-netfilter`) | required KeeneticOS component for the current default VoIP bypass path | provides `xt_multiport`; without it `020-bypass-wa.sh` cannot install its UDP multiport MARK/CONNMARK/RETURN rules; a KN-1010/5.1.6 A/B/C reboot test reproduced this dependency | early read-only `show version` component preflight; Doctor also verifies the live `_CUST_BYPASS_WA_` rules |
| KeeneticOS **DNS-over-TLS proxy** (`dns-tls`) **OR DNS-over-HTTPS proxy** (`dns-https`) | **at least one is required** | Keenetic's Proxy Client guide warns that proxy Internet access may work incorrectly without DoT/DoH and recommends enabling DoT or DoH for reliable access | installer enforces the OR contract from `show version`; Doctor mirrors absence of both as FAIL |
| KeeneticOS **Ext filesystem** (`ext`) | **required when `/opt` is external** | the project's supported external Entware profile is EXT4 only | external `/opt` adds a read-only `show version` requirement for component id `ext` |
| KeeneticOS **EXT4 filesystem utilities** (`ext-utils`) | **required when `/opt` is external** | provides the platform check/repair tooling for EXT4; KeeneticOS 5.1 exposes storage checks when the corresponding filesystem utilities are installed | external `/opt` adds a read-only `show version` requirement for component id `ext-utils` |
| Internet access during installation | required install-time capability | downloads packages/scripts and the current Mihomo ipk | download/opkg failures are reported by the installer |
| Shell access to Entware | required operator capability, **not a required KeeneticOS component** | installation/update commands are run in a shell | use any administration path that provides the required Entware shell; the KeeneticOS SSH server component itself is not a runtime dependency |

## Audit against the KeeneticOS component list

This table is intentionally about **KeeneticOS components**, not features that happen to
be installed on one reference router.

| KeeneticOS component | Project status | Evidence / reason |
|---|---|---|
| **Proxy client / Клиент прокси** | **REQUIRED** | Creates ProxyN, the Keenetic → Mihomo SOCKS5 bridge to 127.0.0.1:7890. A real clean install without this component silently rejected Proxy creation; install.sh now fails early on read-back. |
| **Open Package support / Поддержка открытых пакетов (OPKG)** | **REQUIRED** | The entire runtime stack under /opt (Mihomo, MagiTrickle, cron and tools) is Entware-based. |
| **Kernel modules for Netfilter / Модули ядра подсистемы Netfilter** (`opkg-kmod-netfilter`) | **REQUIRED for the project VoIP bypass path** | Provides `xt_multiport`; without it, after reboot `_CUST_BYPASS_WA_` may still exist but remain empty and cannot mark the target UDP ports. |
| **Kernel modules for Traffic Control support / Модули ядра Traffic Control** | **NOT REQUIRED by current project code** | No tc/qdisc/class/filter operations are used by the repository. Do not require this component merely because it is installed on a reference router. |
| **Extension package Xtables-addons for Netfilter / Пакет расширения Xtables-addons** | **NOT REQUIRED by the current bypass path** | KN-1010/5.1.6 C testing restored `xt_multiport` and all `_CUST_BYPASS_WA_` rules with only `opkg-kmod-netfilter` installed while Xtables-addons remained disabled. |
| **Kernel modules for filesystems support / Модули ядра для поддержки файловых систем** | **CONDITIONAL** | Platform support depends on the chosen storage; this does not replace the project's separate EXT4-only external `/opt` contract. |
| **Storage support / Поддержка накопителей** | **CONDITIONAL** | Required for USB/external-storage Entware layouts; internal-storage Entware on supported models does not make USB storage a universal project prerequisite. |
| **Ext filesystem** (`ext`) + **EXT4 filesystem utilities** (`ext-utils`) | **REQUIRED for external Entware `/opt`** | The project deliberately supports external `/opt` only on EXT4; `ext-utils` supplies the platform filesystem check/repair tooling. |
| **SSH server / Сервер SSH** | **OPTIONAL administration method** | Convenient for the documented interactive shell workflow, but the project runtime does not depend on the KeeneticOS SSH server. It is not a project component prerequisite. |
| **Cloud-based content filtering and ad blocking / Фильтрация контента и блокировка рекламы при помощи облачных сервисов** (`dns-filter`) | **REQUIRED for the supported DNS-interception profile** | Keenetic exposes the DNS-filter/interception machinery through this component family. The project requires `dns-proxy intercept enable`; if that command/capability is absent, install.sh cannot satisfy the MagiTrickle DNS contract and must fail rather than silently continue. Installing this component does **not** mean that a third-party filtering service must be selected for clients. |
| **DNS-over-TLS proxy** (`dns-tls`) | **ONE OF `dns-tls` / `dns-https` IS REQUIRED** | Keenetic recommends DoT/DoH for reliable Internet access through Proxy Client; the second secure-DNS component is not required. |
| **DNS-over-HTTPS proxy** (`dns-https`) | **ONE OF `dns-tls` / `dns-https` IS REQUIRED** | Same Proxy Client contract; the project intentionally enforces OR rather than requiring both components. |
| **Internet connection status monitoring (Ping Check)** | **RECOMMENDED operational component** | Not called by project code (the watchdog has its own checks), but useful for Keenetic's own WAN health/failover diagnostics. Recommended on managed routers, not a hard install dependency. |
| **Traffic classification engine** | **RECOMMENDED operational component** | Current project code does not call it, but it is useful visibility on a managed routing appliance. Recommended baseline, not a hard dependency. |
| **Packet capture** | **RECOMMENDED diagnostic component** | Not required at runtime, but valuable when DNS/routing/VPN behavior must be proven from packets instead of guessed. |
| **iPerf3** | **RECOMMENDED diagnostic component** | Not used by install/runtime scripts, but useful for repeatable throughput/path diagnostics. |
| **Dynamic DNS (DDNS) client / KeenDNS-related service** | **RECOMMENDED for managed/remote-access deployments** | Not required for packet routing itself, but useful for the documented protected remote-access patterns and router administration. |
| **mDNS service** | **NOT A PROJECT REQUIREMENT** | It may be mandatory for the router's own component set, but current project code does not depend on mDNS. |
| **Wi-Fi controller, mobile/cloud agents, shaper, DHCP, Wi-Fi/USB interfaces** | **PLATFORM / ROUTER FEATURES, NOT PROJECT PREREQUISITES** | They may be mandatory or useful to KeeneticOS itself, but the project does not require them as install-time dependencies. |
| **PPTP/L2TP/SSTP/OpenVPN/WireGuard/IPsec/OpenConnect/ZeroTier clients or servers** | **OPTIONAL / topology-specific** | A user may select a VPN interface as an exit, but no particular VPN technology is universally required. Servers are likewise outside the base project dependency set. |
| **PPPoE/802.1X clients, EoIP/GRE/IP-IP, VRRP, ALGs, NetFlow, UPnP, udpxy, SNMP, captive portal** | **NOT REQUIRED** | No current install/runtime path depends on these components. |
| **USB modem/serial/CDC/NDIS/QMI modules** | **CONDITIONAL on WAN hardware only** | Relevant only when that modem type is the router's WAN; not a project dependency. |
| **SMB/DLNA/Transmission/FTP/SFTP/WebDAV/folder ACL components** | **NOT REQUIRED** | Storage applications are unrelated to the project runtime. |

### External-storage contract

For `/opt` on USB/NVMe, this project supports **EXT4 only**. Modern KeeneticOS can technically mount/use other filesystems, and some OPKG versions permit additional layouts, but those are deliberately outside the supported `keenetic-auto-setup` profile. New installs reject NTFS, exFAT, FAT and other external `/opt` filesystems.

This follows Keenetic's current OPKG guidance, which requires an Ext filesystem for USB storage and recommends journaled EXT4: <https://support.keenetic.com/hero-dsl/kn-2410/en/18481-opkg.html>.

External `/opt` also requires component ids `ext` and `ext-utils`. Since KeeneticOS 5.1, the Storage & Devices tools can run a filesystem check when the corresponding filesystem utilities are installed: <https://support.keenetic.com/hero-4g-plus/kn-2311/en/44933-managing-usb-drives-in-the-web-interface.html>. The project does **not** claim that Keenetic automatically runs fsck on every boot; what is confirmed is the supported check/repair mechanism. The installer and Doctor never format, convert or repair the filesystem themselves.

Two distinctions matter:

1. **Installed on a known-good router does not mean required by the project.**
2. **Mandatory for KeeneticOS does not mean required by this repository.** If KeeneticOS
   forces a base component to stay installed, the project does not need to duplicate that
   requirement unless its own code actually depends on it.

Official basis for the secure-DNS prerequisite: Keenetic's Proxy Client guide warns that Internet resources through a proxy may not work correctly without DoT/DoH and recommends enabling DNS-over-TLS or DNS-over-HTTPS for reliable proxy access: <https://support.keenetic.com/peak/kn-2710/en/49443-proxy-client.html>.

## Required KeeneticOS capabilities

These are capabilities used by the project, but the repository has no evidence that they
must be installed as additional named components on supported current KeeneticOS builds.
Do not invent a component name.

- **DNS proxy + transit interception** — `dns-proxy intercept enable`. The project
  requires classic port-53 transit DNS to be intercepted by Keenetic so MagiTrickle can
  observe it. The desired GUI state is **transit requests blocked** (the corresponding
  checkbox is off). DoH/DoT traffic is a different mechanism.
- **IP policy routing** — used for the `bypass_wa` policy and its permitted exits.
- **Keenetic/Entware netfilter hook** — `/opt/etc/ndm/netfilter.d/020-bypass_wa.sh`
  installs the VoIP marking rules when Keenetic rebuilds the firewall.
- **Persistent configuration save** — project-owned Keenetic changes are committed with
  `system configuration save`.

If one of these commands/capabilities is unavailable on a particular firmware/component
set, treat that as a real compatibility failure and record the exact hardware/KeeneticOS
evidence before adding a new prerequisite.

## Installed by this project through Entware

`install.sh` ensures `ca-bundle`, `curl`, `jq`, `nano`, and `cron`; installs
Mihomo from the sibling `saymer-alt/entware-go` release with the configured Entware feed
as last resort; and adds/installs MagiTrickle from its package repository.

These are not KeeneticOS components.

## Conditional / optional

- **Secure-DNS component vs resolver choice** — the supported ProxyN profile **requires at least one** of `dns-tls` / `dns-https`. Which one is used, which upstream resolver it points to, and whether the second component is installed remain operational choices. Classic DNS interception is a separate project contract, and resolver reachability still wins over theory, especially on whitelist networks.
- **WireGuard / AmneziaWG / SSTP / OpenConnect / other VPN clients** — optional exits
  selected by the operator or MagiTrickle; none is a universal project prerequisite.
- **Mihomo external Controller / Web UI** — optional. Mihomo routing and ProxyN do not
  require the Controller.
- **Controller secret** — optional inside the documented trusted LAN/VPN model; direct
  exposure to WAN/untrusted networks is outside that trust boundary.
- **TUN / `mitun0`** — created only by a user Mihomo config that enables TUN. The
  bootstrap config does not require it.
- **Concrete encrypted-DNS upstream/resolver** — operational choice. This does not remove the install prerequisite above: the supported ProxyN profile still requires at least one of `dns-tls` / `dns-https`.

## Component-audit rule

When a real clean installation fails because a KeeneticOS capability is absent:

1. preserve the exact failure evidence;
2. identify the smallest missing capability/component;
3. make the installer fail early or report the dependency clearly;
4. add a small permanent regression/contract check;
5. update this document and the user-facing prerequisites.

The September 2026 external clean-install failure that exposed the missing **Proxy client**
component, followed by the current explicit component contract (`proxy`, `dns-filter`,
`opkg-kmod-netfilter`, secure-DNS OR `dns-tls`/`dns-https`, plus `ext` + `ext-utils`
for external `/opt`), is the reference example for this process.
