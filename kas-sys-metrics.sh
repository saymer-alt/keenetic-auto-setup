#!/bin/sh

# kas-sys-metrics.sh v0.1.0
#
# Optional read-only router metrics collector (issue #309). Gathers, from
# standard kernel interfaces only:
#   - CPU/SoC temperature: /sys/class/thermal/thermal_zone*/{type,temp}
#     and /sys/class/hwmon/hwmon*/{name,temp*_input}
#   - load average 1/5/15 min: /proc/loadavg (this is LOAD AVERAGE, never
#     a CPU-percentage reading)
#   - uptime seconds: /proc/uptime
#   - memory and swap totals: /proc/meminfo (summary level only)
#
# Design rules (issue #309 decision, 2026-10-31):
#   - read-only; one-shot; no daemons, no cron, no network, no packages;
#   - a missing, unreadable, ambiguous or implausible sensor is reported
#     as UNKNOWN/N-A - never a fake value, never a FAIL/WARN;
#   - NO temperature thresholds: vendor limits are not known per model,
#     so this collector reports observations, not overheating verdicts;
#   - load average is never converted into a CPU-percentage claim;
#   - no secrets or hardware identifiers are emitted.
#
# Test injection: KAS_SYSFS_ROOT / KAS_PROC_ROOT override the /sys and
# /proc trees (fixture tests); unset in normal operation.
#
# Output: human report plus optional router-metrics/v1 JSON (--json FILE).
#
# Exit codes: 0 = at least one metric observed; 1 = nothing could be
# observed (all UNKNOWN); 2 = usage error.

set -u

PROG_NAME="kas-sys-metrics.sh"
PROG_VERSION="0.1.0"
SCHEMA="router-metrics/v1"
SYS_ROOT="${KAS_SYSFS_ROOT:-/sys}"
PROC_ROOT="${KAS_PROC_ROOT:-/proc}"
JSON_FILE=""
MAX_ZONES=8
MAX_HWMON=8

