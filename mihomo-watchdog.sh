#!/bin/sh

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

# BEGIN MIHOMO INIT RESOLUTION v1 (issue #355)
# Single authoritative Mihomo init-script resolution for standalone KAS
# tools. Upstream Entware renamed the packaged script S99mihomo ->
# S28mihomo (ee4b689) while earlier feeds and the entware-go fork still
# ship S99, so both names are field realities. Contract (identical block
# in every consumer; guard-tested by
# tests/mihomo-init-contract-regression.py):
#   - only the two known names are candidates, never a glob;
#   - exactly one executable regular-file candidate is authoritative
#     (return 0, MIHOMO_INIT_RESOLVED);
#   - two executable candidates mean ambiguous ownership: return 2 with
#     state "ambiguous" — KAS refuses to pick one because two Mihomo
#     launches at boot would break the one-Mihomo invariant; the operator
#     removes the stale leftover;
#   - classification dereferences the path exactly like the boot init:
#     a directory or a non-executable/dangling entry is unusable (return
#     2 carries the offending path, state notfile:/notexec:); KAS only
#     ever executes stop/start/restart through the resolved path and
#     never modifies it;
#   - no known name exists: return 1, state "absent".
# Diagnostics only: this block never creates, renames, chmods or deletes
# package-owned init scripts (owner decision 2026-11-03).
MIHOMO_INIT_RESOLVED=""
MIHOMO_INIT_STATE=""
resolve_mihomo_init() {
    _mir_found=""
    _mir_state="absent"
    for _mir_path in /opt/etc/init.d/S28mihomo /opt/etc/init.d/S99mihomo; do
        if [ -d "$_mir_path" ]; then
            _mir_state="notfile:$_mir_path"
        elif [ -f "$_mir_path" ] && [ -x "$_mir_path" ]; then
            if [ -n "$_mir_found" ]; then
                MIHOMO_INIT_STATE="ambiguous"
                return 2
            fi
            _mir_found="$_mir_path"
            _mir_state=""
        elif [ -e "$_mir_path" ] || [ -L "$_mir_path" ]; then
            _mir_state="notexec:$_mir_path"
        fi
    done
    if [ -n "$_mir_found" ]; then
        MIHOMO_INIT_RESOLVED="$_mir_found"
        MIHOMO_INIT_STATE=""
        return 0
    fi
    MIHOMO_INIT_STATE="$_mir_state"
    if [ "$_mir_state" = "absent" ]; then
        return 1
    fi
    return 2
}
# END MIHOMO INIT RESOLUTION v1



# =========================================================
# MIHOMO WATCHDOG SCRIPT - PRODUCTION VERSION
# ---------------------------------------------------------
# Embedded Linux watchdog for Mihomo proxy
# Current release hardware acceptance includes Keenetic + Entware on mipsel and aarch64.
# See docs/TESTING_STRATEGY.md for the model/architecture evidence matrix.

# All WAN checks are performed DIRECTLY, without Mihomo.

# If no target responds, WAN is considered unavailable.
# In this case Mihomo is NOT restarted because its actual
# state cannot be determined.

# Features:
# - Two-stage WAN connectivity check
# - Normal Internet targets checked first
# - Whitelist fallback for restricted/mobile networks
# - Mihomo port availability check
# - End-to-end SOCKS5h tunnel check with one confirming retry before restart
# - Restart rate limiting (cooldown to prevent loops)
# - PID/starttime locks: stale recovery and exclusive maintenance/restart
# - Hard --max-time on every probe so a stalled target cannot wedge the run
# - Jitter for multi-router deployments (~20 nodes)

# Canonical location: /opt/bin/mihomo_watchdog.sh (maintained by
# update-watchdog.sh). Cron runs it through the thin scheduler wrapper
# /opt/etc/cron.5mins/mihomo_watchdog (exec, every 5 minutes).
# =========================================================

# --- FILES ---

LOG="/opt/var/log/mihomo_watchdog.log"
LOCK_DIR="/tmp/mihomo_watchdog.lock.d"
RESTART_STATE="/tmp/mihomo_watchdog.restart"
HEALTHY_STATE="/tmp/mihomo_watchdog.healthy"


# --- CONFIGURATION ---

# Normal Internet targets.
# These are checked first.
# If at least one target responds, WAN is considered available.
WAN_PRIMARY_TARGETS="http://cp.cloudflare.com http://www.google.com"

# Fallback targets for restricted/whitelist networks.
# Checked only if ALL primary targets fail.
# At least one responding target is enough to consider WAN available.
#
# For Russian mobile networks these targets provide a
# practical fallback when normal Internet access is restricted.
WAN_WHITELIST_TARGETS="http://gosuslugi.ru http://ya.ru http://mail.ru http://vk.ru http://vk.com"

# Mihomo mixed proxy port (HTTP + SOCKS5)
PROXY="127.0.0.1:7890"

# A single tunnel probe can fail transiently (endpoint jitter, TLS/DNS timing,
# outbound failover). Require one confirming retry before restarting Mihomo.
PROXY_RETRY_DELAY=3

