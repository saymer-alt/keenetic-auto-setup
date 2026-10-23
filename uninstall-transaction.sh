#!/bin/sh
# KAS experimental uninstall transaction: sealed preparation and audited removal.
# Production promotion still requires independent virtual/hardware acceptance.
set -eu
umask 077
export LC_ALL=C

mode=${1:-}
name=${2:-}
[ "$#" -eq 2 ] || { echo "Usage: sh uninstall-transaction.sh --prepare|--remove SNAPSHOT_NAME" >&2; exit 2; }
case "$name" in
    ''|*[!0-9-]*) echo '[BLOCKED] invalid snapshot name' >&2; exit 3 ;;
esac
printf '%s\n' "$name" | grep -Eq '^[0-9]{8}-[0-9]{6}-[0-9]+$' ||
    { echo '[BLOCKED] invalid snapshot name' >&2; exit 3; }
case "$mode" in
    --prepare) ;;
    --rehearse)
        [ -n "${KAS_TXN_FIXTURE_ROOT:-}" ] ||
            { echo "[BLOCKED] --rehearse only works against an isolated fixture" >&2; exit 3; }
        ;;
    --remove) ;;
    --purge) printf '[BLOCKED] --purge is NOT_IMPLEMENTED and deliberately separate from --remove\n' >&2; exit 3 ;;
    *) echo "Usage: sh uninstall-transaction.sh --prepare|--remove SNAPSHOT_NAME" >&2; exit 2 ;;
esac
fail() { printf '[BLOCKED] transaction preparation: %s\n' "$1" >&2; exit 3; }

# Fixture mode exists solely to exercise the read-only plan on a fake tree.
root=${KAS_TXN_FIXTURE_ROOT:-}
case "$root" in
    '') ;;
    /*) [ "$root" != / ] || fail "invalid fixture root" ;;
    *) fail "fixture root must be absolute" ;;
esac
if [ "$mode" = --rehearse ] || { [ "$mode" = --remove ] && [ -n "${KAS_TXN_FIXTURE_ROOT:-}" ]; }; then
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
# Exception: a --remove whose journal already says complete is verified by
# the engine's whole-system already-removed audit instead (the pre-removal
# snapshot comparison is meaningless after a legitimate removal).
txn_skip_gate=0
if [ "$mode" = --remove ]; then
    _j="$root/opt/kas-uninstall-backups/$name/transaction/journal.v1"
    if [ -f "$_j" ] && [ ! -L "$_j" ]; then
        txn_skip_gate=1
    fi
fi
if [ "$txn_skip_gate" -eq 0 ]; then
    KAS_SNAPSHOT_ROOT="$root" sh "$dir/uninstall-transaction-gate.sh" --check "$name" ||
        fail "strict ownership, snapshot or dependency gate failed"
fi

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
    if [ "${REMOVE_ACTIVE:-0}" -eq 1 ]; then
        printf '%s %s
' interrupted '(signal or abort)' >> "$journal" 2>/dev/null || true
        sync
        REMOVE_ACTIVE=0
    fi
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


# ---------------------------------------------------------------------------
# Removal engine primitives (used by --remove; defined for every mode).
# Every step is state-aware and idempotent: each predicate reads the ACTUAL
# system, so an interrupted run resumes without replaying completed work.
txn_journal_line() {
    if [ "$#" -eq 2 ]; then
        printf '%s %s\n' "$1" "$2" >> "$journal" || fail "cannot append transaction journal"
    else
        printf '%s\n' "$1" >> "$journal" || fail "cannot append transaction journal"
    fi
    sync
}

txn_owned_cron_present() {
    # Exactly the canonical owned schedule line (flag decided in END: an
    # `exit` in the body would be overridden by the END status).
    awk '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
        {
            norm=$0
            gsub(/^[ \t]+|[ \t]+$/, "", norm)
            gsub(/[ \t]+/, " ", norm)
            if (norm == "*/5 * * * * root /bin/sh /opt/etc/cron.5mins/mihomo_watchdog") owned=1
        }
        END { exit !owned }
    ' "$root/opt/etc/crontab"
}

