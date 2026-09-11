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
trap 'rm -f "$TMP_DIR/mihomo.ipk"' EXIT INT TERM

# ---------------------------
# CHECK BASE
# ---------------------------
command -v opkg >/dev/null 2>&1 || err "opkg not found"

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
    ndmc -c "dns-proxy intercept enable" >/dev/null 2>&1 || warn "Failed to enable DNS transit interception"
    ndmc -c "system configuration save" >/dev/null 2>&1
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

[ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" = "null" ] && \
    err "No mihomo ipk found for arch suffix: ${IPK_SUFFIX}. Check https://github.com/${REPO_OWNER}/${REPO_NAME}/releases"

log "Found: $(basename "$DOWNLOAD_URL")"
log "Downloading..."

retry curl -fL "$DOWNLOAD_URL" -o "$TMP_DIR/mihomo.ipk" || err "Failed to download mihomo ipk"

log "Installing package..."
opkg install "$TMP_DIR/mihomo.ipk" || err "Mihomo install failed"

rm -f "$TMP_DIR/mihomo.ipk"

MIHOMO_BIN=$(command -v mihomo 2>/dev/null || echo "/opt/bin/mihomo")
log "Mihomo version: $(${MIHOMO_BIN} -v 2>/dev/null | head -1 || echo "unknown")"

# ---------------------------
# MIHOMO BOOTSTRAP CONFIG
# ---------------------------
# The mihomo ipk ships its own placeholder config.yaml (a conffile) with no
# mixed-port: 7890 — the project contract port (Proxy0 upstream, watchdog,
# self-check). Provide a project bootstrap instead:
#   - config.yaml missing -> create it;
#   - config.yaml still identical to the conffile md5 recorded by opkg at
#     package install time (untouched package placeholder) -> replace it;
#   - anything else is a user config -> never modified.
# Once replaced, the file differs from the recorded conffile md5, so future
# package upgrades preserve it exactly like a user config.
ensure_bootstrap_config() {
    _config="$1"

    mkdir -p "${_config%/*}" || { warn "Cannot create ${_config%/*}"; return 0; }

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
        cat > "$_config" <<'EOF' || warn "Failed to write bootstrap config"
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
MAX_PROXY_PROBE=32   # Protective scan cap ONLY: KeeneticOS documents no limit
                     # for Proxy instances; the cap bounds ndmc probing cost
                     # in a pathological setup and is not an OS maximum.

proxy_exists() {
    ndmc -c "show interface $1" >/dev/null 2>&1
}

proxy_is_project() {
    ndmc -c "show running-config" 2>/dev/null | awk -v iface="$1" -v num="$2" '
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

select_project_proxy() {
    PROXY_IFACE=""

    # 1) Reuse an existing project proxy (lowest number first).
    _n=0
    while [ "$_n" -lt "$MAX_PROXY_PROBE" ]; do
        if proxy_exists "Proxy$_n" && proxy_is_project "Proxy$_n" "$_n"; then
            PROXY_IFACE="Proxy$_n"
            log "Using existing project proxy ${PROXY_IFACE}"
            return 0
        fi
        _n=$((_n+1))
    done

    # 2) No project proxy exists: create Proxy0 when the slot is free.
    if ! proxy_exists "Proxy0"; then
        log "Creating project proxy Proxy0..."
        create_project_proxy "Proxy0"
        PROXY_IFACE="Proxy0"
        return 0
    fi

    # 3) Proxy0 is foreign: leave it untouched, take the first free ProxyN.
    _n=1
    while [ "$_n" -lt "$MAX_PROXY_PROBE" ] && proxy_exists "Proxy$_n"; do
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

    if ! proxy_exists "$_px"; then
        warn "${_px} not available, bypass_wa exit binding skipped"
        return 0
    fi

    # Bind only a project-managed proxy interface. Both markers are checked
    # in running-config: the upstream port is not visible in "show interface".
    # A foreign Proxy interface is never modified and never used as the
    # bypass_wa exit — the policy keeps exactly the exits its owner configured.
    if ! proxy_is_project "$_px" "$_num"; then
        warn "Existing ${_px} does not match the project profile (mihomo t2s${_num} / 127.0.0.1:7890), bypass_wa exit binding skipped"
        return 0
    fi

    # Find the policy block by its description (the policy NAME may differ,
    # e.g. Policy0 when created via web UI). Prints the policy name when it
    # lacks the project permit, "BOUND" when the permit already exists, and
    # nothing when no bypass_wa policy exists. Running-config nests policy
    # directives, so a plain grep would false-positive on other policies'
    # permit lists; block state is evaluated when each block closes, not at END.
    _pol_state=$(ndmc -c "show running-config" 2>/dev/null | awk -v px="$_px" '
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
    wget -qO- http://bin.magitrickle.dev/packages/add_repo.sh | sh || \
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

if retry curl -fsSL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/020-bypass_wa.sh \
    -o /opt/etc/ndm/netfilter.d/020-bypass_wa.sh; then

    chmod +x /opt/etc/ndm/netfilter.d/020-bypass_wa.sh
else
    warn "bypass download failed"
fi

# ---------------------------
# WATCHDOG
# ---------------------------
log "Installing watchdog..."

mkdir -p /opt/etc/cron.5mins

if retry curl -fsSL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo_watchdog.sh \
    -o /opt/etc/cron.5mins/mihomo_watchdog; then

    chmod +x /opt/etc/cron.5mins/mihomo_watchdog

    mkdir -p /opt/var/log
    touch /opt/var/log/mihomo_watchdog.log
    chmod 666 /opt/var/log/mihomo_watchdog.log

    if grep -q "cron.5mins" /opt/etc/crontab 2>/dev/null; then
        log "Using run-parts"
    else
        log "Fallback to crontab"
        grep -q "mihomo_watchdog" /opt/etc/crontab 2>/dev/null || \
            echo "*/5 * * * * root /bin/sh /opt/etc/cron.5mins/mihomo_watchdog" >> /opt/etc/crontab
    fi

    /opt/etc/init.d/S10cron restart || warn "Cron restart failed"
else
    warn "Watchdog download failed"
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

CONFIG="/opt/etc/mihomo/config.yaml"

# Mihomo binary + version
if [ -x /opt/bin/mihomo ] || command -v mihomo >/dev/null 2>&1; then
    MIHOMO_BIN=$(command -v mihomo 2>/dev/null || echo "/opt/bin/mihomo")
    if ${MIHOMO_BIN} -v >/dev/null 2>&1; then
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
# markers are verified in running-config (deterministic text output)
if [ -z "$PROXY_IFACE" ]; then
    check_fail "No project proxy (Proxy0 is foreign and no free ProxyN found)"
elif proxy_exists "$PROXY_IFACE" && proxy_is_project "$PROXY_IFACE" "${PROXY_IFACE#Proxy}"; then
    check_ok "Project proxy ${PROXY_IFACE}: mihomo t2s${PROXY_IFACE#Proxy} -> 127.0.0.1:7890"
else
    check_fail "Project proxy ${PROXY_IFACE} missing or does not match the project profile"
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

# Watchdog + cron registration
if [ -x /opt/etc/cron.5mins/mihomo_watchdog ]; then
    check_ok "watchdog present"
else
    check_fail "watchdog /opt/etc/cron.5mins/mihomo_watchdog missing or not executable"
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
    if ${MIHOMO_BIN} -t -d /opt/etc/mihomo -f "$CONFIG" >/dev/null 2>&1; then
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
    check_warn "config.yaml not found (bootstrap missing) — 7890 stays down until a config exists"
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
