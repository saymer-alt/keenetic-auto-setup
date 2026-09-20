#!/bin/sh

set -e

echo "=== Keenetic Auto Setup ==="

MODE="${1:-ram}"

if [ "$MODE" != "ram" ] && [ "$MODE" != "disk" ]; then
    echo "Usage: sh install.sh [ram|disk]"
    exit 1
fi

echo "[*] Mode: $MODE"

TMP_DIR="/tmp"

log() { echo "[setup] $1"; }
warn() { echo "[WARN] $1"; }
err() { echo "[ERROR] $1"; exit 1; }

retry() {
    for i in 1 2 3; do
        "$@" && return 0
        warn "Retry $i/3 failed for: $*"
        sleep 2
    done
    return 1
}

# Cleanup temp files on any exit
WATCHDOG_STAGE="/opt/bin/.mihomo_watchdog.sh.new.$$"
# Cleanup temp files on any exit (the watchdog stage lives on /opt,
# next to its final destination - a /tmp -> /opt move is not atomic
# and must never be claimed as such)
trap 'rm -f "$TMP_DIR/mihomo.ipk" "$TMP_DIR/mihomo-watchdog.new" "$WATCHDOG_STAGE"' EXIT INT TERM HUP

# ---------------------------
# CHECK BASE
# ---------------------------
command -v opkg >/dev/null 2>&1 || err "opkg not found"

# ---------------------------
# RAM PREFLIGHT
# ---------------------------
# 256 MB+ is the supported/recommended profile. 128 MB-class devices are
# intentionally not blocked: they can work, but have very little headroom and
# are best-effort/experimental. Warn BEFORE downloads or package mutations.
MEM_TOTAL_KB=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)
case "$MEM_TOTAL_KB" in
    ''|*[!0-9]*)
        warn "Cannot determine total RAM from /proc/meminfo; continuing without the low-RAM preflight"
        ;;
    *)
        MEM_TOTAL_MB=$((MEM_TOTAL_KB / 1024))
        log "RAM: ${MEM_TOTAL_MB} MB total"
        if [ "$MEM_TOTAL_KB" -lt 250000 ]; then
            warn "============================================================"
            warn "LOW-RAM / BEST-EFFORT INSTALL: ${MEM_TOTAL_MB} MB detected"
            warn "256 MB+ is the supported and recommended project profile."
            warn "128 MB-class devices are allowed, but stability is NOT guaranteed."
            warn "Memory pressure can break Keenetic services, Mihomo or updates."
            if [ "$MODE" = "ram" ]; then
                warn "RAM mode also uses tmpfs; disk mode is safer on 128 MB-class devices."
            fi
            warn "Never run a second Mihomo process beside the daemon."
            warn "============================================================"
        fi
        ;;
esac

# ---------------------------
# OPKG UPDATE
# ---------------------------
log "Updating opkg..."
retry opkg update || err "opkg update failed"

# ---------------------------
# BASE PACKAGES (strict install)
# ---------------------------
log "Installing base packages..."

pkg_is_installed() {
    case "$1" in
        curl|jq|nano)
            command -v "$1" >/dev/null 2>&1
            ;;
        *)
            opkg list-installed 2>/dev/null | grep -q "^$1 "
            ;;
    esac
}

pkg_ensure() {
    _pkg="$1"
    if pkg_is_installed "$_pkg"; then
        log "$_pkg already installed"
        return 0
    fi
    log "Installing $_pkg..."
    opkg install "$_pkg" || err "Failed to install $_pkg"
}

pkg_ensure ca-bundle
pkg_ensure curl
pkg_ensure jq
pkg_ensure nano
pkg_ensure cron

command -v jq >/dev/null 2>&1 || err "jq not available after install"

# ---------------------------
# SYSTEM INFO
# ---------------------------
log "Router: $(ndmc -c "show version" 2>/dev/null | grep -Ei 'model|hw id' | head -1 || echo "unknown")"
log "Free space on /opt: $(df -h /opt 2>/dev/null | awk 'NR==2 {print $4}' || echo "unknown")"

# ---------------------------
# bypass_wa policy
# ---------------------------
log "Configuring bypass_wa..."

if ! ndmc -c "show ip policy" 2>/dev/null | grep -w -q "bypass_wa"; then
    ndmc -c "ip policy bypass_wa" >/dev/null 2>&1 || warn "Failed to create bypass_wa policy"
    ndmc -c "ip policy bypass_wa description bypass_wa" >/dev/null 2>&1
fi

# ---------------------------
# DNS TRANSIT INTERCEPTION
# ---------------------------
# Clients' classic (port 53) DNS must go through Keenetic's DNS proxy so
# MagiTrickle sees every query and can classify routes. Enabling transit
# interception redirects queries addressed straight to external resolvers
# into the system DNS profile instead of letting them bypass the router.
# This is not a DoH/DoT protection: encrypted DNS is not affected.
log "Configuring DNS transit interception..."

if ndmc -c "show running-config" 2>/dev/null | grep -q "intercept enable"; then
    log "DNS transit interception already enabled, skipping"
else
    if ! ndmc -c "dns-proxy intercept enable" >/dev/null 2>&1; then
        err "Failed to enable required DNS transit interception"
    fi
    ndmc -c "system configuration save" >/dev/null 2>&1 || warn "Failed to save DNS transit interception immediately"
    # Critical persistent mutation: do not continue a long install after a
    # command that appeared to succeed but did not take effect.
    if ! ndmc -c "show running-config" 2>/dev/null | grep -q "intercept enable"; then
        err "DNS transit interception did not appear in running-config after enable; installation cannot satisfy the MagiTrickle DNS contract"
    fi
