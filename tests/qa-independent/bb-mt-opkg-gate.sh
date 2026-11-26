#!/bin/sh
# BB-MT — MagiTrickle installer gate: claim-vs-reality at "opkg success".
#
# Black-box oracle over VERBATIM production text from install.sh at the
# current checkout: the MAGITRICKLE RUNTIME STATE block, the installer
# call-site (single managed start + read-only confirmation gate) and the
# final checkpoint re-read. Only /opt/ and /tmp/ prefixes are remapped into
# the mktemp lab; no production logic is rewritten, replaced or stubbed.
#
# Observable properties:
# - an opkg/init success is NEVER reported as "installed and started"
#   unless a real process is observable (real /proc, real fixture daemon);
# - a proven-stopped daemon yields MT_RUNTIME_STOPPED + MT_RUNTIME_ASYNC,
#   never a second start (init called exactly once) and never a claim;
# - an undeterminable state yields MT_RUNTIME_UNKNOWN: read-only, no start,
#   no claim;
# - the final checkpoint re-reads live state instead of trusting the gate;
# - the gate is read-only: it cannot abort the installer flow (|| true);
# - process identity alone never implies DNS listener health.
#
# Environment: WSL2 Ubuntu Linux, dash / BusyBox ash / bash. LOCAL_MOCK.
# FIELD and EMULATOR are NOT_TESTED by design (no router access).

QA_SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$QA_SELF_DIR/lib.sh"
set -u

# KAS_QA_MUTANT: path to a mutated verbatim copy (mutation runner only);
# empty means the pristine checkout source.
INSTALL_SH=${KAS_QA_MUTANT:-$QA_REPO_ROOT/install.sh}
[ -f "$INSTALL_SH" ] || { echo "BLOCKED bb-mt: install.sh not found at $QA_REPO_ROOT"; exit 2; }

qa_new_lab || { echo "BLOCKED bb-mt: cannot create lab"; exit 2; }
qa_min_bins || { echo "BLOCKED bb-mt: cannot build minimal bins"; exit 2; }

# ---------------------------------------------------------------------------
# Production text extraction (verbatim, path-remapped)
# ---------------------------------------------------------------------------
qa_extract_region "$INSTALL_SH" \
    '# BEGIN MAGITRICKLE RUNTIME STATE v1' \
    '# END MAGITRICKLE RUNTIME STATE v1' > "$QA_LAB/mt-block.raw" || {
    echo "BLOCKED bb-mt: MT runtime block not found/unique"; exit 2; }

qa_extract_region "$INSTALL_SH" \
    'log "Starting MagiTrickle..."' \
    'mt_confirm_after_start || true' > "$QA_LAB/mt-callsite.raw" || {
    echo "BLOCKED bb-mt: MT call site not found/unique"; exit 2; }

# Final checkpoint: from the magitrickle package check through the closing fi
# after the "package not installed" branch.
awk '
    !f && index($0, "if opkg list-installed 2>/dev/null | grep -q \"^magitrickle \"; then") { f = 1 }
    f { print }
    f && index($0, "check_fail \"MagiTrickle package not installed\"") { g = 1 }
    g && $0 ~ /^[[:space:]]*fi[[:space:]]*$/ { exit }
' "$INSTALL_SH" > "$QA_LAB/mt-checkpoint.raw" || {
    echo "BLOCKED bb-mt: checkpoint extraction failed"; exit 2; }
grep -q 'if mt_runtime_state; then' "$QA_LAB/mt-checkpoint.raw" || {
    echo "BLOCKED bb-mt: checkpoint extraction lost the runtime re-read"; exit 2; }
grep -q 'MT_RUNTIME_STOPPED' "$QA_LAB/mt-checkpoint.raw" || {
    echo "BLOCKED bb-mt: checkpoint extraction lost the stopped advice"; exit 2; }

for _name in mt-block mt-callsite mt-checkpoint; do
    qa_remap_file "$QA_LAB/$_name.raw" "$QA_LAB/$_name.sh" || {
        echo "BLOCKED bb-mt: remap failed for $_name"; exit 2; }
    qa_assert_remap_complete "$QA_LAB/$_name.sh" || {
        echo "BLOCKED bb-mt: remap incomplete for $_name"; exit 2; }
