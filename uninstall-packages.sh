#!/bin/sh
# Minimal KAS exit: remove only the two Entware packages, not KeeneticOS state.
# Intentionally no transaction, rollback cache, journal, snapshot or purge.
set -u
export LC_ALL=C

# Optional explicit modes; the default is ordinary stop + package removal.
ROOT=${KAS_UNINSTALL_TEST_ROOT:-}
CLEANUP=0
PURGE=0
for arg in "$@"; do
    case "$arg" in
        --cleanup) CLEANUP=1 ;;
        --purge-config) PURGE=1 ;;
        --help|-h) echo 'Usage: sh uninstall-packages.sh [--cleanup] [--purge-config]'; exit 0 ;;
        *) echo 'Usage: sh uninstall-packages.sh [--cleanup] [--purge-config]' >&2; exit 2 ;;
    esac
done
# Only disposable, marked test roots are allowed; no arbitrary root override.
if [ -n "$ROOT" ]; then
    case "$ROOT" in /tmp/kas-uninstall-test-*) ;; *) exit 2 ;; esac
    [ ! -L "$ROOT" ] &&
        [ "$(cat "$ROOT/.kas-uninstall-test" 2>/dev/null)" = KAS_UNINSTALL_TEST_V1 ] || exit 2
fi

if ! command -v opkg >/dev/null 2>&1; then
    echo "[ERROR] Entware opkg is unavailable; nothing changed" >&2
    exit 1
fi
installed=$(opkg list-installed 2>/dev/null) || {
    echo "[ERROR] Cannot query installed packages; nothing changed" >&2
    exit 1
}

# Protect the user's two YAML files before touching OPKG or any service.
# This is only a small file copy, not a transaction or IPK rollback system.
BACKUP=''
if [ "$PURGE" -eq 0 ]; then
    for cfg in "$ROOT/opt/etc/mihomo/config.yaml" "$ROOT/opt/var/lib/magitrickle/config.yaml"; do
        [ -e "$cfg" ] || [ -L "$cfg" ] || continue
        [ -f "$cfg" ] && [ ! -L "$cfg" ] ||
            { echo "[ERROR] Unsafe YAML path: $cfg" >&2; exit 1; }
        if [ -z "$BACKUP" ]; then
            mkdir -p "$ROOT/opt/var" || exit 1
            BACKUP=$(umask 077; mktemp -d "$ROOT/opt/var/kas-yaml.XXXXXX") || exit 1
        fi
        case "$cfg" in */etc/mihomo/*) name=mihomo ;; *) name=magitrickle ;; esac
        cp -p "$cfg" "$BACKUP/$name.yaml" && cmp -s "$cfg" "$BACKUP/$name.yaml" ||
            { echo "[ERROR] YAML safety copy failed; no service stopped" >&2; exit 1; }
    done
    [ -z "$BACKUP" ] || echo "[SAVED] YAML copies: $BACKUP"
fi

# Remove only the recognized KAS cron schedule. Preserve unrelated run-parts.
wrapper="$ROOT/opt/etc/cron.5mins/mihomo_watchdog"
cron="$ROOT/opt/etc/crontab"
if [ -e "$wrapper" ] || [ -L "$wrapper" ]; then
    if [ -L "$wrapper" ] || [ ! -f "$wrapper" ] ||
       ! { [ "$(cat "$wrapper")" = "$(printf '#!/bin/sh\nexec /opt/bin/mihomo_watchdog.sh "$@"\n')" ] ||
           grep -q 'MIHOMO WATCHDOG SCRIPT' "$wrapper"; }; then
        echo '[ERROR] Unknown watchdog wrapper; nothing removed' >&2; exit 1
    fi
fi
if [ -e "$cron" ] || [ -L "$cron" ]; then
    [ -f "$cron" ] && [ ! -L "$cron" ] ||
        { echo '[ERROR] Shared crontab is unsafe; nothing removed' >&2; exit 1; }
    tmp=$(mktemp "$ROOT/opt/etc/.kas-uncron.XXXXXX") || exit 1
    cp -p "$cron" "$tmp" || { rm -f "$tmp"; exit 1; }
    if ! awk '
      {x=$0; gsub(/^[ \t]+|[ \t]+$/, "", x); gsub(/[ \t]+/, " ", x)
       if (x=="*/5 * * * * root /bin/sh /opt/etc/cron.5mins/mihomo_watchdog" ||
           x=="*/5 * * * * root /opt/etc/cron.5mins/mihomo_watchdog" ||
           x=="*/5 * * * * root /bin/sh /opt/bin/mihomo_watchdog.sh" ||
           x=="*/5 * * * * root /opt/bin/mihomo_watchdog.sh") next
       if (x !~ /^#/ && index(x,"mihomo_watchdog")) bad=1
       print
      } END {if(bad) exit 1}' "$cron" > "$tmp"; then
        rm -f "$tmp"; echo '[ERROR] Unknown active watchdog cron line; nothing removed' >&2; exit 1
    fi
    if ! cmp -s "$cron" "$tmp"; then
        mv -f "$tmp" "$cron" || exit 1
        if [ -x "$ROOT/opt/etc/init.d/S10cron" ]; then
            "$ROOT/opt/etc/init.d/S10cron" restart ||
                echo '[WARN] Cron restart failed; verify scheduler' >&2
        fi
    else rm -f "$tmp"; fi
