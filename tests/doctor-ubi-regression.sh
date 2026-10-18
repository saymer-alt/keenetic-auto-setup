#!/bin/sh
# Read-only NAND/UBI Doctor report: sanitized KN-1012/KN-1010 field shapes.
# Extract the real Doctor functions; run against private temporary sysfs data.
# Never touches /sys, /proc/mtd or a router.
set -eu

ROOT="$1"
WORK=$(mktemp -d /tmp/kas-doctor-ubi.XXXXXX) || exit 1
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

sed -n '/^# BEGIN DOCTOR UBI HEALTH v1/,/^# END DOCTOR UBI HEALTH v1/p' \
    "$ROOT/mihomo-doctor.sh" > "$WORK/functions.sh"
[ -s "$WORK/functions.sh" ] || exit 1
sh -n "$WORK/functions.sh" || exit 1

run_case() (
    case_name=$1
    opt_kind=$2
    ro_value=$3
    expected_ok=$4
    expected_warn=$5
    expected_fail=$6
    device_count=$7
    base="$WORK/$case_name"
    mkdir -p "$base/sys" "$base/data"
    mounts="$base/mounts"
    if [ "$opt_kind" = internal ]; then
        printf '/dev/ubi0_0 /storage ubifs rw 0 0\n/dev/ubi0_0 /opt ubifs rw 0 0\n' > "$mounts"
    elif [ "$opt_kind" = external ]; then
        printf '/dev/ubi0_0 /storage ubifs rw 0 0\n/dev/sda2 /opt ext4 rw,noatime 0 0\n' > "$mounts"
    else
        printf '/dev/sda2 /opt ext4 rw 0 0\n' > "$mounts"
    fi

    if [ "$device_count" -gt 0 ]; then
        mkdir -p "$base/sys/ubi0" "$base/sys/ubi0_0"
        # Volume ubi0_0 MUST NOT be treated as another UBI device.
        printf '400\n' > "$base/sys/ubi0_0/ro_mode"
        printf '2\n' > "$base/sys/ubi0/max_ec"
        printf '0\n' > "$base/sys/ubi0/bad_peb_count"
        case "$ro_value" in
            missing) : ;;
            unreadable) ln -s "$base/nonexistent" "$base/sys/ubi0/ro_mode" ;;
            *) printf '%s\n' "$ro_value" > "$base/sys/ubi0/ro_mode" ;;
        esac
    fi
    if [ "$device_count" -gt 1 ]; then
        mkdir -p "$base/sys/ubi1" "$base/sys/ubi1_0"
        printf '12\n' > "$base/sys/ubi1/max_ec"
        printf '7\n' > "$base/sys/ubi1/bad_peb_count"
        printf '1\n' > "$base/sys/ubi1/ro_mode"
    fi

    DOCTOR_UBI_ROOT="$base/sys"
    MOUNTS_SRC="$mounts"
    N_OK=0; N_INFO=0; N_WARN=0; N_FAIL=0
    info() { N_INFO=$((N_INFO+1)); printf '[INFO] %s\n' "$1"; }
    ok() { N_OK=$((N_OK+1)); printf '[OK] %s\n' "$1"; }
    warn() { N_WARN=$((N_WARN+1)); printf '[WARN] %s\n' "$1"; }
    fail() { N_FAIL=$((N_FAIL+1)); printf '[FAIL] %s\n' "$1"; }

    . "$WORK/functions.sh"
    _doc_report_ubi_health > "$base/report"

    [ "$N_OK" -eq "$expected_ok" ] &&
    [ "$N_WARN" -eq "$expected_warn" ] &&
    [ "$N_FAIL" -eq "$expected_fail" ] || {
        cat "$base/report"
        echo "[FAIL] $case_name counts $N_OK/$N_WARN/$N_FAIL; expected $expected_ok/$expected_warn/$expected_fail" >&2
        exit 1
    }

    if grep -q 'UBI ubi0_0:' "$base/report"; then
        echo "[FAIL] volume ubi0_0 reported as a UBI device" >&2; exit 1
    fi
    if [ "$device_count" -gt 0 ]; then
        grep -q 'UBI ubi0: max_ec=2;' "$base/report"
    fi
    if [ "$opt_kind" = external ]; then
        grep -q '/storage mount: source=/dev/ubi0_0; filesystem=ubifs' "$base/report"
    fi
    printf '[OK] %s\n' "$case_name"
)

run_case "kn1012-external" external 0 1 0 0 1
run_case "kn1012-internal" internal 0 1 0 0 1
run_case "kn1010-external" external 0 1 0 0 1
run_case "read-only-failure" internal 1 0 0 1 1
run_case "bad-blocks-and-read-only-second-device" internal 0 1 0 1 2
run_case "invalid-ro" internal not-a-number 0 1 0 1
run_case "missing-ro" internal missing 0 1 0 1
run_case "unreadable-ro" internal unreadable 0 1 0 1
run_case "without-ubi-but-ubifs-mounted" internal 0 0 1 0 0
run_case "without-ubi-no-ubifs" absent 0 0 0 0 0
echo "[OK] Doctor NAND/UBI read-only diagnostics fixtures PASS"
