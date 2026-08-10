#!/bin/sh

# =========================================================
# MIHOMO WATCHDOG UPDATER
# ---------------------------------------------------------
# Safe atomic update with syntax check and backup.
#
# Usage:
#   curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/update-watchdog.sh | sh
#   or locally:
#   ./update-watchdog.sh
#
# Environment:
#   WATCHDOG_URL - override source URL (optional)
# =========================================================

WATCHDOG="/opt/bin/mihomo_watchdog.sh"
TMP_FILE="/tmp/mihomo_watchdog.sh.new.$$"
BACKUP_DIR="/opt/var/log"
URL="${WATCHDOG_URL:-https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo_watchdog.sh}"

# --- CLEANUP ---
cleanup() {
    rm -f "$TMP_FILE"
}
trap cleanup EXIT INT TERM

# --- DEPENDENCIES ---
if ! command -v curl >/dev/null 2>&1; then
    echo "[ERROR] curl is required but not found"
    exit 1
fi

# --- TARGET CHECK ---
WATCHDOG_DIR=$(dirname "$WATCHDOG")
if [ ! -d "$WATCHDOG_DIR" ]; then
    echo "[ERROR] Target directory does not exist: $WATCHDOG_DIR"
    exit 1
fi

# --- DOWNLOAD ---
echo "[INFO] Downloading watchdog..."
echo "[INFO] Source: $URL"

if ! curl -fSsL "$URL" -o "$TMP_FILE"; then
    echo "[ERROR] Download failed"
    exit 1
fi

# --- VALIDATION ---
if [ ! -s "$TMP_FILE" ]; then
    echo "[ERROR] Downloaded file is empty"
    exit 1
fi

if ! grep -q "MIHOMO WATCHDOG SCRIPT" "$TMP_FILE"; then
    echo "[ERROR] Sanity check failed: not a valid watchdog script"
    exit 1
fi

if ! sh -n "$TMP_FILE"; then
    echo "[ERROR] Syntax check failed"
    exit 1
fi

chmod +x "$TMP_FILE"

# --- BACKUP ---
if [ -f "$WATCHDOG" ]; then
    if [ -d "$BACKUP_DIR" ]; then
        BACKUP_FILE="$BACKUP_DIR/mihomo_watchdog.sh.bak.$(date +%s)"
        if cp "$WATCHDOG" "$BACKUP_FILE" 2>/dev/null; then
            echo "[INFO] Backup saved: $BACKUP_FILE"
        fi
    fi
fi

# --- ATOMIC REPLACE ---
if ! mv "$TMP_FILE" "$WATCHDOG"; then
    echo "[ERROR] Failed to replace $WATCHDOG"
    exit 1
fi

echo "[OK] Watchdog updated: $WATCHDOG"
exit 0
