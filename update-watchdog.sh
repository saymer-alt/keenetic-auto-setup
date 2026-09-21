#!/bin/sh

# =========================================================
# MIHOMO WATCHDOG UPDATER (transactional, layout-canonicalizing)
# ---------------------------------------------------------
# Keeps the canonical watchdog at /opt/bin/mihomo_watchdog.sh with the
# thin scheduler wrapper at /opt/etc/cron.5mins/mihomo_watchdog, and
# migrates the known historical managed layouts to it.
#
# Router states this updater recognizes and how it reacts:
#
#   already-current  canonical binary == downloaded source
#                    -> ZERO flash writes: no rewrite, no timestamp
#                       change, no backup, no cron restart; the cron
#                       layout and crontab schedule are still verified
#                       and only fixed when actually wrong
#   canonical        binary present, content differs
#                    -> update through a same-filesystem stage with an
#                       atomic rename commit
#   legacy (managed) one of the known historical managed watchdogs
#                       (identified by exact SHA-256, see
#                       LEGACY_HASHES) at the cron path and/or /opt/bin
#                    -> one-time migration: install/update the canonical
#                       binary, turn the cron file into the wrapper,
#                       keep ONE bounded backup of the replaced cron
#                       copy (overwrite, never accumulates)
#   unknown          unrecognized, user-modified or foreign files
#                    -> preserved and reported, never deleted
#   absent           neither the binary nor a known cron copy exists
#                    -> WARN, nothing changed (install.sh is installer)
#
# Transaction model (same principles as update-mihomo.sh):
#   - the candidate is downloaded to /tmp (RAM) and fully validated
#     BEFORE anything on /opt is touched;
#   - it is staged at /opt/bin/.mihomo_watchdog.sh.new.$$ (SAME
#     filesystem as the target), re-validated there, and committed with
#     a single atomic rename; the canonical file never passes through a
#     missing or partially copied state; a cross-filesystem /tmp -> /opt
#     move is never used and never claimed atomic;
#   - orphaned stages of crashed earlier runs (this updater's exclusive
#     `.mihomo_watchdog.sh.new.` namespace, plus the /tmp stage of the
#     previous cross-filesystem updater generation) are removed at the
#     start; nothing else is ever deleted;
#   - no backups are kept for the canonical binary itself: it is small
#     and the same content always remains available at the source URL.
#
# Cron schedule normalization: exactly one route runs the watchdog
# (a cron.5mins run-parts line, or the single managed direct line).
# Duplicate managed direct lines are collapsed to one; a direct line is
# removed only when a cron.5mins run-parts line also exists; crontab
# lines that do not exactly match the managed direct line are preserved.
#
# The installer installs and recognizes; the updater updates and
# migrates. Re-running against an already-canonical router is a no-op.
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
STAGE_FILE="/opt/bin/.mihomo_watchdog.sh.new.$$"
TMP_FILE="/tmp/mihomo-watchdog.sh.new.$$"
CRON_LEGACY_BAK="/opt/etc/mihomo_watchdog.legacy.bak"
CRON_LEGACY_BAK_OLD="/opt/etc/cron.5mins/mihomo_watchdog.legacy.bak"
CRONTAB_FILE="/opt/etc/crontab"
CRON_DIRECT='*/5 * * * * root /bin/sh /opt/etc/cron.5mins/mihomo_watchdog'
URL="${WATCHDOG_URL:-https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo-watchdog.sh}"

# Known MANAGED legacy watchdog bodies. The pre-canonicalization
# installers downloaded the watchdog straight into the cron file, so the
# deployed copies are byte-identical to these historical blobs. Identity
# is exact SHA-256: anything else is by definition not positively
# identified, is preserved and reported instead of migrated or deleted.
#   a660e19... 152-line generation (May 2026)
#   7c8b6969 / 39c5a07f / a37fbd88 / 122d17d8  268-line generations
#   (Aug 2026; the last one deployed until the Sep 2026 canonicalization)
LEGACY_HASHES="a660e191909664b79f3d6d5fa0211ea85ad5609ab20e090e7309ee89d122d9ff 7c8b6969fd4474e355d51801d6379d06281525140e74c8ca2d85e02dca5a8715 39c5a07ff74d9bc922678e06ecb7def97c0c5ab66641b2d41aedba741b9fbee6 a37fbd888bb6b7149922c3603b1fc26f6478e3e5c88f91945f31f0552c7c163a 122d17d8fa40cc9d6a4c1879094cdcf299c5e6e5a4e00c83a8bb807a7749bd80"