txn_step_cron_done() { ! txn_owned_cron_present; }
txn_step_cron() {
    # A foreign mihomo_watchdog schedule is a consumer we do not own:
    # refuse before touching the shared crontab at all.
    if awk '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ {next}
        {
            norm=$0
            gsub(/^[ \t]+|[ \t]+$/, "", norm)
            gsub(/[ \t]+/, " ", norm)
            if (index(norm, "mihomo_watchdog") && norm != "*/5 * * * * root /bin/sh /opt/etc/cron.5mins/mihomo_watchdog") foreign=1
        }
        END { exit !foreign }
    ' "$root/opt/etc/crontab"; then
        fail "foreign mihomo_watchdog cron consumer: preserve and remove manually"
    fi
    awk '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ {print; next}
        {
            norm=$0
            gsub(/^[ \t]+|[ \t]+$/, "", norm)
            gsub(/[ \t]+/, " ", norm)
            if (norm == "*/5 * * * * root /bin/sh /opt/etc/cron.5mins/mihomo_watchdog") next
            print
        }
    ' "$root/opt/etc/crontab" > "$root/opt/etc/crontab.kas-txn.$$" ||
        fail "cannot stage crontab without the owned schedule"
    cat "$root/opt/etc/crontab.kas-txn.$$" > "$root/opt/etc/crontab" ||
        { rm -f "$root/opt/etc/crontab.kas-txn.$$"; fail "cannot rewrite crontab"; }
    rm -f "$root/opt/etc/crontab.kas-txn.$$"
    if cmp -s "$root/opt/etc/crontab" "$snap/files/opt/etc/crontab"; then
        fail "crontab rewrite made no change"
    fi
}

txn_step_watchdog_done() {
    [ ! -e "$root/opt/etc/cron.5mins/mihomo_watchdog" ] && [ ! -L "$root/opt/etc/cron.5mins/mihomo_watchdog" ] &&
    [ ! -e "$root/opt/bin/mihomo_watchdog.sh" ] && [ ! -L "$root/opt/bin/mihomo_watchdog.sh" ]
}
txn_step_watchdog() {
    rm -f "$root/opt/etc/cron.5mins/mihomo_watchdog" "$root/opt/bin/mihomo_watchdog.sh" ||
        fail "cannot quarantine watchdog files"
}

txn_chain_present() {
    iptables -t mangle -S _CUST_BYPASS_WA_ >/dev/null 2>&1
}
txn_step_netfilter_done() { ! txn_chain_present; }
txn_step_netfilter() {
    txn_audit
    if txn_chain_present; then
        # Delete exactly the KAS jump as serialized live; never a flush.
        _jump=$(iptables -t mangle -S PREROUTING 2>/dev/null | grep -F -- '-j _CUST_BYPASS_WA_') ||
            _jump=''
        if [ -n "$_jump" ]; then
            set -f
            iptables -t mangle $(printf '%s\n' "$_jump" | sed 's/^-A /-D /') ||
                fail "cannot detach the KAS PREROUTING jump"
            set +f
            txn_fault_check netfilter-jump
        fi
        # Only the verified snapshot rules, in their original order. Audit
        # accepts a deleted prefix only while this step has durable intent.
        _rules=$(iptables -t mangle -S _CUST_BYPASS_WA_) || fail "cannot read owned chain"
        _rule_count=0
        while IFS= read -r _rule; do
            case "$_rule" in
                '-A _CUST_BYPASS_WA_ '*)
                    txn_audit
                    set -f
                    iptables -t mangle $(printf '%s\n' "$_rule" | sed 's/^-A /-D /') ||
                        fail "cannot delete verified KAS rule"
                    set +f
                    _rule_count=$((_rule_count + 1))
                    txn_fault_check "netfilter-rule-$_rule_count"
                    txn_fault_check "netfilter-rule"
                    ;;
            esac
        done <<_RULES
$_rules
_RULES
        txn_audit
        iptables -t mangle -X _CUST_BYPASS_WA_ ||
            fail "cannot remove the KAS-owned chain"
    fi
    if txn_chain_present; then
        fail "KAS chain still present after teardown"
    fi
}

txn_step_hook_done() {
    [ ! -e "$root/opt/etc/ndm/netfilter.d/020-bypass_wa.sh" ] && [ ! -L "$root/opt/etc/ndm/netfilter.d/020-bypass_wa.sh" ]
}
txn_step_hook() {
    rm -f "$root/opt/etc/ndm/netfilter.d/020-bypass_wa.sh" ||
        fail "cannot remove the KAS netfilter hook"
}

