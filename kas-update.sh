#!/bin/sh

# kas-update.sh v0.1.0
#
# KAS CORE UPDATER — единая точка входа обслуживания установленного KAS Core
# (issue #390, MVP "Фаза B": одна команда --check / --apply поверх
# существующего транзакционного update-watchdog.sh).
#
# Что проверяет (--check, строго read-only):
#   - фактическое состояние установленных KAS-managed файлов:
#     canonical watchdog /opt/bin/mihomo_watchdog.sh и его cron wrapper
#     /opt/etc/cron.5mins/mihomo_watchdog;
#   - доступную версию watchdog на канале (KEENETIC_AUTO_SETUP_REF, по
#     умолчанию stable) по фактическому SHA-256. Версий у script-installed
#     KAS Core на устройстве нет — идентификация только по содержимому,
#     фиктивные номера не выводятся;
#   - информационный инвентарь остальных компонентов (Mihomo binary,
#     MagiTrickle, netfilter hook, S00ubifs, ownership ledger) БЕЗ изменений;
#   - состояние общего lifecycle lock (advisory);
#   - недоступные для достоверного определения состояния — UNKNOWN,
#     догадками не подменяются.
#
# Что делает (--apply, явное действие):
#   - повторно оценивает состояние, печатает план и (интерактивно)
#     запрашивает подтверждение; без TTY требуется --yes;
#   - скачивает с канала штатный update-watchdog.sh, проверяет его
#     (маркер, sh -n) и запускает его для транзакции. ВСЯ логика замены,
#     backup, atomic rename и cron-нормализации остаётся в существующем
#     updater'е — kas-update её не копирует;
#   - после применения проверяет фактический SHA-256 установленного
#     watchdog и сообщает результат. Повторный запуск идемпотентен:
#     уже актуальное состояние не переписывается (zero flash writes).
#
# kas-update НИКОГДА (в любой режим):
#   - не трогает Mihomo binary, config.yaml, MagiTrickle и его настройки,
#     netfilter, политики маршрутизации, WAN/VPN, Entware-пакеты;
#   - не создаёт второй watchdog, дубли cron или новые службы;
#   - не устанавливает ничего сверх уже установленного KAS
#     (первичная установка — bootstrap.sh/install.sh, не kas-update);
#   - не обновляет KAS Web (отдельный lifecycle) и не использует
#     GitHub "latest": источник — только выбранный ref проекта.
#   - при UNKNOWN/чужом/изменённом файле отказывается от применения,
#     ничего не переписывая.
#
# Использование:
#   sh kas-update.sh --check          # read-only: состояние + план
#   sh kas-update.sh --apply [--yes]  # явное применение (watchdog)
#   sh kas-update.sh --help
#
# Канал: KEENETIC_AUTO_SETUP_REF (по умолчанию stable). Для старых
# установок без локального kas-update первоначальный запуск — через GitHub:
#   curl -fSsL -o /tmp/kas-update.sh \
#     https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/kas-update.sh \
#     && sh -n /tmp/kas-update.sh && sh /tmp/kas-update.sh --check
#
# Коды выхода:
#   --check: 0 = состояние распознано и актуально (или watchdog не
#                установлен — это INFO, установка отдельная операция);
#            1 = доступны обновления/исправления (есть план);
#            2 = UNKNOWN/ошибка среды (достоверно определить не удалось).
#   --apply: 0 = применено успешно либо обновлять нечего;
#            1 = отказ или ошибка (система не изменена, либо её
#                восстановлением занимался транзакционный updater).
#   прочее:  2 = ошибка использования.
#
# Отношение к IPK (issue #295): kas-update — интерфейс обслуживания.
# Будущий kas-core.ipk станет способом доставки; CLI сохраняется как
# фронтенд (проверка/активация через bundle). См.
# docs/kas-core-ipk-plan-20261030.md.

set -u

PROG_NAME="kas-update.sh"
KAS_UPDATE_VERSION="0.1.0"
REPO="saymer-alt/keenetic-auto-setup"

