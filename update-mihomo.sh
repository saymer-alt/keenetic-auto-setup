#!/bin/sh
#
# Mihomo Auto Updater for Keenetic routers with Entware
# -----------------------------------------------------
# Automatically fetches the latest Mihomo release from GitHub,
# detects architecture, downloads the correct binary, backs up
# the old version, replaces it, restarts the service, and rolls
# back on failure.
#
# Usage:
#   sh update-mihomo.sh
#   sh update-mihomo.sh --force     # skip version check, always update
#
# Tested on: Keenetic ARM64 (aarch64) with Entware
# Author: saymer-alt
# Repository: https://github.com/saymer-alt/keenetic-auto-setup
#

set -e

echo "=== Mihomo Auto Updater for Keenetic ==="

# Configuration
TMP_DIR="/tmp"
REPO="MetaCubeX/mihomo"
FORCE_UPDATE=0

# Parse arguments
for arg in "$@"; do
  case "$arg" in
    --force) FORCE_UPDATE=1 ;;
  esac
done

# Logging helpers
log() { echo "[updater] $1"; }
error() { echo "[ERROR] $1"; exit 1; }

# Retry wrapper: attempts a command up to 3 times with 2s delay
retry() {
  for i in 1 2 3; do
    "$@" && return 0
    sleep 2
  done
  return 1
}

# -----------------------------
# 1. Base checks
# -----------------------------
command -v opkg >/dev/null 2>&1 || {
  error "opkg not found. Is Entware installed?"
}

log "Updating package lists..."
opkg update || error "opkg update failed"

# Install required packages if missing
pkg_install() {
  opkg list-installed | grep -q "^$1 " || opkg install "$1"
}

pkg_install curl
pkg_install jq
pkg_install gzip

command -v jq >/dev/null || error "jq is required but not installed"
command -v curl >/dev/null || error "curl is required but not installed"

# -----------------------------
# 2. Detect router architecture
# -----------------------------
ARCH=$(opkg print-architecture | awk '\
  /^arch/ && $2 ~ /^(mips|mipsel|aarch64|arm|armv7)/ {
    sub(/[-_].*/, "", $2)
    print $2
    exit
  }')

[ -z "$ARCH" ] && error "Cannot detect architecture from opkg"

# Map Entware arch to Mihomo release binary name
case "$ARCH" in
  aarch64)
    MIHOMO_ARCH="arm64"
    ;;
  arm|armv7)
    MIHOMO_ARCH="armv7"
    ;;
  mipsel|mips)
    error "MIPS is not supported by official Mihomo binaries. Use opkg package or build manually."
    ;;
  *)
    error "Unsupported architecture: $ARCH"
    ;;
esac

log "Detected arch: $ARCH -> mihomo-$MIHOMO_ARCH"

# -----------------------------
# 3. Fetch latest release info
# -----------------------------
log "Fetching latest release from GitHub API..."

LATEST_JSON=$(retry curl -fsSL "https://api.github.com/repos/$REPO/releases/latest") || \
  error "Failed to fetch release info from GitHub API"

