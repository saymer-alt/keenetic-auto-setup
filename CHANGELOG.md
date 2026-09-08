# Changelog

All notable changes to this project will be documented in this file.

---

## [Unreleased]

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