PROJECT_REF="${KEENETIC_AUTO_SETUP_REF:-stable}"
case "$PROJECT_REF" in
    ''|*[!A-Za-z0-9._/-]*)
        printf '%s[ERROR]%s invalid KEENETIC_AUTO_SETUP_REF value\n' "[ERROR]" "" >&2
        exit 2
        ;;
esac
RAW_BASE="https://raw.githubusercontent.com/$REPO/$PROJECT_REF"
API_BASE="https://api.github.com/repos/$REPO/contents"

CANDIDATE_SCRIPT="mihomo-watchdog.sh"
UPDATER_SCRIPT="update-watchdog.sh"
CANDIDATE_URL="$RAW_BASE/$CANDIDATE_SCRIPT"
UPDATER_URL="$RAW_BASE/$UPDATER_SCRIPT"
CANDIDATE_API="$API_BASE/$CANDIDATE_SCRIPT?ref=$PROJECT_REF"
UPDATER_API="$API_BASE/$UPDATER_SCRIPT?ref=$PROJECT_REF"
SELF_URL="$RAW_BASE/$PROG_NAME"
SELF_API="$API_BASE/$PROG_NAME?ref=$PROJECT_REF"

# Paths mirror the managed files owned by install.sh / update-watchdog.sh.
WATCHDOG_BIN="/opt/bin/mihomo_watchdog.sh"
WATCHDOG_CRON="/opt/etc/cron.5mins/mihomo_watchdog"
CRON_LEGACY_BAK="/opt/etc/mihomo_watchdog.legacy.bak"
CRON_LEGACY_BAK_OLD="/opt/etc/cron.5mins/mihomo_watchdog.legacy.bak"
CRONTAB_FILE="/opt/etc/crontab"
MIHOMO_STATE="/opt/etc/keenetic-auto-setup-mihomo.state"
OWNERSHIP_LEDGER="/opt/etc/keenetic-auto-setup/ownership.v1"
NETFILTER_HOOK="/opt/etc/ndm/netfilter.d/020-bypass_wa.sh"
S00UBIFS_SERVICE="/opt/etc/init.d/S00ubifs"

# Read-only diagnostic boundaries (reported, never modified here).
MIHOMO_CONFIG="/opt/etc/mihomo/config.yaml"

WORK_DIR="/tmp/kas-update.$$"

MODE=""
ASSUME_YES=0
HASH_TOOL=""

