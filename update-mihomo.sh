#!/bin/sh

echo "=== Mihomo Auto Updater for Keenetic ==="

TMP_DIR="/tmp"
REPO="MetaCubeX/mihomo"

log() { echo "[updater] $1"; }
error() { echo "[ERROR] $1"; exit 1; }

retry() {
  for i in 1 2 3; do
    "$@" && return 0
    sleep 2
  done
  return 1
}

# -----------------------------
# CHECK BASE
# -----------------------------
command -v opkg >/dev/null 2>&1 || {
  echo "[ERROR] opkg not found. Is Entware installed?"
  exit 1
}

log "Updating packages..."
opkg update || error "opkg update failed"

# Убедимся, что нужные утилиты есть
pkg_install() {
  opkg list-installed | grep -q "^$1 " || opkg install "$1"
}

pkg_install curl
pkg_install jq
pkg_install gzip

command -v jq >/dev/null || error "jq not installed"
command -v curl >/dev/null || error "curl not installed"

# -----------------------------
# DETECT ARCH
# -----------------------------
ARCH=$(opkg print-architecture | awk '/^arch/ && $2~/^(mips|mipsel|aarch64|arm|armv7)/{
  sub(/[-_].*/,"",$2); print $2; exit
}')

[ -z "$ARCH" ] && error "Cannot detect architecture"

# Маппинг архитектуры Entware -> бинарник Mihomo
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

log "Arch: $ARCH -> mihomo-$MIHOMO_ARCH"

# -----------------------------
# GET LATEST VERSION
# -----------------------------
log "Fetching latest release..."

LATEST_JSON=$(retry curl -fsSL "https://api.github.com/repos/$REPO/releases/latest") || \
  error "Failed to fetch release info"

LATEST_TAG=$(echo "$LATEST_JSON" | jq -r '.tag_name')
LATEST_VER=${LATEST_TAG#v}

[ -z "$LATEST_VER" ] || [ "$LATEST_VER" = "null" ] && error "Cannot parse version"

log "Latest version: $LATEST_VER"

# -----------------------------
# DOWNLOAD
# -----------------------------
FILENAME="mihomo-linux-${MIHOMO_ARCH}-v${LATEST_VER}.gz"
URL="https://github.com/$REPO/releases/download/$LATEST_TAG/$FILENAME"

log "Downloading $FILENAME..."

cd "$TMP_DIR" || error "Cannot cd to $TMP_DIR"
rm -f "$TMP_DIR/mihomo-linux-"* 2>/dev/null

retry curl -fSL "$URL" -o "$TMP_DIR/$FILENAME" || {
  # fallback на wget, если curl не справился
  log "curl failed, trying wget..."
  wget -q "$URL" -O "$TMP_DIR/$FILENAME" || error "Download failed"
}

# -----------------------------
# EXTRACT & TEST
# -----------------------------
log "Extracting..."
gzip -df "$TMP_DIR/$FILENAME" || error "Extraction failed"

BINARY_NAME="mihomo-linux-${MIHOMO_ARCH}-v${LATEST_VER}"
chmod +x "$TMP_DIR/$BINARY_NAME"

log "Testing binary..."
"$TMP_DIR/$BINARY_NAME" -v >/dev/null 2>&1 || error "Binary test failed (incompatible arch?)"

# -----------------------------
# FIND INSTALLED MIHOMO
# -----------------------------
MIHOMO_PATH=$(find /opt -name "mihomo" -type f 2>/dev/null | head -1)
[ -z "$MIHOMO_PATH" ] && MIHOMO_PATH=$(which mihomo 2>/dev/null)
[ -z "$MIHOMO_PATH" ] && error "Cannot find installed mihomo"

log "Found: $MIHOMO_PATH"
CURRENT_VER=$("$MIHOMO_PATH" -v 2>/dev/null | head -1 | awk '{print $3}')
log "Current: ${CURRENT_VER:-unknown}"

# -----------------------------
# BACKUP
# -----------------------------
if [ -f "$MIHOMO_PATH" ]; then
  log "Creating backup..."
  cp -f "$MIHOMO_PATH" "${MIHOMO_PATH}.backup" || error "Backup failed"
fi

# -----------------------------
# REPLACE
# -----------------------------
log "Replacing binary..."
mv -f "$TMP_DIR/$BINARY_NAME" "$MIHOMO_PATH" || error "Replace failed"
chmod +x "$MIHOMO_PATH"

# -----------------------------
# RESTART SERVICE
# -----------------------------
INIT_SCRIPT=$(find /opt/etc/init.d -name '*mihomo*' -type f 2>/dev/null | head -1)

if [ -n "$INIT_SCRIPT" ]; then
  log "Restarting mihomo ($INIT_SCRIPT)..."
  "$INIT_SCRIPT" restart >/dev/null 2>&1 || error "Restart failed"
  sleep 2
else
  log "WARNING: init script not found. Restart manually: mihomo -d /opt/etc/mihomo"
fi

# -----------------------------
# VERIFY
# -----------------------------
log "Verifying..."

sleep 1
NEW_VER=$("$MIHOMO_PATH" -v 2>/dev/null | head -1)

if [ -n "$NEW_VER" ]; then
  log "Success! $NEW_VER"
  
  if pgrep -f "mihomo" >/dev/null 2>&1; then
    log "Process is running."
  else
    log "WARNING: binary works, but process not detected."
  fi
else
  log "New binary broken! Rolling back..."
  
  if [ -f "${MIHOMO_PATH}.backup" ]; then
    mv -f "${MIHOMO_PATH}.backup" "$MIHOMO_PATH"
    chmod +x "$MIHOMO_PATH"
    [ -n "$INIT_SCRIPT" ] && "$INIT_SCRIPT" restart >/dev/null 2>&1
    log "Rolled back to previous version."
  fi
  
  error "Update failed"
fi

# -----------------------------
# CLEANUP
# -----------------------------
rm -f "$TMP_DIR/$FILENAME" "$TMP_DIR/$BINARY_NAME" 2>/dev/null

# -----------------------------
# DONE
# -----------------------------
echo "[OK] Mihomo updated successfully"
