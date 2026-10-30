# Panel self-update implementation plan

> **For agentic workers:** use superpowers:executing-plans inline; one independent final review.

**Goal:** explicit Web update of the opkg-owned panel with verified runtime return.
**Architecture:** fixed channel manifest, streaming IPK validation, detached worker,
persistent exclusive gate and runtime receipt; normal opkg owns package installation.
**Tech Stack:** Go standard library, existing Entware opkg/init, Python package tooling, RU/EN JS.
**Spec:** ../specs/2026-10-29-panel-self-update-design.md (owner approved 2026-10-29).

## Global Constraints

- No changes to routers, main/stable/latest or release publication.
- No rollback/history, arbitrary URL/command, forced opkg, or dependencies.
- Preserve settings/credentials/core configuration; old test15 remains installed.
- Commit/push only with explicit instruction (AGENTS.md); retain verified working diff.

## Review Focus

- opkg preinst must not deadlock waiting for the self-update worker.
- Reboot and lost browser response must not erase exclusive operation identity.
- A newer filename is not proof of control.Version; use real opkg comparison.
- Truncated archives, links and dependencies must fail before stop/install.
- Init success is not proof that the expected new listener/version is running.

### Task 1: Candidate identity and package preflight

Files: `panel_update_package.go`, `panel_update_package_test.go`,
`packaging/update-manifest.py`, `tests/test_panel_manifest.py`.
Interfaces: `panelCandidate`, `parsePanelIndex`, `validatePanelIPK`,
`panelVersionNewer(ctx, opkg, current, candidate)`.

- [x] Write failing tests: exact channel/ABI/name/digest/size; duplicate JSON/control,
  traversal/links/dependencies, altered bytes, mismatched internal version.
- [x] Run targeted Go tests RED; implement bounded streaming parser; rerun GREEN.
- [x] Generate index from actual gzip-tar IPKs, not guessed asset versions.
- [x] Verify real opkg compare-versions including `~` versus `.`.

### Task 2: Durable worker and recovery

Files: `panel_update.go`, `panel_update_worker.go`, tests; main/components wiring.
Interfaces: `panelUpdater` check/apply/state, persistent private `panelJob`,
`runPanelUpdateWorker`, `panelUpdateGate`, `writePanelRuntimeReceipt`.

- [x] RED: same job survives cancellation/restart, exclusive gate across processes,
  failure before opkg retains old service, opkg failure never reports OK.
- [x] Implement protected state, fixed worker CLI, download/preflight/free-space,
  detached runner, opkg install, init start, runtime receipt and explicit recovery.
- [x] Exclude self-worker from importer drain; central handler denies other mutating
  API requests under durable gate, including on restarted panel.
- [x] Verify real two-process handoff, state writes, failure cleanup and gate behavior
  (aarch64 service lab, job `selfupdate-lifecycle`).

### Task 3: Web interface

Files: `web/panel-update.js`, `web/index.html`, `web/app.js`, Node/browser tests.
Interfaces: fixed `/api/updates/panel/{check,apply,operation}`; no candidate in body.

- [x] RED: explicit check/confirm, stale operation ID, lost response, reconnect,
  exact fresh `/api/components` version/SHA required before success.
- [x] Implement RU/EN and shared busy state; store operation ID only.
- [x] Verify Node suite and Chromium at mobile/desktop widths (CI `browser` job).

### Task 4: Integration and review

Files: package/service lab tests, workflow gate, `PANEL_UPDATE.md`.

- [x] Real Entware opkg offline install/upgrade with preserved user configuration.
- [x] Disposable init/service update including stop/start, browser loss, start error;
  staging reserve exercised via the space-shortage scenario. Firmware emulator stays
  separately labelled; hardware acceptance remains the owner's step.
- [x] Go suite/race/vet, Node, Python IPK tests, crossbuild four ABIs, whitespace.
- [x] Independent whole-diff review; fix material findings with RED→GREEN.
- [x] Report verified scope and remaining CI/hardware acceptance; no real installation.

## Verified checkpoint (2026-10-29, exact HEAD 16dc1ca/c0f3d22 CI wave)

All `web-ipk` jobs green on the pushed head: package-tests, service-lifecycle,
selfupdate-lifecycle (native aarch64 disposable VM), crossbuild (four ABIs);
`web-prototype`, `browser` (real Chromium panel flows), `settings-emulated`
(arm64/mipsle), lifecycle, offline-opkg also green. The selfupdate lab drives the
real chain end to end: old daemon → explicit Web check/apply → detached session
worker → real opkg/preinst stop/drain → explicit init start → private runtime
receipt → fresh authenticated identity with the exact version/SHA; honest failure
matrix: space, download, tampered index, tampered asset, wrong ABI, busy real
opkg lock, start failure plus explicit recovery, concurrent mutation denial,
byte-for-byte settings/YAML preservation.

Environment findings fixed with RED→GREEN evidence:
1. Flaky CI stop failure root-caused with new diagnostics: drain-loop identity
   race where the exiting process answers kill -0 as a zombie; state re-read added.
2. The aarch64 Entware opkg (2022) writes the package list world-writable 0666 on
   real installations; the worker now reads opkg-owned lists as evidence while
   panel-private files keep the strict mode contract.
3. The init untracked guard counted the recovery CLI itself as a second daemon;
   fixed internal CLI modes are excluded from the scan.

Remaining: hardware acceptance on a real KeeneticOS device is the owner's separate
step; no channel index publication and no releasable IPK are authorized.
