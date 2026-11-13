#!/bin/sh
# BB/FI-TUN — migrate-mihomo-tun.sh: fail-closed rollback of the user YAML.
#
# Black-box oracle over the FULL production migrator (verbatim, path-remapped
# into the mktemp lab). Fixtures: a real user config.yaml (0600-class mode, a
# user data marker), a scripted mihomo binary (-v / -t), a real init script
# managing a REAL /proc-backed daemon, curl/pidof/sleep PATH shims. Signals
# are delivered by a real kill from an mv PATH shim standing in the
# interrupted-commit window (no production edit).
#
# Observable properties:
# - --check is strictly read-only (bytes, mode, no new files);
# - an already-migrated config is never rewritten;
# - mihomo -t failure aborts BEFORE commit: YAML byte+mode identical, service
#   restored, no backups, no temp leftovers;
# - SIGTERM inside the atomic commit window rolls the user YAML back
#   byte+mode identical and never leaves a false RUNNING service;
# - a post-commit port-busy verification failure rolls the user YAML back,
#   restores the previous service state and cleans every artifact;
# - when the rollback itself fails, the migrator fails CLOSED: honest
#   "Config recovery FAILED", the per-run backup is retained, the service is
#   NOT claimed running, exit code 1.
#
# Environment: WSL2 Ubuntu Linux, dash / BusyBox ash. LOCAL_MOCK.
# FIELD and EMULATOR are NOT_TESTED by design (no router access).

QA_SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$QA_SELF_DIR/lib.sh"
set -u

# KAS_QA_MUTANT: path to a mutated verbatim copy (mutation runner only).
TUN_SRC=${KAS_QA_MUTANT:-$QA_REPO_ROOT/migrate-mihomo-tun.sh}
[ -f "$TUN_SRC" ] || { echo "BLOCKED fi-tun: migrate-mihomo-tun.sh not found"; exit 2; }

SHELL_NAMES=${KAS_QA_SHELLS:-dash,busybox,bash}

USER_YAML='mixed-port: 7890
# USER-DATA-MARKER: this content must survive every failed migration
dns:
  enable: true
'

CONFIG_DIR_IN_CASE=""

shell_spec() {
    case "$1" in
        dash)    printf '/usr/bin/dash' ;;
        busybox) printf '/usr/bin/busybox|ash' ;;
        bash)    printf '/usr/bin/bash' ;;
        *)       printf '%s' "$1" ;;
    esac
}

for_each_shell() {
    _cb=$1
    _s=$SHELL_NAMES
    while [ -n "$_s" ]; do
        _name=${_s%%,*}
        [ "$_name" = "$_s" ] && _s="" || _s=${_s#*,}
        "$_cb" "$_name" || return 1
    done
}

new_case_lab() {
    qa_kill_daemons
    [ -n "${QA_LAB:-}" ] && chmod -R u+w "$QA_LAB" 2>/dev/null
    [ -n "${QA_LAB:-}" ] && rm -rf "$QA_LAB"
    qa_new_lab || { echo "BLOCKED fi-tun: cannot create lab"; exit 2; }
    qa_min_bins || { echo "BLOCKED fi-tun: cannot build bins"; exit 2; }
    CONFIG_DIR_IN_CASE=$QA_LAB/opt/etc/mihomo
    mkdir -p "$CONFIG_DIR_IN_CASE" || exit 2
    mkdir -p "$QA_LAB/sys/class/net" || exit 2
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
tun_write_user_config() {
    printf '%s\n' "$USER_YAML" > "$CONFIG_DIR_IN_CASE/config.yaml" || return 1
    chmod 0640 "$CONFIG_DIR_IN_CASE/config.yaml" || return 1
}

tun_write_mihomo_fixture() {
    # Scripted mihomo: -v prints the version, -t validates per KAS_VALIDATE.
    cat > "$QA_LAB/opt/bin/mihomo" <<'EOF'
#!/bin/sh
case "$1" in
    -v)
        printf 'Mihomo Meta 1.19.31 linux mips with gvisor\n'
        exit 0
        ;;
    -t)
        if [ "${KAS_VALIDATE:-ok}" = fail ]; then
            echo 'invalid dns: boom' >&2
            exit 1
        fi
        exit 0
        ;;
esac
echo "fixture usage error" >&2
exit 2
EOF
    chmod 0755 "$QA_LAB/opt/bin/mihomo" || return 1
}

