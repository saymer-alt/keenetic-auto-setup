# Native Ported QEMU acceptance

The caller in `.github/workflows/ported-native-e2e.yml` executes the actual PR
scripts in WR3000P Keenetic Ported with genuine EXT4 Entware. The reusable
laboratory and its source are pinned to one full Router Emulator commit:
`44c6cab9d50fcd33147ac0a3a193a5a985710796` — upstream 3.9 with the full lab
integration (PRs #1–#3), the patch-series check (PR #5) and the netfilter
settle probe-retry fix (PR #7). Dependencies are frozen separately; a KAS
change does not silently upgrade them.

After owner review/merge of the boot fix, laboratory and this caller, every KAS
PR runs on GitHub-hosted Ubuntu without the owner's computer or a physical router.
Manual dispatch accepts a full KAS SHA; an empty value selects the dispatch commit.
The workflow also runs for this caller PR before merge. No schedule is enabled.

Read the job summary and the three files in the `ported-gates` artifact: JSON,
JUnit and Markdown. BOOT, AUTH, ENTWARE, PREFLIGHT, INSTALL, DOCTOR, REBOOT,
ROLLBACK and UNINSTALL are independent gates. Expected guard rejection can make
an execution job green while the report remains BLOCKED. In the frozen baseline,
`uninstall.sh --remove` has no native removal implementation and exits 3; the lab
verifies refusal and unchanged state, and never substitutes manual deletion or
fixture rehearsal. This is not full uninstall acceptance. The real transactional `--remove`
(KAS PR #215) is exercised by dispatching this caller with `kas_ref` set to
that feature SHA; its gate contract accepts the allocator-rendered
`ip global` index (32767 on Ported), so the transaction gate can PASS
virtually before any hardware run.

The first run builds only AArch64 QEMU. Cache keys cover the exact patch series;
run dispatch once on the default branch after merge to seed a cache reusable by
PRs. Caches are repository/ref scoped. There is no full Windows/MIPS/PGO rebuild.
No secrets, PAT, device credentials or live VPN server are needed. WAN stays
restricted. Only pinned dependency paths and genuine local HTTP/DNS fixtures are
available; public watchdog targets receive no fabricated success.

Public artifacts exclude NAND, firmware, USB images, credentials, keys, password
hashes, running configurations and UART/SSH logs. Do not upload private working
directories to diagnose failures. Full input SHA values and binary hashes are in
JSON. See the pinned emulator's `lab/PORTED-E2E.md` for implementation and limits.

This result covers WR3000P Ported QEMU, not physical KN-1012/KN-3811 or any other
router. Real radios, USB behavior, power loss, external VPN/WAN/NTP and hardware
model compatibility need separate evidence. Native TUN and local SOCKS traffic
do not prove a real VPN tunnel. Production runtime and uninstall guards are
unchanged by this caller.
