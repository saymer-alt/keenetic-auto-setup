#!/bin/sh
# KAS uninstall transaction: verified rollback cache before PREPARED/remove.
# Hardware removal remains an explicit owner-authorized operation.
set -eu
umask 077
export LC_ALL=C

mode=${1:-}
name=${2:-}
[ "$#" -eq 2 ] || { echo "Usage: sh uninstall-transaction.sh --prepare|--remove SNAPSHOT_NAME" >&2; exit 2; }
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

# A snapshot name is an opaque single-line token from our own directory
# listing; reject anything else before it reaches a path or the journal.
txn_validate_name() {
    case "$name" in
        ''|*[!A-Za-z0-9_-]*|*/*) fail 'invalid snapshot name' ;;
    esac
}
txn_validate_name

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
txn_step_services_done() {
    local proc comm exe data tail state flags seen rc procdir
    procdir="$root/proc"
    # These init scripts delegate stop to rc.func (killall). Neither retains
    # a PID/starttime record proving which invocation belongs to KAS. Even an
    # identical executable/argv can be a manual foreign invocation: fail closed.
    [ -r "$procdir/self/stat" ] && [ -d "$procdir/1" ] && [ -r "$procdir/mounts" ] ||
        fail "process inventory unavailable"
    # Same restricted-proc rule as KAS mp_state; absence must be observable.
    if grep -Eq 'hidepid=([1-9]|invisible|noaccess)' "$procdir/mounts"; then
        fail "restricted process inventory"
    else
        rc=$?
        [ "$rc" -eq 1 ] || fail "process mounts unreadable"
    fi
    seen=0
    for proc in "$procdir"/[0-9]*; do
        [ -d "$proc" ] || continue
        seen=1
        IFS= read -r comm < "$proc/comm" || {
            [ ! -d "$proc" ] && continue
            fail "process inventory unreadable"
        }
        case "$comm" in mihomo|magitrickled) return 1 ;; esac
        if exe=$(readlink "$proc/exe" 2>/dev/null); then
            case "${exe% (deleted)}" in */mihomo|*/magitrickled) return 1 ;; esac
            for comm in /opt/sbin/mihomo /opt/bin/mihomo /opt/bin/magitrickled; do
                if [ "$proc/exe" -ef "$root$comm" ]; then return 1; fi
            done
            continue
        fi
        # Reuse mp_state's treatment of vanished processes, zombies and
        # PF_KTHREAD. An unreadable live userspace executable is UNKNOWN.
        [ -d "$proc" ] || continue
        if data=$(cat "$proc/stat" 2>/dev/null); then
            tail=${data##*) }
            state=${tail%% *}
            case "$state" in Z|X) continue ;; esac
            flags=$(printf '%s\n' "$tail" | awk 'NF >= 7 {print $7}')
            case "$flags" in
                ''|*[!0-9]*) ;;
                *) [ $((flags & 2097152)) -ne 0 ] && continue ;;
            esac
        fi
        [ ! -d "$proc" ] || fail "live process executable unreadable"
    done
    [ "$seen" -eq 1 ] || fail "empty process inventory"
    return 0
}

txn_step_services() {
    txn_step_services_done ||
        fail "live service ownership unproven; no signals sent; stop services manually after verifying ownership"
}

# Refuse unproven live processes BEFORE gates, lock or marker writes.
if [ "$mode" = --remove ]; then txn_step_services; fi

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
    if [ -n "${TXN_CACHE_STAGE:-}" ]; then
        case "$TXN_CACHE_STAGE" in "$snap"/.packages.*) rm -rf "$TXN_CACHE_STAGE";; esac
        TXN_CACHE_STAGE=''
    fi
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
    if txn_chain_present; then
        # Delete exactly the KAS jump as serialized live; never a flush.
        _jump=$(iptables -t mangle -S PREROUTING 2>/dev/null | grep -F -- '-j _CUST_BYPASS_WA_') ||
            _jump=''
        if [ -n "$_jump" ]; then
            set -f
            iptables -t mangle $(printf '%s\n' "$_jump" | sed 's/^-A /-D /') ||
                fail "cannot detach the KAS PREROUTING jump"
            set +f
        fi
        # Delete each chain rule through its own exact -D built from the
        # live -S serialization (resume-safe: a partially deleted chain
        # simply has fewer rules left). No -F, no table-wide flush.
        _rules=$(iptables -t mangle -S _CUST_BYPASS_WA_) ||
            fail "cannot read the owned chain"
        while IFS= read -r _rule; do
            case "$_rule" in
                '-A _CUST_BYPASS_WA_ '*)
                    set -f
                    iptables -t mangle $(printf '%s\n' "$_rule" | sed 's/^-A /-D /') ||
                        fail "cannot delete a verified KAS rule"
                    set +f
                    ;;
            esac
        done <<_TXN_RULES
