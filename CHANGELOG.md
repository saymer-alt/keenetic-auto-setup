# Changelog

All notable changes to this project will be documented in this file.

---

## [Unreleased]

### Added

- `migrate-mihomo-mips.sh`: idempotent migration of the TUN `stack: gvisor` → `stack: mips` (the Mihomo IP Stack; requires mihomo ≥ 1.19.31, feature-detected through a `mihomo -t` gate rather than a version threshold). Read-only `--check` mode; minimal config mutation (only `stack:` values, trailing comments preserved, atomic same-filesystem replace, validated with `mihomo -t` before replacing); `config.yaml.pre-mips` backup kept after success as a persistent revert artifact and never overwritten; one-instance discipline (stop with confirmation before any binary execution, a watchdog-revived instance re-stopped before every execution and the final start, restart only when the service was running before, user-stopped services stay stopped); automatic rollback on validation/start/port failure; no config contents in stdout. Binary discovery mirrors the updater: running daemon’s `/proc/<pid>/exe` (canonical paths only), then `/opt/sbin/mihomo`, then `/opt/bin/mihomo`; recursive `find /opt` selection removed.
- `mihomo-doctor.sh`: strictly read-only diagnostic for the installed stack — system (RAM/swap/disk, Entware architecture and expected ipk suffix), Mihomo binary (missing / not executable / runs / version unrecognized / error exit / SIGSEGV exit 139 — reported with the live-evidence note that a concurrent daemon (memory pressure), not UPX packing, is the established pattern), config (ports, external-controller binding and secret presence, best-effort `mihomo -d /opt/etc/mihomo -t` test that is skipped — not misreported — when the binary cannot run), service state, contract port 7890 listener, project ProxyN bridge and `bypass_wa` binding (same both-marker detection as install.sh; UNKNOWN is never treated as absent), watchdog layout (canonical/wrapper/legacy) plus a read-only analysis of the watchdog log itself (history range, healthy-run/problem/restart counts, failure categories, same-hour failure series, recovery confirmation, log staleness - printed as categories and counts, never raw lines; recovery is judged only from a later `[OK] All good` entry since `[RESTART]` is logged before the restart without a success record), network reachability (DNS, GitHub API, raw.githubusercontent.com), and `mihomo` package availability in `saymer-alt/entware-go:latest` (nohf variants never selected). Prints `[OK]/[WARN]/[FAIL]/[INFO]` lines plus a summary; exit codes: 0 no problems, 1 warnings only, 2 failures. Never installs, updates, removes, starts or stops anything; never prints config contents or secrets. Binary diagnostics follow the deterministic runtime-resolution policy: the running daemon’s `/proc/<pid>/exe` names the subject when it points at a canonical path, otherwise `/opt/sbin/mihomo`, then `/opt/bin/mihomo` (the Entware init PATH order); nested copies such as `meta-backup/mihomo` are reported as extras and never selected; the opkg database’s mihomo version is reported as informational metadata, explicitly distinct from the binary version (stale opkg metadata is expected under the binary-update model).
- Bootstrap `config.yaml` (`/opt/etc/mihomo/config.yaml`): on fresh installs the installer writes a minimal project bootstrap containing `mixed-port: 7890`. An untouched package placeholder is replaced; an existing user config is never modified.
- Project proxy selection: the installer reuses an existing project proxy interface matched by both description (`mihomo t2sN`) and upstream (`127.0.0.1 7890`); otherwise it creates `Proxy0` when the slot is free, or the first free `ProxyN` — a foreign `Proxy0` is never modified.
- Automatic `bypass_wa` binding: the policy (found by its description) is bound to the selected project proxy with `permit global`. Existing permits — e.g. a manual VPN binding — are never removed or reordered; a missing policy produces a warning instead of a silently created one.
- `docs/EN/README.md`: English entry point, kept in sync with the Russian README.
- `install.sh`: last-resort Mihomo install fallback — `opkg install mihomo` from the configured Entware feed. Used only after the whole GitHub path (asset lookup → download → package install) has failed before a successful install; the transition is logged as a WARN, and the feed version may be older than the GitHub release build.

### Changed

