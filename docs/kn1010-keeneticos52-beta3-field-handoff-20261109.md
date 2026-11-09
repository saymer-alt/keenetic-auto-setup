# FIELD KN-1010 / KeeneticOS 5.2 Beta 3 — KAS handoff (2026-11-09)

> **Evidence state:** **HARDWARE INSTALL & RUNTIME PASS**, **CLIENT E2E / REBOOT NOT TESTED**.
> This is an evidence/handoff document, **not** a claim of complete end-to-end acceptance or permission to merge, deploy, modify a router or publish a release.
> Sensitive YAML, subscription endpoints, secrets, serials, device identifiers and private network inventory are intentionally omitted.

## Environment

- **Hardware:** Keenetic Giga KN-1010, MIPS, Entware `mipsel-3.4` / `mipsel-3.4_kn`.
- **Firmware:** KeeneticOS **5.2 Beta 3**, technical release `5.02.B.3.0-2` (confirmed by Doctor and read-only Keenetic MCP).
- **Install:** KAS Core **v1.8.8** via the experimental universal launcher, KAS Web **v0.1.0.beta.8-1** (`mipsel-3.4`; source SHA `94eec963...`), first fetch attempt transiently failed; subsequent idempotent run ended `[KAS] Done`.
- **Entware:** `/opt` external `/dev/sda2`, ext4; **14,118 MB free of 14,190 MB** in Doctor observation. Physical RAM class 256 MB (Doctor: 248 MB usable); external storage-backed swap **468 MB**, zRAM off. No memory exhaustion observed.
- **Reference:** installer FIELD #480, transport failure and retry evidence #483. Doc and observations reflect the installed Web beta.8 and must not be mistaken for source in subsequent commits.

## What was confirmed on real hardware