done

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
qa_write_mt_init() {
    # MagiTrickle init fixture: records every invocation; rc per scenario.
    cat > "$QA_LAB/opt/etc/init.d/S99magitrickle" <<'EOF'
#!/bin/sh
echo "call:$1" >> "${KASLAB:?}/init-calls.log"
echo done
exit ${MT_INIT_RC:-0}
EOF
    chmod 0755 "$QA_LAB/opt/etc/init.d/S99magitrickle" || return 1
}

qa_write_mt_config() {
    # $1 = dnsProxy port value or "" for package default
    mkdir -p "$QA_LAB/opt/var/lib/magitrickle" || return 1
    if [ -n "$1" ]; then
        printf 'application:\n  dnsProxy:\n    port: %s\n  httpWeb:\n    port: 8080\n' "$1" \
            > "$QA_LAB/opt/var/lib/magitrickle/config.yaml" || return 1
    else
        printf 'application:\n  httpWeb:\n    port: 8080\n' \
            > "$QA_LAB/opt/var/lib/magitrickle/config.yaml" || return 1
    fi
}

qa_start_real_daemon() {
    # Real /proc-backed magitrickled: a shell copy running a sleep loop.
    # /proc/<pid>/exe resolves to the lab binary named magitrickled, so the
    # production /proc scan finds positive evidence without any stub. When a
    # daemon exists the scan returns running BEFORE the uncertain flag can
    # matter, so this is deterministic also without root privileges.
    cp /bin/sh "$QA_LAB/opt/bin/magitrickled" || return 1
    chmod 0755 "$QA_LAB/opt/bin/magitrickled" || return 1
    "$QA_LAB/opt/bin/magitrickled" -c 'while :; do sleep 1; done' >/dev/null 2>&1 &
    _pid=$!
    echo "$_pid" >> "$QA_LAB/fixture-daemons"
    _i=0
    while [ ! -d "/proc/$_pid" ] && [ "$_i" -lt 50 ]; do
        _i=$((_i + 1))
    done
    [ -d "/proc/$_pid" ] || return 1
}

qa_write_pidof_shim() {
    qa_write_shim pidof <<'EOF'
#!/bin/sh
if [ -f "${KASLAB:?}/pidof.rc" ]; then
    _rc=$(cat "$KASLAB/pidof.rc")
else
    _rc=1
fi
if [ -f "$KASLAB/pidof.out" ]; then
    cat "$KASLAB/pidof.out"
fi
exit "$_rc"
EOF
}

qa_write_netstat_shim() {
    qa_write_shim netstat <<'EOF'
#!/bin/sh
cat "${KASLAB:?}/netstat.out" 2>/dev/null
exit 0
EOF
}

qa_write_opkg_shim() {
    # opkg list-installed: package present (opkg success premise).
    qa_write_shim opkg <<'EOF'
#!/bin/sh
if [ "$1" = "list-installed" ]; then
    printf 'magitrickle - 1.0.0-1\n'
    exit 0
fi
exit 0
EOF
}

# Glue that install.sh provides around the extracted text. check_* record
# structured status lines so the outer script can assert on outcomes.
cat > "$QA_LAB/mt-glue.sh" <<'EOF'
log()  { echo "CLAIM: $*"; }
warn() { echo "WARN: $*"; }
err()  { echo "ERR: $*"; exit 1; }
check_ok()   { echo "STATUS:ok $*"; }
check_warn() { echo "STATUS:warn $*"; }
check_info() { echo "STATUS:info $*"; }
check_fail() { echo "STATUS:fail $*"; }
EOF

build_harness() {
    {
        cat "$QA_LAB/mt-glue.sh"
        echo 'sleep() { :; }'
        cat "$QA_LAB/mt-block.sh"
        echo ''
        cat "$QA_LAB/mt-callsite.sh"
        echo 'echo "AFTER-GATE-CONTINUED"'
        echo ''
        cat "$QA_LAB/mt-checkpoint.sh"
    } > "$QA_LAB/harness.sh" || return 1
}

