# C1 evidence gate — offline Stage A (Refs #473, #456, #465)

This is a **pure consistency checker over caller-supplied untrusted snapshots**.
It neither calls GitHub nor verifies any source's provenance. The module returns
`C1_OFFLINE_MOCK_UNVERIFIED` and `provenance_verified=False` even for
`POTENTIAL_PASS`. **Never copy an output into coordinator's `*_verified=True`
fields, call it CI PASS, merge a PR, or treat it as field acceptance.**

The exact inputs model:
- GitHub Shell workflow record (`.github/workflows/ci.yml`) with matching
  repository, event, run URL/id, completed status and 40-hex PR head;
- distinct Native E2E workflow record
  (`.github/workflows/ported-native-e2e.yml`), same head;
- **untrusted** native `gates.json` aggregate, schema version 1,
  `references.kas_commit` matching that same head, and per-gate statuses.

Return classes: `INCOMPLETE` (invalid/missing/conflicting evidence),
`GATE_FAILED` (Shell, Native or aggregate failure), `GATE_BLOCKED` (native
workflow green but aggregate blocked), and `POTENTIAL_PASS` (**mock
consistency only; NOT verified**).

The real #458 Shell success / Native failure is `GATE_FAILED`. The #470
workflow success / `gates.json` BLOCKED from unimplemented removal checks is
`GATE_BLOCKED`, not PASS.

## Local regression

```sh
python3 -m unittest discover -s scripts/orchestration-evidence/tests -v
```

24 offline unittest cases; no tokens, model, network, GitHub write, devices,
clock dependence or external dependencies. The CI workflow must explicitly
discover this **new** directory before hosted test evidence can be claimed.

## Required next stage (NOT implemented)

Owner-controlled read-only adapter that fetches **real** GitHub metadata and
byte-limited native artifact by exact run ID, enforces pagination/provenance,
ties the artifact to the current PR head, independently validates the outcome,
and only THEN grants verified evidence to C0 policy. Test adversarial cases
including replayed/forged artifacts, wrong runs, transient network errors,
malformed or oversized ZIP/JSON, and stale PR HEAD. No real claims, merge,
comment publication or executor dispatch without their own GO.

This file and module are isolated from ongoing #458/#466; no production
runtime integration, auto retry, external API calls or router/VPS changes.
