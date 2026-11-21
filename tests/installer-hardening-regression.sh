#!/bin/sh
# Negative regressions for the installer hardening blocks transferred from
# Draft #258 without the RCI token stack:
#   1. kas_trusted_directory must reject unsafe /opt layouts before the
#      Netfilter hook delivery (symlink substitution, writable or foreign
#      components, traversal, missing/non-directory components).
#   2. project_script_candidate_ok must fail closed when a digest pin is set:
#      no digest computation, no acceptance. Without a pin the validator keeps
#      the legacy behavior (shebang + sh -n only).
#   3. The Netfilter hook delivery must reuse an existing hook without a
#      second download only when it is a regular executable file in the
#      trusted directory whose sha256 matches the pinned installer revision;
#      every miss (wrong digest, symlink, unsafe directory, missing file)
#      falls back to the download chain and stays fail-closed when the
#      transports are unreachable.
# The positive probe path is covered by tests/bypass-provenance-regression.sh
# in Draft #258. Offline host test: dash and BusyBox ash; no hardware claim.
set -eu
ROOT=${1:-.}
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail() { echo "FAIL: $1" >&2; exit 1; }
expect_fail() {
    # expect_fail <label> <command...>: nonzero exit is required
    label=$1; shift
    if "$@" 2>/dev/null; then fail "$label unexpectedly succeeded"; fi
}

# --- 1. trusted directory negatives -----------------------------------------
if [ ! -x /bin/busybox ]; then
    # Host without BusyBox: point the block's /opt fallback at a shim that
    # executes the applet from PATH (readlink/ls/awk exist on the host).
    printf '#!/bin/sh\ncmd=$1\nshift\nexec "$cmd" "$@"\n' > "$TMP/busybox-shim"
    chmod +x "$TMP/busybox-shim"
    BB_SED=";s|/opt/bin/busybox|$TMP/busybox-shim|"
else
    BB_SED=""
fi
sed -n '/^# BEGIN KAS TRUSTED DIRECTORY$/,/^# END KAS TRUSTED DIRECTORY$/p' \
        "$ROOT/install.sh" |
    sed "s|^    kas_parent=$|    kas_parent=$TMP|;s|-v owner=0|-v owner=$(id -u)|g$BB_SED" \
    > "$TMP/blocks"
[ -s "$TMP/blocks" ] || fail "trusted directory block not found in install.sh"
# shellcheck disable=SC1090
. "$TMP/blocks"

opt=$TMP/opt
mkdir -p "$opt/etc/hooks"
printf '#!/bin/sh\n' > "$opt/etc/hooks/hook"
chmod 755 "$opt/etc/hooks"

# Positive control: a clean user-owned tree passes so negatives are meaningful.
kas_trusted_directory "$opt/etc/hooks" "$opt" ||
    fail "positive control rejected a clean tree"

expect_fail "path outside /opt" kas_trusted_directory "$TMP/outside/x" "$opt"
expect_fail "missing component" kas_trusted_directory "$opt/etc/missing" "$opt"
expect_fail "traversal component" kas_trusted_directory "$opt/etc/../evil" "$opt"

chmod 777 "$opt/etc" 2>/dev/null || true
# Some hosts (MSYS/NTFS) silently keep the old mode; only assert what stuck.
if kas_busybox ls -ldn "$opt/etc" 2>/dev/null | kas_busybox awk 'NR==1 { exit !(substr($1,6,1)=="w" || substr($1,9,1)=="w") }'; then
    expect_fail "group/world-writable component" kas_trusted_directory "$opt/etc/hooks" "$opt"
else
    echo "[SKIP] writable-component case: host chmod cannot open the mode; covered on Linux CI"
fi
chmod 755 "$opt/etc" 2>/dev/null || true

mv "$opt/etc" "$opt/real-etc"
# MSYS ln -s copies by default; force native symlinks where possible.
MSYS=winsymlinks:nativestrict ln -s real-etc "$opt/etc" 2>/dev/null || ln -s real-etc "$opt/etc" 2>/dev/null || true
if [ -L "$opt/etc" ]; then
    expect_fail "symlinked component" kas_trusted_directory "$opt/etc/hooks" "$opt"
else
    echo "[SKIP] symlink-component case: host ln -s cannot create symlinks; covered on Linux CI"
fi
rm -rf "$opt/etc"
mv "$opt/real-etc" "$opt/etc"

