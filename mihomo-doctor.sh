#!/bin/sh

# =========================================================
# mihomo-doctor.sh v1.0.0 - READ-ONLY diagnostic for the
# keenetic-auto-setup stack (Mihomo + watchdog + Keenetic
# proxy bridge) on Keenetic + Entware.
#
# The doctor collects facts and prints a report. It NEVER:
#   installs, updates or removes anything; never touches
#   config.yaml or Keenetic configuration; never creates
#   Proxy interfaces; never starts/stops/restarts Mihomo;
#   never runs install.sh / update-mihomo.sh / opkg.
# It is safe to run at any time and safe to paste the whole
# output into a support chat: no config contents, secrets,
# subscription URLs or proxy credentials are printed.
#
# Statuses: [OK] / [WARN] / [FAIL] / [INFO]
# Exit codes: 0 = no FAIL, no WARN; 1 = WARN but no FAIL;
#             2 = at least one FAIL.
#
# Test hooks (do not set in normal use): DOCTOR_OPT_ROOT
# redirects the /opt prefix and DOCTOR_MEMINFO the meminfo
# source, so the doctor can be exercised on a non-Entware
# host. Unset they behave exactly like /opt and /proc/meminfo.
# =========================================================

OPT_ROOT="${DOCTOR_OPT_ROOT:-/opt}"
MEMINFO="${DOCTOR_MEMINFO:-/proc/meminfo}"

MIHOMO_PATH="$OPT_ROOT/bin/mihomo"
CONFIG_DIR="$OPT_ROOT/etc/mihomo"
CONFIG="$CONFIG_DIR/config.yaml"
INIT_EXPECTED="$OPT_ROOT/etc/init.d/S99mihomo"
WATCHDOG_BIN="$OPT_ROOT/bin/mihomo_watchdog.sh"
WATCHDOG_CRON="$OPT_ROOT/etc/cron.5mins/mihomo_watchdog"
WATCHDOG_LOG="$OPT_ROOT/var/log/mihomo_watchdog.log"
CRONTAB_FILE="$OPT_ROOT/etc/crontab"

ENTWARE_REPO="saymer-alt/entware-go"
CONTRACT_PORT=7890          # watchdog PROXY + project ProxyN upstream
MAX_PROXY_PROBE=32          # same protective scan cap as install.sh

N_OK=0; N_WARN=0; N_FAIL=0; N_INFO=0

ok()   { printf '[OK]   %s\n' "$1"; N_OK=$((N_OK+1)); }
warn() { printf '[WARN] %s\n' "$1"; N_WARN=$((N_WARN+1)); }
fail() { printf '[FAIL] %s\n' "$1"; N_FAIL=$((N_FAIL+1)); }
info() { printf '[INFO] %s\n' "$1"; N_INFO=$((N_INFO+1)); }
hdr()  { printf '\n===== %s =====\n\n' "$1"; }

is_num() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    return 0
}

first_line() {
    printf '%s\n' "$1" | head -n 1
}

# fetch_url URL -> globals FETCH_OUT (body) and FETCH_RC.
# curl preferred, wget fallback; nothing is written to disk.
fetch_url() {
    if command -v curl >/dev/null 2>&1; then
        FETCH_OUT=$(curl -fsSL --connect-timeout 5 --max-time 15 "$1" 2>/dev/null)
        FETCH_RC=$?
    elif command -v wget >/dev/null 2>&1; then
        FETCH_OUT=$(wget -qO- -T 15 "$1" 2>/dev/null)
        FETCH_RC=$?
    else
        FETCH_OUT=""; FETCH_RC=127
    fi
}

# run_with_timeout SECS CMD... -> globals RUN_OUT / RUN_RC.
# Uses the timeout applet when present, otherwise runs directly.
run_with_timeout() {
    _to="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        RUN_OUT=$(timeout "$_to" "$@" 2>&1)
    else
        RUN_OUT=$( "$@" 2>&1 )
    fi
    RUN_RC=$?
}

# port_listening N -> PL_RC: 0 listening, 1 not listening,
# 2 cannot determine. netstat -> ss -> /proc/net/tcp(6) hex
# compare (no strtonum: the decimal port is converted to hex).
port_listening() {
    _pl="$1"
    if command -v netstat >/dev/null 2>&1; then
        if netstat -tln 2>/dev/null | awk '{print $4}' | grep -q ":$_pl\$"; then
            PL_RC=0; else PL_RC=1; fi
    elif command -v ss >/dev/null 2>&1; then
        if ss -tln 2>/dev/null | awk '{print $4}' | grep -q ":$_pl\$"; then
            PL_RC=0; else PL_RC=1; fi
    elif [ -r /proc/net/tcp ] || [ -r /proc/net/tcp6 ]; then
        _hx=$(printf '%04X' "$_pl")
        PL_RC=1
        for _f in /proc/net/tcp /proc/net/tcp6; do
            [ -r "$_f" ] || continue
            if awk -v h="$_hx" 'NR>1 {n=split($2,a,":"); if (a[n]==h) found=1} END{exit !found}' "$_f" 2>/dev/null; then
                PL_RC=0
                break
            fi
        done
    else
        PL_RC=2
    fi
}

# count_mihomo_procs -> MIHOMO_PROCS. pidof preferred; without
# it, scan /proc cmdlines for argv0 basename == "mihomo"
# (the watchdog and this doctor have different basenames and
# are not counted).
count_mihomo_procs() {
    MIHOMO_PROCS=0
    if command -v pidof >/dev/null 2>&1; then
        set -- $(pidof mihomo 2>/dev/null)
        MIHOMO_PROCS=$#
    else
        for _p in /proc/[0-9]*/cmdline; do
            _pid=${_p%/cmdline}; _pid=${_pid#/proc/}
            [ "$_pid" = "$$" ] && continue
            _a0=$(tr '\000' '\n' < "$_p" 2>/dev/null | head -n 1)
            [ "$(basename "$_a0" 2>/dev/null)" = "mihomo" ] || continue
            MIHOMO_PROCS=$((MIHOMO_PROCS+1))
        done
    fi
}

# cfg_scalar KEY -> prints the first column-0 YAML scalar value
# for KEY, quotes stripped. Nested keys are not matched.
cfg_scalar() {
    _v=$(grep -E "^$1:" "$CONFIG" 2>/dev/null | head -n 1 | sed "s/^$1:[[:space:]]*//")
    printf '%s' "$_v" | tr -d "\"'"
}

# Numeric dotted-version comparator (same semantics as
# update-mihomo.sh): prints lt | eq | gt, or "unknown" when a
# component is non-numeric (prerelease/build suffixes).
ver_compare() {
    _va=$1; _vb=$2
    while :; do
        _a=${_va%%.*}; _ra=""
        case "$_va" in *.*) _ra=${_va#*.} ;; esac
        _b=${_vb%%.*}; _rb=""
        case "$_vb" in *.*) _rb=${_vb#*.} ;; esac
        [ -z "$_a" ] && _a=0
        [ -z "$_b" ] && _b=0
        case "$_a$_b" in *[!0-9]*) echo unknown; return 0 ;; esac
        if [ "$_a" -lt "$_b" ]; then echo lt; return 0; fi
        if [ "$_a" -gt "$_b" ]; then echo gt; return 0; fi
        if [ -z "$_ra" ] && [ -z "$_rb" ]; then echo eq; return 0; fi
        _va=$_ra; _vb=$_rb
    done
}

