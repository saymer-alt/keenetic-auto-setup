#!/bin/sh
# lib.sh — shared lab helpers for Agent D independent QA.
# POSIX sh; runs under dash, BusyBox ash and bash. No network, no router.
#
# Independence rules implemented here:
# - production scripts are copied VERBATIM into a mktemp lab; only the
#   absolute prefixes /opt/ /tmp/ /sys/ are remapped to the lab root;
# - system tools are replaced by PATH shims (real files, no production edits);
# - everything lives under one mktemp root, removed on exit;
# - KAS_QA_MUTANT overrides the production source for mutation testing;
# - KAS_QA_ONLY=<case-id> runs a single case for focused mutation oracles.
# NOT_TESTED/BLOCKED never become PASS: qa_fail exits non-zero.

QA_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
QA_REPO_ROOT=$(CDPATH= cd -- "$QA_DIR/../.." && pwd -P)

QA_FAILURES=0
QA_CURRENT_CASE=""

qa_case() {
    QA_CURRENT_CASE=$1
    if [ -n "${KAS_QA_ONLY:-}" ] && [ "$KAS_QA_ONLY" != "$1" ]; then
        return 1
    fi
    echo "CASE $1"
    return 0
}

qa_check_rc() {
    # qa_check_rc <description> <rc> ; 0 is ok, anything else fails the case.
    if [ "$2" -ne 0 ]; then
        echo "FAIL $QA_CURRENT_CASE: $1 (rc=$2)"
        exit 1
    fi
}

qa_check_present() {
    # qa_check_present <description> <grep -c count> ; >=1 is ok.
    case "$2" in
        ''|*[!0-9]*) echo "FAIL $QA_CURRENT_CASE: $1 (non-numeric count '$2')"; exit 1 ;;
    esac
    [ "$2" -ge 1 ] || { echo "FAIL $QA_CURRENT_CASE: $1 (marker absent)"; exit 1; }
}

qa_check_absent() {
    # qa_check_absent <description> <grep -c count> ; 0 is ok.
    case "$2" in
        ''|*[!0-9]*) echo "FAIL $QA_CURRENT_CASE: $1 (non-numeric count '$2')"; exit 1 ;;
    esac
    [ "$2" -eq 0 ] || { echo "FAIL $QA_CURRENT_CASE: $1 (marker present x$2)"; exit 1; }
}

qa_check_eq() {
    # qa_check_eq <description> <actual> <expected>
    [ "$2" = "$3" ] || { echo "FAIL $QA_CURRENT_CASE: $1 (got '$2', want '$3')"; exit 1; }
}

qa_fail() {
    echo "FAIL $QA_CURRENT_CASE: $1"
    exit 1
}

qa_pass() {
    echo "PASS $QA_CURRENT_CASE"
}

qa_diag() {
    echo "  .. $1"
}

# ---------------------------------------------------------------------------
# Lab construction
# ---------------------------------------------------------------------------

qa_new_lab() {
    QA_LAB=$(mktemp -d "${TMPDIR:-/tmp}/kas-qa-independent.XXXXXX") || return 1
    mkdir -p "$QA_LAB/opt/var/log" "$QA_LAB/opt/etc/init.d" \
             "$QA_LAB/opt/bin" "$QA_LAB/opt/sbin" "$QA_LAB/tmp" "$QA_LAB/shim" \
             "$QA_LAB/sys/class/net" || return 1
    export KASLAB=$QA_LAB
    QA_PIDOF_SHIM=1
    trap qa_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    return 0
}

qa_cleanup() {
    # Preserve the pending exit status: dash/BusyBox ash replace the shell's
    # exit status with the status of the last command run inside the EXIT
    # trap, which would turn every FAIL into a green exit. Re-exit with the
    # captured status after the lab is removed.
    _qa_pending_rc=$?
    if [ -n "${KAS_QA_KEEP:-}" ]; then
        echo "KEEP: lab retained at ${QA_LAB:-unset}" >&2
        exit "$_qa_pending_rc"
    fi
    if [ -n "${QA_LAB:-}" ] && [ -f "$QA_LAB/fixture-daemons" ]; then
        while IFS= read -r _pid; do
            [ -n "$_pid" ] && kill "$_pid" 2>/dev/null
        done < "$QA_LAB/fixture-daemons"
    fi
    [ -n "${QA_LAB:-}" ] && rm -rf -- "$QA_LAB" 2>/dev/null
    KASLAB=""
    exit "$_qa_pending_rc"
}

