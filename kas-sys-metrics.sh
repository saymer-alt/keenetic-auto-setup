#!/bin/sh

# kas-sys-metrics.sh v0.2.0
#
# Optional read-only router metrics collector (issues #309, #476). Gathers,
# from standard kernel interfaces only:
#   - CPU/SoC temperature: /sys/class/thermal/thermal_zone*/{type,temp}
#     and /sys/class/hwmon/hwmon*/{name,temp*_input}
#   - load average 1/5/15 min: /proc/loadavg (this is LOAD AVERAGE, never
#     a CPU-percentage reading)
#   - uptime seconds: /proc/uptime
#   - memory and swap totals: /proc/meminfo (summary level only)
#   - Entware /opt storage (issue #476 stage A): mount class/filesystem and
#     free/total kB from df + /proc/mounts; filesystem-level capacity, never
#     a raw flash size, never /tmp tmpfs or swap/zRAM confusion
#
# Design rules (issue #309 decision, 2026-10-31; #476 stage A, 2026-11-09):
#   - read-only; one-shot; no daemons, no cron, no network, no packages;
#   - a missing, unreadable, ambiguous or implausible sensor is reported
#     as UNKNOWN/N-A - never a fake value, never a FAIL/WARN;
#   - NO temperature thresholds: vendor limits are not known per model,
#     so this collector reports observations, not overheating verdicts;
#   - load average is never converted into a CPU-percentage claim;
#   - storage: absent/ambiguous/unreadable /opt is UNKNOWN (or N/A when no
#     /opt mount is observed at all), never zeros, never a health verdict;
#   - no secrets or hardware identifiers are emitted (the /opt device
#     source identifier is deliberately not reported).
#
# Test injection: KAS_SYSFS_ROOT / KAS_PROC_ROOT override the /sys and
# /proc trees (fixture tests); KAS_OPT_ROOT / KAS_MOUNTS_SRC / KAS_DF_BIN
# override /opt, the mount table and the df binary; unset in normal
# operation.
#
# Output: human report plus optional router-metrics/v1 JSON (--json FILE).
#
# Exit codes: 0 = at least one metric observed; 1 = nothing could be
# observed (all UNKNOWN); 2 = usage error. The exit code reflects the four
# core readings only; storage is an additive observation and never changes
# it.

set -u

PROG_NAME="kas-sys-metrics.sh"
PROG_VERSION="0.2.0"
SCHEMA="router-metrics/v1"
SYS_ROOT="${KAS_SYSFS_ROOT:-/sys}"
PROC_ROOT="${KAS_PROC_ROOT:-/proc}"
OPT_ROOT="${KAS_OPT_ROOT:-/opt}"
MOUNTS_SRC="${KAS_MOUNTS_SRC:-/proc/mounts}"
DF_BIN="${KAS_DF_BIN:-df}"
JSON_FILE=""
MAX_ZONES=8
MAX_HWMON=8
MAX_MOUNTS=128
STORAGE_MAX_TOTAL_KB=9999999999

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
average, uptime, memory/swap summary, and the Entware /opt storage
filesystem (class, filesystem, free/total; df + /proc/mounts). No
thresholds are asserted and no verdicts about overheating or storage
health are made; unobservable values are UNKNOWN/N-A.

Usage:
  sh $PROG_NAME [--json <file>]

Options:
  --json <file>  also write the router-metrics/v1 JSON report
  -h, --help     this help

Exit codes: 0 at least one metric observed; 1 nothing observed; 2 usage.
The exit code reflects the four core readings only; the /opt storage
observation is additive and never changes it.
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
# Storage: Entware /opt filesystem (issue #476 stage A). One-shot
# read-only df + /proc/mounts classification mirroring the main
# Doctor: internal (UBIFS/squashfs or ubi*/mtd* source), external
# (known ext-class filesystem on /dev/sd*|/dev/nvme*|/tmp/mnt/*),
# RAM-backed (tmpfs/ramfs) or unknown. The deepest mount carrying
# $OPT_ROOT wins; equally deep conflicting entries are ambiguous and
# classify as unknown. Capacity is filesystem-level df data, never a
# raw flash size, and never /tmp tmpfs or swap/zRAM: only $OPT_ROOT
# is probed. Absent/ambiguous/unreadable data is UNKNOWN or N/A -
# never zeros, never a health verdict. The device source identifier
# is deliberately not emitted. Test injection: KAS_OPT_ROOT,
# KAS_MOUNTS_SRC, KAS_DF_BIN.
# ---------------------------------------------------------------
printf '\n=== Storage: Entware /opt ===\n'
STORAGE_STATUS="UNKNOWN"
STORAGE_REASON="not yet observed"
OPT_CLASS="unknown"; OPT_FSTYPE="unknown"; OPT_MP="unknown"
OPT_FREE=""; OPT_TOTAL=""; OPT_SOURCE="none"
ST_MOUNTS_OK=0
ST_BEST_LEN=-1; ST_BEST_MP=""; ST_BEST_FST=""; ST_BEST_SRC=""; ST_AMBIG=0