# Minimum seconds between restarts to prevent storm during upstream outage
MIN_RESTART_INTERVAL=300

# Log rotation thresholds
LOG_MAX_LINES=500
LOG_KEEP_LINES=300

# Healthy checks run every 5 minutes, but routine success logs are throttled.
# Problem/restart events remain immediate and reset this heartbeat so the next
# healthy run is always recorded as a recovery marker.
HEALTHY_LOG_INTERVAL=1200


# --- INCIDENT DIAGNOSTICS (issue #328, observability only) ---
#
# Compact per-class failure accounting in tmpfs plus event-triggered,
# bounded read-only diagnostics. These settings NEVER influence the
# restart decision: the restart policy below is unchanged.
#
# Classes are accounted separately: wan_failure, proxy_tunnel_failure,
# port_failure. WAN_UNREACHABLE is UNKNOWN for the tunnel state and never
# touches tunnel history; a successful matching check resets consecutive
# failures but keeps the repeat window until it expires by time.
INCIDENT_STATE="/tmp/mihomo_watchdog.incidents"

# A confirmed failure cycle must repeat within this window before the
# incident diagnostics (L2) are allowed once. Owner guidance: ~2 separate
# failed cron cycles within ~30 minutes.
DIAG_WINDOW_SECS=1800

# Minimum confirmed failed cycles within the window that arm L2.
DIAG_FAIL_THRESHOLD=2

# Separate diagnostic cooldown (independent from MIN_RESTART_INTERVAL):
# at most one L2 diagnostic event per class per this interval.
DIAG_MIN_INTERVAL=900

# Hard cap on extra network requests issued by ONE diagnostic event.
DIAG_MAX_REQUESTS=4

# Independent alternate SOCKS5h target used only during a tunnel incident.
# Never logged as a URL with credentials; only its result class is logged.
DIAG_SOCKS_TARGET_ALT="https://www.cloudflare.com"

# Optional read-only Controller evidence during a tunnel incident.
# Empty by default: no controller request is made unless the operator
# explicitly sets this (e.g. the real external-controller bind, which may
# be a LAN address, not localhost). Only the result class is logged.
MIHOMO_CONTROLLER_URL=""


# Per-run lock prevents overlapping cron checks; lifecycle is taken only for restart.
ml_lock_acquire "$LOCK_DIR" || exit 0

cleanup() {
    ml_lifecycle_release || true
    ml_lock_release "$LOCK_DIR" || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# =========================================================
# JITTER (Random delay 0-24s)
#
# Desynchronizes multiple routers to avoid thundering herd
# against upstream check targets and local Mihomo instance.
# =========================================================

sleep $(( $(date +%s) % 25 ))


# =========================================================
# LOGGING & ROTATION
# =========================================================

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
}

reset_healthy_heartbeat() {
    rm -f "$HEALTHY_STATE"
}

log_healthy() {
    local wan_path="$1"
    local wan_target="$2"
    local now last elapsed state last_path path_changed

    now=$(date +%s)
    last=0
    last_path=""
    path_changed=0

    if [ -f "$HEALTHY_STATE" ]; then
        state=$(cat "$HEALTHY_STATE" 2>/dev/null)
        case "$state" in
            *" "*)
                last=${state%% *}
                last_path=${state#* }
                ;;
            *)
                # Backward compatibility with the older timestamp-only state file.
                last="$state"
                ;;
        esac

        case "$last" in
            ''|*[!0-9]*) last=0 ;;
        esac
        case "$last_path" in
            primary|whitelist|'') ;;
            *) last_path="" ;;
        esac
    fi

    if [ -n "$last_path" ] && [ "$last_path" != "$wan_path" ]; then
        path_changed=1
    fi

    elapsed=$(( now - last ))
    if [ "$last" -eq 0 ] || [ "$elapsed" -ge "$HEALTHY_LOG_INTERVAL" ] || [ "$path_changed" -eq 1 ]; then
        log "[OK] All good | WAN=${wan_path} (${wan_target})"
        last="$now"
    fi

    # Keep the last heartbeat timestamp and the most recently observed WAN path
    # in RAM. primary <-> whitelist transitions are visible immediately without
    # restoring per-run healthy log noise.
    echo "$last $wan_path" > "$HEALTHY_STATE"
}
rotate_log() {
    if [ -f "$LOG" ]; then
        LINES=$(wc -l < "$LOG")

        if [ "$LINES" -gt "$LOG_MAX_LINES" ]; then
            tail -n "$LOG_KEEP_LINES" "$LOG" > "$LOG.tmp" &&
                mv "$LOG.tmp" "$LOG"
        fi
    fi
}


# =========================================================
# INCIDENT DIAGNOSTICS BLOCK (issue #328, observability only)
#
# L0 healthy path: unchanged cheap checks; counters live in tmpfs.
# L1 first confirmed failure: compact evidence line from already collected
#    probe data, before any restart decision is acted upon.
# L2 repeated confirmed incident: one bounded, class-aware, read-only
#    diagnostic event with its own cooldown, request budget and dedup.
# L3 manual deep dive: never automatic; the log points at
#    kas-network-doctor.sh for the operator.
#
# This block never changes the restart decision, never mutates any
# configuration, and degrades silently (obs data skipped) when tmpfs or
# helper tools are unavailable. All state files live in tmpfs like the
# existing restart/healthy markers; a reboot resets the window by design.
# =========================================================

