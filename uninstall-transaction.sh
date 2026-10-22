#!/bin/sh
# KAS uninstall transaction: verified PREPARE stage only.
# --remove is explicitly blocked until rollback/teardown CI + hardware gates.
set -eu
umask 077
export LC_ALL=C

mode=${1:-}
name=${2:-}
[ "$#" -eq 2 ] || { echo "Usage: sh uninstall-transaction.sh --prepare SNAPSHOT_NAME" >&2; exit 2; }
case "$mode" in
    --prepare) ;;
    --rehearse)
        [ -n "${KAS_TXN_FIXTURE_ROOT:-}" ] ||
            { echo "[BLOCKED] --rehearse only works against an isolated fixture" >&2; exit 3; }
        ;;
    --remove|--purge) printf '[BLOCKED] Live removal not enabled in transaction engine\n' >&2; exit 3 ;;
    *) echo "Usage: sh uninstall-transaction.sh --prepare SNAPSHOT_NAME" >&2; exit 2 ;;
esac
fail() { printf '[BLOCKED] transaction preparation: %s\n' "$1" >&2; exit 3; }

# Fixture mode exists solely to exercise the read-only plan on a fake tree.
root=${KAS_TXN_FIXTURE_ROOT:-}
case "$root" in
    '') ;;
    /*) [ "$root" != / ] || fail "invalid fixture root" ;;
    *) fail "fixture root must be absolute" ;;
esac
if [ "$mode" = --rehearse ]; then
    # Canonicalize first: '/tmp/..' and path aliases MUST NOT bypass the
    # simulated-device restriction. Never allow real /opt to be the target.
    root=$(CDPATH= cd "$root" && pwd -P) ||
        fail "fixture directory cannot be resolved"
    case "$root" in
        /tmp/kas-uninstall-*/root) ;;
        *) fail "rehearsal allowed only inside a disposable /tmp test fixture" ;;
    esac
    fixture_marker="$root/.kas-uninstall-fixture"
    [ -f "$fixture_marker" ] && [ ! -L "$fixture_marker" ] &&
        [ "$(cat "$fixture_marker")" = KAS_UNINSTALL_TEST_FIXTURE_V1 ] ||
        fail "missing explicit disposable fixture identity marker"
fi
# The lifecycle lock contract is identical to installer/update/watchdog. Only
# the path root differs in offline tests; production always uses /tmp.
# BEGIN MIHOMO LIFECYCLE LOCK v1
# Kept identical in standalone consumers (curl | sh needs no library).
# A short mkdir guard serializes ALL metadata changes, including stale recovery.
# Never steal this guard: a crash inside its tiny critical section fails closed.
# An operator may remove an abandoned guard only with maintenance stopped.
MIHOMO_LIFECYCLE_LOCK="/tmp/mihomo-lifecycle.lock.d"
MAINT_MARKER="/tmp/mihomo.maintenance"
ML_ID=""
ML_GATE=""
ML_MARKER=""
ML_LIFECYCLE_HELD=0

ml_starttime() {
    local data tail
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    data=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    # comm (field 2) may contain spaces and ')'; strip through its LAST ') '.
    tail=${data##*) }
    [ "$tail" != "$data" ] || return 1
    printf '%s\n' "$tail" | awk 'NF >= 20 && $20 ~ /^[0-9]+$/ { print $20; ok=1 } END { if (!ok) exit 1 }'
}

ml_identity() {
    local start
    [ -n "$ML_ID" ] && return 0
    start=$(ml_starttime "$$") || return 1
    ML_ID="$$ $start"
}

# 0 = live identity, 1 = proven stale, 2 = unknown (never steal).
ml_owner_state() {
    local pid start extra current
    IFS=' ' read -r pid start extra < "$1" || return 2
    case "$pid" in ''|0*|*[!0-9]*) return 2 ;; esac
    case "$start" in ''|*[!0-9]*) return 2 ;; esac
    [ -z "$extra" ] || return 2
    if current=$(ml_starttime "$pid"); then
        [ "$current" = "$start" ] && return 0
        return 1
    fi
    [ ! -d "/proc/$pid" ] && return 1
    return 2
}

ml_gate_enter() {
    [ -z "$ML_GATE" ] || return 1
    (umask 077; mkdir "$1.guard") 2>/dev/null || return 1
    ML_GATE="$1.guard"
}

ml_gate_leave() {
    [ -n "$ML_GATE" ] || return 0
    rmdir "$ML_GATE" 2>/dev/null || return 1
    ML_GATE=""
}