if [ $# -gt 0 ]; then
    echo "Usage: sh mihomo-doctor.sh"
    echo "  No options. The doctor is strictly read-only."
    exit 0
fi

echo "=== Mihomo Doctor (read-only diagnostic) ==="
info "Nothing is installed, updated, removed, started or stopped; config.yaml and Keenetic settings are not touched."

BIN_STATE=""      # "" | missing | noexec | ok | segv | execfail
BIN=""            # resolved binary path
BIN_VER=""        # parsed version ("" when unrecognized)
RELEASE_JSON=""
NET_GITHUB=1

# =========================================================
hdr "1. System"
# =========================================================

if command -v ndmc >/dev/null 2>&1; then
    MODEL=$(ndmc -c "show version" 2>/dev/null | tr -d '\r' | grep -Ei 'model|hw id' | head -n 1 | sed 's/^[[:space:]]*//')
    if [ -z "$MODEL" ] && command -v ndmq >/dev/null 2>&1; then
        MODEL=$(ndmq -p 'show version' -f json 2>/dev/null | grep -o '"title":"[^"]*"' | cut -d'"' -f4)
    fi
    if [ -n "$MODEL" ]; then
        info "Router: $MODEL"
    else
        info "Router model: not reported by ndmc/ndmq"
    fi
else
    info "ndmc not available - Keenetic model info skipped"
fi
info "Kernel: $(uname -sr 2>/dev/null)  Machine: $(uname -m 2>/dev/null)"

if command -v opkg >/dev/null 2>&1; then
    ARCH_LINES=$(opkg print-architecture 2>/dev/null)
    if [ -n "$ARCH_LINES" ]; then
        info "opkg architectures: $(printf '%s\n' "$ARCH_LINES" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    fi
    ARCH=$(printf '%s\n' "$ARCH_LINES" | awk '/^arch/ && $2~/^(mips|mipsel|aarch64|arm)/{
        sub(/[-_].*/,"",$2); print $2; exit
    }')
    case "$ARCH" in
        aarch64*)    IPK_SUFFIX="aarch64-3.10" ;;
        armv7*|arm*) IPK_SUFFIX="armv7-3.2" ;;
        mipsel*)     IPK_SUFFIX="mipsel-3.4" ;;
        mips*)       IPK_SUFFIX="mips-3.4" ;;
        *)           IPK_SUFFIX="" ;;
    esac
    info "Detected Entware arch: ${ARCH:-unknown}; expected ipk suffix: ${IPK_SUFFIX:-unknown}"
else
    IPK_SUFFIX=""
    info "opkg not available - Entware architecture unknown"
fi

MEM_TOTAL=$(awk '/^MemTotal:/ {print $2}' "$MEMINFO" 2>/dev/null)
MEM_AVAIL=$(awk '/^MemAvailable:/ {print $2}' "$MEMINFO" 2>/dev/null)
SWAP_TOTAL=$(awk '/^SwapTotal:/ {print $2}' "$MEMINFO" 2>/dev/null)
SWAP_FREE=$(awk '/^SwapFree:/ {print $2}' "$MEMINFO" 2>/dev/null)

if is_num "$MEM_TOTAL"; then
    info "RAM total: $((MEM_TOTAL/1024)) MB, available: $(is_num "$MEM_AVAIL" && echo $((MEM_AVAIL/1024)) || echo '?') MB"
    if [ "$MEM_TOTAL" -lt 250000 ]; then
        warn "Total RAM below the project minimum of 256 MB ($((MEM_TOTAL/1024)) MB) - 128 MB devices are unsupported (docs/06)"
    fi
    if is_num "$MEM_AVAIL" && [ "$MEM_AVAIL" -lt 25000 ]; then
        warn "Very low available memory ($((MEM_AVAIL/1024)) MB) - Mihomo (UPX-packed, unpacks in RAM) and updates need headroom"
    fi
else
    info "RAM usage cannot be read ($MEMINFO)"
fi
if is_num "$SWAP_TOTAL"; then
    if [ "$SWAP_TOTAL" -eq 0 ]; then
        info "Swap: none configured"
    else
        info "Swap: $((SWAP_TOTAL/1024)) MB (free $((SWAP_FREE/1024)) MB)"
    fi
fi

for _mount in "$OPT_ROOT" /tmp; do
    _kb=$(df -k "$_mount" 2>/dev/null | awk 'NR==2 {print $4}')
    case "$_kb" in
        ''|*[!0-9]*)
            info "Free space on $_mount: cannot determine"
            ;;
        *)
            if [ "$_kb" -lt 32768 ]; then
                warn "Low free space on $_mount: $((_kb/1024)) MB - installs and updates need ~50 MB"
            else
                ok "Free space on $_mount: $((_kb/1024)) MB"
            fi
            ;;
    esac
done

# =========================================================
hdr "2. Entware"
# =========================================================

if [ -d "$OPT_ROOT" ]; then
    ok "Entware root present ($OPT_ROOT)"
else
    fail "Entware root $OPT_ROOT not found - is Entware installed?"
fi
if command -v opkg >/dev/null 2>&1; then
    ok "opkg present"
else
    fail "opkg not found - Entware package manager unavailable"
fi
for _d in bin etc etc/init.d etc/mihomo var/log; do
    if [ -d "$OPT_ROOT/$_d" ]; then
        info "Directory present: $OPT_ROOT/$_d"
    else
        info "Directory absent:  $OPT_ROOT/$_d"
    fi
done

PRESENT_TOOLS=""; MISSING_TOOLS=""
for _t in opkg curl wget jq tar gzip pidof ss netstat nslookup ndmc ndmq timeout; do
    if command -v "$_t" >/dev/null 2>&1; then
        PRESENT_TOOLS="$PRESENT_TOOLS $_t"
    else
        MISSING_TOOLS="$MISSING_TOOLS $_t"
    fi
done
info "Tools present:${PRESENT_TOOLS:- none}"
info "Tools missing:${MISSING_TOOLS:- none}"
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    warn "Neither curl nor wget available - network checks, install.sh and update-mihomo.sh cannot download anything"
fi

