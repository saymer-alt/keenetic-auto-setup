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
    /opt/etc/init.d/S99mihomo restart

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

# ---------------------------------------------------------
# Primary targets
# ---------------------------------------------------------

for target in $WAN_PRIMARY_TARGETS; do
    if curl -s --connect-timeout 3 --max-time 6 --head "$target" >/dev/null 2>&1; then
        wan_ok=1
        wan_target_ok="$target"
        break
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
        if curl -s --connect-timeout 3 --max-time 6 --head "$target" >/dev/null 2>&1; then
            wan_ok=1
            wan_target_ok="$target"
            break
        fi
    done
fi


# ---------------------------------------------------------
# Final WAN result
# ---------------------------------------------------------

if [ "$wan_ok" -eq 0 ]; then
    reset_healthy_heartbeat
    log "[WARN] WAN unreachable (primary + whitelist targets failed)"
    exit 0
fi


# =========================================================
# 2. MIHOMO PORT CHECK (TCP listener)
#
# Verifies that Mihomo's mixed port accepts TCP connections.
# We only care that the port is open, not the HTTP response.
#
# If port is closed, Mihomo is likely crashed or not started.
# =========================================================

if ! curl -s --connect-timeout 3 --max-time 5 "http://$PROXY" >/dev/null 2>&1; then
    can_restart "Mihomo port unreachable"
    exit 0
fi


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

proxy_tunnel_ok() {
    curl -x "socks5h://$PROXY" -m 5 -s https://www.google.com >/dev/null 2>&1
}

if ! proxy_tunnel_ok; then
    sleep "$PROXY_RETRY_DELAY"

    if ! proxy_tunnel_ok; then
        can_restart "Proxy tunnel check failed"
        exit 0
    fi

    log "[INFO] Proxy tunnel first probe failed; retry succeeded - no restart"
fi


# =========================================================
# ALL CHECKS PASSED
# =========================================================

log_healthy "$wan_path" "$wan_target_ok"
