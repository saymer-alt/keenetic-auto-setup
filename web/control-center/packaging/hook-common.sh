# opkg uses IPKG_INSTROOT for offline installations. Never run host services there.
# Current Entware opkg exports PKG_ROOT; older ipkg uses IPKG_INSTROOT.
ROOT=${IPKG_INSTROOT:-${PKG_ROOT:-}}
ROOT=${ROOT%/}
case "$ROOT" in ''|/*) ;; *) echo 'invalid offline root' >&2; exit 1;; esac
OPT="$ROOT/opt"
INIT="$OPT/etc/init.d/S98kas-control-center"
MARKER='# KAS-CONTROL-CENTER-IPK-v1'
deny() { echo "kas-control-center: $*" >&2; exit 1; }
check_dirs() {
    for d in "$OPT" "$OPT/bin" "$OPT/etc" "$OPT/etc/init.d" "$OPT/lib" "$OPT/lib/opkg" "$OPT/lib/opkg/info" "$OPT/share" "$OPT/share/kas-control-center"; do
        [ ! -L "$d" ] || deny "unsafe symlink directory: $d"
    done
}
package_owned() {
    list="$OPT/lib/opkg/info/kas-control-center.list"
    [ -f "$list" ] && [ ! -L "$list" ] || return 1
    [ -f "$INIT" ] && [ ! -L "$INIT" ] || return 1
    grep -Fxq "$MARKER" "$INIT" || return 1
    grep -Fxq '/opt/bin/kas-control-center' "$list" &&
        grep -Fxq '/opt/etc/init.d/S98kas-control-center' "$list" &&
        grep -Fxq '/opt/share/kas-control-center/BUILD_INFO' "$list" &&
        grep -Fxq '/opt/share/kas-control-center/THIRD_PARTY_NOTICES' "$list"
}
check_dirs
