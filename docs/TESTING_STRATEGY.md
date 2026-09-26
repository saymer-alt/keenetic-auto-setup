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

| Profile | MCP nominal RAM | MCP swap total | MCP DNS intercept | MCP required components | Doctor evidence |
|---|---:|---:|---|---|---|
| dača NC-1012 external EXT4 | 512 MiB | 1,047,548 KB (~1023 MiB) | enabled | required set + `ext`/`ext-utils` present | post-maintenance **37 OK / 0 WARN / 0 FAIL**; external storage-backed swap |
| home NC-1812 external EXT4 | 1024 MiB | 1,047,548 KB (~1023 MiB) | enabled | required set + `ext`/`ext-utils` present | **36 OK / 0 WARN / 0 FAIL**; raw per-line resource numbers were not retained in the summary |
| work KN-1012 SE external EXT4 | 512 MiB | 1,047,548 KB (~1023 MiB) | enabled | required set + `ext`/`ext-utils` present | Linux RAM ~486 MB, external storage-backed swap ~1022 MB, **38 OK / 0 WARN / 0 FAIL** |
| dača KN-1012 GSM internal UBIFS | 512 MiB | 524,284 KB (~512 MiB) | enabled | required set present; `ext`/`ext-utils` absent as expected for internal `/opt` | Linux RAM ~486 MB, zRAM ~511 MB, **33 OK / 0 WARN / 0 FAIL** |
| KN-3811 "126 security" internal storage | 512 MiB | 524,284 KB (~512 MiB) | enabled | required component IDs present; `ext-utils` absent and not required for internal `/opt` | earlier old-parser run falsely reported component FAILs; Linux runtime showed zRAM ~511 MB and healthy Netfilter rules |

Current MCP and Doctor observations agree on the facts they both expose. The major historical disagreement on KN-3811 was the already-fixed Doctor line-oriented `show version` parser, not a real router-state mismatch. A fresh current Doctor run on KN-3811 remains a useful live closure check after the parser fix, but the MCP component list already independently confirms that the required IDs are present.

MCP must not be used to weaken Doctor checks. In particular, `show system swaptotal` does not tell whether swap is zRAM or storage-backed, and an installed `opkg-kmod-netfilter` ID does not prove that `xt_multiport` and the project MARK/CONNMARK/RETURN rules are actually loaded.
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

### 2026-09-25 NC-1812 home / external-HDD live acceptance

The operator's home **Netcraze Ultra NC-1812 / KeeneticOS 5.1.6 / aarch64** is now a
completed live acceptance point rather than a pending re-check. The retained Doctor run finished
with **36 OK / 0 WARN / 0 FAIL**: required components were present, external EXT4 `/opt`
was accepted, runtime Mihomo/watchdog were healthy, and DNS interception, the project ProxyN
path and live `bypass_wa` checks passed.

Same-evening MCP inventory preserves the operating context without publishing private
configuration: the router is a live mesh controller, its primary/default Internet path is
**2KOM** over a 1 Gbit/s Ethernet WAN, `Proxy0` is up through that WAN, and OPKG is bound
to an external USB storage volume. MCP identifies the attached media as a **Seagate Slim**
USB 3.0 disk; the operator identifies it as a repurposed **2.5-inch 500 GB laptop HDD**.
An MCN Telecom L860-GL-16 LTE interface is also present as a non-default secondary path.

Current MCP component inventory also confirms `proxy`, `dns-filter`, `opkg-kmod-netfilter`, both secure-DNS components, and the external-storage pair `ext` + `ext-utils` as installed. This router is also one of the operator-confirmed devices where MetaCubeXD/Mihomo
Web-UI core self-upgrade is used successfully on external EXT4 storage. The exact binary
size from the 2026-09-25 Doctor transcript was not retained in the current evidence summary,
so do not invent one; the important retained facts are the healthy **36/0/0** acceptance,
external-HDD profile and the operator-confirmed out-of-band core-update path.

### 2026-09-25 KN-1012 SE / external-flash live acceptance

The work **Keenetic Giga KN-1012 "SE" / KeeneticOS 5.1.5 / aarch64** supplies a second,
independent external-EXT4 512 MB-class profile. Same-evening MCP inventory identifies a
**Silicon Power 16 GB** USB flash device used for OPKG/Entware, a live mesh-controller role,
a 100 Mbit/s primary Ethernet WAN (`Sots_Cisco_eth`), and a healthy project `Proxy0`
bound through that WAN.

The retained live Doctor run finished with **38 OK / 0 WARN / 0 FAIL**. It recorded
external EXT4 `/opt`, about **486 MB RAM**, about **1022 MB** active storage-backed swap,
Mihomo runtime **1.19.31**, MagiTrickle **0.8.1-1**, and `tun.stack: mips` on `mitun0`.