ml_lock_acquire() {
    local path state
    path=$1
    ml_identity || return 1
    ml_gate_enter "$path" || return 1
    if [ -e "$path" ] || [ -L "$path" ]; then
        if [ ! -d "$path" ] || [ -L "$path" ] || [ ! -f "$path/owner" ] || [ -L "$path/owner" ]; then
            ml_gate_leave
            return 1
        fi
        if ml_owner_state "$path/owner"; then state=0; else state=$?; fi
        if [ "$state" -ne 1 ]; then
            ml_gate_leave
            return 1
        fi
        # Under the guard no new owner can appear between inspect/remove/mkdir.
        if ! rm -f "$path/owner" || ! rmdir "$path"; then
            ml_gate_leave
            return 1
        fi
    fi
    if ! (umask 077; mkdir "$path"); then
        ml_gate_leave
        return 1
    fi
    if ! printf '%s\n' "$ML_ID" > "$path/owner"; then
        rm -f "$path/owner"
        rmdir "$path" 2>/dev/null || true
        ml_gate_leave
        return 1
    fi
    ml_gate_leave
}

ml_lock_release() {
    local path
    path=$1
    [ -n "$ML_ID" ] || return 0
    # A signal during metadata work may already own this short guard.
    if [ "$ML_GATE" != "$path.guard" ]; then
        ml_gate_enter "$path" || return 1
    fi
    if [ -d "$path" ] && [ ! -L "$path" ] && [ -f "$path/owner" ] &&
       [ ! -L "$path/owner" ] && [ "$(cat "$path/owner" 2>/dev/null)" = "$ML_ID" ]; then
        if [ "$path" = "$MIHOMO_LIFECYCLE_LOCK" ] && [ -n "$ML_MARKER" ] &&
           [ ! -L "$MAINT_MARKER" ] && [ -f "$MAINT_MARKER" ] &&
           [ "$(cat "$MAINT_MARKER" 2>/dev/null)" = "$ML_MARKER" ]; then
            rm -f "$MAINT_MARKER" || { ml_gate_leave; return 1; }
        fi
        rm -f "$path/owner" || { ml_gate_leave; return 1; }
        rmdir "$path" 2>/dev/null || { ml_gate_leave; return 1; }
    fi
    ml_gate_leave
}

# Old tools do not participate in this protocol. Never remove their lock files;
# require a quiescent handover. A PID-only live marker is conservatively busy.
ml_legacy_busy() {
    local path
    for path in /tmp/mihomo-update.lock /tmp/mihomo-update.lock.d \
        /tmp/mihomo-config-import.lock.d /tmp/mihomo-migrate.lock \
        /tmp/mihomo-migrate.lock.d /tmp/mihomo-tun-migrate.lock.d; do
        if [ -e "$path" ] || [ -L "$path" ]; then return 0; fi
    done
    return 1
}

ml_marker_busy() {
    local pid stamp start extra current
    [ -e "$MAINT_MARKER" ] || [ -L "$MAINT_MARKER" ] || return 1
    [ -f "$MAINT_MARKER" ] && [ ! -L "$MAINT_MARKER" ] || return 0
    IFS=' ' read -r pid stamp start extra < "$MAINT_MARKER" || return 0
    case "$pid" in ''|*[!0-9]*) return 0 ;; esac
    if current=$(ml_starttime "$pid"); then
        case "$start" in ''|*[!0-9]*) return 0 ;; esac
        [ "$start" != "$current" ] && [ -z "$extra" ] && return 1
        return 0
    fi
    [ ! -d "/proc/$pid" ] && return 1
    return 0
}

ml_lifecycle_acquire() {
    ml_lock_acquire "$MIHOMO_LIFECYCLE_LOCK" || return 1
    ML_LIFECYCLE_HELD=1
    if ml_legacy_busy || ml_marker_busy; then
        ml_lifecycle_release
        return 1
    fi
    # First two fields remain compatible with older watchdogs.
    ML_MARKER="$$ $(date +%s) ${ML_ID#* }"
    if ! (umask 077; printf '%s\n' "$ML_MARKER" > "$MAINT_MARKER"); then
        ml_lifecycle_release
        return 1
    fi
    return 0
}

ml_lifecycle_release() {
    [ "$ML_LIFECYCLE_HELD" -eq 1 ] || return 0
    ml_lock_release "$MIHOMO_LIFECYCLE_LOCK" || return 1
    ML_LIFECYCLE_HELD=0
    ML_MARKER=""
}
# END MIHOMO LIFECYCLE LOCK v1

MIHOMO_LIFECYCLE_LOCK="$root/tmp/mihomo-lifecycle.lock.d"
MAINT_MARKER="$root/tmp/mihomo.maintenance"

dir=$(CDPATH= cd "$(dirname "$0")" && pwd) || fail "cannot resolve script directory"
[ -f "$dir/uninstall-snapshot-verify.sh" ] || fail "missing verifier"
[ -f "$dir/uninstall-transaction-gate.sh" ] || fail "missing strict gate"

