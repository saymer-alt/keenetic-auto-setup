# C1 evidence gate — offline Stage A (Refs #473, #456, #465)

This is a **pure consistency and manifest-completeness checker over
caller-supplied untrusted snapshots**. It neither calls GitHub nor verifies any
source's provenance. The module returns `C1_OFFLINE_MOCK_UNVERIFIED` and
`provenance_verified=False` for **every** result, including `POTENTIAL_PASS`.
**Never copy an output into coordinator's `*_verified=True` fields, call it CI
PASS, merge a PR, or treat it as field acceptance.**

## Manifest v1 — the exact native `gates.json` contract

The classifier no longer accepts any nonempty `gates`/`checks` pair. It enforces
a **versioned manifest** (`MANIFEST_VERSION = 1`, stage `"kas"`) pinned to the
real producer `lab.gates.Evidence` at
`saymer-alt/router-emulator@9e59e0bff1319acbd191867dac1f5ace2df0655f` — the
exact reusable-workflow ref hardcoded in
`.github/workflows/ported-native-e2e.yml` — and cross-checked against the real
hosted artifact of native run
[42556157563](https://github.com/saymer-alt/keenetic-auto-setup/actions/runs/42556157563)
(artifact id 13647269022) built at KAS HEAD `274b66c1511b9224995a884372fdaf4a6bae123f`.
The manifest sets (`GATE_NAMES` 11, `CHECK_NAMES` 21, `REQUIRED_CHECKS` 8,
`CAPABILITY_NAMES` 18, `EVIDENCE_REASONS` 77) are exactly the producer's
`GATES`/`CHECKS`/`CAPABILITIES`/`REASONS` at that pin.

### Enforced shape (all fail closed)

| Section | Rule | Fail-closed reason |
|---|---|---|
| top-level | `schema == 1` (int, not bool) | `NATIVE_ARTIFACT_SCHEMA_UNSUPPORTED` |
| top-level | `platform == "WR3000P_PORTED_5_1_8_QEMU"` | `NATIVE_ARTIFACT_PLATFORM_MISMATCH` |
| top-level | `hardware_acceptance == "NOT_TESTED"` | `NATIVE_ARTIFACT_HARDWARE_ACCEPTANCE_MISMATCH` |
| `gates` | exactly the 11 producer gate keys | `REQUIRED_GATE_MISSING:<names>` / `NATIVE_UNEXPECTED_GATE_KEY` |
| `checks` | all 8 stage-required checks present | `REQUIRED_CHECK_MISSING:<names>` |
| `checks` | no keys outside the stage manifest (other stages/profiles) | `NATIVE_CHECK_OUTSIDE_STAGE_MANIFEST` / `NATIVE_UNEXPECTED_CHECK_KEY` |
| entries | exactly `{"status", "reason"}`; status in the producer vocabulary; reason in the 77-label producer vocabulary | `NATIVE_GATE_DETAILS_MALFORMED` |
| `capabilities` | exactly the 18 producer keys; `SUPPORTED/UNSUPPORTED/BLOCKED/NOT_TESTED` | `NATIVE_ARTIFACT_CAPABILITIES_MALFORMED` / `NATIVE_GATE_DETAILS_MALFORMED` |
| `references` | exactly the 9 producer names; `kas_commit == head`; `emulator_commit`/`qemu_source_commit`/firmware/keenboot/both lock hashes pinned to producer constants; `qemu_binary_sha256` 64-hex | `NATIVE_ARTIFACT_REFERENCE_MISMATCH` |
| `measurements` | subset of `doctor_ok/doctor_warn/doctor_fail`, int 0..10000, not bool | `NATIVE_ARTIFACT_MEASUREMENTS_MALFORMED` |
| outcome | `PASS/FAIL/BLOCKED` consistent with per-entry statuses (producer outcome rule) | `NATIVE_AGGREGATE_CONTRADICTS_GATE_DETAILS` |

### Stage producibility — why `outcome=PASS` can never pass

The producer controller sets `KAS_UNINSTALL_PACKAGES` and `KAS_UPDATE_E2E` to
`BLOCKED/prerequisite_blocked` before the stage-`kas` lifecycle and never
overrides them, so a `pull_request` artifact can never carry `outcome=PASS`
(verified against the real artifact above, whose `outcome` is `BLOCKED` even on
a workflow-green run). Consequently:

- any snapshot claiming `outcome=PASS` → `INCOMPLETE:
  NATIVE_OUTCOME_NOT_PRODUCIBLE_FOR_STAGE`;
- any snapshot deviating from `BLOCKED/prerequisite_blocked` for that pair →
  `INCOMPLETE: NATIVE_GATE_NOT_PRODUCIBLE_FOR_STAGE`;
- `POTENTIAL_PASS` is reachable **only** with the full manifest: exact 11 gates,
  all 8 required checks, all exercised gates and required checks `PASS`, the
  prerequisite pair exactly `BLOCKED/prerequisite_blocked`, `outcome=BLOCKED`,
  reason `ALL_REQUIRED_GATES_CONSISTENT`. The legacy two-entry fixture
  (`BOOT_READY` + `KAS_FOREIGN_RESOURCES`) now fails with
  `REQUIRED_GATE_MISSING:AUTH_READY,...` instead of a potential full pass.

Workflow-only stage variants (`uninstall-packages`, `kas-update`, `entware`,
`preflight`, `knvr`, profile `legacy-bridge`) are `workflow_dispatch`-only in
the native workflow and are **not** part of the PR evidence contract; any
artifact carrying their checks (e.g. `KAS_UPDATE_RELEASE_UPGRADE`) fails closed
with `NATIVE_CHECK_OUTSIDE_STAGE_MANIFEST`. A producer or emulator-pin bump
makes new artifacts fail closed until this manifest is consciously
re-versioned — that is the intended drift tripwire.

**Duplicate keys:** the module assesses a *parsed* JSON object; raw-text
duplicate keys collapse before assessment (last-wins) and are therefore covered
by exact-set equality — a collapsed duplicate can neither add an unexpected key
nor remove a required one. Raw-text duplicate detection needs the artifact
bytes and belongs to Stage B. Duplicate workflow run ids fail closed now
(`NON_DISTINCT_WORKFLOW_RUNS`).

## Result classes

`INCOMPLETE` (invalid/missing/malformed/manifest-incomplete/conflicting
evidence), `GATE_FAILED` (Shell, Native or aggregate failure),
`GATE_BLOCKED` (native workflow green, aggregate blocked — including the real
#470 shape), `POTENTIAL_PASS` (mock consistency only; **NOT verified**). The
#458 Shell success / Native failure is `GATE_FAILED`. Every result carries
`source=C1_OFFLINE_MOCK_UNVERIFIED` and `provenance_verified=False`; reason
strings are fixed labels (plus sorted manifest constant names after the `:` in
`REQUIRED_*` reasons) and never echo untrusted input.

## Local regression

```sh
python3 -m unittest discover -s scripts/orchestration-evidence/tests -v
```

67 offline unittest cases: positive classification, all workflow-level
regressions (#458, #470), manifest completeness negatives (missing/unexpected/
outside-stage gates and checks, tampered/missing/extra pinned references,
forged reason labels, entry shape, capabilities/measurements mutations, stage
producibility, aggregate contradictions, untrusted-payload non-echo). No
tokens, model, network, GitHub writes, devices or clock dependence. The CI
workflow discovers this directory with a guarded mock-only step.

## Required next stage (NOT implemented)

Owner-controlled read-only adapter that fetches **real** GitHub metadata and
byte-limited native artifact by exact run ID, enforces pagination/provenance,
ties the artifact to the current PR head, independently validates the outcome,
and only THEN grants verified evidence to C0 policy. Test adversarial cases
including replayed/forged artifacts, wrong runs, transient network errors,
malformed or oversized ZIP/JSON, raw duplicate-key detection, and stale PR
HEAD. No real claims, merge, comment publication or executor dispatch without
their own GO.

This file and module are isolated from ongoing #458/#466; no production
runtime integration, auto retry, external API calls or router/VPS changes.