# =========================================================
hdr "3. Mihomo binary"
# =========================================================

if [ -f "$MIHOMO_PATH" ]; then
    BIN="$MIHOMO_PATH"
elif COMMAND_PATH=$(command -v mihomo 2>/dev/null) && [ -n "$COMMAND_PATH" ]; then
    BIN="$COMMAND_PATH"
    info "Binary not at $MIHOMO_PATH, found via PATH: $BIN"
else
    fail "Mihomo binary not found ($MIHOMO_PATH)"
    info "Install with install.sh - the doctor does not install anything."
    BIN_STATE="missing"
fi

if [ -n "$BIN" ]; then
    if [ -x "$BIN" ]; then
        BIN_STATE=""   # decided by the run below
    else
        fail "Mihomo binary exists but is not executable ($BIN) - 'chmod +x $BIN' is needed; the doctor does not modify files"
        BIN_STATE="noexec"
    fi

    BIN_SIZE=$(wc -c < "$BIN" 2>/dev/null)
    if is_num "$BIN_SIZE"; then
        info "Binary: $BIN ($((BIN_SIZE/1024)) KB)"
    fi

    EXTRA_BINS=$(find "$OPT_ROOT" -name mihomo -type f 2>/dev/null | grep -v "^$BIN\$" | head -n 4)
    if [ -n "$EXTRA_BINS" ]; then
        warn "Additional mihomo binaries found - update-mihomo.sh picks the first find() hit, which is an undefined selection:"
        printf '%s\n' "$EXTRA_BINS" | while IFS= read -r _x; do info "  $_x"; done
    fi

    if [ "$BIN_STATE" != "noexec" ]; then
        run_with_timeout 15 "$BIN" -v
        MV_RC=$RUN_RC
        MV_OUT=$RUN_OUT
        case "$MV_RC" in
            0)
                BIN_STATE="ok"
                BIN_VER=$(first_line "$MV_OUT" | awk '{print $3}')
                BIN_VER=${BIN_VER#v}
                case "$BIN_VER" in
                    ''|*[!0-9.]*) BIN_VER="" ;;
                esac
                if [ -n "$BIN_VER" ]; then
                    ok "Mihomo binary runs - version $BIN_VER ($(first_line "$MV_OUT"))"
                else
                    ok "Mihomo binary executes (exit 0)"
                    info "Version string not recognized from: $(first_line "$MV_OUT")"
                    info "A successful exit with an unparseable version is NOT proof of corruption; update-mihomo.sh reports 'Current Mihomo: unknown' for such builds and treats it as a repair case."
                fi
                ;;
            124)
                fail "Mihomo binary did not exit within 15s (timeout) - hung execution"
                BIN_STATE="execfail"
                ;;
            139)
                fail "Mihomo binary exists but cannot execute (exit 139 / possible SIGSEGV)"
                BIN_STATE="segv"
                ;;
            126)
                fail "Mihomo binary cannot be executed (exit 126 - wrong architecture or corrupted file)"
                BIN_STATE="execfail"
                ;;
            127)
                fail "Mihomo binary execution failed (exit 127 - missing dynamic loader or broken file)"
                BIN_STATE="execfail"
                ;;
            *)
                if [ "$MV_RC" -gt 128 ] && [ "$MV_RC" -lt 192 ]; then
                    fail "Mihomo binary killed by signal $((MV_RC-128)) (exit $MV_RC)"
                else
                    fail "Mihomo binary exits with an error (exit $MV_RC)"
                fi
                BIN_STATE="execfail"
                ;;
        esac
        if [ "$MV_RC" -ne 0 ] && printf '%s\n' "$MV_OUT" | grep -q "Segmentation fault"; then
            if [ "$BIN_STATE" != "segv" ]; then
                fail "Mihomo binary exists but cannot execute (Segmentation fault reported, exit $MV_RC)"
                BIN_STATE="segv"
            fi
        fi
        if [ "$BIN_STATE" = "segv" ]; then
            info "Output: $(first_line "$MV_OUT")"
            info "SIGSEGV on some MIPSLE Mihomo builds is under separate investigation (a possible UPX connection is unconfirmed). The doctor does not modify binaries."
            info "Low available memory (section 1) is another possible factor; recovery path is a reinstall via install.sh (not done by the doctor)."
        fi
    fi
fi

# =========================================================
hdr "4. Config"
# =========================================================

if [ ! -f "$CONFIG" ]; then
    warn "config.yaml not found ($CONFIG) - Mihomo has nothing to load; install.sh writes a bootstrap (mixed-port 7890) on fresh installs"
elif [ ! -r "$CONFIG" ]; then
    warn "config.yaml is not readable ($CONFIG)"