# Both independent gates run BEFORE acquiring the maintenance marker.
# Once locked, compare live state and backed-up evidence again before
# producing a transaction marker; that closes the normal KAS TOCTOU window.
KAS_SNAPSHOT_ROOT="$root" sh "$dir/uninstall-transaction-gate.sh" --check "$name" ||
    fail "strict ownership, snapshot or dependency gate failed"

ml_lifecycle_acquire || fail "canonical Mihomo lifecycle lock is busy"
REHEARSE_ACTIVE=0
rehearse_restore() {
    [ "$REHEARSE_ACTIVE" -eq 1 ] || return 0
    _rr_status=0
    # Source paths and snapshot backup paths are fixed, never user-provided.
    for _rr_item in /opt/bin/mihomo_watchdog.sh \
                    /opt/etc/cron.5mins/mihomo_watchdog \
                    /opt/etc/ndm/netfilter.d/020-bypass_wa.sh \
                    /opt/etc/crontab; do
        _rr_source="$root$_rr_item"
        _rr_copy="$snap/files$_rr_item"
        [ -f "$_rr_copy" ] && [ ! -L "$_rr_copy" ] || { _rr_status=1; continue; }
        cp -p "$_rr_copy" "$_rr_source" || _rr_status=1
        cmp -s "$_rr_copy" "$_rr_source" || _rr_status=1
    done
    [ "$_rr_status" -eq 0 ] && REHEARSE_ACTIVE=0
    return "$_rr_status"
}
cleanup() {
    if [ "$REHEARSE_ACTIVE" -eq 1 ]; then
        rehearse_restore ||
            echo '[ERROR] Rehearsal restore failed, manual recovery from private snapshot needed' >&2
    fi
    ml_lifecycle_release || {
        echo '[ERROR] Cannot release lifecycle lock; manual review required' >&2
        return 1
    }
}
trap 'cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

snap="$root/opt/kas-uninstall-backups/$name"
[ -d "$snap" ] && [ ! -L "$snap" ] || fail "snapshot vanished"
[ -f "$snap/READY" ] && [ ! -L "$snap/READY" ] || fail "snapshot no longer READY"

# Comparison inside lock: external agents may mutate regardless of KAS lock;
# strict comparison is mandatory as late as possible in PREPARE.
for item in /opt/etc/keenetic-auto-setup/ownership.v1 \
            /opt/etc/mihomo/config.yaml \
            /opt/var/lib/magitrickle/config.yaml \
            /opt/etc/crontab \
            /opt/etc/ndm/netfilter.d/020-bypass_wa.sh \
            /opt/etc/cron.5mins/mihomo_watchdog \
            /opt/bin/mihomo_watchdog.sh \
            /opt/etc/opkg/magitrickle.conf; do
    orig="$root$item"
    copy="$snap/files$item"
    [ -f "$orig" ] && [ ! -L "$orig" ] ||
        fail "source disappeared or changed type: $item"
    [ -f "$copy" ] && [ ! -L "$copy" ] ||
        fail "missing private recovery file: $item"
    cmp -s "$orig" "$copy" || fail "source changed after verification: $item"
done
rc=$(ndmc -c 'show running-config' 2>/dev/null | tr -d '\r') ||
    fail "failed second read of running-config"
printf '%s\n' "$rc" | cmp -s - "$snap/running-config" ||
    fail "running-config changed under lifecycle lock"
policy=$(ndmc -c 'show ip policy' 2>/dev/null) ||
    fail "policy changed or unreadable"
printf '%s\n' "$policy" | cmp -s - "$snap/ip-policy" ||
    fail "policy changed under lifecycle lock"
mangle=$(iptables -t mangle -S 2>/dev/null) ||
    fail "iptables mangle state unreadable"
printf '%s\n' "$mangle" | cmp -s - "$snap/iptables-mangle" ||
    fail "mangle rules changed under lifecycle lock"
packages=$(opkg list-installed 2>/dev/null) ||
    fail "OPKG inventory unreadable"
printf '%s\n' "$packages" | cmp -s - "$snap/opkg-packages" ||
    fail "OPKG inventory changed under lifecycle lock"

