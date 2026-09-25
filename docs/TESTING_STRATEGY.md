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

## External command output is an input protocol

Text printed by KeeneticOS/Entware commands is external input, not a shell-native data structure. Parser assumptions must be based on the producer's real record grammar, not on one visually convenient sample.

Three output classes are intentionally treated differently:

- **Structured output** (for example RCI/JSON): parse structurally when available and practical.
- **Configuration command streams** such as `show running-config`: physical lines are commands/block structure. Do not globally concatenate or unwrap them.
- **Human-readable/display output** such as `show version`: one logical field may be wrapped across physical lines for presentation. Line-by-line token matching is unsafe when the field grammar allows continuation.

The wrapped-component incident established a concrete rule. On 2026-09-19 the operator's Netcraze Ultra **NC-1812 / KeeneticOS 5.1.5** already showed a component ID split inside the token (for example `ike-` / `client`). No regression was created then. On 2026-09-25 KN-3811 / 5.1.5 and 5.1.6 reproduced the same formatting class with required IDs (`dns-` / `filter`, `opkg-kmod-` / `netfilter`), and the old line-oriented matcher produced false missing-component evidence.

Permanent rules from that failure:

1. Normalize only the logical field whose continuation grammar is understood; never strip arbitrary newlines from an entire command dump.
2. Stop normalization at the next known field/block boundary.
3. Match identifiers exactly after normalization; related names such as `opkg-kmod-netfilter-addons` must not satisfy `opkg-kmod-netfilter`.
4. Treat unreadable/truncated/unconvincing observations as UNKNOWN/UNVERIFIED, not as proof of absence.
5. Read back critical persistent mutations from a fresh observation; command success alone is not proof that KeeneticOS applied the state.
6. When Installer and Doctor implement the same interpretation independently, regressions must execute both implementations.
7. Preserve real producer **shape** in small sanitized fixtures. Never publish private addresses, credentials, secrets or full private router configuration as fixtures.
8. For finite required IDs, generic formatting coverage is preferable to memorizing only previously observed split points. The component regression now tests every required component ID at every possible internal wrap position.
9. Green CI means all modeled shapes and known invariants passed; it does not mean every firmware/model presentation format has been proven.

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

The support matrix distinguishes **code/package support** from fresh hardware acceptance.

Current release devices with direct retained live evidence: **KN-1010, KN-1012, KN-3811, KN-3812, Netcraze Giga NC-1012 and the operator's home Netcraze Ultra NC-1812**. NC-1812 and Keenetic Titan KN-1812 are different market models built on the same MT7988D-class hardware platform; evidence from one must not be relabelled as a physical test of the other. Record the exact model/hw_id reported by the tested router.

| Architecture | Current evidence | Status |
|---|---|---|
| `aarch64` | KN-1012 / MT7981B Cortex-A53, KN-3811 / MT7981B Cortex-A53, KN-3812 / MT7981B Cortex-A53, Netcraze Giga NC-1012 / aarch64, NC-1812 / MT7988D-class; all five are current-release live-tested devices | current live evidence |
| `mipsel` | KN-1010 / MT7621AT MIPS 1004KEc; Keenetic's OPKG guide specifies the `mipsel` archive; live acceptance includes universal installer lifecycle and MIPS-stack migration findings | current live evidence |
| `armv7` | installer/updater package path is implemented and CI-covered structurally | supported path; no equally fresh live acceptance recorded |
| big-endian `mips` | installer/updater package path is implemented and CI-covered structurally | supported path; no equally fresh live acceptance recorded |

Official Keenetic references used for the mapping:

- KN-1010 Command Reference / OPKG: <https://docs.help.keenetic.com/cli/3.1/en/cli_manual_kn-1010_tr.pdf> · <https://support.keenetic.ru/eaeu/giga/kn-1010/ru/18482-installing-opkg-entware-in-the-router-s-internal-memory.html>
- KN-1012 Command Reference / OPKG: <https://storage.googleapis.com/docs.help.keenetic.com/cli/4.3/en/cli_manual_kn-1012.pdf> · <https://destek.keenetic.com.tr/hero/kn-1012/en/20980-installing-the-entware-repository-on-a-usb-drive.html>
- KN-3811 Command Reference: <https://storage.googleapis.com/docs.help.keenetic.com/cli/4.2/ru/cli_manual_kn-3811_ru.pdf>
- KN-3812 Command Reference / OPKG: <https://storage.googleapis.com/docs.help.keenetic.com/cli/5.0/en/cli_manual_kn-3812.pdf> · <https://support.keenetic.ru/eaeu/hopper-se/kn-3812/en/20980-installing-the-entware-repository-on-a-usb-drive.html>
- NC-1812 live-device reference: <https://netcraze.ru/ru/netcraze-ultra> — the tested device is recorded from its own CLI as NC-1812.
- KN-1812 architecture/reference sibling: <https://storage.googleapis.com/docs.help.keenetic.com/cli/4.3/en/cli_manual_kn-1812.pdf> · <https://support.keenetic.com/eu/titan/kn-1812/en/20980-installing-the-entware-repository-on-a-usb-drive.html> — useful for the shared MT7988D-class platform, but not counted as a separate physical run.

Earlier field use on KN-1810 and KN-1913 remains valid historical evidence. Historical model coverage is not presented as a substitute for the current per-architecture acceptance above.

Do not buy/find hardware or create synthetic emulation merely to make every matrix cell
green. When an `armv7` or big-endian `mips` router naturally becomes available, run
the same conservative install → Doctor → update/reboot acceptance and record the result.