tun_write_init() {
    # Real init managing a REAL live process. The TUN migrator has no
    # exe-identity check (pidof evidence only), so a long-lived /bin/sleep is
    # a faithful stand-in for the daemon: killable, /proc-visible, gone on
    # stop. The scripted mihomo fixture stays separate for -v/-t probes.
    cat > "$QA_LAB/opt/etc/init.d/S99mihomo" <<'EOF'
#!/bin/sh
_pidfile="${KASLAB:?}/mihomo.pid"
case "$1" in
    start|restart)
        if [ -f "$_pidfile" ]; then
            kill "$(cat "$_pidfile")" 2>/dev/null
            rm -f "$_pidfile"
        fi
        /bin/sleep 300 >/dev/null 2>&1 &
        echo $! > "$_pidfile"
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
EOF
    chmod 0755 "$QA_LAB/opt/etc/init.d/S99mihomo" || return 1
}

tun_write_shims() {
    # pidof: positive evidence from the pid file only.
    qa_write_shim pidof <<'PIDOFOK'
#!/bin/sh
if [ -f "${KASLAB:?}/mihomo.pid" ]; then
    cat "$KASLAB/mihomo.pid"
    exit 0
fi
exit 1
PIDOFOK
    # sleep: no-op (lab runs stay fast; the daemon uses /bin/sleep itself).
    qa_write_shim sleep <<'SLEEPOK'
#!/bin/sh
exit 0
SLEEPOK
    # curl: mixed-port probe (127.0.0.1:7890) per plan; logs every call.
    qa_write_shim curl <<'CURLOK'
#!/bin/sh
_rc=0
case " $* " in
    *"http://127.0.0.1:7890"*)
        [ "${KAS_PORT:-up}" = up ] || _rc=7
        ;;
    *) _rc=0 ;;
esac
printf 'curl %s\n' "$_rc" >> "${KASLAB:?}/curl.log"
exit "$_rc"
CURLOK
}

tun_write_mv_shim() {
    # Injection points around the real /bin/mv, trigger-file driven:
    # - mv-kill: SIGTERM to the migrator right after the atomic commit move
    #   (interrupted-commit window);
    # - mv-ro: the rollback restore move itself fails (rollback-failure path).
    # A chmod-based write-protection injection does not work here: the lab
    # runs as root, and root ignores write-permission bits on ext4.
    qa_write_shim mv <<'MVOKE'
#!/bin/sh
for _a in "$@"; do
    case "$_a" in
        *.tun-rollback.*)
            if [ -f "${KASLAB:?}/mv-ro" ]; then
                echo "mv: injected rollback failure" >&2
                exit 1
            fi
            ;;
    esac
done
/bin/mv "$@"
_rc=$?
for _a in "$@"; do
    case "$_a" in
        *.tun-tmp.*)
            [ -f "${KASLAB:?}/mv-kill" ] && kill -TERM "$PPID"
            ;;
    esac
done
exit "$_rc"
MVOKE
}

tun_start_daemon() {
    "$QA_LAB/opt/etc/init.d/S99mihomo" start
    _pid=$(cat "$QA_LAB/mihomo.pid")
    _i=0
    while [ ! -d "/proc/$_pid" ] && [ "$_i" -lt 50 ]; do
        _i=$((_i + 1))
    done
    [ -d "/proc/$_pid" ]
}

tun_stop_daemon() {
    "$QA_LAB/opt/etc/init.d/S99mihomo" stop
    return 0
}

tun_run() {
    # tun_run <shell spec> <check|apply> <validate plan> <port plan> <mv trig>
    _spec=$1
    _mode=$2
    _validate=$3
    _port=$4
    _mvtrig=$5
    _old_ifs=$IFS
    IFS='|'
    # shellcheck disable=SC2086
    set -- $_spec
    IFS=$_old_ifs
    _cmd=$1
    shift
    rm -f "$QA_LAB/curl.log" "$QA_LAB/mv-kill" "$QA_LAB/mv-ro"
    [ "$_mvtrig" = term ] && : > "$QA_LAB/mv-kill"
    [ "$_mvtrig" = ro ] && : > "$QA_LAB/mv-ro"
    if [ -f "$QA_LAB/mv-kill" ] || [ -f "$QA_LAB/mv-ro" ]; then
        tun_write_mv_shim
    fi
    if [ "$_mode" = check ]; then
        _arg=--check
    else
        _arg=""
    fi
    KASLAB="$QA_LAB" PATH="$(qa_harness_path)" \
        KAS_VALIDATE="$_validate" KAS_PORT="$_port" \
        "$_cmd" "$@" "$QA_LAB/tun.sh" $_arg
}

tun_stage() {
    qa_stage_production "$TUN_SRC" "$QA_LAB/tun.sh" || return 1
    tun_write_mihomo_fixture || return 1
    tun_write_init || return 1
    tun_write_shims || return 1
    return 0
}