qa_track_daemon() {
    echo "$1" >> "$QA_LAB/fixture-daemons"
}

qa_kill_daemons() {
    if [ -n "${QA_LAB:-}" ] && [ -f "$QA_LAB/fixture-daemons" ]; then
        while IFS= read -r _pid; do
            [ -n "$_pid" ] && kill "$_pid" 2>/dev/null
        done < "$QA_LAB/fixture-daemons"
        # Wait until the kernel releases the fixture binaries (Text-file-busy
        # protection) so the next case can recreate them.
        _i=0
        while [ "$_i" -lt 40 ]; do
            _alive=0
            while IFS= read -r _pid; do
                [ -n "$_pid" ] && [ -d "/proc/$_pid" ] && _alive=1
            done < "$QA_LAB/fixture-daemons"
            [ "$_alive" -eq 0 ] && break
            sleep 0.05 2>/dev/null || sleep 1
            _i=$((_i + 1))
        done
        rm -f "$QA_LAB/fixture-daemons"
    fi
    return 0
}

# Minimal curated tool directory: the harness PATH is shim+bins only, so the
# production tool-detection branches (netstat/ss, pidof, curl) see exactly the
# fixtures the scenario provides and never a host tool by accident.
# NOTE: pidof, netstat, ss, curl and sleep are deliberately NOT provided as
# real binaries here (sleep is always shimmed to keep runs fast).
qa_min_bins() {
    mkdir -p "$QA_LAB/bins" || return 1
    for _t in cat grep awk sed readlink date sha256sum wc tail head \
              mv rm mkdir rmdir cksum cut chmod cp cmp stat find dirname basename; do
        _p=$(command -v "$_t" 2>/dev/null) || return 1
        ln -sf "$_p" "$QA_LAB/bins/$_t" || return 1
    done
    return 0
}

qa_harness_path() {
    printf '%s\n' "$QA_LAB/shim:$QA_LAB/bins"
}

# Copy a production script verbatim with /opt/, /tmp/ and /sys/ remapped into
# the lab. Windows checkouts carry CRLF; the lab normalizes to the canonical
# LF form stored in git. Marker-based two-phase substitution prevents the lab
# path itself (which contains /tmp/) from being re-substituted.
# Shared verbatim remap: CRLF -> LF, then marker-based prefix substitution.
qa_remap_file() {
    tr -d '\r' < "$1" | sed -e 's|/opt/|@QAOPT@|g' \
                           -e 's|/tmp/|@QATMP@|g' \
                           -e 's|/sys/|@QASYS@|g' \
                           -e "s|@QAOPT@|$QA_LAB/opt/|g" \
                           -e "s|@QATMP@|$QA_LAB/tmp/|g" \
                           -e "s|@QASYS@|$QA_LAB/sys/|g" > "$2"
}

qa_assert_remap_complete() {
    # Replace the lab root with a plain word prefix (its own path legitimately
    # contains /tmp/), then any surviving /opt/ or /tmp/ prefix is a real miss.
    _qa_stripped=$(sed "s|$QA_LAB|QALABROOT|g" "$1") || return 1
    if printf '%s\n' "$_qa_stripped" | grep -qE '(^|[^a-zA-Z0-9_."'"'"'])/opt/'; then
        echo "FAIL lab: un-remapped /opt/ path in $1" >&2
        return 1
    fi
    if printf '%s\n' "$_qa_stripped" | grep -qE '(^|[^a-zA-Z0-9_."'"'"'])/tmp/'; then
        echo "FAIL lab: un-remapped /tmp/ path in $1" >&2
        return 1
    fi
    return 0
}

qa_stage_production() {
    _src=$1
    _dst=$2
    if [ -n "${KAS_QA_MUTANT:-}" ]; then
        # Mutation runner supplies the already-mutated lab copy verbatim.
        qa_remap_file "$KAS_QA_MUTANT" "$_dst" || return 1
    else
        qa_remap_file "$_src" "$_dst" || return 1
    fi
    qa_assert_remap_complete "$_dst"
}