# BEGIN WATCHDOG INCIDENT DIAGNOSTICS v1

# Millisecond clock for probe latency evidence. /proc/uptime is present on
# every supported kernel and has centisecond precision; no GNU date %N and
# no new dependency. Empty result means "latency unknown" and is honest.
now_ms() {
    now_ms_result=""
    [ -r /proc/uptime ] || return 1
    read _nm_up _nm_idle < /proc/uptime || return 1
    case "$_nm_up" in
        *.*)
            _nm_int=${_nm_up%%.*}
            _nm_frac=${_nm_up#*.}
            ;;
        *)
            _nm_int=$_nm_up
            _nm_frac=""
            ;;
    esac
    case "$_nm_int" in ''|*[!0-9]*) return 1 ;; esac
    case "$_nm_frac" in
        ''|*[!0-9]*) _nm_frac="0" ;;
    esac
    while [ "${#_nm_frac}" -lt 3 ]; do
        _nm_frac="${_nm_frac}0"
    done
    _nm_frac=${_nm_frac%"${_nm_frac#???}"}
    # POSIX sh/dash/ash arithmetic reads a leading 0 as octal, so the padded
    # centisecond fraction must re-enter arithmetic as plain decimal: an
    # uptime fraction like .09 pads to "090" and would abort the whole
    # watchdog run with "Illegal number: 090". Strip the zero pad instead.
    _nm_pad=${_nm_frac#"${_nm_frac%%[1-9]*}"}
    [ -n "$_nm_pad" ] || _nm_pad=0
    now_ms_result=$(( _nm_int * 1000 + _nm_pad ))
    return 0
}

# Map a curl exit code to a short fixed category. Raw codes stay visible;
# categories keep shareable logs free of URLs, stderr and target details.
dg_rc_class() {
    case "$1" in
        0)  echo "ok" ;;
        6)  echo "dns" ;;
        7)  echo "connect_refused" ;;
        28) echo "timeout" ;;
        35) echo "tls" ;;
        56) echo "recv_failure" ;;
        '') echo "unknown" ;;
        *)  echo "rc_$1" ;;
    esac
}

# One bounded diagnostic request. Mode selects the proven production probe
# shape (same flags as the regular checks). Sets DG_RC (curl exit code or
# empty when skipped) and DG_MS (elapsed ms or empty). Honors the total
# request budget: over budget means skip with unknown evidence, never an
# unbounded or slowing probe.
DG_REQUESTS=0
dg_probe() {
    DG_RC=""
    DG_MS=""
    [ "$DG_REQUESTS" -lt "$DIAG_MAX_REQUESTS" ] || return 1
    _dg_mode=$1
    _dg_url=$2
    _dg_ms0=""
    if now_ms; then
        _dg_ms0=$now_ms_result
    fi
    case "$_dg_mode" in
        direct)
            curl -s --connect-timeout 3 --max-time 6 --noproxy '*' --head "$_dg_url" >/dev/null 2>&1
            ;;
        socks)
            curl -x "socks5h://$PROXY" -m 5 -s "$_dg_url" >/dev/null 2>&1
            ;;
        controller)
            curl -s --connect-timeout 2 --max-time 3 "$_dg_url" >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
    DG_RC=$?
    if [ -n "$_dg_ms0" ] && now_ms; then
        DG_MS=$(( now_ms_result - _dg_ms0 ))
    fi
    return "$DG_RC"
}

# Safe process-state word for summaries. Uses the standalone mp_state
# contract (0 running / 1 stopped / 2 unknown); anything else stays unknown.
dg_mihomo_state() {
    mp_state >/dev/null 2>&1
    case $? in
        0) echo "running" ;;
        1) echo "stopped" ;;
        *) echo "unknown" ;;
    esac
}

# Stable small hash for diagnostic summary dedup. cksum is a POSIX tool
# present in BusyBox; when absent, dedup is disabled (hash empty) and the
# full event is logged - degraded, never wrong.
dg_sum_hash() {
    dg_sum_hash_result=""
    _dg_h=$(printf '%s' "$1" | cksum 2>/dev/null | cut -d' ' -f1)
    case "$_dg_h" in
        ''|*[!0-9]*) return 0 ;;
        *) dg_sum_hash_result=$_dg_h ;;
    esac
    return 0
}

