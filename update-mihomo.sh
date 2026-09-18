#!/bin/sh

# Mihomo Auto Updater for Keenetic routers with Entware
# -----------------------------------------------------
# Binary-update edition, package-container source:
#   - Source of truth: the ready-to-install Entware .ipk set published on the
#     saymer-alt/entware-go release tagged `latest` (the project's build
#     pipeline uploads there only after the full multi-arch package set is
#     built and verified).
#   - The updater never looks at MetaCubeX releases at all. It only sees the
#     latest version actually packaged on entware-go:latest: if the device
#     already runs that version the result is "Already up to date"; if the
#     device is older it is updated to that version. An upstream MetaCubeX
#     release that has not been packaged yet is simply invisible here.
#   - The .ipk is used ONLY as the canonical architecture-specific container
#     of the new /opt/bin/mihomo binary: the updater extracts
#     ./opt/bin/mihomo from it and then performs the usual transactional
#     binary replacement. `opkg install` is never invoked for Mihomo, so the
#     opkg package database is never touched and can never disagree with the
#     binary this updater restores on rollback. opkg itself is used only for
#     architecture information and, if missing, for the updater's own tool
#     dependencies (curl, jq, gzip).
#   - Staged /tmp lifecycle keeps the peak footprint small: outer archive is
#     unpacked into a dedicated temp dir, the downloaded .ipk is deleted
#     immediately, then data.tar.gz is unpacked and immediately removed along
#     with the rest of the package payload — only the new binary stays, and
#     it is deleted together with the backup by the centralized cleanup trap
#     on EVERY exit (success, abort, config failure, download/extraction
#     failure, signal, rollback). The update lock is released by the same trap.
#   - Pre-flight: the extracted binary is checked before anything on the
#     system is modified — its `mihomo -v` must match the version in the
#     package filename, then it is tested against the current config.yaml
#     (mihomo -d /opt/etc/mihomo -t). Failure leaves the old Mihomo intact.
#   - Rollback: the previous binary is backed up to /tmp before replacement
#     and restored if any post-replacement check fails.
#   - One-instance rule: the packaged binary is UPX-packed and unpacks
#     itself in memory on execution; two Mihomo instances must never run
#     at the same time (on 256 MB devices a second instance crashed with
#     SIGSEGV). This updater extracts the package and performs every check
#     that does not execute the new ELF while the old Mihomo is still
#     running, then stops the old Mihomo, and only then runs the runtime
#     pre-flight of the new binary. The stop is confirmed and re-checked
#     again right before the replacement, because the cron watchdog
#     restarts Mihomo whenever its port is unreachable — which it is
#     during this downtime. The short downtime is intended; the previous
#     service state is restored afterwards. A running Mihomo without an
#     init script is an abort, never a second instance. The rule covers
#     the INSTALLED binary as well: while a Mihomo daemon may be running
#     (pidof reports it, or pidof is unavailable so the state is unknown),
#     the installed-version probe (`mihomo -v` on the installed ELF) is
#     deferred until after the controlled stop — a second execution at
#     that moment is the documented SIGSEGV pattern (rc=139) on 256 MB
#     devices, and after the stop it is safe. The version decision then
#     happens with the daemon down; the "already up to date" and
#     downgrade-skip exits restore the service. Re-running the updater on
#     a current version with the daemon up therefore costs one package
#     download and a short planned downtime instead of a blind second
#     ELF execution.
#   - No automatic downgrade: the available version is numerically compared
#     with the installed one (the updater's truth is `mihomo -v`, not opkg).
#     An older available version — or one that cannot be reliably ordered,
#     e.g. prerelease/build suffixes — is skipped with a warning, even with
#     --force. Downgrade, if ever needed, is a separate manual task.
#   - Signal safety: INT/TERM abort the updater and restore the system
#     (service state in Phase A, binary rollback in Phase B); EXIT only
#     cleans temp files.
#   - User config.yaml is only ever read (mihomo -t); never written.
#
# Usage:
#   sh update-mihomo.sh
#   sh update-mihomo.sh --force     # replace even if the version already matches
#
# Tested on: Keenetic ARM64 (aarch64) with Entware
# Author: saymer-alt
# Repository: https://github.com/saymer-alt/keenetic-auto-setup

set -e

echo "=== Mihomo Auto Updater for Keenetic (binary update, entware-go packages) ==="

# Configuration
TMP_DIR="/tmp"
REPO="saymer-alt/entware-go"
CONFIG_PATH="/opt/etc/mihomo/config.yaml"
FORCE_UPDATE=0
SERVICE_WAS_STOPPED=0
SERVICE_WAS_RUNNING=0
OPKG_UPDATED=0
REPLACEMENT_STARTED=0
TMP_NEW=""
WORK_DIR=""

# Parse arguments
for arg in "$@"; do
  case "$arg" in
    --force) FORCE_UPDATE=1 ;;
  esac
done

# Logging helpers
log() { echo "[updater] $1"; }
warn() { echo "[WARN] $1"; }
error() { echo "[ERROR] $1"; exit 1; }

# Retry wrapper: attempts a command up to 3 times with 2s delay
retry() {
  for i in 1 2 3; do
    "$@" && return 0
    sleep 2
  done
  return 1
}

