# KAS Control Center — simple Home LAN HTTP mode (Stage 4, experimental)

## Decision and why
Users already administer MT/Mihomo Web UI via local HTTP or an existing KeeneticOS KeenDNS HTTPS proxy with optional router-level authentication. KAS must NOT duplicate Keenetic TLS certificates, create a second PKI, or require an additional account. Our new experimental Stage 4 replaces the abandoned TLS-by-default design.

## Default installed service
- Once installed as an **opt-in Web component**, start uses the Home bridge `br0` and auto-detects its single private IPv4 address and netmask. It binds **only that IPv4** on TCP port 18081, not 0.0.0.0 or WAN, and rejects clients outside the Home bridge subnet.
- No KAS password by default. No built-in TLS, certificates, cloud accounts, login screen, or arbitrary interface scan.
- Home LAN example: `http://192.168.1.1:18081` (actual address can differ). Loopback command remains available explicitly: `kas-control-center -listen 127.0.0.1:18081`.
- If `br0` is absent, down, non-private, or has ambiguous IPv4 addresses, the service refuses to start. It does NOT silently bind 0.0.0.0, a guest bridge, WAN, or a modem IP. More complex router setups need a separate compatibility study.
- Default listener changes only for the standalone Web service in this experimental Stage 4 branch; KAS core installer and existing stable/main remain untouched.

## Optional password (off by default)
An administrator may explicitly create `/opt/etc/kas-control-center.password` as a private regular file (0600), containing a password of 12–128 characters without colon or newline. The service detects that file and enables HTTP Basic authentication. If absent, there is no KAS-level auth. Removing it and restarting disables auth.

Basic over *ordinary HTTP is not encrypted*. Use it only on a genuinely trusted LAN, or access through an independently authenticated HTTPS proxy provided by Keenetic. Do NOT assume a KAS password alone protects credentials over an untrusted segment.

## Existing KeenDNS domains and HTTPS
Do not change KeenDNS, its 4th-level subdomains, its HTTPS certificate, WAN access rules, or user configuration from KAS. They remain the responsibility of KeeneticOS.

When the owner has configured a 4th-level KeenDNS reverse-proxy hostname AND separately enabled router-level authentication, they can create `/opt/etc/kas-control-center.proxy-origin` with one line, for example:

    https://kas.myrouter.keenetic.pro

The service then accepts the exact proxy hostname + HTTPS Origin pair (no generic X-Forwarded-Host or X-Forwarded-Proto trust), in addition to direct Home IP HTTP requests. This optional setting **does not publish** the application or enable KeenDNS: the router's proxy/authentication/firewall still need to be configured, tested and reviewed independently.

## Scope of defenses without complexity
- Home bridge br0 private address and actual prefix are checked at runtime; invalid/ambiguous configurations refuse to bind.
- HTTP API accepts only Home-origin requests (or configured exact HTTPS reverse-proxy origin) and checks Host, Origin and Sec-Fetch-Site for state-changing requests.
- Optional password uses a private file; invalid file fails closed, not silently disables authentication.
- All YAML changes still use the canonical KAS importer, no Web YAML engine or second Mihomo process. Offline Go/RU-EN frontend unchanged.
- No WAN/guest exposure rule, port forwarding, automatic TLS or KeenDNS modifications.

## Proof and no-go
- Stage 3 native Ported/QEMU YAML success/invalid/restore + install/start/stop/remove **PASS**: https://github.com/saymer-alt/keenetic-auto-setup/actions/runs/40507797691
- Stage 4 LAN configuration and reverse-proxy Host/Origin tests require CI. Real router Home bridge and guest isolation need field acceptance before merging.
- A private/grey ISP address is NOT itself a firewall or protection if explicit proxy or router-port publication is enabled. Review WAN, guest/IoT/VPN, and proxy authentication separately. Never publish unauthenticated KAS YAML management to the public Internet.
- Manual installed-service opt-in remains separate from core KAS. No modifications to main/stable or actual router without approval.