# Per-class diagnostic gate: repeated-incident threshold, separate cooldown
# and maintenance/lock awareness. Returns 0 when the L2 event may run now.
# Below the threshold the gate returns 1 silently: that is the normal quiet
# state, not a skip worth logging.
dg_diag_gate() {
    _dg_g_class=$1
    eval "_dg_g_cycles=\$INC_${_dg_g_class}_window_count"
    case "$_dg_g_cycles" in
        ''|*[!0-9]*) _dg_g_cycles=0 ;;
    esac
    [ "$_dg_g_cycles" -ge "$DIAG_FAIL_THRESHOLD" ] || return 1
    eval "_dg_g_last=\$INC_${_dg_g_class}_diag_last"
    case "$_dg_g_last" in
        ''|*[!0-9]*) _dg_g_last=0 ;;
    esac
    if ml_marker_busy; then
        log "[DIAG-SKIP] ${_dg_g_class} | maintenance marker busy"
        return 1
    fi
    _dg_g_now=$(date +%s)
    _dg_g_elapsed=$(( _dg_g_now - _dg_g_last ))
    if [ "$_dg_g_last" -gt 0 ] && [ "$_dg_g_elapsed" -lt "$DIAG_MIN_INTERVAL" ]; then
        log "[DIAG-SKIP] ${_dg_g_class} | diagnostic cooldown (${_dg_g_elapsed}s < ${DIAG_MIN_INTERVAL}s)"
        return 1
    fi
    return 0
}

# Record the L2 outcome (cooldown stamp, dedup counter, summary hash) and
# emit deduplicated [DIAG-SUMMARY] logging. Same summary inside the window
# collapses into a single repeat line instead of a log wall.
dg_diag_finish() {
    _dg_f_class=$1
    _dg_f_summary=$2
    dg_sum_hash "$_dg_f_summary"
    _dg_f_hash=$dg_sum_hash_result
    eval "_dg_f_prev=\$INC_${_dg_f_class}_hash; _dg_f_occ=\$INC_${_dg_f_class}_diag_occ"
    if [ -n "$_dg_f_hash" ] && [ -n "$_dg_f_prev" ] && [ "$_dg_f_hash" = "$_dg_f_prev" ]; then
        eval "INC_${_dg_f_class}_diag_occ=\$(( \$INC_${_dg_f_class}_diag_occ + 1 ))"
        eval "INC_${_dg_f_class}_diag_last=\$(date +%s)"
        eval "_dg_f_occ=\$INC_${_dg_f_class}_diag_occ"
        log "[DIAG] repeat ${_dg_f_class} | occurrences=$_dg_f_occ | summary unchanged"
    else
        eval "INC_${_dg_f_class}_hash=\"$_dg_f_hash\""
        eval "INC_${_dg_f_class}_diag_occ=1"
        eval "INC_${_dg_f_class}_diag_last=\$(date +%s)"
        log "[DIAG-SUMMARY] ${_dg_f_summary}"
        log "[INFO] Full Network Doctor: run manually for deeper evidence (kas-network-doctor.sh)"
    fi
    incident_save
    return 0
}

# L2 for proxy_tunnel_failure: only when WAN and local port are already
# proven up in this run. Two independent SOCKS5h targets plus optional
# read-only Controller evidence. Classification stays an observation:
# a passing alt target does not prove the user traffic path.
run_diag_tunnel() {
    dg_diag_gate proxy_tunnel_failure || return 0
    eval "_rdt_cycles=\$INC_proxy_tunnel_failure_window_count"
    log "[DIAG-TRIGGER] proxy_tunnel | confirmed_cycles=$_rdt_cycles window=${DIAG_WINDOW_SECS}s | reason=repeated_confirmed_failure"
    DG_REQUESTS=0
    dg_probe socks "https://www.google.com"
    _rdt_rc1=$DG_RC
    _rdt_c1=$(dg_rc_class "$DG_RC")
    dg_probe socks "$DIAG_SOCKS_TARGET_ALT"
    _rdt_rc2=$DG_RC
    _rdt_c2=$(dg_rc_class "$DG_RC")
    _rdt_ctl="not_configured"
    if [ -n "$MIHOMO_CONTROLLER_URL" ]; then
        if dg_probe controller "${MIHOMO_CONTROLLER_URL%/}/version"; then
            _rdt_ctl="ok"
        else
            _rdt_ctl="unavailable"
        fi
    fi
    log "[DIAG] socks_primary=${_rdt_c1}(rc=${_rdt_rc1:-unknown}) | socks_alt=${_rdt_c2}(rc=${_rdt_rc2:-unknown}) | controller=$_rdt_ctl | requests=$DG_REQUESTS"
    _rdt_cause="upstream_or_route_unknown"
    _rdt_conf="UNKNOWN"
    _rdt_action="manual_network_doctor"
    if [ "$_rdt_c1" = "ok" ] && [ "$_rdt_c2" = "ok" ]; then
        _rdt_cause="transient_recovered_during_diag"
        _rdt_conf="LOW"
        _rdt_action="observe_next_cycles"
    elif [ "$_rdt_c1" = "ok" ] || [ "$_rdt_c2" = "ok" ]; then
        _rdt_cause="single_target_or_route_suspected"
        _rdt_conf="LOW"
        _rdt_action="review_rules"
    fi
    dg_diag_finish proxy_tunnel_failure "tunnel=FAIL | wan=$wan_path | mihomo=$(dg_mihomo_state) | port=up | socks_primary=$_rdt_c1 | socks_alt=$_rdt_c2 | cause=$_rdt_cause | confidence=$_rdt_conf | action=$_rdt_action"
    return 0
}

