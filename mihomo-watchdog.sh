#!/bin/sh

# =========================================================
# MIHOMO WATCHDOG SCRIPT - PRODUCTION VERSION
# ---------------------------------------------------------
# Embedded Linux watchdog for Mihomo proxy
# Tested on Keenetic + Entware systems (MT7621 / MIPS).

# All WAN checks are performed DIRECTLY, without Mihomo.

# If no target responds, WAN is considered unavailable.
# In this case Mihomo is NOT restarted because its actual
# state cannot be determined.

# Features:
# - Two-stage WAN connectivity check
# - Normal Internet targets checked first
# - Whitelist fallback for restricted/mobile networks
# - Mihomo port availability check
# - End-to-end SOCKS5h tunnel check
# - Restart rate limiting (cooldown to prevent loops)
# - Stale-safe mkdir lock: atomic takeover, race-free, recovers after SIGKILL
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

# Minimum seconds between restarts to prevent storm during upstream outage
MIN_RESTART_INTERVAL=300

# Log rotation thresholds
LOG_MAX_LINES=500
LOG_KEEP_LINES=300

# Healthy checks run every 5 minutes, but routine success logs are throttled.
# Problem/restart events remain immediate and reset this heartbeat so the next
# healthy run is always recorded as a recovery marker.
HEALTHY_LOG_INTERVAL=1200


# =========================================================
# LOCK MECHANISM (mkdir + atomic takeover)
#
# /tmp/mihomo_watchdog.lock.d is the lock. Ownership truth is the
# directory itself: mkdir is an atomic test-and-set, so exactly one
# concurrent process can hold it. The pid/ts files inside serve liveness
# diagnostics and stale-recovery only — losing or misreading them never
# weakens mutual exclusion.
#
#   mkdir fails + live pid of a mihomo_watchdog -> another run is active,
#                                                  exit silently
#   mkdir fails + pid dead/garbage/foreign      -> stale takeover:
#           mv "$LOCK_DIR" "$LOCK_DIR.stale.$$"
#   The atomic rename IS the takeover claim: exactly one process can
#   rename a given directory; the winner removes only the directory it
#   renamed, every loser exits without deleting anything.
#   mkdir fails + empty/garbage pid + dir younger than the 60s grace
#   -> possibly a process between its mkdir and its pid write: skip.
#   The real mkdir->pid gap is microseconds (adjacent shell operations);
#   dead holders keep a valid pid and are recovered by liveness
#   immediately, so SIGKILL recovery stays at the next cron run.
#
# The trap is installed only AFTER a successful acquisition, so a loser
# of acquire or takeover has no cleanup handler and can never delete the
# winner's lock. While we run, our live pid inside the directory prevents
# any takeover, so our own cleanup always removes our own lock.
# /tmp is RAM: leftovers after SIGKILL disappear at reboot.
# =========================================================

lock_write_owner() {
    echo "$$" > "$LOCK_DIR/pid"
    date +%s > "$LOCK_DIR/ts"
}

lock_is_our_watchdog() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ -d "/proc/$1" ] || return 1
    grep -q "mihomo_watchdog" "/proc/$1/cmdline" 2>/dev/null
}

if mkdir "$LOCK_DIR" 2>/dev/null; then
    lock_write_owner
