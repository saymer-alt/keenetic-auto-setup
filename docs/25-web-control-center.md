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


## Stage 2 work-in-progress (stacked branch feat/kas-control-center-yaml-import)

This prototype now exposes a **loopback-only** upload/paste-and-apply path:

- The browser uploads an entire YAML file with explicit confirmation (max 1 MiB). No URL/subscription fetch, arbitrary filesystem path, YAML construction or config download.
- The adapter creates a 0600 O_EXCL temporary candidate in /tmp, invokes its build-time bundled copy of **the canonical config-import.sh** via `sh -s -- <staged-file>`, then removes the candidate. Both importer and Doctor are copied by `go generate` from the reviewed source revision; no runtime `curl | sh`.
- Canonical KAS importer owns the lifecycle lock, one-Mihomo pre-validation, backup and rollback. The GUI intentionally does **not** implement a second rollback or attempt to pre-validate with a second Mihomo daemon.
- HTTP response is 202 with an operation ID, and GET /api/config/operation returns just the latest running/success/failure state and actual exit code. The work continues after browser disconnect. The GUI polls only while an operation is RUNNING; it does not run a background health loop.
- No uploaded YAML, subscription URL, password, shell output or raw exception is returned through the import API or written to app logs. Errors have generic machine-readable codes. This is deliberate: Mihomo validation output could otherwise reveal configuration secrets despite heuristic redaction.
- Concurrent import/Doctor invocations are blocked in the adapter. Core KAS locking independently remains authoritative.
- A successful importer exit shows only that the importer reported success; a failure does not assert rollback until independently verified. An unresponsive importer remains RUNNING rather than being SIGKILLed mid-transaction.

### Known blockers before any router test or release

- Staging listener remains 127.0.0.1 only (or explicit ::1). No password/session implementation, no verified trusted management-LAN boundary, no WAN/guest/IPv6 protection beyond loopback.
- No GUI package lifecycle, IPK, service supervision or operator-friendly independent install/uninstall yet.
- Full real `config-import.sh` emulator E2E, failed post-commit rollback, reboot, storage-full tests and memory/CPU benchmarks have **not** been completed as part of Stage 2.
- The in-memory latest-operation record is not durable across GUI restart. A restart during an import can leave the last state UNKNOWN; do not infer a rollback. Never test a live router until the service lifecycle and crash semantics are evaluated.
- Independent `Проверить YAML` without side effects is not supplied: the existing canonical importer must temporarily stop Mihomo for its one-instance validation. We will not pretend that a read-only preflight is equivalent.
- The 1 MiB input limit is deliberately conservative. Larger configs require a separate evidence-backed decision.
- Server transport is HTTP on loopback only: SSH forwarding is acceptable for test development, not a final replacement for SSH.

Tests in the branch cover bounds, bad Host/Origin/Content-Type/confirmation, duplicate requests, temporary-file mode, absence of secret echoes, truthful failure exit and non-TTY file-argument handoff. They are unit/adapter tests, **not** the full KAS importer end-to-end proof.