fi

# ---------------------------
# TMPFS
# ---------------------------
if [ "$MODE" = "ram" ]; then
    log "Installing S00ubifs..."

    if retry curl -fsSL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/S00ubifs \
        -o /opt/etc/init.d/S00ubifs; then

        chmod +x /opt/etc/init.d/S00ubifs
        /opt/etc/init.d/S00ubifs start || warn "S00ubifs start failed"
    else
        warn "S00ubifs download failed"
    fi
else
    log "Skip S00ubifs (disk mode)"
fi

# ---------------------------
# DETECT ARCH
# ---------------------------
ARCH=$(opkg print-architecture | awk '/^arch/ && $2~/^(mips|mipsel|aarch64|arm)/{
    sub(/[-_].*/,"",$2); print $2; exit
}')

[ -z "$ARCH" ] && err "Cannot detect architecture"

log "Arch: $ARCH"

# ---------------------------
# MIHOMO INSTALL
# ---------------------------
log "Installing Mihomo..."

REPO_OWNER="saymer-alt"
REPO_NAME="entware-go"

case "$ARCH" in
    aarch64*) IPK_SUFFIX="aarch64-3.10" ;;
    armv7*|arm*) IPK_SUFFIX="armv7-3.2" ;;
    mipsel*) IPK_SUFFIX="mipsel-3.4" ;;
    mips*) IPK_SUFFIX="mips-3.4" ;;
    *) err "Unsupported arch: $ARCH" ;;
esac

log "Looking for mihomo ipk (${IPK_SUFFIX}) in ${REPO_OWNER}/${REPO_NAME}..."

API_URL="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
ASSETS_JSON=$(retry curl -fsSL "$API_URL" 2>/dev/null) || ASSETS_JSON=""

DOWNLOAD_URL=""

# Primary: GitHub API + jq (без regex)
if [ -n "$ASSETS_JSON" ]; then
    DOWNLOAD_URL=$(echo "$ASSETS_JSON" | jq -r --arg suffix "$IPK_SUFFIX" '
        .assets[]? 
        | select(.name | startswith("mihomo_") and endswith("_" + $suffix + ".ipk")) 
        | .browser_download_url
    ' 2>/dev/null | head -n 1)
fi

# Fallback 1: grep/sed на API JSON
if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ]; then
    log "jq filter empty, trying grep fallback on API response..."
    if [ -n "$ASSETS_JSON" ]; then
        DOWNLOAD_URL=$(echo "$ASSETS_JSON" | grep -o '"browser_download_url": *"[^"]*mihomo_[^"]*_'${IPK_SUFFIX}'\.ipk"' | head -1 | sed 's/.*": *"//;s/"$//')
    fi
fi

# Fallback 2: повторный API fetch + grep (если первый был пустым)
if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ]; then
    log "API failed, trying direct API grep..."
    ASSETS_JSON=$(curl -fsSL "$API_URL" 2>/dev/null) || ASSETS_JSON=""
    if [ -n "$ASSETS_JSON" ]; then
        DOWNLOAD_URL=$(echo "$ASSETS_JSON" | grep -o '"browser_download_url": *"[^"]*mihomo_[^"]*_'${IPK_SUFFIX}'\.ipk"' | head -1 | sed 's/.*": *"//;s/"$//')
    fi
fi

# Fallback 3: HTML scraping
if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ]; then
    log "Trying HTML scraping..."
    HTML_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest"
    REL_PATH=$(curl -fsSL "$HTML_URL" 2>/dev/null | \
        grep -oE 'href="[^"]*releases/download/[^"]*mihomo_[^"]*_'${IPK_SUFFIX}'\.ipk"' | \
        head -n 1 | cut -d'"' -f2)
    if [ -n "$REL_PATH" ]; then
        DOWNLOAD_URL="https://github.com${REL_PATH}"
    fi
fi

# GitHub Releases (saymer-alt/entware-go) are the PRIMARY package source;
# the Entware feed install below is a LAST RESORT, not an equal alternative.
MIHOMO_INSTALLED=0

if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ]; then
    warn "No mihomo ipk found for arch suffix: ${IPK_SUFFIX}. Check https://github.com/${REPO_OWNER}/${REPO_NAME}/releases"
else
    log "Found: $(basename "$DOWNLOAD_URL")"
    log "Downloading..."
    if retry curl -fL "$DOWNLOAD_URL" -o "$TMP_DIR/mihomo.ipk"; then
        log "Installing package..."
        if opkg install "$TMP_DIR/mihomo.ipk"; then
            MIHOMO_INSTALLED=1
        else
            warn "Mihomo install from the downloaded GitHub package failed"
        fi
    else
        warn "Failed to download mihomo ipk"
    fi
fi

# Timely cleanup after the GitHub attempt (the EXIT trap is only a backstop):
# a failed attempt must not leave a partial ipk in /tmp.
rm -f "$TMP_DIR/mihomo.ipk"