LATEST_TAG=$(echo "$LATEST_JSON" | jq -r '.tag_name')
LATEST_VER=${LATEST_TAG#v}

[ -z "$LATEST_VER" ] || [ "$LATEST_VER" = "null" ] && error "Cannot parse version from GitHub response"

log "Latest available version: $LATEST_VER"

# -----------------------------
# 4. Find currently installed mihomo
# -----------------------------
MIHOMO_PATH=$(find /opt -name "mihomo" -type f 2>/dev/null | head -1)
[ -z "$MIHOMO_PATH" ] && MIHOMO_PATH=$(which mihomo 2>/dev/null)
[ -z "$MIHOMO_PATH" ] && error "Cannot find installed mihomo binary"

log "Installed at: $MIHOMO_PATH"

CURRENT_VER=$("$MIHOMO_PATH" -v 2>/dev/null | head -1 | awk '{print $3}')
log "Current version: ${CURRENT_VER:-unknown}"

# Skip update if versions match (unless --force)
if [ "$FORCE_UPDATE" -eq 0 ] && [ "$CURRENT_VER" = "$LATEST_VER" ]; then
  log "Already up to date ($CURRENT_VER). Use --force to reinstall."
  exit 0
fi

# -----------------------------
# 5. Download new binary
# -----------------------------
FILENAME="mihomo-linux-${MIHOMO_ARCH}-v${LATEST_VER}.gz"
URL="https://github.com/$REPO/releases/download/$LATEST_TAG/$FILENAME"

log "Downloading: $FILENAME"

cd "$TMP_DIR" || error "Cannot change to $TMP_DIR"
rm -f "$TMP_DIR/mihomo-linux-"* 2>/dev/null || true

retry curl -fSL "$URL" -o "$TMP_DIR/$FILENAME" || {
  log "curl failed, trying wget as fallback..."
  wget -q "$URL" -O "$TMP_DIR/$FILENAME" || error "Download failed (both curl and wget)"
}

# -----------------------------
# 6. Extract and test binary
# -----------------------------
log "Extracting archive..."
gzip -df "$TMP_DIR/$FILENAME" || error "Failed to extract $FILENAME"

# After gzip -d, the file name loses the .gz suffix
BINARY_NAME="mihomo-linux-${MIHOMO_ARCH}-v${LATEST_VER}"
chmod +x "$TMP_DIR/$BINARY_NAME"

log "Testing binary compatibility..."
"$TMP_DIR/$BINARY_NAME" -v >/dev/null 2>&1 || error "Binary test failed — architecture mismatch or corrupted file"

# -----------------------------
# 7. Backup old version
# -----------------------------
BACKUP_PATH="${MIHOMO_PATH}.backup"

if [ -f "$MIHOMO_PATH" ]; then
  log "Creating backup at $BACKUP_PATH"
  cp -f "$MIHOMO_PATH" "$BACKUP_PATH" || error "Failed to create backup"
fi

# -----------------------------
# 8. Replace binary
# -----------------------------
log "Replacing binary..."
mv -f "$TMP_DIR/$BINARY_NAME" "$MIHOMO_PATH" || error "Failed to replace binary"
chmod +x "$MIHOMO_PATH"

# -----------------------------
# 9. Restart mihomo service
# -----------------------------
INIT_SCRIPT=$(find /opt/etc/init.d -name '*mihomo*' -type f 2>/dev/null | head -1)

if [ -n "$INIT_SCRIPT" ]; then
  log "Restarting service: $INIT_SCRIPT"
  "$INIT_SCRIPT" restart >/dev/null 2>&1 || error "Service restart failed"
  sleep 2
else
  log "WARNING: No init script found. Please restart manually: mihomo -d /opt/etc/mihomo"
fi

# -----------------------------
# 10. Verify update
# -----------------------------
log "Verifying installation..."

sleep 1
NEW_VER=$("$MIHOMO_PATH" -v 2>/dev/null | head -1)

if [ -n "$NEW_VER" ]; then
  log "Success! $NEW_VER"
else
  log "New binary is broken! Rolling back..."

  if [ -f "$BACKUP_PATH" ]; then
    mv -f "$BACKUP_PATH" "$MIHOMO_PATH"
    chmod +x "$MIHOMO_PATH"
    [ -n "$INIT_SCRIPT" ] && "$INIT_SCRIPT" restart >/dev/null 2>&1
    log "Rolled back to previous version."
  fi

  error "Update failed — rolled back to previous version"
fi

# Check if process is running (graceful fallback if pgrep missing)
if command -v pgrep >/dev/null 2>&1; then
  if pgrep -f "mihomo" >/dev/null 2>&1; then
    log "Process is running."
  else
    log "WARNING: Binary works, but mihomo process is not detected."
  fi
else
  log "pgrep not available, skipping process check"
fi

# -----------------------------
# 11. Cleanup
# -----------------------------
rm -f "$TMP_DIR/$FILENAME" 2>/dev/null || true

# Keep backup for manual rollback, but log its location
if [ -f "$BACKUP_PATH" ]; then
  log "Backup kept at: $BACKUP_PATH"
  log "To rollback manually: mv $BACKUP_PATH $MIHOMO_PATH"
fi

# -----------------------------
# Done
# -----------------------------
echo "[OK] Mihomo updated successfully"
