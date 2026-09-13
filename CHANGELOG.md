# Changelog

All notable changes to this project will be documented in this file.

---

## [Unreleased]

### Added

- Bootstrap `config.yaml` (`/opt/etc/mihomo/config.yaml`): on fresh installs the installer writes a minimal project bootstrap containing `mixed-port: 7890`. An untouched package placeholder is replaced; an existing user config is never modified.
- Project proxy selection: the installer reuses an existing project proxy interface matched by both description (`mihomo t2sN`) and upstream (`127.0.0.1 7890`); otherwise it creates `Proxy0` when the slot is free, or the first free `ProxyN` — a foreign `Proxy0` is never modified.
- Automatic `bypass_wa` binding: the policy (found by its description) is bound to the selected project proxy with `permit global`. Existing permits — e.g. a manual VPN binding — are never removed or reordered; a missing policy produces a warning instead of a silently created one.
- `docs/EN/README.md`: English entry point, kept in sync with the Russian README.

### Changed

- Installation and architecture documentation aligned with the current installer flow (bootstrap `config.yaml`, project ProxyN selection with foreign-`Proxy0` protection, automatic `bypass_wa` binding, self-check): `docs/03-install.md`, `docs/HOWTO_RU.md`/`HOWTO.md`, `ARCHITECTURE.md`, `docs/01-architecture.md`, `docs/02-quick-start.md`.
- Component roles clarified across the architecture docs: KeeneticOS provides the routing/firewall/NAT mechanisms, MagiTrickle automates the scheme, Mihomo routes only the traffic that enters it, MetaCubeX UI is optional and hosted by Mihomo when enabled.
- DNS/ports/bootstrap claims in the encyclopedia updated to the current bootstrap (`10`, `12`, `26`, `27`): the old package placeholder (DNS block with `1053`/fake-ip, commented controller lines) is marked historical.
- `docs/05-bypass-wa.md`: default path is the project ProxyN binding; a manual VPN permit is documented as an alternative.

### Removed

- VPS/Ubuntu notes and server-side materials (`scripts/ubuntu*.md`, `debian1.md`, `setup_debian12*.sh`, `mieru.md`) moved to `saymer-alt/vps-gateway-bootstrap`.
- Personal Entware service utility (`scripts/service`) removed from this repository (preserved in `saymer-alt/keenetic-knowledge-base`).

## [1.2.0] - 2026-09-08

### Added

- Universal `install.sh` is now the primary installation path: architecture detection covers mipsel/mips as well as ARM. Actively tested on ARM/aarch64 — the mipsel path has not been re-tested recently and should not be treated as verified until checked on a clean device.
- Dedicated `install_7621.sh` for MT7621 devices: a full project installer with the Mihomo package source adapted to the platform's architecture (MagiTrickle and the VoIP bypass are not part of this path).
- DNS transit interception (`dns-proxy intercept enable`) is enabled automatically by both installers: classic port-53 queries from LAN clients are redirected into Keenetic's DNS proxy where MagiTrickle classifies them. Idempotent (state checked first, config saved only on change); classic DNS only — not a DoH/DoT protection.
- The Mihomo proxy interface is created with the human-readable label `mihomo t2sN` (`Proxy0` → `mihomo t2s0`), matching MagiTrickle's `t2sN` numbering.

### Changed

- Quick Start reordered around the universal installer: both install locations are shown up front — internal memory (default) and disk/USB (`disk` key) — with `install_7621.sh` as the alternative for MT7621 devices where the universal installer doesn't pass.
- `update-mihomo.sh` hardened into a storage-safe, fail-safe updater: downloads to `/tmp` with a RAM gate, binary and config tests before touching the service, free-space check, automatic rollback on any failed step, `--force` reinstall, intentional MIPS refusal.

### Documentation

- README rebuilt: Russian primary + full English version; architecture model; use cases (browser-only proxy via FoxyProxy with WebRTC caveats); DNS guidance for whitelist networks (resolver table with documented endpoints, availability diagnostics, substitution warning); daily operational commands (`mihomo -t -f` config validation, status/logs).
- `ARCHITECTURE.md` reworked into the main architecture document: three traffic paths, MagiTrickle decision model (`link`, DNS interception), `ProxyN` vs `mitun0`, MetaCubeX `interface-name` ≠ WAN, security boundaries.
- New complete guides `docs/HOWTO.md` (EN) and `docs/HOWTO_RU.md` (RU): preparation, installation, modes, Mihomo config, MagiTrickle, watchdog, update/rollback, diagnostics, MT7621, troubleshooting; documentation table completed (`docs/07`, `docs/10`).
- Operational/security notes: `allow-lan` rationale and the port `7890` firewall boundary; controller API security (localhost/LAN binding, `secret`, VPN/SSH tunnel); intentional IPv6-off in the base configuration; no Docker in the Keenetic stack; MT TEST smoke test; universal step-by-step diagnostic flow.

---

## [1.1.0] - 2026-08-10

### Added
- `update-mihomo.sh`: automatic Mihomo updater (binary test, config test, free-space check, automatic rollback)
- `update-watchdog.sh`: safe watchdog updater (sanity check, `sh -n`, backup, atomic replace)
- `mihomo-interface-check.sh`: helper that lists WAN interfaces for Mihomo `interface-name` config
- `ARCHITECTURE.md`: layered architecture overview

### Changed
- `install.sh`: Mihomo packages are now fetched from `saymer-alt/entware-go` GitHub releases (API + fallback chain) instead of `sw.ext.io`
- `mihomo_watchdog.sh`: two-stage WAN check (primary targets + whitelist fallback), restart rate limiting, lock file, log rotation, jitter
- `S00ubifs`: adaptive tmpfs sizing based on available RAM

---

## [1.0.0] - 2026-05-07

### Added
- Automatic Mihomo installation
- Proxy0 auto configuration
- MagiTrickle integration
- bypass_wa policy support
- Watchdog with WAN and proxy health checks
- TMPFS mode via S00ubifs
- Log rotation for watchdog
- Jitter for distributed watchdog execution
- ARM64 and MT7621 support
- Fallback Mihomo package download
- Documentation and troubleshooting guides

### Improved
- Safer architecture detection
- Retry logic for downloads
- Better cron handling
- More reliable watchdog behavior

### Tested
- Keenetic KN-1810
- Keenetic KN-3811
- Keenetic KN-1913