$_rules
_TXN_RULES
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

# The owned proxy interface is the ledger claim (Proxy0 on a clean
# install, Proxy1 beside a foreign Proxy0). Recorded in the journal at
# begin so predicates keep working after the ledger itself is removed.
txn_owned_proxy() {
    if [ -f "$journal" ] && [ ! -L "$journal" ]; then
        _tp=$(awk '$1 == "owned-proxy" { print $2; exit }' "$journal")
        case "$_tp" in
            Proxy[0-9]) printf '%s' "$_tp"; return 0 ;;
        esac
    fi
    _tp=$(awk -F'|' '$1 == "owned" && $2 == "proxy" { print $3; exit }' \
        "$root/opt/etc/keenetic-auto-setup/ownership.v1" 2>/dev/null)
    case "$_tp" in
        Proxy[0-9]) printf '%s' "$_tp"; return 0 ;;
    esac
    return 1
}

txn_proxy_present() {
    _own=$(txn_owned_proxy) || fail 'cannot resolve the owned proxy interface'
    ndmc -c 'show running-config' 2>/dev/null | tr -d '\r' | grep -q "^interface $_own$"
}
txn_step_proxy_done() { ! txn_proxy_present; }
txn_step_proxy() {
    _own=$(txn_owned_proxy) || fail 'cannot resolve the owned proxy interface'
    if txn_proxy_present; then
        ndmc -c "no interface $_own" >/dev/null 2>&1 ||
            fail "ndmc rejected removal of the owned $_own interface"
    fi
    if txn_proxy_present; then
        fail "owned $_own still present after removal"
    fi
    ndmc -c 'system configuration save' >/dev/null 2>&1 ||
        fail "cannot persist the Keenetic configuration after teardown"
}

txn_step_opkg_done() {
    _list=$(opkg list-installed 2>/dev/null) || return 1
    ! printf '%s\n' "$_list" | grep -Eq '^(mihomo|magitrickle)[[:space:]]'
}
txn_step_opkg() {
    txn_step_services_done || fail 'services restarted before package removal'
    for pkg in magitrickle mihomo; do
        if printf '%s\n' "$(opkg list-installed 2>/dev/null)" | grep -Eq "^${pkg}[[:space:]]"; then
            opkg remove "$pkg" ||
                fail "opkg refused to remove the ledger-owned $pkg (shared consumer?)"
        fi
    done
    # opkg remove may delete the packaged YAMLs; they are USER data and
    # must survive every outcome of the removal transaction.
    for _yaml in /opt/etc/mihomo/config.yaml /opt/var/lib/magitrickle/config.yaml; do
        if [ ! -e "$root$_yaml" ] && [ ! -L "$root$_yaml" ]; then
            mkdir -p "$root${_yaml%/*}" || fail "cannot retain user YAML directory"
            cp -p "$snap/files$_yaml" "$root$_yaml" || fail "cannot retain user YAML"
            printf '[INFO] user YAML retained from the private snapshot: %s\n' "$_yaml"
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

# Exact-version IPKs: trusted SHA256 plus installed Package/Version/Architecture.
# KAS_ROLLBACK_IPKS is an operator-approved data file: SHA256|local-path-or-HTTPS.
# A basename is relative to that file. It is never sourced or evaluated.
txn_pkg_expected() {
    local pkg ver arch base
    pkg=$1
    ver=$(opkg list-installed 2>/dev/null | awk -v p="$pkg" '$1==p {v=$3;n++} END {if(n==1)print v;else exit 1}') || return 1
    arch=$(opkg status "$pkg" 2>/dev/null | awk '$1=="Architecture:" {v=$2;n++} END {if(n==1)print v;else exit 1}') || return 1
    case "$ver" in ''|*[!A-Za-z0-9.+:~_-]*) return 1;; esac
    base=$arch
    [ "$pkg" != magitrickle ] || base=${arch%_kn}
    case "$base" in aarch64-3.10|armv7-3.2|mipsel-3.4|mips-3.4) ;; *) return 1;; esac
    opkg print-architecture | awk -v a="$arch" -v b="$base" '$1=="arch" && ($2==a || $2==b) {ok=1} END {exit !ok}' || return 1
    printf '%s %s\n' "$ver" "$arch"
}