# BEGIN MIHOMO PROCESS STATE v1
# Identical standalone contract: 0 running, 1 stopped, 2 unknown.
# MP_PIDS contains only positive evidence; unknown is never absence.
mp_state() {
    local rc p exe name flags state data tail seen uncertain
    MP_PIDS=""
    if command -v pidof >/dev/null 2>&1; then
        if MP_PIDS=$(pidof mihomo 2>/dev/null); then
            [ -n "$MP_PIDS" ] || return 2
            seen=0
            for p in $MP_PIDS; do
                seen=1
                case "$p" in ''|0|*[!0-9]*) MP_PIDS=""; return 2 ;; esac
            done
            [ "$seen" -eq 1 ] || return 2
            return 0
        else
            rc=$?
            MP_PIDS=""
            [ "$rc" -eq 1 ] && return 1
            return 2
        fi
    fi
    # A restricted/incomplete proc view cannot establish absence.
    [ -r /proc/self/stat ] && [ -d /proc/1 ] && [ -r /proc/mounts ] || return 2
    if grep -Eq 'hidepid=([1-9]|invisible|noaccess)' /proc/mounts; then
        return 2
    else
        rc=$?
        [ "$rc" -eq 1 ] || return 2
    fi
    seen=0; uncertain=0
    for p in /proc/[0-9]*; do
        [ -d "$p" ] || continue
        seen=1
        if exe=$(readlink "$p/exe" 2>/dev/null); then
            exe=${exe% (deleted)}
            case "$exe" in
                /opt/sbin/mihomo|/opt/bin/mihomo|*/mihomo)
                    MP_PIDS="$MP_PIDS ${p##*/}"
                    continue ;;
            esac
            # A renamed executable may still be the canonical inode.
            for name in /opt/sbin/mihomo /opt/bin/mihomo; do
                if [ "$p/exe" -ef "$name" ]; then
                    MP_PIDS="$MP_PIDS ${p##*/}"
                    break
                fi
            done
            continue
        fi
        # Vanished processes, zombies and kernel threads execute no userspace ELF.
        [ -d "$p" ] || continue
        if data=$(cat "$p/stat" 2>/dev/null); then
            tail=${data##*) }
            state=${tail%% *}
            case "$state" in Z|X) continue ;; esac
            flags=$(printf '%s\n' "$tail" | awk 'NF >= 7 {print $7}')
            case "$flags" in
                ''|*[!0-9]*) ;;
                *) [ $((flags & 2097152)) -ne 0 ] && continue ;;
            esac
        fi
        [ -d "$p" ] && uncertain=1
    done
    [ "$seen" -eq 1 ] || return 2
    [ "$uncertain" -eq 0 ] || return 2
    [ -n "$MP_PIDS" ] && return 0
    return 1
}

mp_running() { mp_state; }
mp_stopped() {
    local rc
    if mp_state; then return 1; else rc=$?; fi
    [ "$rc" -eq 1 ]
}
mp_known() {
    local rc
    if mp_state; then return 0; else rc=$?; fi
    [ "$rc" -eq 1 ]
}
mp_pids() {
    mp_state || return 1
    printf '%s\n' "$MP_PIDS"
}
# END MIHOMO PROCESS STATE v1

txn_magi_state() {
    local rc p exe name flags state data tail seen uncertain
    MP_PIDS=""
    if command -v pidof >/dev/null 2>&1; then
        if MP_PIDS=$(pidof magitrickled 2>/dev/null); then
            [ -n "$MP_PIDS" ] || return 2
            seen=0
            for p in $MP_PIDS; do
                seen=1
                case "$p" in ''|0|*[!0-9]*) MP_PIDS=""; return 2 ;; esac
            done
            [ "$seen" -eq 1 ] || return 2
            return 0
        else
            rc=$?
            MP_PIDS=""
            [ "$rc" -eq 1 ] && return 1
            return 2
        fi
    fi
    # A restricted/incomplete proc view cannot establish absence.
    [ -r /proc/self/stat ] && [ -d /proc/1 ] && [ -r /proc/mounts ] || return 2
    if grep -Eq 'hidepid=([1-9]|invisible|noaccess)' /proc/mounts; then
        return 2
    else
        rc=$?
        [ "$rc" -eq 1 ] || return 2
    fi
    seen=0; uncertain=0
    for p in /proc/[0-9]*; do
        [ -d "$p" ] || continue
        seen=1
        if exe=$(readlink "$p/exe" 2>/dev/null); then
            exe=${exe% (deleted)}
            case "$exe" in
                /opt/sbin/magitrickled|/opt/bin/magitrickled|*/magitrickled)
                    MP_PIDS="$MP_PIDS ${p##*/}"
                    continue ;;
            esac
            # A renamed executable may still be the canonical inode.
            for name in /opt/sbin/magitrickled /opt/bin/magitrickled; do
                if [ "$p/exe" -ef "$name" ]; then
                    MP_PIDS="$MP_PIDS ${p##*/}"
                    break
                fi
            done
            continue
        fi
        # Vanished processes, zombies and kernel threads execute no userspace ELF.
        [ -d "$p" ] || continue
        if data=$(cat "$p/stat" 2>/dev/null); then
            tail=${data##*) }
            state=${tail%% *}
            case "$state" in Z|X) continue ;; esac
            flags=$(printf '%s\n' "$tail" | awk 'NF >= 7 {print $7}')
            case "$flags" in
                ''|*[!0-9]*) ;;
                *) [ $((flags & 2097152)) -ne 0 ] && continue ;;
            esac
        fi
        [ -d "$p" ] && uncertain=1
    done
    [ "$seen" -eq 1 ] || return 2
    [ "$uncertain" -eq 0 ] || return 2
    [ -n "$MP_PIDS" ] && return 0
    return 1
}