COLOR_RESET=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_CYAN=""
if [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    if [ -t 1 ] 2>/dev/null; then
        COLOR_RESET=$(printf '\033[0m')
        COLOR_GREEN=$(printf '\033[1;32m')
        COLOR_YELLOW=$(printf '\033[1;33m')
        COLOR_CYAN=$(printf '\033[1;36m')
    fi
fi
ok_out()   { printf '%s[OK]%s %s\n'     "$COLOR_GREEN"  "$COLOR_RESET" "$1"; }
unk_out()  { printf '%s[UNKNOWN]%s %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$1"; }
info_out() { printf '%s[INFO]%s %s\n'   "$COLOR_CYAN"   "$COLOR_RESET" "$1"; }

usage() {
    cat <<USAGE
$PROG_NAME v$PROG_VERSION

Read-only one-shot router metrics: SoC/CPU temperature (sysfs), load
average, uptime, memory/swap summary. No thresholds are asserted and no
verdicts about overheating are made; unobservable values are UNKNOWN/N-A.

Usage:
  sh $PROG_NAME [--json <file>]

Options:
  --json <file>  also write the router-metrics/v1 JSON report
  -h, --help     this help

Exit codes: 0 at least one metric observed; 1 nothing observed; 2 usage.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --json)
            [ "$#" -ge 2 ] || { printf '[ERROR] --json requires a value\n' >&2; exit 2; }
            JSON_FILE=$2; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; printf '[ERROR] Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

printf '=== %s ===\n' "KAS system metrics (read-only, one-shot)"
printf 'sysfs: %s  procfs: %s\n' "$SYS_ROOT" "$PROC_ROOT"

# ---------------------------------------------------------------
# json_escape: minimal single-line JSON escaping via awk octals.
# ---------------------------------------------------------------
json_escape() {
    printf '%s' "$1" | tr '\n' ' ' | awk '
    {
        gsub(/\\/, "\\\\")
        gsub(/"/,  "\\\"")
        gsub(/[\001-\037\177]/, "?")
        printf "%s", $0
    }'
}

# ---------------------------------------------------------------
# Temperature: sysfs only; millidegrees C expected. An implausible
# value (empty, non-numeric, <-40C, >150C after /1000) is UNKNOWN,
# never clamped or faked.
# ---------------------------------------------------------------
printf '\n=== Temperature ===\n'
TEMP_ZONE=""
TEMP_ZONE_TYPE=""
TEMP_MILLIC=""
TEMP_SOURCE=""
_nzones=0
if [ -d "$SYS_ROOT/class/thermal" ]; then
    for _tz in "$SYS_ROOT"/class/thermal/thermal_zone*; do
        [ -d "$_tz" ] || continue
        _nzones=$((_nzones+1))
        [ "$_nzones" -le "$MAX_ZONES" ] || break
        _type=$(cat "$_tz/type" 2>/dev/null || true)
        _temp=$(cat "$_tz/temp" 2>/dev/null || true)
        case "$_temp" in
            ''|*[!0-9-]*) _temp="" ;;
            -*) _temp="" ;;
        esac
        printf 'zone %s: type=%s temp=%s\n' \
            "${_tz##*/}" "${_type:-unknown}" "${_temp:-unreadable}"
        if [ -z "$TEMP_ZONE" ] && [ -n "$_temp" ]; then
            # strict CPU/SoC identification: the type must mention cpu/soc
            # (case-insensitive). A generic "thermal" zone is NOT accepted:
            # board/enclosure sensors must not be reported as CPU temperature.
            _tl=$(printf '%s' "$_type" | tr 'A-Z' 'a-z')
            case "$_tl" in
                *cpu*|*soc*)
                    TEMP_ZONE=${_tz##*/}
                    TEMP_ZONE_TYPE=${_type:-unknown}
                    TEMP_MILLIC=$_temp
                    TEMP_SOURCE="sysfs:thermal"
                    ;;
            esac
        fi
    done
else
    printf 'thermal zones: %s/class/thermal not present\n' "$SYS_ROOT"
fi
if [ -z "$TEMP_ZONE" ] && [ -d "$SYS_ROOT/class/hwmon" ]; then
    _nhw=0
    for _hw in "$SYS_ROOT"/class/hwmon/hwmon*; do
        [ -d "$_hw" ] || continue
        _nhw=$((_nhw+1))
        [ "$_nhw" -le "$MAX_HWMON" ] || break
        _name=$(cat "$_hw/name" 2>/dev/null || true)
        for _in in "$_hw"/temp[0-9]*_input; do
            [ -r "$_in" ] || continue
            _temp=$(cat "$_in" 2>/dev/null || true)
            case "$_temp" in
                ''|*[!0-9]*) _temp="" ;;
            esac
            printf 'hwmon %s: name=%s input=%s temp=%s\n' \
                "${_hw##*/}" "${_name:-unknown}" "${_in##*/}" "${_temp:-unreadable}"
            if [ -z "$TEMP_ZONE" ] && [ -n "$_temp" ]; then
                _hl=$(printf '%s' "$_name" | tr 'A-Z' 'a-z')
                case "$_hl" in
                    *cpu*|*soc*|*coretemp*)
                        TEMP_ZONE=${_hw##*/}
                        TEMP_ZONE_TYPE=${_name:-unknown}
                        TEMP_MILLIC=$_temp
                        TEMP_SOURCE="sysfs:hwmon"
                        break
                        ;;
                esac
            fi
        done
        [ -z "$TEMP_ZONE" ] || break
    done
fi
if [ -n "$TEMP_MILLIC" ]; then
    TEMP_C=$(awk -v m="$TEMP_MILLIC" 'BEGIN { printf "%.1f", m / 1000 }')
    case "$TEMP_C" in
        ''|*[!0-9.-]*) TEMP_C="" ;;
    esac
    _neg=""
    case "$TEMP_C" in -*) _neg=x ;; esac
    if [ -n "$TEMP_C" ] && [ -z "$_neg" ]; then
        _ok=$(awk -v c="$TEMP_C" 'BEGIN { print (c >= -40.0 && c <= 150.0) ? "yes" : "no" }')
    else
        _ok=no
    fi
    if [ "$_ok" = "yes" ]; then
        ok_out "temperature.cpu-soc: ${TEMP_C} C (zone ${TEMP_ZONE}, type ${TEMP_ZONE_TYPE}, source ${TEMP_SOURCE})"
        TEMP_STATUS="PASS"
    else
        unk_out "temperature.cpu-soc: sensor value outside the plausible range (-40..150 C): raw=${TEMP_MILLIC}; reported UNKNOWN, not clamped"
        TEMP_MILLIC=""
        TEMP_C=""
        TEMP_STATUS="UNKNOWN"
    fi