else
    CONFIG_SIZE=$(wc -c < "$CONFIG" 2>/dev/null)
    if is_num "$CONFIG_SIZE"; then
        info "config.yaml present ($((CONFIG_SIZE/1024)) KB) - contents are never printed by the doctor"
    fi

    CFG_PORTS=""
    CFG_HAS_CONTRACT=0
    for _key in mixed-port port socks-port redir-port tproxy-port; do
        _val=$(cfg_scalar "$_key")
        is_num "$_val" || continue
        info "Configured port ($_key): $_val"
        case " $CFG_PORTS " in *" $_val "*) ;; *) CFG_PORTS="$CFG_PORTS $_val" ;; esac
        [ "$_val" = "$CONTRACT_PORT" ] && CFG_HAS_CONTRACT=1
    done
    if [ -z "$CFG_PORTS" ]; then
        info "No inbound proxy port parsed from config (contract port $CONTRACT_PORT normally comes from mixed-port; the bootstrap sets it)"
    elif [ "$CFG_HAS_CONTRACT" -eq 0 ]; then
        warn "Contract port $CONTRACT_PORT is not among the configured ports - watchdog port check and the project ProxyN upstream (127.0.0.1:$CONTRACT_PORT) will fail with this config"
    fi

    EC_VAL=$(cfg_scalar external-controller)
    if [ -z "$EC_VAL" ]; then
        info "external-controller not set - REST API disabled (the project default; port 9090 is a convention, not a default)"
    else
        EC_HOST=${EC_VAL%:*}
        EC_PORT=${EC_VAL##*:}
        case "$EC_HOST" in
            127.0.0.1|localhost|::1)
                info "external-controller bound to loopback (port $EC_PORT)"
                ;;
            *)
                EC_SECRET=$(grep -E "^[[:space:]]*secret:" "$CONFIG" 2>/dev/null | head -n 1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d "\"'")
                if [ -z "$EC_SECRET" ]; then
                    warn "external-controller bound beyond loopback without a secret - anyone on the network can control Mihomo (doctor does not modify config)"
                else
                    info "external-controller bound beyond loopback with a secret set (port $EC_PORT)"
                fi
                ;;
        esac
    fi

    if grep -Eq "^tun:" "$CONFIG" 2>/dev/null && \
       awk '/^tun:/{f=1;next} f&&/^[^[:space:]]/{f=0} f&&/enable:/&&/true/{found=1} END{exit !found}' "$CONFIG" 2>/dev/null; then
        info "TUN enabled in config (mitun0 inbound expected)"
    fi

    DL_VAL=$(grep -E "^[[:space:]]+listen:" "$CONFIG" 2>/dev/null | head -n 1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d "\"'")
    DL_PORT=${DL_VAL##*:}
    DNS_PORT=""
    if is_num "$DL_PORT"; then
        DNS_PORT="$DL_PORT"
        info "DNS listen (best-effort parse): port $DNS_PORT"
    fi

    if [ "$BIN_STATE" = "ok" ]; then
        run_with_timeout 30 "$BIN" -d "$CONFIG_DIR" -t
        if [ "$RUN_RC" -eq 0 ]; then
            ok "Config test passed ($BIN -d $CONFIG_DIR -t)"
        else
            fail "Config test FAILED (exit $RUN_RC) - the running config is rejected by this Mihomo version"
            info "Run 'mihomo -t -d $CONFIG_DIR' interactively for the exact error (the doctor does not print config-derived error text to avoid leaking details)."
        fi
    else
        info "Config test not performed: the binary cannot be executed right now (state: ${BIN_STATE:-unknown}) - the config itself is NOT judged"
    fi
fi

# =========================================================
hdr "5. Service"
# =========================================================

INIT_SCRIPT=""
if [ -x "$INIT_EXPECTED" ]; then
    INIT_SCRIPT="$INIT_EXPECTED"
    ok "Mihomo init script present ($INIT_SCRIPT)"
elif [ -f "$INIT_EXPECTED" ]; then
    INIT_SCRIPT="$INIT_EXPECTED"
    warn "Mihomo init script exists but is not executable ($INIT_SCRIPT)"
else
    INIT_SCRIPT=$(find "$OPT_ROOT/etc/init.d" -name '*mihomo*' -type f 2>/dev/null | head -n 1)
    if [ -n "$INIT_SCRIPT" ]; then
        info "Init script found (non-standard name): $INIT_SCRIPT"
    else
        info "No Mihomo init script in $OPT_ROOT/etc/init.d (expected $INIT_EXPECTED)"
    fi
fi

count_mihomo_procs
if [ "$MIHOMO_PROCS" -gt 0 ]; then
    if [ -n "$INIT_SCRIPT" ]; then
        ok "Mihomo is running ($MIHOMO_PROCS process(es)), managed by $INIT_SCRIPT"
    else
        warn "Mihomo is running ($MIHOMO_PROCS process(es)) but no init script found - not managed, not started on boot"
    fi
    if [ "$MIHOMO_PROCS" -gt 1 ]; then
        warn "Multiple mihomo processes ($MIHOMO_PROCS) - expected 1, possible stale leftovers"
    fi
else
    if [ -n "$INIT_SCRIPT" ]; then
        warn "Mihomo service is stopped (init script present). If you stopped it yourself, this is expected - the doctor never starts services"
    else
        fail "Mihomo is not running and no init script exists - nothing will start it on boot ($INIT_EXPECTED missing)"
    fi
fi
if ! command -v pidof >/dev/null 2>&1; then
    info "pidof unavailable - process count done via /proc scan"
fi

# =========================================================
hdr "6. Ports"
# =========================================================

if [ "$MIHOMO_PROCS" -eq 0 ]; then
    info "Mihomo is not running - listener checks are informational only"
    port_listening "$CONTRACT_PORT"
    if [ "$PL_RC" -eq 0 ]; then
        warn "Port $CONTRACT_PORT is listening but Mihomo is not running - a foreign process or a stale instance holds the contract port"
    else
        info "Contract port $CONTRACT_PORT not listening (consistent with the stopped service)"
    fi
else
    if [ -n "$CFG_PORTS" ]; then
        for _pl in $CFG_PORTS; do
            port_listening "$_pl"
            if [ "$PL_RC" -eq 0 ]; then
                ok "Listening on configured port $_pl"
            elif [ "$PL_RC" -eq 2 ]; then
                info "Cannot verify listeners (no netstat/ss and no /proc/net/tcp)"
            elif [ "$_pl" = "$CONTRACT_PORT" ]; then
                fail "Mihomo is running but contract port $CONTRACT_PORT is NOT listening - the proxy is unreachable (check config and startup logs)"
            else
                warn "Mihomo is running but configured port $_pl is not listening"
            fi
        done
    else
        port_listening "$CONTRACT_PORT"
        if [ "$PL_RC" -eq 0 ]; then
            ok "Listening on contract port $CONTRACT_PORT"
        elif [ "$PL_RC" -eq 2 ]; then
            info "Cannot verify listeners (no netstat/ss and no /proc/net/tcp)"
        else
            warn "No port defined in config and contract port $CONTRACT_PORT not listening - the watchdog will treat the proxy as down (TUN-only config?)"
        fi
    fi

    if [ -n "$EC_PORT" ] && is_num "$EC_PORT"; then
        port_listening "$EC_PORT"
        if [ "$PL_RC" -eq 0 ]; then
            info "external-controller port $EC_PORT is listening"
        else
            info "external-controller port $EC_PORT is configured but not listening (optional listener)"
        fi
    fi
    if [ -n "$DNS_PORT" ]; then
        port_listening "$DNS_PORT"
        if [ "$PL_RC" -eq 0 ]; then
            info "DNS listen port $DNS_PORT is listening"
        else
            info "DNS listen port $DNS_PORT is configured but not listening (optional listener)"
        fi
    fi
fi

# =========================================================
hdr "7. Keenetic proxy bridge (ProxyN)"
# =========================================================

if ! command -v ndmc >/dev/null 2>&1; then
    info "ndmc not available - Proxy bridge checks skipped (not a Keenetic shell?)"
else
    # One validated running-config snapshot for every decision below
    # (same semantics as install.sh: UNKNOWN is never treated as
    # NOT_FOUND, and nothing is ever modified here).
    _rc_att=0
    RC_DUMP=""
    while [ "$_rc_att" -lt 2 ]; do
        RC_DUMP=$(ndmc -c "show running-config" 2>/dev/null | tr -d '\r')
        if printf '%s\n' "$RC_DUMP" | grep -q '^interface '; then
            break
        fi
        _rc_att=$((_rc_att+1))
        [ "$_rc_att" -lt 2 ] && sleep 2
    done

    if ! printf '%s\n' "$RC_DUMP" | grep -q '^interface '; then
        warn "Cannot read/validate running-config - proxy state UNKNOWN, nothing is assumed (transient ndmc problem?)"
    else
        proxy_is_project() {
            printf '%s\n' "$RC_DUMP" | awk -v iface="$1" -v num="$2" '
                $0 == "interface " iface {pdesc=0; pup=0; inblk=1; next}
                inblk && /^!/ {if (pdesc && pup) found=1; inblk=0; next}
                inblk && $0 ~ "^ *description \"?mihomo t2s" num "\"? *$" {pdesc=1}
                inblk && /^ *proxy upstream 127\.0\.0\.1 7890 *$/ {pup=1}
                END {if (inblk && pdesc && pup) found=1; exit !found}
            '
        }

        PROJECT_PROXY=""
        FOREIGN_PROXIES=""
        _n=0
        while [ "$_n" -lt "$MAX_PROXY_PROBE" ]; do
            if printf '%s\n' "$RC_DUMP" | grep -qx "interface Proxy$_n"; then
                if proxy_is_project "Proxy$_n" "$_n"; then
                    if [ -z "$PROJECT_PROXY" ]; then
                        PROJECT_PROXY="Proxy$_n"
                        ok "Project proxy Proxy$_n: description \"mihomo t2s$_n\" -> upstream 127.0.0.1:$CONTRACT_PORT"
                    else
                        info "Second project proxy Proxy$_n present (install.sh uses the lowest-numbered one)"
                    fi
                else
                    FOREIGN_PROXIES="$FOREIGN_PROXIES Proxy$_n"
                fi
            fi
            _n=$((_n+1))
        done

        if [ -z "$PROJECT_PROXY" ]; then
            if [ -n "$FOREIGN_PROXIES" ]; then
                fail "No project ProxyN found - foreign Proxy interface(s):$FOREIGN_PROXIES (left untouched; Keenetic has no bridge into Mihomo)"
            else
                fail "No Proxy interfaces found at all - Keenetic has no bridge into Mihomo (install.sh creates Proxy0 / first free ProxyN)"
            fi
        elif [ -n "$FOREIGN_PROXIES" ]; then
            info "Foreign Proxy interface(s) present:$FOREIGN_PROXIES - not project-managed, reported only"
        fi

        _pol_state=$(printf '%s\n' "$RC_DUMP" | awk -v px="${PROJECT_PROXY:-__none__}" '
            /^ip policy / {pdesc=0; ppermit=0; pother=0; inblk=1; next}
            inblk && /^ *description bypass_wa *$/ {pdesc=1}
            inblk && $0 ~ "^ *permit global " px " *$" {ppermit=1}
            inblk && /^ *permit global [A-Za-z0-9_-]+ *$/ {pother=1}
            /^!/ {if (inblk && pdesc) {if (ppermit) st="bound"; else if (pother) st="other"} inblk=0}
            END {if (inblk && pdesc) {if (ppermit) st="bound"; else if (pother) st="other"}; print st""}
        ')
        case "$_pol_state" in
            bound) ok "bypass_wa policy permits ${PROJECT_PROXY:-the project proxy}" ;;
            other) warn "bypass_wa policy has other interface permits but not ${PROJECT_PROXY:-the project proxy} - VoIP bypass exits elsewhere" ;;
            *)     warn "bypass_wa policy not found or has no interface permit - VoIP bypass has no exit route" ;;
        esac

        if printf '%s\n' "$RC_DUMP" | grep -q "intercept enable"; then
            ok "DNS transit interception enabled (dns-proxy intercept enable)"
        else
            warn "DNS transit interception not found - transit port-53 DNS bypasses Keenetic's resolver (install.sh enables it; MagiTrickle coverage may suffer)"
        fi
    fi