fi
if [ -e "$wrapper" ]; then
    rm -f "$wrapper" || { echo '[ERROR] Cannot remove watchdog cron wrapper' >&2; exit 1; }
fi
wd="$ROOT/opt/bin/mihomo_watchdog.sh"
if [ -f "$wd" ] && [ ! -L "$wd" ] &&
   grep -q 'MIHOMO WATCHDOG SCRIPT' "$wd"; then
    rm -f "$wd" || { echo '[ERROR] Cannot disable watchdog file; packages retained' >&2; exit 1; }
elif [ -e "$wd" ] || [ -L "$wd" ]; then
    echo '[WARN] Unknown watchdog binary kept' >&2
fi

# The cron entry is gone, but a watchdog launched just before removal may
# still be executing. It owns this existing per-run lock until it finishes.
# Wait for it before stopping Mihomo; NEVER remove or steal a live/stale lock.
wd_lock="$ROOT/tmp/mihomo_watchdog.lock.d"
if [ -e "$wd_lock" ] || [ -L "$wd_lock" ]; then
    [ -d "$wd_lock" ] && [ ! -L "$wd_lock" ] ||
        { echo '[ERROR] Unsafe watchdog lock; packages retained' >&2; exit 1; }
    wd_wait=0
    wd_max=30
    [ -z "$ROOT" ] || wd_max=2
    while [ -d "$wd_lock" ] && [ "$wd_wait" -lt "$wd_max" ]; do
        sleep 1
        wd_wait=$((wd_wait+1))
    done
    if [ -e "$wd_lock" ] || [ -L "$wd_lock" ]; then
        echo '[ERROR] Watchdog run still active or lock stale; packages retained. Check /tmp/mihomo_watchdog.lock.d' >&2
        exit 1
    fi
fi

# Stop with native init.d. Never kill by name. Leave a still-running package.
stop_native() {
    pkg="$1"
    daemon="$2"
    init="$ROOT/opt/etc/init.d/S99$pkg"
    if [ -L "$init" ]; then
        echo "[ERROR] $pkg init is a symlink; package retained" >&2; return 1
    fi
    if [ -f "$init" ]; then
        # Some Entware init scripts check ENABLED before dispatching 'stop'.
        # Stop FIRST, while the script is still enabled; then disable boot start.
        if [ -x "$init" ]; then
            "$init" stop || echo "[WARN] $pkg stop returned error; checking process" >&2
        fi
        if grep -qx 'ENABLED=yes' "$init"; then
            tmp=$(mktemp "$ROOT/opt/etc/init.d/.kas-init.XXXXXX") || return 1
            if ! cp -p "$init" "$tmp" ||
               ! sed 's/^ENABLED=yes$/ENABLED=no/' "$init" > "$tmp" ||
               ! mv -f "$tmp" "$init"; then
                rm -f "$tmp"
                echo "[ERROR] Cannot disable $pkg autostart" >&2; return 1
            fi
        fi
    fi
    n=0
    while pidof "$daemon" >/dev/null 2>&1 && [ "$n" -lt 4 ]; do
        sleep 1; n=$((n+1))
    done
    if pidof "$daemon" >/dev/null 2>&1; then
        echo "[ERROR] $daemon still running; $pkg package retained" >&2; return 1
    fi
    return 0
}
ready_mihomo=0
ready_magitrickle=0
if command -v pidof >/dev/null 2>&1; then
    if printf '%s\n' "$installed" | grep -q '^mihomo - '; then
        stop_native mihomo mihomo && ready_mihomo=1
    fi
    if printf '%s\n' "$installed" | grep -q '^magitrickle - '; then
        stop_native magitrickle magitrickled && ready_magitrickle=1
    fi
