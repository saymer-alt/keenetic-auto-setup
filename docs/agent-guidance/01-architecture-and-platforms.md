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

## 3. Target platforms

- KeeneticOS + Entware (/opt). Direct retained release acceptance covers **KN-1010 (MT7621AT / mipsel)** plus **KN-1012, KN-3811, KN-3812 and the operator's home Netcraze Ultra NC-1812 (AArch64 / ARM64)**. KN-1012 evidence intentionally includes materially different live profiles: work **KN-1012 SE** with external EXT4 USB flash and dača **KN-1012 GSM** with internal UBIFS/zRAM; do not collapse them into one storage/update-path result. NC-1812 and Keenetic Titan KN-1812 are different market models built on the same MT7988D-class hardware platform; never relabel evidence from one model as a physical test of the other. Preserve the exact `model` / `hw_id` reported by the tested router. Official references still establish the architecture family: KN-1010 uses the mipsel archive; KN-1012/3811/3812 use MT7981B AArch64; NC-1812/KN-1812 are MT7988D-class AArch64. Earlier field use also includes other Keenetic models; hardware tests complement, not replace, CI.
- Architectures: aarch64, armv7, mipsel, mips — one install.sh for all, including
  MT7621 (live test passed); there is no separate installer anymore.
  ipk suffixes:
  aarch64-3.10 / armv7-3.2 / mipsel-3.4 / mips-3.4 (packages come from the current
  saymer-alt/entware-go release; the final fallback if the GitHub path fails is
  `opkg install mihomo` from the configured Entware feed, whose version may be older).
- Secure-DNS component contract: because the supported traffic path always uses KeeneticOS Proxy Client / ProxyN, new installs require **at least one** of `dns-tls` (DNS-over-TLS proxy) or `dns-https` (DNS-over-HTTPS proxy). This is an OR requirement, not AND: Keenetic's Proxy Client guide warns proxy Internet access may be unreliable without DoT/DoH and recommends enabling either DoT or DoH. The project does not auto-select a resolver; whitelist-network reachability remains operator-specific.
- Entware storage / flash-protection contract: Doctor must report the deepest mount that actually carries `/opt` (source, mountpoint, filesystem and internal/external class). If Entware `/opt` is on internal Keenetic storage, supported runtime health requires the project S00ubifs service to be present, executable and enabled, and `/opt/tmp`, `/opt/var/log`, `/opt/var/run` to be active tmpfs mounts. Missing/disabled service or any missing tmpfs is a Doctor FAIL: file presence alone is not proof of NAND-write protection. This check is N/A/INFO when `/opt` is external persistent storage.
- External-storage contract: if Entware `/opt` is on external persistent storage, new installs support **EXT4 only**. `install.sh` reads the actual deepest `/opt` mount from `/proc/mounts`; external non-EXT4 is a hard preflight error. External `/opt` additionally requires KeeneticOS component ids `ext` and `ext-utils` from `show version`. Internal UBIFS installs are not subject to these two storage-component requirements. Doctor mirrors violations as FAIL; update-mihomo.sh only warns for an already-existing legacy non-EXT4 install and continues servicing it. The project never formats, converts or repairs storage automatically. `ext-utils` is required for the platform filesystem check/repair tooling; do not claim automatic fsck on every boot without separate evidence.
- Mihomo package/binary metadata boundary: `update-mihomo.sh` is a **binary-only** updater and must not rewrite Entware opkg package metadata or call `opkg install mihomo`. The opkg database describes the package payload as a whole; the canonical binary committed by the project is tracked separately in `/opt/etc/keenetic-auto-setup-mihomo.state`. That state must participate in the same rollback transaction as the binary. Doctor treats runtime version as truth, project binary state as project provenance, and opkg metadata as package-manager provenance; none may be silently substituted for another.
- **CONSTITUTION:** `docs/CONSTITUTION.md` is binding for every agent, contributor, review and release. Any proposed change that reduces the dual-swap ERROR/FAIL gate or adds a bypass MUST be rejected, even when tests are green; do not treat historical WARN documentation as precedent.
- **NON-NEGOTIABLE zRAM + external SWAP prohibition (owner decision, reinforced for v1.8.2):** Never downgrade coexistence to WARN/INFO, introduce an override, or silently disable either backend. Installer MUST reject it before package/network/mutations, Doctor MUST report FAIL, and update-mihomo.sh MUST abort before binary/service mutation. This applies to every RAM class and every /opt mode. The rule remains even if vendor guidance or RAM-class policy changes: changing it requires a separately reviewed explicit owner decision, not refactoring or an automated agent's judgment. Keep negative acceptance tests across these consumers and BusyBox ash. Historical v1.8.0 and v1.8.1 tags demonstrably allowed this combination with WARN; this is a correction of previously weakened policy, not a newly discovered regression confined to v1.8.1.
- Resource-profile contract `20261012_1` (live-detected from /proc/meminfo, /proc/swaps, /proc/mounts; never guessed; rationale, vendor links and field evidence in docs/06): 128 MB-class remains best-effort/experimental and install.sh REFUSES it unless /opt is verified external AND external storage-backed active swap is >=384 MB (project-specific floor; zRAM never counts). 256 MB-class is expected to have one active memory-pressure backend: native KeeneticOS zRAM OR verified external storage-backed swap; absence remains WARN and does not block installation. **512 MB-class is a constrained profile, not a bare-RAM supported baseline:** a supported new install REQUIRES active native KeeneticOS zRAM OR verified external storage-backed swap; if neither backend can be verified, install.sh stops with ERROR and Doctor reports FAIL. There is no low-memory override for this class. This rule is keyed to live MemTotal/backend state, not model name or router role; there is no AP/extender exception because role/load can change and the project must retain OOM headroom. When external swap is chosen on 256/512 MB-class, 1x detected RAM remains the project warning floor: below 1x is WARN, while 1x..3x is informational only. The preferred sizing target remains 3x detected RAM capped at 2 GiB; external swap above 2 GiB is an install ERROR / Doctor FAIL. The 1x floor and 3x target are project policy, not vendor minimums. Vendor guidance says not to combine zRAM with disk/file swap; Installer rejects new installation if both are active; Doctor reports FAIL; the existing-install updater rejects the update without changing the running installation. None automatically changes either backend. Above the 512 MB-class, swap/zRAM is optional. update-mihomo.sh blocks the zRAM + external SWAP conflict before mutation, while other existing legacy resource-profile violations remain WARN-only; all transaction safety gates remain enforced. The project never creates/enables/formats/mounts/resizes swap or storage.
- MIPS/mipsel: upstream Mihomo publishes official MIPS/MIPSLE builds, and the current universal install.sh AND update-mihomo.sh both support the packaged `mipsel-3.4` / `mips-3.4` paths from saymer-alt/entware-go. Do not substitute random third-party binaries.
- Shell dialect is busybox/ash: do not use bashisms; `local` is allowed
  (busybox supports it and it is already used in the watchdog). $RANDOM, pidof, ss, netstat
  may be absent — preserve selective `command -v` checks in the code.