# L2 for wan_failure: direct-path evidence only. The budget is not spent
# on SOCKS probes: with WAN unconfirmed, tunnel state stays UNKNOWN and a
# Mihomo fault must not be implied (owner rule for #328).
run_diag_wan() {
    dg_diag_gate wan_failure || return 0
    eval "_rdw_cycles=\$INC_wan_failure_window_count"
    log "[DIAG-TRIGGER] wan_failure | confirmed_cycles=$_rdw_cycles window=${DIAG_WINDOW_SECS}s | reason=repeated_confirmed_failure"
    DG_REQUESTS=0
    set -- $WAN_PRIMARY_TARGETS
    _rdw_target=$1
    if [ -z "$_rdw_target" ]; then
        log "[DIAG] no primary target configured | scope=direct_path"
        dg_diag_finish wan_failure "wan=FAIL | scope=direct_path | direct=unconfigured | cause=configuration | confidence=HIGH | action=check_watchdog_config"
        return 0
    fi
    dg_probe direct "$_rdw_target"
    _rdw_c=$(dg_rc_class "$DG_RC")
    log "[DIAG] direct_primary=${_rdw_c}(rc=${DG_RC:-unknown}) | scope=direct_path | socks_probes=skipped_by_design"
    _rdw_cause="direct_path_unreachable"
    _rdw_conf="UNKNOWN"
    _rdw_action="check_isp_wan_and_dns"
    case "$_rdw_c" in
        dns)     _rdw_cause="dns_resolution_suspected" ; _rdw_conf="LOW" ;;
        timeout|connect_refused|tls|recv_failure)
                 _rdw_cause="direct_connectivity_suspected" ; _rdw_conf="LOW" ;;
        ok)      _rdw_cause="wan_flapping_or_transient" ; _rdw_conf="LOW" ; _rdw_action="observe_next_cycles" ;;
    esac
    dg_diag_finish wan_failure "wan=FAIL | scope=direct_path | direct_primary=$_rdw_c | cause=$_rdw_cause | confidence=$_rdw_conf | action=$_rdw_action"
    return 0
}

# L2 for port_failure: local facts only, zero network probes (owner rule:
# a local failure must not spend budget on external TLS/DNS targets).
run_diag_port() {
    dg_diag_gate port_failure || return 0
    eval "_rdp_cycles=\$INC_port_failure_window_count"
    log "[DIAG-TRIGGER] port_failure | confirmed_cycles=$_rdp_cycles window=${DIAG_WINDOW_SECS}s | reason=repeated_confirmed_failure"
    _rdp_state=$(dg_mihomo_state)
    log "[DIAG] port=down | mihomo=$_rdp_state | scope=local_only (no external probes)"
    if [ "$_rdp_state" = "stopped" ]; then
        dg_diag_finish port_failure "port=FAIL | mihomo=stopped | cause=process_down | confidence=HIGH | action=check_mihomo_service_logs"
    else
        dg_diag_finish port_failure "port=FAIL | mihomo=$_rdp_state | cause=listener_not_accepting | confidence=MEDIUM | action=check_mihomo_service_logs"
    fi
    return 0
}

# Bounded post-restart tunnel observation, run only after an actual
# restart. [RESTART-OK] proves the process; this adds whether SOCKS works
# again immediately. It is a correlation record, not proof that the restart
# repaired the upstream, and it never triggers further actions here.
# The probe uses dg_probe (defined above both call sites): this function is
# reachable from the port-failure path, which executes before the tunnel
# section of the script has defined proxy_tunnel_ok.
wd_post_recheck() {
    DG_REQUESTS=0
    dg_probe socks "https://www.google.com"
    if [ "$DG_RC" = "0" ]; then
        log "[INFO] post-restart tunnel recheck: SOCKS recovered (correlation only; next cycle re-verifies)"
    elif [ -z "$DG_RC" ]; then
        log "[INFO] post-restart tunnel recheck: unknown (probe skipped or budget exhausted)"
    else
        log "[INFO] post-restart tunnel recheck: still failing (curl_rc=$DG_RC)"
    fi
    return 0
}

# --- per-class incident counters (tmpfs, all numeric fields) ---
# One line per class:
#   <class> <confirmed> <consecutive> <window_count> <window_start>
#           <first_seen> <last_seen> <transient> <diag_last> <diag_occ> <hash>

incident_valid_class() {
    case "$1" in
        wan_failure|proxy_tunnel_failure|port_failure) return 0 ;;
        *) return 1 ;;
    esac
}