# Extract a verbatim text region between two unique one-line markers
# (both inclusive). Fails hard when either anchor is missing or ambiguous.
qa_extract_region() {
    _file=$1
    _start=$2
    _end=$3
    awk -v s="$_start" -v e="$_end" '
        !f && index($0, s) { f = 1 }
        f { print }
        f && index($0, e) { exit }
    ' "$_file"
    _qa_er_rc=$?
    [ "$_qa_er_rc" -eq 0 ] || return 1
    # Ambiguity check: both markers must occur exactly once in the source.
    [ "$(grep -cF -- "$_start" "$_file")" -eq 1 ] || {
        echo "FAIL lab: start marker not unique: $_start" >&2; return 1; }
    [ "$(grep -cF -- "$_end" "$_file")" -eq 1 ] || {
        echo "FAIL lab: end marker not unique: $_end" >&2; return 1; }
    return 0
}

qa_write_shim() {
    # qa_write_shim <name> ; content on stdin. Executable file in lab PATH.
    _n=$1
    cat > "$QA_LAB/shim/$_n" || return 1
    chmod 0755 "$QA_LAB/shim/$_n" || return 1
}

qa_path() {
    # Lab PATH: shims first, then the real system.
    printf '%s\n' "$QA_LAB/shim:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
}

qa_run_lab() {
    # qa_run_lab <shell> <script> ; runs the lab script with lab env.
    _shell=$1
    _script=$2
    KASLAB="$QA_LAB" PATH="$(qa_path)" "$_shell" "$_script"
}

qa_read_log() {
    cat "$QA_LAB/opt/var/log/mihomo_watchdog.log" 2>/dev/null
}

# Entware package-init recipe bytes (documented production contract; the
# same constant the repo's init fixtures use). The lab pins the resolver
# digest to THIS fixture, because the real router blob is unavailable offline.
qa_entware_init_bytes() {
    printf '%s\n' \
'#!/bin/sh' \
'' \
'ENABLED=yes' \
'PROCS=mihomo' \
'ARGS="-d /opt/etc/$PROCS"' \
'PREARGS=""' \
'DESC=$PROCS' \
'PATH=/opt/sbin:/opt/bin:/opt/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
'' \
'. /opt/etc/init.d/rc.func'
}

qa_write_pinned_init() {
    # Writes the fixture init + rc.func, returns the fixture sha256 on stdout.
    # The recipe is kept verbatim EXCEPT the rc.func source line, which must
    # point into the lab (the resolver digest is pinned to the fixture bytes,
    # so the lab-internal path is covered by the same pinned-digest contract).
    _dst=$1
    qa_entware_init_bytes | sed "s|\. /opt/etc/init.d/rc.func|. $(dirname "$_dst")/rc.func|" > "$_dst" || return 1
    grep -q "rc.func" "$_dst" || return 1
    chmod 0755 "$_dst" || return 1
    cat > "$(dirname "$_dst")/rc.func" <<-'RCFUNC' || return 1
		#!/bin/sh
		# Lab rc.func: dispatch to a case-driven fixture implementation if present.
		for _cmd in start stop restart; do
		    [ "$1" = "$_cmd" ] || continue
		    if [ -x "$(dirname "$0")/fixture-impl.sh" ]; then
		        "$(dirname "$0")/fixture-impl.sh" "$@"
		        exit $?
		    fi
		    exit 0
		done
		exit 0
	RCFUNC
    chmod 0755 "$(dirname "$_dst")/rc.func" || return 1
    sha256sum < "$_dst" | cut -d' ' -f1
}