tun_snapshot() {
    # Prints config checksum + mode + config-dir file list for comparisons.
    ( cd "$CONFIG_DIR_IN_CASE" &&
      sha256sum config.yaml 2>/dev/null | cut -d' ' -f1
      stat -c '%a' config.yaml 2>/dev/null
      ls -A | sort ) 2>/dev/null
}

tun_daemon_running() {
    [ -f "$QA_LAB/mihomo.pid" ] || return 1
    _p=$(cat "$QA_LAB/mihomo.pid")
    [ -d "/proc/$_p" ]
}

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

# --- BB-TUN-1: happy apply path with the service stopped --------------------
cb_tun_1() {
    _name=$1
    _spec=$(shell_spec "$_name")
    new_case_lab
    tun_stage || qa_fail "cannot stage TUN lab"
    tun_write_user_config || qa_fail "cannot write user config"
    _before=$(tun_snapshot)
    _out=$(tun_run "$_spec" apply ok up none 2>&1)
    _rc=$?
    qa_check_rc "$_name: apply exits 0" "$_rc"
    qa_check_present "$_name: [OK] Added project TUN block reported" \
        "$(printf '%s\n' "$_out" | grep -cF '[OK] Added project TUN block with device mitun0 and stack: mips')"
    grep -q '^tun:$' "$CONFIG_DIR_IN_CASE/config.yaml" || \
        qa_fail "$_name: config must contain the top-level tun: block"
    grep -q 'USER-DATA-MARKER' "$CONFIG_DIR_IN_CASE/config.yaml" || \
        qa_fail "$_name: user YAML content must survive the migration"
    qa_check_eq "$_name: config mode preserved (0640)" \
        "$(stat -c '%a' "$CONFIG_DIR_IN_CASE/config.yaml")" "640"
    _pre="$CONFIG_DIR_IN_CASE/config.yaml.pre-tun"
    [ -f "$_pre" ] || qa_fail "$_name: persistent pre-TUN backup must exist"
    printf '%s\n' "$USER_YAML" > "$QA_LAB/expect-orig"
    cmp -s "$_pre" "$QA_LAB/expect-orig" || \
        qa_fail "$_name: pre-TUN backup must hold the original bytes"
    tun_daemon_running && qa_fail "$_name: service was stopped before and must stay stopped (no false RUNNING)"
    [ -e "$QA_LAB/tmp/mihomo-lifecycle.lock.d" ] && \
        qa_fail "$_name: lifecycle lock must be released after exit"
    _left=$(ls -A "$CONFIG_DIR_IN_CASE" | grep -c '\.tun-')
    qa_check_eq "$_name: no .tun-* transaction leftovers" "$_left" "0"
    qa_diag "$_name: happy path adds TUN, preserves user YAML and service state"
}

case_tun_1() {
    qa_case "BB-TUN-1/apply-success-stopped-service" || return 0
    for_each_shell cb_tun_1 || return 1
    qa_pass
}

# --- BB-TUN-2: --check is strictly read-only --------------------------------
cb_tun_2() {
    _name=$1
    _spec=$(shell_spec "$_name")
    new_case_lab
    tun_stage || qa_fail "cannot stage TUN lab"
    tun_write_user_config || qa_fail "cannot write user config"
    tun_start_daemon || qa_fail "cannot start fixture daemon"
    _before=$(tun_snapshot)
    _out=$(tun_run "$_spec" check ok up none 2>&1)
    _rc=$?
    qa_check_rc "$_name: --check exits 0" "$_rc"
    qa_check_present "$_name: --check reports read-only intent" \
        "$(printf '%s\n' "$_out" | grep -cF '=== Mihomo TUN bootstrap migration check (read-only) ===')"
    qa_check_present "$_name: --check honestly skips the version probe while running" \
        "$(printf '%s\n' "$_out" | grep -cF 'Runtime version probe skipped: daemon running or lifecycle unavailable')"
    qa_check_eq "$_name: config bytes+mode+dir listing unchanged" \
        "$(tun_snapshot)" "$_before"
    [ -e "$QA_LAB/tmp/mihomo-lifecycle.lock.d" ] && \
        qa_fail "$_name: --check must release the lifecycle lock"
    qa_diag "$_name: --check never mutates anything"
}

case_tun_2() {
    qa_case "BB-TUN-2/check-strictly-read-only" || return 0
    for_each_shell cb_tun_2 || return 1
    qa_pass
}