fi

# =========================================================
hdr "8. Watchdog"
# =========================================================

WD_CANON=0
if [ -f "$WATCHDOG_BIN" ] && grep -q "MIHOMO WATCHDOG SCRIPT" "$WATCHDOG_BIN" 2>/dev/null; then
    WD_CANON=1
    if [ -x "$WATCHDOG_BIN" ]; then
        ok "Canonical watchdog present ($WATCHDOG_BIN)"
    else
        warn "Canonical watchdog present but not executable ($WATCHDOG_BIN)"
    fi
fi

if [ -f "$WATCHDOG_CRON" ]; then
    if grep -q "^exec $WATCHDOG_BIN" "$WATCHDOG_CRON" 2>/dev/null; then
        ok "Cron wrapper points at the canonical watchdog ($WATCHDOG_CRON)"
    elif grep -q "MIHOMO WATCHDOG SCRIPT" "$WATCHDOG_CRON" 2>/dev/null; then
        warn "Legacy watchdog layout (full script in cron.5mins) - works, but update-watchdog.sh migrates it to the canonical layout"
    else
        warn "Unknown file at $WATCHDOG_CRON - not a project wrapper"
    fi
else
    if [ "$WD_CANON" -eq 1 ]; then
        warn "Canonical watchdog present but the cron wrapper is missing ($WATCHDOG_CRON) - nothing schedules it"
    else
        warn "Watchdog not installed (neither $WATCHDOG_BIN nor a legacy cron layout found) - self-healing absent; install.sh installs it"
    fi
fi

if grep -q "cron.5mins" "$CRONTAB_FILE" 2>/dev/null || grep -q "mihomo_watchdog" "$CRONTAB_FILE" 2>/dev/null; then
    ok "Watchdog scheduled in $CRONTAB_FILE"
else
    warn "Watchdog not scheduled in $CRONTAB_FILE (no cron.5mins/mihomo_watchdog entry)"
fi

# Watchdog log content is analyzed in section 8b only: raw log
# lines are never printed anywhere in this doctor.
if [ -f /tmp/mihomo_watchdog.restart ]; then
    info "Restart state file present - the watchdog has restarted Mihomo at least once (last epoch: $(cat /tmp/mihomo_watchdog.restart 2>/dev/null))"
fi

# =========================================================
hdr "8b. Watchdog history (read-only log analysis)"
# =========================================================
# Ground truth from mihomo_watchdog.sh: every log line is
#   "%Y-%m-%d %H:%M:%S <message>" appended to the log, with
# exactly these messages: "[OK] All good", "[WAN] Connectivity
# OK via <target>", "[WAN] Primary targets unavailable, checking
# whitelist targets", "[WARN] WAN unreachable (primary + whitelist
# targets failed)", "[RESTART] <reason>", "[RATE-LIMIT] Restart
# blocked (...) | <reason>". The only reasons are "Mihomo port
# unreachable" and "Proxy tunnel check failed". Rotation keeps the
# last ~300-500 lines (trimmed at the start of every run); the log
# lives on tmpfs and is lost on reboot. [RESTART] is written BEFORE
# the restart is executed, with no success record afterwards, so a
# recovery can only be confirmed by a later "[OK] All good" entry.
# Analysis prints categories, counts and timestamps only - never
# raw log lines.

