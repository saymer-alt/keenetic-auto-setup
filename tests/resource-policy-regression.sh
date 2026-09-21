#!/bin/sh
# Focused regression fixtures for the resource-profile policy in install.sh.
# This does not emulate KeeneticOS: it extracts the production policy block and
# feeds it read-only fixture files for meminfo, mounts and swaps.
set -eu

ROOT=${1:-.}
INSTALL="$ROOT/install.sh"
TMP="${TMPDIR:-/tmp}/keenetic-resource-policy.$$"

fail() { echo "[FAIL] $1" >&2; exit 1; }
pass() { echo "[OK] $1"; }
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/sys-empty"

awk '
    /^RESOURCE_PROFILE_CONTRACT_VERSION=/ { copy=1 }
    /^# REQUIRED KEENETICOS COMPONENT PREFLIGHT/ { copy=0 }
    copy { print }
' "$INSTALL" > "$TMP/policy.sh"

grep -q '^RESOURCE_PROFILE_CONTRACT_VERSION=' "$TMP/policy.sh" ||
    fail "could not extract resource policy from install.sh"
grep -q '^MEMINFO=' "$TMP/policy.sh" ||
    fail "install.sh resource policy must support fixture meminfo input"

cat > "$TMP/mounts-external" <<'EOF'
/dev/sda2 /opt ext4 rw 0 0
EOF

cat > "$TMP/mounts-internal" <<'EOF'
ubi0_0 /opt ubifs rw 0 0
EOF

cat > "$TMP/mem-128" <<'EOF'
MemTotal:         131072 kB
SwapTotal:             0 kB
SwapFree:              0 kB
EOF

cat > "$TMP/mem-256" <<'EOF'
MemTotal:         254472 kB
SwapTotal:             0 kB
SwapFree:              0 kB
EOF

cat > "$TMP/swaps-oversize" <<'EOF'
Filename                                Type            Size    Used    Priority
/dev/sda1                               partition       2200000 0       -1
EOF

cat > "$TMP/swaps-128-enough" <<'EOF'
Filename                                Type            Size    Used    Priority
/dev/sda1                               partition       393216  0       -1
EOF

cat > "$TMP/swaps-128-small" <<'EOF'
Filename                                Type            Size    Used    Priority
/dev/sda1                               partition       300000  0       -1
EOF

cat > "$TMP/swaps-zram-plus-disk" <<'EOF'
Filename                                Type            Size    Used    Priority
/dev/zram0                              partition       262140  0       100
/dev/sda1                               partition       479996  0       -1
EOF

run_policy() {
    _mem=$1
    _mounts=$2
    _swaps=$3
    _out=$4

    (
        set -e
        INSTALL_MEMINFO="$_mem"
        INSTALL_MOUNTS="$_mounts"
        INSTALL_SWAPS="$_swaps"
        INSTALL_SYS_CLASS_BLOCK="$TMP/sys-empty"

        log()  { echo "[setup] $1"; }
        warn() { echo "[WARN] $1"; }
        err()  { echo "[ERROR] $1"; exit 1; }

        . "$TMP/policy.sh"
    ) >"$_out" 2>&1
}

expect_reject() {
    _name=$1
    _mem=$2
    _mounts=$3
    _swaps=$4
    _needle=$5
    _out="$TMP/out-reject"

    if run_policy "$_mem" "$_mounts" "$_swaps" "$_out"; then
        cat "$_out" >&2
        fail "$_name: policy unexpectedly accepted fixture"
    fi
    grep -Fq "$_needle" "$_out" || {
        cat "$_out" >&2
        fail "$_name: expected rejection text not found"
    }
    pass "$_name"
}

expect_accept() {
    _name=$1
    _mem=$2
    _mounts=$3
    _swaps=$4
    _needle=$5
    _out="$TMP/out-accept"

    if ! run_policy "$_mem" "$_mounts" "$_swaps" "$_out"; then
        cat "$_out" >&2
        fail "$_name: policy unexpectedly rejected fixture"
    fi
    grep -Fq "$_needle" "$_out" || {
        cat "$_out" >&2
        fail "$_name: expected accepted-state text not found"
    }
    pass "$_name"
}

expect_reject     "external swap above 2 GiB is a hard install reject"     "$TMP/mem-256" "$TMP/mounts-external" "$TMP/swaps-oversize"     "External storage-backed SWAP exceeds the 2 GiB project/vendor cap"

expect_reject     "128 MB profile rejects internal /opt even with enough external swap"     "$TMP/mem-128" "$TMP/mounts-internal" "$TMP/swaps-128-enough"     "/opt is on INTERNAL storage"

expect_reject     "128 MB profile rejects external swap below the 384 MB floor"     "$TMP/mem-128" "$TMP/mounts-external" "$TMP/swaps-128-small"     "required at least 384 MB on external storage"

expect_accept     "128 MB profile accepts the exact 384 MB external-swap floor as experimental"     "$TMP/mem-128" "$TMP/mounts-external" "$TMP/swaps-128-enough"     "LOW-RAM / BEST-EFFORT INSTALL"

expect_accept     "zRAM plus external swap continues but emits the coexistence warning"     "$TMP/mem-256" "$TMP/mounts-external" "$TMP/swaps-zram-plus-disk"     "zRAM and external storage-backed swap are active together"

echo "[OK] Resource policy regression fixtures passed"
