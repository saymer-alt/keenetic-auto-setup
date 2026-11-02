#!/bin/sh
# Host laboratory only: preflight before real opkg can initialize its database.
# Trusted project-built packages only; this is NOT a sandbox for package hooks.
set -eu
umask 077
fail() { echo "KAS_CORE_PREFLIGHT: $*" >&2; exit 1; }
[ "$#" -eq 4 ] || fail 'usage: ROOT VERIFIED_OPKG install ABSOLUTE_IPK | ROOT VERIFIED_OPKG remove kas-core'
ROOT=$1
OPKG=$2
action=$3
target=$4
[ "$(id -u)" = 0 ] || fail 'root required for offline ownership qualification'
case "$ROOT" in /*) ;; *) fail 'absolute offline root required';; esac
canonical=$(CDPATH= cd -- "$ROOT" 2>/dev/null && pwd -P) || fail 'offline root must exist'
[ "$canonical" != / ] && [ "$canonical" = "$ROOT" ] || fail 'live root, alias or symlink ancestor refused'
case "$ROOT" in *[!A-Za-z0-9_./-]*) fail 'lab root contains unsupported characters';; esac
safe_path() {
    [ ! -L "$1" ] || fail 'symlink refused before opkg'
    if [ -e "$1" ]; then
        [ -f "$1" ] || [ -d "$1" ] || fail 'nonregular path refused'
        metadata=$(LC_ALL=C ls -ldn "$1") || fail 'cannot read path metadata'
        set -- $metadata
        [ "$3" = 0 ] && [ "$4" = 0 ] || fail 'non-root path refused'
        case "$1" in ?????w????|????????w?) fail 'writable path refused';; esac
    fi
}
for path in "$ROOT" "$ROOT/opt" "$ROOT/opt/lib" "$ROOT/opt/lib/opkg" \
    "$ROOT/opt/lib/opkg/info" "$ROOT/opt/lib/opkg/lists" "$ROOT/opt/lib/opkg/status" "$ROOT/opt/tmp"; do
    safe_path "$path"
done
if [ -d "$ROOT/opt/lib/opkg" ]; then
    anomalous=$(find "$ROOT/opt/lib/opkg" ! -type d ! -type f -print) || fail 'cannot inspect database'
    [ -z "$anomalous" ] || fail 'nonregular database member refused before opkg'
    members=$(find "$ROOT/opt/lib/opkg" -print) || fail 'cannot inspect database members'
    printf '%s\n' "$members" | while IFS= read -r path; do
        case "$path" in *[!A-Za-z0-9_./+-]*) fail 'unsupported database filename';; esac
        safe_path "$path"
    done || fail 'unsafe database metadata'
fi
case "$action:$target" in
    install:/*) safe_path "$target"; [ -f "$target" ] || fail 'package missing';;
    remove:kas-core) ;;
    *) fail 'only fixed install or remove kas-core operations are supported';;
esac
case "$OPKG" in /*) ;; *) fail 'absolute verified opkg path required';; esac
safe_path "$OPKG"
[ -f "$OPKG" ] && [ -x "$OPKG" ] || fail 'opkg unavailable'
actual=$(sha256sum "$OPKG" | awk '{print $1}')
[ "$actual" = 08c8feb2ef3153f025ba687f8df02adf915e4252a3605cc6798f8d105162cb38 ] || fail 'unexpected host Entware opkg binary'
# Everything above is read-only. Fixed arguments below cannot be overridden by
# caller-supplied opkg flags or an inherited package-hook offline-root variable.
unset IPKG_INSTROOT PKG_ROOT
lock="$ROOT/.kas-core-opkg.lock"
mkdir "$lock" 2>/dev/null || fail 'offline-root transaction busy; inspect stale lock manually'
work=""
cleanup() {
    [ -z "$work" ] || rm -rf "$work"
    rmdir "$lock" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
work=$(mktemp -d "$ROOT/.kas-core-opkg.XXXXXX") || fail 'cannot create private work directory'
mkdir "$work/tmp"
printf 'dest root /\narch all 100\n' > "$work/opkg.conf"
result=0
"$OPKG" -f "$work/opkg.conf" --offline-root "$ROOT" --force-postinstall \
    --tmp-dir "$work/tmp" "$action" "$target" || result=$?
exit "$result"
