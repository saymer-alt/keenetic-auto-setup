# Router metrics: read-only state collector (Web beta.4 candidate)

`kas-sys-metrics.sh` is an optional one-shot read-only collector of standard Linux/KeeneticOS kernel readings (issue [#309](https://github.com/saymer-alt/keenetic-auto-setup/issues/309)): SoC/CPU temperature from sysfs, load average, uptime, a memory/swap summary from /proc and - since collector 0.2.0 (issue [#476](https://github.com/saymer-alt/keenetic-auto-setup/issues/476), stage A, backend only) - the Entware `/opt` storage filesystem. Owner decision (2026-10-31): an **optional convenience feature for the future** - first the collector with honest UNKNOWN handling, then simple cards in KAS Web beta.4. This is not monitoring and not a beta.4 blocker.

## What is collected

| Reading | Source | Rule |
| --- | --- | --- |
| SoC/CPU temperature | `/sys/class/thermal/thermal_zone*/{type,temp}`, then `/sys/class/hwmon/hwmon*/{name,temp*_input}` | the zone is selected strictly by a case-insensitive cpu/soc mention in `type`/`name`; a generic `thermal` zone is not treated as a CPU sensor; empty/non-numeric/negative/out-of-range (-40..+150 C) -> **UNKNOWN, never clamped or faked**; the choice and source are printed |
| Load average 1/5/15 | `/proc/loadavg` | this is **load average, not CPU percentage**; no percentage is derived |
| Uptime | `/proc/uptime` | Linux time since boot; not WAN/ISP/Mihomo/watchdog uptime |
| RAM / swap | `/proc/meminfo` (MemTotal, MemAvailable, SwapTotal, SwapFree) | summary only; the full RAM/storage health analysis stays in the main Doctor - no duplicated verdicts |
| Entware /opt storage (0.2.0, #476 stage A) | `df -kP` (fallback `-k`) on `$KAS_OPT_ROOT` (default `/opt`) + deepest mount from `/proc/mounts` | Doctor-mirrored classification: `ubifs`/`squashfs` or `ubi*`/`mtd*` source -> `internal`; `tmpfs`/`ramfs` -> `ram` (RAM-backed, not flash); known ext-class filesystem on `/dev/sd*`/`/dev/nvme*`/`/tmp/mnt/*` -> `external`; anything else -> `unknown`. Free/total are **filesystem-level df kilobytes, never a raw flash size**, and only `/opt` is probed - never `/tmp` tmpfs or swap/zRAM. The exit code never changes because of storage. |

## /opt storage fail-closed rules (#476 stage A)

- The deepest mount carrying `/opt` wins; equally deep **conflicting** entries are ambiguous -> classification `unknown` (df numbers, when valid, stay honest `PASS` with `source: df`).
- Absent `/opt` mount + absent directory -> `N/A` (nothing to observe); a covering mount with unreadable/malformed/out-of-range df -> `UNKNOWN` (never zeros, never a verdict).
- df values must be pure integers with `0 < total <= 9999999999` kB and `free <= total`; anything else (negative, decimal, overflow, zero total) -> `UNKNOWN`, numbers are not emitted.
- A `PASS` reading always carries `mount_class`, `fstype`, `mount_point`, `source` (`df+proc_mounts` / `df` / `proc_mounts` / `none`) and `observed_utc`; non-PASS blocks carry no numbers and a plain-language reason in `note`.
- The device source identifier (e.g. `/dev/ubi0_0`) is deliberately **not** reported; kernel-escaped mount points are decoded for display (`\040` -> space).
- Web rendering of this block is **Stage B, intentionally deferred** (serial with the canonical Web #491 changes); this PR changes no Web UI.

## What the collector does not do

- Changes nothing; one run is one pass; no daemons, cron, network or packages (Fastfetch/flashfetch are **not installed** and not required).
- **No overheating thresholds**: vendor limits are not known per model, so there are no "OK/WARN/FAIL" temperature verdicts - observations only.
- **No storage health verdicts**: no "flash is dying/healthy" claims; free/total are observations, `0 kB free` is reported honestly.
- A missing or ambiguous sensor is `UNKNOWN`/`N/A` - never a fake value, never a FAIL.
- No secrets or hardware identifiers are emitted.

## Running

```sh
sh kas-sys-metrics.sh
sh kas-sys-metrics.sh --json /opt/tmp/metrics.json
```

Exit codes: `0` at least one metric observed; `1` nothing observed (all UNKNOWN); `2` usage error. The exit code reflects the **four core readings only**; the `/opt` storage observation is additive and never changes it. Tests use the `KAS_SYSFS_ROOT` / `KAS_PROC_ROOT` injection roots and, for storage, `KAS_OPT_ROOT` / `KAS_MOUNTS_SRC` / `KAS_DF_BIN` (all unset in normal operation).

## The router-metrics/v1 JSON contract

`--json FILE` writes the schema version, tool name/version, UTC time, exit code and the `temperature` (status, celsius, zone, type, source, "no thresholds asserted" note), `load` (status, 1/5/15 min, "load average, not CPU percentage" note), `uptime` (status, seconds, note), `memory`, `swap` and - since 0.2.0 - an optional additive `storage` block (`status`, `path`, `mount_class`, `fstype`, `mount_point`, `free_kb`, `total_kb`, `source`, `observed_utc`, `note`). All statuses are `PASS / UNKNOWN / N/A / INFO`; the format is ready for future Web beta.4 cards.

**Version compatibility (defensible versioned-contract choice):** the schema stays `router-metrics/v1` because the field is optional and additive - old consumers ignore unknown keys, and old saved v1 payloads remain valid. `tool_version` moves `0.1.0` -> `0.2.0`: the Go adapter accepts both, rejects a `0.1.0` payload that claims a storage block (that collector never emitted one), and strictly validates the block whenever it is present (status vocabulary, class/source sets, numeric bounds, `free <= total`, no numbers on non-PASS, no control bytes). Collector and validator always ship together inside the same Web binary, so no production skew is possible; a `0.2.0` JSON fed to an old beta.8 build is rejected by its version pin, which is fail-closed by design.

## Testing and evidence boundaries

- `tests/sys-metrics-regression.py` - offline regression on fixture sysfs/procfs trees (injection roots): a normal `soc_thermal` zone, hwmon-only variant, multiple zones (first CPU zone selected, all printed), implausible value -> UNKNOWN without clamping, negative and textual values -> UNKNOWN, unreadable file -> UNKNOWN, no sensors with working /proc -> 3 of 4 observed, nothing at all -> exit 1 all-UNKNOWN, malformed loadavg/uptime, no swap -> N/A, JSON validity and no FAIL/WARN-style verdicts in the report.
- `tests/sys-metrics-storage-regression.py` (#476 stage A) - offline storage regression on injected `/opt` + mount-table + df fixtures: internal UBIFS via the root mount (KN-3811 FIELD shape), external EXT4 with bind-style `/opt` and an escaped parent mount point, `/opt` on tmpfs -> `ram`, no `/opt` -> N/A, directory without a covering mount, garbled/nonnumeric/out-of-range df, zero free -> honest PASS, oversized total, missing df binary, `-kP` -> `-k` fallback, ambiguity -> unknown class, unreadable mounts with working/broken df, `\040` mount-point decoding, /opt-vs-/tmp tmpfs distinctness and the untouched exit code.
- Go contract coverage: `web/control-center/router_metrics_test.go` - versioned payload table (old v1, new v1 with/without valid and malformed storage) and end-to-end collector fixtures through the embedded script (`KAS_OPT_ROOT`/`KAS_MOUNTS_SRC`/`KAS_DF_BIN` are test-only injections; production passes none).
- Executed on host sh and BusyBox ash 1.37: **MOCK PASS on both dialects** for both regression suites.
- **QEMU (separate read-only guest run): PASS for executing the collector** in disposable KeeneticOS Ported 5.1.8 / Entware (DRIVER_OK, 254 s): `kas-sys-metrics.sh` exited 0, `router-metrics/v1` JSON was valid, and guest `/proc/loadavg`, `/proc/uptime`, `/proc/meminfo` were read. That QEMU run predates the 0.2.0 storage block; the storage section itself has **no QEMU and no physical evidence**. Fixture coverage is a separate **MOCK PASS**, and `native-kas / ported-lab` CI is a separate KAS lifecycle result. **PHYSICAL: NOT TESTED** - KN-3811/KN-1010/KN-1012/NC-1812 and other hardware require separate owner GO; the KN-3811 FIELD omission stays open until then.