qa_pin_digest() {
    # qa_pin_digest <lab-copy> <fixture-sha256> ; swap the production digest
    # constant for the fixture digest (lab-only; same technique as the repo's
    # pin_fixture_init). Old digest constant:
    _old=06ba8f6abe78a3b109d2037c902d826085d5a4814cf4b4aca0d135b22a7b86d9
    sed -i "s|$_old|$2|g" "$1" || return 1
    grep -q "$2" "$1" || { echo "FAIL lab: digest pinning failed" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# Watchdog lab fixtures (shared by BB-WD and FI-WD suites)
# ---------------------------------------------------------------------------

QA_WD_WATCHDOG_SRC=""
QA_WD_LOGFILE=""

qa_wd_init_paths() {
    QA_WD_WATCHDOG_SRC=$1
    QA_WD_LOGFILE=$QA_LAB/opt/var/log/mihomo_watchdog.log
}

qa_wd_write_curl_shim() {
    # Classifies production probe shapes and answers from the scenario plan.
    # Every invocation is logged (class + rc) for probe-budget assertions.
    qa_write_shim curl <<'EOF'
#!/bin/sh
_kas_log="${KASLAB:?}/curl.log"
_rc=0
_class=other
for _a in "$@"; do
    case "$_a" in
        socks5h://*) _class=tunnel ;;
        http://127.0.0.1:7890) _class=port ;;
        --head) _class=wan ;;
    esac
done
case "$_class" in
    wan)
        _prev=""
        _t=""
        for _a in "$@"; do
            [ "$_prev" = "--head" ] && _t=$_a
            _prev=$_a
        done
        case "$_t" in
            http://cp.cloudflare.com|http://www.google.com) _grp=primary ;;
            *) _grp=whitelist ;;
        esac
        case "${KAS_WAN:-up}" in
            up)                        _rc=0 ;;
            down)                      _rc=7 ;;
            primary-down-whitelist-up) [ "$_grp" = primary ] && _rc=7 || _rc=0 ;;
            rc28)                      _rc=28 ;;
            *)                         _rc=7 ;;
        esac
        ;;
    port)  case "${KAS_PORT:-up}" in up) _rc=0 ;; *) _rc=7 ;; esac ;;
    tunnel)
        case "${KAS_TUNNEL:-ok}" in
            ok)    _rc=0 ;;
            fail)  _rc=7 ;;
            transient)
                _n=$(cat "$KASLAB/tunnel.count" 2>/dev/null || echo 0)
                _n=$((_n + 1))
                echo "$_n" > "$KASLAB/tunnel.count"
                [ "$_n" -eq 1 ] && _rc=7 || _rc=0
                ;;
            *)     _rc=7 ;;
        esac
        ;;
    other) _rc=0 ;;
esac
printf '%s %s\n' "$_class" "$_rc" >> "$_kas_log"
exit "$_rc"

# ---------------------------------------------------------------------------
# Watchdog lab fixtures (shared by BB-WD and FI-WD suites)
# ---------------------------------------------------------------------------

qa_wd_init_paths() {
    QA_WD_WATCHDOG_SRC=$1
    QA_WD_LOGFILE=$QA_LAB/opt/var/log/mihomo_watchdog.log
}

qa_wd_write_curl_shim() {
    # Classifies production probe shapes and answers from the scenario plan.
    # Every invocation is logged (class + rc) for probe-budget assertions.
    qa_write_shim curl <<'EOF'
#!/bin/sh
_kas_log="${KASLAB:?}/curl.log"
_rc=0
_class=other
for _a in "$@"; do
    case "$_a" in
        socks5h://*) _class=tunnel ;;
        http://127.0.0.1:7890) _class=port ;;
        --head) _class=wan ;;
    esac
done
case "$_class" in
    wan)
        _prev=""
        _t=""
        for _a in "$@"; do
            [ "$_prev" = "--head" ] && _t=$_a
            _prev=$_a
        done
        case "$_t" in
            http://cp.cloudflare.com|http://www.google.com) _grp=primary ;;
            *) _grp=whitelist ;;
        esac
        case "${KAS_WAN:-up}" in
            up)                        _rc=0 ;;
            down)                      _rc=7 ;;
            primary-down-whitelist-up) [ "$_grp" = primary ] && _rc=7 || _rc=0 ;;
            rc28)                      _rc=28 ;;
            *)                         _rc=7 ;;
        esac
        ;;
    port)  case "${KAS_PORT:-up}" in up) _rc=0 ;; *) _rc=7 ;; esac ;;
    tunnel)
        case "${KAS_TUNNEL:-ok}" in
            ok)    _rc=0 ;;
            fail)  _rc=7 ;;
            transient)
                _n=$(cat "$KASLAB/tunnel.count" 2>/dev/null || echo 0)
                _n=$((_n + 1))
                echo "$_n" > "$KASLAB/tunnel.count"
                [ "$_n" -eq 1 ] && _rc=7 || _rc=0
                ;;
            *)     _rc=7 ;;
        esac
        ;;
    other) _rc=0 ;;
esac
printf '%s %s\n' "$_class" "$_rc" >> "$_kas_log"
exit "$_rc"
EOF
}

qa_wd_write_sleep_shim() {
    qa_write_shim sleep <<'SHIMEOF'
#!/bin/sh
exit 0
SHIMEOF
}

qa_wd_write_pidof_shim() {
    qa_write_shim pidof <<'SHIMEOF'
#!/bin/sh
if [ -f "${KASLAB:?}/mihomo.pid" ]; then
    cat "$KASLAB/mihomo.pid"
    exit 0
fi
exit 1
SHIMEOF
}

