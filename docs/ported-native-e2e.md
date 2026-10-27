# Native Keenetic Ported E2E

KAS retains `.github/workflows/ported-native-e2e.yml` as an independently
pinned, **disposable QEMU/Entware integration test** for installing KAS,
running Doctor and exercising related lifecycle checks. It does not connect
to real routers and does not modify the installation scripts.

## When the workflow runs

The caller automatically runs on pull requests that change **anything other than** Markdown documentation and issue templates (the `pull_request.paths-ignore` rules). Script/runtime, test, CI and workflow changes **still** trigger native Ported E2E. Manual `workflow_dispatch` remains available with a full immutable KAS ref. This avoids paying for an approximately 14–24 minute emulation run on documentation-only PRs; it does **not** weaken required `Shell contracts` checks, source pinning or gate semantics. Do not treat a workflow skipped by path filter as a passing native E2E test.

## What this caller tests

The KAS caller uses an immutable Router Emulator revision (`1abea236...`),
which was the exact source of the successful targeted package-removal run
[#40313388777](https://github.com/saymer-alt/router-emulator/actions/runs/40313388777).
Normal KAS pull requests **always** run the existing `kas` lifecycle stage,
with the PR head's complete SHA passed as `kas_ref`. The stage proves install,
Doctor and reboot, and intentionally observes a *blocked* legacy
`uninstall.sh --remove`; it **does not prove ordinary OPKG removal**. Read the
sanitized per-gate statuses in the `ported-gates` artifact rather than treating
an overall green workflow as a PASS for every stage.

## Accepted minimal uninstaller

The separate **`uninstall-packages` stage** was added in
[router-emulator PR #35](https://github.com/saymer-alt/router-emulator/pull/35)
and runs a real install → native service stop → `opkg remove` → preserved YAML →
repeat → reboot on virtual Keenetic Ported/Entware. Its final
[run 40313388777](https://github.com/saymer-alt/router-emulator/actions/runs/40313388777)
passed. The same production package uninstaller also passed the KN-1010
hardware test, documented in
[KAS PR #235](https://github.com/saymer-alt/keenetic-auto-setup/pull/235).

To rerun that specific test from **this KAS repository**:

1. Open **Actions → Keenetic Ported native KAS E2E → Run workflow**.
2. Select `stage=uninstall-packages`, optionally enter the full 40-character
   `kas_ref` of the KAS commit being tested (leave empty to use the selected
   dispatch branch's commit), then start the single job.
3. Inspect sanitized `ported-gates` / `summary.md`: require
   `KAS_UNINSTALL_PACKAGES=PASS` **and**
   `KAS_UNINSTALL_PACKAGES_REPEAT=PASS` and
   `KAS_UNINSTALL_PACKAGES_REBOOT=PASS` in independent checks. A `BLOCKED`,
   `FAIL` or `NOT_TESTED` result for one of those is not an acceptance PASS.

Manual `stage=kas` preserves the original installation/Doctor/reboot stage.
The stage selector does **not** add a second automatic QEMU job to pull requests.
Both the called workflow code and its checked-out emulator version are pinned
to the same full immutable SHA. The KAS commit SHA is independently pinned per
run. Retest explicitly when promoting a newer Router Emulator revision; never
change the pin to a floating `main`/branch. The previous native uninstaller
acceptance proof remains [run #40313388777](https://github.com/saymer-alt/router-emulator/actions/runs/40313388777),
not a claim about this caller's manual workflow until it is separately run.

## Security and limitations

The lab publishes only sanitized gate labels, JSON/JUnit and summary text.
Guest NAND, firmware images, USB filesystems, credentials, private YAML and
UART/SSH logs must remain private and are destroyed at the end of a run.
Pinned source and assets are necessary for reproducibility.

The old snapshot/PREPARE/transaction prototype was abandoned and its
repository files removed. The historical PRs remain on GitHub, but are not
a supported uninstall path. Production `uninstall-packages.sh` removes only
Mihomo/MagiTrickle and their recognized Entware services/watchdog; it leaves
KeeneticOS ProxyN, policies, DNS and live Netfilter state untouched.