Current MCP component inventory independently confirms the required runtime IDs (`proxy`, `dns-filter`, `opkg-kmod-netfilter`, DoT/DoH) plus `ext` and `ext-utils` for the external EXT4 profile.

This device provides especially useful update-path evidence: Doctor resolved the running
Mihomo binary at **55,937 KB** and runtime **1.19.31**, while the opkg database still carried
stale Mihomo metadata **1.19.28-1**. The operator confirms that this router, like the external
NC-1012 and home NC-1812, updates Mihomo core through the MetaCubeXD/Web-UI self-upgrade
path. The runtime/package-version mismatch plus the ~55 MB binary is therefore expected
out-of-band state, not package corruption.

### 2026-09-25 KN-3811 "126 security" wrapped-components acceptance

The work **Keenetic Hopper KN-3811 "126 security"** is the contrasting internal-storage
profile. Before the firmware update, on **KeeneticOS 5.1.5**, real `show version` output
physically wrapped required IDs such as `dns-` / `filter` and
`opkg-kmod-` / `netfilter`. The old line-oriented Doctor parser therefore reported
a misleading **30 OK / 2 WARN / 2 FAIL**, even though the components were actually present.

Runtime evidence at the same time showed Mihomo **1.19.31** with a roughly **13,000 KB**
binary, internal UBIFS `/opt` with about **62 MB free**, native zRAM about **511 MB**,
`tun.stack: mips`, loaded `xt_multiport`, and real
`_CUST_BYPASS_WA_` UDP multiport MARK/CONNMARK/RETURN rules. Watchdog history showed
four recorded restarts in total, two within the prior 24 hours; that history was evidence
to inspect, not proof of a current Mihomo outage.

After the router moved to **KeeneticOS 5.1.6**, the required components and runtime path
remained healthy and the same wrapped presentation class remained observable. Same-evening
MCP now confirms 5.1.6, **no USB storage**, `opkg disk storage:/` (internal storage),
a 1 Gbit/s Ethernet WAN (`Sotsenergo 126 Eth`), and a live project `Proxy0`.
Current MCP component inventory confirms `proxy`, `dns-filter`, `opkg-kmod-netfilter`, `dns-tls` and `dns-https` as installed on the 5.1.6 router. `ext` is present, while `ext-utils` is not in the slim installed list; because this profile uses internal `storage:/`, the project does not require the external-storage `ext` + `ext-utils` pair here. This device is the real-hardware reason the project now normalizes only the understood
`components:` field before exact matching; it remains a regression anchor for both
wrapped component IDs and live Netfilter bypass rules.

### 2026-09-25 NC-1012 live parser acceptance

Netcraze Giga **NC-1012 / KeeneticOS 5.1.6 stable / aarch64** provided a fresh real-output parser check. This is the dača wired router: live MCP inventory shows its Internet path as **Mynetcity PPPoE** over a 1 Gbit/s Ethernet link (PPPoE MTU 1492), while Entware lives on the operator-confirmed **USB/NVMe 32 GB** external storage mounted as EXT4 `/opt`. The router is also serving as a live mesh controller, so the acceptance was performed on a real production-role device rather than an isolated lab unit. Its `show version` physically split `dns-filter` as `dns-` / `filter` and also split the related `opkg-kmod-netfilter-addons` token across lines. The current Doctor reconstructed the logical `components:` field correctly and reported `proxy`, `dns-filter`, `opkg-kmod-netfilter`, `dns-tls`, `dns-https`, `ext` and `ext-utils` as present. The router used external EXT4 `/opt`, external storage-backed swap, and live `xt_multiport` plus the expected bypass MARK/CONNMARK/RETURN rules. The initial Doctor run finished with **35 OK / 1 WARN / 0 FAIL**; the only warning was the pre-migration legacy watchdog layout. The same router then completed watchdog migration to the canonical layout, moved Mihomo from runtime **1.19.30** to **1.19.31**, migrated `tun.stack` from **gvisor** to **mips** with controlled stop / `mihomo -t` validation / restart, and passed a post-maintenance Doctor run with **37 OK / 0 WARN / 0 FAIL** while retaining the live bypass rules and working Proxy0/DNS-interception path.

### 2026-09-25 NC-1012 transactional binary-state live acceptance

The dača **Netcraze Giga NC-1012 / KeeneticOS 5.1.6 / external EXT4 `/opt`** also completed the first real-hardware acceptance of the project-owned Mihomo binary-state transaction.