# --- CLEANUP / SIGNALS ---
cleanup() {
    rm -f "$STAGE_FILE" "$TMP_FILE" 2>/dev/null || true
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

file_hash() {
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

is_known_legacy() { # $1 = file -> 0 when positively identified managed legacy
    [ -f "$1" ] || return 1
    command -v sha256sum >/dev/null 2>&1 || return 1
    _lh=$(file_hash "$1")
    [ -n "$_lh" ] || return 1
    for _k in $LEGACY_HASHES; do
        [ "$_lh" = "$_k" ] && return 0
    done
    return 1
}

has_marker() {
    [ -f "$1" ] && grep -q "MIHOMO WATCHDOG SCRIPT" "$1" 2>/dev/null
}

wrapper_content() {
    printf '#!/bin/sh\nexec /opt/bin/mihomo_watchdog.sh "$@"\n'
}

is_exact_wrapper() {
    [ -f "$WATCHDOG_CRON" ] || return 1
    [ "$(cat "$WATCHDOG_CRON" 2>/dev/null)" = "$(wrapper_content)" ]
}

is_wrapperish() { # our managed wrapper with drift (references the binary)
    [ -f "$WATCHDOG_CRON" ] \
        && grep -q "^exec /opt/bin/mihomo_watchdog.sh" "$WATCHDOG_CRON" 2>/dev/null
}

# --- DEPENDENCIES ---
if ! command -v curl >/dev/null 2>&1; then
    echo "[ERROR] curl is required but not found"
    exit 1
fi

# --- OBJECT SANITY (fail conservatively, never write through anomalies) ---
if [ -e "$WATCHDOG_BIN" ] && [ ! -f "$WATCHDOG_BIN" ]; then
    echo "[WARN] $WATCHDOG_BIN exists but is not a regular file - refusing to touch it"
    echo "[WARN] Remove or fix it manually, then re-run this updater"
    exit 0
fi
if [ -e "$WATCHDOG_CRON" ] && [ ! -f "$WATCHDOG_CRON" ]; then
    echo "[WARN] $WATCHDOG_CRON exists but is not a regular file - refusing to touch it"
    echo "[WARN] Remove or fix it manually, then re-run this updater"
    exit 0
fi

# --- ABSENT ---
if [ ! -e "$WATCHDOG_BIN" ] && [ ! -f "$WATCHDOG_CRON" ]; then
    echo "[WARN] Watchdog not installed (no canonical binary and no cron copy), nothing changed"
    echo "[WARN] Run install.sh first"
    exit 0
fi

# --- ORPHANED STAGES of crashed earlier runs (exclusive namespaces) ---
rm -f /opt/bin/.mihomo_watchdog.sh.new.* 2>/dev/null || true

# Older updater generations stored the bounded legacy backup inside cron.5mins.
# On BusyBox/run-parts an executable backup there can be scheduled as a second
# watchdog. Move it out of the cron directory and make the backup non-executable.
if [ -f "$CRON_LEGACY_BAK_OLD" ]; then
    if cp -f "$CRON_LEGACY_BAK_OLD" "$CRON_LEGACY_BAK" 2>/dev/null; then
        chmod -x "$CRON_LEGACY_BAK" 2>/dev/null || true
        rm -f "$CRON_LEGACY_BAK_OLD" 2>/dev/null || true
        echo "[INFO] Moved legacy watchdog backup out of cron.5mins"
    else
        chmod -x "$CRON_LEGACY_BAK_OLD" 2>/dev/null || true
        echo "[WARN] Could not move old watchdog backup out of cron.5mins; executable bit removed"
    fi
fi
rm -f /tmp/mihomo-watchdog.sh.new.* 2>/dev/null || true

# --- DOWNLOAD + VALIDATE (in RAM, before touching anything on /opt) ---
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

# --- INSTALL / UPDATE the canonical binary (unless already current) ---
ALREADY_CURRENT=0
if [ -f "$WATCHDOG_BIN" ] && cmp -s "$TMP_FILE" "$WATCHDOG_BIN" 2>/dev/null; then
    ALREADY_CURRENT=1
    echo "[INFO] Canonical watchdog is already current - no binary rewrite"
else
    mkdir -p /opt/bin
    # Same-filesystem stage: copy, re-validate on the target filesystem,
    # then commit with one atomic rename (old file intact on any failure).
    if ! cp -f "$TMP_FILE" "$STAGE_FILE"; then
        echo "[ERROR] Failed to stage the new watchdog at $STAGE_FILE (ENOSPC or I/O error) - installed watchdog untouched"
        exit 1
    fi
    if ! grep -q "MIHOMO WATCHDOG SCRIPT" "$STAGE_FILE" 2>/dev/null; then
        echo "[ERROR] Staged watchdog failed the sanity check - installed watchdog untouched"
        exit 1
    fi
    if ! sh -n "$STAGE_FILE"; then
        echo "[ERROR] Staged watchdog failed the syntax check - installed watchdog untouched"
        exit 1
    fi
    chmod +x "$STAGE_FILE" || {
        echo "[ERROR] Failed to set executable permission on the staged watchdog - installed watchdog untouched"
        exit 1
    }
    if ! mv -f "$STAGE_FILE" "$WATCHDOG_BIN"; then
        echo "[ERROR] Failed to replace $WATCHDOG_BIN (atomic rename) - old watchdog intact"
        exit 1
    fi
    echo "[INFO] Watchdog installed: $WATCHDOG_BIN"
fi

# --- CRON LAYOUT CANONICALIZATION ---
CRON_ACTION="none"
if is_exact_wrapper || is_wrapperish; then
    # Exact wrapper, or our managed wrapper with local drift: both work
    # and are left untouched (a working wrapper is never rewritten).
    CRON_ACTION="ok"
elif is_known_legacy "$WATCHDOG_CRON"; then
    CRON_ACTION="migrate"
elif has_marker "$WATCHDOG_CRON"; then
    echo "[WARN] $WATCHDOG_CRON is a full watchdog but NOT a known managed version - preserved, nothing migrated"
    echo "[WARN] If it is a deliberate custom watchdog, keep it; otherwise migrate it manually"
else
    # missing or foreign content: only ever ADD our wrapper when the slot
    # is empty; a foreign file was already reported above and is kept
    if [ ! -f "$WATCHDOG_CRON" ]; then
        CRON_ACTION="create"
    else
        echo "[WARN] $WATCHDOG_CRON contains unrecognized content - preserved, nothing changed"
    fi
fi

case "$CRON_ACTION" in
    migrate)
        # One bounded backup of the replaced managed legacy copy
        # (overwritten on every migration, never accumulates).
        if cp -f "$WATCHDOG_CRON" "$CRON_LEGACY_BAK" 2>/dev/null; then
            chmod -x "$CRON_LEGACY_BAK" 2>/dev/null || true
            echo "[INFO] Legacy watchdog copy backed up to $CRON_LEGACY_BAK"
        else
            echo "[WARN] Could not back up the legacy watchdog copy (migrating anyway)"
        fi
        wrapper_content > "$WATCHDOG_CRON" || { echo "[ERROR] Failed to write wrapper at $WATCHDOG_CRON"; exit 1; }
        chmod +x "$WATCHDOG_CRON" 2>/dev/null || true
        echo "[INFO] Managed legacy watchdog migrated: cron entry converted to wrapper"
        ;;
    create)
        mkdir -p /opt/etc/cron.5mins
        wrapper_content > "$WATCHDOG_CRON" || { echo "[ERROR] Failed to write wrapper at $WATCHDOG_CRON"; exit 1; }
        chmod +x "$WATCHDOG_CRON" 2>/dev/null || true
        echo "[INFO] Cron wrapper created: $WATCHDOG_CRON"
        ;;
