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
#   curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/update-watchdog.sh | sh
#   or locally:
#   ./update-watchdog.sh
#
# Environment:
#   WATCHDOG_URL - override source URL (optional)
#   KEENETIC_AUTO_SETUP_REF - override project channel/ref (default: stable)
# =========================================================

PROJECT_REF="${KEENETIC_AUTO_SETUP_REF:-stable}"
PROJECT_RAW_BASE="https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/${PROJECT_REF}"
PROJECT_API_CONTENTS="https://api.github.com/repos/saymer-alt/keenetic-auto-setup/contents"

WATCHDOG_BIN="/opt/bin/mihomo_watchdog.sh"
WATCHDOG_CRON="/opt/etc/cron.5mins/mihomo_watchdog"
STAGE_FILE="/opt/bin/.mihomo_watchdog.sh.new.$$"
TMP_FILE="/tmp/mihomo-watchdog.sh.new.$$"
CRON_LEGACY_BAK="/opt/etc/mihomo_watchdog.legacy.bak"
CRON_LEGACY_BAK_OLD="/opt/etc/cron.5mins/mihomo_watchdog.legacy.bak"
CRONTAB_FILE="/opt/etc/crontab"
CRON_DIRECT='*/5 * * * * root /bin/sh /opt/etc/cron.5mins/mihomo_watchdog'
URL="${WATCHDOG_URL:-$PROJECT_RAW_BASE/mihomo-watchdog.sh}"

# Terminal status colors are presentation only. Semantic prefixes remain the
# source of truth; redirects/log captures stay plain and NO_COLOR/TERM=dumb
# disable ANSI output.
COLOR_RESET=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_RED=""
COLOR_CYAN=""
COLOR_ERR_RESET=""
COLOR_ERR_RED=""

