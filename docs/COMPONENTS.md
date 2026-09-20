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
| Operator shell access (normally SSH) | required installation access, not a runtime component | the supported installation/update commands are run in a shell | operator prerequisite |

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