# --- BB-TUN-3: already migrated -> nothing to add ----------------------------
cb_tun_3() {
    _name=$1
    _spec=$(shell_spec "$_name")
    new_case_lab
    tun_stage || qa_fail "cannot stage TUN lab"
    tun_write_user_config || qa_fail "cannot write user config"
    printf '\ntun:\n  enable: true\n  device: mitun0\n  stack: mips\n' >> "$CONFIG_DIR_IN_CASE/config.yaml"
    _before=$(tun_snapshot)
    _out=$(tun_run "$_spec" apply ok up none 2>&1)
    _rc=$?
    qa_check_rc "$_name: exits 0" "$_rc"
    qa_check_present "$_name: reports nothing-to-add" \
        "$(printf '%s\n' "$_out" | grep -cF '[OK] Top-level tun: already exists and mips is present - nothing to add.')"
    qa_check_eq "$_name: config untouched" "$(tun_snapshot)" "$_before"
    qa_diag "$_name: existing TUN config is never rewritten"
}

case_tun_3() {
    qa_case "BB-TUN-3/already-migrated-untouched" || return 0
    for_each_shell cb_tun_3 || return 1
    qa_pass
}

# --- FI-TUN-1: mihomo -t validation failure aborts before commit -------------
cb_tun_4() {
    _name=$1
    _spec=$(shell_spec "$_name")
    new_case_lab
    tun_stage || qa_fail "cannot stage TUN lab"
    tun_write_user_config || qa_fail "cannot write user config"
    tun_start_daemon || qa_fail "cannot start fixture daemon"
    _before=$(tun_snapshot)
    _out=$(tun_run "$_spec" apply fail up none 2>&1)
    _rc=$?
    [ "$_rc" -ne 0 ] || qa_fail "$_name: validation failure must exit non-zero"
    qa_check_present "$_name: honest untouched-config error" \
        "$(printf '%s\n' "$_out" | grep -cF '[ERROR] Candidate config failed mihomo -t; config untouched.')"
    qa_check_eq "$_name: user YAML bytes+mode+dir unchanged" \
        "$(tun_snapshot)" "$_before"
    [ -f "$CONFIG_DIR_IN_CASE/config.yaml.pre-tun" ] && \
        qa_fail "$_name: no persistent backup may exist when validation failed pre-commit"
    tun_daemon_running || qa_fail "$_name: running service must be restored after abort"
    [ -e "$QA_LAB/tmp/mihomo-lifecycle.lock.d" ] && \
        qa_fail "$_name: lifecycle lock must be released"
    qa_diag "$_name: validation failure leaves zero mutations"
}

case_tun_4() {
    qa_case "FI-TUN-1/validation-failure-aborts-clean" || return 0
    for_each_shell cb_tun_4 || return 1
    qa_pass
}

# --- FI-TUN-2: SIGTERM inside the atomic commit window -----------------------
cb_tun_5() {
    _name=$1
    _spec=$(shell_spec "$_name")
    new_case_lab
    tun_stage || qa_fail "cannot stage TUN lab"
    tun_write_user_config || qa_fail "cannot write user config"
    _before=$(tun_snapshot)
    _out=$(tun_run "$_spec" apply ok up term 2>&1)
    _rc=$?
    [ "$_rc" -ne 0 ] || qa_fail "$_name: interrupted commit must exit non-zero"
    qa_check_present "$_name: TERM reported honestly" \
        "$(printf '%s\n' "$_out" | grep -cF 'Received TERM - aborting migration.')"
    printf '%s\n' "$USER_YAML" > "$QA_LAB/expect-orig"
    cmp -s "$CONFIG_DIR_IN_CASE/config.yaml" "$QA_LAB/expect-orig" || \
        qa_fail "$_name: user YAML must be rolled back byte-identical"
    qa_check_eq "$_name: config mode restored (0640)" \
        "$(stat -c '%a' "$CONFIG_DIR_IN_CASE/config.yaml")" "640"
    _pre="$CONFIG_DIR_IN_CASE/config.yaml.pre-tun"
    [ -f "$_pre" ] || qa_fail "$_name: persistent pre-TUN backup must exist"
    cmp -s "$_pre" "$QA_LAB/expect-orig" || \
        qa_fail "$_name: pre-TUN backup must hold the original bytes"
    tun_daemon_running && qa_fail "$_name: service was stopped before and must stay stopped (no false RUNNING)"
    _left=$(ls -A "$CONFIG_DIR_IN_CASE" | grep -c '\.tun-')
    qa_check_eq "$_name: no .tun-* transaction leftovers" "$_left" "0"
    [ -e "$QA_LAB/tmp/mihomo-lifecycle.lock.d" ] && \
        qa_fail "$_name: lifecycle lock must be released"
    [ -e "$QA_LAB"/tmp/mihomo-tun-config.backup.* ] && \
        qa_fail "$_name: per-run backup must be removed after successful recovery"
    qa_diag "$_name: interrupted atomic commit rolls back cleanly"
}