# LAST RESORT: package `mihomo` from the configured Entware feed. Reached
# only after the whole GitHub path failed before a successful install; the
# feed version may be older than the GitHub release build.
if [ "$MIHOMO_INSTALLED" -eq 0 ]; then
    warn "GitHub Mihomo package unavailable, trying Entware feed fallback..."
    opkg install mihomo || err "Mihomo install failed: GitHub package unavailable and Entware feed fallback failed"
    log "Mihomo installed from Entware feed fallback (version may be older than the GitHub release build)"
fi

MIHOMO_BIN=$(command -v mihomo 2>/dev/null || echo "/opt/bin/mihomo")
log "Mihomo version: $(${MIHOMO_BIN} -v 2>/dev/null | head -1 || echo "unknown")"

# ---------------------------
# MIHOMO BOOTSTRAP CONFIG
# ---------------------------
# The mihomo ipk ships a placeholder config.yaml (a conffile). Package builds
# before the entware-go mixed-port fix declared only transparent-proxy ports
# (tproxy/redir) and no mixed-port: 7890 — the project contract port (Proxy0
# upstream, watchdog, self-check). Provide a project bootstrap instead:
#   - config.yaml missing -> create it;
#   - config.yaml still identical to the conffile md5 recorded by opkg at
#     package install time (untouched package placeholder) -> replace it;
#   - anything else is a user config -> never modified.
# Once replaced, the file differs from the recorded conffile md5, so future
# package upgrades preserve it exactly like a user config.
ensure_bootstrap_config() {
    _config="$1"

    mkdir -p "${_config%/*}" || err "Cannot create ${_config%/*} for required Mihomo bootstrap config"

    _replace=0
    if [ ! -f "$_config" ]; then
        _replace=1
    elif command -v md5sum >/dev/null 2>&1; then
        _pkg_md5=$(opkg status mihomo 2>/dev/null | awk -v cf="$_config" '$1 == cf {print $2}' | head -n 1)
        _file_md5=$(md5sum "$_config" 2>/dev/null | awk '{print $1}')
        if [ -n "$_pkg_md5" ] && [ "$_pkg_md5" = "$_file_md5" ]; then
            log "Untouched package placeholder detected, replacing with bootstrap"
            _replace=1
        fi
    fi

    if [ "$_replace" -eq 1 ]; then
        log "Writing bootstrap config (mixed-port 7890)..."
        cat > "$_config" <<'EOF' || err "Failed to write required Mihomo bootstrap config"
# Bootstrap config installed by keenetic-auto-setup.
# mixed-port 7890 is the project contract port (Proxy0, watchdog, self-check);
# until it listens, Proxy0 and the watchdog tunnel check stay down.
# Replace this file with your real Mihomo config (docs/HOWTO, or build one at
# https://github.com/saymer-alt/link-generators), then:
#   /opt/etc/init.d/S99mihomo restart
mixed-port: 7890
EOF
    else
        log "Existing Mihomo config left untouched"
    fi
}

ensure_bootstrap_config "/opt/etc/mihomo/config.yaml"

# ---------------------------
# PROJECT PROXY INTERFACE
# ---------------------------
# The project proxy is a Keenetic Proxy-class interface pointing at Mihomo's
# local SOCKS5 upstream (127.0.0.1:7890 — fixed project contract). It is
# identified by BOTH markers in running-config:
#   description "mihomo t2sN"      (N = interface number; project convention)
#   proxy upstream 127.0.0.1 7890
# A Proxy interface matching only one marker (or neither) is foreign and is
# never modified. Preference order: reuse an existing project ProxyN (lowest
# number first); otherwise create Proxy0 when absent; otherwise — Proxy0 is
# foreign — create the first free ProxyN and leave Proxy0 exactly as is.
# Every Proxy decision reads ONE validated running-config snapshot
# (load_rc_dump; positive control: a real running-config always contains at
# least one `interface ` block). A failed or unconvincing ndmc read is
# UNKNOWN: nothing is created or modified, and UNKNOWN is never treated as
# NOT_FOUND — a transient ndmc error must not turn an occupied slot into a
# "free" one.
MAX_PROXY_PROBE=32   # Protective scan cap ONLY: KeeneticOS documents no limit
                     # for Proxy instances; the cap bounds ndmc probing cost
                     # in a pathological setup and is not an OS maximum.

load_rc_dump() {
    # One validated running-config snapshot (RC_DUMP) for every Proxy
    # decision. Two bounded attempts (an inline loop rather than retry():
    # retry() prints its WARN to stdout, which would pollute the captured
    # dump). The positive control separates a trustworthy NOT_FOUND from
    # an ndmc failure (UNKNOWN). Returns 1 only for UNKNOWN.
    _attempt=0
    while [ "$_attempt" -lt 2 ]; do
        RC_DUMP=$(ndmc -c "show running-config" 2>/dev/null | tr -d '\r')
        if printf '%s\n' "$RC_DUMP" | grep -q '^interface '; then
            return 0
        fi
        _attempt=$((_attempt + 1))
        if [ "$_attempt" -lt 2 ]; then
            sleep 2
        fi
    done
    RC_DUMP=""
    return 1
}

proxy_state() {
    # Classifies one interface against RC_DUMP: sets PROXY_STATE to FOUND
    # or NOT_FOUND. Must only be called after a successful load_rc_dump;
    # always returns 0 (callers branch on $PROXY_STATE, keeping bare calls
    # set -e-safe).
    if printf '%s\n' "$RC_DUMP" | grep -qx "interface $1"; then
        PROXY_STATE="FOUND"
    else
        PROXY_STATE="NOT_FOUND"
    fi
    return 0
}