mkdir -p "$opt/etc2"
printf 'not a directory\n' > "$opt/etc2/hooks"
expect_fail "regular file as directory component" kas_trusted_directory "$opt/etc2/hooks" "$opt"

# Symlinked /opt resolves to the real tree: the validator returns the physical
# path, so a caller-side equality check ("Entware root changed") must fire.
mkdir -p "$TMP/real/etc"
MSYS=winsymlinks:nativestrict ln -s real "$TMP/link" 2>/dev/null || ln -s real "$TMP/link" 2>/dev/null || true
if [ -L "$TMP/link" ]; then
    kas_trusted_directory "$TMP/link/etc" "$TMP/link" ||
        fail "validator failed on a resolvable symlinked root"
    [ "$kas_trusted_path" = "$TMP/link/etc" ] &&
        fail "symlinked root was not re-anchored to the physical path"
    [ "$kas_trusted_path" = "$TMP/real/etc" ] || fail "unexpected re-anchored path"
    echo "[OK] symlinked root re-anchored to the physical path"
else
    echo "[SKIP] symlinked-root re-anchor case: host ln -s cannot create symlinks"
fi
echo "[OK] trusted directory negatives (outside/missing/traversal/writable/symlink/file/dir-masquerade/re-anchor)"

# --- 2. digest fail-closed unit cases ----------------------------------------
sed -n '/^project_script_candidate_ok() {/,/^}/p' "$ROOT/install.sh" > "$TMP/validator.sh"
[ -s "$TMP/validator.sh" ] || fail "candidate validator not found in install.sh"
# shellcheck disable=SC1090
. "$TMP/validator.sh"

printf '#!/bin/sh\necho revision-a\n' > "$TMP/rev-a"
printf '#!/bin/sh\necho revision-b\n' > "$TMP/rev-b"
sha_a=$(sha256sum < "$TMP/rev-a"); sha_a=${sha_a%% *}
sha_b=$(sha256sum < "$TMP/rev-b"); sha_b=${sha_b%% *}

project_script_candidate_ok "$TMP/rev-a" || fail "legacy validator rejected a valid script"
project_script_candidate_ok "$TMP/rev-a" "$sha_a" || fail "digest-matching candidate rejected"
expect_fail "digest mismatch" project_script_candidate_ok "$TMP/rev-b" "$sha_a"
expect_fail "wrong-revision valid script" project_script_candidate_ok "$TMP/rev-a" "$sha_b"

sha256sum() { return 127; }
expect_fail "missing sha256sum with pin set" project_script_candidate_ok "$TMP/rev-a" "$sha_a"
project_script_candidate_ok "$TMP/rev-a" ||
    fail "legacy validator depends on sha256sum without a pin"
unset -f sha256sum
echo "[OK] digest fail-closed unit cases (match/mismatch/wrong-revision/no-sha256sum/no-pin-legacy)"

# --- 3. pinned bypass hook reuse ---------------------------------------------
# The delivery block itself is extracted from install.sh, so the regressions
# exercise the real call-site branch, not a copy of it.
sed -n '/^project_script_reuse_pinned() {/,/^}/p' "$ROOT/install.sh" > "$TMP/reuse.sh"
[ -s "$TMP/reuse.sh" ] || fail "pinned-reuse helper not found in install.sh"
# shellcheck disable=SC1090
. "$TMP/reuse.sh"

printf '#!/bin/sh\necho hook-revision\n' > "$TMP/hook-rev"
hook_sha=$(sha256sum < "$TMP/hook-rev"); hook_sha=${hook_sha%% *}
printf '#!/bin/sh\necho hook-other-revision\n' > "$TMP/hook-other"

cp "$TMP/hook-rev" "$TMP/reuse-good"; chmod +x "$TMP/reuse-good"
project_script_reuse_pinned "$TMP/reuse-good" "$hook_sha" ||
    fail "pinned reuse rejected a matching executable hook"