| Area | Direct field evidence | State |
| --- | --- | --- |
| Core installation | Repeat `all` completed; install preflight, retained Mihomo, YAML backup/import, final post-check | INSTALL FIELD PASS (#480) |
| Web | KAS Web beta.8 opens, Overview/Diagnostics render; Web package verified by published SHA256 during install | WEB SMOKE PASS |
| Mihomo | Runtime Controller version **1.19.33**, one process, configured mixed-port `7890` listening; `Proxy0` canonical `mihomo t2s0` | RUNTIME PASS |
| MagiTrickle | OPKG **0.8.2-1**, one `magitrickled` process, PID file consistent, DNS proxy `3553` listening; two port-53 NAT redirects | RUNTIME/LISTENER PASS |
| Routing plumbing | `bypass_wa` policy, hook, Netfilter PREROUTING/mangle rules and `Proxy0` detected | CONFIG/READ-ONLY PASS |
| Watchdog | Canonical script, cron wrapper and schedule exist; healthy log and heartbeat evidence detailed below | HEALTHY CHECK PASS |
| Doctor | Web's embedded Doctor **1.2.19**: **35 OK / 1 WARN / 0 FAIL** at `2026-11-09T13:23:53Z` (16:23 Moscow time) | SNAPSHOT WARN, explained below |
| Network | Doctor resolved `github.com`, reached GitHub API and KAS delivery endpoints | ROUTER PROBES PASS; client routes not proven |
| System snapshot | KAS Web: loadavg **1.49 / 0.73 / 0.51** (not CPU %), uptime **1 d 3 h**, available RAM **64.7 / 248.5 MiB**, free swap **467.0 / 468.7 MiB** | OBSERVED |

### Watchdog warning was an early-snapshot artifact, not a demonstrated runtime failure

- Doctor at **16:23 MSK** reported `Watchdog log is empty`; wrapper and schedule were already detected.
- Later SSH read-only evidence: `/opt/var/log/mihomo_watchdog.log` contains **`2026-11-09 16:25:03 [OK] All good | WAN=primary (http://cp.cloudflare.com)`**.
- `/tmp/mihomo_watchdog.healthy` last modified **16:40 MSK**, consistent with continuing healthy cycles. This file does **not** by itself prove which scheduler or operator invoked the script.
- Current watchdog deliberately runs healthy checks every 5 min and throttles routine `[OK]` logging to approximately **20 min**; one healthy log line does **not** mean only one run.
- **Open question:** `ps | grep '[c]rond'` printed no process at the observed moment, whereas `/opt/etc/crontab` contained `*/5 * * * * root /opt/bin/run-parts /opt/etc/cron.5mins`. Do **not** infer `crond` is definitely absent, running or broken from that grep alone. For follow-up, read-only inspect `ps`, `cron|crond`, service status, history over multiple intervals and actual run provenance; **do not** restart cron just to dismiss a warning.
- Re-running Doctor after a healthy log should resolve that *specific* empty-log warning, without proving absence of every other warning.

## Three Web beta.8 observations — #484

1. **KeeneticOS reports UNKNOWN despite Doctor evidence.** Doctor prints `[INFO] KeeneticOS: 5.2 Beta 3`, but `web/control-center/web/doctor-report.js` matches `/^KeeneticOS: ([0-9][A-Za-z0-9.+~-]{0,63})$/`: **space** in `5.2 Beta 3` is rejected. Update a strictly bounded/sanitized parser + unit regression in RU/EN; this is **not** proof that 5.2 is unsupported.
2. **Wrong initial-state MT label.** Under «Обновления MagiTrickle», initial text says «Обновления Mihomo ещё не проверялись». In `web/control-center/web/app.js::drawMTUpdates()` the initial state uses the Mihomo key `t('updateNone')`. Use a distinct `mtNone` in both RU/EN and cover transitions.
3. **Embedded Doctor differs from installed Core.** Web beta.8 runs bundled Doctor **1.2.19**; Core v1.8.8 repository Doctor is **1.2.22**. `web/control-center/main.go` embeds a generated snapshot of `mihomo-doctor.sh` with `//go:generate` / `//go:embed`. Sync and verify the bundled version in a *future* Web candidate; installing Core does not automatically replace the Web-embedded script.

No user config change is required to explain these issues. The Web «kas-core package not installed» state is normal for script-based Core installs; an installed watchdog SHA matching the Web snapshot establishes identity, **not** a cron-execution guarantee.

## Temperature finding — #485

- In KAS Web, `CPU/SoC temperature: Unable to determine` is **expected** with current `kas-sys-metrics.sh` because it reads only identifiable `/sys/class/thermal` or `/sys/class/hwmon` CPU/SoC sensors.
- Read-only official Keenetic MCP `show interface WifiMaster0` returned `temperature: 45` for 2.4 GHz; `show interface WifiMaster1` also returned `temperature: 45` for 5 GHz.
- These are **Wi-Fi radio-interface readings in °C**, **not established CPU temperature**, and equal values do not establish two independent sensors. `show system cpustat` reports CPU usage, not CPU temperature. A universal native CPU-temperature command has **not** been found/validated.
- Proposed read-only `ndmc -c 'show interface WifiMasterN'` fallback on supported KeeneticOS, once per user request, bounded parsing/timeout and fixed commands, with a **separate Wi-Fi temperature card** and explicit sensor provenance/UNKNOWN handling. **First verify real output syntax through Entware SSH**; the MCP JSON does not guarantee the `ndmc -c` text format. No CPU substitution or new package/daemon. See #485; pre-existing sysfs scope #309.

## Installation and network-download findings from today's other KAS field testing

- **KN-1010 (#483):** first attempt to download official MagiTrickle `add_repo.sh` failed intermittently due to resolver/transport behavior; subsequent read-only IPv4 HTTPS request succeeded with valid TLS and **HTTP 200**; a non-`-4` request initially failed DNS but later fetched the same **6,522-byte** helper successfully. **HTTPS is supported; do not downgrade to HTTP, use `-k`, or run unverified remote shell.** The repeat installation succeeded.
- **KN-3811 / internal UBIFS (#478), a DIFFERENT router:** project UPX Mihomo ~12.7 MiB was not downloaded; last fallback installed Entware package whose **extracted ELF** is ~55 MiB. **55 MiB is not the downloaded IPK size**; `opkg install mihomo` itself downloads a compressed IPK. Project asset API fallback and explicit interactive TTY download progress/retry messages are tracked by #478 / Draft PR #479.
- The GitLab **source Git mirror** alone does not contain release Mihomo IPKs; a verified release mirror is separate #481. Keep existing source/asset hash and ABI gates, bounded retries, and last-resort OPKG fallback. Do not silently use unverifiable mirrors or uncompressed upstream binary.
- These are two distinct observations: **KN-1010 MT intermittent DNS** and **KN-3811 compact Mihomo asset delivery/flash footprint**. Do not merge them into a single root-cause claim.

## What is NOT tested, and decision gates

- **NOT_TESTED:** real client egress through selected Mihomo policy, per-client DNS interception and leak behavior, MagiTrickle end-to-end DNS resolution on custom port, after-reboot service/watchdog/Web persistence, Web write/update workflows, and 3 other ABI installs through the universal launcher.
- Native QEMU/shell/node CI PASS does not replace real device evidence. Some Web discrepancies are display defects, not KAS core failures.
- **Recommended next tasks:** Web #484 (bounded parser, MT label, bundled Doctor freshness); metrics #485 (radio source research + fixtures); installer #478/#483/#481 (safe delivery); reproduce scheduler naming if watchdog warnings persist. Then targeted CI + physical follow-up with the owner.
- **Safety:** read-only observations here; changes to live routers, Core/Web releases, `stable` or update channels require separate owner authorization; code implementation via linked PR and exact-SHA checks, not this documentation PR.

## Links

- KN-1010 universal install [#480](https://github.com/saymer-alt/keenetic-auto-setup/issues/480)
- MT DNS delivery [#483](https://github.com/saymer-alt/keenetic-auto-setup/issues/483)
- Mihomo IPK fallback + progress [#478](https://github.com/saymer-alt/keenetic-auto-setup/issues/478)
- GitLab artifact mirror [#481](https://github.com/saymer-alt/keenetic-auto-setup/issues/481)
- Web observed defects [#484](https://github.com/saymer-alt/keenetic-auto-setup/issues/484)
- Temperature research [#485](https://github.com/saymer-alt/keenetic-auto-setup/issues/485)
- Prior metrics contract [#309](https://github.com/saymer-alt/keenetic-auto-setup/issues/309)
- Web release/handoff [#395](https://github.com/saymer-alt/keenetic-auto-setup/issues/395)
