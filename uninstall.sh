#!/bin/sh
# Keenetic Auto-Setup read-only uninstall preflight (phase 1).
# An old installation has no durable ownership ledger: signatures are not
# proof that a ProxyN, policy, package, hook or file belongs only to KAS.
set -u

usage() {
    cat <<'TEXT'
KAS uninstall — read-only first stage
  sh uninstall.sh --check    Inspect packages, files and Keenetic routing.
  sh uninstall.sh --help     Display this help.
--remove and --purge are blocked until project ownership can be verified.
Details: docs/23-uninstall.md
TEXT
}
MODE=${1:---check}
case "$MODE" in
    --help|-h) usage; exit 0 ;;
    --check) [ "$#" -le 1 ] || { usage >&2; exit 2; } ;;
    --remove|--purge) [ "$#" -eq 1 ] || { usage >&2; exit 2; } ;;
    *) usage >&2; exit 2 ;;
esac

# Test fixture prefix for read-only probes only. Never writes anywhere.
ROOT=${KAS_AUDIT_ROOT:-}
case "$ROOT" in
    '') ;;
    /*) [ "$ROOT" != '/' ] || { printf '[ERROR] Bad audit root\n' >&2; exit 2; } ;;
    *) printf '[ERROR] Audit root must be absolute\n' >&2; exit 2 ;;
esac
report() { printf '[%s] %s — %s\n' "$1" "$2" "$3"; }
probe() {
    _f="$ROOT$1"
    if [ -L "$_f" ]; then
        report UNKNOWN "$1" 'symbolic link: never follow automatically'
    elif [ ! -e "$_f" ]; then
        report ABSENT "$1" 'not found'
    elif [ ! -f "$_f" ]; then
        report UNKNOWN "$1" 'not a regular file'
    elif [ "$2" = shared ]; then
        report SHARED_OR_FOREIGN "$1" 'user or package data: preserve'
    else
        report UNKNOWN "$1" 'possible project artifact; exclusive ownership unproven'
    fi
}

printf '[KAS uninstall] READ-ONLY inventory; nothing will be removed or stopped.\n'
# Recognize creation-only V1 ownership claims. Parsing is data-only; never source
# the file as shell code. Ledger is evidence for later review, not permission to
# tear down a shared interface or package.
LEDGER_VALID=0
ledger_check() {
    _dir="$ROOT/opt/etc/keenetic-auto-setup"
    _file="$_dir/ownership.v1"
    if [ -L "$_dir" ] || [ -L "$_file" ]; then
        report UNKNOWN ledger 'symbolic link; refuse to trust it'
        return
    fi
    if [ ! -e "$_file" ]; then
        report UNKNOWN ledger 'absent: legacy installation cannot be removed automatically'
        return
    fi
    if [ ! -f "$_file" ] || [ ! -r "$_file" ]; then
        report UNKNOWN ledger 'not a readable regular file'
        return
    fi
    if [ "$(head -n 1 "$_file" 2>/dev/null)" != KAS_OWNERSHIP_V1 ]; then
        report UNKNOWN ledger 'unknown version or damaged header'
        return
    fi
    if ! awk '
        NR == 1 { next }
        /^owned[|]proxy[|]Proxy[0-9]+$/ { next }
        /^owned[|]policy[|]bypass_wa$/ { next }
        /^enabled[|]dns[|]intercept$/ { next }
        /^owned[|]package[|](mihomo|magitrickle)$/ { next }
        /^owned[|]repository[|]magitrickle.conf$/ { next }
        /^owned[|]hook[|]020-bypass_wa.sh$/ { next }
        /^owned[|]watchdog[|](binary|wrapper)$/ { next }
        /^owned[|]service[|]S00ubifs$/ { next }
        { exit 1 }
    ' "$_file"; then
        report UNKNOWN ledger 'malformed record; refuse to trust it'
        return
    fi
    LEDGER_VALID=1
    report LEDGER ownership.v1 'valid creation log (not exclusive removal authority)'
    while IFS= read -r _item || [ -n "$_item" ]; do
        [ "$_item" != KAS_OWNERSHIP_V1 ] || continue
        report RECORDED "$_item" 'created/enabled by KAS; current dependencies unverified'
    done < "$_file"
}
ledger_check
if [ "$MODE" != --check ]; then
    if [ "$LEDGER_VALID" -ne 1 ]; then
        printf '[BLOCKED] %s: no valid ownership journal; no automatic removal, no --force. Nothing changed.\n' "$MODE" >&2
    else
        printf '[BLOCKED] %s: creation journal verified, but shared dependencies/recovery checks are not yet implemented. Nothing changed.\n' "$MODE" >&2
    fi
    exit 3
fi

probe /opt/etc/mihomo/config.yaml shared
probe /opt/etc/mihomo/config.yaml.bak shared
probe /opt/etc/keenetic-auto-setup-mihomo.state unknown
probe /opt/bin/mihomo_watchdog.sh unknown
probe /opt/etc/cron.5mins/mihomo_watchdog unknown
probe /opt/etc/crontab shared
probe /opt/etc/ndm/netfilter.d/020-bypass_wa.sh unknown
probe /opt/etc/init.d/S00ubifs unknown
probe /opt/etc/init.d/S99mihomo shared
probe /opt/etc/init.d/S99magitrickle shared
probe /opt/var/lib/magitrickle/config.yaml shared

if command -v opkg >/dev/null 2>&1; then
    _pkgs=$(opkg list-installed 2>/dev/null) || _pkgs=''
    if [ -n "$_pkgs" ]; then
        for _pkg in mihomo magitrickle; do
            if printf '%s\n' "$_pkgs" | grep -Eq "^${_pkg}[[:space:]]"; then
                report SHARED_OR_FOREIGN "opkg/$_pkg" 'installed; could be used elsewhere'
            else
                report ABSENT "opkg/$_pkg" 'not reported installed'
            fi
        done
    else
        report UNKNOWN opkg 'package inventory unavailable'
    fi
else
    report UNKNOWN opkg 'opkg unavailable'
fi

if command -v ndmc >/dev/null 2>&1; then
    _rc=$(ndmc -c 'show running-config' 2>/dev/null) || _rc=''
    if printf '%s\n' "$_rc" | grep -q '^interface '; then
        if printf '%s\n' "$_rc" | grep -Eq 'proxy upstream 127[.]0[.]0[.]1[[:space:]]+7890'; then
            report UNKNOWN ProxyN 'Mihomo SOCKS5 upstream found; ownership unproven'
        else
            report ABSENT ProxyN 'no contract upstream found'
        fi
        if printf '%s\n' "$_rc" | grep -Eq 'dns-proxy intercept enable|intercept enable'; then
            report SHARED_OR_FOREIGN 'dns-proxy intercept' 'enabled; prior setting unknown'
        else
            report ABSENT 'dns-proxy intercept' 'no enable directive seen'
        fi
    else
        report UNKNOWN ProxyN 'running-config invalid/unavailable'
        report UNKNOWN 'dns-proxy intercept' 'running-config invalid/unavailable'
    fi
    _policy=$(ndmc -c 'show ip policy' 2>/dev/null) || _policy=''
    if [ -n "$_policy" ]; then
        if printf '%s\n' "$_policy" | grep -q 'bypass_wa'; then
            report UNKNOWN 'policy/bypass_wa' 'present; creation provenance unknown'
        else
            report ABSENT 'policy/bypass_wa' 'not in policy listing'
        fi
    else
        report UNKNOWN 'policy/bypass_wa' 'policy inventory unavailable'
    fi
else
    report UNKNOWN ProxyN 'ndmc unavailable'
    report UNKNOWN 'dns-proxy intercept' 'ndmc unavailable'
    report UNKNOWN 'policy/bypass_wa' 'ndmc unavailable'
fi

if command -v iptables >/dev/null 2>&1; then
    if iptables -t mangle -S _CUST_BYPASS_WA_ >/dev/null 2>&1; then
        report UNKNOWN 'netfilter/_CUST_BYPASS_WA_' 'chain present; ownership unproven'
    else
        report UNKNOWN 'netfilter/_CUST_BYPASS_WA_' 'absent or unreadable'
    fi
else
    report UNKNOWN 'netfilter/_CUST_BYPASS_WA_' 'iptables unavailable'
fi

printf '[KAS uninstall] No changes made. UNKNOWN and SHARED_OR_FOREIGN remain protected.\n'
printf '[KAS uninstall] --remove/--purge blocked pending ownership and recovery contract.\n'