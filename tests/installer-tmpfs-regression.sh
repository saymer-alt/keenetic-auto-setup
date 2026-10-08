#!/bin/sh
# KAS-01: executable presence alone is not active tmpfs protection.
# No real mounts, root access or router mutation required.
set -eu

ROOT=.
if [ "$#" -gt 0 ]; then ROOT=$1; fi
INSTALL="$ROOT/install.sh"
TMP=$(mktemp -d /tmp/kas-tmpfs.XXXXXX) || exit 1
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
fail() { echo "[FAIL] $1" >&2; exit 1; }
pass() { echo "[OK] $1"; }

# Run functions extracted from the current production installer.
awk '
    /^installer_tmpfs_service_enabled\(\) \{/ { copy=1 }
    copy { print }
    /^# END INSTALLER TMPFS PROTECTION v1/ { exit }
' "$INSTALL" > "$TMP/activation.sh"
awk '
    /^project_script_candidate_ok\(\) \{/ { copy=1 }
    copy { print }
    copy && /^}/ { exit }
' "$INSTALL" > "$TMP/validator.sh"
grep -q '^installer_tmpfs_activate()' "$TMP/activation.sh" || fail "missing activation function"
grep -q '^installer_tmpfs_protection_ready()' "$TMP/activation.sh" || fail "missing readiness function"
grep -q '^project_script_candidate_ok()' "$TMP/validator.sh" || fail "missing candidate validator"
. "$TMP/activation.sh"
. "$TMP/validator.sh"
grep -Fq 'if installer_tmpfs_protection_ready "$S00_SCRIPT" "$S00_ROOT" "$PROC_MOUNTS"; then' "$INSTALL" ||
    fail "final verdict must check live protection"
grep -Fq 'installer_tmpfs_activate "$S00_SCRIPT" "$S00_ROOT" "$PROC_MOUNTS"' "$INSTALL" ||
    fail "RAM install must activate and verify protection"

OPT="$TMP/opt"
SVC="$OPT/etc/init.d/S00ubifs"
MOUNTS="$TMP/mounts"
GOOD_MOUNTS="$TMP/full-mounts"
FRESH="$TMP/fresh-service"
mkdir -p "$OPT/etc/init.d" "$OPT/tmp" "$OPT/var/log" "$OPT/var/run"
{
    printf 'ubi0_0 %s ubifs rw 0 0\n' "$OPT"
    for d in "$OPT/tmp" "$OPT/var/log" "$OPT/var/run"; do
        printf 'tmpfs %s tmpfs rw 0 0\n' "$d"
    done
} > "$GOOD_MOUNTS"

cat > "$FRESH" <<'EOF'
#!/bin/sh
ENABLED=yes
[ "$1" = start ] || exit 9
case "$MOCK_START_MODE" in
    mount) cp "$MOCK_GOOD_MOUNTS" "$MOCK_MOUNTS" ;;
    partial) grep -v '/var/log ' "$MOCK_GOOD_MOUNTS" > "$MOCK_MOUNTS" ;;
    wrong-fs) sed 's|/var/run tmpfs |/var/run ubifs |' "$MOCK_GOOD_MOUNTS" > "$MOCK_MOUNTS" ;;
    no-op) : ;;
    failure) exit 1 ;;
    *) exit 9 ;;
esac
EOF
chmod +x "$FRESH"
MOCK_GOOD_MOUNTS="$GOOD_MOUNTS"
MOCK_MOUNTS="$MOUNTS"
export MOCK_GOOD_MOUNTS MOCK_MOUNTS

project_script_download() {
    [ "$MOCK_DOWNLOAD" != fail ] || return 1
    cp "$FRESH" "$2"
}
log() { :; }
warn() { :; }
err() { echo "[ERROR] $1" >&2; exit 1; }
reset_mounts() { printf 'ubi0_0 %s ubifs rw 0 0\n' "$OPT" > "$MOUNTS"; }
old_copy() { cp "$FRESH" "$SVC"; chmod +x "$SVC"; }
run_activate() {
    (
        MOCK_DOWNLOAD="$1"
        MOCK_START_MODE="$2"
        export MOCK_DOWNLOAD MOCK_START_MODE
        installer_tmpfs_activate "$SVC" "$OPT" "$MOUNTS"
    ) > "$TMP/output" 2>&1
}
expect_good() {
    run_activate "$1" "$2" || { cat "$TMP/output" >&2; fail "$3"; }
    installer_tmpfs_protection_ready "$SVC" "$OPT" "$MOUNTS" || fail "$3 readiness"
    pass "$3"
}
expect_bad() {
    if run_activate "$1" "$2"; then fail "$3 unexpectedly succeeded"; fi
    pass "$3"
}

reset_mounts
rm -f "$SVC"
expect_good success mount "fresh service mounts all three tmpfs"

reset_mounts
old_copy
cp "$SVC" "$TMP/before"
expect_good fail mount "download failure starts valid existing service"
cmp -s "$SVC" "$TMP/before" || fail "fallback changed existing service"

reset_mounts
rm -f "$SVC"
expect_bad fail mount "download failure without service is fatal"

reset_mounts
old_copy
sed -i 's/^ENABLED=yes$/ENABLED=no/' "$SVC"
expect_bad fail mount "disabled existing service is rejected"

reset_mounts
old_copy
chmod -x "$SVC"
expect_bad fail mount "non-executable existing service is rejected"

reset_mounts
old_copy
expect_bad fail no-op "successful start without mounts is fatal"

reset_mounts
expect_bad success partial "missing log tmpfs is fatal"

reset_mounts
expect_bad success wrong-fs "non-tmpfs run mount is fatal"

reset_mounts
expect_bad success failure "service start error is fatal"

reset_mounts
old_copy
cp "$GOOD_MOUNTS" "$MOUNTS"
installer_tmpfs_protection_ready "$SVC" "$OPT" "$MOUNTS" || fail "healthy live mounts rejected"
reset_mounts
if installer_tmpfs_protection_ready "$SVC" "$OPT" "$MOUNTS"; then
    fail "final check accepts stale script without mounts"
fi
pass "final predicate follows live mount state"
echo "[OK] KAS-01 installer RAM protection regression passed"
