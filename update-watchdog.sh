#!/bin/sh

# =========================================================
# MIHOMO WATCHDOG UPDATER
# ---------------------------------------------------------
# Downloads the latest watchdog version from GitHub
# and safely replaces the installed copy.
# =========================================================

WATCHDOG="/opt/bin/mihomo_watchdog.sh"
TMP="/tmp/mihomo_watchdog.sh.new"
URL="https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo_watchdog.sh"

echo "[INFO] Downloading latest Mihomo watchdog..."

if ! curl -fSsL "$URL" -o "$TMP"; then
    echo "[ERROR] Failed to download watchdog."
    rm -f "$TMP"
    exit 1
fi

# Basic sanity check
if ! grep -q "MIHOMO WATCHDOG SCRIPT" "$TMP"; then
    echo "[ERROR] Downloaded file does not look like mihomo_watchdog.sh"
    rm -f "$TMP"
    exit 1
fi

chmod +x "$TMP"

# Atomic replacement
if ! mv "$TMP" "$WATCHDOG"; then
    echo "[ERROR] Failed to replace installed watchdog."
    rm -f "$TMP"
    exit 1
fi

echo "[OK] Mihomo watchdog updated successfully."
echo "[INFO] Installed: $WATCHDOG"

exit 0