else
    unk_out "temperature.cpu-soc: no identifiable CPU/SoC temperature sensor readable on this system (zones found: ${_nzones})"
    TEMP_STATUS="UNKNOWN"
    TEMP_ZONE="-"; TEMP_ZONE_TYPE="-"; TEMP_C=""
    TEMP_SOURCE="none"
fi

# ---------------------------------------------------------------
# Load average (/proc/loadavg): reported as-is. This is load
# average, NOT CPU utilization; no percentage is derived.
# ---------------------------------------------------------------
printf '\n=== Load average and uptime ===\n'
LOAD1=""; LOAD5=""; LOAD15=""
if [ -r "$PROC_ROOT/loadavg" ]; then
    LOAD_ALL=$(cat "$PROC_ROOT/loadavg" 2>/dev/null || true)
    LOAD1=$(printf '%s' "$LOAD_ALL" | awk '{print $1}')
    LOAD5=$(printf '%s' "$LOAD_ALL" | awk '{print $2}')
    LOAD15=$(printf '%s' "$LOAD_ALL" | awk '{print $3}')
    case "$LOAD1$LOAD5$LOAD15" in
        *[!0-9.]*|"") LOAD1=""; LOAD5=""; LOAD15="" ;;
    esac
fi
if [ -n "$LOAD1" ]; then
    ok_out "load.avg: 1m=${LOAD1} 5m=${LOAD5} 15m=${LOAD15} (load average, not CPU percent)"
    LOAD_STATUS="PASS"
else
    unk_out "load.avg: /proc/loadavg unreadable or malformed; UNKNOWN"
    LOAD_STATUS="UNKNOWN"
    LOAD1="-"; LOAD5="-"; LOAD15="-"
fi

UPTIME_S=""
if [ -r "$PROC_ROOT/uptime" ]; then
    UPTIME_RAW=$(cat "$PROC_ROOT/uptime" 2>/dev/null || true)
    UPTIME_S=$(printf '%s' "$UPTIME_RAW" | awk '{print $1}')
    case "$UPTIME_S" in
        ''|*[!0-9.]*) UPTIME_S="" ;;
    esac
fi
if [ -n "$UPTIME_S" ]; then
    UPTIME_H=$(awk -v s="$UPTIME_S" 'BEGIN { printf "%.1f", s / 3600.0 }')
    ok_out "uptime: ${UPTIME_S} s (~${UPTIME_H} h since Linux boot; not WAN/ISP uptime)"
    UPTIME_STATUS="PASS"
else
    unk_out "uptime: /proc/uptime unreadable or malformed; UNKNOWN"
    UPTIME_STATUS="UNKNOWN"
    UPTIME_S="-"; UPTIME_H=""
fi

# ---------------------------------------------------------------
# Memory / swap summary from /proc/meminfo (kB fields). Deliberately
# summary-level: the full storage/RAM health analysis stays in the
# main Doctor; this collector does not duplicate its verdicts.
# ---------------------------------------------------------------
printf '\n=== Memory summary ===\n'
MEM_TOTAL=""; MEM_AVAIL=""; SWAP_TOTAL=""; SWAP_FREE=""
if [ -r "$PROC_ROOT/meminfo" ]; then
    _mi=$(cat "$PROC_ROOT/meminfo" 2>/dev/null || true)
    MEM_TOTAL=$(printf '%s\n' "$_mi"  | awk '/^MemTotal:/{print $2}')
    MEM_AVAIL=$(printf '%s\n' "$_mi"  | awk '/^MemAvailable:/{print $2}')
    SWAP_TOTAL=$(printf '%s\n' "$_mi" | awk '/^SwapTotal:/{print $2}')
    SWAP_FREE=$(printf '%s\n' "$_mi"  | awk '/^SwapFree:/{print $2}')
    case "$MEM_TOTAL" in ''|*[!0-9]*) MEM_TOTAL="" ;; esac
    case "$MEM_AVAIL" in ''|*[!0-9]*) MEM_AVAIL="" ;; esac
    case "$SWAP_TOTAL" in ''|*[!0-9]*) SWAP_TOTAL="" ;; esac
    case "$SWAP_FREE" in ''|*[!0-9]*) SWAP_FREE="" ;; esac
fi
if [ -n "$MEM_TOTAL" ] && [ -n "$MEM_AVAIL" ]; then
    ok_out "memory: total ${MEM_TOTAL} kB, available ${MEM_AVAIL} kB (kernel view at read time)"
    MEM_STATUS="PASS"
else
    unk_out "memory: MemTotal/MemAvailable unreadable; UNKNOWN"
    MEM_STATUS="UNKNOWN"
    MEM_TOTAL="-"; MEM_AVAIL="-"