# Numeric dotted-version comparator: prints lt | eq | gt, or "unknown" when
# either version carries non-numeric components (prerelease/build suffixes).
# Deliberately minimal — unknown means "cannot order" and the caller errs on
# the safe side (no replacement). Not a SemVer library.
ver_compare() {
  _va=$1
  _vb=$2
  while :; do
    _a=${_va%%.*}
    _ra=""
    case "$_va" in *.*) _ra=${_va#*.} ;; esac
    _b=${_vb%%.*}
    _rb=""
    case "$_vb" in *.*) _rb=${_vb#*.} ;; esac
    if [ -z "$_a" ]; then _a=0; fi
    if [ -z "$_b" ]; then _b=0; fi
    case "$_a$_b" in
      *[!0-9]*) echo unknown; return 0 ;;
    esac
    if [ "$_a" -lt "$_b" ]; then echo lt; return 0; fi
    if [ "$_a" -gt "$_b" ]; then echo gt; return 0; fi
    if [ -z "$_ra" ] && [ -z "$_rb" ]; then echo eq; return 0; fi
    _va=$_ra
    _vb=$_rb
  done
}

# -----------------------------
# Extract the new binary from an Entware .ipk package container.
#
# Entware .ipk = gzipped tar with ./debian-binary ./control.tar.gz
# ./data.tar.gz; the binary lives inside data.tar.gz as ./opt/bin/mihomo.
# Everything is extracted (no member-name matching — maximally BusyBox-safe)
# using only tar/gzip/mkdir/test, all present on BusyBox/Entware out of the
# box. Staged deletion keeps the /tmp peak small:
#   outer archive unpacked -> downloaded .ipk deleted immediately ->
#   data.tar.gz unpacked -> outer payload deleted immediately ->
#   only the new binary tree remains.
# Sets EXTRACTED_BIN on success; leaves the binary tree in <workdir>.
# -----------------------------
extract_new_binary_from_ipk() {
  EXTRACTED_BIN=""
  _ipk="$1"
  _wd="$2"

  mkdir -p "$_wd" || return 1

  if ! tar -xzf "$_ipk" -C "$_wd"; then
    gzip -dc "$_ipk" 2>/dev/null | tar -x -C "$_wd" || return 1
  fi
  [ -f "$_wd/data.tar.gz" ] || return 1
  rm -f "$_ipk"

  if ! tar -xzf "$_wd/data.tar.gz" -C "$_wd"; then
    gzip -dc "$_wd/data.tar.gz" 2>/dev/null | tar -x -C "$_wd" || return 1
  fi
  [ -f "$_wd/opt/bin/mihomo" ] || return 1
  rm -f "$_wd/data.tar.gz" "$_wd/control.tar.gz" "$_wd/debian-binary"
  rm -rf "$_wd/opt/etc"

  EXTRACTED_BIN="$_wd/opt/bin/mihomo"
  return 0
}

# Rollback helper: restores the pre-update binary and attempts to start the
# service if this updater is responsible for it being down. The opkg package
# database is not involved at all: this updater only ever replaces the
# /opt/bin/mihomo file, so the restored system is exactly the pre-update one.
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

# Restore a service that THIS updater stopped (the one-instance stop before
# the runtime pre-flight, or the ghost-block space stop) when the update
# aborts before the old binary is replaced. The
# old binary is still in place, so starting it returns the system to its
# pre-update state. A user-stopped service (SERVICE_WAS_STOPPED=0) is never
# touched. Abort paths after the binary replacement are handled by
# rollback_and_exit and must not go through this path.
restore_stopped_service() {
  if [ "$SERVICE_WAS_STOPPED" -ne 1 ] || [ -z "$INIT_SCRIPT" ]; then
    return 0
  fi
  if command -v pidof >/dev/null 2>&1 && pidof mihomo >/dev/null 2>&1; then
    log "Mihomo is already running again; nothing to restore."
    return 0
  fi
  log "Update aborted before replacement: restarting Mihomo stopped by this updater..."
  "$INIT_SCRIPT" start >/dev/null 2>&1 || true
  if command -v pidof >/dev/null 2>&1; then
    _i=0
    while [ "$_i" -lt 5 ]; do
      if pidof mihomo >/dev/null 2>&1; then
        log "Old Mihomo is running again."
        return 0
      fi
      sleep 1
      _i=$((_i + 1))
    done
    log "WARNING: could not confirm Mihomo is running after restore."
  else
    log "pidof not available, skipping restore verification."
  fi
  return 0
}

# Pre-flight failure: nothing on the system has been modified, but this
# updater may already have stopped the old service (the one-instance stop
# or the ghost-block stop) — bring it back before exiting.
preflight_fail() {
  restore_stopped_service
  error "$1"
}

# Stop Mihomo and confirm it is really down before anything may execute the
# new binary. Aborts the update rather than ever risking a second Mihomo
# instance. Called before the runtime pre-flight and again right before the
# destructive replacement: the cron watchdog restarts Mihomo whenever its
# port is unreachable, which is exactly the state during this updater's
# downtime, so an instance stopped above may legitimately come back.
stop_mihomo_confirmed() {
  if [ -z "$INIT_SCRIPT" ]; then
    preflight_fail "Mihomo is running but no init script was found in /opt/etc/init.d. A second Mihomo instance must not be started alongside it — stop Mihomo manually and re-run the updater."
  fi
  "$INIT_SCRIPT" stop >/dev/null 2>&1 || true
  SERVICE_WAS_STOPPED=1
  _i=0
  while [ "$_i" -lt 10 ]; do
    pidof mihomo >/dev/null 2>&1 || break
    sleep 1
    _i=$((_i + 1))
  done
  if pidof mihomo >/dev/null 2>&1; then
    preflight_fail "Old Mihomo did not stop — refusing to run a second Mihomo instance. Update aborted, installed binary untouched."
  fi
  sleep 1
}