else
    echo '[ERROR] pidof unavailable; packages retained' >&2
fi

echo "[INFO] Removing only Entware packages mihomo and magitrickle."
echo "[WARN] Router ProxyN/policies/DNS and live Netfilter rules are not modified."
echo "[WARN] Shared and unknown resources are retained; routing may need manual cleanup."
echo "[INFO] YAML preserved by default. Use --purge-config only to discard it."

failed=0
for pkg in mihomo magitrickle; do
    if printf '%s\n' "$installed" | grep -q "^$pkg - "; then
        printf '[REMOVE] %s\n' "$pkg"
        case "$pkg" in
            mihomo) [ "$ready_mihomo" -eq 1 ] || { echo "[ERROR] Mihomo not stopped" >&2; failed=1; continue; } ;;
            magitrickle) [ "$ready_magitrickle" -eq 1 ] || { echo "[ERROR] MagiTrickle not stopped" >&2; failed=1; continue; } ;;
        esac
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


# OPKG may delete conffiles. Restore from safety copies, retaining copies too.
if [ -n "$BACKUP" ]; then
    for pair in 'mihomo:etc/mihomo/config.yaml' 'magitrickle:var/lib/magitrickle/config.yaml'; do
        name=${pair%%:*}; rel=${pair#*:}
        source="$BACKUP/$name.yaml"
        target="$ROOT/opt/$rel"
        [ -f "$source" ] || continue
        if [ ! -e "$target" ] && [ ! -L "$target" ]; then
            mkdir -p "${target%/*}" && cp -p "$source" "$target" ||
                { echo "[ERROR] Could not restore $target; copy at $source" >&2; failed=1; }
        elif ! cmp -s "$source" "$target"; then
            echo "[ERROR] YAML changed during removal; prior copy at $source" >&2; failed=1
        fi
    done
fi
if [ "$PURGE" -eq 1 ]; then
    after=$(opkg list-installed 2>/dev/null) || { echo '[ERROR] OPKG recheck failed' >&2; exit 1; }
    for pair in 'mihomo:etc/mihomo/config.yaml' 'magitrickle:var/lib/magitrickle/config.yaml'; do
        pkg=${pair%%:*}; rel=${pair#*:}; target="$ROOT/opt/$rel"
        if ! printf '%s\n' "$after" | grep -q "^$pkg - " &&
           [ -f "$target" ] && [ ! -L "$target" ]; then
            rm -f "$target" || failed=1
        fi
    done
fi

# Separate opt-in file cleanup, limited to resources recorded as KAS-created.
if [ "$CLEANUP" -eq 1 ] && [ "$failed" -eq 0 ]; then
    ledger="$ROOT/opt/etc/keenetic-auto-setup/ownership.v1"
    if [ -f "$ledger" ] && [ ! -L "$ledger" ]; then
        for item in 'repository:magitrickle.conf:etc/opkg/magitrickle.conf' 'hook:020-bypass_wa.sh:etc/ndm/netfilter.d/020-bypass_wa.sh'; do
            kind=${item%%:*}; rest=${item#*:}; claim=${rest%%:*}; rel=${rest#*:}
            path="$ROOT/opt/$rel"
            grep -Fqx "owned|$kind|$claim" "$ledger" || continue
            if [ -L "$path" ]; then
                echo "[WARN] Symlink preserved: $path" >&2; continue
            fi
            [ -f "$path" ] || continue
            if [ "$kind" = hook ]; then
                grep -Fq 'chain="_CUST_BYPASS_WA_"' "$path" ||
                    { echo "[WARN] Modified hook preserved: $path" >&2; continue; }
            fi
            rm -f "$path" || failed=1
        done
    fi
fi
echo '[WARN] KeeneticOS ProxyN/policy/DNS and live Netfilter rules remain unchanged.'
echo '[INFO] Inspect them with: sh uninstall.sh --plan'

if [ "$failed" -ne 0 ]; then
    echo "[PARTIAL] One or more package removals failed. No automatic retry or rollback." >&2
    exit 1
fi

echo "[OK] Entware package removal finished; KeeneticOS state is separate."
echo "[INFO] Do not format an Entware drive unless ALL its data can be discarded."