incident_load() {
    for _il_c in wan_failure proxy_tunnel_failure port_failure; do
        eval "INC_${_il_c}_confirmed=0 INC_${_il_c}_consecutive=0 INC_${_il_c}_window_count=0 INC_${_il_c}_window_start=0 INC_${_il_c}_first=0 INC_${_il_c}_last=0 INC_${_il_c}_transient=0 INC_${_il_c}_diag_last=0 INC_${_il_c}_diag_occ=0 INC_${_il_c}_hash=''"
    done
    [ -r "$INCIDENT_STATE" ] || return 0
    while IFS= read -r _il_line; do
        case "$_il_line" in
            ''|'#'*) continue ;;
        esac
        # shellcheck disable=SC2086 # fixed 11-field numeric record
        set -- $_il_line
        [ "$#" -eq 11 ] || continue
        incident_valid_class "$1" || continue
        _il_c=$1
        eval "INC_${_il_c}_confirmed=\$2 INC_${_il_c}_consecutive=\$3 INC_${_il_c}_window_count=\$4 INC_${_il_c}_window_start=\$5 INC_${_il_c}_first=\$6 INC_${_il_c}_last=\$7 INC_${_il_c}_transient=\$8 INC_${_il_c}_diag_last=\$9 INC_${_il_c}_diag_occ=\${10} INC_${_il_c}_hash=\${11}"
        # "-" is the stored form of "no summary hash yet" (field must not be
        # empty or word splitting would drop it and shift every later field).
        eval "[ \"\$INC_${_il_c}_hash\" = '-' ] && INC_${_il_c}_hash=''"
    done < "$INCIDENT_STATE" 2>/dev/null
    return 0
}

incident_save() {
    _is_tmp="${INCIDENT_STATE}.new.$$"
    _is_ok=1
    : > "$_is_tmp" 2>/dev/null || _is_ok=0
    if [ "$_is_ok" -eq 1 ]; then
        for _is_c in wan_failure proxy_tunnel_failure port_failure; do
            eval "_is_v=\$INC_${_is_c}_confirmed; _is_v2=\$INC_${_is_c}_consecutive; _is_v3=\$INC_${_is_c}_window_count; _is_v4=\$INC_${_is_c}_window_start; _is_v5=\$INC_${_is_c}_first; _is_v6=\$INC_${_is_c}_last; _is_v7=\$INC_${_is_c}_transient; _is_v8=\$INC_${_is_c}_diag_last; _is_v9=\$INC_${_is_c}_diag_occ; _is_v10=\$INC_${_is_c}_hash"
            [ -n "$_is_v10" ] || _is_v10="-"
            printf '%s %s %s %s %s %s %s %s %s %s %s\n' \
                "$_is_c" "$_is_v" "$_is_v2" "$_is_v3" "$_is_v4" \
                "$_is_v5" "$_is_v6" "$_is_v7" "$_is_v8" "$_is_v9" "$_is_v10" >> "$_is_tmp" 2>/dev/null || _is_ok=0
        done
    fi
    if [ "$_is_ok" -eq 1 ]; then
        mv "$_is_tmp" "$INCIDENT_STATE" 2>/dev/null || _is_ok=0
    fi
    [ "$_is_ok" -eq 1 ] || rm -f "$_is_tmp" 2>/dev/null
    return 0
}

# Record one confirmed failure cycle for a class. Window semantics:
# within DIAG_WINDOW_SECS of window_start the count grows; otherwise a new
# window starts at 1. Success later resets consecutive but keeps the
# window until it expires (owner rule, issue #328).
incident_confirm() {
    [ "$#" -eq 3 ] || return 0
    incident_valid_class "$1" || return 0
    eval "_ic_ws=\$INC_${1}_window_start"
    case "$_ic_ws" in ''|*[!0-9]*) _ic_ws=0 ;; esac
    _ic_now=$(date +%s)
    if [ "$_ic_ws" -gt 0 ] && [ $(( _ic_now - _ic_ws )) -lt "$DIAG_WINDOW_SECS" ]; then
        eval "INC_${1}_window_count=\$(( \$INC_${1}_window_count + 1 ))"
    else
        eval "INC_${1}_window_count=1 INC_${1}_window_start=$_ic_now"
    fi
    eval "INC_${1}_confirmed=\$(( \$INC_${1}_confirmed + 1 ))"
    eval "INC_${1}_consecutive=\$(( \$INC_${1}_consecutive + 1 ))"
    eval "[ \"\$INC_${1}_first\" -eq 0 ] && INC_${1}_first=$_ic_now"
    eval "INC_${1}_last=$_ic_now"
    incident_save
    return 0
}

# Transient observation: first probe failed, confirming retry succeeded.
# Informational counter only; never a confirmed cycle.
incident_transient() {
    incident_valid_class "$1" || return 0
    eval "INC_${1}_transient=\$(( \$INC_${1}_transient + 1 ))"
    incident_save
    return 0
}

# A successful matching check resets consecutive failures. The repeat
# window is preserved until it expires by time.
incident_recover() {
    incident_valid_class "$1" || return 0
    eval "[ \"\$INC_${1}_consecutive\" -eq 0 ] && return 0"
    eval "INC_${1}_consecutive=0"
    incident_save
    return 0
}

incident_load

# END WATCHDOG INCIDENT DIAGNOSTICS v1

# NOTE: Log directory should be created during installation (install.sh).
# If running standalone, ensure /opt/var/log exists beforehand.

# Log generation anchor: when the log file does not exist yet
# (fresh tmpfs after boot, or the very first run), record a
# single [INIT] marker so analysis can tell a fresh generation
# from a rotated one. RAM-only; no extra persistence.
if [ ! -f "$LOG" ]; then
    reset_healthy_heartbeat
    log "[INIT] log generation started (fresh tmpfs after boot or first run)"