Before the test, the running core was the operator-confirmed Web-UI/self-upgraded upstream-form **Mihomo 1.19.31** at about **54.6 MB**, `opkg list-installed` still reported **1.19.27-1**, and `/opt/etc/keenetic-auto-setup-mihomo.state` did not yet exist. The production updater was then run with `--force` because `entware-go:latest` also contained 1.19.31. It deliberately performed a same-version replacement: downloaded `mihomo_1.19.31-2_aarch64-3.10.ipk`, measured about **17,096 KB** same-filesystem staging need, stopped the old daemon under the one-Mihomo rule, validated the candidate and live config, atomically committed the new binary, wrote project binary state, restarted Mihomo, and verified the process.

After the transaction, the canonical runtime remained **1.19.31** but the binary was the project packaged/UPX form at about **12.7 MB / 13,311,564 bytes**. The state file recorded `runtime_version=1.19.31`, `source=entware-go-binary-updater`, asset `mihomo_1.19.31-2_aarch64-3.10.ipk`, package release `2`, and the pre-existing opkg metadata `1.19.27-1`. The Entware opkg database intentionally remained unchanged.

Doctor v1.2.8 then resolved runtime **1.19.31** through the Controller, reported the stale opkg version as expected INFO, verified that project binary state matched runtime, and completed with **37 OK / 0 WARN / 0 FAIL**. Proxy0, DNS interception, live `bypass_wa` Netfilter rules, watchdog, MagiTrickle, `tun.stack: mips`, external storage-backed swap and configured ports remained healthy. This closes the real-hardware release gate for the new binary-state provenance path; a later reboot remains useful persistence evidence but is not required to prove the update transaction itself.
### 2026-09-26 external NC-1812 legacy/internal-UBIFS Doctor re-check