# Terminal status colors are presentation only (docs/18). Semantic prefixes
# remain the source of truth; NO_COLOR/TERM=dumb and non-TTY keep it plain.
COLOR_RESET=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_RED=""
COLOR_CYAN=""
if [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    if [ -t 1 ] 2>/dev/null; then
        COLOR_RESET=$(printf '\033[0m')
        COLOR_GREEN=$(printf '\033[1;32m')
        COLOR_YELLOW=$(printf '\033[1;33m')
        COLOR_RED=$(printf '\033[1;31m')
        COLOR_CYAN=$(printf '\033[1;36m')
    fi
fi

ok_out() { printf '%s[OK]%s %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$1"; }
info_out() { printf '%s[INFO]%s %s\n' "$COLOR_CYAN" "$COLOR_RESET" "$1"; }
warn_out() { printf '%s[WARN]%s %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$1"; }
unknown_out() { printf '%s[UNKNOWN]%s %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$1"; }
err_out() { printf '%s[ERROR]%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$1" >&2; }

cleanup() {
    rm -rf "$WORK_DIR" 2>/dev/null || true
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

file_hash() { # sha256 of $1, empty on any failure
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

has_hash_tool() {
    [ -n "$HASH_TOOL" ] && return 0
    if command -v sha256sum >/dev/null 2>&1; then
        HASH_TOOL=1
        return 0
    fi
    return 1
}

# --- bounded read-only download chain -------------------------------------
# Same proven transport order as the project installers/updaters:
# raw curl (3 bounded attempts) -> curl IPv4+X25519 compatibility ->
# wget (3 bounded attempts) -> GitHub Contents API raw media.
# Per-attempt transport noise stays quiet; one WARN per exhausted
# transport, never a retry-count reduction.
fetch_url() { # $1 = url, $2 = contents-api url ("" = no api fallback), $3 = dest
    _fu_url="$1"
    _fu_api="$2"
    _fu_dest="$3"
    rm -f "$_fu_dest" 2>/dev/null || true
    if command -v curl >/dev/null 2>&1; then
        for _fu_try in 1 2 3; do
            rm -f "$_fu_dest" 2>/dev/null || true
            if curl -fSsL --connect-timeout 5 --max-time 20 "$_fu_url" -o "$_fu_dest" 2>/dev/null; then
                return 0
            fi
            rm -f "$_fu_dest" 2>/dev/null || true
            sleep 2
        done
        rm -f "$_fu_dest" 2>/dev/null || true
        if curl -fSsL --connect-timeout 5 --max-time 20 -4 --curves X25519 "$_fu_url" -o "$_fu_dest" 2>/dev/null; then
            return 0
        fi
        rm -f "$_fu_dest" 2>/dev/null || true
        warn_out "curl download failed after bounded retries; trying wget fallback"
    fi
    if command -v wget >/dev/null 2>&1; then
        for _fu_try in 1 2 3; do
            rm -f "$_fu_dest" 2>/dev/null || true
            if wget -qO "$_fu_dest" -T 20 "$_fu_url" 2>/dev/null; then
                return 0
            fi
            rm -f "$_fu_dest" 2>/dev/null || true
            sleep 2
        done
        if [ -n "$_fu_api" ] && command -v curl >/dev/null 2>&1; then
            warn_out "wget download failed after 3 attempts; trying GitHub Contents API fallback"
        else
            warn_out "download failed after bounded retries on all available transports"
        fi
    fi
    if [ -n "$_fu_api" ] && command -v curl >/dev/null 2>&1; then
        for _fu_try in 1 2 3; do
            rm -f "$_fu_dest" 2>/dev/null || true
            if curl -fSsL --connect-timeout 5 --max-time 20 \
                -H "Accept: application/vnd.github.raw+json" \
                -H "X-GitHub-Api-Version: 2022-11-28" \
                "$_fu_api" -o "$_fu_dest" 2>/dev/null; then
                return 0
            fi
            rm -f "$_fu_dest" 2>/dev/null || true
            sleep 2
        done
        rm -f "$_fu_dest" 2>/dev/null || true
        if curl -fSsL --connect-timeout 5 --max-time 20 -4 --curves X25519 \
            -H "Accept: application/vnd.github.raw+json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            "$_fu_api" -o "$_fu_dest" 2>/dev/null; then
            return 0
        fi
        rm -f "$_fu_dest" 2>/dev/null || true
    fi
    return 1
}

validate_shell_file() { # $1 = file, $2 = required marker
    [ -s "$1" ] || return 1
    grep -q "$2" "$1" 2>/dev/null || return 1
    sh -n "$1" 2>/dev/null || return 1
    return 0
}

# --- advisory lifecycle lock peek (report only; apply never trusts it) ----
# Mirrors the ownership identity of the shared lifecycle lock (pid +
# /proc starttime), but a wrong or unreadable answer may only become
# "unknown" in the report. Authorization always happens inside the
# transactional updater itself.
kas_lock_state() {
    KAS_LOCK_STATE="unknown"
    _kl_lock="/tmp/mihomo-lifecycle.lock.d"
    [ -d "$_kl_lock" ] && [ ! -L "$_kl_lock" ] || { KAS_LOCK_STATE="idle"; return 0; }
    _kl_owner="$_kl_lock/owner"
    [ -f "$_kl_owner" ] && [ ! -L "$_kl_owner" ] || return 0
    IFS=' ' read -r _kl_pid _kl_start _kl_extra < "$_kl_owner" || return 0
    case "$_kl_pid" in ''|*[!0-9]*) return 0 ;; esac
    case "$_kl_start" in ''|*[!0-9]*) return 0 ;; esac
    [ -z "${_kl_extra:-}" ] || return 0
    if [ -d "/proc/$_kl_pid" ]; then
        _kl_data=$(cat "/proc/$_kl_pid/stat" 2>/dev/null) || return 0
        _kl_tail=${_kl_data##*) }
        _kl_now=$(printf '%s\n' "$_kl_tail" | awk 'NF >= 20 && $20 ~ /^[0-9]+$/ { print $20; ok=1 } END { if (!ok) exit 1 }') || return 0
        if [ "$_kl_now" = "$_kl_start" ]; then
            KAS_LOCK_STATE="busy"
        else
            KAS_LOCK_STATE="idle"
        fi
    else
        # Stale lock of a dead owner; the updater recovers it under its guard.
        KAS_LOCK_STATE="idle"
    fi
    return 0
}

# --- installed watchdog pair classification -------------------------------
wrapper_content() {
    printf '#!/bin/sh\nexec %s "$@"\n' "$WATCHDOG_BIN"
}

is_exact_wrapper() {
    [ -f "$WATCHDOG_CRON" ] || return 1
    [ "$(cat "$WATCHDOG_CRON" 2>/dev/null)" = "$(wrapper_content)" ]
}

is_wrapperish() { # managed wrapper with local drift; it works and is kept
    [ -f "$WATCHDOG_CRON" ] \
        && grep -q "^exec $WATCHDOG_BIN" "$WATCHDOG_CRON" 2>/dev/null
}

has_watchdog_marker() {
    [ -f "$1" ] && grep -q "MIHOMO WATCHDOG SCRIPT" "$1" 2>/dev/null
}

# Managed-path anomaly: symlink or non-regular. The updater refuses these;
# kas-update refuses to plan anything for them.
managed_path_anomaly() {
    [ -e "$1" ] || [ -L "$1" ] || return 1
    [ -f "$1" ] && [ ! -L "$1" ] || return 0
    return 1
}

# --- assessment ------------------------------------------------------------
# Sets globals consumed by both modes:
#   W_HASH            sha256 of the installed canonical watchdog ("" if none)
#   W_STATE           absent | current | update | unknown
#   W_REASON          human explanation for unknown
#   AVAIL_HASH        sha256 of the channel candidate ("" if unavailable)
#   AVAIL_STATE       ok | unavailable | invalid
#   WRAPPER_STATE     exact | wrapperish | missing | foreign | anomaly
#   PLAN_BINARY / PLAN_WRAPPER   0/1
#   MANAGED_UNKNOWN   0/1 (watchdog pair unknown -> --apply must refuse)
#   CANDIDATE_FILE    local copy of the channel candidate (for post-verify)
assess_watchdog() {
    W_HASH=""
    W_STATE="unknown"
    W_REASON=""
    AVAIL_HASH=""
    AVAIL_STATE="unavailable"
    WRAPPER_STATE="unknown"
    PLAN_BINARY=0
    PLAN_WRAPPER=0
    MANAGED_UNKNOWN=1
    CANDIDATE_FILE="$WORK_DIR/candidate.sh"

    if ! has_hash_tool; then
        W_REASON="sha256sum is not available; installed watchdog cannot be identified"
        return 0
    fi

    if managed_path_anomaly "$WATCHDOG_BIN"; then
        W_STATE="anomaly"
        W_REASON="$WATCHDOG_BIN is a symlink or not a regular file; refusing to touch it"
        return 0
    fi
    if [ -e "$WATCHDOG_CRON" ] || [ -L "$WATCHDOG_CRON" ]; then
        if managed_path_anomaly "$WATCHDOG_CRON"; then
            W_STATE="anomaly"
            W_REASON="$WATCHDOG_CRON is a symlink or not a regular file; refusing to touch it"
            return 0
        fi
    fi

    if [ -f "$WATCHDOG_BIN" ]; then
        W_HASH=$(file_hash "$WATCHDOG_BIN")
        [ -n "$W_HASH" ] || { W_REASON="cannot hash $WATCHDOG_BIN"; return 0; }
        if ! has_watchdog_marker "$WATCHDOG_BIN"; then
            W_STATE="foreign"
            W_REASON="installed watchdog has no KAS sanity marker; it is preserved as user content"
            return 0
        fi
    fi

    # Wrapper classification (report + plan only).
    if [ ! -e "$WATCHDOG_CRON" ] && [ ! -L "$WATCHDOG_CRON" ]; then
        WRAPPER_STATE="missing"
    elif is_exact_wrapper; then
        WRAPPER_STATE="exact"
    elif is_wrapperish; then
        WRAPPER_STATE="wrapperish"
    elif has_watchdog_marker "$WATCHDOG_CRON"; then
        WRAPPER_STATE="foreign"
    else
        WRAPPER_STATE="foreign"
    fi

    # Channel candidate: bounded download to RAM, validated before use.
    if fetch_url "$CANDIDATE_URL" "$CANDIDATE_API" "$CANDIDATE_FILE" \
        && validate_shell_file "$CANDIDATE_FILE" "MIHOMO WATCHDOG SCRIPT"; then
        AVAIL_HASH=$(file_hash "$CANDIDATE_FILE")
        if [ -n "$AVAIL_HASH" ]; then
            AVAIL_STATE="ok"
        else
            AVAIL_STATE="unavailable"
        fi
    else
        AVAIL_STATE="invalid"
    fi

    if [ ! -f "$WATCHDOG_BIN" ]; then
        # Absent canonical binary. An empty slot is NOT an update target:
        # primary installation belongs to bootstrap.sh/install.sh. A file at
        # the cron path alone is a legacy layout the transactional updater
        # recognizes (exact known bodies migrate; unknown ones are preserved).
        W_STATE="absent"
        W_REASON="watchdog is not installed; primary installation is bootstrap.sh/install.sh"
        if [ "$AVAIL_STATE" = "ok" ] \
            && [ "$WRAPPER_STATE" != "missing" ] && [ "$WRAPPER_STATE" != "unknown" ]; then
            PLAN_WRAPPER=1
        fi
    elif [ "$AVAIL_STATE" = "ok" ]; then
        if [ "$W_HASH" = "$AVAIL_HASH" ]; then
            W_STATE="current"
        else
            W_STATE="update"
            PLAN_BINARY=1
        fi
    else
        # Installed content is recognized, but the channel version could not
        # be verified this run: no conclusions, no apply.
        W_STATE="unknown"
        W_REASON="available watchdog version could not be verified (download or validation failed)"
        return 0
    fi

    # A missing wrapper next to a recognized canonical binary is a real
    # repair target (the updater creates it in the empty slot). Without the
    # canonical binary an empty slot is NOT a kas-update task.
    if [ "$W_STATE" = "current" ] || [ "$W_STATE" = "update" ]; then
        if [ "$WRAPPER_STATE" = "missing" ]; then
            PLAN_WRAPPER=1
        fi
    fi

    MANAGED_UNKNOWN=0
    [ "$W_STATE" != "unknown" ] || MANAGED_UNKNOWN=1
    [ "$W_STATE" != "anomaly" ] || MANAGED_UNKNOWN=1
    [ "$W_STATE" != "foreign" ] || MANAGED_UNKNOWN=1
    return 0
}

print_watchdog_state() {
    if [ -f "$WATCHDOG_BIN" ]; then
        if [ -n "$W_HASH" ]; then
            info_out "installed watchdog SHA-256: $W_HASH"
        fi
        if [ "$AVAIL_STATE" = "ok" ]; then
            info_out "available SHA-256 ($PROJECT_REF): $AVAIL_HASH"
        elif [ "$AVAIL_STATE" = "invalid" ]; then
            unknown_out "available watchdog on $PROJECT_REF failed validation; nothing is compared against it"
        else
            unknown_out "available watchdog version could not be fetched from $PROJECT_REF"
        fi
        case "$W_STATE" in
            current) ok_out "watchdog: already current (content-identical to $PROJECT_REF)" ;;
            update) warn_out "watchdog: update available (installed content differs from $PROJECT_REF)" ;;
            absent) info_out "watchdog: not installed as the canonical binary" ;;
            foreign) unknown_out "watchdog: $W_REASON" ;;
            anomaly) unknown_out "watchdog: $W_REASON" ;;
            *) unknown_out "watchdog: $W_REASON" ;;
        esac
    else
        info_out "canonical watchdog $WATCHDOG_BIN is not installed"
        info_out "primary installation is bootstrap.sh/install.sh; kas-update does not install KAS"
        case "$WRAPPER_STATE" in
            missing) info_out "cron wrapper slot is empty; nothing is scheduled" ;;
            anomaly) unknown_out "cron wrapper is a symlink or not a regular file" ;;
            *) warn_out "a file exists at the cron wrapper path while the canonical watchdog is missing; the updater can migrate a recognized legacy layout or will preserve unknown content" ;;
        esac
    fi
    case "$WRAPPER_STATE" in
        exact) info_out "cron wrapper: exact managed wrapper" ;;
        wrapperish) info_out "cron wrapper: managed wrapper with local drift (works; the updater keeps it)" ;;
        missing) warn_out "cron wrapper missing: $WATCHDOG_CRON (apply lets the updater create it)" ;;
        foreign) warn_out "cron wrapper content is unrecognized; it is preserved, never deleted" ;;
        anomaly) unknown_out "cron wrapper is a symlink or not a regular file" ;;
        *) unknown_out "cron wrapper state could not be determined" ;;
    esac
    if [ -f "$CRON_LEGACY_BAK" ] || [ -f "$CRON_LEGACY_BAK_OLD" ]; then
        info_out "legacy watchdog backup present (bounded, owned by the updater)"
    fi
}

