# Testing Strategy

## Reading guide

**Agents:** read the applicable section, its linked test(s) and required [Constitution](CONSTITUTION.md) rules; **do not load the entire historical testing record**. Dates and past release outcomes are evidence only, never today's release approval.

| Task | Read first |
| --- | --- |
| Safety invariants and stateful changes | [High-consequence invariants](#high-consequence-invariants), [test-budget rule](#test-budget-rule) |
| Router acceptance / permission and evidence limits | [Real-hardware testing](#real-hardware-testing), [MCP cross-validation](#mcp-cross-validation-as-an-independent-live-oracle) |
| BusyBox and external CLI assumptions | [BusyBox portability gate](#busybox--runtime-portability-gate), [external output parsing](#external-command-output-is-an-input-protocol) |
| Historical model matrix, Doctor/MCP comparisons and 2026 field follow-ups | [September 2026 field archive](archaeology/kas-testing-field-evidence-2026-09.md) — **on demand only** |
| Final release checks | [Release gate](#release-gate), [deliberately untested faults](#deliberately-untested-destructive-faults) |
| Network Doctor and read-only metrics | [Network Doctor / metrics regressions](#network-doctor-and-router-metrics-2026-11) |

## C2–C7 maintenance regressions

`python3 tests/maintenance-regression.py` runs production watchdog updater,
cron normalization, S00ubifs dispatcher, installer asset selector and updater
version decisions under dash and BusyBox ash. Kernel mounts, ownership and
downloads are controlled fixtures; file modes, bytes and renames are real.
Asset names/URLs were recorded from entware-go:latest on 2026-09-28; ambiguity,
wrong-package and missing-asset variants are derived fixtures. Coverage includes
permission/rename failures, foreign schedules, comments, duplicate routes,
idempotence, lock exclusion, partial mount setup and malformed/older versions.
The rollback suite adds full TUN migration INT/TERM/HUP cases around stop,
backup, commit and start, plus failed recovery with retained per-run backups.
No router, privileged mount or live-network acceptance is implied.

## B6/C1: process discovery and swap identity

Run `python3 tests/process-regression.py` and `python3 tests/swap-regression.py`.
Both require dash-compatible sh and BusyBox ash. Process tests use copied BusyBox
ELFs running the sleep applet, real `/proc/<pid>/exe`, deleted/replaced inodes,
restricted observation fixtures and extracted production stop/restore/Doctor
functions. Unknown cannot satisfy stop or start confirmation; a live daemon
prevents a second restore-start and Doctor ELF probe. The rollback suite also
runs MIPS/updater transactions with pidof masked and `/proc` observations supplied
by the existing recorded service fixture, retaining all B3/B4 assertions.

Swap tests run all three production scanners against the same inputs, plus the
installer policy. Block-device stat metadata and sysfs are fixtures; no swap is
created/enabled. They cover numeric zram devices, fake filenames, >2 GiB files,
128/256/512 MB classes, coexistence, escaped paths, deleted sources and conflicting
sysfs. These tests do not constitute hardware/live-network acceptance.
See [process and backend contracts (RU)](20-process-swap-detection.md).

## B5: partial transport regression

Run `python3 tests/download-regression.py` with Python 3, dash-compatible `sh`
and BusyBox. The extracted production installer downloader runs with real temp
files, validation and rename, plus recorded curl/wget stubs that write a valid
shell prefix and return non-zero. Fifteen cases per shell cover raw/API failure,
successful fallback and retry, invalid content, stale/no-output retries, cleanup,
and validation before same-directory commit. API fixtures exercise the existing
raw-media path and headers; there is no JSON/base64 decoding in this path.
This is transport fault injection, not hardware or live GitHub availability testing.

## B3/B4: rollback fault regression

Run `python3 tests/rollback-regression.py`. It runs the full MIPS migration and
the updater's production transaction from staging onward against real temporary
files, with recorded init/process/ELF stubs. Both dash and BusyBox ash exercise
historical A/current B/candidate C, failed commit, permissions, running/stopped
service, INT/TERM/HUP after commit/start, repeated recovery signals, rollback
copy/chmod/rename/state failures, stop failure, failed restored start and wrong
runtime identity. A separate real Linux process checks `/proc` inode identity.
The fixtures assert action ordering and absence of concurrent ELF probes;
they do not replace real Keenetic/Entware hardware acceptance.

## B1/B2: process-based lifecycle regression

Run `python3 tests/lifecycle-regression.py` with host `sh` and BusyBox installed.
The same production helper blocks are exercised with real file/stdin processes,
PID/starttime identity, stale recovery, signal cleanup and deterministic barriers.
Init/ELF calls are recorded stubs; the full watchdog also runs with failed WAN
transports. This complements structural assertions, not hardware acceptance.
See the [protocol and failure boundaries (RU)](19-lifecycle-lock.md).

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
   Treat the router runtime as BusyBox/Entware, not as the Linux CI host: a command or option existing on
   Ubuntu is not proof it exists on Keenetic. Prefer already field-proven primitives; any new runtime
   dependency/option needs target evidence or a guarded fallback.
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

## MCP cross-validation as an independent live oracle

When Keenetic MCP access is available, use it as a **second read-only observation path** for Doctor acceptance. It is not a Doctor runtime dependency and must never become required for normal users; it is a fleet/test oracle that helps catch parser or interpretation drift.

| Fact | MCP source | Doctor source | Interpretation |
|---|---|---|---|
| exact model / firmware | device metadata / live router | `show version` | should agree exactly |
| installed KeeneticOS component IDs | `list_installed_components` (normalized from `show version`) | Doctor's independent `show version` parser | excellent parser cross-check, especially wrapped IDs |
| nominal physical RAM | `show system memtotal` | `/proc/meminfo MemTotal` | values can differ because Linux excludes reserved memory; Doctor's Linux value remains authoritative for project resource gates |
| total active swap | `show system swaptotal/swapfree` | `/proc/swaps` + `/proc/meminfo` | totals should approximately agree |
| swap backend type | not exposed by current MCP tools | `/proc/swaps` plus mount topology | Doctor is authoritative for zRAM vs storage-backed classification |
| DNS transit interception | redacted live running-config | live `show running-config` | should agree |
| ProxyN live state | live interface state | `show interface ProxyN` / project markers | should agree |
| physical USB media | `show usb` | indirect via `/proc/mounts`/storage checks | MCP enriches physical-device context; Doctor remains authoritative for actual `/opt` filesystem/class |
| live Netfilter rules / xt_multiport | component presence only | `lsmod` + `iptables` runtime rules | Doctor is stronger; a component ID alone is not runtime proof |
| Mihomo runtime binary/version/opkg metadata | not exposed by current Keenetic MCP tools | `/proc/PID/exe`, Controller `/version`, Entware `opkg list-installed` | Doctor is authoritative |

### 2026-09-25 MCP ↔ Doctor comparison

The September 2026 per-device table, component-wrap observations and historical Doctor counts moved intact to the [dated field-evidence archive](archaeology/kas-testing-field-evidence-2026-09.md#2026-09-25-mcp--doctor-comparison).

**Active interpretation remains:** MCP is a second, read-only test oracle, not an installer/Doctor dependency or permission to downgrade its checks. Total swap does **not** identify its backend; an installed Netfilter package does **not** prove live iptables MARK/CONNMARK/RETURN rules. Recheck exact device/firmware before any present-tense claim.

## BusyBox / runtime portability gate

The project deliberately does not build a full KeeneticOS emulator. That makes portability review a
first-class release gate rather than an assumption hidden inside normal Linux CI.

- CI under BusyBox ash validates shell dialect, but external commands can still resolve to host GNU
  tools. Passing CI therefore does not prove a GNU option exists on the router.
- Before adding a new runtime command/flag, check whether the project already has a field-proven way to
  obtain the same fact. Prefer `/proc`, `/sys`, shell builtins and basic BusyBox-compatible text tools.
- Known negative evidence is permanent: Keenetic BusyBox 1.37 lacks GNU `stat -c`; some field devices
  also lack helpers such as `ss`, `ndmq` or `timeout`, and `pidof` is not a universal safety primitive.
  Optional helpers must be detected explicitly and cannot be used as proof when absent.
- Temporary/staging names are part of concurrency safety. Use real `$$` or an established
  lifecycle-owned adjacent stage; a syntactically valid literal `$` suffix is unsafe because separate
  runs collide.
- Every real portability failure should produce the smallest durable sentinel/regression that can catch
  that exact bad assumption without pretending to emulate all of KeeneticOS.
## Current hardware evidence

**Scope note:** this heading is retained for existing links; the old “current” fleet matrix is a **September 2026 snapshot**, not an up-to-date device inventory or evidence of new releases. The historical support/architecture matrix, all per-router Doctor acceptance transcripts and platform citations are preserved in the [September 2026 field archive](archaeology/kas-testing-field-evidence-2026-09.md#current-hardware-evidence).

**Active evidence policy:** distinguish **implemented/CI-tested architecture** from **hardware-accepted model**, record the exact model/hw_id, KeeneticOS version, architecture, `/opt` class/filesystem, sanitized component output, Doctor verdict and whether reboot-dependent capabilities were actually tested. Do not transfer NC-1812 evidence to KN-1812, or AP evidence to full-gateway operation. Do not fabricate `show running-config` wrap fixtures: preserve real line boundaries from observed cases and cover them with focused tests. An observed field failure should get the smallest durable regression possible.

Do not purchase hardware, build a full emulator, toggle a production router's components, or run disruptive install/update/reboot/power-loss tests simply to fill a historical matrix. A fresh live acceptance requires a relevant task, safe maintenance window and explicit operator permission. See [Real-hardware testing](#real-hardware-testing), [Release gate](#release-gate) and the binding [Constitution](CONSTITUTION.md).

## Next optional evidence

Historical optional follow-ups from September 2026 — including KN-3812 refresh and dača KN-1012 reboot questions — are archived [here](archaeology/kas-testing-field-evidence-2026-09.md#next-optional-evidence). They are **not automatic current tasks or release blockers**; determine current scope from the active issue, approved plan and exact device evidence.

### Remaining dača 1012 follow-ups after 2026-09-25

[Archived notes](archaeology/kas-testing-field-evidence-2026-09.md#remaining-dača-1012-follow-ups-after-2026-09-25) are historical observations and cannot justify unapproved device mutation.

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


## v1.8.2 / KAS-SAFETY-001 release acceptance

Current resource-profile contract is `20261012_1`; the historical [512 MB field rationale](archaeology/kas-testing-field-evidence-2026-09.md#2026-09-27-512-mb-class-memory-pressure-fleet-snapshot) remains supporting evidence, not today's hardware acceptance. RAM thresholds are unchanged. Dual native zRAM + external SWAP is always Installer ERROR / Doctor FAIL / Updater ERROR, including >512 MB and both RAM/DISK modes.

`tests/swap-regression.py` executes production scanners and policy under dash and BusyBox ash: 51 scanner cases, 9 installer profile cases and 72 constitutional policy cases per shell (264 total). The constitutional matrix covers 128/256/512/1024 MB, RAM/DISK and dual/zRAM-only/external-only. The 128 MB zRAM-only installer remains rejected by the independent external-swap prerequisite. Installer uses its complete entry prefix through resource preflight; Updater uses its entire resource preflight; Doctor uses its scanner and production FAIL dispatch. Reaching the next phase after a forbidden Installer/Updater profile fails the test. Existing identity fixtures include misleading zram filenames, unknown devices, conflicting/unreadable sysfs and deleted sources. CI also runs transaction/lifecycle/rollback regressions and contract guards.

These are synthetic Linux kernel-observation fixtures, not a router emulator. Physical v1.8.2 acceptance on KN-1010, reboot and power-loss behaviour are NOT TESTED in this release audit. No live router experiment is authorized by the automated fixture suite.

## Network Doctor and router metrics (2026-11)

`tests/network-doctor-regression.py` runs `kas-network-doctor.sh` against mock curl/nslookup/ndmc/netstat/jq/pgrep binaries injected via PATH (per-test plan files); no sockets open, no bytes are executed. Cases cover DNS NXDOMAIN/SERVFAIL/REFUSED/timeout, TCP refused/reset/timeout, TLS 35/60/56/28, HTTP 200/403/500/redirect including a captive-portal redirect, resolver disagreement, missing curl (inconclusive verdict), unreachable/authorized Controller, disabled egress observation, positive Mihomo/ProxyN/MagiTrickle evidence, exact request budget counts, PATH isolation, JSON contract validity on happy and failure paths, and a secret-non-disclosure assertion (the controller secret never appears in stdout, stderr, the human report or the JSON). `tests/sys-metrics-regression.py` runs `kas-sys-metrics.sh` against fixture sysfs/procfs trees through the documented injection roots: normal/hwmon/multi-zone temperature fixtures, implausible/negative/textual/unreadable values (UNKNOWN, never clamped), malformed loadavg/uptime, absent swap (N/A), all-UNKNOWN exit 1, JSON field-level checks and the absence of FAIL/WARN-style verdicts. Both suites execute under dash-compatible sh and BusyBox ash. This is MOCK evidence only: QEMU was not run for this change and no physical device has been tested; field acceptance requires a separate owner GO.