else
    _lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    if lock_is_our_watchdog "$_lock_pid"; then
        # Another live watchdog holds the lock; skip silently
        exit 0
    fi
    _lock_fresh=0
    case "$_lock_pid" in
        ''|*[!0-9]*)
            # Garbage/empty pid: the dir may belong to a process that has
            # just done mkdir but has not written its pid yet. The real
            # gap is microseconds; one minute of grace is ~4 orders of
            # magnitude of margin and does not affect SIGKILL recovery
            # (dead holders keep a valid pid and never reach this branch).
            _now=$(date +%s)
            _ts=$(cat "$LOCK_DIR/ts" 2>/dev/null)
            case "$_ts" in ''|*[!0-9]*) _ts=0 ;; esac
            if [ $((_now - _ts)) -lt 60 ]; then
                _lock_fresh=1
            fi
            ;;
    esac
    if [ "$_lock_fresh" = "1" ]; then
        # Too young to judge: never steal a possibly-live starter
        exit 0
    fi
    _claim="$LOCK_DIR.stale.$$"
    if mv "$LOCK_DIR" "$_claim" 2>/dev/null; then
        # The atomic rename is the takeover claim: only the mv winner
        # touches the claimed directory.
        rm -rf "$_claim"
        if ! mkdir "$LOCK_DIR" 2>/dev/null; then
            # A fresh run took the freed path first; it owns the lock now
            exit 0
        fi
        lock_write_owner
    else
        # Claim lost: another stale-recoverer won or the holder changed
        exit 0
    fi
fi

cleanup() {
    rm -rf "$LOCK_DIR"
}

trap cleanup EXIT INT TERM


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
    local now last elapsed

    now=$(date +%s)
    last=0

    if [ -f "$HEALTHY_STATE" ]; then
        last=$(cat "$HEALTHY_STATE" 2>/dev/null)
        case "$last" in
            ''|*[!0-9]*) last=0 ;;
        esac
    fi

    elapsed=$(( now - last ))
    if [ "$last" -eq 0 ] || [ "$elapsed" -ge "$HEALTHY_LOG_INTERVAL" ]; then
        log "[OK] All good | WAN=${wan_path} (${wan_target})"
        echo "$now" > "$HEALTHY_STATE"
    fi
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


# =========================================================
# MAINTENANCE COORDINATION
#
# update-mihomo.sh and migrate-mihomo-mips.sh write
# /tmp/mihomo.maintenance for the duration of a transaction that may
# intentionally stop Mihomo. While a fresh marker exists, this watchdog
# run exits before any checks, so a cron tick landing inside an update
# or migration cannot resurrect Mihomo mid-transaction. A malformed or
# missing timestamp is treated as fresh (conservative for the running
# maintenance); the marker lives in /tmp, so a crashed run self-heals at
# the next reboot, and anything older than 3600 s is ignored so a
# watchdog outage stays bounded.
# =========================================================

if [ -f "/tmp/mihomo.maintenance" ]; then
    _maint_ts=$(head -n 1 /tmp/mihomo.maintenance 2>/dev/null | awk '{print $2}')
    case "$_maint_ts" in
        ''|*[!0-9]*) _maint_ts=$(date +%s) ;;
    esac
    if [ $(( $(date +%s) - _maint_ts )) -le 3600 ]; then
        log "[SKIP] maintenance in progress - checks skipped"
        exit 0
    fi
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

    # Record restart timestamp and proceed
    echo "$now" > "$RESTART_STATE"

    log "[RESTART] ${reason}"
    /opt/etc/init.d/S99mihomo restart

    # Same-run outcome verification (observability only): the
    # [RESTART] line above is written before the restart, so this
    # bounded check records whether the process came back without
    # waiting for the next cron run. No further action is taken
    # here - the next run repeats the full health checks.
    if command -v pidof >/dev/null 2>&1; then
        _i=0
        while [ "$_i" -lt 10 ]; do
            pidof mihomo >/dev/null 2>&1 && break
            sleep 1
            _i=$((_i + 1))
        done
        if pidof mihomo >/dev/null 2>&1; then
            log "[RESTART-OK] process is running after restart"
        else
            log "[RESTART-FAIL] process did not come up within 10s after restart"
        fi
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
# =========================================================

if ! curl -x "socks5h://$PROXY" -m 5 -s https://www.google.com >/dev/null 2>&1; then
    can_restart "Proxy tunnel check failed"
    exit 0
fi


# =========================================================
# ALL CHECKS PASSED
# =========================================================

log_healthy "$wan_path" "$wan_target_ok"