print_component_inventory() {
    if [ -f "$MIHOMO_STATE" ] && [ ! -L "$MIHOMO_STATE" ]; then
        _mi_ver=$(sed -n 's/^runtime_version=//p' "$MIHOMO_STATE" 2>/dev/null | head -n 1)
        if [ -n "$_mi_ver" ]; then
            info_out "Mihomo binary (project state): version $_mi_ver"
        else
            unknown_out "Mihomo project state is present but its version cannot be read"
        fi
    else
        info_out "Mihomo binary (project state): no project state record found"
    fi
    info_out "Mihomo updates are a separate explicit operation: update-mihomo.sh (not run by kas-update)"
    if command -v opkg >/dev/null 2>&1; then
        _mt_ver=$(opkg list-installed 2>/dev/null | awk '$1 == "magitrickle" { print $2; exit }')
        if [ -n "$_mt_ver" ]; then
            info_out "MagiTrickle (opkg): $_mt_ver; updates: opkg install magitrickle (explicit, not run by kas-update)"
        else
            info_out "MagiTrickle: not found in the opkg package list"
        fi
    else
        info_out "opkg not available; MagiTrickle version not checked"
    fi
    if [ -e "$NETFILTER_HOOK" ]; then
        info_out "netfilter hook present: $NETFILTER_HOOK (never modified by kas-update; refreshed by install.sh)"
    fi
    if [ -e "$S00UBIFS_SERVICE" ]; then
        info_out "S00ubifs service present (never modified by kas-update; refreshed by install.sh)"
    fi
    if [ -f "$OWNERSHIP_LEDGER" ]; then
        info_out "ownership ledger present: $OWNERSHIP_LEDGER"
    fi
    if [ -f "$MIHOMO_CONFIG" ]; then
        info_out "user config present: $MIHOMO_CONFIG (never modified by kas-update)"
    fi
    info_out "doctor/config-import run from GitHub on each invocation; they keep no installed copy to update"
}

