# Core baseline catalogue, verified activation receipts and version display

> **For agentic workers:** Use superpowers:executing-plans task-by-task; all work
> is in the existing isolated feature worktree. User approved autonomous continuation.

**Goal:** Connect the existing guarded watchdog primitive to source-recognized
baselines and report actual installed/applied versions without claiming that a
package install activated its payload.

**Spec:** `docs/superpowers/specs/2026-10-28-kas-core-ipk-design.md`.

## Constraints and decisions

- Keep kas-core lab/offline-root-only. No automatic package hook activation,
  router calls, release, merge, main/stable/latest changes or background update.
- Runtime activation is an explicit fixed watchdog action, no arbitrary command.
- Recognize only exact watchdog blobs reachable from the selected source commit;
  unknown/local/newer unrecognized bodies are preserved. History does not imply
  semantic version ordering or package authenticity.
- Runtime shell tool uses existing KAS dependency jq, no Python on routers.
- A private receipt is evidence only when its digest matches the actual canonical
  file. A failed receipt write must never report success or overwrite the last
  valid receipt. Later status detects mismatch even across a crash window.
- Default network updater, lifecycle helpers and watchdog runtime logic unchanged.

## Task 1: package catalogue

Files: `packaging/core/build-ipk.py`, `packaging/core/hook-common.sh`,
`tests/test_core_ipk.py`.

- [x] Failing tests require source-reachable unique digest/commit TSV and explicit
      activation tool entry, all covered by package integrity metadata.
- [x] Build `watchdog-history.tsv` only from selected commit ancestry; include the
      source-pinned `kas-core-watchdog.sh` helper as an extra package tool.
- [x] Keep the 17 original scripts copied byte-for-byte and live paths untouched.

## Task 2: explicit activation and truthful receipt

Files: `packaging/core/kas-core-watchdog.sh`, `tests/test_core_activation.py`.
CLI: `status` (read-only JSON) or `apply` (explicit canonical watchdog action).
State: `/opt/etc/kas-core/watchdog.json`, private and outside package payload.

- [x] Run failing full-script fixture tests before implementation.
- [x] Validate package ownership/integrity, catalogue, source/candidate identity
      and existing canonical digest; unknown bodies cannot invoke the updater.
- [x] Use existing `--package-candidate` updater. Serialize helper calls with a
      private transaction directory; pre-stage receipt before update, verify
      actual file afterward, atomically commit receipt, then verify status.
- [x] Test unknown/custom body, tampered catalogue, stale receipt, updater failure,
      receipt commit failure, retry after receipt failure, unsafe paths and
      unchanged default package install/remove behavior.
- [x] Record failure after successful runtime apply honestly: old receipt remains,
      status is unrecorded/stale; a repeat of apply reconciles it. No claim of a
      filesystem transaction spanning runtime file and receipt.

## Task 3: read-only panel identity/inventory

Files: new `web/control-center/components.go`/`components_test.go`, existing main,
web HTML/JS, package builder and UI/browser tests.

- [x] Compile panel version/SHA into IPK binary; developer builds say development.
- [x] GET `/api/components` inherits existing auth/Host guards; returns bounded,
      sanitized panel/core/receipt identity, never YAML/credentials/script bodies.
- [x] Hash canonical watchdog and cross-check receipt and package source; classify
      missing/unrecorded/current/stale/bundle_changed without false health claims.
- [x] Show versions and the project GitHub link in the existing UI; no new update
      button or execution endpoint in this deliverable.

## Task 4: verification/review

- [x] Core/activation/preflight package tests with real opkg where applicable.
- [x] Go tests/race/vet, 31 Node UI tests and actual Chromium fixture pass locally.
      Source-pinned archive tests pass after the checkpoint commit.
- [ ] Published-head CI: native PID/proc sh/dash/BusyBox and mandatory root
      ownership tests, including ARM64/MIPSel emulation.
- [x] Fresh whole-branch review; reproduce/fix concurrent bundle replacement,
      shell-matrix coverage and root ownership findings.
- [ ] Update draft PR #267 and inspect published-head CI.
- [x] Guest panel-IPK reboot acceptance and production core migration stay explicit
      next gates, not claimed by Linux fixture tests.

Local qualification (2026-10-28): 13 core archive/opkg tests, 8 preflight
tests, 8 panel packaging tests, 10 receipt/activation tests and 19 guarded
updater regressions pass. Go test/race/vet, 31 Node tests, contract smoke
tests and 484 Markdown links pass. Actual Chromium fixture passes. Local
PID/proc adaptation and unavailable foreign-UID chown are disclosed; native
CI remains required. No router writes, release or merge.