WD_STAB="OK"
WD_STAB_WHY=""
if [ ! -e "$WATCHDOG_LOG" ]; then
    if [ "$WD_CANON" -eq 1 ] || [ -f "$WATCHDOG_CRON" ]; then
        warn "Watchdog log not found ($WATCHDOG_LOG) - the watchdog has not run/logged yet, or the tmpfs log was lost on reboot"
    else
        info "Watchdog log not found ($WATCHDOG_LOG) - nothing to analyze (watchdog is not installed)"
    fi
elif [ ! -r "$WATCHDOG_LOG" ]; then
    warn "Watchdog log exists but is not readable ($WATCHDOG_LOG)"
else
    WD_STATS=$(tr -d '\r' < "$WATCHDOG_LOG" | awk '
        {
            total++
            if (length($0) > 20 && $1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ && $2 ~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/) {
                ts = $1 " " $2
                msg = substr($0, 21)
            } else { bad++; next }
            if (first == "") first = ts
            last = ts
            if (msg ~ /^\[OK\]/) { ok++; lastok = ts }
            else if (msg ~ /^\[RESTART\]/) {
                restart++
                lastprob = ts; lastprobk = "restart"
                if (msg ~ /Mihomo port unreachable/) r_port++
                else if (msg ~ /Proxy tunnel check failed/) r_tunnel++
                else r_other++
                pb[substr(ts, 1, 13)]++
                pe[pen++] = "restart " ts
            }
            else if (msg ~ /^\[RATE-LIMIT\]/) {
                ratelimit++
                lastprob = ts; lastprobk = "rate-limited"
                if (msg ~ /Mihomo port unreachable/) l_port++
                else if (msg ~ /Proxy tunnel check failed/) l_tunnel++
                else l_other++
                pb[substr(ts, 1, 13)]++
                pe[pen++] = "rate-limited " ts
            }
            else if (msg ~ /^\[WARN\] WAN unreachable/) wanout++
            else if (msg ~ /^\[WAN\] Primary targets unavailable/) wanwl++
        }
        END {
            print "total=" total + 0
            print "bad=" bad + 0
            print "first=" first
            print "last=" last
            print "ok=" ok + 0
            print "lastok=" lastok
            print "restart=" restart + 0
            print "r_port=" r_port + 0
            print "r_tunnel=" r_tunnel + 0
            print "r_other=" r_other + 0
            print "ratelimit=" ratelimit + 0
            print "l_port=" l_port + 0
            print "l_tunnel=" l_tunnel + 0
            print "l_other=" l_other + 0
            print "wanout=" wanout + 0
            print "wanwl=" wanwl + 0
            print "lastprob=" lastprob
            print "lastprobk=" lastprobk
            print "pen=" pen + 0
            max = 0; mk = ""
            for (k in pb) if (pb[k] > max) { max = pb[k]; mk = k }
            print "seriesmax=" max + 0
            print "serieskey=" mk
            for (i = 0; i < pen && i < 100; i++) print "pevent=" pe[i]
        }
    ')

    WD_TOTAL=0; WD_BAD=0; WD_OK=0; WD_RESTART=0; WD_RL=0
    WD_R_PORT=0; WD_R_TUNNEL=0; WD_R_OTHER=0
    WD_L_PORT=0; WD_L_TUNNEL=0; WD_L_OTHER=0
    WD_WANOUT=0; WD_WANWL=0; WD_PEN=0; WD_SERIESMAX=0
    WD_FIRST=""; WD_LAST=""; WD_LASTOK=""
    WD_LASTPROB=""; WD_LASTPROBK=""; WD_SERIESKEY=""; WD_PEVENTS=""

    while IFS= read -r _line; do
        _k=${_line%%=*}
        _v=${_line#*=}
        case "$_k" in
            total)      WD_TOTAL=$_v ;;
            bad)        WD_BAD=$_v ;;
            first)      WD_FIRST=$_v ;;
            last)       WD_LAST=$_v ;;
            ok)         WD_OK=$_v ;;
            lastok)     WD_LASTOK=$_v ;;
            restart)    WD_RESTART=$_v ;;
            r_port)     WD_R_PORT=$_v ;;
            r_tunnel)   WD_R_TUNNEL=$_v ;;
            r_other)    WD_R_OTHER=$_v ;;
            ratelimit)  WD_RL=$_v ;;
            l_port)     WD_L_PORT=$_v ;;
            l_tunnel)   WD_L_TUNNEL=$_v ;;
            l_other)    WD_L_OTHER=$_v ;;
            wanout)     WD_WANOUT=$_v ;;
            wanwl)      WD_WANWL=$_v ;;
            lastprob)   WD_LASTPROB=$_v ;;
            lastprobk)  WD_LASTPROBK=$_v ;;
            pen)        WD_PEN=$_v ;;
            seriesmax)  WD_SERIESMAX=$_v ;;
            serieskey)  WD_SERIESKEY=$_v ;;
            pevent)     WD_PEVENTS="$WD_PEVENTS $_v" ;;
        esac
    done <<_WDEOF