print_plan() {
    info_out "apply plan:"
    if [ "$PLAN_BINARY" -eq 1 ]; then
        info_out "  - update canonical watchdog to the $PROJECT_REF version (transactional update-watchdog.sh: validation, backup hygiene, atomic rename)"
    fi
    if [ "$PLAN_WRAPPER" -eq 1 ]; then
        info_out "  - let update-watchdog.sh handle the cron wrapper layout (create a missing wrapper in an empty slot, or migrate a recognized legacy layout; foreign content is preserved and reported)"
    fi
    if [ "$PLAN_BINARY" -eq 0 ] && [ "$PLAN_WRAPPER" -eq 0 ]; then
        info_out "  - nothing to change"
    fi
    info_out "  - never touched: Mihomo binary, $MIHOMO_CONFIG, MagiTrickle, netfilter, routing policies, WAN/VPN, Entware packages, KAS Web"
}

usage() {
    cat <<EOF
$PROG_NAME $KAS_UPDATE_VERSION - unified KAS Core maintenance entry point (issue #390)

Usage:
  sh $PROG_NAME --check          read-only state + plan
  sh $PROG_NAME --apply [--yes]  explicit apply (canonical watchdog, via the
                                 transactional $UPDATER_SCRIPT)

Channel: KEENETIC_AUTO_SETUP_REF (default: stable).
Exit codes: see the script header. --check never changes the system.
EOF
}

self_check() { # advisory: is the running kas-update copy current on the channel?
    SELF_STATE="unknown"
    [ -f "$0" ] && [ ! -L "$0" ] || { info_out "kas-update self-check: running copy is not a readable file; skipped"; return 0; }
    has_hash_tool || { info_out "kas-update self-check: skipped (no sha256sum)"; return 0; }
    _sc_local=$(file_hash "$0")
    [ -n "$_sc_local" ] || { info_out "kas-update self-check: skipped (cannot hash the running copy)"; return 0; }
    _sc_remote="$WORK_DIR/kas-update.selfcheck.sh"
    if fetch_url "$SELF_URL" "$SELF_API" "$_sc_remote" \
        && validate_shell_file "$_sc_remote" "KAS CORE UPDATER"; then
        _sc_avail=$(file_hash "$_sc_remote")
        if [ -n "$_sc_avail" ] && [ "$_sc_avail" = "$_sc_local" ]; then
            SELF_STATE="current"
            info_out "kas-update $KAS_UPDATE_VERSION: running copy matches $PROJECT_REF"
        else
            SELF_STATE="stale"
            info_out "kas-update: a different version exists on $PROJECT_REF; re-fetch the script from GitHub"
        fi
    else
        info_out "kas-update self-check: channel copy unavailable; skipped"
    fi
    return 0
}

do_check() {
    kas_lock_state
    info_out "kas-update $KAS_UPDATE_VERSION - read-only check (channel: $PROJECT_REF)"
    case "$KAS_LOCK_STATE" in
        busy) warn_out "lifecycle lock is BUSY: another maintenance operation is running; its result may change under this report" ;;
        unknown) info_out "lifecycle lock: state unknown (advisory only)" ;;
        *) info_out "lifecycle lock: idle" ;;
    esac
    assess_watchdog
    print_watchdog_state
    print_component_inventory
    self_check
    if [ "$MANAGED_UNKNOWN" -eq 1 ]; then
        unknown_out "check result: UNKNOWN - apply is refused until the state above is resolved"
        return 2
    fi
    if [ "$PLAN_BINARY" -eq 1 ] || [ "$PLAN_WRAPPER" -eq 1 ]; then
        print_plan
        return 1
    fi
    ok_out "check result: KAS Core watchdog is current; nothing to apply"
    return 0
}

