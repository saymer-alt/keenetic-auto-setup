#!/bin/sh

# =========================================================
# Mihomo Watchdog Script
# Auto-restart if proxy or process fails
# =========================================================

PROXY_URL="127.0.0.1:7890"
CHECK_URLS="http://google.com/generate_204 http://connectivitycheck.gstatic.com/generate_204"
WAN_CHECK_URL="http://1.1.1.1"

LOG_FILE="/opt/var/log/mihomo_watchdog.log"
RESTART_CMD="/opt/etc/init.d/S99mihomo restart"
LOCK_FILE="/tmp/mihomo_watchdog.lock"

COOLDOWN=300

# Prefer Entware pidof if available
PIDOF_BIN="/opt/bin/pidof"
[ -x "$PIDOF_BIN" ] || PIDOF_BIN="pidof"

# -----------------------------
# JITTER (avoid mass restart)
# -----------------------------
sleep $((RANDOM % 20))

# -----------------------------
# PROCESS CHECK
# -----------------------------
if ! $PIDOF_BIN mihomo >/dev/null 2>&1; then
    echo "$(date '+%F %T'): mihomo dead, restart" >> "$LOG_FILE"
    $RESTART_CMD >> "$LOG_FILE" 2>&1
    date +%s > "$LOCK_FILE"
    exit 0
fi

# -----------------------------
# COOLDOWN
# -----------------------------
if [ -f "$LOCK_FILE" ]; then
    LAST=$(cat "$LOCK_FILE" 2>/dev/null || echo 0)
    NOW=$(date +%s)
    [ $((NOW - LAST)) -lt $COOLDOWN ] && exit 0
fi

# -----------------------------
# WAN CHECK
# -----------------------------
if ! curl -s --max-time 5 --connect-timeout 3 -o /dev/null "$WAN_CHECK_URL" 2>/dev/null; then
    echo "$(date '+%F %T'): WAN unreachable, skip" >> "$LOG_FILE"
    exit 0
fi

# -----------------------------
# PROXY CHECK
# -----------------------------
CODES=""
OK=0

for URL in $CHECK_URLS; do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
        --proxy "$PROXY_URL" \
        --max-time 10 \
        --connect-timeout 3 \
        "$URL" 2>/dev/null)

    CODES="${CODES:+$CODES/}$STATUS"

    if [ "$STATUS" = "204" ]; then
        OK=1
        break
    fi
done

# -----------------------------
# ACTION
# -----------------------------
if [ "$OK" -ne 1 ]; then
    echo "$(date '+%F %T'): proxy fail [$CODES], restart" >> "$LOG_FILE"
    date +%s > "$LOCK_FILE"
    $RESTART_CMD >> "$LOG_FILE" 2>&1
fi

# -----------------------------
# LOG ROTATE
# -----------------------------
if [ -f "$LOG_FILE" ]; then
    LINES=$(wc -l < "$LOG_FILE" 2>/dev/null)
    if [ "${LINES:-0}" -gt 120 ]; then
        tail -n 100 "$LOG_FILE" > "$LOG_FILE.$$" && mv "$LOG_FILE.$$" "$LOG_FILE"
    fi
fi
