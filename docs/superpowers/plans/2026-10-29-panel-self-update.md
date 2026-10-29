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

- [ ] RED: same job survives cancellation/restart, exclusive gate across processes,
  failure before opkg retains old service, opkg failure never reports OK.
- [x] Implement protected state, fixed worker CLI, download/preflight/free-space,
  detached runner, opkg install, init start, runtime receipt and explicit recovery.
- [ ] Exclude self-worker from importer drain; central handler denies other mutating
  API requests under durable gate, including on restarted panel.
- [ ] Verify real two-process handoff, state writes, failure cleanup and gate behavior.

### Task 3: Web interface

Files: `web/panel-update.js`, `web/index.html`, `web/app.js`, Node/browser tests.
Interfaces: fixed `/api/updates/panel/{check,apply,operation}`; no candidate in body.

- [x] RED: explicit check/confirm, stale operation ID, lost response, reconnect,
  exact fresh `/api/components` version/SHA required before success.
- [x] Implement RU/EN and shared busy state; store operation ID only.
- [ ] Verify Node suite and Chromium at mobile/desktop widths.

### Task 4: Integration and review

Files: package/service lab tests, workflow gate, `PANEL_UPDATE.md`.

- [x] Real Entware opkg offline install/upgrade with preserved user configuration.
- [ ] Disposable init/service update including stop/start, browser loss, start error;
  quantify staging reserve. Firmware emulator stays separately labelled.
- [ ] Go suite/race/vet, Node, Python IPK tests, crossbuild four ABIs, whitespace.
- [x] Independent whole-diff review; fix material findings with RED→GREEN.
- [ ] Report verified scope and remaining CI/hardware acceptance; no real installation.

## Verified checkpoint (2026-10-29)

Go full suite and actual source-built MIPSel IPK preflight pass with verified Entware
opkg; actual offline install/upgrade/remove retains settings and worker staging.
Node suite: 69 PASS. Four Linux architectures compile. Independent review findings
were reproduced and fixed RED→GREEN: admitted mutation race, tilde asset names,
reloaded stale operation identity. Added detached-session/stdout independence,
interrupted admission and dead-worker regressions. Chromium scenario and workflow
job prepared but NOT EXECUTED locally (no browser binary). Full firmware Web update
and runtime receipt remain unverified; no releasable IPK publication is authorized.

Executor limitation: PID namespace differs from mounted proc. Detached session test
observes the child's own proc record; this is not a substitute for target firmware
process/receipt acceptance. Next integration step needs a committed draft PR for CI;
Owner explicitly authorized commit/push and draft PR on 2026-10-29.
Handoff: 2026-10-29-panel-self-update-handoff.md.