# Centralized temp cleanup: runs on EVERY exit (success, safe abort, config
# failure, download/extraction failure, signal, rollback). No large artifacts
# (downloaded .ipk, extracted package data, new binary, backup) survive the
# updater; the lock file is cleaned by the same trap.
cleanup_tmp() {
  rm -f "$LOCK_LEGACY" 2>/dev/null || true
  rm -rf "$LOCK_DIR" 2>/dev/null || true
  rm -f "$TMP_DIR"/mihomo-update.ipk "$TMP_DIR"/mihomo.backup.* 2>/dev/null || true
  rm -rf "$TMP_DIR"/mihomo-ipk.* 2>/dev/null || true
}

# Signal safety: INT/TERM explicitly abort the updater and restore the
# system; EXIT only cleans temp files. REPLACEMENT_STARTED separates
#   Phase A (0): old binary untouched — restore a service the updater
#                stopped itself; a user-stopped service is never started.
#   Phase B (1): old binary already replaced — full rollback from the backup.
# Re-entry via further INT/TERM/HUP is disabled first; the handler always exits
# non-zero (Phase B through rollback_and_exit, whose `error` exits 1 after
# the rollback completed — the EXIT trap cleans only afterwards, so the
# backup is never removed before the rollback is done).
signal_handler() {
  trap '' INT TERM HUP
  log "Received $1 — aborting update."
  if [ "$REPLACEMENT_STARTED" -eq 1 ]; then
    rollback_and_exit "Update interrupted ($1)"
  fi
  restore_stopped_service
  log "No changes were made."
  cleanup_tmp
  exit 1
}

# -----------------------------
# -----------------------------
# 0. Prevent parallel updates - atomic mkdir lock, stale-safe takeover.
#
# /tmp/mihomo-update.lock.d IS the lock: mkdir is an atomic test-and-set,
# so two concurrent updaters can never both believe they own it. The pid
# and ts files inside serve liveness and stale recovery only - losing or
# misreading them never weakens mutual exclusion:
#   mkdir ok            -> we own the lock
#   dir held, pid alive and its /proc/<pid>/cmdline references this
#   updater             -> another run is active, abort
#   pid dead, or alive with a foreign cmdline (PID reuse) -> stale owner
#   pid missing/garbage -> fresh (<60s by ts) may be a starter between
#   its mkdir and its pid write: abort; otherwise stale
# A stale takeover renames the directory away first (the mv IS the atomic
# claim: exactly one recoverer wins) and then removes only the directory
# it renamed. A takeover additionally requires that NO live process with
# this updater's name exists in /proc - the independent process scan is
# the backstop that keeps malformed metadata or clock anomalies from ever
# overrunning a live run. Wall-clock age alone decides nothing: the
# router may boot before time sync, so a live owner pid (checked through
# /proc/<pid>/cmdline) always outranks any timestamp.
# Legacy form: versions before the mkdir lock used the plain file
# /tmp/mihomo-update.lock with no owner metadata. It is still honored:
# a legacy lock backed by a live update process blocks this run; with no
# live update process behind it, it is stale and reclaimed. While we
# hold the lock we keep the legacy file present with our pid, so an
# old-version updater (which only checks that the file exists) still
# sees "another update is running" instead of racing us. Residual: an
# old-version updater has a racy check-then-touch of its own and can
# slip through a microseconds-wide window; that generation is racy by
# design and phases out as routers update.
# -----------------------------
LOCK_DIR="/tmp/mihomo-update.lock.d"
LOCK_LEGACY="/tmp/mihomo-update.lock"
LOCK_TOOL_MARKER="update-mihomo"
LOCK_HINT="If no update is actually running, remove it manually: rm -rf /tmp/mihomo-update.lock.d /tmp/mihomo-update.lock"

# True when <pid> is a live process whose cmdline references this updater.
lock_pid_is_ours() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ -d "/proc/$1" ] || return 1
  grep -q "$LOCK_TOOL_MARKER" "/proc/$1/cmdline" 2>/dev/null
}

# Independent backstop for every takeover decision: is any OTHER live
# process visibly running this updater? Covers legacy locks (which carry
# no pid), half-written metadata and PID reuse. Self and the direct
# parent are excluded; a false positive only errs on the safe side.
LOCK_TOOL_PIDS=""
lock_tool_alive() {
  LOCK_TOOL_PIDS=""
  for _lock_d in /proc/[0-9]*; do
    [ "$_lock_d" = "/proc/$$" ] && continue
    [ "$_lock_d" = "/proc/$PPID" ] && continue
    if grep -q "$LOCK_TOOL_MARKER" "$_lock_d/cmdline" 2>/dev/null; then
      LOCK_TOOL_PIDS="$LOCK_TOOL_PIDS ${_lock_d#/proc/}"
    fi
  done
  [ -n "$LOCK_TOOL_PIDS" ]
}

lock_write_owner() {
  # The claim symlink is the ownership decider: creating it is an atomic
  # create-if-absent, so on a filesystem/kernel where directory creation
  # itself is not a reliable test-and-set (observed on a WSL2 kernel), two
  # concurrent starters still cannot both hold the lock - exactly one
  # claim lands, the loser backs off without touching anything. On normal
  # kernels the ln cannot fail after our own mkdir and this is a no-op
  # guarantee. Written before pid/ts so a lost claim never corrupts the
  # winner's metadata.
  ln -s "pid=$$;ts=$(date +%s)" "$LOCK_DIR/claim" 2>/dev/null || return 1
  echo "$$" > "$LOCK_DIR/pid" 2>/dev/null || true
  date +%s > "$LOCK_DIR/ts" 2>/dev/null || true
  # Best-effort legacy companion: old-version updaters only check that
  # the plain file exists; new runs read our pid from it.
  echo "$$" > "$LOCK_LEGACY" 2>/dev/null || true
}

