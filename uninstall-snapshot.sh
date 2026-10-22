#!/bin/sh
# KAS pre-uninstall snapshot. Never stops services or changes router settings.
# A READY snapshot is a prerequisite for a future transactional --remove.
set -eu
umask 077

mode=${1:---check}
[ "$#" -le 1 ] || { echo "Usage: sh uninstall-snapshot.sh [--check|--create]" >&2; exit 2; }
case "$mode" in
    --check|--create) ;;
    *) echo "Usage: sh uninstall-snapshot.sh [--check|--create]" >&2; exit 2 ;;
esac

# Only for mocked regression fixtures; never passed as a shell command.
root=${KAS_SNAPSHOT_ROOT:-}
case "$root" in
    '') ;;
    /*) [ "$root" != / ] || { echo "[BLOCKED] invalid root" >&2; exit 3; } ;;
    *) echo "[BLOCKED] root must be absolute" >&2; exit 3 ;;
esac

owner_dir="$root/opt/etc/keenetic-auto-setup"
ledger="$owner_dir/ownership.v1"
fail() { printf '[BLOCKED] %s\n' "$1" >&2; exit 3; }
regular() { [ -f "$1" ] && [ ! -L "$1" ]; }
[ ! -L "$root/opt" ] || fail "/opt is a symlink"
[ ! -L "$owner_dir" ] || fail "ownership directory is a symlink"
regular "$ledger" || fail "missing, unreadable or linked ownership.v1"
[ -r "$ledger" ] || fail "ownership.v1 unreadable"
[ "$(head -n 1 "$ledger")" = KAS_OWNERSHIP_V1 ] || fail "ownership ledger version mismatch"
awk '
  NR==1 { next }
  /^owned[|]proxy[|]Proxy[0-9]+$/ { valid=1 }
  /^owned[|]policy[|]bypass_wa$/ { valid=1 }
  /^enabled[|]dns[|]intercept$/ { valid=1 }
  /^owned[|]package[|](mihomo|magitrickle)$/ { valid=1 }
  /^owned[|]repository[|]magitrickle.conf$/ { valid=1 }
  /^owned[|]hook[|]020-bypass_wa.sh$/ { valid=1 }
  /^owned[|]watchdog[|](binary|wrapper)$/ { valid=1 }
  /^owned[|]service[|]S00ubifs$/ { valid=1 }
  { if (!valid || seen[$0]++) exit 1; valid=0 }
' "$ledger" || fail "invalid or repeated ownership record"

# Prevent a torn copy while installer, updater or importer is active.
# A future removal operation must additionally acquire the canonical lifecycle lock.
for busy in "$root/tmp/mihomo-lifecycle.lock.d" "$root/tmp/mihomo.maintenance"; do
    [ ! -e "$busy" ] && [ ! -L "$busy" ] || fail "Mihomo lifecycle/maintenance is busy"
done

# Source paths are FIXED; neither the ledger nor user input supplies a path.
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
for item in $items; do
    f="$root$item"
    [ ! -L "$f" ] || fail "symlink in source: $item"
    if [ -e "$f" ]; then
        regular "$f" && [ -r "$f" ] || fail "invalid or unreadable source: $item"
    fi
done

# A journal-owned package may lose its YAML during OPKG removal.
for pkg in mihomo magitrickle; do
    if grep -Fqx "owned|package|$pkg" "$ledger"; then
        case "$pkg" in
            mihomo) yaml="$root/opt/etc/mihomo/config.yaml" ;;
            magitrickle) yaml="$root/opt/var/lib/magitrickle/config.yaml" ;;
        esac
        regular "$yaml" && [ -r "$yaml" ] || fail "owned package has no safely readable YAML: $pkg"
    fi
done

command -v ndmc >/dev/null 2>&1 || fail "ndmc not found"
command -v iptables >/dev/null 2>&1 || fail "iptables not found"
command -v opkg >/dev/null 2>&1 || fail "opkg not found"

# Capture required router evidence before making any backup directory.
rc=$(ndmc -c 'show running-config' 2>/dev/null | tr -d '\r') || fail "cannot read running-config"
printf '%s\n' "$rc" | grep -q '^interface ' || fail "invalid running-config"
policy=$(ndmc -c 'show ip policy' 2>/dev/null) || fail "cannot read policy state"
mangle=$(iptables -t mangle -S 2>/dev/null) || fail "cannot read live mangle rules"
packages=$(opkg list-installed 2>/dev/null) || fail "cannot inventory installed packages"
[ -n "$mangle" ] && [ -n "$packages" ] || fail "incomplete system evidence"

if [ "$mode" = --check ]; then
    printf '[PASS] ownership, configuration files and live read-only inventory verified\n'
    printf '[INFO] No files created or settings changed\n'
    exit 0
fi

parent="$root/opt/kas-uninstall-backups"
[ ! -L "$parent" ] || fail "backup parent is a symlink"
[ ! -e "$parent" ] || [ -d "$parent" ] || fail "backup parent is not a directory"
if [ ! -d "$parent" ]; then
    mkdir -m 700 "$parent" || fail "cannot create private backup parent"
fi
chmod 700 "$parent" || fail "cannot protect backup parent"
stamp=$(date +%Y%m%d-%H%M%S) || fail "cannot get date"
snap="$parent/$stamp-$$"
(umask 077; mkdir -m 700 "$snap") || fail "cannot create unique private snapshot"
manifest="$snap/manifest.v1"
printf 'KAS_UNINSTALL_SNAPSHOT_V1\n' > "$manifest"
chmod 600 "$manifest"

for item in $items; do
    src="$root$item"
    if [ -f "$src" ]; then
        dest="$snap/files$item"
        mkdir -p "${dest%/*}" || fail "cannot make backup directory for $item (incomplete snapshot retained)"
        cp -p "$src" "$dest" || fail "cannot copy $item (incomplete snapshot retained)"
        chmod 600 "$dest" || fail "cannot secure $item (incomplete snapshot retained)"
        cmp -s "$src" "$dest" || fail "copy verification failed for $item (incomplete snapshot retained)"
        printf 'copied|%s\n' "$item" >> "$manifest"
    else
        printf 'absent|%s\n' "$item" >> "$manifest"
    fi
done

printf '%s\n' "$rc" > "$snap/running-config"
printf '%s\n' "$policy" > "$snap/ip-policy"
printf '%s\n' "$mangle" > "$snap/iptables-mangle"
printf '%s\n' "$packages" > "$snap/opkg-packages"
chmod 600 "$snap/running-config" "$snap/ip-policy" "$snap/iptables-mangle" "$snap/opkg-packages" ||
    fail "cannot protect router evidence (incomplete snapshot retained)"
cmp -s "$ledger" "$snap/files/opt/etc/keenetic-auto-setup/ownership.v1" ||
    fail "ownership journal changed (incomplete snapshot retained)"
for busy in "$root/tmp/mihomo-lifecycle.lock.d" "$root/tmp/mihomo.maintenance"; do
    [ ! -e "$busy" ] && [ ! -L "$busy" ] ||
        fail "maintenance started during snapshot (incomplete snapshot retained)"
done
printf 'READY\n' > "$snap/READY"
chmod 600 "$snap/READY" || fail "cannot protect READY marker"
printf '[PASS] Private, verified pre-uninstall snapshot created: %s\n' "$snap"
printf '[INFO] Configs and router evidence may contain secrets; keep directory private\n'
printf '[INFO] No services stopped, packages removed or Keenetic settings changed\n'