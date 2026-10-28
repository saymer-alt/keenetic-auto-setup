# KAS Control Center — Home-address HTTP and optional Home-only access (experimental)

## Decision and why
Owner decision 2026-10-28: routed administrative access (including SSTP/L2TP) must work by default. Source-subnet restriction is an explicit optional panel setting, not a mandatory gate. Users already administer MT/Mihomo Web UI via local HTTP or an existing KeeneticOS KeenDNS HTTPS proxy with optional router-level authentication. KAS must NOT duplicate Keenetic TLS certificates, create a second PKI, or require an additional account. Our new experimental Stage 4 replaces the abandoned TLS-by-default design.

## Default installed service
- Once installed as an **opt-in Web component**, start uses the Home bridge `br0` and auto-detects its single private IPv4 address and netmask. It binds **only that IPv4** on TCP port 18081, not 0.0.0.0 or WAN, and leaves source-subnet filtering off by default. Routed VPN clients can connect when KeeneticOS permits them.
- Home-only filtering and KAS password are both off by default. No built-in TLS, certificates, cloud accounts, login screen, or arbitrary interface scan.
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

The service then accepts the exact proxy hostname + HTTPS Origin pair (no generic X-Forwarded-Host or X-Forwarded-Proto trust), in addition to direct Home IP HTTP requests. **Router authentication is delegated, not reimplemented by KAS**: with the optional LAN password enabled, proxy requests do not get a second KAS login *only when* their actual TCP peer is the router's own Home IPv4 or loopback, and the proxy hostname matches exactly. Ordinary LAN clients cannot bypass the optional password simply by forging Host. KAS does not verify a Keenetic login session or turn on any router authorization itself. The owner MUST explicitly enable and test router authentication for the published KeenDNS domain; without it, a public unauthenticated proxy to KAS would be unsafe. This optional setting **does not publish** the application or enable KeenDNS: the router's proxy/authentication/firewall still need to be configured, tested and reviewed independently.

## Scope of defenses without complexity
- Home bridge br0 private address and actual prefix are checked at runtime; invalid/ambiguous configurations refuse to bind.
- The HTTP API requires the actual panel Host and same Origin (or the explicitly configured exact HTTPS proxy origin), regardless of source subnet. Host/Origin/Fetch-Site checks remain enabled when Home-only filtering is off. Forwarded client-IP headers are not trusted.
- Optional password uses a private file; invalid file fails closed, not silently disables authentication.
- All YAML changes still use the canonical KAS importer, no Web YAML engine or second Mihomo process. Offline Go/RU-EN frontend unchanged.
- No WAN/guest exposure rule, port forwarding, automatic TLS or KeenDNS modifications.

## Proof and no-go
- Stage 3 native Ported/QEMU YAML success/invalid/restore + install/start/stop/remove **PASS**: https://github.com/saymer-alt/keenetic-auto-setup/actions/runs/40507797691
- Stage 4 LAN configuration and reverse-proxy Host/Origin tests require CI. Real router Home bridge and guest isolation need field acceptance before merging.
- A private/grey ISP address is NOT itself a firewall or protection if explicit proxy or router-port publication is enabled. Review WAN, guest/IoT/VPN, and proxy authentication separately. Never publish unauthenticated KAS YAML management to the public Internet.
- Manual installed-service opt-in remains separate from core KAS. No modifications to main/stable or actual router without approval.
## Optional provider names export for Mihomo Unified Generator (experimental)

The **subscription server list** can be read from an already running Mihomo without browser CORS or HTTPS Pages → HTTP Mixed Content. This is a **different project feature** from the existing #322 manual fallback in link-generators. It does not fetch subscriptions and does not fix browser subscription-preview connectivity.

This export is **disabled by default**. To opt in on a disposable test router, create a regular local flag file `/opt/etc/kas-control-center.export-names` (e.g. `touch ... && chmod 600 ...`) and restart the KAS Web service using the normal service helper. Export is read-only: an explicit click requests GET `/api/providers/names` from KAS, which asks only `127.0.0.1:9090` or the router's **own Home IPv4** on TCP/9090 for `GET /providers/proxies`. No arbitrary URL or cross-network proxy support, no mutations and no subscriptions fetched remotely.

If the existing Mihomo API uses a nonempty `secret`, an administrator may separately create a private regular 0600 file `/opt/etc/kas-control-center.mihomo-api-secret` containing it. The file is read only at KAS Web startup; the secret does not appear in command-line arguments, UI, downloaded JSON, JS storage, or public logs. If no file exists, export requests are made unauthenticated; 401/403 is a failure, not an invitation to weaken the API. The original Mihomo config and API secret are never modified.

The exported `mihomo-providers-names.json` intentionally contains only provider names, optional `vehicleType`, and proxy `name` fields (shape `{ "providers": {"Provider": {"proxies": [{"name":"Node"}]}}}`). It strips server addresses, ports, UUIDs, passwords, latency history and API metadata. **Names may still contain sensitive labels:** do not post the file publicly. The output is bounded in size and always marked `Cache-Control: no-store`.

In [Mihomo Unified Generator](https://saymer-alt.github.io/link-generators/) open Mihomo Builder → Routing/DNS → Show subscription servers → Import nodes from running Mihomo → **Upload .json**, then select exclusions. Generator #322/#323 provides a manual fallback; this Web feature is an optional additional offline-JSON path and does not install or modify the generator.

For field acceptance: first confirm normal KAS Web Home-LAN and KeenDNS security with export **off**. Only then enable export, test an existing controller bound to localhost **or** own Home IPv4, optional nonempty secret, node-name Unicode/duplicates, read-only contract, Home-only opt-in denial of non-Home clients, reboot and memory. If a source is unavailable, return a clear error rather than scanning the LAN or modifying Mihomo settings.

## Optional “Home only” switch (owner field feedback, 2026-10-28)

The panel's **Panel access** section has **Allow access only from the Home subnet**,
unchecked by default. Saving is explicit and same-origin confirmed. Switching on
restricts actual TCP peers to the Home prefix; the existing explicitly configured
router-local KeenDNS proxy trust boundary remains. Switching off allows clients
from any source subnet that can reach the listener. This does not bind wildcard,
create a WAN publication, change firewall, configure SSTP/L2TP, or add authentication.
With password and Home-only filtering both off, anyone who can reach that listener
can use its management functions; reachability is the router administrator's policy.

The setting is applied live and retained across panel restarts in the private
fixed file `/opt/etc/kas-control-center.home-only` (0600, contents `1`). Absence
means off. Malformed/symlinked/non-private files refuse startup or saving rather
than silently changing the selected policy. The launcher needs no new arguments.
Enabling shows a warning that VPN/other-subnet clients may lose access. From such
a client the save response succeeds, but subsequent requests receive 403.

If enabled remotely by mistake, use Home access to disable it, or recover via SSH:

```sh
rm /opt/etc/kas-control-center.home-only &&
sh /opt/etc/init.d/S98kas-control-center stop &&
sh /opt/etc/init.d/S98kas-control-center start
```

This removes only the optional source restriction and does not alter Mihomo.
Panel removal intentionally retains this user setting like the optional password.
Do not broaden binding or alter KeeneticOS firewall merely to bypass this setting.
