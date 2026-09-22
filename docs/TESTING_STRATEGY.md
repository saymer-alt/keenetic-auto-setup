# Testing Strategy

This document records the testing policy that emerged from development of this project. The target is KeeneticOS + Entware on real routers, so a larger synthetic test matrix is not automatically a better test.

## What we learned

Extensive synthetic testing successfully hardened known high-risk invariants, especially locking, transactional replacement, rollback, recovery, and the one-Mihomo rule. The large temporary adversarial harness used during that work is not a permanent project artifact; preserve the resulting production invariants and add only small committed regressions/contracts when they are cheap and useful.

They did not adequately cover the diversity of real installation prerequisites and cross-repository bootstrap state. The first external clean installation exposed two ordinary integration failures that the synthetic campaigns had not modeled:

- the KeeneticOS Proxy Client component was absent, so ProxyN creation did not take effect;
- the Mihomo package from the sibling `entware-go` repository shipped a bootstrap config without the project's required `mixed-port: 7890` endpoint.

Both failures were converted into permanent production checks, and the repository now keeps a small committed contract smoke test in `tests/contracts.sh` for the cross-component assumptions that can be checked without emulating KeeneticOS. This is the model to follow: a real failure should leave behind the smallest useful permanent check.

## Priority order

For normal development, test in this order:

1. **Real installation states and real bug reports.** Reproduce the smallest relevant state instead of inventing a broad failure matrix.
2. **Cross-component contracts.** Check boundaries that can drift independently: KeeneticOS component/capability → installer, `entware-go` package → bootstrap config, ProxyN → `127.0.0.1:7890`, watchdog → canonical runtime layout.
3. **Committed contract/regression checks.** Run `sh tests/contracts.sh` and extend it only when a real bug can be represented cheaply. High-consequence maintenance ordering is additionally pinned by `python3 tests/transaction-invariants.py`: it checks the real updater/watchdog-updater/migrator source for stage → backup/validation → controlled stop → atomic commit → rollback/preservation invariants without pretending to emulate KeeneticOS. Temporary adversarial harnesses used during development are not a permanent KeeneticOS emulator.
   Minimal GitHub Actions CI runs these committed contract/regression checks plus shell syntax,
   repository-local Markdown-link validation and whitespace checks automatically on pushes/pull
   requests to `main` and `stable`; green CI is a required cheap gate, not proof of router compatibility.
4. **Static/syntax review.** Run `sh -n` for changed shell scripts and review BusyBox/POSIX compatibility.
5. **Focused synthetic failure injection** only when the change touches a high-consequence invariant.

A green synthetic harness does not prove a clean installation on every Keenetic configuration. Conversely, a real device failure should not trigger a full-system Keenetic emulator when a narrow contract test can preserve the lesson.

## High-consequence invariants

Deeper adversarial testing is justified for changes to atomic update/replacement and rollback, locking and stale-lock takeover, one-Mihomo execution discipline, service-state restoration, watchdog recovery decisions, and destructive or persistent router mutations.

For documentation, diagnostics, read-only helpers, and narrow presentation changes, prefer focused verification. Do not automatically rerun the largest failure matrix.

## Test-budget rule

Before building a temporary harness, ask whether an existing permanent test can express the scenario.

For a normal task:

- prefer roughly 5–10 focused scenarios over a new exhaustive matrix;
- if temporary scaffolding is unavoidable, keep it small (roughly <=100 lines) and disposable;
- allow at most two iterations spent repairing the test harness itself;
- if the harness fails twice because of harness defects, or maintaining the model costs more than validating the production change, stop and report the limitation;
- do not build a full KeeneticOS emulator for a narrow change.

Partial but truthful verification of the production diff is better than a large synthetic environment whose own behavior is uncertain.

## Real-hardware testing

Live hardware is most useful for contract and integration checks that mocks cannot reliably reproduce: component availability, `ndmc` behavior, package/conffile semantics, memory pressure, filesystem behavior, process lifecycle, and actual routing.

Live tests must remain conservative:

- no destructive experiment on a production router merely to improve coverage;
- preserve the user's current service state;
- prefer read-only observation first;
- use a short planned outage when executable Mihomo validation is required rather than running a second Mihomo beside the daemon;
- never publish private addresses, credentials, configuration secrets, or raw diagnostics from a user's router as test fixtures.

## Current hardware evidence

The support matrix distinguishes **code/package support** from fresh hardware acceptance:

| Architecture | Current evidence | Status |
|---|---|---|
| `aarch64` | KN-1012 live acceptance, including repeat install + Doctor on KeeneticOS 5.1.5 | current live evidence |
| `mipsel` | KN-1010 / MT7621 live acceptance, including universal installer lifecycle and MIPS-stack migration findings | current live evidence |
| `armv7` | installer/updater package path is implemented and CI-covered structurally | supported path; no equally fresh live acceptance recorded |
| big-endian `mips` | installer/updater package path is implemented and CI-covered structurally | supported path; no equally fresh live acceptance recorded |

Earlier field use on KN-1810, KN-3811 and KN-1913 remains valid historical evidence, but
is not presented as a substitute for current per-architecture acceptance.

Do not buy/find hardware or create synthetic emulation merely to make every matrix cell
green. When an `armv7` or big-endian `mips` router naturally becomes available, run
the same conservative install → Doctor → update/reboot acceptance and record the result.

## Deliberately untested destructive faults

A deliberate hard power cut in the microsecond around updater/migrator commit is **not**
a required production-router test. The safety model is architectural instead:

- the old canonical file remains present until a same-filesystem atomic rename commit;
- rollback material is prepared before the risky phase where applicable;
- orphaned managed stage files are bounded and cleaned by the next maintenance run;
- temporary maintenance coordination lives under `/tmp` and naturally disappears on reboot.

If a real spontaneous power-loss incident ever exposes a recovery gap, preserve the exact
evidence and add the smallest regression for that failure. Until then this is a documented
residual fault class, not an action item.

## Release gate

A release does not require rerunning every historical synthetic campaign. Run the committed
CI checks (including `sh tests/contracts.sh`, shell syntax and local Markdown-link validation);
the gate should then confirm:

- the intended commit is the current release candidate;
- GitHub Actions CI is green for the reviewed candidate;
- relevant permanent regressions for changed high-risk code are green;
- real-hardware acceptance evidence exists where the change depended on hardware behavior;
- sibling-repository contracts used at install time are still valid;
- documentation describes current behavior and safety invariants;
- no secrets or private live diagnostics were added;
- the tag/release, when approved, is created from the exact reviewed commit.

New feature work stops during the release gate unless a concrete blocker is found.