$WD_STATS
_WDEOF

    # Normalize counters (awk output is numeric by construction; the
    # guard only protects against a future format drift).
    for _n in WD_TOTAL WD_BAD WD_OK WD_RESTART WD_R_PORT WD_R_TUNNEL \
              WD_R_OTHER WD_RL WD_L_PORT WD_L_TUNNEL WD_L_OTHER \
              WD_WANOUT WD_WANWL WD_PEN WD_SERIESMAX; do
        eval "_v=\$$_n"
        case "$_v" in
            ''|*[!0-9]*) eval "$_n=0" ;;
        esac
    done

    if [ "$WD_TOTAL" -eq 0 ]; then
        warn "Watchdog log is empty - the watchdog has not logged anything yet (tmpfs log is lost on reboot)"
    else
        if [ "$WD_BAD" -gt 0 ]; then
            info "$WD_BAD of $WD_TOTAL line(s) did not match the expected '<timestamp> <message>' format and were skipped"
        fi
        if [ -n "$WD_FIRST" ] && [ -n "$WD_LAST" ]; then
            info "Available history: $WD_FIRST -> $WD_LAST (rotation keeps ~300-500 lines; tmpfs: lost on reboot)"
        fi

        if [ -n "$WD_LAST" ]; then
            _now=$(date +%s)
            _last_e=$(date -d "$WD_LAST" +%s 2>/dev/null)
            case "$_last_e" in ''|*[!0-9]*) _last_e="" ;; esac
            if [ -z "$_last_e" ]; then
                info "Last entry: $WD_LAST (age cannot be determined)"
            else
                _age=$((_now - _last_e))
                if [ "$_age" -lt 0 ]; then
                    info "Last entry: $WD_LAST (timestamp is in the future - clock skew between log and this run?)"
                elif [ "$_age" -gt 1800 ]; then
                    warn "Log last updated $((_age / 60)) min ago (the watchdog runs every 5 min) - the watchdog may not be running or logging is broken"
                    info "Recommendation: if the log keeps aging, check cron scheduling and the watchdog installation (sections 8, cron)"
                else
                    info "Last entry: $WD_LAST ($((_age / 60)) min ago)"
                fi
            fi
        fi
        info "Healthy runs ([OK] All good) on record: $WD_OK"

        if [ "$WD_RESTART" -eq 0 ] && [ "$WD_RL" -eq 0 ]; then
            ok "No restarts or problem detections in the available history"
        else
            info "Problem events on record: $WD_RESTART restart(s), $WD_RL rate-limited run(s) (problem detected, restart suppressed by cooldown)"
            if [ $((WD_R_PORT + WD_L_PORT)) -gt 0 ]; then
                info "Category 'Mihomo port unreachable': $((WD_R_PORT + WD_L_PORT)) event(s)"
            fi
            if [ $((WD_R_TUNNEL + WD_L_TUNNEL)) -gt 0 ]; then
                info "Category 'Proxy tunnel check failed': $((WD_R_TUNNEL + WD_L_TUNNEL)) event(s)"
            fi
            if [ $((WD_R_OTHER + WD_L_OTHER)) -gt 0 ]; then
                info "Events with an unrecognized reason string: $((WD_R_OTHER + WD_L_OTHER))"
            fi
            if [ -n "$WD_LASTPROB" ]; then
                info "Last problem event: $WD_LASTPROB ($WD_LASTPROBK)"
            fi

            if [ -n "$WD_LASTOK" ]; then
                _e_ok=$(date -d "$WD_LASTOK" +%s 2>/dev/null)
                _e_prob=$(date -d "$WD_LASTPROB" +%s 2>/dev/null)
                case "$_e_ok" in ''|*[!0-9]*) _e_ok="" ;; esac
                case "$_e_prob" in ''|*[!0-9]*) _e_prob="" ;; esac
                if [ -n "$_e_ok" ] && [ -n "$_e_prob" ]; then
                    if [ "$_e_ok" -gt "$_e_prob" ]; then
                        info "Last healthy check after the last problem: $WD_LASTOK - recovered as of that check"
                    else
                        warn "No healthy check recorded after the last problem event ($WD_LASTPROB)"
                        WD_STAB="WARN"; WD_STAB_WHY="no confirmed recovery after the last problem"
                    fi
                else
                    info "Cannot compare the last healthy check and the last problem (unparseable timestamps)"
                fi
            else
                warn "No '[OK] All good' entry found at all - no confirmed healthy run in the available history"
                WD_STAB="WARN"; WD_STAB_WHY="no confirmed healthy run on record"
            fi

            if [ "$WD_SERIESMAX" -ge 3 ]; then
                warn "Repeated failures: $WD_SERIESMAX problem events within the same clock hour ($WD_SERIESKEY:00)"
                WD_STAB="WARN"; WD_STAB_WHY="repeated problem events within one hour"
            fi
        fi

        # Recent interventions: last 24h from this run's clock
        WD_RECENT=0; WD_RECENT_UNKNOWN=0
        _now=$(date +%s)
        set -- $WD_PEVENTS
        while [ $# -ge 3 ]; do
            _ts="$2 $3"; shift 3
            _e=$(date -d "$_ts" +%s 2>/dev/null)
            case "$_e" in ''|*[!0-9]*)
                WD_RECENT_UNKNOWN=$((WD_RECENT_UNKNOWN + 1))
                continue
                ;;
            esac
            if [ $((_now - _e)) -ge 0 ] && [ $((_now - _e)) -lt 86400 ]; then
                WD_RECENT=$((WD_RECENT + 1))
            fi
        done
        if [ "$WD_RECENT" -gt 0 ]; then
            warn "Watchdog interventions in the last 24h: $WD_RECENT problem event(s) (restarts + suppressed restarts)"
            WD_STAB="WARN"; WD_STAB_WHY="watchdog interventions in the last 24h"
        elif [ "$WD_PEN" -gt 0 ] && [ "$WD_RECENT_UNKNOWN" -eq "$WD_PEN" ]; then
            info "Problem events exist in history but their age cannot be determined (unparseable timestamps)"
        elif [ "$WD_PEN" -gt 0 ]; then
            ok "No watchdog interventions in the last 24h (older events on record: $WD_PEN)"
        fi

        # WAN problems are deliberately separated from Mihomo problems
        if [ "$WD_WANOUT" -gt 0 ]; then
            info "WAN full-outage runs on record: $WD_WANOUT (the watchdog deliberately does NOT restart Mihomo when WAN is down)"
        fi
        if [ "$WD_WANWL" -gt 0 ]; then
            info "Whitelist-fallback runs (primary WAN targets unavailable, whitelist checked): $WD_WANWL - a sign of a restricted network, not of a Mihomo fault"
        fi

        # Verdict: current process state is not enough on its own
        if [ "$WD_STAB" = "WARN" ]; then
            if [ "$MIHOMO_PROCS" -gt 0 ]; then
                warn "Historical stability: WARN - Mihomo is running now, but there was $WD_STAB_WHY; the current running state does not by itself prove stability"
            else
                warn "Historical stability: WARN - $WD_STAB_WHY (and the service is currently stopped)"
            fi
        else
            if [ "$WD_PEN" -gt 0 ]; then
                ok "Historical stability: OK - no interventions in the last 24h (older events on record; service currently $( [ "$MIHOMO_PROCS" -gt 0 ] && echo running || echo stopped))"
            else
                ok "Historical stability: OK - no watchdog interventions on record (service currently $( [ "$MIHOMO_PROCS" -gt 0 ] && echo running || echo stopped))"
            fi
        fi

        # Recommendations: facts above, interpretation here, never a root cause
        if [ $((WD_R_TUNNEL + WD_L_TUNNEL)) -gt 0 ] && [ $((WD_R_TUNNEL + WD_L_TUNNEL)) -ge $((WD_R_PORT + WD_L_PORT)) ]; then
            info "Recommendation: repeated 'Proxy tunnel check failed' events can have several causes (upstream server availability, DPI filtering, WAN quality) - the log does not identify which one; check the config/runtime separately"
        fi
        if [ $((WD_R_PORT + WD_L_PORT)) -gt 0 ] && [ $((WD_R_PORT + WD_L_PORT)) -gt $((WD_R_TUNNEL + WD_L_TUNNEL)) ]; then
            info "Recommendation: 'Mihomo port unreachable' means the watchdog found port $CONTRACT_PORT closed - the log does not show why (process exit, missing port in config, startup failure); compare with sections 3-6 above"
        fi
    fi