- Naming normalized to lowercase kebab-case: `mihomo_watchdog.sh` → `mihomo-watchdog.sh` and `020-bypass_wa.sh` → `020-bypass-wa.sh` (repository files and their internal raw.githubusercontent download URLs). The deployed runtime contracts are intentionally unchanged: the watchdog is still installed as `/opt/bin/mihomo_watchdog.sh` with the `/opt/etc/cron.5mins/mihomo_watchdog` wrapper and the `/opt/var/log/mihomo_watchdog.log` log, and the netfilter hook still lands as `/opt/etc/ndm/netfilter.d/020-bypass_wa.sh` — existing installations keep working without any action.
- `mihomo-watchdog.sh`: log generation anchor and same-run restart verification — when the log file does not exist yet (fresh tmpfs after boot or the first run), the watchdog records an `[INIT] log generation started` marker; after its own `S99mihomo restart` it confirms the process via `pidof` (bounded, ≤10 s) and records `[RESTART-OK]` or `[RESTART-FAIL]`, closing the gap where a recovery was only visible at the next cron run. Backward compatible: older logs simply lack these lines; INT/TERM now also clean the lock/tmp files via the existing trap.
- `update-mihomo.sh` reworked: the update source is now the ready-to-install Entware `.ipk` published on the `saymer-alt/entware-go` release tagged `latest` — never raw MetaCubeX binaries and never the regular Entware feed. The package is used strictly as the architecture-specific container of the new `/opt/bin/mihomo`: the updater extracts the binary, verifies its reported version against the package filename (prerelease/build suffixes supported — only the last `-<release>` is the package release) and the live `config.yaml` before touching anything, then performs the same transactional binary replacement as before (backup in `/tmp`, stop, replace, verify, rollback on failure). `opkg install` is never invoked for Mihomo, so the opkg package database stays untouched; `opkg` is used only for architecture detection (`opkg print-architecture`, aarch64 / armv7 / mipsel / mips — same as `install.sh`) and, if missing, for the updater's own tool dependencies (curl, jq, gzip). Binary discovery is now deterministic: the running daemon’s `/proc/<pid>/exe` when it names `/opt/sbin/mihomo` or `/opt/bin/mihomo`, else `/opt/sbin/mihomo`, else `/opt/bin/mihomo` — mirroring the Entware init script’s PATH order; the undefined recursive `find /opt | head -1` selection is gone, and nested copies such as `meta-backup/mihomo` are never considered. Low RAM (<256 MB) is a warning instead of an abort; on low-RAM devices the old Mihomo is stopped before the extracted binary is first executed (the packaged binary is UPX-packed and unpacks in memory) and restored if pre-flight fails; a user-stopped service is never started. The downloaded `.ipk` is deleted immediately after extraction and a centralized cleanup trap removes all temp artifacts on every exit; `--force` replaces the binary even when the version already matches. No automatic downgrade: an available version that is numerically older than the installed one — or cannot be reliably ordered (prerelease/build suffixes) — is skipped with a warning, even with `--force`; exact version equality is matched by string. INT/TERM abort the updater with full restoration (service state in Phase A, binary rollback in Phase B), while EXIT only cleans temp files. The one-instance rule now also covers the installed binary: whenever a daemon may be running (pidof reports it, or pidof is unavailable), the installed-version probe is deferred until after the confirmed stop — the second-execution SIGSEGV pattern on 256 MB devices is eliminated; `Already up to date` and downgrade-skip decisions are made with the daemon down and the service is restored, so re-running the updater on a current version costs one package download and a short planned downtime instead of a blind second Mihomo execution.
- Installation and architecture documentation aligned with the current installer flow (bootstrap `config.yaml`, project ProxyN selection with foreign-`Proxy0` protection, automatic `bypass_wa` binding, self-check): `docs/03-install.md`, `docs/HOWTO_RU.md`/`HOWTO.md`, `ARCHITECTURE.md`, `docs/01-architecture.md`, `docs/02-quick-start.md`.
- Component roles clarified across the architecture docs: KeeneticOS provides the routing/firewall/NAT mechanisms, MagiTrickle automates the scheme, Mihomo routes only the traffic that enters it, MetaCubeX UI is optional and hosted by Mihomo when enabled.
- DNS/ports/bootstrap claims in the encyclopedia updated to the current bootstrap (`10`, `12`, `26`, `27`): the old package placeholder (DNS block with `1053`/fake-ip, commented controller lines) is marked historical.
- `docs/05-bypass-wa.md`: default path is the project ProxyN binding; a manual VPN permit is documented as an alternative.

### Removed

- Legacy `install_7621.sh` removed. The universal `install.sh` is the single supported installer for aarch64, armv7, mipsel and mips (live-tested on MT7621). Historical release notes below still mention the legacy installer — kept as history.
- Legacy `deploy.sh` (first-generation installer) and `mihomo_manual_update_arm.md` (manual ARM binary replacement, superseded by the transactional `update-mihomo.sh`) removed; `update-mihomo.sh` is the single supported update path.
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