fi

rotate_log


# Early skip is only an optimization. The restart decision takes the shared
# lifecycle lock even if maintenance began after these WAN/proxy checks.
if ml_marker_busy; then
    log "[SKIP] maintenance in progress - checks skipped"
    exit 0
fi

# =========================================================
# RESTART RATE LIMITER
#
# Prevents restart loops during upstream outages.
#
# Validates state file content to handle corruption/emptiness.
#
# Arguments:
# $1 - reason string for log message
#
# Returns:
# 0 if restart is allowed
# 1 if rate-limited
# =========================================================

can_restart() {
    local reason="$1"
    local now

    # Force the first healthy run after any Mihomo problem to be logged
    # immediately, regardless of the regular heartbeat interval.
    reset_healthy_heartbeat
    now=$(date +%s)
    local last=0

    if [ -f "$RESTART_STATE" ]; then
        last=$(cat "$RESTART_STATE")

        # Validate: ensure content is numeric to prevent
        # arithmetic errors on corrupted/empty state file
        case "$last" in
            ''|*[!0-9]*) last=0 ;;
        esac

        local elapsed
        elapsed=$(( now - last ))

        if [ "$elapsed" -lt "$MIN_RESTART_INTERVAL" ]; then
            log "[RATE-LIMIT] Restart blocked (${elapsed}s < ${MIN_RESTART_INTERVAL}s) | ${reason}"
            return 1
        fi
    fi

    if ! ml_lifecycle_acquire; then
        log "[SKIP] Mihomo lifecycle busy or unverifiable - restart skipped"
        return 1
    fi

    if ! mp_known; then
        log "[SKIP] Mihomo runtime UNKNOWN - restart skipped"
        ml_lifecycle_release || true
        return 1
    fi

    # Record restart timestamp and proceed
    echo "$now" > "$RESTART_STATE"

    log "[RESTART] ${reason}"
    # Issue #355: the restart goes through the guarded S28/S99 resolution.
    # Without a usable init script the watchdog logs and skips this attempt:
    # a restart loop against a missing service path is pointless log spam,
    # and picking an arbitrary *mihomo* script could launch a second Mihomo.
    if resolve_mihomo_init; then
        "$MIHOMO_INIT_RESOLVED" restart
    else
        case "$MIHOMO_INIT_STATE" in
            ambiguous)
                log "[SKIP] Mihomo init ownership ambiguous (S28mihomo and S99mihomo both exist) - restart skipped; remove the stale leftover"
                ;;
            absent)
                log "[SKIP] No Mihomo init script found (expected S28mihomo or S99mihomo) - restart skipped"
                ;;
            *)
                log "[SKIP] Mihomo init script unusable (${MIHOMO_INIT_STATE%%:*}): ${MIHOMO_INIT_STATE#*:} - restart skipped"
                ;;
        esac
    fi

    # Same-run outcome verification (observability only): the
    # [RESTART] line above is written before the restart, so this
    # bounded check records whether the process came back without
    # waiting for the next cron run. No further action is taken
    # here - the next run repeats the full health checks.
    if mp_known; then
        _i=0
        while [ "$_i" -lt 10 ]; do
            mp_running && break
            sleep 1
            _i=$((_i + 1))
        done
        if mp_running; then
            log "[RESTART-OK] process is running after restart"
        else
            log "[RESTART-FAIL] process did not come up within 10s after restart"
        fi
    else
        log "[RESTART-FAIL] runtime UNKNOWN after restart"
    fi

    return 0
}


# =========================================================
# HEALTH CHECKS
# =========================================================


# =========================================================
# 1. WAN CONNECTIVITY CHECK
#
# First check normal Internet targets.
#
# If all primary targets fail, check whitelist targets.
#
# All WAN checks are performed DIRECTLY, without Mihomo.
#
# If no target responds, WAN is considered unavailable.
# In this case Mihomo is NOT restarted because its actual
# state cannot be determined.
# =========================================================

wan_ok=0
wan_target_ok=""
wan_path="primary"
wan_probe_rc=""
wan_probe_ms=""

# ---------------------------------------------------------
# Primary targets
#
# --noproxy '*' pins the check to the direct path even when the cron
# environment carries HTTP_PROXY/HTTPS_PROXY/ALL_PROXY variables (issue
# #328): a router-originated WAN probe must never travel through a proxy.
# The last failed exit code and latency are kept for the [FAIL] evidence
# line; the pass/fail decision itself is unchanged.
# ---------------------------------------------------------

for target in $WAN_PRIMARY_TARGETS; do
    _w_ms0=""
    if now_ms; then
        _w_ms0=$now_ms_result
    fi
    curl -s --connect-timeout 3 --max-time 6 --noproxy '*' --head "$target" >/dev/null 2>&1
    _w_rc=$?
    if [ "$_w_rc" -eq 0 ]; then
        wan_ok=1
        wan_target_ok="$target"
        break
    fi
    wan_probe_rc=$_w_rc
    wan_probe_ms=""
    if [ -n "$_w_ms0" ] && now_ms; then
        wan_probe_ms=$(( now_ms_result - _w_ms0 ))
    fi
