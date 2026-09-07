# Changelog

All notable changes to this project will be documented in this file.

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
