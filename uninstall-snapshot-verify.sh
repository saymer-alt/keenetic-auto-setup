#!/bin/sh
# Verify a KAS uninstall snapshot independently before any future removal.
# Strictly read-only. Snapshot names, never paths, are accepted.
set -eu
export LC_ALL=C

[ "$#" -eq 1 ] || { echo "Usage: sh uninstall-snapshot-verify.sh SNAPSHOT_NAME" >&2; exit 2; }
name=$1
case "$name" in
    ''|*[!0-9-]*|*-|-*|*--*|*..*) echo "[BLOCKED] invalid snapshot name" >&2; exit 3 ;;
esac
printf '%s\n' "$name" | grep -Eq '^[0-9]{8}-[0-9]{6}-[0-9]+$' ||
    { echo "[BLOCKED] invalid snapshot name" >&2; exit 3; }

root=${KAS_SNAPSHOT_ROOT:-}
case "$root" in
    '') ;;
    /*) [ "$root" != / ] || { echo "[BLOCKED] invalid fixture root" >&2; exit 3; } ;;
    *) echo "[BLOCKED] invalid fixture root" >&2; exit 3 ;;
esac
parent="$root/opt/kas-uninstall-backups"
snap="$parent/$name"
fail() { printf '[BLOCKED] %s\n' "$1" >&2; exit 3; }
private_dir() {
    [ -d "$1" ] && [ ! -L "$1" ] || fail "missing or linked directory"
    _mode=$(ls -ld "$1" 2>/dev/null | cut -c1-10) || fail "cannot inspect permissions"
    [ "$_mode" = drwx------ ] || fail "backup directory permissions not private"
}
private_file() {
    [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ] || fail "missing, unreadable or linked snapshot file"
    _mode=$(ls -ld "$1" 2>/dev/null | cut -c1-10) || fail "cannot inspect permissions"
    [ "$_mode" = -rw------- ] || fail "snapshot file permissions not private"
}
[ ! -L "$root/opt" ] || fail "linked /opt"
private_dir "$parent"
private_dir "$snap"
private_file "$snap/READY"
[ "$(cat "$snap/READY")" = READY ] || fail "missing READY marker"
private_file "$snap/manifest.v1"
[ "$(head -n 1 "$snap/manifest.v1")" = KAS_UNINSTALL_SNAPSHOT_V1 ] ||
    fail "unsupported manifest version"

items='/opt/etc/keenetic-auto-setup/ownership.v1
/opt/etc/mihomo/config.yaml
/opt/var/lib/magitrickle/config.yaml
/opt/etc/crontab
/opt/etc/ndm/netfilter.d/020-bypass_wa.sh
/opt/etc/cron.5mins/mihomo_watchdog
/opt/bin/mihomo_watchdog.sh
/opt/etc/opkg/magitrickle.conf
/opt/etc/init.d/S99mihomo
/opt/etc/init.d/S99magitrickle'

# Exactly ten entries in the canonical order, no unknown paths or duplicates.
expected=$(printf 'KAS_UNINSTALL_SNAPSHOT_V1\n')
count=0
for item in $items; do
    src="$root$item"
    dest="$snap/files$item"
    status=absent
    if [ -e "$src" ] || [ -L "$src" ]; then
        [ -f "$src" ] && [ ! -L "$src" ] && [ -r "$src" ] ||
            fail "source missing, linked or not regular"
        status=copied
    fi
    # The manifest indicates what was copied at snapshot time; source and
    # copy must agree now to qualify as a FRESH recovery point.
    entry=$(sed -n "$((count+2))p" "$snap/manifest.v1") || fail "unreadable manifest"
    [ "$entry" = "$status|$item" ] || fail "manifest mismatch or source changed"
    if [ "$status" = copied ]; then
        dir=${dest%/*}
        while [ "$dir" != "$snap" ]; do
            private_dir "$dir"
            dir=${dir%/*}
        done
        private_file "$dest"
        cmp -s "$src" "$dest" || fail "snapshot copy differs from live source"
    else
        [ ! -e "$dest" ] && [ ! -L "$dest" ] ||
            fail "unexpected snapshot file for absent source"
    fi
    count=$((count+1))
done
[ "$(wc -l < "$snap/manifest.v1")" -eq "$((count+1))" ] ||
    fail "extra manifest records"

for f in running-config ip-policy iptables-mangle opkg-packages; do
    private_file "$snap/$f"
done
# The future transaction MUST acquire a lifecycle lock and rerun these gates
# inside that lock. This independent verification is not a lock.
for marker in "$root/tmp/mihomo-lifecycle.lock.d" "$root/tmp/mihomo.maintenance"; do
    [ ! -e "$marker" ] && [ ! -L "$marker" ] ||
        fail "Mihomo lifecycle/maintenance marker active"
done
command -v ndmc >/dev/null 2>&1 || fail "ndmc unavailable"
command -v iptables >/dev/null 2>&1 || fail "iptables unavailable"
command -v opkg >/dev/null 2>&1 || fail "opkg unavailable"
rc=$(ndmc -c 'show running-config' 2>/dev/null | tr -d '\r') ||
    fail "running-config read failed"
printf '%s\n' "$rc" | grep -q '^interface ' ||
    fail "unverifiable running-config"
printf '%s\n' "$rc" | cmp -s - "$snap/running-config" ||
    fail "running-config changed since snapshot"
policy=$(ndmc -c 'show ip policy' 2>/dev/null) ||
    fail "policy read failed"
printf '%s\n' "$policy" | cmp -s - "$snap/ip-policy" ||
    fail "policy changed since snapshot"
mangle=$(iptables -t mangle -S 2>/dev/null) ||
    fail "mangle read failed"
printf '%s\n' "$mangle" | cmp -s - "$snap/iptables-mangle" ||
    fail "mangle changed since snapshot"
pkgs=$(opkg list-installed 2>/dev/null) ||
    fail "package inventory failed"
printf '%s\n' "$pkgs" | cmp -s - "$snap/opkg-packages" ||
    fail "packages changed since snapshot"
printf '[PASS] Snapshot verified and current: %s\n' "$name"
printf '[INFO] No files, services or router settings changed; remove still blocked\n'