txn_step_services_done() {
    if mp_state; then _ms=0; else _ms=$?; fi
    if txn_magi_state; then _gs=0; else _gs=$?; fi
    [ "$_ms" -ne 2 ] && [ "$_gs" -ne 2 ] || fail "service state UNKNOWN"
    [ "$_ms" -eq 1 ] && [ "$_gs" -eq 1 ]
}
txn_step_services() {
    for svc in S99mihomo S99magitrickle; do
        if [ -x "$root/opt/etc/init.d/$svc" ]; then
            "$root/opt/etc/init.d/$svc" stop >/dev/null 2>&1 || true
        fi
    done
    _tries=0
    while ! txn_step_services_done; do
        _tries=$((_tries + 1))
        [ "$_tries" -le 10 ] || fail "owned services did not stop"
        sleep 2
    done
}

txn_policy_present() {
    ndmc -c 'show running-config' 2>/dev/null | tr -d '\r' | grep -q '^ip policy bypass_wa$'
}
txn_step_policy_done() { ! txn_policy_present; }
txn_step_policy() {
    if txn_policy_present; then
        ndmc -c 'no ip policy bypass_wa' >/dev/null 2>&1 ||
            fail "ndmc rejected removal of the owned policy"
    fi
    if txn_policy_present; then
        fail "owned policy still present after removal"
    fi
}

txn_proxy_present() {
    ndmc -c 'show running-config' 2>/dev/null | tr -d '\r' | grep -q '^interface Proxy0$'
}
txn_step_proxy_done() { ! txn_proxy_present; }
txn_step_proxy() {
    if txn_proxy_present; then
        ndmc -c 'no interface Proxy0' >/dev/null 2>&1 ||
            fail "ndmc rejected removal of the owned Proxy0 interface"
    fi
    if txn_proxy_present; then
        fail "owned Proxy0 still present after removal"
    fi
    ndmc -c 'system configuration save' >/dev/null 2>&1 ||
        fail "cannot persist the Keenetic configuration after teardown"
}

txn_step_opkg_done() {
    _list=$(opkg list-installed 2>/dev/null) || return 1
    ! printf '%s\n' "$_list" | grep -Eq '^(mihomo|magitrickle)[[:space:]]'
}
txn_step_opkg() {
    for pkg in magitrickle mihomo; do
        if printf '%s\n' "$(opkg list-installed 2>/dev/null)" | grep -Eq "^${pkg}[[:space:]]"; then
            _pkg_result=0
            opkg remove "$pkg" || _pkg_result=$?
            # Packages may unlink their conffiles. Preserve the user's exact
            # verified bytes at the original paths, never purge their trees.
            for _yaml in /opt/etc/mihomo/config.yaml /opt/var/lib/magitrickle/config.yaml; do
                if [ ! -e "$root$_yaml" ] && [ ! -L "$root$_yaml" ]; then
                    txn_no_links "$root$_yaml"
                    mkdir -p "${root}${_yaml%/*}" || fail "cannot retain user YAML directory"
                    cp -p "$snap/files$_yaml" "$root$_yaml" || fail "cannot retain user YAML"
                fi
                cmp -s "$root$_yaml" "$snap/files$_yaml" || fail "package changed user YAML"
            done
            [ "$_pkg_result" -eq 0 ] || fail "opkg refused to remove the ledger-owned package"
            txn_audit
        fi
    done
    txn_step_opkg_done || fail "owned packages remain installed"
}

txn_step_feed_done() {
    [ ! -e "$root/opt/etc/opkg/magitrickle.conf" ] && [ ! -L "$root/opt/etc/opkg/magitrickle.conf" ]
}
txn_step_feed() {
    rm -f "$root/opt/etc/opkg/magitrickle.conf" ||
        fail "cannot remove the KAS-owned feed configuration"
}

txn_step_ledger_done() {
    [ ! -e "$root/opt/etc/keenetic-auto-setup/ownership.v1" ] &&
    [ ! -L "$root/opt/etc/keenetic-auto-setup/ownership.v1" ]
}
txn_step_ledger() {
    rm -f "$root/opt/etc/keenetic-auto-setup/ownership.v1" ||
        fail "cannot remove the ownership ledger"
    rmdir "$root/opt/etc/keenetic-auto-setup" 2>/dev/null || true
}

