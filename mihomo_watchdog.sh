#!/bin/sh

LOG="/opt/var/log/mihomo_watchdog.log"
PROXY="socks5://127.0.0.1:7890"
STATE="/opt/var/run/mihomo_fail"

MAX_FAIL=3

log() {
    echo "$(date '+%F %T') $1" >> "$LOG"
}

# jitter
sleep $(( $(date +%s) % 25 ))

# WAN check
if ! ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
    log "[WARN] WAN unreachable"
    exit 0
fi

# читаем счётчик
FAIL=0
[ -f "$STATE" ] && FAIL=$(cat "$STATE")

# proxy check
if ! curl -x "$PROXY" -m 5 -s https://ipinfo.io >/dev/null 2>&1; then
    FAIL=$((FAIL + 1))
    echo "$FAIL" > "$STATE"
    log "[FAIL] Proxy not responding ($FAIL/$MAX_FAIL)"
else
    echo "0" > "$STATE"
    log "[OK] Proxy alive"
    exit 0
fi

# restart
if [ "$FAIL" -ge "$MAX_FAIL" ]; then
    log "[ACTION] Restarting Mihomo"
    /opt/etc/init.d/S99mihomo restart
    echo "0" > "$STATE"
    sleep 10
fi

# log rotate
LINES=$(wc -l < "$LOG" 2>/dev/null)
[ "$LINES" -gt 200 ] && tail -n 100 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