confirm_apply() {
    [ "$ASSUME_YES" -eq 1 ] && return 0
    if [ -t 0 ] 2>/dev/null; then
        printf 'Apply the watchdog update now? [y/N] '
        IFS= read -r _ca_answer || return 1
        case "$_ca_answer" in
            y|Y|yes|YES|Yes) return 0 ;;
            *) return 1 ;;
        esac
    fi
    err_out "apply requires an interactive confirmation; re-run with --yes for non-interactive use"
    return 1
}

do_apply() {
    [ "$(id -u)" -eq 0 ] || { err_out "apply must run as root (the transactional updater requires it)"; return 1; }
    has_hash_tool || { err_out "sha256sum is not available; cannot verify the update"; return 1; }

    kas_lock_state
    case "$KAS_LOCK_STATE" in
        busy) err_out "lifecycle lock is busy: another maintenance operation is running; wait for it to finish"; return 1 ;;
    esac

    assess_watchdog
    if [ "$MANAGED_UNKNOWN" -eq 1 ]; then
        err_out "refusing to apply: managed watchdog state is not safely recognizable:"
        [ -n "$W_REASON" ] && err_out "  - $W_REASON"
        [ "$WRAPPER_STATE" = "anomaly" ] && err_out "  - cron wrapper is a symlink or not a regular file"
        err_out "nothing was changed. Resolve the state above, then re-run --check"
        return 1
    fi

    if [ "$PLAN_BINARY" -eq 0 ] && [ "$PLAN_WRAPPER" -eq 0 ]; then
        ok_out "watchdog is already current; nothing to apply (no files rewritten)"
        return 0
    fi

    print_watchdog_state
    print_plan
    confirm_apply || { warn_out "apply cancelled; nothing was changed"; return 1; }

    # Stage the channel updater and delegate the whole transaction to it.
    # kas-update never reimplements replacement/backup/atomic-rename logic.
    UPDATER_FILE="$WORK_DIR/update-watchdog.sh"
    info_out "fetching the transactional updater from $PROJECT_REF..."
    if ! fetch_url "$UPDATER_URL" "$UPDATER_API" "$UPDATER_FILE" \
        || ! validate_shell_file "$UPDATER_FILE" "MIHOMO WATCHDOG UPDATER"; then
        err_out "the $UPDATER_SCRIPT from $PROJECT_REF failed validation; nothing was changed"
        return 1
    fi

    info_out "running update-watchdog.sh (it acquires the lifecycle lock and performs the transactional update)..."
    # The ref alone determines the updater's source URL (full transport chain
    # including the Contents API fallback); overriding WATCHDOG_URL would
    # silently disable that fallback, so it is deliberately not passed.
    if KEENETIC_AUTO_SETUP_REF="$PROJECT_REF" \
        sh "$UPDATER_FILE"; then
        _da_now=$(file_hash "$WATCHDOG_BIN")
        if [ -n "$_da_now" ] && [ "$_da_now" = "$AVAIL_HASH" ]; then
            ok_out "apply verified: installed watchdog SHA-256 matches the assessed $PROJECT_REF version"
        elif [ -n "$_da_now" ]; then
            warn_out "apply finished, but the installed SHA-256 differs from the assessed version:"
            warn_out "  assessed: ${AVAIL_HASH:-unavailable}; installed: $_da_now"
            warn_out "the updater validated what it installed; re-run --check to re-assess"
        else
            warn_out "apply finished, but the installed watchdog could not be hashed; re-run --check"
        fi
        return 0
    fi
    err_out "watchdog updater reported a failure; its own transaction keeps the previous watchdog or restores it"
    # Report facts, not assumptions: re-assess read-only and show what the
    # system looks like now (a non-zero updater exit may also mean a
    # deliberately preserved foreign cron layout next to an updated binary).
    if assess_watchdog && [ "$AVAIL_STATE" = "ok" ]; then
        print_watchdog_state
    fi
    err_out "review the updater output above; re-run kas-update --check afterwards"
    return 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --check)
            [ -z "$MODE" ] || { err_out "--check and --apply are mutually exclusive"; exit 2; }
            MODE=check
            ;;
        --apply)
            [ -z "$MODE" ] || { err_out "--check and --apply are mutually exclusive"; exit 2; }
            MODE=apply
            ;;
        --yes)
            ASSUME_YES=1
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            err_out "unknown argument: $1"
            usage
            exit 2
            ;;
    esac
    shift
done

if [ -z "$MODE" ]; then
    usage
    exit 2
fi

umask 077
if ! mkdir -m 700 "$WORK_DIR" 2>/dev/null; then
    err_out "cannot create the private working directory $WORK_DIR"
    exit 2
fi

if [ "$MODE" = check ]; then
    do_check
    exit $?
fi
do_apply
exit $?
