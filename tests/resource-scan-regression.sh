#!/bin/sh
# Regression for a real KN-1010 failure: install.sh uses global set -e, so
# scan_swap_backends must not return the status of its final false [ ... ] test.
# Keep this narrow: extract the production scanner and run only read-only fixtures.
set -eu

ROOT=${1:-.}
INSTALL="$ROOT/install.sh"
TMP="${TMPDIR:-/tmp}/keenetic-resource-scan.$$"

fail() { echo "[FAIL] $1" >&2; exit 1; }
pass() { echo "[OK] $1"; }
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/sys-empty"

awk '
    /^# classify_mount SOURCE FSTYPE/ { copy=1 }
    /^MEM_TOTAL_KB=/ { copy=0 }
    copy { print }
' "$INSTALL" > "$TMP/scanner.sh"

grep -q '^scan_swap_backends()' "$TMP/scanner.sh" ||
    fail "could not extract scan_swap_backends from install.sh"

cat > "$TMP/mounts" <<'EOF'
/dev/sda2 /opt ext4 rw 0 0
EOF

run_case() {
    _name=$1
    _swaps=$2
    _ext=$3
    _deleted_count=$4
    _deleted_kb=$5

    (
        set -e
        SYS_CLASS_BLOCK="$TMP/sys-empty"
        PROC_MOUNTS="$TMP/mounts"
        PROC_SWAPS="$_swaps"
        SWAP_MAX_KB=2097152
        . "$TMP/scanner.sh"

        # This call itself is the regression: under set -e it must return 0
        # for ordinary non-fatal states, including no swap at all.
        scan_swap_backends

        [ "$SW_EXT_KB" -eq "$_ext" ]
        [ "$SW_DELETED_COUNT" -eq "$_deleted_count" ]
        [ "$SW_DELETED_KB" -eq "$_deleted_kb" ]
        [ "$SW_EXT_OVERSIZE" -eq 0 ]
    ) || fail "$_name: scanner returned non-zero or classified the fixture incorrectly"

    pass "$_name"
}

cat > "$TMP/swaps-none" <<'EOF'
Filename                                Type            Size    Used    Priority
EOF
run_case "no swap backend remains non-fatal under set -e" "$TMP/swaps-none" 0 0 0

cat > "$TMP/swaps-normal" <<'EOF'
Filename                                Type            Size    Used    Priority
/dev/sda1                               partition       479996  0       -1
EOF
run_case "normal external swap below 2 GiB remains non-fatal under set -e" "$TMP/swaps-normal" 479996 0 0

cat > "$TMP/swaps-deleted" <<'EOF'
Filename                                Type            Size    Used    Priority
/dev/sda1\040(deleted)                  partition       1048572 0       -1
/dev/sdb1                               partition       479996  0       -2
EOF
run_case "deleted swap is ignored without poisoning function status" "$TMP/swaps-deleted" 479996 1 1048572

echo "[OK] Resource scanner set -e regression passed"
