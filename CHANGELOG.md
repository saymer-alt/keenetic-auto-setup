# Changelog

All notable changes to this project will be documented in this file.

---

## [Unreleased]

### Added
- `docs/HOWTO.md` and `docs/HOWTO_RU.md`: complete step-by-step usage guide (preparation, Entware, installation, modes, Mihomo config, MagiTrickle, watchdog operation, update/rollback, diagnostics, MT7621 specifics, troubleshooting)
- README: Use Cases section (whole-network split tunneling, browser-only via FoxyProxy/SOCKS5, VoIP stabilization, small fleets) and Ecosystem section for `saymer-alt/link-generators`
- `install.sh` / `install_7621.sh`: DNS transit interception (`dns-proxy intercept enable`) is now part of the automatic installation — classic port-53 queries from clients are redirected into Keenetic's DNS proxy where MagiTrickle classifies them. Idempotent (state checked before applying, config saved only on change); classic DNS only, not a DoH/DoT protection. HOWTO: WebRTC caveat and browser-specific advice for the browser-only (FoxyProxy) scenario
- README/HOWTO: DNS in whitelist networks — upstream resolver choice as part of the routing (Keenetic-native DoT/DoH, provider/Yandex/foreign resolvers comparison table with documented endpoints, availability diagnostics via `show dns-proxy` per-server stats, DNS-substitution warning, dedicated whitelist troubleshooting scenario)
- README/HOWTO: "How traffic routing actually works" — explanatory mental-model section: MagiTrickle as the decision layer (not a VPN), why clients must use the router's DNS, why client-side VPN tunnels bypass router routing, Proxy0 vs Mihomo's TUN (`mitun0`), extra Wi-Fi/LAN segments as a per-segment use case (incl. the MagiTrickle `link:`/`br0`/`br1` coverage caveat), DNS ≠ routing; plus MagiTrickle 101 (Group → Interface → Rule → Type/Condition) and Mihomo basics (role, outbounds, TUN vs Proxy0) with links to official documentation
- README/HOWTO: Mihomo `interface-name` binds only Mihomo's outbound connections — it is not a router-wide WAN switch (TUN traffic follows Keenetic kernel routing; dual-WAN example, `auto-detect-interface` note); Mihomo runs without any web UI (dashboard is optional tooling, remote hosting + SSH-tunnel security guidance); RAM measurement command in diagnostics
- README/HOWTO: final consistency pass — `ProxyN` terminology (Proxy0 is the clean-router example, not the only possible ID; `mihomo t2sN` follows the number), `allow-lan: true` rationale (for LAN clients, not for the router; firewall boundary for 7890/API), intentional IPv6-off note, explicit "no Docker in this stack" statement, advanced notes (router-side tunnels chained through Mihomo with chain-specific MTU; WARP colo ≠ exit country + [warpscout](https://github.com/vernette/warpscout) link), Quick MT smoke test and a universal 10-step diagnostic flow
- `ARCHITECTURE.md` reworked into the project's main architecture document (RU): three traffic paths (DNS classification / direct :7890 / TUN), MagiTrickle decision model (Group → Interface → Rule → Condition, `link`), ProxyN vs mitun0, MetaCubeX interface ≠ WAN, DNS architecture (client path / interception / upstream / DoH-DoT / whitelist), extra segments, browser mode (allow-lan, WebRTC), client VPN & nested tunnels, intentional IPv6-off, WARP/colo, MT TEST smoke test, diagnostics tree, security boundaries; README navigation updated to point at it

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