proxy_is_project() {
    # Ownership check against the validated RC_DUMP snapshot: BOTH project
    # markers must sit in the same interface block.
    printf '%s\n' "$RC_DUMP" | awk -v iface="$1" -v num="$2" '
        $0 == "interface " iface {pdesc=0; pup=0; inblk=1; next}
        inblk && /^!/ {if (pdesc && pup) found=1; inblk=0; next}
        inblk && $0 ~ "^ *description \"?mihomo t2s" num "\"? *$" {pdesc=1}
        inblk && /^ *proxy upstream 127\.0\.0\.1 7890 *$/ {pup=1}
        END {if (inblk && pdesc && pup) found=1; exit !found}
    '
}

create_project_proxy() {
    _iface="$1"
    _num="${_iface#Proxy}"
    # Every step is best-effort (the pre-function block relied on its
    # if-context for the same); the self-check reports any missed delivery.
    ndmc -c "interface ${_iface}" >/dev/null 2>&1 || true
    ndmc -c "interface ${_iface} proxy protocol socks5" >/dev/null 2>&1 || true
    ndmc -c "interface ${_iface} proxy socks5-udp" >/dev/null 2>&1 || true
    ndmc -c "interface ${_iface} proxy upstream 127.0.0.1 7890" >/dev/null 2>&1 || true
    ndmc -c "interface ${_iface} description \"mihomo t2s${_num}\"" >/dev/null 2>&1 || warn "Failed to set ${_iface} description"
    ndmc -c "interface ${_iface} ip global auto" >/dev/null 2>&1 || true
    ndmc -c "interface ${_iface} up" >/dev/null 2>&1 || true
    ndmc -c "system configuration save" >/dev/null 2>&1 || true
}

proxy_client_missing() {
    # The project Proxy interface did not take effect after an attempted
    # creation. On real hardware (Keenetic Hopper, 2026-09) this is the
    # signature of the KeeneticOS "Proxy client / Клиент прокси" component
    # being absent: without it the interface type itself does not exist.
    # Fail before any dependent mutation (bypass_wa binding, watchdog,
    # restart) and tell the operator exactly what to install. The installer
    # never installs KeeneticOS components itself.
    _pi="$1"
    echo "[ERROR] Не удалось создать проектный Proxy-интерфейс (${_pi}): он не появился в running-config после попытки создания." >&2
    echo "[ERROR] Наиболее вероятная причина: в KeeneticOS не установлен компонент «Клиент прокси» (Proxy client) — без него интерфейсы Proxy* не существуют. Этот компонент обязателен для проекта (ProxyN → Mihomo)." >&2
    echo "[ERROR] Установите компонент вручную: KeeneticOS → General system settings / Общие настройки системы → KeeneticOS update and components / Обновление и компоненты KeeneticOS → Change component set / Изменить набор компонентов → Proxy client / Клиент прокси." >&2
    echo "[ERROR] Установщик сам компоненты KeeneticOS не устанавливает. После установки компонента запустите установщик повторно." >&2
    exit 1
}

select_project_proxy() {
    PROXY_IFACE=""

    # The whole selection runs against one validated snapshot. If the
    # snapshot cannot be validated the Proxy state is UNKNOWN and nothing
    # is created or modified: empty PROXY_IFACE is the "no proxy" signal
    # for the callers, and the self-check reports the undetermined state.
    if ! load_rc_dump; then
        warn "Cannot validate running-config, Proxy state UNKNOWN — no Proxy created or modified"
        return 0
    fi

    # 1) Reuse an existing project proxy (lowest number first).
    _n=0
    while [ "$_n" -lt "$MAX_PROXY_PROBE" ]; do
        proxy_state "Proxy$_n"
        if [ "$PROXY_STATE" = "FOUND" ] && proxy_is_project "Proxy$_n" "$_n"; then
            PROXY_IFACE="Proxy$_n"
            log "Using existing project proxy ${PROXY_IFACE}"
            return 0
        fi
        _n=$((_n+1))
    done

    # 2) No project proxy exists: create Proxy0 when the slot is free.
    proxy_state "Proxy0"
    if [ "$PROXY_STATE" = "NOT_FOUND" ]; then
        log "Creating project proxy Proxy0..."
        create_project_proxy "Proxy0"
        PROXY_IFACE="Proxy0"
        # Refresh the snapshot and VERIFY the creation took effect: a
        # component-less KeeneticOS (no "Proxy client") silently rejects
        # every Proxy* write above, and the failure must not hide until the
        # self-check. On a reload failure the creation result is UNKNOWN:
        # nothing is bound or assumed, verification is left to the
        # self-check (safe direction, no mutation).
        if ! load_rc_dump; then
            warn "Cannot re-validate running-config after create - creation result UNKNOWN; verify the project proxy manually"
            return 0
        fi
        proxy_state "Proxy0"
        if [ "$PROXY_STATE" != "FOUND" ]; then
            proxy_client_missing "Proxy0"
        fi
        if ! proxy_is_project "Proxy0" "0"; then
            err "Proxy0 appeared in running-config but the required project profile (mihomo t2s0 / SOCKS5 upstream 127.0.0.1:7890) did not fully apply"
        fi
        log "Project proxy Proxy0 created and verified"
        return 0
    fi

    # 3) Proxy0 is foreign: leave it untouched, take the first free ProxyN.
    _n=1
    while [ "$_n" -lt "$MAX_PROXY_PROBE" ]; do
        proxy_state "Proxy$_n"
        if [ "$PROXY_STATE" = "NOT_FOUND" ]; then
            break
        fi
        _n=$((_n+1))
    done

    if [ "$_n" -ge "$MAX_PROXY_PROBE" ]; then
        warn "No free ProxyN within the ${MAX_PROXY_PROBE}-interface scan cap; existing proxy interfaces left untouched"
        # Empty PROXY_IFACE is the "no proxy" signal for the caller; the
        # function itself returns 0 so the bare top-level call stays
        # set -e-safe.
        return 0
    fi

    log "Proxy0 is not project-managed, creating project proxy Proxy${_n}..."
    create_project_proxy "Proxy${_n}"
    PROXY_IFACE="Proxy${_n}"
    # Same verification as in step 2: the new interface must be visible to
    # ensure_bypass_policy_exit, and its absence after the create is the
    # missing-Proxy-client signature (fail before the bypass_wa binding).
    if ! load_rc_dump; then
        warn "Cannot re-validate running-config after create - creation result UNKNOWN; verify the project proxy manually"
        return 0
    fi
    proxy_state "Proxy${_n}"
    if [ "$PROXY_STATE" != "FOUND" ]; then
        proxy_client_missing "Proxy${_n}"
    fi
    if ! proxy_is_project "Proxy${_n}" "$_n"; then
        err "Proxy${_n} appeared in running-config but the required project profile (mihomo t2s${_n} / SOCKS5 upstream 127.0.0.1:7890) did not fully apply"
    fi
    log "Project proxy Proxy${_n} created and verified"
}