acquire_lock() {
  # Legacy evidence first: an old-version updater only knows the plain
  # lock file, so its presence outranks everything else.
  if [ -e "$LOCK_LEGACY" ]; then
    if [ ! -f "$LOCK_LEGACY" ] || [ -L "$LOCK_LEGACY" ]; then
      error "Update lock has an unexpected form: $LOCK_LEGACY is not a regular file. Will not remove an unknown object. $LOCK_HINT"
    fi
    _lp=$(head -n 1 "$LOCK_LEGACY" 2>/dev/null | awk '{print $1}' || true)
    if lock_pid_is_ours "$_lp"; then
      error "Another Mihomo update is already running (pid $_lp). Aborting."
    fi
    if lock_tool_alive; then
      error "Another Mihomo update is already running (live process:${LOCK_TOOL_PIDS}). Aborting."
    fi
    log "Removing stale legacy update lock (no live update process behind it)..."
    rm -f "$LOCK_LEGACY"
  fi

  if mkdir "$LOCK_DIR" 2>/dev/null; then
    if ! lock_write_owner; then
      # The claim was lost to a concurrent starter (or the write failed):
      # back off WITHOUT cleanup - the visible lock belongs to the winner.
      error "Another Mihomo update is already running (lock claim lost). Aborting."
    fi
    return 0
  fi

  if [ ! -d "$LOCK_DIR" ]; then
    error "Update lock has an unexpected form: $LOCK_DIR is not a directory. Will not remove an unknown object. $LOCK_HINT"
  fi

  _lp=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
  _lock_busy=0
  case "$_lp" in
    ''|*[!0-9]*)
      # Missing/garbage pid: possibly a starter between its mkdir and its
      # pid write (microseconds). Trust only a fresh ts; a malformed or
      # missing ts counts as ancient and falls through to the
      # live-process backstop before any takeover.
      _now=$(date +%s)
      _ts=$(cat "$LOCK_DIR/ts" 2>/dev/null || true)
      case "$_ts" in ''|*[!0-9]*) _ts=0 ;; esac
      [ $((_now - _ts)) -lt 60 ] && _lock_busy=1
      ;;
    *)
      lock_pid_is_ours "$_lp" && _lock_busy=1
      # /proc/<pid> gone, or alive with a foreign cmdline (PID reuse):
      # a dead or stale owner either way; the backstop below still runs.
      ;;
  esac
  if [ "$_lock_busy" -eq 1 ]; then
    error "Another Mihomo update is already running. Aborting."
  fi

  # Stale verdict: a live maintenance process must never be overrun,
  # whatever its (malformed) metadata says.
  if lock_tool_alive; then
    error "Another Mihomo update is already running (live process:${LOCK_TOOL_PIDS}). Aborting."
  fi

  log "Taking over a stale update lock (owner pid ${_lp:-unknown} is gone)..."
  _claim="$LOCK_DIR.stale.$$"
  if mv "$LOCK_DIR" "$_claim" 2>/dev/null; then
    rm -rf "$_claim"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      lock_write_owner
      return 0
    fi
    # A fresh run took the freed path first; it owns the lock now.
    error "Another Mihomo update is already running. Aborting."
  fi
  error "Another Mihomo update is already running. Aborting."
}

acquire_lock

trap cleanup_tmp EXIT
trap 'signal_handler INT' INT
trap 'signal_handler TERM' TERM
trap 'signal_handler HUP' HUP



# -----------------------------
# 1. Base checks and updater dependencies
# -----------------------------
command -v opkg >/dev/null 2>&1 || {
  error "opkg not found. Is Entware installed?"
}

# Install required packages if missing. `opkg update` here serves the
# updater's own tooling (curl, jq, gzip) only — Mihomo itself is never
# installed from a feed or through opkg.
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

command -v jq >/dev/null || error "jq is required but not installed"
command -v curl >/dev/null || error "curl is required but not installed"
command -v tar >/dev/null || error "tar is required but not installed (busybox applet)"

# -----------------------------
# 2. RAM notice (low RAM is the user's responsibility)
# -----------------------------
TOTAL_MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)
case "$TOTAL_MEM_KB" in
  ''|*[!0-9]*) TOTAL_MEM_KB="" ;;
esac

if [ -n "$TOTAL_MEM_KB" ]; then
  log "Total RAM: ${TOTAL_MEM_KB} KB"
  if [ "$TOTAL_MEM_KB" -lt 250000 ]; then
    warn "Device has less than 256 MB RAM (${TOTAL_MEM_KB} KB). Update may require additional memory and can fail on low-memory systems."
  fi
fi

# -----------------------------
# 3. Detect Entware architecture (same method as install.sh)
# -----------------------------
ARCH=$(opkg print-architecture | awk '/^arch/ && $2~/^(mips|mipsel|aarch64|arm)/{
    sub(/[-_].*/,"",$2); print $2; exit
}')

[ -z "$ARCH" ] && error "Cannot detect architecture"

case "$ARCH" in
  aarch64*)            IPK_SUFFIX="aarch64-3.10" ;;
  armv7*|arm*)         IPK_SUFFIX="armv7-3.2" ;;
  mipsel*)             IPK_SUFFIX="mipsel-3.4" ;;
  mips*)               IPK_SUFFIX="mips-3.4" ;;
  *) error "Unsupported architecture: $ARCH" ;;
