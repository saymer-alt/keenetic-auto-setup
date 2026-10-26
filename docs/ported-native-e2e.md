# Native Keenetic Ported E2E

KAS retains `.github/workflows/ported-native-e2e.yml` as an independently
pinned, **disposable QEMU/Entware integration test** for installing KAS,
running Doctor and exercising related lifecycle checks. It does not connect
to real routers and does not modify the installation scripts.

## What this caller tests

The KAS caller runs on pull requests and can also be dispatched manually with
a full 40-character `kas_ref`. It delegates to the Router Emulator reusable
workflow at the pinned SHA **shown in the caller's YAML**. That pinned
laboratory runs the `kas` lifecycle stage, including a *deliberate refusal*
from the historical `uninstall.sh --remove`. A green GitHub Actions job in this
stage **does not prove the new package uninstaller worked**. Consult the
individual gate labels in the sanitized `ported-gates` artifact; an overall
report may remain BLOCKED when a gate was not attempted.

## Accepted minimal uninstaller

The separate **`uninstall-packages` stage** was added in
[router-emulator PR #35](https://github.com/saymer-alt/router-emulator/pull/35)
and runs a real install → native service stop → `opkg remove` → preserved YAML →
repeat → reboot on virtual Keenetic Ported/Entware. Its final
[run 40313388777](https://github.com/saymer-alt/router-emulator/actions/runs/40313388777)
passed. The same production package uninstaller also passed the KN-1010
hardware test, documented in
[KAS PR #235](https://github.com/saymer-alt/keenetic-auto-setup/pull/235).

To repeat that targeted test, dispatch the **Router Emulator**
`ported-entware-kas.yml` workflow with `stage=uninstall-packages`, a full
SHA of the KAS commit under test (`kas_ref`) and a full SHA of the
compatible Router Emulator commit (`emulator_ref`); use the already accepted
run's exact inputs when reproducing that evidence. Do not infer any result
from an unrelated `kas` lifecycle workflow.

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
