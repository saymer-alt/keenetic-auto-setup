#!/bin/sh

# =========================================================
# MIHOMO WATCHDOG UPDATER
# ---------------------------------------------------------
# Keeps the canonical watchdog at /opt/bin/mihomo_watchdog.sh and
# understands exactly three router states:
#
#   legacy:  full watchdog at /opt/etc/cron.5mins/mihomo_watchdog
#            -> one-time switch to the new layout: install the canonical
#               binary, turn the cron file into a thin wrapper
#   new:     canonical binary + cron wrapper
#            -> update the binary only; the wrapper is left untouched
#   unknown: unrecognized or user-custom files (or nothing installed)
#            -> WARN, nothing changed
#
# The new file is downloaded and validated (marker + sh -n) in RAM (/tmp)
# before it replaces the old one. No backups are kept: the watchdog is
# small and the same content always remains available at the source URL.
# The installer installs and recognizes; the updater updates and migrates.
#
# Usage:
#   curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/update-watchdog.sh | sh
#   or locally:
#   ./update-watchdog.sh
#
# Environment:
#   WATCHDOG_URL - override source URL (optional)
# =========================================================

WATCHDOG_BIN="/opt/bin/mihomo_watchdog.sh"
WATCHDOG_CRON="/opt/etc/cron.5mins/mihomo_watchdog"
TMP_FILE="/tmp/mihomo_watchdog.sh.new.$$"
URL="${WATCHDOG_URL:-https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo_watchdog.sh}"

# --- CLEANUP ---
cleanup() {
    rm -f "$TMP_FILE"
}
trap cleanup EXIT INT TERM

watchdog_is_canonical() {
    [ -f "$1" ] && grep -q "MIHOMO WATCHDOG SCRIPT" "$1" 2>/dev/null
}

watchdog_cron_is_wrapper() {
    [ -f "$WATCHDOG_CRON" ] && grep -q "$WATCHDOG_BIN" "$WATCHDOG_CRON" 2>/dev/null
}

# --- DEPENDENCIES ---
if ! command -v curl >/dev/null 2>&1; then
    echo "[ERROR] curl is required but not found"
    exit 1
fi

# --- STATE RECOGNITION ---
# A full watchdog in cron.5mins is migrated even when a canonical binary
# also exists (the hybrid state converges to the new layout).
if watchdog_is_canonical "$WATCHDOG_CRON"; then
    MODE="legacy"
elif watchdog_is_canonical "$WATCHDOG_BIN"; then
    MODE="new"
else
    MODE="unknown"
fi

case "$MODE" in
    legacy)
        echo "[INFO] Legacy layout: full watchdog at $WATCHDOG_CRON"
        echo "[INFO] Switching to: $WATCHDOG_BIN + cron wrapper" ;;
    new)
        echo "[INFO] New layout, updating $WATCHDOG_BIN" ;;
    unknown)
        echo "[WARN] Watchdog state not recognized (or not installed), nothing changed"
        echo "[WARN] Run install.sh first, or check $WATCHDOG_BIN and $WATCHDOG_CRON manually"
        exit 0 ;;
esac

# --- DOWNLOAD + VALIDATE (in RAM, before touching anything) ---
echo "[INFO] Downloading watchdog..."
echo "[INFO] Source: $URL"

if ! curl -fSsL "$URL" -o "$TMP_FILE"; then
    echo "[ERROR] Download failed"
    exit 1
fi

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

# --- INSTALL canonical binary (the fix from review: legacy installs may
# not have /opt/bin at all) ---
mkdir -p /opt/bin
if ! mv "$TMP_FILE" "$WATCHDOG_BIN"; then
    echo "[ERROR] Failed to replace $WATCHDOG_BIN"
    exit 1
fi
echo "[INFO] Watchdog installed: $WATCHDOG_BIN"

# --- LEGACY: the cron file becomes a thin wrapper ---
if [ "$MODE" = "legacy" ]; then
    cat > "$WATCHDOG_CRON" <<'EOF' || { echo "[ERROR] Failed to write wrapper at $WATCHDOG_CRON"; exit 1; }
#!/bin/sh
exec /opt/bin/mihomo_watchdog.sh "$@"
EOF
    chmod +x "$WATCHDOG_CRON"
    echo "[INFO] Cron entry converted to wrapper: $WATCHDOG_CRON"
fi

# --- RESULT ---
if watchdog_is_canonical "$WATCHDOG_BIN" && watchdog_cron_is_wrapper; then
    echo "[OK] Watchdog update complete (canonical binary + cron wrapper)"
else
    echo "[WARN] Layout incomplete after update:"
    watchdog_is_canonical "$WATCHDOG_BIN" || \
        echo "[WARN] - $WATCHDOG_BIN is not a valid watchdog"
    watchdog_cron_is_wrapper || \
        echo "[WARN] - $WATCHDOG_CRON is missing or not a wrapper (cron may not run the watchdog)"
    echo "[WARN] Check $WATCHDOG_BIN and $WATCHDOG_CRON manually"
fi
exit 0
