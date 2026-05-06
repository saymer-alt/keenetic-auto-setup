#!/bin/sh

LOG="/opt/var/log/mihomo_watchdog.log"
WAN_TARGET="1.1.1.1"
PROXY="127.0.0.1:7890"

# -----------------------------
# JITTER (распределение нагрузки)
# -----------------------------
sleep $(( $(date +%s) % 25 ))

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
}

# -----------------------------
# WAN CHECK
# -----------------------------
if ! ping -c 2 -W 2 $WAN_TARGET >/dev/null 2>&1; then
    log "[WARN] WAN unreachable"
    exit 0
fi

# -----------------------------
# PORT CHECK (через curl, без netcat)
# -----------------------------
if ! curl -s --connect-timeout 3 http://127.0.0.1:7890 >/dev/null 2>&1; then
    log "[FAIL] Mihomo port unreachable → restarting"
    /opt/etc/init.d/S99mihomo restart
    exit 0
fi

# -----------------------------
# PROXY CHECK (через SOCKS5)
# -----------------------------
if ! curl -x socks5h://$PROXY -m 5 -s https://www.google.com >/dev/null 2>&1; then
    log "[FAIL] Proxy check failed → restarting"
    /opt/etc/init.d/S99mihomo restart
    exit 0
fi

# -----------------------------
# LOG ROTATION
# -----------------------------
if [ -f "$LOG" ]; then
    LINES=$(wc -l < "$LOG")
    if [ "$LINES" -gt 200 ]; then
        tail -n 100 "$LOG" > "$LOG.tmp"
        mv "$LOG.tmp" "$LOG"
    fi
fi

log "[OK] All good"