if [ -r "$MOUNTS_SRC" ]; then
    ST_MOUNTS_OK=1
    _st_lines=0
    while read -r _st_src _st_mp _st_fst _st_rest; do
        _st_lines=$((_st_lines+1))
        [ "$_st_lines" -le "$MAX_MOUNTS" ] || break
        [ -n "$_st_mp" ] || continue
        # the root mount "/" covers every path; the "$mp"/* glob form would
        # expand to "//*" for it and never match, so test it explicitly
        if [ "$_st_mp" = "/" ]; then
            _st_cover=yes
        else
            _st_cover=no
            case "$OPT_ROOT" in
                "$_st_mp") _st_cover=yes ;;
                *) case "$OPT_ROOT" in
                       "$_st_mp"/*) _st_cover=yes ;;
                   esac ;;
            esac
        fi
        [ "$_st_cover" = yes ] || continue
        _st_len=${#_st_mp}
        if [ "$_st_len" -gt "$ST_BEST_LEN" ]; then
            ST_BEST_LEN=$_st_len; ST_BEST_MP=$_st_mp; ST_BEST_FST=$_st_fst; ST_BEST_SRC=$_st_src
            ST_AMBIG=0
        elif [ "$_st_len" -eq "$ST_BEST_LEN" ]; then
            # equally deep second cover: ambiguous unless identical
            if [ "$_st_fst" != "$ST_BEST_FST" ] || [ "$_st_src" != "$ST_BEST_SRC" ]; then
                ST_AMBIG=1
            fi
        fi
    done < "$MOUNTS_SRC"
else
    printf 'mounts source: %s not readable\n' "$MOUNTS_SRC"
fi

if [ "$ST_MOUNTS_OK" -eq 1 ] && [ "$ST_BEST_LEN" -ge 0 ]; then
    if [ "$ST_AMBIG" -eq 1 ]; then
        OPT_CLASS="unknown"; OPT_FSTYPE="unknown"; OPT_MP="unknown"
    else
        # kernel-escaped mount point: decode the common \040 space escape
        # for display; other escapes are shown in their kernel form
        OPT_MP=$(printf '%s' "$ST_BEST_MP" | awk '{ gsub(/\\040/, " "); print }')
        case "$OPT_MP" in
            ''|*[[:cntrl:]]*) OPT_MP="unknown" ;;
        esac
        [ "${#OPT_MP}" -le 200 ] || OPT_MP="unknown"
        _st_fst=$(printf '%s' "$ST_BEST_FST" | tr 'A-Z' 'a-z')
        case "$_st_fst" in
            ''|*[!a-z0-9._-]*) _st_fst="unknown" ;;
        esac
        [ "${#_st_fst}" -le 32 ] || _st_fst="unknown"
        OPT_FSTYPE=$_st_fst
        case "$OPT_FSTYPE" in
            ubifs|squashfs) OPT_CLASS="internal" ;;
            tmpfs|ramfs)    OPT_CLASS="ram" ;;
            *)
                case "$ST_BEST_SRC" in
                    ubi*|mtd*) OPT_CLASS="internal" ;;
                    *)
                        case "$OPT_FSTYPE" in
                            ext2|ext3|ext4|btrfs|f2fs|xfs|vfat|fat|exfat|ntfs|ntfs3|fuseblk)
                                case "$ST_BEST_SRC" in
                                    /dev/sd*|/dev/nvme*|/tmp/mnt/*) OPT_CLASS="external" ;;
                                    *) OPT_CLASS="unknown" ;;
                                esac ;;
                            *) OPT_CLASS="unknown" ;;
                        esac ;;
                esac ;;
        esac
    fi
fi

# df: POSIX format first (single line, no wrapping), then plain -k for
# BusyBox builds without -P. A missing or erroring df yields empty output.
ST_DF_OUT=""
ST_DF_OUT=$("$DF_BIN" -kP "$OPT_ROOT" 2>/dev/null) || ST_DF_OUT=""
if [ -z "$ST_DF_OUT" ]; then
    ST_DF_OUT=$("$DF_BIN" -k "$OPT_ROOT" 2>/dev/null) || ST_DF_OUT=""
fi
ST_DF_TOTAL=""
ST_DF_AVAIL=""
if [ -n "$ST_DF_OUT" ]; then
    _st_df=$(printf '%s\n' "$ST_DF_OUT" | awk 'NR==2 { print $2 " " $4 }')
    ST_DF_TOTAL=${_st_df%% *}
    ST_DF_AVAIL=${_st_df#* }
    [ "$ST_DF_TOTAL" != "$_st_df" ] || { ST_DF_TOTAL=""; ST_DF_AVAIL=""; }
    case "$ST_DF_TOTAL" in ''|*[!0-9]*) ST_DF_TOTAL="" ;; esac
    case "$ST_DF_AVAIL" in ''|*[!0-9]*) ST_DF_AVAIL="" ;; esac
fi

ST_PLAUSIBLE=no
if [ -n "$ST_DF_TOTAL" ] && [ -n "$ST_DF_AVAIL" ]; then
    if awk -v t="$ST_DF_TOTAL" -v a="$ST_DF_AVAIL" \
        'BEGIN { exit !(t+0 > 0 && t+0 <= '"$STORAGE_MAX_TOTAL_KB"' && a+0 <= t+0) }' 2>/dev/null; then
        ST_PLAUSIBLE=yes
    fi
fi

if [ "$ST_MOUNTS_OK" -ne 1 ]; then
    # neither the mount table nor anything else can classify /opt
    if [ "$ST_PLAUSIBLE" = "yes" ]; then
        OPT_FREE=$ST_DF_AVAIL; OPT_TOTAL=$ST_DF_TOTAL; OPT_SOURCE="df"
        STORAGE_STATUS="PASS"
        STORAGE_REASON=""
        ok_out "storage /opt: ${OPT_FREE} kB free of ${OPT_TOTAL} kB (filesystem ${OPT_FSTYPE}, class ${OPT_CLASS}; df filesystem-level capacity, not raw flash size)"
    else
        STORAGE_STATUS="UNKNOWN"
        STORAGE_REASON="mount table unreadable and df unavailable or malformed"
        unk_out "storage /opt: UNKNOWN (${STORAGE_REASON})"
    fi
elif [ "$ST_BEST_LEN" -lt 0 ]; then
    # readable mount table with no entry covering $OPT_ROOT
    if [ "$ST_PLAUSIBLE" = "yes" ]; then
        STORAGE_STATUS="UNKNOWN"
        STORAGE_REASON="df reported capacity but no mount entry covers ${OPT_ROOT}"
        unk_out "storage /opt: UNKNOWN (${STORAGE_REASON})"
    elif [ -d "$OPT_ROOT" ]; then
        STORAGE_STATUS="UNKNOWN"
        STORAGE_REASON="directory present but no mount entry covers ${OPT_ROOT}"
        unk_out "storage /opt: UNKNOWN (${STORAGE_REASON})"
    else
        STORAGE_STATUS="N/A"
        STORAGE_REASON=""
        info_out "storage /opt: N/A - no /opt mount or directory observed (Entware may not be installed)"
    fi
else
    # a mount covering $OPT_ROOT is known
    if [ "$ST_PLAUSIBLE" = "yes" ]; then
        OPT_FREE=$ST_DF_AVAIL; OPT_TOTAL=$ST_DF_TOTAL; OPT_SOURCE="df+proc_mounts"
        if [ "$ST_AMBIG" -eq 1 ]; then
            OPT_SOURCE="df"
            STORAGE_STATUS="PASS"
            STORAGE_REASON=""
            ok_out "storage /opt: ${OPT_FREE} kB free of ${OPT_TOTAL} kB (filesystem unknown, class unknown; equally deep conflicting mount entries; df filesystem-level capacity, not raw flash size)"
        else
            STORAGE_STATUS="PASS"
            STORAGE_REASON=""
            ok_out "storage /opt: ${OPT_FREE} kB free of ${OPT_TOTAL} kB (filesystem ${OPT_FSTYPE}, class ${OPT_CLASS}; df filesystem-level capacity, not raw flash size)"
        fi
    elif [ -n "$ST_DF_TOTAL" ] || [ -n "$ST_DF_AVAIL" ]; then
        OPT_SOURCE="proc_mounts"
        STORAGE_STATUS="UNKNOWN"
        STORAGE_REASON="df output outside the plausible range (total must be >0, free <= total, total <= ${STORAGE_MAX_TOTAL_KB} kB)"
        unk_out "storage /opt: UNKNOWN (${STORAGE_REASON})"
    else
        OPT_SOURCE="proc_mounts"
        STORAGE_STATUS="UNKNOWN"
        STORAGE_REASON="df unavailable or malformed for ${OPT_ROOT}"
        unk_out "storage /opt: UNKNOWN (filesystem ${OPT_FSTYPE}, class ${OPT_CLASS}; ${STORAGE_REASON})"
    fi
fi
if [ "$STORAGE_STATUS" != "PASS" ]; then
    OPT_FREE=""; OPT_TOTAL=""
fi
if [ "$STORAGE_STATUS" = "PASS" ]; then
    ST_NOTE="filesystem-level df capacity of the /opt filesystem, not raw flash size; /tmp tmpfs, swap/zRAM and RAM are separate readings; device source intentionally not reported"
else
    ST_NOTE="no reliable /opt filesystem capacity observation; /tmp tmpfs, swap/zRAM and RAM are separate readings; device source intentionally not reported"
    if [ -n "$STORAGE_REASON" ]; then
        ST_NOTE="$ST_NOTE; reason: $STORAGE_REASON"
    fi
fi

# ---------------------------------------------------------------
# Summary + JSON
# ---------------------------------------------------------------
NOW_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)
[ -n "$NOW_UTC" ] || NOW_UTC="unknown"

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
    if [ "$STORAGE_STATUS" = "PASS" ]; then
        unk_out "no core metric could be observed on this system; the /opt storage reading is an additive observation and does not change the exit code"
    else
        unk_out "no core metric could be observed on this system; report is all-UNKNOWN"
    fi
    FINAL_RC=1
fi
info_out "storage /opt (${STORAGE_STATUS}) is an additive issue #476 stage A observation; it never alters the exit code, never /tmp tmpfs or swap/zRAM"

if [ -n "$JSON_FILE" ]; then
    case "$JSON_FILE" in
        */*) JSON_DIR=${JSON_FILE%/*}
             [ -d "$JSON_DIR" ] || { printf '[ERROR] json directory does not exist: %s\n' "$JSON_DIR" >&2; exit 2; } ;;
    esac
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
        printf '  },\n'
        printf '  "storage": {\n'
        printf '    "status": "%s",\n' "$STORAGE_STATUS"
        printf '    "path": "%s",\n' "$(json_escape "$OPT_ROOT")"
        printf '    "mount_class": "%s",\n' "$OPT_CLASS"
        printf '    "fstype": "%s",\n' "$OPT_FSTYPE"
        printf '    "mount_point": "%s",\n' "$(json_escape "$OPT_MP")"
        printf '    "free_kb": "%s",\n' "$OPT_FREE"
        printf '    "total_kb": "%s",\n' "$OPT_TOTAL"
        printf '    "source": "%s",\n' "$OPT_SOURCE"
        printf '    "observed_utc": "%s",\n' "$NOW_UTC"
        printf '    "note": "%s"\n' "$(json_escape "$ST_NOTE")"
        printf '  }\n'
        printf '}\n'
    } > "$JSON_FILE" 2>/dev/null || { printf '[ERROR] cannot write: %s\n' "$JSON_FILE" >&2; exit 2; }
    info_out "JSON contract ($SCHEMA) written to $JSON_FILE."
fi

exit "$FINAL_RC"