esac

log "Detected Entware arch: $ARCH"
log "Package architecture: $IPK_SUFFIX"

# -----------------------------
# 4. Fetch the `latest` release of saymer-alt/entware-go
# -----------------------------
log "Fetching latest package release from saymer-alt/entware-go..."

RELEASE_JSON=$(retry curl -fsSL "https://api.github.com/repos/$REPO/releases/tags/latest" 2>/dev/null) || RELEASE_JSON=""

if [ -z "$RELEASE_JSON" ]; then
  log "tags/latest endpoint failed, trying releases/latest..."
  RELEASE_JSON=$(retry curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null) || RELEASE_JSON=""
fi

[ -z "$RELEASE_JSON" ] && error "Failed to fetch release information from $REPO"

# -----------------------------
# 5. Find currently installed mihomo (deterministic resolution; see the
#    resolver comment for the source-of-truth order)
# -----------------------------
# -----------------------------
# Resolve the Mihomo runtime binary deterministically. The Entware init
# script resolves `mihomo` through a PATH in which /opt/sbin precedes
# /opt/bin, so a router keeping both copies runs /opt/sbin/mihomo
# (live-verified through /proc/<pid>/exe). A running daemon's
# /proc/<pid>/exe is authoritative when it names one of these two
# canonical paths; nested copies such as meta-backup/mihomo are never
# considered.
# -----------------------------
resolve_mihomo_binary() {
  if command -v pidof >/dev/null 2>&1; then
    for _p in $(pidof mihomo 2>/dev/null); do
      _exe=$(readlink "/proc/$_p/exe" 2>/dev/null) || continue
      if [ "$_exe" = "/opt/sbin/mihomo" ] || [ "$_exe" = "/opt/bin/mihomo" ]; then
        if [ -x "$_exe" ]; then
          printf '%s\n' "$_exe"
          return 0
        fi
      fi
    done
  fi
  if [ -x /opt/sbin/mihomo ]; then
    printf '%s\n' /opt/sbin/mihomo
    return 0
  fi
  if [ -x /opt/bin/mihomo ]; then
    printf '%s\n' /opt/bin/mihomo
    return 0
  fi
  return 0
}

MIHOMO_PATH=$(resolve_mihomo_binary)
[ -z "$MIHOMO_PATH" ] && error "Cannot find installed mihomo binary at /opt/sbin/mihomo or /opt/bin/mihomo. Use install.sh to install it first."

MIHOMO_DIR=$(dirname "$MIHOMO_PATH")
log "Installed at: $MIHOMO_PATH"

# One-instance rule for the INSTALLED binary too: while a daemon may be
# running (pidof reports mihomo, or pidof is unavailable so the state is
# unknown), executing a second Mihomo ELF is the documented SIGSEGV
# pattern on memory-constrained devices. Defer the version probe until
# after the controlled stop; only a confirmed-down daemon allows the
# early probe (the fast, zero-downtime "already up to date" path).
DEFER_VERSION_DECISION=1
if command -v pidof >/dev/null 2>&1 && ! pidof mihomo >/dev/null 2>&1; then
  DEFER_VERSION_DECISION=0
fi
CURRENT_VER=""
if [ "$DEFER_VERSION_DECISION" -eq 0 ]; then
  if VERSION_OUTPUT=$("$MIHOMO_PATH" -v 2>/dev/null); then
    CURRENT_VER=$(echo "$VERSION_OUTPUT" | head -1 | awk '{print $3}')
    CURRENT_VER=${CURRENT_VER#v}
  fi
fi
if [ "$DEFER_VERSION_DECISION" -eq 1 ]; then
  log "Mihomo may be running — the installed-version probe is deferred until after the controlled stop (one-instance rule)."
fi
log "Current Mihomo: ${CURRENT_VER:-unknown}"

# -----------------------------
# 6. Select the package asset for this architecture
# -----------------------------
DOWNLOAD_URL=""

if [ -n "$RELEASE_JSON" ]; then
  DOWNLOAD_URL=$(printf '%s\n' "$RELEASE_JSON" | jq -r --arg suffix "$IPK_SUFFIX" '
    .assets[]?
    | select(.name | startswith("mihomo_") and endswith("_" + $suffix + ".ipk") and (contains("nohf") | not))
    | .browser_download_url
  ' 2>/dev/null | head -n 1)
fi

if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ]; then
  log "jq filter empty, trying grep fallback on API response..."
  if [ -n "$RELEASE_JSON" ]; then
    DOWNLOAD_URL=$(printf '%s\n' "$RELEASE_JSON" \
      | grep -o '"browser_download_url": *"[^"]*mihomo_[^"]*_'${IPK_SUFFIX}'\.ipk"' \
      | grep -v "nohf" \
      | head -n 1 | sed 's/.*": *"//;s/"$//')
  fi
fi

if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ]; then
  error "No mihomo package for $IPK_SUFFIX in $REPO:latest — only versions actually published there can be installed. Check https://github.com/$REPO/releases"
fi

ASSET_NAME=$(basename "$DOWNLOAD_URL")

# Sanity: exactly a mihomo package for this architecture, never the
# armv7 softfloat variant (mihomo_nohf_...) and never a foreign file.
case "$ASSET_NAME" in
  mihomo_*_${IPK_SUFFIX}.ipk) : ;;
  *) error "Unexpected asset for ${IPK_SUFFIX}: ${ASSET_NAME:-<empty>}" ;;