select_project_proxy

# ---------------------------
# BYPASS_WA POLICY EXIT
# ---------------------------
# Keenetic routes traffic marked with a policy mark through the interfaces in
# that policy's permit list (permit global <iface>); an empty policy has no
# default route, so the VoIP bypass silently goes nowhere (docs/05). Add the
# selected project proxy (Proxy0 or a free ProxyN) to the bypass_wa permit
# list. Existing permits are never removed or reordered: if the policy
# already permits other interfaces (e.g. a VPN tunnel bound manually), they
# keep working and the route order remains the user's choice.
ensure_bypass_policy_exit() {
    _px="$1"

    if [ -z "$_px" ]; then
        warn "No project proxy selected, bypass_wa exit binding skipped"
        return 0
    fi
    _num="${_px#Proxy}"

    # Bind only a project-managed proxy interface. Both markers are checked
    # in the validated running-config snapshot: the upstream port is not
    # visible in "show interface". A foreign Proxy interface is never
    # modified and never used as the bypass_wa exit — the policy keeps
    # exactly the exits its owner configured.
    proxy_state "$_px"
    if [ "$PROXY_STATE" != "FOUND" ]; then
        warn "${_px} not available, bypass_wa exit binding skipped"
        return 0
    fi
    if ! proxy_is_project "$_px" "$_num"; then
        warn "Existing ${_px} does not match the project profile (mihomo t2s${_num} / 127.0.0.1:7890), bypass_wa exit binding skipped"
        return 0
    fi

    # Find the policy block by its description (the policy NAME may differ,
    # e.g. Policy0 when created via web UI). Prints the policy name when it
    # lacks the project permit, "BOUND" when the permit already exists, and
    # nothing when no bypass_wa policy exists. Read from the same validated
    # snapshot that approved the ownership check, so both decisions see the
    # same configuration state. Running-config nests policy directives, so
    # a plain grep would false-positive on other policies' permit lists;
    # block state is evaluated when each block closes, not at END.
    _pol_state=$(printf '%s\n' "$RC_DUMP" | awk -v px="$_px" '
        /^ip policy / {if (inblk && pdesc && !ppermit) target=pname; if (inblk && pdesc && ppermit) bound=1; pname=$3; pdesc=0; ppermit=0; inblk=1; next}
        inblk && /^ *description bypass_wa *$/ {pdesc=1}
        inblk && $0 ~ "^ *permit global " px " *$" {ppermit=1}
        /^!/ {if (inblk && pdesc) {if (!ppermit) target=pname; else bound=1} inblk=0}
        END {if (inblk && pdesc) {if (!ppermit) target=pname; else bound=1}; if (target != "") print target; else if (bound) print "BOUND"}
    ')

    case "$_pol_state" in
        "")    warn "bypass_wa policy not found, exit binding skipped" ; return 0 ;;
        BOUND) log "bypass_wa policy exit already set" ; return 0 ;;
    esac

    if ndmc -c "ip policy ${_pol_state} permit global ${_px}" >/dev/null 2>&1; then
        log "bypass_wa policy bound to ${_px} (mihomo t2s${_num})"
        ndmc -c "system configuration save" >/dev/null 2>&1 || warn "Failed to save configuration"
    else
        warn "Failed to bind bypass_wa policy to ${_px}"
    fi
}

ensure_bypass_policy_exit "$PROXY_IFACE"

# ---------------------------
# MAGITRICKLE
# ---------------------------
log "Installing MagiTrickle..."

curl -fsSL https://bin.magitrickle.dev/packages/add_repo.sh 2>/dev/null | sh || \
    wget -qO- https://bin.magitrickle.dev/packages/add_repo.sh | sh || \
    warn "MagiTrickle repo add failed"

opkg update || warn "opkg update after magitrickle failed"
pkg_ensure magitrickle || warn "MagiTrickle install failed"