txn_ipk_check() { # file package version architecture approved-SHA256
    local file pkg ver arch sha filename names ctrl data member control extract
    file=$1; pkg=$2; ver=$3; arch=$4; sha=$5; filename=${file##*/}
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    [ "${#sha}" -eq 64 ] || return 1
    case "$sha" in *[!0-9A-Fa-f]*) return 1;; esac
    sha=$(printf '%s' "$sha" | tr A-F a-f)
    case "$filename" in "${pkg}_${ver}_${arch}.ipk"|"${pkg}_${ver}_entware_${arch}.ipk") ;; *) return 1;; esac
    [ "$(sha256sum "$file" | awk '{print $1}')" = "$sha" ] || return 1
    # BusyBox does not auto-detect gzip with -tf/-xOf (GNU tar does).
    if names=$(tar -tzf "$file" 2>/dev/null); then extract=-xzOf
    else names=$(tar -tf "$file" 2>/dev/null) || return 1; extract=-xOf; fi
    printf '%s\n' "$names" | awk '
        {n=$0;if(substr(n,1,2)=="./")n=substr(n,3);if(n=="")next
         if(n!="debian-binary" && n!="control.tar.gz" && n!="data.tar.gz")bad=1
         seen[n]++}
        END {exit (bad || seen["debian-binary"]!=1 || seen["control.tar.gz"]!=1 || seen["data.tar.gz"]!=1)}' || return 1
    ctrl=$(printf '%s\n' "$names" | grep -E '^([.]/)?control[.]tar[.]gz$') || return 1
    data=$(printf '%s\n' "$names" | grep -E '^([.]/)?data[.]tar[.]gz$') || return 1
    member=$(printf '%s\n' "$names" | grep -E '^([.]/)?debian-binary$') || return 1
    [ "$(tar "$extract" "$file" "$member" 2>/dev/null)" = 2.0 ] || return 1
    member=$(tar "$extract" "$file" "$ctrl" 2>/dev/null | tar -tzf - 2>/dev/null |
        awk '$0=="control" || $0=="./control" {m=$0;n++} END {if(n==1)print m;else exit 1}') || return 1
    control=$(tar "$extract" "$file" "$ctrl" 2>/dev/null | tar -xzOf - "$member" 2>/dev/null) || return 1
    printf '%s\n' "$control" | awk -v p="$pkg" -v v="$ver" -v a="$arch" '
        $1=="Package:" {np++;if($2!=p || NF!=2)bad=1}
        $1=="Version:" {nv++;if($2!=v || NF!=2)bad=1}
        $1=="Architecture:" {na++;if($2!=a || NF!=2)bad=1}
        END {exit (bad || np!=1 || nv!=1 || na!=1)}' || return 1
    tar "$extract" "$file" "$data" 2>/dev/null | tar -tzf - >/dev/null 2>&1
}

