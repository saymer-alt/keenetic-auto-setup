# Qualification only: never allow this prototype to install on the live root.
ROOT=${IPKG_INSTROOT:-${PKG_ROOT:-}}
ROOT=${ROOT%/}
deny() { echo "kas-core LAB: $*" >&2; exit 1; }
case "$ROOT" in /*) ;; *) deny 'offline-root is required; live installation is blocked';; esac
canonical=$(CDPATH= cd -- "$ROOT" 2>/dev/null && pwd -P) || deny 'offline-root must exist'
[ "$canonical" != / ] || deny 'live installation is blocked, including root aliases'
[ "$canonical" = "$ROOT" ] || deny 'offline-root must be canonical without symlink ancestors'
[ "$(id -u)" = 0 ] || deny 'root ownership required'
LIB="$ROOT/opt/libexec/kas"
META="$ROOT/opt/share/kas-core"
INFO="$ROOT/opt/lib/opkg/info"
LIST="$INFO/kas-core.list"
SUMS="$INFO/kas-core.md5sums"
for path in "$ROOT" "$ROOT/opt" "$ROOT/opt/libexec" "$LIB" "$ROOT/opt/share" "$META" \
    "$ROOT/opt/lib" "$ROOT/opt/lib/opkg" "$INFO"; do
    [ ! -L "$path" ] || deny 'symlink directory refused'
    if [ -e "$path" ]; then
        [ -d "$path" ] || deny 'non-directory parent refused'
        metadata=$(ls -ldn "$path") || deny 'unreadable directory metadata'
        set -- $metadata
        [ "$3" = 0 ] && [ "$4" = 0 ] || deny 'non-root directory refused'
        case "$1" in d????w????|d???????w?) deny 'writable parent directory refused';; esac
    fi
done
owned_bundle() {
    [ -f "$LIST" ] && [ ! -L "$LIST" ] && [ -f "$SUMS" ] && [ ! -L "$SUMS" ] || return 1
    grep -Fxq '/opt/share/kas-core/BUILD_INFO' "$LIST" || return 1
    [ -f "$META/BUILD_INFO" ] && [ ! -L "$META/BUILD_INFO" ] || return 1
    grep -Fxq 'KAS_CORE_LAB_ONLY=1' "$META/BUILD_INFO" || return 1
}
validate_bundle() {
    owned_bundle || deny 'missing package ownership or incomplete bundle'
    # opkg's recorded md5sums is an installed-file baseline, not an authenticity
    # signature. SHA256SUMS separately checks the declared source payload.
    awk 'NF != 2 || length($1) != 32 || $1 ~ /[^0-9a-f]/ || $2 !~ /^opt\/(libexec\/kas\/[A-Za-z0-9_.-]+|share\/kas-core\/(BUILD_INFO|SHA256SUMS|scripts.json|LICENSE|watchdog-history.tsv))$/ {bad=1} END {exit bad || NR == 0}' "$SUMS" || deny 'invalid ownership baseline'
    [ -d "$LIB" ] && [ -d "$META" ] || deny 'incomplete bundle directories'
    [ -z "$(find "$LIB" "$META" ! -type d ! -type f -print)" ] || deny 'nonregular bundle member refused'
    actual=$(find "$LIB" "$META" -type f -print | while IFS= read -r file; do printf '%s\n' "${file#"$ROOT"/}"; done | LC_ALL=C sort)
    expected=$(awk '{print $2}' "$SUMS" | LC_ALL=C sort)
    [ "$actual" = "$expected" ] || deny 'added or missing bundle file'
    (cd "$ROOT" && md5sum -c "$SUMS" >/dev/null 2>&1) || deny 'modified bundle file; preserved'
    (cd "$ROOT" && sha256sum -c "$META/SHA256SUMS" >/dev/null 2>&1) || deny 'bundle SHA256 mismatch'
    for path in "$LIB"/* "$META"/*; do
        metadata=$(ls -ldn "$path") || deny 'unreadable file metadata'
        set -- $metadata
        [ "$3" = 0 ] && [ "$4" = 0 ] || deny 'non-root bundle file refused'
        case "$path" in "$LIB"/*) [ "$1" = -rwxr-xr-x ] || deny 'changed script mode';;
            *) [ "$1" = -rw-r--r-- ] || deny 'changed metadata mode';; esac
    done
}
