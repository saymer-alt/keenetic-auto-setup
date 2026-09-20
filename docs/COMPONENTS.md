# KeeneticOS / Entware prerequisites

This document is the install-time capability contract for `keenetic-auto-setup`.
It deliberately separates **required KeeneticOS components**, **required capabilities**,
and **optional user choices**. Do not turn every feature seen on a working router into a
project prerequisite.

## Required before install

| Item | Class | Why the project needs it | How failure is detected |
|---|---|---|---|
| Entware / OPKG mounted at `/opt` | required platform prerequisite | packages, init scripts, cron, Mihomo and MagiTrickle live under `/opt` | `install.sh` fails immediately when `opkg` is absent |
| KeeneticOS **Proxy client / Клиент прокси** | required KeeneticOS component | provides the `ProxyN` interface used as the Keenetic → Mihomo bridge | after creation, `install.sh` reads running-config back and aborts if the interface did not appear |
| Internet access during installation | required install-time capability | downloads packages/scripts and the current Mihomo ipk | download/opkg failures are reported by the installer |
| Shell access to Entware | required operator capability, **not a required KeeneticOS component** | installation/update commands are run in a shell | use any administration path that provides the required Entware shell; the KeeneticOS SSH Server component itself is not a runtime dependency |

## Audit against the KeeneticOS component list

This table is intentionally about **KeeneticOS components**, not features that happen to
be installed on one reference router.

| KeeneticOS component | Project status | Evidence / reason |
|---|---|---|
| **Proxy client / Клиент прокси** | **REQUIRED** | Creates ProxyN, the Keenetic → Mihomo SOCKS5 bridge to 127.0.0.1:7890. A real clean install without this component silently rejected Proxy creation; install.sh now fails early on read-back. |
| **Open package support / Поддержка открытых пакетов (OPKG)** | **REQUIRED** | The entire runtime stack under /opt (Mihomo, MagiTrickle, cron and tools) is Entware-based. |
| **Netfilter kernel modules / Модули ядра подсистемы Netfilter** | **REQUIRED for the project VoIP bypass path** | 020-bypass-wa.sh uses iptables mangle plus mark, MARK, CONNMARK and multiport and is installed as a netfilter.d hook. Without working Netfilter/iptables support that project feature cannot be implemented. |
| **Traffic Control kernel modules / Модули ядра Traffic Control** | **NOT REQUIRED by current project code** | No tc/qdisc/class/filter operations are used by the repository. Do not require this component merely because it is installed on a reference router. |
| **Xtables-addons for Netfilter / Пакет расширения Xtables-addons** | **NOT PROVEN / currently NOT REQUIRED** | The project uses ordinary iptables mangle/MARK/CONNMARK/multiport operations and contains no Xtables-addons-specific target or match. Do not require it without a reproduced dependency. |
| **Filesystem kernel modules / Модули ядра для поддержки файловых систем** | **CONDITIONAL** | Needed only insofar as the chosen Entware storage/filesystem requires them; not a universal routing/Mihomo dependency. |
| **Storage support / Поддержка накопителей** | **CONDITIONAL** | Required for USB/external-storage Entware layouts; internal-storage Entware on supported models does not make USB storage a universal project prerequisite. |
| **ext filesystem + ext utilities** | **CONDITIONAL** | Required when the selected Entware drive uses ext; not a Mihomo/MagiTrickle requirement by itself. |
| **SSH Server / Сервер SSH** | **OPTIONAL administration method** | Convenient for the documented interactive shell workflow, but the project runtime does not depend on the KeeneticOS SSH server. It is not a project component prerequisite. |
| **Content filtering / cloud ad blocking** | **NOT REQUIRED** | The project uses Keenetic DNS proxy transit interception; it does not require a cloud content-filter provider. |
| **DNS-over-TLS proxy** | **OPTIONAL** | Upstream encrypted DNS choice; unrelated to the required classic port-53 transit interception contract. |
| **DNS-over-HTTPS proxy** | **OPTIONAL** | Same: useful router DNS choice, not required by install.sh/MagiTrickle integration. |
| **Ping Check** | **OPTIONAL** | The project watchdog performs its own bounded WAN/proxy checks; it does not call the Keenetic Ping Check service. |
| **Traffic classification service** | **NOT REQUIRED by current project code** | No dependency on the Keenetic traffic-classification service is present in the repository. |
| **Packet capture** | **OPTIONAL diagnostic tool** | Useful for manual troubleshooting, but no project script requires it. |
| **iPerf3** | **OPTIONAL diagnostic tool** | Not used by install/runtime scripts. |
| **DDNS / KeenDNS-related service** | **OPTIONAL** | Useful for remote access patterns described in the docs; not required for routing/Mihomo/MagiTrickle operation. |
| **mDNS** | **NOT A PROJECT REQUIREMENT** | It may be mandatory for the router's own component set, but current project code does not depend on mDNS. |
| **Wi-Fi controller, mobile/cloud agents, shaper, DHCP, Wi-Fi/USB interfaces** | **PLATFORM / ROUTER FEATURES, NOT PROJECT PREREQUISITES** | They may be mandatory or useful to KeeneticOS itself, but the project does not require them as install-time dependencies. |
| **PPTP/L2TP/SSTP/OpenVPN/WireGuard/IPsec/OpenConnect/ZeroTier clients or servers** | **OPTIONAL / topology-specific** | A user may select a VPN interface as an exit, but no particular VPN technology is universally required. Servers are likewise outside the base project dependency set. |
| **PPPoE/802.1X clients, EoIP/GRE/IP-IP, VRRP, ALGs, NetFlow, UPnP, udpxy, SNMP, captive portal** | **NOT REQUIRED** | No current install/runtime path depends on these components. |
| **USB modem/serial/CDC/NDIS/QMI modules** | **CONDITIONAL on WAN hardware only** | Relevant only when that modem type is the router's WAN; not a project dependency. |
| **SMB/DLNA/Transmission/FTP/SFTP/WebDAV/folder ACL components** | **NOT REQUIRED** | Storage applications are unrelated to the project runtime. |

Two distinctions matter:

1. **Installed on a known-good router does not mean required by the project.**
2. **Mandatory for KeeneticOS does not mean required by this repository.** If KeeneticOS
   forces a base component to stay installed, the project does not need to duplicate that
   requirement unless its own code actually depends on it.

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

- **DoH / DoT components and servers** — optional. The project requires classic DNS
  interception, not encrypted DNS support.
- **WireGuard / AmneziaWG / SSTP / OpenConnect / other VPN clients** — optional exits
  selected by the operator or MagiTrickle; none is a universal project prerequisite.
- **Mihomo external Controller / Web UI** — optional. Mihomo routing and ProxyN do not
  require the Controller.
- **Controller secret** — optional inside the documented trusted LAN/VPN model; direct
  exposure to WAN/untrusted networks is outside that trust boundary.
- **TUN / `mitun0`** — created only by a user Mihomo config that enables TUN. The
  bootstrap config does not require it.
- **Encrypted DNS on the router** — operational choice, not an installation prerequisite.

## Component-audit rule

When a real clean installation fails because a KeeneticOS capability is absent:

1. preserve the exact failure evidence;
2. identify the smallest missing capability/component;
3. make the installer fail early or report the dependency clearly;
4. add a small permanent regression/contract check;
5. update this document and the user-facing prerequisites.

The September 2026 external clean-install failure that exposed the missing **Proxy client**
component is the reference example for this process.