if [ -x /opt/etc/init.d/S99magitrickle ]; then
    /opt/etc/init.d/S99magitrickle start || warn "MagiTrickle start failed"
fi

# ---------------------------
# BYPASS RULES
# ---------------------------
log "Installing bypass rules..."

mkdir -p /opt/etc/ndm/netfilter.d

if retry curl -fsSL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/020-bypass-wa.sh \
    -o /opt/etc/ndm/netfilter.d/020-bypass_wa.sh; then

    chmod +x /opt/etc/ndm/netfilter.d/020-bypass_wa.sh
else
    warn "bypass download failed"
fi

# ---------------------------
# WATCHDOG
# ---------------------------
# Layout: the canonical watchdog lives at /opt/bin/mihomo_watchdog.sh;
# /opt/etc/cron.5mins/mihomo_watchdog is only a thin scheduler wrapper
# (exec). The installer installs the new layout on a clean router,
# accepts an existing new layout, and never touches legacy or unknown
# installations — update-watchdog.sh migrates; the installer installs
# and recognizes.
log "Installing watchdog..."

WATCHDOG_BIN="/opt/bin/mihomo_watchdog.sh"
WATCHDOG_CRON="/opt/etc/cron.5mins/mihomo_watchdog"
WATCHDOG_URL="https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo-watchdog.sh"

watchdog_is_canonical() {
    [ -f "$1" ] && grep -q "MIHOMO WATCHDOG SCRIPT" "$1" 2>/dev/null
}

install_watchdog_bin() {
    mkdir -p /opt/bin || return 1
    if ! retry curl -fsSL "$WATCHDOG_URL" -o "$TMP_DIR/mihomo-watchdog.new"; then
        warn "Watchdog download failed"
        return 1
    fi
    # Same sanity gates as update-watchdog.sh: marker + syntax.
    if ! grep -q "MIHOMO WATCHDOG SCRIPT" "$TMP_DIR/mihomo-watchdog.new" || \
       ! sh -n "$TMP_DIR/mihomo-watchdog.new"; then
        warn "Watchdog sanity check failed, not installed"
        return 1
    fi
    # Same-filesystem staging: copy the validated candidate next to its
    # destination, then commit with one atomic rename. The canonical
    # watchdog never passes through a partially copied state; a crash
    # mid-copy leaves only this updater's stage file, which the next
    # install.sh or update-watchdog.sh run removes.
    if ! cp -f "$TMP_DIR/mihomo-watchdog.new" "$WATCHDOG_STAGE"; then
        warn "Failed to stage the new watchdog at $WATCHDOG_STAGE"
        return 1
    fi
    if ! mv -f "$WATCHDOG_STAGE" "$WATCHDOG_BIN"; then
        warn "Failed to install $WATCHDOG_BIN"
        return 1
    fi
    chmod +x "$WATCHDOG_BIN"
}

ensure_watchdog_cron() {
    mkdir -p /opt/etc/cron.5mins
    cat > "$WATCHDOG_CRON" <<'EOF' || { warn "Failed to write $WATCHDOG_CRON"; return 1; }
#!/bin/sh
exec /opt/bin/mihomo_watchdog.sh "$@"
EOF
    chmod +x "$WATCHDOG_CRON"

    mkdir -p /opt/var/log
    touch /opt/var/log/mihomo_watchdog.log
    chmod 666 /opt/var/log/mihomo_watchdog.log

    # Exactly one cron route: run-parts on cron.5mins when the crontab
    # already delegates it, otherwise one direct line (deduplicated).
    if grep -q "cron.5mins" /opt/etc/crontab 2>/dev/null; then
        log "Using run-parts"
    else
        log "Fallback to crontab"
        grep -q "mihomo_watchdog" /opt/etc/crontab 2>/dev/null || \
            echo "*/5 * * * * root /bin/sh /opt/etc/cron.5mins/mihomo_watchdog" >> /opt/etc/crontab
    fi

    /opt/etc/init.d/S10cron restart || warn "Cron restart failed"
}

if watchdog_is_canonical "$WATCHDOG_BIN"; then
    # Canonical binary present: accept the new layout, keep one cron route.
    # A wrapper is recognized by its exec line, so a full watchdog that
    # merely mentions the canonical path in its header is not mistaken
    # for one.
    if [ -f "$WATCHDOG_CRON" ] && ! grep -q "^exec $WATCHDOG_BIN" "$WATCHDOG_CRON" 2>/dev/null; then
        warn "Unknown file at $WATCHDOG_CRON, left unchanged"
    elif [ -f "$WATCHDOG_CRON" ]; then
        log "New watchdog layout already in place"
    else
        log "Canonical watchdog present, installing cron wrapper"
        ensure_watchdog_cron || warn "Watchdog cron wrapper installation failed"
    fi
elif watchdog_is_canonical "$WATCHDOG_CRON"; then
    # Old project layout (full watchdog in cron.5mins): not the installer's
    # job to migrate — the updater owns that transition.
    warn "Legacy watchdog installation detected."
    warn "Left unchanged."
    warn "Use update-watchdog.sh to migrate/update it safely."
elif [ -e "$WATCHDOG_BIN" ] || [ -e "$WATCHDOG_CRON" ]; then
    warn "Unrecognized watchdog installation, left unchanged"
