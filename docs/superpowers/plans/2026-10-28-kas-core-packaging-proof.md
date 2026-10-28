# KAS Core Packaging Qualification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Prove an archive/ownership boundary before migrating active KAS files.

**Architecture:** Build a laboratory all-architecture script bundle, leaving all
active files untouched. Characterize real Entware opkg failure semantics rather
than assuming it implements the KAS transaction.

**Tech Stack:** Python standard library (build/tests), POSIX sh hooks, official
Entware opkg in disposable offline roots.

**Spec:** `docs/superpowers/specs/2026-10-28-kas-core-ipk-design.md`

## Global Constraints

- No real-router operations or main/stable/latest changes.
- Lab bundle only: do not activate scripts, publish a release or add UI dependency.
- Preserve original runtime scripts byte-for-byte in this phase.
- Root-only file ownership and foreign/modified-file protection.

## Review Focus

- Changed/unrecognized bundle: refuse replacement and preserve it.
- Symlink directory/file: refuse writes through it.
- Existing watchdog/config/cron: remain byte-identical during bundle lifecycle.
- Failed postinst: observe actual payload state, do not claim rollback.
- Package removal: demonstrate why live operational files need a separate policy.

### Task 1: Real opkg characterization

**Files:** Create `tests/test_core_ipk.py`.
**Interfaces:** Official opkg path is supplied by `KAS_TEST_OPKG`; no live root.

- [x] Build synthetic packages with the existing tar-IPK archive writer.
- [x] Install and upgrade a synthetic live file with failing postinst; assert
      nonzero exit and identify whether the old file was restored.
- [x] Remove the synthetic package; record whether its operational file remains.
- [x] Run with verified official opkg and record the concrete findings.

### Task 2: Protected laboratory bundle

**Files:** Create `packaging/core/build-ipk.py`, `packaging/core/README.md`;
extend `tests/test_core_ipk.py`.
**Interfaces:** CLI `--version VERSION --source-sha SHA --output DIRECTORY`;
package `kas-core`, architecture `all`, scripts under `/opt/libexec/kas/`,
metadata under `/opt/share/kas-core/`. Build labels must say lab-only.

- [x] Write failing build/archive/install/upgrade/remove/protection tests.
- [x] Implement a source-pinned script archive and integrity manifest.
- [x] Refuse adoption of preexisting paths; on upgrades require opkg ownership
      and matching installed-file digests. Reject symlinks and changed files.
- [x] Validate installed bundle in postinst, without executing bundled scripts.
- [x] Refuse destructive removal of changed bundle files.
- [x] Verify real opkg transactions, all script shell syntax and existing IPK tests.

### Task 3: Evidence and regression gate

**Files:** Create `.github/workflows/kas-core-package-proof.yml` and document
findings in `packaging/core/README.md`.
**Interfaces:** CI pins official opkg SHA256 and runs offline-root tests only.

- [x] Add CI on this experimental branch and relevant PR paths.
- [x] Record proof limitations and the chosen direction for activation.
- [x] Obtain a fresh whole-branch review and address blocking findings.
- [ ] Commit/publish an isolated draft PR; no release or merge.

## Later plans

Activation/adoption, real guest IPK boot, version UI/Doctor and maintenance
buttons are subsequent deliverables, not falsely claimed by this qualification.

## Execution evidence (2026-10-28)

- 12 core qualification tests pass with pinned official Entware opkg.
- 8 existing panel IPK tests pass with the same real opkg.
- All bundled scripts/hooks pass sh and dash syntax checks; repository contracts pass.
- Fresh independent review found three issues: CI privilege, live-root aliases and
  opkg database writes before hooks. Fixed privilege/aliases, added regressions,
  documented and characterized the database boundary. Re-review: no blockers for
  the lab-only deliverable.
- Production gates still open: pre-opkg preflight, canonical activation/adoption,
  rollback/removal policy and actual guest panel IPK boot.