qa_wd_write_fixture_init() {
    # Pinned package-init + rc.func dispatch; restart behavior in impl.
    # Control files: restart-fail (init rc=1), no-daemon (rc=0, no process).
    _digest=$(qa_write_pinned_init "$QA_LAB/opt/etc/init.d/S99mihomo") || return 1
    cat > "$QA_LAB/opt/etc/init.d/fixture-impl.sh" <<'IMPLEOF'
#!/bin/sh
_pidfile="${KASLAB:?}/mihomo.pid"
echo "call:$1" >> "${KASLAB:?}/init-calls.log"
case "$1" in
    start|restart)
        if [ -f "$_pidfile" ]; then
            kill "$(cat "$_pidfile")" 2>/dev/null
            rm -f "$_pidfile"
        fi
        if [ -f "${KASLAB:?}/restart-fail" ]; then
            echo "start failed" >&2
            exit 1
        fi
        if [ -f "${KASLAB:?}/no-daemon" ]; then
            echo started
            exit 0
        fi
        # /bin/sleep with an absolute path: the inherited lab PATH shims
        # sleep to a no-op, which would turn this loop into a busy spin.
        # stdout/stderr detached: a daemon holding the caller's capture pipe
        # open would make every command substitution wait forever.
        "${KASLAB:?}/opt/bin/mihomo" -c 'while :; do /bin/sleep 1; done' >/dev/null 2>&1 &
        echo $! > "$_pidfile"
        echo started
        exit 0
        ;;
    stop)
        if [ -f "$_pidfile" ]; then
            kill "$(cat "$_pidfile")" 2>/dev/null
            rm -f "$_pidfile"
        fi
        exit 0
        ;;
esac
exit 0
IMPLEOF
    chmod 0755 "$QA_LAB/opt/etc/init.d/fixture-impl.sh" || return 1
    printf '%s\n' "$_digest"
}

qa_wd_stage() {
    # $1 = production watchdog source; stages remapped copy + pinned digest.
    [ -n "$QA_WD_WATCHDOG_SRC" ] || return 1
    qa_stage_production "$QA_WD_WATCHDOG_SRC" "$QA_LAB/watchdog.sh" || return 1
    _digest=$(qa_wd_write_fixture_init) || return 1
    qa_pin_digest "$QA_LAB/watchdog.sh" "$_digest" || return 1
    qa_wd_write_curl_shim || return 1
    qa_wd_write_sleep_shim || return 1
    qa_wd_write_pidof_shim || return 1
    # The fixture mihomo binary the init spawns; /proc/<pid>/exe resolves to
    # this path, which the remapped identity checks expect.
    cp /bin/sh "$QA_LAB/opt/bin/mihomo" || return 1
    chmod 0755 "$QA_LAB/opt/bin/mihomo" || return 1
    return 0
}

qa_wd_run() {
    # One cron-style watchdog invocation.
    # $1 = shell spec, $2 = wan plan, $3 = port plan, $4 = tunnel plan
    _spec=$1
    _wan=$2
    _port=$3
    _tun=$4
    _old_ifs=$IFS
    IFS='|'
    # shellcheck disable=SC2086
    set -- $_spec
    IFS=$_old_ifs
    _cmd=$1
    shift
    KASLAB="$QA_LAB" PATH="$(qa_harness_path)" \
        KAS_WAN="$_wan" KAS_PORT="$_port" KAS_TUNNEL="$_tun" \
        "$_cmd" "$@" "$QA_LAB/watchdog.sh"
}

qa_wd_reset_state() {
    # Clean per-invocation state between runs (lab scripts persist).
    rm -f "$QA_WD_LOGFILE" "$QA_LAB/curl.log" "$QA_LAB/tunnel.count" \
          "$QA_LAB/mihomo.pid" "$QA_LAB/init-calls.log" \
          "$QA_LAB"/tmp/mihomo_watchdog.restart \
          "$QA_LAB"/tmp/mihomo_watchdog.healthy \
          "$QA_LAB"/tmp/mihomo_watchdog.incidents 2>/dev/null
    rm -rf "$QA_LAB/tmp/mihomo_watchdog.lock.d" \
           "$QA_LAB/tmp/mihomo-lifecycle.lock.d" 2>/dev/null
    return 0
}

qa_wd_incident_field() {
    # qa_wd_incident_field <class> <field-index 2..11>
    awk -v c="$1" -v f="$2" '$1 == c { print $f }' \
        "$QA_LAB/tmp/mihomo_watchdog.incidents" 2>/dev/null
}