else
    log "Installing canonical watchdog to $WATCHDOG_BIN"
    if install_watchdog_bin && ensure_watchdog_cron; then
        log "Watchdog installed (new layout)"
    else
        warn "Watchdog installation incomplete"
    fi
fi

# ---------------------------
# RESTART
# ---------------------------
if [ -x /opt/etc/init.d/S99mihomo ]; then
    /opt/etc/init.d/S99mihomo restart || warn "Mihomo restart failed"
else
    warn "S99mihomo not found, cannot restart"
fi

sleep 2

# ---------------------------
# POST-INSTALL SELF-CHECK
# ---------------------------
# Validates what this installer promises to install. install.sh leaves a
# bootstrap config.yaml (mixed-port 7890) in place unless a user config
# already exists. Missing config.yaml means bootstrap creation failed — WARN,
# not FAIL. Port 7890 is checked whenever a config exists: the bootstrap must
# listen on 7890, so a miss here means Mihomo is not running properly (or a
# user config does not define the contract port) — never a package
# placeholder, which install.sh replaces.
FAILS=0
WARNS=0

check_ok()   { echo "[ok] $1"; }
check_warn() { echo "[WARN] $1"; WARNS=$((WARNS+1)); }
check_fail() { echo "[FAIL] $1"; FAILS=$((FAILS+1)); }
check_info() { echo "[info] $1"; }

# One-Mihomo invariant: the self-check executes the Mihomo binary (-v/-t)
# ONLY when no daemon is running - a second execution is the documented
# SIGSEGV pattern on constrained hardware. Without pidof the state cannot
# be verified, so the probes are skipped conservatively (assumed running).
mihomo_running() {
    if command -v pidof >/dev/null 2>&1; then
        pidof mihomo >/dev/null 2>&1
    else
        return 0
    fi
}

CONFIG="/opt/etc/mihomo/config.yaml"

# Mihomo binary + version
if [ -x /opt/bin/mihomo ] || command -v mihomo >/dev/null 2>&1; then
    MIHOMO_BIN=$(command -v mihomo 2>/dev/null || echo "/opt/bin/mihomo")
    if mihomo_running; then
        check_info "Mihomo daemon is running - binary probe (-v) skipped (one-Mihomo invariant); the running daemon itself proves the binary executes"
    elif ${MIHOMO_BIN} -v >/dev/null 2>&1; then
        check_ok "Mihomo binary: $(${MIHOMO_BIN} -v 2>/dev/null | head -1)"
    else
        check_fail "Mihomo binary exists but 'mihomo -v' failed"
    fi
else
    check_fail "Mihomo binary not found (/opt/bin/mihomo)"
fi

# Mihomo init script
if [ -x /opt/etc/init.d/S99mihomo ]; then
    check_ok "Mihomo init script present"
else
    check_fail "Mihomo init script /opt/etc/init.d/S99mihomo missing"
fi

# Project proxy — Proxy0 or a free ProxyN when Proxy0 is foreign; both project
# markers are verified against a freshly validated running-config snapshot.
# An ndmc failure here is UNKNOWN: reported as FAIL, never misread as an
# absent or non-project proxy.
if [ -z "$PROXY_IFACE" ]; then
    check_fail "No project proxy (ndmc read failed during selection, or no free ProxyN with foreign Proxy0)"
elif ! load_rc_dump; then
    check_fail "Proxy state cannot be determined (running-config read failed)"
else
    proxy_state "$PROXY_IFACE"
    if [ "$PROXY_STATE" = "FOUND" ] && proxy_is_project "$PROXY_IFACE" "${PROXY_IFACE#Proxy}"; then
        check_ok "Project proxy ${PROXY_IFACE}: mihomo t2s${PROXY_IFACE#Proxy} -> 127.0.0.1:7890"
    else
        check_fail "Project proxy ${PROXY_IFACE} missing or does not match the project profile"
    fi
fi

# DNS transit interception
if ndmc -c "show running-config" 2>/dev/null | grep -q "intercept enable"; then
    check_ok "DNS transit interception enabled"
else
    check_fail "DNS transit interception (dns-proxy intercept enable) not found"
fi

# Bypass rules
if [ -x /opt/etc/ndm/netfilter.d/020-bypass_wa.sh ]; then
    check_ok "bypass rules: 020-bypass_wa.sh present"
else
    check_fail "bypass rules: /opt/etc/ndm/netfilter.d/020-bypass_wa.sh missing or not executable"
fi

# bypass_wa policy exit: report specifically whether the selected project
# proxy is permitted; other permits (e.g. a manually bound VPN) are fine and
# preserved
_bp_state=$(ndmc -c "show running-config" 2>/dev/null | awk -v px="${PROXY_IFACE:-__none__}" '
    /^ip policy / {pdesc=0; ppermit=0; pother=0; inblk=1; next}
    inblk && /^ *description bypass_wa *$/ {pdesc=1}
    inblk && $0 ~ "^ *permit global " px " *$" {ppermit=1}
    inblk && /^ *permit global [A-Za-z0-9_-]+ *$/ {pother=1}
    /^!/ {if (inblk && pdesc) {if (ppermit) st="bound"; else if (pother) st="other"} inblk=0}
    END {if (inblk && pdesc) {if (ppermit) st="bound"; else if (pother) st="other"}; print st""}
')
case "$_bp_state" in
    bound) check_ok "bypass_wa policy has permit global ${PROXY_IFACE}" ;;
    other) check_warn "bypass_wa policy has interface permits but not ${PROXY_IFACE:-the project proxy} — VoIP exit is not the project proxy" ;;
    *)     check_warn "bypass_wa policy missing or has no interface permit — VoIP bypass has no exit route" ;;