cp "$TMP/hook-other" "$TMP/reuse-wrong"; chmod +x "$TMP/reuse-wrong"
expect_fail "reuse of a wrong-digest hook" project_script_reuse_pinned "$TMP/reuse-wrong" "$hook_sha"
expect_fail "reuse without a digest pin" project_script_reuse_pinned "$TMP/reuse-good" ""
expect_fail "reuse of a non-executable hook" project_script_reuse_pinned "$TMP/hook-rev" "$hook_sha"
expect_fail "reuse of a missing hook" project_script_reuse_pinned "$TMP/reuse-absent" "$hook_sha"
expect_fail "reuse of a directory" project_script_reuse_pinned "$TMP/opt" "$hook_sha"
MSYS=winsymlinks:nativestrict ln -s reuse-good "$TMP/reuse-link" 2>/dev/null ||
    ln -s reuse-good "$TMP/reuse-link" 2>/dev/null || true
if [ -L "$TMP/reuse-link" ]; then
    expect_fail "reuse of a symlinked hook" project_script_reuse_pinned "$TMP/reuse-link" "$hook_sha"
else
    echo "[SKIP] reuse symlink case: host ln -s cannot create symlinks; covered on Linux CI"
fi
sha256sum() { return 127; }
expect_fail "reuse without sha256sum while a pin is set" project_script_reuse_pinned "$TMP/reuse-good" "$hook_sha"
unset -f sha256sum
echo "[OK] pinned reuse unit cases (match/wrong-digest/no-pin/non-executable/missing/directory/symlink/no-sha256sum)"

for _f in status_out log warn err retry_silent project_script_candidate_ok \
        project_script_reuse_pinned project_script_transfer \
        project_script_curl_retry project_script_download; do
    awk -v fn="$_f" '
        index($0, fn "() {") == 1 { p = 1; print; if ($0 ~ /\}$/) p = 0; next }
        p { print; if ($0 ~ /^}$/) p = 0 }
    ' "$ROOT/install.sh" >> "$TMP/funcs.sh"
done
[ -s "$TMP/funcs.sh" ] || fail "project script functions not found in install.sh"
sh -n "$TMP/funcs.sh" || fail "extracted project script functions are not valid shell"
# shellcheck disable=SC1090
. "$TMP/funcs.sh"

awk '
    index($0, "kas_trusted_directory /opt/etc /opt || err") == 1 { p = 1 }
    p && $0 ~ /No verified bypass hook from the installer revision/ { e = 1 }
    p && e && /^fi$/ { print; exit }
    p && index($0, "# On a first install, the KeeneticOS proxy configuration") == 1 { exit }
    p { print }
' "$ROOT/install.sh" | sed "s|/opt|$TMP/opt|g" > "$TMP/callsite.sh"
[ -s "$TMP/callsite.sh" ] || fail "bypass hook delivery block not found in install.sh"
[ "$(wc -l < "$TMP/callsite.sh")" -lt 100 ] ||
    fail "hook delivery block extraction overshot the block boundaries"
sh -n "$TMP/callsite.sh" || fail "extracted hook delivery block is not valid shell"

kas_ledger_record() { printf '%s\n' "$*" >> "$TMP/ledger"; }
COLOR_GREEN=; COLOR_YELLOW=; COLOR_RED=; COLOR_RESET=
TMP_DIR=$TMP
PROJECT_REF="reuse-test"
PROJECT_RAW_BASE="https://reuse-test.invalid/raw"
PROJECT_API_CONTENTS="https://reuse-test.invalid/api/contents"
KAS_BYPASS_HOOK_SHA256=$hook_sha
opt=$TMP/opt
mkdir -p "$opt/etc/ndm/netfilter.d"
chmod 755 "$opt" "$opt/etc" "$opt/etc/ndm" "$opt/etc/ndm/netfilter.d"
hook_path=$opt/etc/ndm/netfilter.d/020-bypass_wa.sh

# curl and wget shims count every transport attempt and fail like a refused
# connection, so the delivery runs offline and its attempts stay measurable.
mkdir -p "$TMP/bin"
printf '#!/bin/sh\necho attempt >> "%s"\nexit 7\n' "$TMP/attempts" > "$TMP/bin/curl"
cp "$TMP/bin/curl" "$TMP/bin/wget"
chmod +x "$TMP/bin/curl" "$TMP/bin/wget"

run_delivery() {
    rc=0
    (
        PATH="$TMP/bin:$PATH"
        export PATH
        # shellcheck disable=SC1090
        . "$TMP/callsite.sh"
    ) || rc=$?
    return "$rc"
}