TXN_STEPS='cron watchdog netfilter hook services policy proxy opkg feed ledger'

txn_step_done() {
    case "$1" in
        cron) txn_step_cron_done ;;
        watchdog) txn_step_watchdog_done ;;
        netfilter) txn_step_netfilter_done ;;
        hook) txn_step_hook_done ;;
        services) txn_step_services_done ;;
        policy) txn_step_policy_done ;;
        proxy) txn_step_proxy_done ;;
        opkg) txn_step_opkg_done ;;
        feed) txn_step_feed_done ;;
        ledger) txn_step_ledger_done ;;
        *) fail "unknown removal step" ;;
    esac
}

txn_step_run() {
    case "$1" in
        cron) txn_step_cron ;;
        watchdog) txn_step_watchdog ;;
        netfilter) txn_step_netfilter ;;
        hook) txn_step_hook ;;
        services) txn_step_services ;;
        policy) txn_step_policy ;;
        proxy) txn_step_proxy ;;
        opkg) txn_step_opkg ;;
        feed) txn_step_feed ;;
        ledger) txn_step_ledger ;;
    esac
}

txn_fault_check() {
    if [ "${KAS_TXN_TEST_FAIL_AT:-}" = "$1" ]; then
        txn_journal_line interrupted "$1"
        fail "fault injection after step $1"
    fi
}