esac

# Watchdog: canonical binary + cron wrapper (or a legacy layout we left alone)
if watchdog_is_canonical "$WATCHDOG_BIN"; then
    check_ok "watchdog canonical present ($WATCHDOG_BIN)"
    if [ -x "$WATCHDOG_CRON" ] && grep -q "^exec $WATCHDOG_BIN" "$WATCHDOG_CRON" 2>/dev/null; then
        check_ok "watchdog cron wrapper present"
    else
        check_fail "watchdog cron wrapper missing or does not point at $WATCHDOG_BIN"
    fi
elif watchdog_is_canonical "$WATCHDOG_CRON"; then
    check_warn "Legacy watchdog layout (full script in cron.5mins) — left unchanged, update-watchdog.sh migrates"
else
    check_fail "watchdog not installed (neither $WATCHDOG_BIN nor legacy cron layout found)"
fi
if grep -q "cron.5mins" /opt/etc/crontab 2>/dev/null || grep -q "mihomo_watchdog" /opt/etc/crontab 2>/dev/null; then
    check_ok "watchdog scheduled in crontab"
else
    check_fail "watchdog not scheduled (no cron.5mins/mihomo_watchdog entry in /opt/etc/crontab)"
fi

# Cron
if [ -x /opt/etc/init.d/S10cron ]; then
    check_ok "cron init script present"
    if ps 2>/dev/null | grep -q "[c]ron"; then
        check_ok "cron is running"
    else
        check_warn "cron process not visible in ps (init script present)"
    fi
else
    check_fail "cron init script /opt/etc/init.d/S10cron missing"
fi

# MagiTrickle
if opkg list-installed 2>/dev/null | grep -q "^magitrickle "; then
    check_ok "MagiTrickle installed"
    if [ -x /opt/etc/init.d/S99magitrickle ]; then
        check_ok "MagiTrickle init script present"
    else
        check_warn "MagiTrickle init script /opt/etc/init.d/S99magitrickle missing"
    fi
else
    check_fail "MagiTrickle package not installed"
fi

# S00ubifs (ram mode only)
if [ "$MODE" = "ram" ]; then
    if [ -x /opt/etc/init.d/S00ubifs ]; then
        check_ok "S00ubifs present (ram mode)"
    else
        check_fail "S00ubifs missing (ram mode)"
    fi
fi

# Config.yaml: the bootstrap (mixed-port 7890) should always be present;
# port 7890 is checked whenever a config exists.
if [ -f "$CONFIG" ]; then
    if mihomo_running; then
        check_info "Mihomo config syntax check skipped - the daemon is running and 'mihomo -t' would execute a second Mihomo (one-Mihomo invariant); the running service proves the config loads"
    elif ${MIHOMO_BIN} -t -d /opt/etc/mihomo -f "$CONFIG" >/dev/null 2>&1; then
        check_ok "Mihomo config syntax valid"
    else
        check_warn "Mihomo config syntax check (mihomo -t) failed"
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -tln 2>/dev/null | grep -q 7890 || check_warn "Port 7890 not listening — Mihomo may not be running, or config.yaml does not define mixed-port 7890"
    elif command -v ss >/dev/null 2>&1; then
        ss -tln 2>/dev/null | grep -q 7890 || check_warn "Port 7890 not listening — Mihomo may not be running, or config.yaml does not define mixed-port 7890"
    fi
else
    check_fail "config.yaml not found (required bootstrap missing) — project ProxyN cannot reach Mihomo on 7890"
fi

# Mihomo endpoint distinction (read-only): the project ProxyN upstream needs
# a SOCKS5/Mixed endpoint on 7890. A user config exposing only transparent
# proxy ports (tproxy/redir) cannot feed ProxyN; the installer never
# modifies the user config — reported so the gap is visible immediately.
if [ -f "$CONFIG" ] &&    grep -qE '^[[:space:]]*(tproxy-port|redir-port):' "$CONFIG" &&    ! grep -qE '^[[:space:]]*(mixed-port|socks-port|port):' "$CONFIG"; then
    check_warn "config.yaml defines only transparent-proxy ports (tproxy/redir) and no SOCKS5/Mixed endpoint — the project ProxyN upstream (127.0.0.1:7890) needs one, e.g. 'mixed-port: 7890' (user config is never modified by the installer)"
fi

# Free space on /opt (critical low)
AVAIL_KB=$(df -k /opt 2>/dev/null | awk 'NR==2 {print $4}')
case "$AVAIL_KB" in
    ''|*[!0-9]*)
        check_warn "Cannot determine free space on /opt"
        ;;
    *)
        if [ "$AVAIL_KB" -lt 32768 ]; then
            check_warn "Low free space on /opt: ${AVAIL_KB} KB"
        else
            check_ok "Free space on /opt: ${AVAIL_KB} KB"
        fi
        ;;
esac

# Verdict
if [ "$FAILS" -gt 0 ]; then
    echo "[FAIL] $FAILS check(s) failed, $WARNS warning(s) — installation incomplete"
    exit 1
fi
if [ "$WARNS" -gt 0 ]; then
    echo "[OK] Done ($WARNS warning(s))"
else
    echo "[OK] Done"
fi