# Matching executable hook plus unreachable transports: no download attempt,
# existing bytes preserved, no ownership journal for an existing file.
rm -f "$hook_path"
cp "$TMP/hook-rev" "$hook_path"; chmod +x "$hook_path"
hook_before=$(sha256sum < "$hook_path"); hook_before=${hook_before%% *}
: > "$TMP/attempts"; : > "$TMP/ledger"
run_delivery ||
    fail "pinned hook reuse failed with unreachable transports"
hook_after=$(sha256sum < "$hook_path"); hook_after=${hook_after%% *}
[ "$hook_before" = "$hook_after" ] || fail "reused hook was modified by delivery"
[ ! -s "$TMP/attempts" ] || fail "pinned hook reuse attempted a download"
[ ! -s "$TMP/ledger" ] || fail "reused hook was journaled as newly installed"
echo "[OK] pinned hook reuse skips re-download with unreachable transports"

# Wrong digest plus unreachable transports: the download chain must be tried
# and the delivery must fail closed with the existing hook left untouched.
rm -f "$hook_path"
cp "$TMP/hook-other" "$hook_path"; chmod +x "$hook_path"
hook_before=$(sha256sum < "$hook_path"); hook_before=${hook_before%% *}
: > "$TMP/attempts"; : > "$TMP/ledger"
run_delivery && fail "wrong-digest hook did not fail closed on unreachable transports"
hook_after=$(sha256sum < "$hook_path"); hook_after=${hook_after%% *}
[ "$hook_before" = "$hook_after" ] || fail "failed delivery modified the existing hook"
[ -s "$TMP/attempts" ] || fail "wrong-digest hook did not try the download chain"
[ ! -s "$TMP/ledger" ] || fail "failed delivery journaled a hook it never installed"
echo "[OK] wrong-digest hook falls back to downloads and fails closed"

# Missing hook plus unreachable transports: fail closed without leftovers.
rm -f "$hook_path"
: > "$TMP/attempts"; : > "$TMP/ledger"
run_delivery && fail "missing hook did not fail closed on unreachable transports"
[ ! -e "$hook_path" ] || fail "failed delivery left a hook behind"
[ -s "$TMP/attempts" ] || fail "missing hook did not try the download chain"
[ ! -s "$TMP/ledger" ] || fail "failed delivery journaled a hook it never installed"
echo "[OK] missing hook with unreachable transports fails closed without leftovers"

# Symlink at the hook path: refused before delivery, no transport attempts.
rm -f "$hook_path"
MSYS=winsymlinks:nativestrict ln -s "$TMP/hook-rev" "$hook_path" 2>/dev/null ||
    ln -s "$TMP/hook-rev" "$hook_path" 2>/dev/null || true
if [ -L "$hook_path" ]; then
    : > "$TMP/attempts"; : > "$TMP/ledger"
    run_delivery && fail "symlinked hook path was accepted"
    [ ! -s "$TMP/attempts" ] || fail "symlinked hook path reached the download chain"
    echo "[OK] symlinked hook path refused before delivery"
else
    echo "[SKIP] delivery symlink case: host ln -s cannot create symlinks; covered on Linux CI"
fi
rm -f "$hook_path"

# A pin-matching hook in an unsafe (world-writable) trusted directory must
# not be reused: the directory guard refuses before delivery starts.
cp "$TMP/hook-rev" "$hook_path"; chmod +x "$hook_path"
hook_before=$(sha256sum < "$hook_path"); hook_before=${hook_before%% *}
chmod 777 "$opt/etc/ndm/netfilter.d" 2>/dev/null || true
if kas_busybox ls -ldn "$opt/etc/ndm/netfilter.d" 2>/dev/null |
        kas_busybox awk 'NR==1 { exit !(substr($1,6,1)=="w" || substr($1,9,1)=="w") }'; then
    : > "$TMP/attempts"; : > "$TMP/ledger"
    run_delivery && fail "pin-matching hook in an unsafe directory was accepted"
    [ ! -s "$TMP/attempts" ] || fail "unsafe directory reached the download chain"
    hook_after=$(sha256sum < "$hook_path"); hook_after=${hook_after%% *}
    [ "$hook_before" = "$hook_after" ] || fail "unsafe-directory refusal modified the hook"
    echo "[OK] pin-matching hook in an unsafe directory refused"
else
    echo "[SKIP] unsafe-directory case: host chmod cannot open the mode; covered on Linux CI"
fi
chmod 755 "$opt/etc/ndm/netfilter.d" 2>/dev/null || true
rm -f "$hook_path"

echo "[OK] installer hardening regression passed"