fi

# =========================================================
hdr "9. Network"
# =========================================================

if command -v nslookup >/dev/null 2>&1; then
    if nslookup github.com >/dev/null 2>&1; then
        ok "DNS resolution works (github.com)"
    else
        warn "DNS resolution FAILED (github.com) - network-level problem, separate from any local Mihomo state"
    fi
else
    info "nslookup unavailable - DNS check skipped"
fi

fetch_url "https://api.github.com/repos/$ENTWARE_REPO/releases/tags/latest"
if [ "$FETCH_RC" -ne 0 ] || [ -z "$FETCH_OUT" ]; then
    fetch_url "https://api.github.com/repos/$ENTWARE_REPO/releases/latest"
fi
if [ "$FETCH_RC" -eq 127 ]; then
    warn "No curl/wget - GitHub checks skipped (installs and updates would fail)"
    NET_GITHUB=0
elif [ -n "$FETCH_OUT" ]; then
    if printf '%s\n' "$FETCH_OUT" | grep -q '"API rate limit'; then
        warn "GitHub API rate-limited (unauthenticated limit) - package availability check skipped, try again later"
        NET_GITHUB=0
    else
        ok "GitHub API reachable - $ENTWARE_REPO release fetched"
        RELEASE_JSON=$FETCH_OUT
    fi
else
    warn "GitHub unreachable - install.sh and update-mihomo.sh cannot fetch packages (a running Mihomo keeps working)"
    NET_GITHUB=0
fi

fetch_url "https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/README.md"
if [ "$FETCH_RC" -eq 127 ]; then
    info "raw.githubusercontent.com check skipped (no curl/wget)"
elif [ -n "$FETCH_OUT" ]; then
    ok "raw.githubusercontent.com reachable (script delivery path for install.sh/update-watchdog.sh)"
else
    warn "raw.githubusercontent.com unreachable - curl|sh delivery of install.sh and updaters would fail"
fi

# =========================================================
hdr "10. entware-go package availability"
# =========================================================

if [ "$NET_GITHUB" -eq 0 ]; then
    info "Package availability check skipped (GitHub fetch failed above)"
elif [ -z "$IPK_SUFFIX" ]; then
    info "Package availability check skipped (architecture unknown)"
else
    FOUND_NAME=""
    if command -v jq >/dev/null 2>&1; then
        FOUND_NAME=$(printf '%s\n' "$RELEASE_JSON" | jq -r --arg suffix "$IPK_SUFFIX" '
            .assets[]?
            | select(.name | startswith("mihomo_") and endswith("_" + $suffix + ".ipk") and (contains("nohf") | not))
            | .name
        ' 2>/dev/null | head -n 1)
    fi
    if [ -z "$FOUND_NAME" ] || [ "$FOUND_NAME" = "null" ]; then
        FOUND_URL=$(printf '%s\n' "$RELEASE_JSON" \
            | grep -o '"browser_download_url": *"[^"]*mihomo_[^"]*_'${IPK_SUFFIX}'\.ipk"' \
            | grep -v "nohf" \
            | head -n 1 | sed 's/.*": *"//;s/"$//')
        [ -n "$FOUND_URL" ] && FOUND_NAME=$(basename "$FOUND_URL")
    fi

    case "$FOUND_NAME" in
        mihomo_*_${IPK_SUFFIX}.ipk) : ;;
        *) FOUND_NAME="" ;;
    esac
    case "$FOUND_NAME" in
        *nohf*) FOUND_NAME="" ;;
    esac

    if [ -n "$FOUND_NAME" ]; then
        ok "Package for $IPK_SUFFIX available in $ENTWARE_REPO:latest - $FOUND_NAME"
        AVAIL_VER=${FOUND_NAME#mihomo_}
        AVAIL_VER=${AVAIL_VER%_${IPK_SUFFIX}.ipk}
        case "$AVAIL_VER" in
            *-*)
                _rel=${AVAIL_VER##*-}
                case "$_rel" in
                    ''|*[!0-9]*) AVAIL_VER="" ;;
                    *) AVAIL_VER=${AVAIL_VER%-"$_rel"} ;;
                esac
                ;;
            *) AVAIL_VER="" ;;
        esac
        if [ -n "$BIN_VER" ] && [ -n "$AVAIL_VER" ]; then
            _cmp=$(ver_compare "$AVAIL_VER" "$BIN_VER")
            case "$_cmp" in
                gt) info "Update available on entware-go:latest: $BIN_VER -> $AVAIL_VER" ;;
                eq) info "Installed version matches entware-go:latest ($BIN_VER)" ;;
                lt) info "Available version ($AVAIL_VER) is older than installed ($BIN_VER) - update-mihomo.sh will skip (no automatic downgrade)" ;;
                *)  info "Versions cannot be reliably ordered ($AVAIL_VER vs $BIN_VER) - update-mihomo.sh will skip (downgrade protection)" ;;
            esac
        else
            info "Installed version unknown - availability comparison skipped"
        fi
    else
        NOHF_ONLY=$(printf '%s\n' "$RELEASE_JSON" | grep -o '"name": *"mihomo_nohf_[^"]*_'${IPK_SUFFIX}'\.ipk"' | head -n 1)
        warn "No mihomo package for suffix $IPK_SUFFIX in $ENTWARE_REPO:latest - the GitHub install/update path fails for this arch (install.sh Entware-feed fallback may still install an older version)"
        if [ -n "$NOHF_ONLY" ]; then
            info "Only a nohf variant exists for this suffix - it is deliberately never selected (softfloat build)"
        fi
    fi
fi

# =========================================================
# Summary
# =========================================================
echo
info "Doctor is read-only: no files, services or settings were changed."
echo
echo "=== Mihomo Doctor Summary ==="
printf 'OK:   %d\n' "$N_OK"
printf 'WARN: %d\n' "$N_WARN"
printf 'FAIL: %d\n' "$N_FAIL"
printf 'INFO: %d\n' "$N_INFO"
echo
if [ "$N_FAIL" -gt 0 ]; then
    echo "Overall status: FAIL"
    exit 2
elif [ "$N_WARN" -gt 0 ]; then
    echo "Overall status: WARN"
    exit 1
else
    echo "Overall status: OK"
    exit 0
fi
