#!/bin/sh
# Focused Doctor regression for Entware mount reporting and internal-flash protection.
set -eu

ROOT=${1:-.}
DOCTOR="$ROOT/mihomo-doctor.sh"
TMP="${TMPDIR:-/tmp}/keenetic-doctor-storage.$$"

fail_test() { echo "[FAIL] $1" >&2; exit 1; }
pass() { echo "[OK] $1"; }
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP"

awk '
    /^_doc_classify_mount\(\) \{/ { copy=1 }
    copy { print }
    /^# END DOCTOR STORAGE PROTECTION v1/ { exit }
' "$DOCTOR" > "$TMP/storage.sh"

grep -q '^_doc_resolve_mount()' "$TMP/storage.sh" || fail_test "could not extract Doctor storage resolver"
grep -q '^_doc_check_internal_flash_protection()' "$TMP/storage.sh" || fail_test "could not extract Doctor internal-flash check"

run_internal() {
    _case=$1
    _missing=${2:-}
    _enabled=${3:-yes}
    _root="$TMP/$_case/opt"
    _mounts="$TMP/$_case/mounts"
    mkdir -p "$_root/etc/init.d" "$_root/tmp" "$_root/var/log" "$_root/var/run"
    cat > "$_root/etc/init.d/S00ubifs" <<EOF
#!/bin/sh
ENABLED=$_enabled
EOF
    chmod +x "$_root/etc/init.d/S00ubifs"

    {
        echo "ubi0_0 $_root ubifs rw 0 0"
        [ "$_missing" = tmp ] || echo "tmpfs $_root/tmp tmpfs rw 0 0"
        [ "$_missing" = log ] || echo "tmpfs $_root/var/log tmpfs rw 0 0"
        [ "$_missing" = run ] || echo "tmpfs $_root/var/run tmpfs rw 0 0"
    } > "$_mounts"

    (
        OPT_ROOT="$_root"
        MOUNTS_SRC="$_mounts"
        N_OK=0
        N_FAIL=0
        ok() { N_OK=$((N_OK+1)); echo "[OK] $1"; }
        fail() { N_FAIL=$((N_FAIL+1)); echo "[FAIL] $1"; }
        info() { echo "[INFO] $1"; }
        . "$TMP/storage.sh"

        _doc_resolve_mount "$OPT_ROOT"
        [ "$DOC_MOUNT_SOURCE" = ubi0_0 ]
        [ "$DOC_MOUNTPOINT" = "$OPT_ROOT" ]
        [ "$DOC_MOUNT_FSTYPE" = ubifs ]
        [ "$DOC_MOUNT_CLASS" = internal ]

        _doc_check_internal_flash_protection

        case "$_case" in
            protected)
                [ "$N_OK" -eq 2 ] && [ "$N_FAIL" -eq 0 ]
                ;;
            missing-log)
                [ "$N_OK" -eq 1 ] && [ "$N_FAIL" -eq 1 ]
                ;;
            disabled)
                [ "$N_OK" -eq 1 ] && [ "$N_FAIL" -eq 1 ]
                ;;
            *) exit 9 ;;
        esac
    ) || fail_test "$_case fixture did not produce expected Doctor storage result"
    pass "$_case"
}

run_internal protected
run_internal missing-log log
run_internal disabled "" no

_ext_root="$TMP/external/opt"
_ext_mounts="$TMP/external/mounts"
mkdir -p "$_ext_root"
echo "/dev/sda2 $_ext_root ext4 rw 0 0" > "$_ext_mounts"
(
    OPT_ROOT="$_ext_root"
    MOUNTS_SRC="$_ext_mounts"
    . "$TMP/storage.sh"
    _doc_resolve_mount "$OPT_ROOT"
    [ "$DOC_MOUNT_SOURCE" = /dev/sda2 ]
    [ "$DOC_MOUNTPOINT" = "$OPT_ROOT" ]
    [ "$DOC_MOUNT_FSTYPE" = ext4 ]
    [ "$DOC_MOUNT_CLASS" = external ]
) || fail_test "external Entware mount classification failed"
pass "external mount details"

echo "[OK] Doctor Entware storage / internal-flash protection regression passed"