esac

# --- CRON SCHEDULE NORMALIZATION (duplicate prevention) ---
# Only the exact managed direct line is ever removed or collapsed; any
# other crontab line mentioning the watchdog is preserved and reported.
if [ -f "$CRONTAB_FILE" ]; then
    _runparts=$(grep "cron.5mins" "$CRONTAB_FILE" 2>/dev/null | grep -vc "mihomo_watchdog" || true)
    _direct_exact=$(grep -cFx "$CRON_DIRECT" "$CRONTAB_FILE" 2>/dev/null || true)
    # grep -c prints "0" AND exits 1 on no match: guard the value, never
    # chain `|| echo 0` into the substitution (it would yield two lines).
    _dc=$(grep -c "mihomo_watchdog" "$CRONTAB_FILE" 2>/dev/null)
    case "$_dc" in ''|*[!0-9]*) _dc=0 ;; esac
    _direct_var=$(( _dc - _direct_exact ))
    _cron_changed=0
    case "${_runparts:-0}" in
        ''|*[!0-9]*) _runparts=0 ;;
    esac
    case "${_direct_exact:-0}" in
        ''|*[!0-9]*) _direct_exact=0 ;;
    esac
    case "${_direct_var:-0}" in
        ''|*[!0-9]*) _direct_var=0 ;;
    esac
    # grep -v exits 1 when every line matched (empty result) - its status
    # is deliberately not part of the commit condition below.
    if [ "${_runparts:-0}" -gt 0 ] && [ "${_direct_exact:-0}" -gt 0 ]; then
        # A cron.5mins run-parts route exists: the managed direct line
        # would execute the watchdog a second time every 5 minutes.
        grep -vFx "$CRON_DIRECT" "$CRONTAB_FILE" > "$CRONTAB_FILE.tmp.$$" 2>/dev/null
        mv -f "$CRONTAB_FILE.tmp.$$" "$CRONTAB_FILE" \
            && { echo "[INFO] Removed duplicate watchdog cron line (run-parts route already covers cron.5mins)"; _cron_changed=1; }
        rm -f "$CRONTAB_FILE.tmp.$$" 2>/dev/null || true
    elif [ "${_direct_exact:-0}" -ge 2 ]; then
        grep -vFx "$CRON_DIRECT" "$CRONTAB_FILE" > "$CRONTAB_FILE.tmp.$$" 2>/dev/null
        echo "$CRON_DIRECT" >> "$CRONTAB_FILE.tmp.$$"
        mv -f "$CRONTAB_FILE.tmp.$$" "$CRONTAB_FILE" \
            && { echo "[INFO] Collapsed duplicate watchdog cron lines to one"; _cron_changed=1; }
        rm -f "$CRONTAB_FILE.tmp.$$" 2>/dev/null || true
    elif [ "${_direct_exact:-0}" -eq 0 ] && [ "${_direct_var:-0}" -eq 0 ] && [ "${_runparts:-0}" -eq 0 ]; then
        echo "$CRON_DIRECT" >> "$CRONTAB_FILE" 2>/dev/null \
            && { echo "[INFO] Watchdog cron line added to $CRONTAB_FILE"; _cron_changed=1; }
    fi
    if [ "${_direct_var:-0}" -gt 0 ]; then
        echo "[WARN] $CRONTAB_FILE has non-standard watchdog cron lines - preserved (possible duplicates, check manually)"
    fi
    if [ "$_cron_changed" -eq 1 ] && [ -x /opt/etc/init.d/S10cron ]; then
        /opt/etc/init.d/S10cron restart >/dev/null 2>&1 || echo "[WARN] Cron restart failed - schedule changes apply at next cron reload"
    fi
else
    echo "[WARN] No /opt/etc/crontab - watchdog schedule not verified"
fi

# --- RESULT ---
if has_marker "$WATCHDOG_BIN" && is_exact_wrapper; then
    if [ "$ALREADY_CURRENT" -eq 1 ] && [ "$CRON_ACTION" = "ok" ]; then
        echo "[OK] Watchdog already current (canonical binary + cron wrapper) - no changes made"
    else
        echo "[OK] Watchdog update complete (canonical binary + cron wrapper)"
    fi
else
    echo "[WARN] Layout incomplete after update:"
    has_marker "$WATCHDOG_BIN" || \
        echo "[WARN] - $WATCHDOG_BIN is not a valid watchdog"
    is_exact_wrapper || is_wrapperish || \
        echo "[WARN] - $WATCHDOG_CRON is missing or not a wrapper (cron may not run the watchdog)"
    echo "[WARN] Check $WATCHDOG_BIN and $WATCHDOG_CRON manually"
fi
exit 0
