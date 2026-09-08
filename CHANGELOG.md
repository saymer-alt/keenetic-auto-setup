# Changelog

All notable changes to this project will be documented in this file.

---

## [Unreleased]

### Added
- `docs/HOWTO.md` and `docs/HOWTO_RU.md`: complete step-by-step usage guide (preparation, Entware, installation, modes, Mihomo config, MagiTrickle, watchdog operation, update/rollback, diagnostics, MT7621 specifics, troubleshooting)
- README: Use Cases section (whole-network split tunneling, browser-only via FoxyProxy/SOCKS5, VoIP stabilization, small fleets) and Ecosystem section for `saymer-alt/link-generators`
- `install.sh` / `install_7621.sh`: DNS transit interception (`dns-proxy intercept enable`) is now part of the automatic installation — classic port-53 queries from clients are redirected into Keenetic's DNS proxy where MagiTrickle classifies them. Idempotent (state checked before applying, config saved only on change); classic DNS only, not a DoH/DoT protection. HOWTO: WebRTC caveat and browser-specific advice for the browser-only (FoxyProxy) scenario

### Changed
- `README.md` fully reworked: English (primary) + full Russian version, conceptual project intro, architecture overview ("Mihomo is a router inside the router"), watchdog principle, hardware/modes table
- `install.sh` / `install_7621.sh`: Proxy0 human-readable description is now `mihomo t2s0` (mapped to MagiTrickle's `t2sN` numbering). Cosmetic only: the internal `Proxy0` id and all routing logic are unchanged; existing installs keep their current description

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
