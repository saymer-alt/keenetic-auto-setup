# Owner Experience Gate v1.0 — Keenetic Auto-Setup

This is an additional **user-observable** release gate. Green syntax,
transaction, BusyBox and rollback tests are necessary but do not alone prove
that a first-time operator can understand the install flow.

## Automated CI contract

`python3 tests/owner-experience-gate.py` exercises the real `setup.sh` in
a restricted-PATH sandbox; no WAN, OPKG operation, installed files or router
is involved. It asserts actionable refusal for missing Entware and missing
curl, clear ERROR prefixes, no ANSI when NO_COLOR is set and no attempt to
invoke an OPKG command. An error exit without a useful next step is a failure.

Additional established suites remain authoritative for lifecycle locks,
RAM/storage gates, safe config import, atomic rollback and BusyBox ash.
The new test **does not** claim to have simulated a full installation.

## Owner/agent acceptance journey (requires dedicated disposable lab)

1. On a disposable Keenetic/Entware fixture, check prerequisite reporting
   for required KeeneticOS components, EXT4, zRAM/external swap and available
   storage; do not silently downgrade an unsupported profile.
2. Start the installation as a new user: verify that output explains chosen
   storage profile, next step, required user input and how to skip config import.
3. Paste malformed YAML: the safe importer must reject it, retain previous
   config/runtime, show how to recover and not claim success.
4. Import supported YAML: verify `mihomo -t`, service and port 7890, then run
   Doctor; distinguish parse-only from observed local traffic.
5. Re-run setup/update and exercise interrupted/failed download, storage
   errors and rollback. No duplicate service, corrupt config or secret echo.
6. Check CLI at 80 and 40 columns, with NO_COLOR and non-interactive stdin;
   every failure must identify its cause and the safe next action.

**Release record:** exact SHA; scenario; command; observed prompt/output;
visible result; PASS/FAIL/UNKNOWN/NOT RUN; rollback/backup evidence; CI URL.
Do not mark UI/physical router acceptance PASS on the strength of shell
fixtures, a screenshot or agent opinion.

## Safety and release policy

Never run system-changing installation, firewall, OPKG, swap, storage or
routing tests on an owner's active router without separately approved
recovery/backup. CI must run read-only/sandboxed tests only. Production
promotion from main to stable and tagging require explicit owner approval.

Every owner-discovered UX defect gets a reproducible test where technically
feasible. Evaluate location/visibility of result, actionable text, cancellation,
idempotence, fail-closed behavior and no silent state mutation, not just exit 0.
