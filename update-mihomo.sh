#!/bin/sh

# Mihomo Auto Updater for Keenetic routers with Entware
# -----------------------------------------------------
# Low-storage safe edition:
#   - Temp files and backups live in /tmp (tmpfs/RAM on Keenetic), not /opt
#   - Service is stopped before replacement to free disk blocks
#   - Free space is checked before writing
#   - Automatic rollback on failure
#   - GitHub API rate-limit fallback via web redirect
#
# Usage:
#   sh update-mihomo.sh
#   sh update-mihomo.sh --force     # skip version check
#
# Tested on: Keenetic ARM64 (aarch64) with Entware
# Author: saymer-alt
# Repository: https://github.com/saymer-alt/keenetic-auto-setup

set -e

echo "=== Mihomo Auto Updater for Keenetic (storage-safe) ==="

# Configuration
TMP_DIR="/tmp"
REPO="MetaCubeX/mihomo"
FORCE_UPDATE=0
SERVICE_WAS_STOPPED=0
SERVICE_WAS_RUNNING=0
OPKG_UPDATED=0

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

# Rollback helper: restores old binary and attempts to start service
rollback_and_exit() {
  log "Rolling back to previous version..."

  if [ ! -f "$TMP_BACKUP" ]; then
    error "$1 — rollback impossible: backup is missing"
  fi

  rm -f "$MIHOMO_PATH"

  cp -f "$TMP_BACKUP" "$MIHOMO_PATH" || error "$1 — failed to restore backup"
  chmod +x "$MIHOMO_PATH"
  log "Previous binary restored."

  if [ "$SERVICE_WAS_RUNNING" -eq 1 ] && [ -n "$INIT_SCRIPT" ]; then
    "$INIT_SCRIPT" start >/dev/null 2>&1 || true
    sleep 2
    if command -v pidof >/dev/null 2>&1 && pidof mihomo >/dev/null 2>&1; then
      log "Rollback successful. Previous mihomo is running."
    else
      log "WARNING: Rollback completed, but mihomo process is not detected."
    fi
  fi

  error "$1"
}

# -----------------------------
# 0. Prevent parallel updates
# -----------------------------
LOCK_FILE="/tmp/mihomo-update.lock"

if [ -e "$LOCK_FILE" ]; then
  error "Another Mihomo update is already running. Aborting."
fi

touch "$LOCK_FILE"

cleanup_lock() {
  rm -f "$LOCK_FILE"
}

trap cleanup_lock EXIT INT TERM

# -----------------------------
# 1. Base checks
# -----------------------------
command -v opkg >/dev/null 2>&1 || {
  error "opkg not found. Is Entware installed?"
}

# Install required packages if missing
pkg_install() {
  if ! opkg list-installed | grep -q "^$1 "; then
    if [ "$OPKG_UPDATED" -eq 0 ]; then
      log "Updating package lists..."
      opkg update || error "opkg update failed"
      OPKG_UPDATED=1
    fi
    opkg install "$1"
  fi
}

pkg_install curl
pkg_install jq
pkg_install gzip
pkg_install wget

command -v jq >/dev/null || error "jq is required but not installed"
command -v curl >/dev/null || error "curl is required but not installed"

# -----------------------------
# 2. RAM check (prevent OOM on low-memory devices)
# -----------------------------
TOTAL_MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
log "Total RAM: ${TOTAL_MEM_KB} KB"

if [ "$TOTAL_MEM_KB" -lt 250000 ]; then
  error "Device has less than 256MB RAM (${TOTAL_MEM_KB} KB). Update aborted to prevent OOM."
fi

# -----------------------------
# 3. Detect router architecture
# -----------------------------
ARCH=$(uname -m)

# Map uname arch to Mihomo release binary name
case "$ARCH" in
  aarch64)
    MIHOMO_ARCH="arm64"
    ;;
  armv7l|armv7*)
    MIHOMO_ARCH="armv7"
    ;;
  mips|mipsel)
    error "MIPS is not supported by official Mihomo binaries. Use opkg package or build manually."
    ;;
  *)
    error "Unsupported architecture: $ARCH"
    ;;
esac

log "Detected arch: $ARCH -> mihomo-$MIHOMO_ARCH"

# -----------------------------
# 4. Fetch latest release info
# -----------------------------
log "Fetching latest release from GitHub API..."

LATEST_JSON=$(retry curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null) || LATEST_JSON=""

LATEST_TAG=""
if [ -n "$LATEST_JSON" ]; then
  LATEST_TAG=$(echo "$LATEST_JSON" | jq -r '.tag_name')
  if [ "$LATEST_TAG" != "null" ] && [ -n "$LATEST_TAG" ]; then
    log "Got version via GitHub API: $LATEST_TAG"
  else
    LATEST_TAG=""
  fi
fi