fi
if [ -n "$SWAP_TOTAL" ] && [ -n "$SWAP_FREE" ]; then
    info_out "swap: total ${SWAP_TOTAL} kB, free ${SWAP_FREE} kB (informational only; no health verdict here)"
    SWAP_STATUS="INFO"
else
    info_out "swap: no swap totals readable (no active swap, or unreadable); N/A"
    SWAP_STATUS="N/A"
    SWAP_TOTAL="-"; SWAP_FREE="-"
fi

# ---------------------------------------------------------------
# Summary + JSON
# ---------------------------------------------------------------
printf '\n=== Summary ===\n'
info_out "Read-only one-shot collection; no thresholds asserted, no overheating verdicts made."
OBSERVED=0
for _s in "$TEMP_STATUS" "$LOAD_STATUS" "$UPTIME_STATUS" "$MEM_STATUS"; do
    [ "$_s" = "PASS" ] && OBSERVED=$((OBSERVED+1))
done
if [ "$OBSERVED" -gt 0 ]; then
    ok_out "metrics observed: ${OBSERVED} of 4 core readings (temperature, load, uptime, memory)"
    FINAL_RC=0
else
    unk_out "no core metric could be observed on this system; report is all-UNKNOWN"
    FINAL_RC=1
fi

if [ -n "$JSON_FILE" ]; then
    case "$JSON_FILE" in
        */*) JSON_DIR=${JSON_FILE%/*}
             [ -d "$JSON_DIR" ] || { printf '[ERROR] json directory does not exist: %s\n' "$JSON_DIR" >&2; exit 2; } ;;
    esac
    NOW_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)
    [ -n "$NOW_UTC" ] || NOW_UTC="unknown"
    {
        printf '{\n'
        printf '  "schema": "%s",\n' "$SCHEMA"
        printf '  "tool": "%s",\n' "$PROG_NAME"
        printf '  "tool_version": "%s",\n' "$PROG_VERSION"
        printf '  "generated_utc": "%s",\n' "$NOW_UTC"
        printf '  "exit_code": %s,\n' "$FINAL_RC"
        printf '  "temperature": {\n'
        printf '    "status": "%s",\n' "$TEMP_STATUS"
        printf '    "celsius": "%s",\n' "${TEMP_C:-}"
        printf '    "zone": "%s",\n' "$(json_escape "${TEMP_ZONE:-}")"
        printf '    "type": "%s",\n' "$(json_escape "${TEMP_ZONE_TYPE:-}")"
        printf '    "source": "%s",\n' "$(json_escape "${TEMP_SOURCE:-}")"
        printf '    "note": "%s"\n' "$(json_escape "no thresholds asserted; absent sensor is UNKNOWN, never a fake value")"
        printf '  },\n'
        printf '  "load": {\n'
        printf '    "status": "%s",\n' "$LOAD_STATUS"
        printf '    "one_min": "%s", "five_min": "%s", "fifteen_min": "%s",\n' \
            "$LOAD1" "$LOAD5" "$LOAD15"
        printf '    "note": "%s"\n' "$(json_escape "load average, not CPU percentage")"
        printf '  },\n'
        printf '  "uptime": {\n'
        printf '    "status": "%s",\n' "$UPTIME_STATUS"
        printf '    "seconds": "%s",\n' "$UPTIME_S"
        printf '    "note": "%s"\n' "$(json_escape "Linux boot time; not WAN/ISP/Mihomo/watchdog uptime")"
        printf '  },\n'
        printf '  "memory": {\n'
        printf '    "status": "%s",\n' "$MEM_STATUS"
        printf '    "mem_total_kb": "%s",\n' "$MEM_TOTAL"
        printf '    "mem_available_kb": "%s"\n' "$MEM_AVAIL"
        printf '  },\n'
        printf '  "swap": {\n'
        printf '    "status": "%s",\n' "$SWAP_STATUS"
        printf '    "total_kb": "%s",\n' "$SWAP_TOTAL"
        printf '    "free_kb": "%s"\n' "$SWAP_FREE"
        printf '  }\n'
        printf '}\n'
    } > "$JSON_FILE" 2>/dev/null || { printf '[ERROR] cannot write: %s\n' "$JSON_FILE" >&2; exit 2; }
    info_out "JSON contract ($SCHEMA) written to $JSON_FILE."
fi

exit "$FINAL_RC"