done


# ---------------------------------------------------------
# Whitelist fallback
#
# Only executed when ALL primary targets fail.
# ---------------------------------------------------------

if [ "$wan_ok" -eq 0 ]; then
    wan_path="whitelist"

    for target in $WAN_WHITELIST_TARGETS; do
        _w_ms0=""
        if now_ms; then
            _w_ms0=$now_ms_result
        fi
        curl -s --connect-timeout 3 --max-time 6 --noproxy '*' --head "$target" >/dev/null 2>&1
        _w_rc=$?
        if [ "$_w_rc" -eq 0 ]; then
            wan_ok=1
            wan_target_ok="$target"
            break
        fi
        wan_probe_rc=$_w_rc
        wan_probe_ms=""
        if [ -n "$_w_ms0" ] && now_ms; then
            wan_probe_ms=$(( now_ms_result - _w_ms0 ))
        fi
    done
fi


# ---------------------------------------------------------
# Final WAN result
# ---------------------------------------------------------

if [ "$wan_ok" -eq 0 ]; then
    reset_healthy_heartbeat
    incident_confirm wan_failure "$wan_probe_rc" "$wan_probe_ms"
    log "[WARN] WAN unreachable (primary + whitelist targets failed)"
    eval "_w_cycles=\$INC_wan_failure_window_count"
    log "[FAIL] wan confirmed | cycles=$_w_cycles | curl_rc=${wan_probe_rc:-unknown} | elapsed_ms=${wan_probe_ms:-unknown}"
    run_diag_wan
    exit 0
fi

incident_recover wan_failure


# =========================================================
# 2. MIHOMO PORT CHECK (TCP listener)
#
# Verifies that Mihomo's mixed port accepts TCP connections.
# We only care that the port is open, not the HTTP response.
#
# If port is closed, Mihomo is likely crashed or not started.
# =========================================================

_p_ms0=""
if now_ms; then
    _p_ms0=$now_ms_result
fi
curl -s --connect-timeout 3 --max-time 5 --noproxy '*' "http://$PROXY" >/dev/null 2>&1
_p_rc=$?
if [ "$_p_rc" -ne 0 ]; then
    _p_ms=""
    if [ -n "$_p_ms0" ] && now_ms; then
        _p_ms=$(( now_ms_result - _p_ms0 ))
    fi
    incident_confirm port_failure "$_p_rc" "$_p_ms"
    eval "_p_cycles=\$INC_port_failure_window_count"
    log "[FAIL] port confirmed | cycles=$_p_cycles | curl_rc=$_p_rc | elapsed_ms=${_p_ms:-unknown}"
    run_diag_port
    if can_restart "Mihomo port unreachable"; then
        wd_post_recheck
    fi
    exit 0
fi

incident_recover port_failure


# =========================================================
# 3. END-TO-END PROXY CHECK (Tunnel test)
#
# Verifies that SOCKS5 proxy actually forwards traffic.
#
# Uses socks5h to force DNS resolution through the tunnel.
#
# Tests against a reliable external HTTPS endpoint
# independently from the direct WAN targets.
#
# One failed probe is not enough to restart Mihomo: transient
# endpoint/TLS/DNS/failover timing can produce a false negative.
# Confirm once after a short delay. A real persistent failure
# still restarts Mihomo within the same watchdog run.
# =========================================================

# The probe keeps its original contract (return code only); it now also
# records the curl exit code and latency for the [FAIL] evidence line.
proxy_tunnel_ok() {
    _t_ms0=""
    if now_ms; then
        _t_ms0=$now_ms_result
    fi
    curl -x "socks5h://$PROXY" -m 5 -s https://www.google.com >/dev/null 2>&1
    PT_RC=$?
    PT_MS=""
    if [ -n "$_t_ms0" ] && now_ms; then
        PT_MS=$(( now_ms_result - _t_ms0 ))
    fi
    return "$PT_RC"
}

if ! proxy_tunnel_ok; then
    sleep "$PROXY_RETRY_DELAY"

    if ! proxy_tunnel_ok; then
        incident_confirm proxy_tunnel_failure "$PT_RC" "$PT_MS"
        eval "_t_cycles=\$INC_proxy_tunnel_failure_window_count"
        log "[FAIL] proxy_tunnel confirmed | cycles=$_t_cycles | curl_rc=${PT_RC:-unknown} | elapsed_ms=${PT_MS:-unknown}"
        run_diag_tunnel
        if can_restart "Proxy tunnel check failed"; then
            wd_post_recheck
        fi
        exit 0
    fi

    incident_transient proxy_tunnel_failure
    log "[INFO] Proxy tunnel first probe failed; retry succeeded - no restart (transient_cycles=$(eval "echo \$INC_proxy_tunnel_failure_transient"))"
fi

incident_recover proxy_tunnel_failure


# =========================================================
# ALL CHECKS PASSED
# =========================================================

log_healthy "$wan_path" "$wan_target_ok"