case_tun_5() {
    qa_case "FI-TUN-2/sigterm-after-atomic-commit" || return 0
    for_each_shell cb_tun_5 || return 1
    qa_pass
}

# --- FI-TUN-3: port busy -> post-commit verification fails -> rollback -------
cb_tun_6() {
    _name=$1
    _spec=$(shell_spec "$_name")
    new_case_lab
    tun_stage || qa_fail "cannot stage TUN lab"
    tun_write_user_config || qa_fail "cannot write user config"
    tun_start_daemon || qa_fail "cannot start fixture daemon"
    printf '%s\n' "$USER_YAML" > "$QA_LAB/expect-orig"
    _out=$(tun_run "$_spec" apply ok down none 2>&1)
    _rc=$?
    [ "$_rc" -ne 0 ] || qa_fail "$_name: failed verification must exit non-zero"
    qa_check_present "$_name: honest verification-failure error" \
        "$(printf '%s\n' "$_out" | grep -cF 'Migration verification failed; restoring the current transaction on exit.')"
    cmp -s "$CONFIG_DIR_IN_CASE/config.yaml" "$QA_LAB/expect-orig" || \
        qa_fail "$_name: user YAML must be restored byte-identical"
    qa_check_eq "$_name: config mode restored (0640)" \
        "$(stat -c '%a' "$CONFIG_DIR_IN_CASE/config.yaml")" "640"
    tun_daemon_running || qa_fail "$_name: previously running service must be running again"
    _left=$(ls -A "$CONFIG_DIR_IN_CASE" | grep -c '\.tun-')
    qa_check_eq "$_name: no .tun-* transaction leftovers" "$_left" "0"
    [ -e "$QA_LAB"/tmp/mihomo-tun-config.backup.* ] && \
        qa_fail "$_name: per-run backup must be removed after successful recovery"
    [ -e "$QA_LAB/tmp/mihomo-lifecycle.lock.d" ] && \
        qa_fail "$_name: lifecycle lock must be released"
    qa_diag "$_name: port-busy verification failure rolls back and restores service"
}

case_tun_6() {
    qa_case "FI-TUN-3/port-busy-verification-rollback" || return 0
    for_each_shell cb_tun_6 || return 1
    qa_pass
}

# --- FI-TUN-4: rollback itself fails -> fail closed, backup retained ---------
cb_tun_7() {
    _name=$1
    _spec=$(shell_spec "$_name")
    new_case_lab
    tun_stage || qa_fail "cannot stage TUN lab"
    tun_write_user_config || qa_fail "cannot write user config"
    tun_start_daemon || qa_fail "cannot start fixture daemon"
    printf '%s\n' "$USER_YAML" > "$QA_LAB/expect-orig"
    _out=$(tun_run "$_spec" apply ok down ro 2>&1)
    _rc=$?
    [ "$_rc" -ne 0 ] || qa_fail "$_name: failed recovery must exit 1"
    qa_check_present "$_name: honest recovery-FAILED warning" \
        "$(printf '%s\n' "$_out" | grep -cF 'Config recovery FAILED; per-run backup retained at ')"
    grep -q '^tun:$' "$CONFIG_DIR_IN_CASE/config.yaml" || \
        qa_fail "$_name: with a failed rollback the committed config stays (honest broken state)"
    _rb=$(ls "$QA_LAB"/tmp/mihomo-tun-config.backup.* 2>/dev/null | head -n 1)
    [ -n "$_rb" ] || qa_fail "$_name: per-run backup must be retained for manual recovery"
    cmp -s "$_rb" "$QA_LAB/expect-orig" || \
        qa_fail "$_name: retained backup must hold the original user YAML bytes"
    tun_daemon_running && qa_fail "$_name: NO false RUNNING after a failed recovery"
    chmod -R u+w "$CONFIG_DIR_IN_CASE" 2>/dev/null
    qa_diag "$_name: rollback failure is reported and never faked as success"
}

case_tun_7() {
    qa_case "FI-TUN-4/rollback-failure-fail-closed" || return 0
    for_each_shell cb_tun_7 || return 1
    qa_pass
}

# ---------------------------------------------------------------------------
case_tun_1
case_tun_2
case_tun_3
case_tun_4
case_tun_5
case_tun_6
case_tun_7

qa_kill_daemons
echo "ALL-PASS fi-tun-rollback"
exit 0