### 2026-09-25 NC-1012 live parser acceptance

Netcraze Giga **NC-1012 / KeeneticOS 5.1.6 stable / aarch64** provided a fresh real-output parser check. Its `show version` physically split `dns-filter` as `dns-` / `filter` and also split the related `opkg-kmod-netfilter-addons` token across lines. The current Doctor reconstructed the logical `components:` field correctly and reported `proxy`, `dns-filter`, `opkg-kmod-netfilter`, `dns-tls`, `dns-https`, `ext` and `ext-utils` as present. The router used external EXT4 `/opt`, external storage-backed swap, and live `xt_multiport` plus the expected bypass MARK/CONNMARK/RETURN rules. The initial Doctor run finished with **35 OK / 1 WARN / 0 FAIL**; the only warning was the pre-migration legacy watchdog layout. The same router then completed watchdog migration to the canonical layout, moved Mihomo from runtime **1.19.30** to **1.19.31**, migrated `tun.stack` from **gvisor** to **mips** with controlled stop / `mihomo -t` validation / restart, and passed a post-maintenance Doctor run with **37 OK / 0 WARN / 0 FAIL** while retaining the live bypass rules and working Proxy0/DNS-interception path.

### 2026-09-25 KN-1012 GSM-role / internal-UBIFS live acceptance

A second dača **Keenetic Giga KN-1012 / KeeneticOS 5.1.6 stable / aarch64** provided a distinct storage/resource and GSM-role profile: internal UBIFS `/opt`, native zRAM-only swap, and USB/LTE modem components (`usblte`, `usbmodem`, `usbnet`, `usbqmi`). Its real `show version` again physically split `dns-filter` as `dns-` / `filter` and also split the unrelated `virtual-ip-server` token as `virtual-` / `ip-server`. Doctor reconstructed the required component set correctly and verified live `xt_multiport` plus the expected bypass rules. Initial Doctor result was **30 OK / 3 WARN / 0 FAIL**: a conservative current-binary staging estimate, DNS transit interception absent, and legacy watchdog layout. Investigation found a stale non-runtime `/opt/sbin/meta-backup/mihomo` copy; removing it increased free space from ~38 MB to ~56 MB. After enabling DNS interception and migrating the watchdog, `update-mihomo.sh` extracted the actual 1.19.31 candidate and measured only **17096 KB** of required same-filesystem staging, so the update completed successfully without violating one-Mihomo/rollback rules. The router then migrated `tun.stack` from **gvisor** to **mips**, installed WARPSCOUT 0.16.0 on the same internal UBIFS, retained ~60 MB free space, and passed the current Doctor with **33 OK / 0 WARN / 0 FAIL**. This field result is the reason Doctor staging output is now INFO-only estimate; only `update-mihomo.sh` can authoritatively gate space because it measures the extracted candidate.

## Next focused acceptance

The next useful work is evidence collection and integration acceptance, not a larger synthetic KeeneticOS emulator.

1. **NC-1812 first, read-only.** Capture `ndmc -c "show version"` and run the current Doctor. Verify that every visibly present required component survives parser normalization despite any physical wrapping, and that Doctor produces no false component-missing result. This device has priority because its 2026-09-19 output was the earliest retained warning that IDs can wrap inside a token.
2. **KN-3812, read-only shape capture.** Record a sanitized `components:` block plus Doctor summary on the current firmware. The dača 1012-class evidence now covers two distinct devices and must keep their identities separate: Netcraze Giga **NC-1012** with external EXT4 `/opt`, and Keenetic Giga **KN-1012** GSM with internal UBIFS `/opt`.
3. **KN-1010 and KN-3811 remain regression anchors.** KN-1010 anchors the reboot-dependent `opkg-kmod-netfilter` → `xt_multiport` → real bypass rules dependency. KN-3811 anchors wrapped `show version` component IDs before/after firmware.
4. **Per-device evidence record.** Store exact model/hw_id, firmware title/release, architecture, `/opt` class/filesystem, sanitized raw `components:` shape, normalized required-component result, Doctor summary, and whether any reboot-dependent capability was actually checked.
5. **Mutation tests only when justified.** Repeat-install/update/reboot tests belong on a non-critical acceptance device or a planned maintenance window. Do not toggle/remove components on a production router just to make the matrix look fuller.

### Remaining dača 1012 follow-ups after 2026-09-25

The two dača routers are healthy and accepted for the checks already performed, but the field campaign is not literally exhaustive.

- **Persistence/reboot:** one final controlled reboot on each router can verify recovery of Mihomo, Proxy0, DNS interception, bypass rules, watchdog, MagiTrickle and the intended swap backend after the latest maintenance.
- **NC-1012 Mihomo file provenance:** the external-EXT4 NC-1012 currently shows a canonical `/opt/sbin/mihomo` around **54.6 MB**, while the internal-UBIFS KN-1012 shows about **13 MB** with the same runtime version 1.19.31. Both are running correctly; treat this as a read-only packaging/provenance question, not evidence of corruption. If investigated, record hashes/file metadata/package source before changing anything.
- WARPSCOUT transport/colo experiments belong to `saymer-alt/link-generators`; they are not part of the core installer/Doctor acceptance contract here.

6. **Do not fabricate running-config wrap tests.** `show running-config` line boundaries are semantic. Add a fixture only when a real variant is observed, preserving the actual block shape and testing the real parser.
7. **Every new live failure becomes a lesson.** Record the observation, classify which boundary assumption failed, and add the smallest permanent regression if the failure can influence behavior.

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
