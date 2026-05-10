#!/bin/sh

# =========================================================
# MIHOMO WATCHDOG SCRIPT - PRODUCTION VERSION
# ---------------------------------------------------------
# Embedded Linux watchdog for Mihomo proxy
# Tested on Keenetic + Entware systems (MT7621 / MIPS).
#
# Features:
# - WAN connectivity check (HTTP-based, no TLS overhead)
# - Mihomo port availability check
# - End-to-end SOCKS5h tunnel check
# - Restart rate limiting (cooldown to prevent loops)
# - Lock file protection & log rotation
# - Jitter for multi-router deployments (~20 nodes)
#
# Cron: */5 * * * * /opt/bin/mihomo_watchdog.sh
# =========================================================

# --- FILES ---
LOG="/opt/var/log/mihomo_watchdog.log"
LOCK_FILE="/tmp/mihomo_watchdog.lock"
RESTART_STATE="/tmp/mihomo_watchdog.restart"

# --- CONFIGURATION ---
# Lightweight WAN check (HTTP to avoid TLS overhead and clock-sync issues on CPU)
WAN_TARGET="http://cp.cloudflare.com"
# Mihomo mixed proxy port (HTTP + SOCKS5)
PROXY="127.0.0.1:7890"
# Minimum seconds between restarts to prevent storm during upstream outage
MIN_RESTART_INTERVAL=300
# Log rotation thresholds
LOG_MAX_LINES=500
LOG_KEEP_LINES=300

# =========================================================
# LOCK MECHANISM
# Prevents overlapping executions if a previous run hangs.
# Trap ensures cleanup on any exit path (normal, interrupt, kill).
# =========================================================
if [ -f "$LOCK_FILE" ]; then
    # Another instance is still running; skip silently
    exit 0
fi

touch "$LOCK_FILE" || exit 0

cleanup() {
    rm -f "$LOCK_FILE"
}

trap cleanup EXIT INT TERM

# =========================================================
# JITTER (Random delay 0-24s)
# Desynchronizes multiple routers to avoid thundering herd
# against upstream check targets and local mihomo instance.
# =========================================================
sleep $(( $(date +%s) % 25 ))

# =========================================================
# LOGGING & ROTATION
# =========================================================
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
}

rotate_log() {
    if [ -f "$LOG" ]; then
        LINES=$(wc -l < "$LOG")
        if [ "$LINES" -gt "$LOG_MAX_LINES" ]; then
            tail -n "$LOG_KEEP_LINES" "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
        fi
    fi
}

# NOTE: Log directory should be created during installation (install.sh).
# If running standalone, ensure /opt/var/log exists beforehand.
rotate_log

# =========================================================
# RESTART RATE LIMITER
# Prevents restart loops during upstream outages.
# Validates state file content to handle corruption/emptiness.
#
# Arguments:
#   $1 - reason string for log message
# Returns:
#   0 if restart is allowed, 1 if rate-limited
# =========================================================
can_restart() {
    local reason="$1"
    local now
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
    return 0
}

# =========================================================
# HEALTH CHECKS
# =========================================================

# 1. WAN CONNECTIVITY CHECK
# Lightweight HTTP HEAD to avoid TLS overhead on MT7621.
# If WAN is down, restarting proxy is pointless — bail out.
if ! curl -s --connect-timeout 3 --head "$WAN_TARGET" >/dev/null 2>&1; then
    log "[WARN] WAN unreachable (${WAN_TARGET})"
    exit 0
fi

# 2. MIHOMO PORT CHECK (TCP listener)
# Verifies that mihomo's mixed port accepts TCP connections.
# We only care that the port is open, not the HTTP response.
# If port is closed, mihomo is likely crashed or not started.
if ! curl -s --connect-timeout 3 "http://$PROXY" >/dev/null 2>&1; then
    can_restart "Mihomo port unreachable"
    exit 0
fi

# 3. END-TO-END PROXY CHECK (Tunnel test)
# Verifies that SOCKS5 proxy actually forwards traffic.
# Uses socks5h to force DNS resolution through the tunnel.
# Tests against a reliable external HTTPS endpoint (different from WAN target
# to ensure independent failure detection).
if ! curl -x "socks5h://$PROXY" -m 5 -s https://www.google.com >/dev/null 2>&1; then
    can_restart "Proxy tunnel check failed"
    exit 0
fi

# --- ALL CHECKS PASSED ---
log "[OK] All good"