if [ -z "$LATEST_TAG" ]; then
  log "GitHub API failed or rate-limited. Falling back to web redirect..."
  REDIRECT_URL=$(curl -fsSL -o /dev/null -w '%{url_effective}\n' "https://github.com/$REPO/releases/latest") || REDIRECT_URL=""
  if [ -n "$REDIRECT_URL" ]; then
    LATEST_TAG=$(echo "$REDIRECT_URL" | sed 's#.*/tag/##')
    log "Got version via web redirect: $LATEST_TAG"
  fi
fi

[ -z "$LATEST_TAG" ] && error "Failed to determine latest release (both API and web redirect failed)"

LATEST_VER=${LATEST_TAG#v}

[ -z "$LATEST_VER" ] || [ "$LATEST_VER" = "null" ] && error "Cannot parse version from GitHub response"

log "Latest available version: $LATEST_VER"

# -----------------------------
# 5. Find currently installed mihomo
# -----------------------------
MIHOMO_PATH=$(find /opt -name "mihomo" -type f 2>/dev/null | head -1)
[ -z "$MIHOMO_PATH" ] && MIHOMO_PATH=$(which mihomo 2>/dev/null)
[ -z "$MIHOMO_PATH" ] && error "Cannot find installed mihomo binary"

MIHOMO_DIR=$(dirname "$MIHOMO_PATH")
log "Installed at: $MIHOMO_PATH"

CURRENT_VER=""
if VERSION_OUTPUT=$("$MIHOMO_PATH" -v 2>/dev/null); then
  CURRENT_VER=$(echo "$VERSION_OUTPUT" | head -1 | awk '{print $3}')
fi
log "Current version: ${CURRENT_VER:-unknown}"

# Skip update if versions match (unless --force)
if [ "$FORCE_UPDATE" -eq 0 ] && [ "$CURRENT_VER" = "$LATEST_VER" ]; then
  log "Already up to date ($CURRENT_VER). Use --force to reinstall."
  exit 0
fi

# Remember whether Mihomo was running before the update
if command -v pidof >/dev/null 2>&1 && pidof mihomo >/dev/null 2>&1; then
  SERVICE_WAS_RUNNING=1
fi

# -----------------------------
# 6. Download new binary to /tmp
# -----------------------------
FILENAME="mihomo-linux-${MIHOMO_ARCH}-v${LATEST_VER}.gz"
URL="https://github.com/$REPO/releases/download/$LATEST_TAG/$FILENAME"

log "Downloading: $FILENAME"

cd "$TMP_DIR" || error "Cannot change to $TMP_DIR"
rm -f "$TMP_DIR/mihomo-linux-"* "$TMP_DIR/mihomo.backup."* 2>/dev/null || true

retry curl -fSL "$URL" -o "$TMP_DIR/$FILENAME" || {
  log "curl failed, trying wget as fallback..."
  wget -q "$URL" -O "$TMP_DIR/$FILENAME" || error "Download failed (both curl and wget)"
}

# -----------------------------
# 7. Extract and test binary
# -----------------------------
log "Extracting archive..."
gzip -df "$TMP_DIR/$FILENAME" || error "Failed to extract $FILENAME"

# After gzip -d, the file name loses the .gz suffix
BINARY_NAME="mihomo-linux-${MIHOMO_ARCH}-v${LATEST_VER}"
chmod +x "$TMP_DIR/$BINARY_NAME"

log "Testing binary compatibility..."
"$TMP_DIR/$BINARY_NAME" -v >/dev/null 2>&1 || error "Binary test failed — architecture mismatch or corrupted file"

log "Testing new binary with current config..."
if [ -d "/opt/etc/mihomo" ]; then
  if ! "$TMP_DIR/$BINARY_NAME" -d /opt/etc/mihomo -t >/dev/null 2>&1; then
    error "Config test failed! New version is incompatible with current config.yaml. Update aborted."
  fi
  log "Config test passed."
else
  log "WARNING: /opt/etc/mihomo not found, skipping config test."
fi

# -----------------------------
# 8. Check free space and clean old backups
# -----------------------------
NEW_SIZE_BYTES=$(wc -c < "$TMP_DIR/$BINARY_NAME")
NEW_SIZE_KB=$(( (NEW_SIZE_BYTES + 1023) / 1024 ))
NEED_KB=$((NEW_SIZE_KB + 4096))  # 4 MB safety margin

get_avail_kb() {
  df -k "$MIHOMO_DIR" | awk 'NR==2 {print $4}'
}

AVAIL_KB=$(get_avail_kb)
log "Free space on $MIHOMO_DIR: ${AVAIL_KB} KB"
log "New binary size: ${NEW_SIZE_KB} KB (need ~${NEED_KB} KB)"

# Remove stale backups in /opt to reclaim space
cleaned=0
for bak in "$MIHOMO_PATH.backup" "$MIHOMO_PATH.old" "$MIHOMO_PATH.bak"; do
  if [ -f "$bak" ]; then
    log "Removing old backup: $bak"
    rm -f "$bak"
    cleaned=1
  fi
done

if [ "$cleaned" -eq 1 ]; then
  AVAIL_KB=$(get_avail_kb)
  log "Recalculated free space: ${AVAIL_KB} KB"
fi

# -----------------------------
# 9. Find init script
# -----------------------------
INIT_SCRIPT=$(find /opt/etc/init.d -name '*mihomo*' -type f 2>/dev/null | head -1)

if [ -n "$INIT_SCRIPT" ]; then
  log "Found init script: $INIT_SCRIPT"
else
  log "WARNING: No init script found in /opt/etc/init.d"
fi

# If still not enough space, stop the service so the old binary
# is no longer held open and its disk blocks can be reclaimed.
if [ "$AVAIL_KB" -lt "$NEED_KB" ]; then
  if [ -n "$INIT_SCRIPT" ]; then
    log "Low space. Stopping mihomo to free disk blocks..."
    "$INIT_SCRIPT" stop >/dev/null 2>&1 || true
    SERVICE_WAS_STOPPED=1
    sleep 2
    AVAIL_KB=$(get_avail_kb)
    log "Free space after stop: ${AVAIL_KB} KB"
  fi
fi

if [ "$AVAIL_KB" -lt "$NEED_KB" ]; then
  error "Not enough free space on $MIHOMO_DIR (${AVAIL_KB} KB available, ${NEED_KB} KB required).
Free up space manually or install Mihomo on external storage."
fi

# -----------------------------
# 10. Backup old binary to /tmp (RAM), not /opt
# -----------------------------
TMP_BACKUP="$TMP_DIR/mihomo.backup.$$"

if [ -f "$MIHOMO_PATH" ]; then
  log "Backing up current binary to $TMP_BACKUP ..."
  cp -f "$MIHOMO_PATH" "$TMP_BACKUP" || error "Failed to create backup in /tmp"
fi

# -----------------------------
# 11. Stop service (if not already stopped), remove old binary, install new one
# -----------------------------
if [ -n "$INIT_SCRIPT" ] && [ "$SERVICE_WAS_STOPPED" -eq 0 ]; then
  log "Stopping mihomo service..."
  "$INIT_SCRIPT" stop >/dev/null 2>&1 || true
  sleep 1
fi

log "Removing old binary from $MIHOMO_DIR ..."
if ! rm -f "$MIHOMO_PATH"; then
  rollback_and_exit "Failed to remove old binary"
fi

log "Installing new binary..."
if ! cp -f "$TMP_DIR/$BINARY_NAME" "$MIHOMO_PATH"; then
  rollback_and_exit "Failed to replace binary — rolled back to previous version"
fi

if ! chmod +x "$MIHOMO_PATH"; then
  rollback_and_exit "Failed to set executable permission"
fi

# -----------------------------
# 12. Test new binary in place and verify version
# -----------------------------
log "Testing installed binary..."
if ! "$MIHOMO_PATH" -v >/dev/null 2>&1; then
  rollback_and_exit "New binary test failed — rolled back to previous version"
fi

INSTALLED_VER=$("$MIHOMO_PATH" -v 2>/dev/null | head -1 | awk '{print $3}')

if [ "$INSTALLED_VER" != "$LATEST_VER" ]; then
  rollback_and_exit "Installed version mismatch: expected $LATEST_VER, got ${INSTALLED_VER:-unknown}"
fi

log "Installed version verified: $INSTALLED_VER"

# -----------------------------
# 13. Start service and verify process
# -----------------------------
if [ "$SERVICE_WAS_RUNNING" -eq 1 ]; then
  if [ -n "$INIT_SCRIPT" ]; then
    log "Starting mihomo service..."
    if ! "$INIT_SCRIPT" start >/dev/null 2>&1; then
      log "WARNING: Mihomo init script reported start failure. Checking process..."
    fi

    if command -v pidof >/dev/null 2>&1; then
      SERVICE_OK=0
      for i in 1 2 3 4 5; do
        if pidof mihomo >/dev/null 2>&1; then
          SERVICE_OK=1
          break
        fi
        sleep 1
      done

      if [ "$SERVICE_OK" -ne 1 ]; then
        rollback_and_exit "Service start failed — rolled back to previous version"
      fi
    else
      log "pidof not available, skipping strict process verification."
    fi
  else
    log "WARNING: No init script found. Please start manually: mihomo -d /opt/etc/mihomo"
  fi
else
  log "Service was stopped prior to update. Leaving it stopped."
fi

# -----------------------------
# 14. Final process verification
# -----------------------------
if [ "$SERVICE_WAS_RUNNING" -eq 1 ]; then
  if command -v pidof >/dev/null 2>&1; then
    if pidof mihomo >/dev/null 2>&1; then
      log "Process is running."
    else
      log "WARNING: Binary works, but mihomo process is not detected."
    fi
  else
    log "pidof not available, skipping process check"
  fi
fi

# -----------------------------
# 15. Cleanup
# -----------------------------
rm -f "$TMP_BACKUP" "$TMP_DIR/$FILENAME" "$TMP_DIR/$BINARY_NAME" 2>/dev/null || true

# -----------------------------
# Done
# -----------------------------
log "Success! Updated to $LATEST_VER"
echo "[OK] Mihomo updated successfully"