run_harness() {
    # $1 = shell spec: "cmd" or "cmd|arg|arg"
    _spec=$1
    build_harness || { echo "BLOCKED bb-mt: harness build failed"; exit 2; }
    _old_ifs=$IFS
    IFS='|'
    # shellcheck disable=SC2086
    set -- $_spec
    IFS=$_old_ifs
    _cmd=$1
    shift
    KASLAB="$QA_LAB" PATH="$(qa_harness_path)" "$_cmd" "$@" "$QA_LAB/harness.sh"
}

shell_spec() {
    case "$1" in
        dash)    printf '/usr/bin/dash' ;;
        busybox) printf '/usr/bin/busybox|ash' ;;
        bash)    printf '/usr/bin/bash' ;;
        *)       printf '%s' "$1" ;;
    esac
}

SHELL_NAMES=${KAS_QA_SHELLS:-dash,busybox,bash}

for_each_shell() {
    # for_each_shell <callback> ; callback receives the shell name in $1.
    _cb=$1
    _s=$SHELL_NAMES
    while [ -n "$_s" ]; do
        _name=${_s%%,*}
        [ "$_name" = "$_s" ] && _s="" || _s=${_s#*,}
        "$_cb" "$_name" || return 1
    done
}

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

# --- BB-MT-1: opkg success + init start rc=0, daemon NEVER appears ---------
cb_mt_1() {
    _name=$1
    : > "$QA_LAB/init-calls.log"
    _spec=$(shell_spec "$_name")
    _out=$(run_harness "$_spec" 2>&1)
    _rc=$?
    qa_check_rc "$_name: harness exit 0 (installer flow continues)" "$_rc"
    qa_check_absent "$_name: no installed-and-started claim without a process" \
        "$(printf '%s\n' "$_out" | grep -cF 'installed and started')"
    qa_check_present "$_name: MT_RUNTIME_STOPPED reported at the gate" \
        "$(printf '%s\n' "$_out" | grep -cF 'MT_RUNTIME_STOPPED: MagiTrickle init start returned success')"
    qa_check_present "$_name: MT_RUNTIME_ASYNC explains the no-second-start rule" \
        "$(printf '%s\n' "$_out" | grep -cF 'MT_RUNTIME_ASYNC')"
    qa_check_present "$_name: final checkpoint re-read also reports stopped" \
        "$(printf '%s\n' "$_out" | grep -cF 'STATUS:warn MT_RUNTIME_STOPPED: magitrickled is not running at the final checkpoint')"
    qa_check_present "$_name: checkpoint keeps the guarded manual-start advice" \
        "$(printf '%s\n' "$_out" | grep -cF 'STATUS:info MT_RUNTIME_ASYNC')"
    _calls=$(grep -c 'call:start' "$QA_LAB/init-calls.log" 2>/dev/null || echo 0)
    qa_check_eq "$_name: exactly ONE managed start" "$_calls" "1"
    qa_check_present "$_name: gate did not abort the installer flow" \
        "$(printf '%s\n' "$_out" | grep -cF 'AFTER-GATE-CONTINUED')"
    qa_diag "$_name: stopped-at-success contract holds"
}

case_bb_mt_1() {
    qa_case "BB-MT-1/mt-stopped-at-opkg-success" || return 0
    qa_write_mt_init || qa_fail "cannot write init fixture"
    qa_write_mt_config "" || qa_fail "cannot write config fixture"
    qa_write_pidof_shim || qa_fail "cannot write pidof shim"
    qa_write_opkg_shim || qa_fail "cannot write opkg shim"
    printf '1\n' > "$QA_LAB/pidof.rc"   # pidof: proven stopped (rc 1, no pids)
    : > "$QA_LAB/init-calls.log"
    for_each_shell cb_mt_1 || return 1
    qa_pass
}

# --- BB-MT-2: real daemon running, listener tool unavailable ---------------
cb_mt_2() {
    _name=$1
    : > "$QA_LAB/init-calls.log"
    _spec=$(shell_spec "$_name")
    _out=$(run_harness "$_spec" 2>&1)
    _rc=$?
    qa_check_rc "$_name: harness exit 0" "$_rc"
    qa_check_present "$_name: confirmed-running claim present (real process evidence)" \
        "$(printf '%s\n' "$_out" | grep -cF 'installed and started (magitrickled process confirmed; DNS listener check unavailable on this system)')"
    qa_check_present "$_name: checkpoint reports running with PIDs" \
        "$(printf '%s\n' "$_out" | grep -cF 'STATUS:ok MagiTrickle process running (magitrickled PID(s):')"
    qa_check_present "$_name: checkpoint listener note is honest about unavailability" \
        "$(printf '%s\n' "$_out" | grep -cF 'STATUS:info MagiTrickle DNS listener check skipped')"
    _calls=$(grep -c 'call:start' "$QA_LAB/init-calls.log" 2>/dev/null || echo 0)
    qa_check_eq "$_name: exactly ONE managed start" "$_calls" "1"
    qa_diag "$_name: real /proc-backed running state confirmed"
}

case_bb_mt_2() {
    qa_case "BB-MT-2/mt-running-listener-unavailable" || return 0
    qa_kill_daemons
    qa_write_mt_init || qa_fail "cannot write init fixture"
    qa_write_mt_config "" || qa_fail "cannot write config fixture"
    qa_write_opkg_shim || qa_fail "cannot write opkg shim"
    : > "$QA_LAB/init-calls.log"
    # Minimal bins only: no netstat, no ss, no pidof -> production must take
    # the /proc scan path (finds the daemon) and the listener rc=2 branch.
    rm -f "$QA_LAB/shim/pidof" "$QA_LAB/shim/netstat"
    qa_start_real_daemon || qa_fail "cannot start real fixture daemon"
    for_each_shell cb_mt_2 || return 1
    qa_pass
}

# --- BB-MT-3: running daemon + listener confirmed on configured port -------
cb_mt_3() {
    _name=$1
    : > "$QA_LAB/init-calls.log"
    _spec=$(shell_spec "$_name")
    _out=$(run_harness "$_spec" 2>&1)
    _rc=$?
    qa_check_rc "$_name: harness exit 0" "$_rc"
    qa_check_present "$_name: claim confirms DNS listener on the CONFIGURED port 9001" \
        "$(printf '%s\n' "$_out" | grep -cF 'installed and started (magitrickled running, DNS listener on port 9001 confirmed)')"
    qa_check_present "$_name: checkpoint confirms listener on 9001" \
        "$(printf '%s\n' "$_out" | grep -cF 'STATUS:ok MagiTrickle DNS listener on port 9001 confirmed')"
    _calls=$(grep -c 'call:start' "$QA_LAB/init-calls.log" 2>/dev/null || echo 0)
    qa_check_eq "$_name: exactly ONE managed start" "$_calls" "1"
    qa_diag "$_name: effective config port honored end-to-end"
}

case_bb_mt_3() {
    qa_case "BB-MT-3/mt-running-listener-confirmed" || return 0
    qa_kill_daemons
    qa_write_mt_init || qa_fail "cannot write init fixture"
    qa_write_mt_config "9001" || qa_fail "cannot write config fixture"
    qa_write_opkg_shim || qa_fail "cannot write opkg shim"
    qa_write_netstat_shim || qa_fail "cannot write netstat shim"
    printf 'tcp 0 0 127.0.0.1:9001 0.0.0.0:* LISTEN\n' > "$QA_LAB/netstat.out"
    : > "$QA_LAB/init-calls.log"
    qa_start_real_daemon || qa_fail "cannot start real fixture daemon"
    for_each_shell cb_mt_3 || return 1
    qa_pass
}

# --- BB-MT-4: running daemon but DNS port NOT listening --------------------
cb_mt_4() {
    _name=$1
    : > "$QA_LAB/init-calls.log"
    _spec=$(shell_spec "$_name")
    _out=$(run_harness "$_spec" 2>&1)
    _rc=$?
    qa_check_rc "$_name: harness exit 0" "$_rc"
    qa_check_absent "$_name: NO installed-and-started claim without a listener" \
        "$(printf '%s\n' "$_out" | grep -cF 'installed and started')"
    qa_check_present "$_name: MT_LISTENER_MISSING warn at the gate" \
        "$(printf '%s\n' "$_out" | grep -cF 'MT_LISTENER_MISSING: magitrickled is running but DNS port 3553 is not listening')"
    qa_check_present "$_name: checkpoint also warns listener missing" \
        "$(printf '%s\n' "$_out" | grep -cF 'STATUS:warn MT_LISTENER_MISSING: MagiTrickle DNS port 3553 is not listening')"
    qa_check_present "$_name: process still reported running at checkpoint" \
        "$(printf '%s\n' "$_out" | grep -cF 'STATUS:ok MagiTrickle process running')"
    _calls=$(grep -c 'call:start' "$QA_LAB/init-calls.log" 2>/dev/null || echo 0)
    qa_check_eq "$_name: exactly ONE managed start" "$_calls" "1"
    qa_diag "$_name: process identity alone never implies DNS health"
}

case_bb_mt_4() {
    qa_case "BB-MT-4/mt-running-listener-missing" || return 0
    qa_kill_daemons
    qa_write_mt_init || qa_fail "cannot write init fixture"
    qa_write_mt_config "" || qa_fail "cannot write config fixture"
    qa_write_opkg_shim || qa_fail "cannot write opkg shim"
    qa_write_netstat_shim || qa_fail "cannot write netstat shim"
    printf 'tcp 0 0 127.0.0.1:9999 0.0.0.0:* LISTEN\n' > "$QA_LAB/netstat.out"
    : > "$QA_LAB/init-calls.log"
    qa_start_real_daemon || qa_fail "cannot start real fixture daemon"
    for_each_shell cb_mt_4 || return 1
    qa_pass
}

# --- BB-MT-5: pidof returns garbage -> UNKNOWN, read-only, no claim --------
cb_mt_5() {
    _name=$1
    : > "$QA_LAB/init-calls.log"
    _spec=$(shell_spec "$_name")
    _out=$(run_harness "$_spec" 2>&1)
    _rc=$?
    qa_check_rc "$_name: harness exit 0" "$_rc"
    qa_check_present "$_name: MT_RUNTIME_UNKNOWN reported at the gate" \
        "$(printf '%s\n' "$_out" | grep -cF 'MT_RUNTIME_UNKNOWN: magitrickled process state cannot be determined')"
    qa_check_absent "$_name: no claim on unknown state" \
        "$(printf '%s\n' "$_out" | grep -cF 'installed and started')"
    qa_check_present "$_name: checkpoint reports UNKNOWN too" \
        "$(printf '%s\n' "$_out" | grep -cF 'STATUS:warn MT_RUNTIME_UNKNOWN: magitrickled process state cannot be determined')"
    _calls=$(grep -c 'call:start' "$QA_LAB/init-calls.log" 2>/dev/null || echo 0)
    qa_check_eq "$_name: exactly ONE managed start, unknown never triggers a start" "$_calls" "1"
    qa_diag "$_name: unknown is never absence and never a claim"
}

case_bb_mt_5() {
    qa_case "BB-MT-5/mt-unknown-read-only" || return 0
    qa_kill_daemons
    qa_write_mt_init || qa_fail "cannot write init fixture"
    qa_write_mt_config "" || qa_fail "cannot write config fixture"
    qa_write_pidof_shim || qa_fail "cannot write pidof shim"
    qa_write_opkg_shim || qa_fail "cannot write opkg shim"
    printf 'garbage\n' > "$QA_LAB/pidof.out"
    printf '0\n' > "$QA_LAB/pidof.rc"
    : > "$QA_LAB/init-calls.log"
    for_each_shell cb_mt_5 || return 1
    qa_pass
}

# ---------------------------------------------------------------------------
case_bb_mt_1
case_bb_mt_2
case_bb_mt_3
case_bb_mt_4
case_bb_mt_5

qa_kill_daemons
echo "ALL-PASS bb-mt-opkg-gate"
exit 0