A separate, **user-owned Netcraze Ultra NC-1812** (not the operator's home NC-1812)
provides a valuable legacy-profile validation point. It remains on **KeeneticOS 5.1.5 /
5.01.C.5.0-0 / aarch64**, uses **internal UBIFS `/opt`** (about 98 MB total, about
40 MB free), has about **991 MB Linux-visible RAM**, and has no swap; swap remains optional
for this above-512 MB memory class.

An earlier Doctor run on this same router reported **25 OK / 3 WARN / 2 FAIL**. The two
FAIL findings were false missing-component results for `dns-filter` and
`opkg-kmod-netfilter`, caused by the old line-oriented interpretation of wrapped
`show version` output. The current stable Doctor **v1.2.9** now reconstructs the logical
component field correctly, reports both required components present, verifies the executable
`bypass_wa` hook plus live PREROUTING/UDP multiport MARK/CONNMARK/RETURN rules, and finishes
with **29 OK / 2 WARN / 0 FAIL / 53 INFO**. This is external field validation that the
wrapped-component fix removed a real false-FAIL class rather than merely fitting the
operator's own routers.

The same rerun also validates the revised update-space model. The router currently runs
Mihomo **1.19.29** from a roughly **43,201 KB** upstream-form binary with about **40 MB**
free on `/opt`; opkg metadata still says **1.19.27-1**, no project binary-state file exists,
and `entware-go:latest` offers **1.19.31-2**. The old Doctor converted
`current binary + 4096 KB` into a WARN because that estimate was about 46 MB. The current
Doctor correctly reports the number as **INFO only**: current-binary size does not determine
candidate size. On another live aarch64 NC-1012, the same project package generation produced
a **13,311,564-byte (~12.7 MB)** packaged binary and the updater measured about **17,096 KB**
of same-filesystem staging need. That evidence explains why the old 46 MB heuristic was
misleading, but it is **not** a promise that this external router has already passed an
update: `update-mihomo.sh` must still extract and measure the actual candidate on the target
before it is authoritative.

The remaining two WARN findings are genuine configuration/maintenance debt rather than
parser artifacts: Keenetic DNS transit interception is not enabled, and the router still uses
the legacy watchdog layout. The legacy watchdog is nevertheless functioning: the retained
history contained **40 healthy heartbeats**, **no restart/problem interventions**, and
**220 full-WAN-outage runs** where the watchdog deliberately did not restart Mihomo. Proxy0,
MagiTrickle 0.8.2-1, port 7890, Controller proxy selection and the live bypass path were
healthy in the same read-only run.

Because this router is not operator-owned, update, watchdog migration, DNS-interception
changes or any other mutation require the owner's explicit permission. The read-only Doctor
result alone is sufficient to preserve the parser/staging lessons above.

### 2026-09-25 KN-1012 GSM-role / internal-UBIFS live acceptance

A second dača **Keenetic Giga KN-1012 / KeeneticOS 5.1.6 stable / aarch64** provided a distinct storage/resource and GSM-role profile: internal UBIFS `/opt`, native zRAM-only swap, and USB/LTE modem components (`usblte`, `usbmodem`, `usbnet`, `usbqmi`). Live MCP inventory from the same evening shows two active cellular uplinks: primary/default `UsbLte0` is **MCN Telecom / T2** on a **Fibocom FM350-GL** with APN `modem.tele2.ru`; `UsbLte1` is **Megafon** on an **L860-GL-16** with APN `router.megafon.ru`, connected as the secondary path. The running configuration also carries a multipathing policy containing both LTE interfaces. A post-test radio snapshot showed the main FM350-GL in 4G+ with B3+B3+B7 aggregation (roughly RSRP -95 / RSRQ -8 / RSSI -70 dBm) while the secondary L860-GL-16 was on B3 with a weaker RSRP around -113 dBm. These radio values are dynamic context, not exact per-scan fixtures. Its real `show version` again physically split `dns-filter` as `dns-` / `filter` and also split the unrelated `virtual-ip-server` token as `virtual-` / `ip-server`. Doctor reconstructed the required component set correctly and verified live `xt_multiport` plus the expected bypass rules. Initial Doctor result was **30 OK / 3 WARN / 0 FAIL**: a conservative current-binary staging estimate, DNS transit interception absent, and legacy watchdog layout. Investigation found a stale non-runtime `/opt/sbin/meta-backup/mihomo` copy; removing it increased free space from ~38 MB to ~56 MB. After enabling DNS interception and migrating the watchdog, `update-mihomo.sh` extracted the actual 1.19.31 candidate and measured only **17096 KB** of required same-filesystem staging, so the update completed successfully without violating one-Mihomo/rollback rules. The router then migrated `tun.stack` from **gvisor** to **mips**, installed WARPSCOUT 0.16.0 on the same internal UBIFS, retained ~60 MB free space, and passed the current Doctor with **33 OK / 0 WARN / 0 FAIL**. This field result is the reason Doctor staging output is now INFO-only estimate; only `update-mihomo.sh` can authoritatively gate space because it measures the extracted candidate.

## Next focused acceptance

The next useful work is evidence collection and integration acceptance, not a larger synthetic KeeneticOS emulator.

1. **KN-3812, read-only shape capture.** Record a sanitized `components:` block plus Doctor summary on the current firmware. NC-1812 has now completed its 2026-09-25 read-only Doctor re-check with **36 OK / 0 WARN / 0 FAIL**.
2. **KN-1010 and KN-3811 remain regression anchors.** KN-1010 anchors the reboot-dependent `opkg-kmod-netfilter` → `xt_multiport` → real bypass rules dependency. KN-3811 anchors wrapped `show version` component IDs before/after firmware; its current 5.1.6/internal-storage shape is now preserved as live evidence.
3. **Keep KN-1012 profiles distinct.** The accepted family now includes at least three materially different 1012-class operating profiles: dača NC-1012 external EXT4/NVMe, work KN-1012 SE external EXT4/USB flash, and dača KN-1012 GSM internal UBIFS/zRAM.
4. **Per-device evidence record.** Store exact model/hw_id, firmware title/release, architecture, `/opt` class/filesystem, sanitized raw `components:` shape, normalized required-component result, Doctor summary, and whether any reboot-dependent capability was actually checked.
5. **Mutation tests only when justified.** Repeat-install/update/reboot tests belong on a non-critical acceptance device or a planned maintenance window. Do not toggle/remove components on a production router just to make the matrix look fuller.

### Remaining dača 1012 follow-ups after 2026-09-25

The two dača routers are healthy and accepted for the checks already performed, but the field campaign is not literally exhaustive.

- **Persistence/reboot:** the NC-1012 binary-state transaction itself is now live-accepted (**37 OK / 0 WARN / 0 FAIL** after forced 55 MB upstream-form → 12.7 MB packaged same-version replacement). One final controlled reboot on each dača router remains useful persistence evidence for Mihomo, project binary state, Proxy0, DNS interception, bypass rules, watchdog, MagiTrickle and the intended swap backend, but it is no longer a release blocker for the state transaction.
- **Two Mihomo update paths explain the binary-size difference.** The external-EXT4 NC-1012 currently shows a canonical `/opt/sbin/mihomo` around **54.6 MB** because that router's core was updated from the Web UI/version control path, which invokes Mihomo's own core-upgrade mechanism and installs the upstream release form. The internal-UBIFS KN-1012 GSM was updated with this project's `update-mihomo.sh`, which consumes the `saymer-alt/entware-go` package; that build recipe explicitly packs Mihomo with `upx -9 --lzma`, producing the much smaller ~**13 MB** canonical binary. Both run runtime version 1.19.31 correctly. Do not treat the size difference as corruption. Operator field history now confirms the Web-UI core update path on VPS hosts and on **three** external-EXT4 routers: dača NC-1012, home NC-1812, and work KN-1012 SE. The SE Doctor evidence is especially strong because runtime 1.19.31 / 55,937 KB coexisted with stale opkg metadata 1.19.28-1. Whether free-space availability itself controls UI eligibility was not isolated and should not be stated as a proven rule.
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
