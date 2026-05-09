#!/bin/sh

LOG="/opt/var/log/mihomo_watchdog.log"
LOCK_FILE="/tmp/mihomo_watchdog.lock"

WAN_TARGET="1.1.1.1"
PROXY="127.0.0.1:7890"

# =========================================================
# LOCK MECHANISM
# =========================================================
if [ -f "$LOCK_FILE" ]; then
    exit 0
fi

touch "$LOCK_FILE"

cleanup() {
    rm -f "$LOCK_FILE"
}

trap cleanup EXIT INT TERM

# =========================================================
# JITTER
# =========================================================
sleep $(( $(date +%s) % 25 ))

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
}

# =========================================================
# WAN CHECK
# =========================================================
if ! curl -s --connect-timeout 3 --head http://1.1.1.1 >/dev/null 2>&1; then
    log "[WARN] WAN unreachable"
    exit 0
fi

# =========================================================
# PORT CHECK
# =========================================================
if ! curl -s --connect-timeout 3 "http://$PROXY" >/dev/null 2>&1; then
    log "[FAIL] Mihomo port unreachable -> restarting"
    /opt/etc/init.d/S99mihomo restart
    exit 0
fi

# =========================================================
# PROXY CHECK
# =========================================================
if ! curl -x "socks5h://$PROXY" -m 5 -s https://www.google.com >/dev/null 2>&1; then
    log "[FAIL] Proxy check failed -> restarting"
    /opt/etc/init.d/S99mihomo restart
    exit 0
fi

# =========================================================
# LOG ROTATION (500 lines max, keeps last 300)
# =========================================================
if [ -f "$LOG" ]; then
    LINES=$(wc -l < "$LOG")
    if [ "$LINES" -gt 500 ]; then
        tail -n 300 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    fi
fi

log "[OK] All good"