txn_store_ipk() { # source sha pkg ver arch cache
    local src sha pkg ver arch cache filename
    src=$1; sha=$2; pkg=$3; ver=$4; arch=$5; cache=$6; filename=${src##*/}
    [ "${#sha}" -eq 64 ] || return 1
    case "$sha" in *[!0-9A-Fa-f]*) return 1;; esac
    case "$filename" in "${pkg}_${ver}_${arch}.ipk"|"${pkg}_${ver}_entware_${arch}.ipk") ;; *) return 1;; esac
    case "$src" in
        https://*) curl -fsSL --connect-timeout 5 --max-time 180 "$src" -o "$cache/$filename" 2>/dev/null || return 1;;
        /*) [ -f "$src" ] && [ ! -L "$src" ] && cp "$src" "$cache/$filename" 2>/dev/null || return 1;;
        *) return 1;;
    esac
    txn_ipk_check "$cache/$filename" "$pkg" "$ver" "$arch" "$sha" || return 1
    printf '%s  %s\n' "$(printf '%s' "$sha" | tr A-F a-f)" "$filename" >> "$cache/MANIFEST" || return 1
    TXN_IPK_NAME=$filename
}

txn_fetch_ipk() { # pkg ver arch cache
    local pkg ver arch cache approved hit sha src dirs conf path list feed filename
    pkg=$1; ver=$2; arch=$3; cache=$4; approved=${KAS_ROLLBACK_IPKS:-}
    if [ -n "$approved" ]; then
        [ -f "$approved" ] && [ ! -L "$approved" ] || return 1
        [ "$(ls -ld "$approved" | cut -c1-10)" = -rw------- ] || return 1
        [ "$(ls -ldn "$approved" | awk '{print $3}')" = "$(id -u)" ] || return 1
        # Reject malformed/duplicate records, not just the selected entry.
        awk -F'|' '/^#/ || /^$/ {next}
          {n=$2;sub(/^.*\//,"",n);if(NF!=2 || length($1)!=64 || $1~/[^0-9A-Fa-f]/ || n=="" || seen[n]++)bad=1}
          END {exit bad}' "$approved" || return 1
        hit=$(awk -F'|' -v a="${pkg}_${ver}_${arch}.ipk" -v b="${pkg}_${ver}_entware_${arch}.ipk" '
          /^#/ || /^$/ {next} {n=$2;sub(/^.*\//,"",n);if(n==a || n==b){row=$0;count++}}
          END {if(count==1)print row;else if(count>1)exit 1}' "$approved") || return 1
        if [ -n "$hit" ]; then
            sha=${hit%%|*}; src=${hit#*|}
            case "$src" in
                https://*|/*) ;;
                */*) return 1;;
                *) src="$(CDPATH= cd "$(dirname "$approved")" && pwd)/$src" || return 1;;
            esac
            txn_store_ipk "$src" "$sha" "$pkg" "$ver" "$arch" "$cache"
            return $?
        fi
    fi
    dirs='/opt/var/opkg-lists /opt/var/opkg/lists'
    for conf in "$root/opt/etc/opkg.conf" "$root"/opt/etc/opkg/*.conf; do
        [ -f "$conf" ] && [ ! -L "$conf" ] || continue
        dirs="$dirs $(awk '$1=="lists_dir" && NF==3 {print $3}' "$conf")"
    done
    for path in $dirs; do
        case "$path" in /*) ;; *) continue;; esac
        [ ! -L "$root$path" ] || continue
        for list in "$root$path"/*; do
            [ -f "$list" ] && [ ! -L "$list" ] || continue
            hit=$(awk -v P="$pkg" -v V="$ver" -v A="$arch" '
              function flush(){if(p==P && v==V && a==A && f!="" && h!=""){n++;row=f "|" h}p=v=a=f=h=""}
              $1=="Package:" {if(p!="")flush();p=$2}
              $1=="Version:" {v=$2} $1=="Architecture:" {a=$2}
              $1=="Filename:" {f=$2} $1=="SHA256sum:" {h=$2}
              /^$/ {flush()} END {flush();if(n==1)print row;else exit 1}' "$list") || continue
            filename=${hit%%|*}; sha=${hit#*|}
            case "$filename" in "${pkg}_${ver}_${arch}.ipk"|"${pkg}_${ver}_entware_${arch}.ipk") ;; *) continue;; esac
            feed=$(awk -v n="${list##*/}" '($1=="src" || $1=="src/gz") && $2==n {print $3}' "$root"/opt/etc/opkg/*.conf 2>/dev/null) || continue
            case "$feed" in https://*) ;; *) continue;; esac
            txn_store_ipk "${feed%/}/$filename" "$sha" "$pkg" "$ver" "$arch" "$cache" && return 0
        done
    done
    printf '[INFO] rollback cache: exact SHA256-approved IPK unavailable for %s %s\n' "$pkg" "$ver"
    return 1
}

