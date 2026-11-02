# Guarded KAS package activation proof

Approved continuation of `2026-10-28-kas-core-ipk-design.md`.

## Scope and decisions

Keep the core IPK laboratory-only. Prove the next two boundaries before any
production adoption: preflight before opkg initializes its database, and guarded
local watchdog activation through the canonical updater. No real-router action,
UI dependency, automatic package hook activation, release, main/stable change.

Package activation first supports an already-canonical installation only. Do not
silently migrate unknown cron layouts. A caller must provide the recognized
installed SHA and the pinned candidate SHA; a SHA alone is not an ordering or
trust policy. Curating accepted release baselines is a later integration gate.

## Task 1: pre-opkg laboratory launcher

Files: `packaging/core/lab-opkg.sh`, `tests/test_core_preflight.py`.
Interface: `lab-opkg.sh ROOT OPKG install ABSOLUTE_IPK` or
`lab-opkg.sh ROOT OPKG remove kas-core`.

- [ ] Write/run failing tests for symlinked database/status/tmp paths, root
      aliases and injection of opkg options; no subprocess or database writes.
- [ ] Implement fixed arguments, pinned official host opkg and canonical private
      offline-root checks before invoking opkg. Never promise an OS sandbox.
- [ ] Prove actual install/upgrade/remove and retain existing raw-opkg
      characterization tests. Add CI execution as root with scoped Git trust.

## Task 2: local watchdog activation

Files: `update-watchdog.sh`, `tests/watchdog-package-regression.py`,
`packaging/core/README.md`.
Interface: `sh update-watchdog.sh --package-candidate FILE CANDIDATE_SHA INSTALLED_SHA`.

- [ ] Reproduce missing local mode with failing tests of the full updater in
      redirected fixtures, never host /opt.
- [ ] Validate canonical layout, exact baseline, root-owned regular files and
      pinned local candidate under the existing lifecycle lock.
- [ ] Stage locally using existing validation/permission helpers; retain private
      same-filesystem recovery copy until post-commit verification succeeds.
- [ ] Recover the previous canonical watchdog on controlled commit/verification
      failures and INT/TERM; retain recovery material if restoration fails.
- [ ] Prove source corruption, stale baseline, foreign cron, lock contention,
      staging failure, commit failure, post-commit signal and idempotency.
- [ ] Ordinary network updater/fallback paths remain unchanged; no second
      watchdog is executed or scheduled. Document SIGKILL/power-loss limits.

## Task 3: validation and review

- [ ] Run package/preflight tests, watchdog regression on sh/dash/BusyBox where
      available, existing repository contracts and relevant lifecycle/download
      regressions; document environment limitations honestly.
- [ ] Fresh independent review, fix blockers, update Draft PR #267 and verify CI.
- [ ] No claim that a lab proof is complete production adoption or guest boot.

## Evidence and rulings

- Default network update retains its existing path and is exercised with a
  controlled local transport fixture. No new download fallback logic.
- Local PID/proc mismatch was reproduced via `/proc/self/stat` versus shell PID.
  Local transaction fixtures seed only the existing identity cache; mandatory CI
  uses native identity and no adaptation.
- Fresh review identified stage alias writes and a repeated-signal recovery
  window. Both were reproduced as failing tests before the fix. Exclusive stage
  claims, trusted parents and ownership-tracked cleanup replace blind copies.
  Package signal traps ignore further handled signals before cleanup starts.
- Source-pinned core tests intentionally reject dirty root scripts. A local
  checkpoint commit is necessary before full provenance/package verification;
  no release or merge follows from that checkpoint.