esac
case "$ASSET_NAME" in
  *nohf*) error "Unexpected nohf variant selected: $ASSET_NAME" ;;
esac

# Package version parsing: strip mihomo_ and _${IPK_SUFFIX}.ipk, then split
# off the LAST -<package release> (digits only). Everything before it is the
# Mihomo version — this keeps prerelease/build suffixes intact, e.g.
#   mihomo_1.19.31-1_<suffix>.ipk          -> 1.19.31        + release 1
#   mihomo_1.19.32-rc.1-1_<suffix>.ipk     -> 1.19.32-rc.1   + release 1
#   mihomo_1.19.32+test-build-2_<suffix>.ipk -> 1.19.32+test-build + release 2
ASSET_VER=${ASSET_NAME#mihomo_}
ASSET_VER=${ASSET_VER%_${IPK_SUFFIX}.ipk}

PACKAGE_RELEASE=""
AVAILABLE_VER=""
case "$ASSET_VER" in
  *-*)
    _rel=${ASSET_VER##*-}
    case "$_rel" in
      ''|*[!0-9]*) error "Cannot parse package release from asset name: $ASSET_NAME" ;;
      *)
        PACKAGE_RELEASE=$_rel
        AVAILABLE_VER=${ASSET_VER%-"$_rel"}
        ;;
    esac
    ;;
  *) error "Cannot parse package release from asset name: $ASSET_NAME" ;;
esac

[ -z "$AVAILABLE_VER" ] && error "Cannot parse version from asset name: $ASSET_NAME"

log "Available package: $ASSET_NAME"
log "Available Mihomo: $AVAILABLE_VER (package release: $PACKAGE_RELEASE)"

# -----------------------------
# 7. Decide the action: update / skip / never downgrade
# -----------------------------
# AVAILABLE is compared numerically with the installed binary (the updater's
# truth is `mihomo -v`, not the opkg database). AVAILABLE != CURRENT alone is
# never a reason to replace: older available versions — and versions that
# cannot be reliably ordered (prerelease/build suffixes) — are skipped with a
# warning, even with --force. A downgrade, if ever needed, is a separate
# manual task. Exact string equality short-circuits first, so devices on a
# prerelease are recognized as up to date when the same version is packaged.
# An unreadable current version is treated as a repair case.
if [ "$DEFER_VERSION_DECISION" -eq 1 ]; then
  log "Version decision deferred until after the controlled stop — the package is fetched so the comparison can be made safely."
elif [ -z "$CURRENT_VER" ]; then
  log "Current version unknown — attempting repair with the available package."
elif [ "$CURRENT_VER" = "$AVAILABLE_VER" ]; then
  if [ "$FORCE_UPDATE" -eq 0 ]; then
    log "Already up to date ($CURRENT_VER). Use --force to replace anyway."
    exit 0
  fi
  log "Same version ($CURRENT_VER) and --force given: replacing the binary anyway."
else
  _ver_rel=$(ver_compare "$AVAILABLE_VER" "$CURRENT_VER")
  if [ "$_ver_rel" = "gt" ]; then
    log "Update available: $CURRENT_VER -> $AVAILABLE_VER."
  elif [ "$_ver_rel" = "lt" ]; then
    warn "Available version ($AVAILABLE_VER) is older than the installed one ($CURRENT_VER). Automatic downgrade is not performed; binary left untouched."
    log "Nothing to do."
    exit 0
  else
    warn "Cannot reliably order versions ($AVAILABLE_VER vs $CURRENT_VER). Automatic downgrade protection: binary left untouched. Use install.sh for a manual switch."
    log "Nothing to do."
    exit 0
  fi
fi

# Remember whether Mihomo was running before the update
if command -v pidof >/dev/null 2>&1 && pidof mihomo >/dev/null 2>&1; then
  SERVICE_WAS_RUNNING=1
fi

# -----------------------------
# 8. Find init script (needed for the one-instance stop and the service steps)
# -----------------------------
INIT_SCRIPT=$(find /opt/etc/init.d -name '*mihomo*' -type f 2>/dev/null | head -1)

if [ -n "$INIT_SCRIPT" ]; then
  log "Found init script: $INIT_SCRIPT"
else
  log "WARNING: No init script found in /opt/etc/init.d"
fi

# -----------------------------
# 9. Download the package container to /tmp (tmpfs)
# -----------------------------
TMP_IPK="$TMP_DIR/mihomo-update.ipk"

# Remove stale artifacts from earlier runs / crashes (the exit trap cleans
# every normal path; this also covers kill -9 leftovers)
rm -f "$TMP_DIR"/mihomo-update.ipk "$TMP_DIR"/mihomo.backup.* 2>/dev/null || true
rm -rf "$TMP_DIR"/mihomo-ipk.* 2>/dev/null || true

log "Downloading: $ASSET_NAME"

retry curl -fsSL "$DOWNLOAD_URL" -o "$TMP_IPK" || error "Failed to download $ASSET_NAME — installed Mihomo untouched"

[ -s "$TMP_IPK" ] || error "Downloaded package is empty — installed Mihomo untouched"

# -----------------------------
# 10. Extract the new binary from the package container. Pure file
# operation: nothing executes the new ELF here, so the old Mihomo keeps
# running through this step and an extraction failure modifies nothing.
# -----------------------------
log "Pre-flight check: extracting the new binary from the package..."
WORK_DIR="$TMP_DIR/mihomo-ipk.$$"

if ! extract_new_binary_from_ipk "$TMP_IPK" "$WORK_DIR"; then
  preflight_fail "Pre-flight failed: cannot extract ./opt/bin/mihomo from $ASSET_NAME — installed Mihomo untouched"