# Exact-version rollback cache. Failures leave no partial trust: the caller
# downgrades to REVIEW and --remove refuses to start without a full cache.
txn_build_cache() {
    rm -rf "$snap/packages"
    (umask 077; mkdir "$snap/packages") || return 1
    : > "$snap/packages/wanted" || return 1
    for pkg in mihomo magitrickle; do
        ver=$(opkg list-installed 2>/dev/null | awk -v p="$pkg" '$1 == p { print $3 }')
        case "$ver" in ''|*[!A-Za-z0-9.+~-]*) return 1 ;; esac
        printf '%s %s\n' "$pkg" "$ver" >> "$snap/packages/wanted" || return 1
        (cd "$snap/packages" && opkg download "$pkg" >/dev/null 2>&1) || return 1
        count=$(find "$snap/packages" -maxdepth 1 -name "${pkg}_${ver}_*.ipk" | wc -l)
        [ "$count" -eq 1 ] || return 1
    done
    (cd "$snap/packages" && sha256sum ./*.ipk > MANIFEST) || return 1
    return 0
}

txn_cache_verified() {
    [ -f "$snap/packages/wanted" ] && [ ! -L "$snap/packages/wanted" ] || return 1
    [ -f "$snap/packages/MANIFEST" ] && [ ! -L "$snap/packages/MANIFEST" ] || return 1
    (cd "$snap/packages" && sha256sum -c MANIFEST >/dev/null 2>&1) || return 1
    while IFS=' ' read -r pkg ver; do
        [ -n "$pkg" ] && [ -n "$ver" ] || return 1
        live=$(opkg list-installed 2>/dev/null | awk -v p="$pkg" '$1 == p { print $3 }')
        [ "$live" = "$ver" ] || return 1
        [ "$(find "$snap/packages" -maxdepth 1 -name "${pkg}_${ver}_*.ipk" | wc -l)" -eq 1 ] || return 1
    done < "$snap/packages/wanted"
    return 0
}


# PREPARE seals the exact recovery inputs. Resume never trusts changed backup
# bytes, nor absence without an ordered journal authorization. No shell eval.
txn_seal() {
    (cd "$snap" && sha256sum manifest.v1 READY running-config ip-policy iptables-mangle opkg-packages \
        files/opt/etc/keenetic-auto-setup/ownership.v1 files/opt/etc/mihomo/config.yaml \
        files/opt/var/lib/magitrickle/config.yaml files/opt/etc/crontab \
        files/opt/etc/ndm/netfilter.d/020-bypass_wa.sh files/opt/etc/cron.5mins/mihomo_watchdog \
        files/opt/bin/mihomo_watchdog.sh files/opt/etc/opkg/magitrickle.conf \
        files/opt/etc/init.d/S99mihomo files/opt/etc/init.d/S99magitrickle \
        packages/wanted packages/MANIFEST packages/*.ipk > transaction/recovery.sha256) ||
        fail "cannot seal recovery inputs"
}

txn_absent() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
txn_no_links() {
    _nl=$1
    while [ "$_nl" != "$root" ] && [ -n "$_nl" ]; do
        [ ! -L "$_nl" ] || fail "linked resource or recovery ancestor"
        _nl=${_nl%/*}
    done
}
txn_authorized() {
    [ "$resuming" -ne 0 ] || return 1
    awk -v s="$1" '$1 == "intent" && $2 == s {yes=1} END {exit !yes}' "$journal"
}
txn_recorded_done() {
    [ "$resuming" -ne 0 ] || return 1
    grep -qx "done $1" "$journal"
}
txn_journal_verified() {
    [ "$resuming" -ne 0 ] || return 0
    [ -f "$journal" ] && [ ! -L "$journal" ] || fail "invalid journal"
    awk -v name="$name" -v steps="$TXN_STEPS" '
        BEGIN {n=split(steps,a," "); i=1; active=0; bad=0}
        NR==1 {if ($0!="KAS_UNINSTALL_JOURNAL_V1") bad=1; next}
        NR==2 {if ($0!="begin " name) bad=1; next}
        ended {bad=1; next}
        $1=="interrupted" {next}
        $1=="intent" && NF==2 && i<=n && $2==a[i] {active=1; next}
        $1=="done" && NF==2 && active && $2==a[i] {i++; active=0; next}
        $0=="complete" && i==n+1 && !active {ended=1; next}
        {bad=1}
        END {exit (bad || NR<2)}
    ' "$journal" || fail "untrusted or unordered transaction journal"
}

txn_audit_file() {
    _af_path=$1; _af_step=$2
    txn_no_links "$root$_af_path"
    [ ! -L "$root$_af_path" ] || fail "remaining resource is linked"
    if txn_absent "$root$_af_path"; then
        txn_authorized "$_af_step" || fail "resource missing without journal intent"
    else
        if [ "${3:-}" != retained ]; then
            txn_recorded_done "$_af_step" && fail "completed resource reappeared"
        fi
        [ -f "$root$_af_path" ] && cmp -s "$root$_af_path" "$snap/files$_af_path" ||
            fail "remaining owned resource drift"
    fi
}

txn_audit() {
    txn_journal_verified
    [ -f "$snap/transaction/recovery.sha256" ] && [ ! -L "$snap/transaction/recovery.sha256" ] ||
        fail "missing sealed recovery inputs; prepare a fresh snapshot"
    # Reject linked ancestors as well as linked leaves before checksum reads.
    for _sealed in "$snap" "$snap/transaction" "$snap/packages" "$snap/files"; do
        txn_no_links "$_sealed"
        [ -d "$_sealed" ] && [ ! -L "$_sealed" ] || fail "linked recovery directory"
    done
    for _sealed in /opt/etc/keenetic-auto-setup/ownership.v1 /opt/etc/mihomo/config.yaml \
        /opt/var/lib/magitrickle/config.yaml /opt/etc/crontab \
        /opt/etc/ndm/netfilter.d/020-bypass_wa.sh /opt/etc/cron.5mins/mihomo_watchdog \
        /opt/bin/mihomo_watchdog.sh /opt/etc/opkg/magitrickle.conf \
        /opt/etc/init.d/S99mihomo /opt/etc/init.d/S99magitrickle; do
        txn_no_links "$snap/files$_sealed"
    done
    (cd "$snap" && sha256sum -c transaction/recovery.sha256 >/dev/null 2>&1) ||
        fail "recovery inputs changed"
    if txn_step_services_done; then :; fi  # UNKNOWN fails before mutation.
    if txn_recorded_done services && ! txn_step_services_done; then
        fail "owned services RUNNING after the recorded stop"
    fi
    for _yf in /opt/etc/mihomo/config.yaml /opt/var/lib/magitrickle/config.yaml; do
        txn_no_links "$root$_yf"
        [ -f "$root$_yf" ] && [ ! -L "$root$_yf" ] &&
            cmp -s "$root$_yf" "$snap/files$_yf" || fail "user YAML drift"
    done
    txn_audit_file /opt/etc/keenetic-auto-setup/ownership.v1 ledger
    txn_audit_file /opt/etc/cron.5mins/mihomo_watchdog watchdog
    txn_audit_file /opt/bin/mihomo_watchdog.sh watchdog
    txn_audit_file /opt/etc/ndm/netfilter.d/020-bypass_wa.sh hook
    txn_audit_file /opt/etc/opkg/magitrickle.conf feed
    txn_audit_file /opt/etc/init.d/S99mihomo opkg retained
    txn_audit_file /opt/etc/init.d/S99magitrickle opkg retained
    txn_no_links "$root/opt/etc/crontab"
    [ -f "$root/opt/etc/crontab" ] && [ ! -L "$root/opt/etc/crontab" ] || fail "crontab unreadable"
    if ! cmp -s "$root/opt/etc/crontab" "$snap/files/opt/etc/crontab"; then
        txn_authorized cron || fail "crontab drift"
        awk '
            {norm=$0; gsub(/^[ \t]+|[ \t]+$/, "", norm); gsub(/[ \t]+/, " ", norm)}
            norm != "*/5 * * * * root /bin/sh /opt/etc/cron.5mins/mihomo_watchdog" {print}
        ' "$snap/files/opt/etc/crontab" | cmp -s - "$root/opt/etc/crontab" || fail "foreign crontab drift"
    elif txn_recorded_done cron; then fail "completed cron reappeared"; fi

    _ar=$(ndmc -c 'show running-config' 2>/dev/null) || fail "running-config UNKNOWN"
    _ar=$(printf '%s\n' "$_ar" | tr -d '\r')
    _pol=0; _prx=0
    if ! printf '%s\n' "$_ar" | grep -qx 'ip policy bypass_wa'; then
        txn_authorized policy || fail "policy disappeared without intent"
        _pol=1
    elif txn_recorded_done policy; then fail "completed policy reappeared"; fi
    if ! printf '%s\n' "$_ar" | grep -qx 'interface Proxy0'; then
        txn_authorized proxy || fail "Proxy0 disappeared without intent"
        _prx=1
    elif txn_recorded_done proxy; then fail "completed Proxy0 reappeared"; fi
    _expected=$(awk -v pol="$_pol" -v prx="$_prx" '
        (pol && $0=="ip policy bypass_wa") || (prx && $0=="interface Proxy0") {skip=1; next}
        skip && /^!$/ {skip=0; next}
        !skip {print}
    ' "$snap/running-config")
    [ "$_ar" = "$_expected" ] || fail "remaining configuration or dependency drift"
    _ap=$(ndmc -c 'show ip policy' 2>/dev/null) || fail "policy inventory UNKNOWN"
    if [ "$_pol" -eq 0 ]; then
        printf '%s\n' "$_ap" | cmp -s - "$snap/ip-policy" || fail "policy inventory drift"
    fi
    _am=$(iptables -t mangle -S 2>/dev/null) || fail "Netfilter UNKNOWN"
    # Only a PREFIX of the four exact owned deletions is legal mid-step.
    _match=0
    for _cut in 0 1 2 3 4 5; do
        [ "$_cut" -eq 0 ] || txn_authorized netfilter || continue
        txn_recorded_done netfilter && [ "$_cut" -ne 5 ] && continue
        _em=$(awk -v cut="$_cut" '
            /^-A PREROUTING .* -j _CUST_BYPASS_WA_$/ {if(cut>=1) next}
            /^-A _CUST_BYPASS_WA_ / {r++; if(cut>=r+1) next}
            /^-N _CUST_BYPASS_WA_$/ {if(cut==5) next}
            {print}
        ' "$snap/iptables-mangle")
        if [ "$_am" = "$_em" ]; then _match=1; break; fi
    done
    [ "$_match" -eq 1 ] || fail "remaining Netfilter or foreign rules drift"
    _apk=$(opkg list-installed 2>/dev/null) || fail "package inventory UNKNOWN"
    _match=0
    for _cut in 0 1 2; do
        [ "$_cut" -eq 0 ] || txn_authorized opkg || continue
        txn_recorded_done opkg && [ "$_cut" -ne 2 ] && continue
        _ep=$(awk -v cut="$_cut" '
            $1=="magitrickle" && cut>=1 {next}
            $1=="mihomo" && cut>=2 {next}
            {print}
        ' "$snap/opkg-packages")
        if [ "$_apk" = "$_ep" ]; then _match=1; break; fi
    done
    [ "$_match" -eq 1 ] || fail "remaining package inventory drift"
}

# The whole-system already-removed audit for idempotent re-runs.
txn_all_steps_done() {
    for step in $TXN_STEPS; do
        txn_step_done "$step" || return 1
    done
    return 0
}

snap="$root/opt/kas-uninstall-backups/$name"
[ -d "$snap" ] && [ ! -L "$snap" ] || fail "snapshot vanished"
[ -f "$snap/READY" ] && [ ! -L "$snap/READY" ] || fail "snapshot no longer READY"

journal="$snap/transaction/journal.v1"
resuming=0
if [ "$mode" = --remove ] && [ -f "$journal" ] && [ ! -L "$journal" ]; then
    # A previously interrupted removal is audited against actual state, not
    # against the pre-removal snapshot (which legitimate steps changed).
    resuming=1
fi

# Comparison inside lock: external agents may mutate regardless of KAS lock;
# strict comparison is mandatory as late as possible in PREPARE.
if [ "$resuming" -eq 0 ]; then
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
    $1 == "-A" && $2 == "PREROUTING" && /-j _CUST_BYPASS_WA_/ {
        if ($0 !~ /^-A PREROUTING -m mark --mark 0x0(\/0xffffffff)? -j _CUST_BYPASS_WA_$/) bad=1
        jumps++; next
    }
    $1 == "-A" && $2 == "_CUST_BYPASS_WA_" {
        rule=$0; sub(/ -m udp /," ",rule)
        prefix="^-A _CUST_BYPASS_WA_ -p udp -m multiport --dports 1400,3478,3482 -j "
        if (rule ~ (prefix "MARK --set-xmark 0x[0-9a-fA-F]+/0xffffffff$")) {mark++; if (connmark || ret) bad=1}
        else if (rule ~ (prefix "CONNMARK --save-mark( --nfmask 0xffffffff --ctmask 0xffffffff)?$")) {connmark++; if(mark!=1 || ret) bad=1}
        else if (rule ~ (prefix "RETURN$")) {ret++; if(mark!=1 || connmark!=1) bad=1}
        else bad=1
        next
    }
    /_CUST_BYPASS_WA_/ { bad=1 }
    END { if (bad || names != 1 || jumps != 1 || mark != 1 || connmark != 1 || ret != 1) exit 1 }
' || fail "KAS mangle chain has unexpected/foreign rules"

fi

# Ensure the user preserves current YAML and settings even if OPKG package
# removal later deletes installed files. PREPARE is strictly non-destructive.
# The transaction record is atomic and private; it MUST NEVER be mistaken for
# permission to perform deletion.
if [ "$mode" != --remove ]; then
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
printf '[INFO] Experimental --remove requires separate acceptance; --purge is NOT_IMPLEMENTED\n'
# Rollback cache (PREPARE only): the exact installed versions must be
# locally restorable, or a future --remove refuses to start. Dependencies
# are NOT removed by --remove, so only the two owned packages are cached.
if [ "$mode" = --prepare ]; then
    packages="$snap/packages"
    if txn_build_cache; then
        txn_seal
        printf '[PASS] Rollback cache verified: exact installed .ipk stored with checksums
'
    else
        rm -rf "$packages"
        printf '[REVIEW] Rollback cache incomplete: --remove will refuse until exact versions are cached in %s
' "$packages"
    fi
fi

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

# ---------------------------------------------------------------------------
fi

# --remove: the destructive transaction. Runs only in --remove mode, after
# the shared gate/lock/verify section above. Fail-closed everywhere: the
# journal records intent before each mutation, steps are state-aware, and
# any unexpected observation aborts without touching later steps.
if [ "$mode" = --remove ]; then
    [ ! -L "$snap/transaction/prepare.v1" ] && [ -f "$snap/transaction/prepare.v1" ] ||
        fail "no prepared transaction for this snapshot; run --prepare first"

    if [ "$resuming" -eq 1 ]; then
        tail -n 1 "$journal" | grep -qx 'complete' && resuming=2
    fi

    if [ "$resuming" -eq 0 ]; then
        txn_cache_verified || fail "rollback cache missing or not the installed versions"
    fi
    txn_audit
    if [ "$resuming" = 2 ]; then
        txn_all_steps_done || fail "completed transaction has remaining resources"
        printf '[PASS] KAS already fully removed (idempotent re-run); nothing changed\n'
        exit 0
    fi
    if [ "$resuming" -ne 0 ]; then
        printf '[INFO] Resuming an interrupted removal (journal present); auditing state\n'
    fi

    REMOVE_ACTIVE=1
    if [ "$resuming" -ne 1 ]; then
        : > "$journal" || fail "cannot create transaction journal"
        printf 'KAS_UNINSTALL_JOURNAL_V1\n' >> "$journal"
        txn_journal_line begin "$name"
    fi

    resuming=1
    for step in $TXN_STEPS; do
        txn_audit
        if txn_recorded_done "$step"; then continue; fi
        txn_journal_line intent "$step"
        if ! txn_step_done "$step"; then txn_step_run "$step"; fi
        txn_step_done "$step" || fail "step $step did not reach its expected state"
        txn_journal_line done "$step"
        txn_audit
        txn_fault_check "$step"
    done

    txn_journal_line complete
    REMOVE_ACTIVE=0
    printf '[PASS] KAS removal transaction complete: only ledger-owned resources were removed\n'
    printf '[REVIEW] DNS intercept left ENABLED (it predates nothing provably foreign; disable manually if unwanted)\n'
    printf '[INFO] Rollback data and both user YAML copies retained in %s\n' "$snap"
    printf '[INFO] Reinstall: opkg install %s/packages/*.ipk and restore YAML from %s/files, or re-run install.sh\n' "$snap" "$snap"
fi