if [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    if [ -t 1 ] 2>/dev/null; then
        COLOR_RESET=$(printf '\033[0m')
        COLOR_GREEN=$(printf '\033[1;32m')
        COLOR_YELLOW=$(printf '\033[1;33m')
        COLOR_RED=$(printf '\033[1;31m')
        COLOR_CYAN=$(printf '\033[1;36m')
    fi
    if [ -t 2 ] 2>/dev/null; then
        COLOR_ERR_RESET=$(printf '\033[0m')
        COLOR_ERR_RED=$(printf '\033[1;31m')
    fi
fi

status_out() { printf '%s%s%s\n' "$1" "$2" "$COLOR_RESET"; }
status_err() { printf '%s%s%s\n' "$COLOR_ERR_RED" "$1" "$COLOR_ERR_RESET" >&2; }


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
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    status_out "$COLOR_RED" "[ERROR] curl or wget is required but neither is available"
    exit 1
fi

download_watchdog_candidate() {
    _dw_url="$1"
    _dw_api="$PROJECT_API_CONTENTS/mihomo-watchdog.sh?ref=$PROJECT_REF"

    rm -f "$TMP_FILE" 2>/dev/null || true

    if command -v curl >/dev/null 2>&1; then
        for _dw_try in 1 2 3; do
            rm -f "$TMP_FILE" 2>/dev/null || true
            if curl -fSsL "$_dw_url" -o "$TMP_FILE"; then
                return 0
            fi
            rm -f "$TMP_FILE" 2>/dev/null || true
            status_out "$COLOR_YELLOW" "[WARN] curl download attempt $_dw_try/3 failed"
            sleep 2
        done
    fi

    if command -v wget >/dev/null 2>&1; then
        status_out "$COLOR_CYAN" "[INFO] Trying wget fallback..."
        for _dw_try in 1 2 3; do
            rm -f "$TMP_FILE" 2>/dev/null || true
            if wget -qO "$TMP_FILE" "$_dw_url"; then
                return 0
            fi
            rm -f "$TMP_FILE" 2>/dev/null || true
            status_out "$COLOR_YELLOW" "[WARN] wget download attempt $_dw_try/3 failed"
            sleep 2
        done
    fi

    # The API fallback is valid only for the normal project-managed source.
    # A caller-provided WATCHDOG_URL remains authoritative and is never
    # silently replaced with a different payload.
    if [ -z "${WATCHDOG_URL:-}" ] && command -v curl >/dev/null 2>&1; then
        status_out "$COLOR_CYAN" "[INFO] Trying GitHub Contents API fallback..."
        for _dw_try in 1 2 3; do
            rm -f "$TMP_FILE" 2>/dev/null || true
            if curl -fSsL \
                -H "Accept: application/vnd.github.raw+json" \
                -H "X-GitHub-Api-Version: 2022-11-28" \
                "$_dw_api" -o "$TMP_FILE"; then
                return 0
            fi
            rm -f "$TMP_FILE" 2>/dev/null || true
            status_out "$COLOR_YELLOW" "[WARN] GitHub API download attempt $_dw_try/3 failed"
            sleep 2
        done
    fi

    return 1
}

# --- OBJECT SANITY (fail conservatively, never write through anomalies) ---
if [ -e "$WATCHDOG_BIN" ] && [ ! -f "$WATCHDOG_BIN" ]; then
    status_out "$COLOR_YELLOW" "[WARN] $WATCHDOG_BIN exists but is not a regular file - refusing to touch it"
    status_out "$COLOR_YELLOW" "[WARN] Remove or fix it manually, then re-run this updater"
    exit 0
fi
if [ -e "$WATCHDOG_CRON" ] && [ ! -f "$WATCHDOG_CRON" ]; then
    status_out "$COLOR_YELLOW" "[WARN] $WATCHDOG_CRON exists but is not a regular file - refusing to touch it"
    status_out "$COLOR_YELLOW" "[WARN] Remove or fix it manually, then re-run this updater"
    exit 0
fi

# --- ABSENT ---
if [ ! -e "$WATCHDOG_BIN" ] && [ ! -f "$WATCHDOG_CRON" ]; then
    status_out "$COLOR_YELLOW" "[WARN] Watchdog not installed (no canonical binary and no cron copy), nothing changed"
    status_out "$COLOR_YELLOW" "[WARN] Run install.sh first"
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
        status_out "$COLOR_CYAN" "[INFO] Moved legacy watchdog backup out of cron.5mins"
    else
        chmod -x "$CRON_LEGACY_BAK_OLD" 2>/dev/null || true
        status_out "$COLOR_YELLOW" "[WARN] Could not move old watchdog backup out of cron.5mins; executable bit removed"
    fi
fi
rm -f /tmp/mihomo-watchdog.sh.new.* 2>/dev/null || true

# --- DOWNLOAD + VALIDATE (in RAM, before touching anything on /opt) ---
status_out "$COLOR_CYAN" "[INFO] Downloading watchdog..."
status_out "$COLOR_CYAN" "[INFO] Source: $URL"

if ! download_watchdog_candidate "$URL"; then
    status_out "$COLOR_RED" "[ERROR] Download failed through all available transports"
    exit 1
fi

if [ ! -s "$TMP_FILE" ]; then
    status_out "$COLOR_RED" "[ERROR] Downloaded file is empty"
    exit 1
fi

if ! grep -q "MIHOMO WATCHDOG SCRIPT" "$TMP_FILE"; then
    status_out "$COLOR_RED" "[ERROR] Sanity check failed: not a valid watchdog script"
    exit 1
fi

if ! sh -n "$TMP_FILE"; then
    status_out "$COLOR_RED" "[ERROR] Syntax check failed"
    exit 1
fi

# --- INSTALL / UPDATE the canonical binary (unless already current) ---
ALREADY_CURRENT=0
if [ -f "$WATCHDOG_BIN" ] && cmp -s "$TMP_FILE" "$WATCHDOG_BIN" 2>/dev/null; then
    ALREADY_CURRENT=1
    status_out "$COLOR_CYAN" "[INFO] Canonical watchdog is already current - no binary rewrite"
else
    mkdir -p /opt/bin
    # Same-filesystem stage: copy, re-validate on the target filesystem,
    # then commit with one atomic rename (old file intact on any failure).
    if ! cp -f "$TMP_FILE" "$STAGE_FILE"; then
        status_out "$COLOR_RED" "[ERROR] Failed to stage the new watchdog at $STAGE_FILE (ENOSPC or I/O error) - installed watchdog untouched"
        exit 1
    fi
    if ! grep -q "MIHOMO WATCHDOG SCRIPT" "$STAGE_FILE" 2>/dev/null; then
        status_out "$COLOR_RED" "[ERROR] Staged watchdog failed the sanity check - installed watchdog untouched"
        exit 1
    fi
    if ! sh -n "$STAGE_FILE"; then
        status_out "$COLOR_RED" "[ERROR] Staged watchdog failed the syntax check - installed watchdog untouched"
        exit 1
    fi
    chmod +x "$STAGE_FILE" || {
        status_out "$COLOR_RED" "[ERROR] Failed to set executable permission on the staged watchdog - installed watchdog untouched"
        exit 1
    }
    if ! mv -f "$STAGE_FILE" "$WATCHDOG_BIN"; then
        status_out "$COLOR_RED" "[ERROR] Failed to replace $WATCHDOG_BIN (atomic rename) - old watchdog intact"
        exit 1
    fi
    status_out "$COLOR_CYAN" "[INFO] Watchdog installed: $WATCHDOG_BIN"
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
    status_out "$COLOR_YELLOW" "[WARN] $WATCHDOG_CRON is a full watchdog but NOT a known managed version - preserved, nothing migrated"
    status_out "$COLOR_YELLOW" "[WARN] If it is a deliberate custom watchdog, keep it; otherwise migrate it manually"
else
    # missing or foreign content: only ever ADD our wrapper when the slot
    # is empty; a foreign file was already reported above and is kept
    if [ ! -f "$WATCHDOG_CRON" ]; then
        CRON_ACTION="create"
    else
        status_out "$COLOR_YELLOW" "[WARN] $WATCHDOG_CRON contains unrecognized content - preserved, nothing changed"
    fi
fi

case "$CRON_ACTION" in
    migrate)
        # One bounded backup of the replaced managed legacy copy
        # (overwritten on every migration, never accumulates).
        if cp -f "$WATCHDOG_CRON" "$CRON_LEGACY_BAK" 2>/dev/null; then
            chmod -x "$CRON_LEGACY_BAK" 2>/dev/null || true
            status_out "$COLOR_CYAN" "[INFO] Legacy watchdog copy backed up to $CRON_LEGACY_BAK"
        else
            status_out "$COLOR_YELLOW" "[WARN] Could not back up the legacy watchdog copy (migrating anyway)"
        fi
        wrapper_content > "$WATCHDOG_CRON" || { status_out "$COLOR_RED" "[ERROR] Failed to write wrapper at $WATCHDOG_CRON"; exit 1; }
        chmod +x "$WATCHDOG_CRON" 2>/dev/null || true
        status_out "$COLOR_CYAN" "[INFO] Managed legacy watchdog migrated: cron entry converted to wrapper"
        ;;
    create)
        mkdir -p /opt/etc/cron.5mins
        wrapper_content > "$WATCHDOG_CRON" || { status_out "$COLOR_RED" "[ERROR] Failed to write wrapper at $WATCHDOG_CRON"; exit 1; }
        chmod +x "$WATCHDOG_CRON" 2>/dev/null || true
        status_out "$COLOR_CYAN" "[INFO] Cron wrapper created: $WATCHDOG_CRON"
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
            && { status_out "$COLOR_CYAN" "[INFO] Removed duplicate watchdog cron line (run-parts route already covers cron.5mins)"; _cron_changed=1; }
        rm -f "$CRONTAB_FILE.tmp.$$" 2>/dev/null || true
    elif [ "${_direct_exact:-0}" -ge 2 ]; then
        grep -vFx "$CRON_DIRECT" "$CRONTAB_FILE" > "$CRONTAB_FILE.tmp.$$" 2>/dev/null
        echo "$CRON_DIRECT" >> "$CRONTAB_FILE.tmp.$$"
        mv -f "$CRONTAB_FILE.tmp.$$" "$CRONTAB_FILE" \
            && { status_out "$COLOR_CYAN" "[INFO] Collapsed duplicate watchdog cron lines to one"; _cron_changed=1; }
        rm -f "$CRONTAB_FILE.tmp.$$" 2>/dev/null || true
    elif [ "${_direct_exact:-0}" -eq 0 ] && [ "${_direct_var:-0}" -eq 0 ] && [ "${_runparts:-0}" -eq 0 ]; then
        echo "$CRON_DIRECT" >> "$CRONTAB_FILE" 2>/dev/null \
            && { status_out "$COLOR_CYAN" "[INFO] Watchdog cron line added to $CRONTAB_FILE"; _cron_changed=1; }
    fi
    if [ "${_direct_var:-0}" -gt 0 ]; then
        status_out "$COLOR_YELLOW" "[WARN] $CRONTAB_FILE has non-standard watchdog cron lines - preserved (possible duplicates, check manually)"
    fi
    if [ "$_cron_changed" -eq 1 ] && [ -x /opt/etc/init.d/S10cron ]; then
        /opt/etc/init.d/S10cron restart >/dev/null 2>&1 || status_out "$COLOR_YELLOW" "[WARN] Cron restart failed - schedule changes apply at next cron reload"
    fi
else
    status_out "$COLOR_YELLOW" "[WARN] No /opt/etc/crontab - watchdog schedule not verified"
fi

# --- RESULT ---
if has_marker "$WATCHDOG_BIN" && is_exact_wrapper; then
    if [ "$ALREADY_CURRENT" -eq 1 ] && [ "$CRON_ACTION" = "ok" ]; then
        status_out "$COLOR_GREEN" "[OK] Watchdog already current (canonical binary + cron wrapper) - no changes made"
    else
        status_out "$COLOR_GREEN" "[OK] Watchdog update complete (canonical binary + cron wrapper)"
    fi
else
    status_out "$COLOR_YELLOW" "[WARN] Layout incomplete after update:"
    has_marker "$WATCHDOG_BIN" || \
        status_out "$COLOR_YELLOW" "[WARN] - $WATCHDOG_BIN is not a valid watchdog"
    is_exact_wrapper || is_wrapperish || \
        status_out "$COLOR_YELLOW" "[WARN] - $WATCHDOG_CRON is missing or not a wrapper (cron may not run the watchdog)"
    status_out "$COLOR_YELLOW" "[WARN] Check $WATCHDOG_BIN and $WATCHDOG_CRON manually"
fi
exit 0