fi

TMP_NEW="$EXTRACTED_BIN"
chmod +x "$TMP_NEW"

# -----------------------------
# 11. Check free space and clean old backups — static checks (wc/df only,
# no ELF execution), performed while the old Mihomo is still running so a
# space problem aborts without any downtime.
# -----------------------------
NEW_SIZE_BYTES=$(wc -c < "$TMP_NEW")
NEW_SIZE_KB=$(( (NEW_SIZE_BYTES + 1023) / 1024 ))
NEED_KB=$((NEW_SIZE_KB + 4096))  # 4 MB safety margin

# Size of the old binary that the replacement will free
OLD_SIZE_BYTES=0
if [ -f "$MIHOMO_PATH" ]; then
  OLD_SIZE_BYTES=$(wc -c < "$MIHOMO_PATH" 2>/dev/null || echo 0)
fi
OLD_SIZE_KB=$(( (OLD_SIZE_BYTES + 1023) / 1024 ))

get_avail_kb() {
  df -k "$MIHOMO_DIR" | awk 'NR==2 {print $4}'
}

# Remove stale backups in /opt to reclaim space
for bak in "$MIHOMO_PATH.backup" "$MIHOMO_PATH.old" "$MIHOMO_PATH.bak"; do
  if [ -f "$bak" ]; then
    log "Removing old backup: $bak"
    rm -f "$bak"
  fi
done

AVAIL_KB=$(get_avail_kb)
# Projected space includes the blocks we will get back after the old binary is freed
PROJECTED_KB=$(( AVAIL_KB + OLD_SIZE_KB ))

log "Free space on $MIHOMO_DIR: ${AVAIL_KB} KB"
log "Old binary size to be freed: ${OLD_SIZE_KB} KB"
log "New binary size: ${NEW_SIZE_KB} KB (need ~${NEED_KB} KB)"

# If projected space is still not enough, stop the service to release "ghost" blocks
if [ "$PROJECTED_KB" -lt "$NEED_KB" ]; then
  if [ -n "$INIT_SCRIPT" ] && [ "$SERVICE_WAS_RUNNING" -eq 1 ] && [ "$SERVICE_WAS_STOPPED" -eq 0 ]; then
    log "Low space. Stopping mihomo to free ghost disk blocks..."
    "$INIT_SCRIPT" stop >/dev/null 2>&1 || true
    SERVICE_WAS_STOPPED=1
    sleep 2
    AVAIL_KB=$(get_avail_kb)
    PROJECTED_KB=$(( AVAIL_KB + OLD_SIZE_KB ))
    log "Free space after stop: ${AVAIL_KB} KB (Projected: ${PROJECTED_KB} KB)"
  fi
fi

if [ "$PROJECTED_KB" -lt "$NEED_KB" ]; then
  # The old binary was never replaced, so a service this updater stopped
  # for the recheck must not stay down.
  restore_stopped_service
  error "Not enough free space on $MIHOMO_DIR (Projected: ${PROJECTED_KB} KB, Required: ${NEED_KB} KB). Free up space manually."
fi

# -----------------------------
# 12. Stop the old Mihomo BEFORE the first execution of the new binary.
#
# The packaged binary is UPX-packed: when executed, it unpacks itself in
# memory (tens of MB). Executing it alongside the running old instance
# crashes memory-starved devices with SIGSEGV, so at most ONE Mihomo may
# execute at any moment. Every check that does not require running the new
# ELF is already done; the intended short downtime starts here and ends
# when the service is started again (or the updater aborts and restores
# the previous state).
#
# The service state is re-probed: the daemon may have been started or may
# have died while the package was downloading and extracting (for example
# by a watchdog restart). A running Mihomo without an init script cannot
# be stopped — abort instead of risking a second instance. The stop is
# confirmed before anything executes the new binary.
# -----------------------------
if command -v pidof >/dev/null 2>&1 && pidof mihomo >/dev/null 2>&1; then
  SERVICE_WAS_RUNNING=1
fi

if [ "$SERVICE_WAS_RUNNING" -eq 1 ]; then
  if [ "$SERVICE_WAS_STOPPED" -eq 0 ]; then
    log "Stopping old Mihomo before running the new binary..."
  fi
  stop_mihomo_confirmed
fi