txn_cache_external() {
    # Same storage convention as install.sh: deepest mount, external EXT4.
    local mount
    mount=$(awk -v path="${snap#"$root"}" '
      {m=$2;if(path==m || m=="/" || index(path,m "/")==1)if(length(m)>best){best=length(m);s=$1;f=$3}}
      END {if(best)print s "|" f;else exit 1}' "$root/proc/mounts") || return 1
    case "$mount" in /dev/sd*'|ext4'|/dev/nvme*'|ext4'|/tmp/mnt/*'|ext4') return 0;; esac
    return 1
}

txn_build_cache() { # private staging dir, never the published cache
    local cache pkg expected ver arch
    cache=$1
    : > "$cache/wanted" && : > "$cache/MANIFEST" || return 1
    for pkg in mihomo magitrickle; do
        expected=$(txn_pkg_expected "$pkg") || return 1
        ver=${expected% *}; arch=${expected##* }
        txn_fetch_ipk "$pkg" "$ver" "$arch" "$cache" || return 1
        printf '%s %s %s %s\n' "$pkg" "$ver" "$arch" "$TXN_IPK_NAME" >> "$cache/wanted" || return 1
    done
    txn_cache_verified "$cache"
}

txn_cache_verified() {
    local cache pkg ver arch filename extra sha seen count expected
    cache=${1:-"$snap/packages"}; seen=''; count=0
    [ -d "$cache" ] && [ ! -L "$cache" ] || return 1
    for filename in wanted MANIFEST; do
        [ -f "$cache/$filename" ] && [ ! -L "$cache/$filename" ] || return 1
    done
    [ "$(wc -l < "$cache/MANIFEST")" -eq 2 ] || return 1
    while IFS=' ' read -r pkg ver arch filename extra; do
        [ -z "$extra" ] && [ -n "$filename" ] || return 1
        case "$pkg" in mihomo|magitrickle) ;; *) return 1;; esac
        case " $seen " in *" $pkg "*) return 1;; esac
        seen="$seen $pkg"; count=$((count+1))
        expected=$(txn_pkg_expected "$pkg") || return 1
        [ "$expected" = "$ver $arch" ] || return 1
        case "$filename" in "${pkg}_${ver}_${arch}.ipk"|"${pkg}_${ver}_entware_${arch}.ipk") ;; *) return 1;; esac
        sha=$(awk -v f="$filename" '$2==f && NF==2 {s=$1;n++} END {if(n==1)print s;else exit 1}' "$cache/MANIFEST") || return 1
        txn_ipk_check "$cache/$filename" "$pkg" "$ver" "$arch" "$sha" || return 1
    done < "$cache/wanted"
    [ "$count" -eq 2 ] && [ "$(find "$cache" -maxdepth 1 -name '*.ipk' | wc -l)" -eq 2 ]
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
if [ "$mode" = --prepare ]; then
    [ ! -e "$journal" ] && [ ! -L "$journal" ] ||
        fail 'journal already exists; do not re-prepare an interrupted transaction'
    TXN_CACHE_VALID=0
    if txn_cache_verified; then
        TXN_CACHE_VALID=1
    else
        # Revoke a legacy PREPARED-without-cache record; never destroy its data.
        rm -f "$txn/prepare.v1" || fail 'cannot invalidate incomplete preparation'
    fi
    txn_cache_external || fail 'rollback IPKs require verified external EXT4 /opt; internal flash is not used'
    if [ "$TXN_CACHE_VALID" -eq 0 ]; then
        [ ! -e "$snap/packages" ] && [ ! -L "$snap/packages" ] ||
            fail 'existing rollback cache unverified and retained; use a fresh snapshot after review'
        TXN_CACHE_STAGE=$(mktemp -d "$snap/.packages.XXXXXXXX") || fail 'cannot stage rollback cache'
        txn_build_cache "$TXN_CACHE_STAGE" || fail 'rollback cache incomplete or unverified; preparation NOT complete'
        [ ! -e "$snap/packages" ] && [ ! -L "$snap/packages" ] || fail 'rollback cache appeared during preparation'
        mv "$TXN_CACHE_STAGE" "$snap/packages" || fail 'cannot publish verified rollback cache'
        TXN_CACHE_STAGE=''
        txn_cache_verified || fail 'published rollback cache verification failed'
    fi
    printf '[PASS] Rollback cache verified: exact installed IPKs with approved SHA256 and control metadata\n'
fi
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
    txn_step_services
    [ ! -L "$snap/transaction/prepare.v1" ] && [ -f "$snap/transaction/prepare.v1" ] ||
        fail "no prepared transaction for this snapshot; run --prepare first"

    if [ "$resuming" -eq 1 ]; then
        tail -n 1 "$journal" | grep -qx 'complete' && resuming=2
    fi

    if [ "$resuming" = 2 ]; then
        # A completed transaction re-run must be a no-op PASS, never a replay.
        txn_all_steps_done ||
            fail "journal says complete but owned resources remain; manual recovery required"
        printf '[PASS] KAS already removed (idempotent re-run); nothing changed\n'
        printf '[INFO] Rollback data retained in %s\n' "$snap"
        exit 0
    fi

    if [ "$resuming" -ne 1 ]; then
        # Fresh removal: exact-version rollback cache must verify BEFORE any
        # mutation. Without restorable packages the transaction refuses.
        txn_cache_verified ||
            fail "rollback cache missing or not the installed versions; re-run --prepare with the feeds reachable"
        txn_all_steps_done &&
            fail "system already matches the removed state; nothing to do"
    else
        printf '[INFO] Resuming an interrupted removal (journal present); auditing state\n'
        # The interrupted steps must form a prefix: done steps may not follow
        # undone steps; anything else is an untrusted hybrid state.
        _seen_undone=0
        for step in $TXN_STEPS; do
            # `services` leaves no observable trace (already-stopped is a
            # legal pre-state); it is idempotent and simply re-runs.
            if [ "$step" = services ]; then continue; fi
            if txn_step_done "$step"; then
                [ "$_seen_undone" -eq 0 ] ||
                    fail "inconsistent removal state at step $step; manual recovery required"
            else
                _seen_undone=1
            fi
        done
    fi

    REMOVE_ACTIVE=1
    if [ "$resuming" -ne 1 ]; then
        : > "$journal" || fail "cannot create transaction journal"
        printf 'KAS_UNINSTALL_JOURNAL_V1\n' >> "$journal"
        txn_journal_line begin "$name"
        _own_proxy=$(txn_owned_proxy) || fail "cannot resolve the owned proxy interface"
        txn_journal_line owned-proxy "$_own_proxy"
    fi

    for step in $TXN_STEPS; do
        if txn_step_done "$step"; then
            [ "$resuming" -eq 1 ] &&
                printf '[INFO] step %s already complete; skipping\n' "$step"
            continue
        fi
        txn_journal_line intent "$step"
        txn_step_run "$step"
        txn_step_done "$step" || fail "step $step did not reach its expected state"
        txn_journal_line done "$step"
        txn_fault_check "$step"
    done

    txn_journal_line complete
    REMOVE_ACTIVE=0
    printf '[PASS] KAS removal transaction complete: only ledger-owned resources were removed\n'
    printf '[REVIEW] DNS intercept left ENABLED (it predates nothing provably foreign; disable manually if unwanted)\n'
    printf '[INFO] Rollback data and both user YAML copies retained in %s\n' "$snap"
    printf '[INFO] Reinstall: opkg install %s/packages/*.ipk and restore YAML from %s/files, or re-run install.sh\n' "$snap" "$snap"
fi
