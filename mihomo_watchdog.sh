#!/bin/sh

LOG="/opt/var/log/mihomo_watchdog.log"
LOCK_FILE="/tmp/mihomo_watchdog.lock"

WAN_TARGET="1.1.1.1"
PROXY="127.0.0.1:7890"

# =========================================================
# LOCK MECHANISM
# Prevents multiple instances of the script from running
# =========================================================
if [ -f "$LOCK_FILE" ]; then
    exit 0
fi

touch "$LOCK_FILE"

cleanup() {
    rm -f "$LOCK_FILE"
}

# Ensure lock file is removed on script exit/interruption
trap cleanup EXIT INT TERM

# =========================================================
# JITTER
# Distributes load to prevent simultaneous requests from multiple devices
# =========================================================
sleep $(( $(date +%s) % 25 ))

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
}

# =========================================================
# WAN CHECK
# Use curl to check internet connectivity (more reliable than ping)
# =========================================================
if ! curl -s --connect-timeout 3 --head http://1.1.1.1 >/dev/null 2>&1; then
    log "[WARN] WAN unreachable"
    exit 0
fi

# =========================================================
# PORT CHECK
# Verifies that Mihomo process is listening on the local port
# =========================================================
if ! curl -s --connect-timeout 3 "http://$PROXY" >/dev/null 2>&1; then
    log "[FAIL] Mihomo port unreachable -> restarting"
    /opt/etc/init.d/S99mihomo restart
    exit 0
fi

# =========================================================
# PROXY CHECK
# Full end-to-end check via SOCKS5h protocol
# =========================================================
if ! curl -x "socks5h://$PROXY" -m 5 -s https://www.google.com >/dev/null 2>&1; then
    log "[FAIL] Proxy check failed -> restarting"
    /opt/etc/init.d/S99mihomo restart
    exit 0
fi

# =========================================================
# LOG ROTATION
# Keeps the log file small (max 200 lines)
# =========================================================
if [ -f "$LOG" ]; then
    LINES=$(wc -l < "$LOG")

    if [ "$LINES" -gt 200 ]; then
        tail -n 100 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
    fi
fi

log "[OK] All good"
