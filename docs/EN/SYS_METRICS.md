# Router metrics: read-only state collector (standalone optional collector)

`kas-sys-metrics.sh` is an optional one-shot read-only collector of standard Linux/KeeneticOS kernel readings (issue [#309](https://github.com/saymer-alt/keenetic-auto-setup/issues/309)): SoC/CPU temperature from sysfs, load average, uptime and a memory/swap summary from /proc. Owner decision (2026-10-31): an **optional convenience feature for the future** - first the collector with honest UNKNOWN handling, then optional KAS Web integration. This is not monitoring and does not block current Web betas. Integration was deferred to Web Beta 5 by the 2026-11-01 owner decision.

## What is collected

| Reading | Source | Rule |
| --- | --- | --- |
| SoC/CPU temperature | `/sys/class/thermal/thermal_zone*/{type,temp}`, then `/sys/class/hwmon/hwmon*/{name,temp*_input}` | the zone is selected strictly by a case-insensitive cpu/soc mention in `type`/`name`; a generic `thermal` zone is not treated as a CPU sensor; empty/non-numeric/negative/out-of-range (-40..+150 C) -> **UNKNOWN, never clamped or faked**; the choice and source are printed |
| Load average 1/5/15 | `/proc/loadavg` | this is **load average, not CPU percentage**; no percentage is derived |
| Uptime | `/proc/uptime` | Linux time since boot; not WAN/ISP/Mihomo/watchdog uptime |
| RAM / swap | `/proc/meminfo` (MemTotal, MemAvailable, SwapTotal, SwapFree) | summary only; the full RAM/storage health analysis stays in the main Doctor - no duplicated verdicts |

## What the collector does not do

- Changes nothing; one run is one pass; no daemons, cron, network or packages (Fastfetch/flashfetch are **not installed** and not required).
- **No overheating thresholds**: vendor limits are not known per model, so there are no "OK/WARN/FAIL" temperature verdicts - observations only.
- A missing or ambiguous sensor is `UNKNOWN`/`N/A` - never a fake value, never a FAIL.
- No secrets or hardware identifiers are emitted.

## Quick start on a new router from `stable`

You need SSH access to Keenetic/Netcraze and a way to download the file (for example, `curl`). KAS, Mihomo, and the Web panel are **not required** to read standard `/proc` and `/sys` files. On a new router with Entware, if `curl` is missing, run `opkg update && opkg install curl` (only the download utility is installed).

Download the script into `/tmp`, validate its syntax, and print a router snapshot:

```sh
curl -fSsL --retry 2 --max-time 60 -o /tmp/kas-sys-metrics.sh \
  https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/kas-sys-metrics.sh &&
sh -n /tmp/kas-sys-metrics.sh &&
sh /tmp/kas-sys-metrics.sh
```

To save JSON after downloading:

```sh
sh /tmp/kas-sys-metrics.sh --json /tmp/kas-metrics.json
```

The `&&` chain prevents execution if the download or syntax check fails. The collector installs nothing, makes no network requests itself, and changes no settings. `/tmp` is temporary; missing temperature sensors are honestly reported as `UNKNOWN`. If GitHub is unreachable, copy the script into `/tmp` with SCP and run `sh /tmp/kas-sys-metrics.sh`.

## Running

```sh
sh kas-sys-metrics.sh
sh kas-sys-metrics.sh --json /opt/tmp/metrics.json
```

Exit codes: `0` at least one metric observed; `1` nothing observed (all UNKNOWN); `2` usage error. Tests use the `KAS_SYSFS_ROOT` / `KAS_PROC_ROOT` injection roots (unset in normal operation).

## The router-metrics/v1 JSON contract

`--json FILE` writes the schema version, tool name/version, UTC time, exit code and the `temperature` (status, celsius, zone, type, source, "no thresholds asserted" note), `load` (status, 1/5/15 min, "load average, not CPU percentage" note), `uptime` (status, seconds, note), `memory` and `swap` blocks. All statuses are `PASS / UNKNOWN / N/A / INFO`; the format is ready for future KAS Web cards.

## Testing and evidence boundaries

- `tests/sys-metrics-regression.py` - offline regression on fixture sysfs/procfs trees (injection roots): a normal `soc_thermal` zone, hwmon-only variant, multiple zones (first CPU zone selected, all printed), implausible value -> UNKNOWN without clamping, negative and textual values -> UNKNOWN, unreadable file -> UNKNOWN, no sensors with working /proc -> 3 of 4 observed, nothing at all -> exit 1 all-UNKNOWN, malformed loadavg/uptime, no swap -> N/A, JSON validity and no FAIL/WARN-style verdicts in the report.
- Executed on host sh and BusyBox ash 1.37: **MOCK PASS on both dialects**.
- **QEMU (separate read-only guest run): PASS for executing the collector** in disposable KeeneticOS Ported 5.1.8 / Entware (DRIVER_OK, 254 s): `kas-sys-metrics.sh` exited 0, `router-metrics/v1` JSON was valid, and guest `/proc/loadavg`, `/proc/uptime`, `/proc/meminfo` were read. The `thermal_zone0` type `cpu-thermal` reading of **45.3 °C is an emulated model reading**, not evidence of a physical SoC temperature; absent hwmon was not fabricated. Fixture coverage is a separate **MOCK PASS**, and `native-kas / ported-lab` CI is a separate KAS lifecycle result. **PHYSICAL: NOT TESTED** - KN-1010/KN-1012/NC-1812 and other hardware require separate owner GO.