# The hook has a dedicated chain; other Netfilter rules MUST NOT be flushed.
# Fail closed when chain is referenced from any unexpected source.
printf '%s\n' "$mangle" | awk '
    $1 == "-N" && $2 == "_CUST_BYPASS_WA_" { names++; next }
    $1 == "-A" && $2 == "PREROUTING" && /-j _CUST_BYPASS_WA_/ { jumps++; next }
    $1 == "-A" && $2 == "_CUST_BYPASS_WA_" {
        if (index($0, "--dports 1400,3478,3482") == 0) exit 1
        if ($0 ~ / -j MARK( |$)/) mark++
        else if ($0 ~ / -j CONNMARK( |$)/) connmark++
        else if ($0 ~ / -j RETURN( |$)/) ret++
        else exit 1
        next
    }
    /_CUST_BYPASS_WA_/ { exit 1 }
    END { if (names != 1 || jumps != 1 || mark != 1 || connmark != 1 || ret != 1) exit 1 }
' || fail "KAS mangle chain has unexpected/foreign rules"

# Ensure the user preserves current YAML and settings even if OPKG package
# removal later deletes installed files. PREPARE is strictly non-destructive.
# The transaction record is atomic and private; it MUST NEVER be mistaken for
# permission to perform deletion.
txn="$snap/transaction"
[ ! -L "$txn" ] || fail "transaction path is a symlink"
if [ ! -d "$txn" ]; then
    mkdir -m 700 "$txn" || fail "cannot create private transaction directory"
fi
[ ! -L "$txn/prepare.v1" ] || fail "transaction marker is a symlink"
stage="$txn/.prepare.$$"
(umask 077
    printf 'KAS_UNINSTALL_PREPARE_V1\n' > "$stage"
    printf 'snapshot=%s\n' "$name" >> "$stage"
    printf 'state=PREPARED_NO_DEVICE_MUTATIONS\n' >> "$stage"
    printf 'requires=explicit-operator-review-of-dns-and-package-consumers\n' >> "$stage"
) || fail "cannot write preparation marker"
chmod 600 "$stage" || fail "cannot protect preparation marker"
mv -f "$stage" "$txn/prepare.v1" ||
    fail "cannot atomically commit preparation marker"
printf '[PASS] KAS uninstall transaction prepared: %s\n' "$name"
printf '[INFO] Lifecycle lock acquired/released; no router settings or packages changed\n'
printf '[BLOCKED] Actual --remove/--purge still require fault-tested rollback engine\n'
# Optional destructive REHEARSAL is never available against a real router.
# It removes only the three ledger-owned files temporarily and restores
# byte-identical originals via the private snapshot while holding the lock.
if [ "$mode" = --rehearse ]; then
    # Before any mutation, reject unrecognized/direct cron consumers.
    cron_tmp="$txn/.cron_rehearse.$"
    if ! awk '
       /^[[:space:]]*#/ || /^[[:space:]]*$/ {print; next}
       {
           norm=$0
           gsub(/^[ \t]+|[ \t]+$/, "", norm)
           gsub(/[ \t]+/, " ", norm)
           if (norm == "*/5 * * * * root /bin/sh /opt/etc/cron.5mins/mihomo_watchdog") next
           if (index(norm, "mihomo_watchdog")) exit 2
           print
       }
    ' "$root/opt/etc/crontab" > "$cron_tmp"; then
        rm -f "$cron_tmp"
        fail "unexpected cron consumer: cannot rehearse removal"
    fi
    REHEARSE_ACTIVE=1
    for item in /opt/etc/cron.5mins/mihomo_watchdog \
                /opt/bin/mihomo_watchdog.sh \
                /opt/etc/ndm/netfilter.d/020-bypass_wa.sh; do
        [ -f "$root$item" ] && [ ! -L "$root$item" ] ||
            fail "owned rehearsal file is missing"
        cmp -s "$root$item" "$snap/files$item" ||
            fail "owned rehearsal file was modified"
        rm -f "$root$item" || fail "cannot quarantine project-owned file"
        case "$item" in
            */mihomo_watchdog)
                if [ "${KAS_TXN_TEST_FAIL_AT:-}" = wrapper ]; then
                    fail "fault injection after watchdog wrapper removal"
                fi ;;
            */mihomo_watchdog.sh)
                if [ "${KAS_TXN_TEST_FAIL_AT:-}" = binary ]; then
                    fail "fault injection after watchdog binary removal"
                fi ;;
            */020-bypass_wa.sh)
                if [ "${KAS_TXN_TEST_FAIL_AT:-}" = hook ]; then
                    fail "fault injection after Netfilter hook removal"
                fi ;;
        esac
    done
    cat "$cron_tmp" > "$root/opt/etc/crontab" ||
        fail "cannot stage cron removal"
    rm -f "$cron_tmp"
    if [ "${KAS_TXN_TEST_FAIL_AT:-}" = cron ]; then
        fail "fault injection after removing owned cron schedule"
    fi
    rehearse_restore || fail "rehearsal could not restore all backed up files"
    printf '[PASS] Simulated owned-file removal and byte-for-byte recovery\n'
    printf '[INFO] No real router settings, service states or packages were changed\n'
fi
