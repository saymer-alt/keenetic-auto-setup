# KAS Control Center — Stage 1 (experimental, 2026-10-27)

Related: [#221](https://github.com/saymer-alt/keenetic-auto-setup/issues/221), [#223](https://github.com/saymer-alt/keenetic-auto-setup/issues/223).

## Proof Before Build

The real need is replacing Mihomo subscriptions/config on several Keenetic routers without SSH. Existing MetaCubeXD does not implement KAS's safe import/update workflow, while current KAS CLI does. Alternatives: keep SSH; use MetaCubeXD for only Controller tasks; built-in KeeneticOS UI (does not expose KAS transaction); thin standalone GUI. Qualitative benefit: **high** for YAML import, **medium** for Status/Doctor alone. Added costs: another optional process, RAM/flash/CPU and security support. Decision: **THIN ADAPTER**. STOP if safe LAN access or resource budget cannot be demonstrated.

## Implemented first slice

- Go stdlib adapter and offline HTML/CSS/JS, no external assets/frameworks.
- Status GET is **filesystem evidence only**, always network state UNKNOWN. File presence proves neither process liveness nor correct client routing.
- Doctor POST executes the **canonical repository** mihomo-doctor.sh, snapshotted from the same source revision and embedded at build time. No download or arbitrary commands on HTTP request. Bounded output, actual exit code and timestamp.
- Basic sensitive-line redaction is not exhaustive; manually review diagnostic output before sharing.
- RU/EN toggle does not rerun Doctor; localStorage disabled is tolerated.
- Max one Doctor, request cap, Host/Origin/Fetch-Site controls, timeouts, no CORS.
- **Loopback-only** hardcoded safety boundary. This is a staging-only prototype, NOT a routable LAN Web UI.

**NOT implemented**: YAML/subscription import, updaters, password-authenticated LAN, router installation/upgrade/removal scripts, UI access from another PC/phone without SSH tunneling, IPK, resource benchmarks or emulator acceptance. No KAS core scripts or installed routers are changed.

## Reproduce in the repository checkout

Run from repo root on a development system with Go >=1.21:

    cd web/control-center
    go generate ./...   # copies canonical ../../mihomo-doctor.sh to a gitignored build snapshot
    go test ./...
    go build -o kas-control-center .
    ./kas-control-center -listen 127.0.0.1:18081

Open http://127.0.0.1:18081/ on that machine. On a staging router access through trusted SSH tunneling only, as a proof of concept, not as the final operator workflow. Always regenerate the embedded Doctor from the reviewed source revision; CI compares the generated script with the root copy. Before actual release pin source revision and checksums.

## NEXT PRIORITY: YAML/subscription replacement (separate PR, not expansion of #223)

1. Implement explicit optional lifecycle, an authenticated management-LAN listener with Host/Origin/CSRF/rebinding protections, no WAN/guest/IoT access, no open IPv6, bounded request bodies. Auth OFF by default remains a product policy requiring a separately proven trusted-LAN boundary; do NOT deploy without one.
2. Upload/paste YAML, enforce size, private temporary 0600 staging. Avoid storing/exposing subscription URLs and secrets in diagnostics. No arbitrary file paths or shell commands from HTTP.
3. Apply only via canonical **non-interactive** config-import.sh candidate-file argument; retain existing lifecycle lock, single Mihomo validation, backup/atomic replace and rollback; no new config engine.
4. Test offline, reboot, no TTY, interrupted request, double-click, invalid YAML, backend failure, storage full, version mismatch, rollback, accidental browser close and panel removal without impacting KAS.
5. Compare Go vs BusyBox CGI and measure ARM64/MIPSel binary size, RSS/HWM and CPU on emulator and test hardware, and check config/import does not depend on UI uptime.

Further: existing Mihomo and MagiTrickle update commands; Doctor/route diagnostics; opt-in native KeeneticOS Ping Check per [#240](https://github.com/saymer-alt/keenetic-auto-setup/issues/240). No second watchdog, network/routing brain, plugin framework or web terminal.

## Verification limitations

Local Go tests cover Host/Origin gate, loopback-only listener, throttling, representative redaction, exit-code handling and no invented network health. CI should run these plus bundle-equality and ARM64 build. This does NOT certify KeeneticOS compatibility, auth, safe LAN write access, YAML import, independent install/uninstall, emulator tests, device memory consumption or resource budget.

No merge to main/stable, no production router installs and no release without review and emulator/test-hardware evidence.