# -----------------------------
# 12b. Deferred installed-version decision (one-instance path). The old
# daemon is confirmed down (or was never running), so probing the
# installed binary is safe here. Same decision rules as the early
# comparison; every exit restores the service this updater stopped.
# -----------------------------
if [ "$DEFER_VERSION_DECISION" -eq 1 ]; then
  INSTALLED_VER=""
  if VERSION_OUTPUT=$("$MIHOMO_PATH" -v 2>/dev/null); then
    INSTALLED_VER=$(echo "$VERSION_OUTPUT" | head -1 | awk '{print $3}')
    INSTALLED_VER=${INSTALLED_VER#v}
  fi
  if [ -z "$INSTALLED_VER" ]; then
    log "Installed version still unreadable after the stop — proceeding with the repair update."
  elif [ "$INSTALLED_VER" = "$AVAILABLE_VER" ]; then
    if [ "$FORCE_UPDATE" -eq 0 ]; then
      if [ "$SERVICE_WAS_STOPPED" -eq 1 ]; then
        log "Already up to date ($INSTALLED_VER) — verified after the controlled stop."
      else
        log "Already up to date ($INSTALLED_VER) — verified without pidof; the service state could not be confirmed."
      fi
      restore_stopped_service
      exit 0
    fi
    log "Same version ($INSTALLED_VER) and --force given: replacing the binary anyway."
  else
    _ver_rel=$(ver_compare "$AVAILABLE_VER" "$INSTALLED_VER")
    if [ "$_ver_rel" = "gt" ]; then
      log "Update confirmed after the stop: $INSTALLED_VER -> $AVAILABLE_VER."
    elif [ "$_ver_rel" = "lt" ]; then
      warn "Available version ($AVAILABLE_VER) is older than the installed one ($INSTALLED_VER). Automatic downgrade is not performed; binary left untouched."
      restore_stopped_service
      log "Nothing to do."
      exit 0
    else
      warn "Cannot reliably order versions ($AVAILABLE_VER vs $INSTALLED_VER). Automatic downgrade protection: binary left untouched."
      restore_stopped_service
      log "Nothing to do."
      exit 0
    fi
  fi
fi

# -----------------------------
# 13. Runtime pre-flight: the new binary executes ONLY here, with the old
# instance confirmed stopped. Failure restores the service this updater
# stopped (a service that was already down stays down) and leaves the old
# binary in place.
# -----------------------------
PACKAGE_VER=$("$TMP_NEW" -v 2>/dev/null | head -1 | awk '{print $3}')
PACKAGE_VER=${PACKAGE_VER#v}
if [ "$PACKAGE_VER" != "$AVAILABLE_VER" ]; then
  preflight_fail "Pre-flight failed: package binary reports ${PACKAGE_VER:-unknown}, expected $AVAILABLE_VER (from $ASSET_NAME) — installed Mihomo untouched"
fi
log "Package binary version verified: $PACKAGE_VER"

if [ -d "/opt/etc/mihomo" ]; then
  log "Testing new version $AVAILABLE_VER with current config..."
  if ! "$TMP_NEW" -d /opt/etc/mihomo -t >/dev/null 2>&1; then
    preflight_fail "Config test failed: version $AVAILABLE_VER is incompatible with the current config.yaml. Update aborted, nothing was modified."
  fi
  log "Config test passed."
else
  log "WARNING: /opt/etc/mihomo not found, skipping config test."
fi

# -----------------------------
# 14. Backup the current binary to /tmp (RAM) as the recovery path
# -----------------------------
TMP_BACKUP="$TMP_DIR/mihomo.backup.$$"

if [ -f "$MIHOMO_PATH" ]; then
  log "Backing up current binary to $TMP_BACKUP ..."
  if ! cp -f "$MIHOMO_PATH" "$TMP_BACKUP"; then
    restore_stopped_service
    error "Failed to create backup in /tmp"
  fi
fi

# -----------------------------
# 15. Transactional binary replacement
#
# The cron watchdog restarts Mihomo whenever its port is unreachable — and
# it IS unreachable during the updater's downtime. If a watchdog restart
# slipped in after the stop above, re-stop it here: the binary is never
# replaced and never verified under a live Mihomo.
# -----------------------------
if [ "$SERVICE_WAS_RUNNING" -eq 1 ] && command -v pidof >/dev/null 2>&1 && pidof mihomo >/dev/null 2>&1; then
  log "Mihomo is running again (watchdog restart?) — stopping before replacement..."
  stop_mihomo_confirmed
fi
if [ -n "$INIT_SCRIPT" ] && [ "$SERVICE_WAS_STOPPED" -eq 0 ] && [ "$SERVICE_WAS_RUNNING" -eq 1 ]; then
  log "Stopping mihomo service..."
  "$INIT_SCRIPT" stop >/dev/null 2>&1 || true
  sleep 1
fi

# From here on the old binary is being destructively replaced: any INT/TERM
# must go through the Phase B rollback path (see signal_handler).
REPLACEMENT_STARTED=1
log "Replacing binary at $MIHOMO_PATH ..."
if ! rm -f "$MIHOMO_PATH"; then
  rollback_and_exit "Failed to remove old binary"
fi

if ! cp -f "$TMP_NEW" "$MIHOMO_PATH"; then
  rollback_and_exit "Failed to install new binary — rolled back to previous version"
fi

if ! chmod +x "$MIHOMO_PATH"; then
  rollback_and_exit "Failed to set executable permission"
fi

# -----------------------------
# 16. Verify the replaced binary (version + config) — rollback on any failure
# -----------------------------
log "Testing installed binary..."
if ! "$MIHOMO_PATH" -v >/dev/null 2>&1; then
  rollback_and_exit "New binary test failed — rolled back to previous version"
fi

INSTALLED_VER=$("$MIHOMO_PATH" -v 2>/dev/null | head -1 | awk '{print $3}')
INSTALLED_VER=${INSTALLED_VER#v}

if [ "$INSTALLED_VER" != "$AVAILABLE_VER" ]; then
  rollback_and_exit "Installed version mismatch: expected $AVAILABLE_VER, got ${INSTALLED_VER:-unknown}"
fi

log "Installed version verified: $INSTALLED_VER"

if [ -d "/opt/etc/mihomo" ]; then
  if ! "$MIHOMO_PATH" -d /opt/etc/mihomo -t >/dev/null 2>&1; then
    rollback_and_exit "Config test failed with the installed version — rolled back"
  fi
  log "Config test passed on the installed binary."
fi

# -----------------------------
# 17. Start service and verify process
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
# 18. Final process verification
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
# Done (temp cleanup runs via the exit trap)
# -----------------------------
log "Success! Updated to $AVAILABLE_VER (from $ASSET_NAME)"
echo "[OK] Mihomo updated successfully"
