#!/bin/sh
# Minimal KAS exit: remove only the two Entware packages, not KeeneticOS state.
# Intentionally no transaction, rollback cache, journal, snapshot or purge.
set -u
export LC_ALL=C

if [ "$#" -ne 0 ]; then
    echo "Usage: sh uninstall-packages.sh" >&2
    exit 2
fi

if ! command -v opkg >/dev/null 2>&1; then
    echo "[ERROR] Entware opkg is unavailable; nothing changed" >&2
    exit 1
fi
installed=$(opkg list-installed 2>/dev/null) || {
    echo "[ERROR] Cannot query installed packages; nothing changed" >&2
    exit 1
}

echo "[INFO] Removing only Entware packages mihomo and magitrickle."
echo "[WARN] This is NOT full KAS cleanup: KeeneticOS ProxyN/policies, Netfilter hook,"
echo "[WARN] DNS, watchdog/cron and other files can remain. Routing may stop working."
echo "[WARN] OPKG may remove package configuration files. Save YAML first if needed."

failed=0
for pkg in mihomo magitrickle; do
    if printf '%s\n' "$installed" | grep -q "^$pkg - "; then
        printf '[REMOVE] %s\n' "$pkg"
        if opkg remove "$pkg"; then
            printf '[OK] %s removed through OPKG\n' "$pkg"
        else
            printf '[ERROR] %s was not removed; inspect OPKG output\n' "$pkg" >&2
            failed=1
        fi
    else
        printf '[SKIP] %s is not installed\n' "$pkg"
    fi
done

if [ "$failed" -ne 0 ]; then
    echo "[PARTIAL] One or more package removals failed. No automatic retry or rollback." >&2
    exit 1
fi

echo "[PARTIAL] Entware package removal done. KeeneticOS/KAS remnants were not removed."
echo "[INFO] Do not format an Entware drive unless ALL its data can be discarded."
