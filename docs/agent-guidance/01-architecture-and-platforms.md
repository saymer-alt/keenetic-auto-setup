# Architecture and supported Keenetic platforms

> Detailed **on-demand** guidance extracted from the previous root `AGENTS.md` at commit `9837c8141d60cbe6e9d408ee69515bb0bd16dbe6`. Root scripts, traffic paths, supported router/storage/memory platforms and exact runtime contracts. Relative plain-text paths like `docs/06` are repository-root-relative. The binding entrypoint remains [AGENTS.md](../../AGENTS.md) and [KAS Constitution](../CONSTITUTION.md). These notes do not authorize relaxing safety or owner permission gates.

## 1. Purpose

A POSIX-shell toolkit that turns a Keenetic router with Entware into a self-healing
VPN gateway: Mihomo (Clash Meta; VLESS/Reality) on 127.0.0.1:7890, DNS split routing
(MagiTrickle), VoIP bypass through iptables marks, tmpfs flash protection, and a watchdog.
Designed for small router fleets, including ~20 devices (docs/09). Documentation
is in Russian. This is not simply "VPN on a router", but a separation of layers
(ARCHITECTURE.md, docs/01): MagiTrickle decides where traffic goes; Mihomo is a separate
routing layer; transports are interchangeable.

## 2. Architecture

The product is the root-level scripts (there are no libraries):

| Script                    | Role |
|---------------------------|------|
| setup.sh                  | simple front-end: classifies `/opt` as internal/external, selects the normal `ram`/`disk` profile, then delegates all mutations and safety gates to `install.sh` |
| install.sh                | unified installer (architecture auto-detection: aarch64/armv7/mipsel/mips, including MT7621 — live test passed; modes `ram`\|`disk`, ram = tmpfs) |
| config-import.sh          | safe config transaction: TTY/file candidate → contract check → one-Mihomo validation → persistent previous-config backup → atomic config commit → runtime verification/rollback |
| migrate-mihomo-tun.sh     | transactional legacy-config bootstrap: when top-level `tun:` is absent, add the project `mitun0` TUN profile, choose mips for Mihomo >=1.19.31 or gvisor compatibility fallback, validate/commit/restart with rollback |
| update-mihomo.sh          | updates the Mihomo binary from the entware-go package for all architectures: config test, automatic rollback, one-instance |
| update-watchdog.sh        | updates/migrates the canonical watchdog using validation + same-filesystem staging + atomic rename |
| mihomo-watchdog.sh        | cron every 5 min: WAN → port 7890 → socks5h tunnel → restart |
| 020-bypass-wa.sh          | netfilter.d hook: mark VoIP UDP 1400/3478/3482 → policy bypass_wa |
| S00ubifs                  | tmpfs on /opt/tmp, /opt/var/log, /opt/var/run (profiles by RAM) |
| mihomo-interface-check.sh | optional manual helper: Linux interface names for proxy-outbound `interface-name`; does not route `mitun0` |
| mihomo-proxy-selection-watch.sh     | read-only diagnostics of the current Mihomo proxy-group selection (GET /proxies only) |
| mihomo-route-check.sh                | focused read-only diagnostic for one domain/IP: DNS, project ProxyN evidence, local 7890, current Controller selection and SOCKS5h target probe; never claims client-policy classification |

Traffic flows (docs/01):
- normal: LAN → Proxy0 → Mihomo → VPN → Internet;
- VoIP (UDP): mangle MARK → policy bypass_wa → VPN directly, bypassing Mihomo;
- watchdog: cron → checks → sometimes restart S99mihomo.

The most sensitive parts — change only for an explicit task and with full understanding:
- watchdog logic: check order, lock file, jitter, cooldown, and the
  "no WAN → do not restart" rule (docs/04 explicitly asks not to touch them);
- idempotency of 020-bypass-wa.sh (the hook runs on every firewall rebuild);
- rollback chain in update-mihomo.sh and RAM gates;
- config-import.sh transaction: never validate by launching a second Mihomo beside the daemon; keep the maintenance marker, previous-config backup, same-filesystem atomic commit, runtime verification and rollback ordering intact;
- migrate-mihomo-tun.sh transaction: existing `tun:` is immutable/no-op; when TUN is absent preserve one-Mihomo stop/probe discipline, version-based mips>=1.19.31 vs gvisor selection, real `mihomo -t`, per-run rollback + persistent pre-TUN backup, same-filesystem atomic commit, prior service state and post-start `mitun0` verification;
- `dns-proxy intercept enable` (transit DNS interception) in both installers:
  installer-managed persistent config; before applying — grep against `show running-config`,
  `system configuration save` only when there is an actual change; this is not protection from DoH/DoT;
- A project-managed ProxyN is the Keenetic → Mihomo bridge. New canonical interfaces use
  human-readable description `mihomo t2sN` (N = interface number, Proxy0 → t2s0), synchronized
  with the t2s numbering in MagiTrickle; the internal Proxy0/Proxy1/… identifier must not be
  changed. Legacy installers used different descriptions, so backward-compatible ownership is
  functional: `proxy protocol socks5` + `proxy socks5-udp` + upstream `127.0.0.1 7890`.
  A legacy-compatible ProxyN is reused exactly as found and its description is INFO-only:
  never rename it just to normalize naming. Selection order is canonical → legacy-compatible →
  create a free ProxyN. Foreign Proxy interfaces remain untouched.

## 3. Runtime platform contracts (current work only)

- Target: KeeneticOS + Entware (/opt) running POSIX/BusyBox ash; supported binary packaging includes aarch64, armv7, mipsel and mips. Verify binary architecture/ABI and packages for the actual task, rather than assuming a router from old fleet notes.
- For **new** external /opt installs, require EXT4 and `ext` + `ext-utils`. For internal storage, require the S00ubifs service and actual tmpfs mounts. Doctor verifies the deepest mount; scripts do not automatically format or repair storage.
- Native zRAM and external storage-backed SWAP simultaneously are a **hard error/fail** (KAS-SAFETY-001). 512 MB class requires a verified single backend for new install; all detailed RAM gates and legacy-update exceptions live in [Constitution](../CONSTITUTION.md) and [docs/06](../06-s00ubifs.md).
- Preserve binary-package provenance separation: the binary updater must not silently rewrite opkg package metadata; restore project state within rollback. Preserve existing ProxyN/KeeneticOS secure DNS requirements: at least one of `dns-tls` or `dns-https` on new installs. Consult active code and focused documentation for exact behavior.
- **No historical hardware roster belongs in agent startup.** Real hardware test evidence is model-/firmware-/storage-specific and must be verified for the exact device. Old model names and field observations have been archived separately, not treated as current live inventory.
