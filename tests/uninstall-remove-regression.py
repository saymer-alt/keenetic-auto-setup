#!/usr/bin/env python3
"""Transactional --remove engine: stateful dash/BusyBox fixtures.

Covers the full happy path, idempotent re-run, missing rollback cache,
foreign cron consumers, post-prepare drift, fault-injected resume, a
mid-step netfilter recovery and the relaxed ip global gate contract."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import tempfile

BASE = Path(__file__).resolve().parents[1]
SHELLS = [["sh"]]
if shutil.which("busybox"):
    SHELLS.append(["busybox", "ash"])

PROXY_350 = "    ip global 350"
PROXY_32767 = "    ip global 32767"

BASE_CONFIG = """interface Bridge0
    description Home
!
interface Proxy0
    description "mihomo t2s0"
    security-level public
{ip_global}
    proxy protocol socks5
    proxy upstream 127.0.0.1 7890
    proxy socks5-udp
    up
!
ip policy bypass_wa
    description bypass_wa
    permit global Proxy0
    no permit global GigabitEthernet1
!
dns-proxy
    intercept enable
!
"""

BASE_MANGLE = """-N _CUST_BYPASS_WA_
-A PREROUTING -m mark --mark 0x0 -j _CUST_BYPASS_WA_
-A _CUST_BYPASS_WA_ -p udp -m multiport --dports 1400,3478,3482 -j MARK --set-xmark 0xffffaaa/0xffffffff
-A _CUST_BYPASS_WA_ -p udp -m multiport --dports 1400,3478,3482 -j CONNMARK --save-mark
-A _CUST_BYPASS_WA_ -p udp -m multiport --dports 1400,3478,3482 -j RETURN
"""
# A foreign rule that must survive every removal untouched.
FOREIGN_RULE = "-A PREROUTING -i Bridge0 -j MARK --set-xmark 0x1/0xffffffff"

OWNED_CRON = "*/5 * * * * root /bin/sh /opt/etc/cron.5mins/mihomo_watchdog\n"
FOREIGN_CRON = "17 3 * * * root /opt/lab/foreign-job\n"

BASE_FILES = {
    "opt/etc/keenetic-auto-setup/ownership.v1": (
        "KAS_OWNERSHIP_V1\nowned|policy|bypass_wa\nenabled|dns|intercept\n"
        "owned|package|mihomo\nowned|proxy|Proxy0\nowned|repository|magitrickle.conf\n"
        "owned|package|magitrickle\nowned|hook|020-bypass_wa.sh\nowned|watchdog|binary\n"
        "owned|watchdog|wrapper\n"),
    "opt/etc/mihomo/config.yaml": "secret: TEST_SECRET_MUST_NOT_PRINT\nmixed-port: 7890\n",
    "opt/var/lib/magitrickle/config.yaml": "server: internal\n",
    "opt/etc/ndm/netfilter.d/020-bypass_wa.sh": "#!/bin/sh\n",
    "opt/bin/mihomo_watchdog.sh": "#!/bin/sh\n",
    "opt/etc/cron.5mins/mihomo_watchdog": "#!/bin/sh\n",
    "opt/etc/opkg/magitrickle.conf": "src/gz magitrickle https://example.invalid\n",
    "opt/etc/init.d/S99mihomo": "#!/bin/sh\n",
    "opt/etc/init.d/S99magitrickle": "#!/bin/sh\n",
}

NDMC = """#!/bin/sh
S=${KAS_FAKE_STATE:?}
case "$2" in
'show running-config') tr -d '\\r' < "$S/running-config" ;;
'show ip policy') grep -A4 '^ip policy' "$S/running-config" || true ;;
'no ip policy bypass_wa')
    awk '
        /^ip policy bypass_wa$/ { skip=1; next }
        skip && /^!/ { skip=0; next }
        skip { next }
        { print }
    ' "$S/running-config" > "$S/running-config.new" && mv "$S/running-config.new" "$S/running-config"
    ;;
'no interface Proxy0')
    awk '
        /^interface Proxy0$/ { skip=1; next }
        skip && /^!/ { skip=0; next }
        skip { next }
        { print }
    ' "$S/running-config" > "$S/running-config.new" && mv "$S/running-config.new" "$S/running-config"
    ;;
'system configuration save') echo 'system configuration save' >> "$S/ndmc.log" ;;
*) exit 40 ;;
esac
"""

IPTABLES = """#!/bin/sh
S=${KAS_FAKE_STATE:?}
spec="$*"
case "$spec" in
'-t mangle -S')
    cat "$S/mangle" ;;
'-t mangle -S _CUST_BYPASS_WA_')
    grep -q '^-N _CUST_BYPASS_WA_' "$S/mangle" || exit 1
    grep -E '^-N _CUST_BYPASS_WA_|^-A _CUST_BYPASS_WA_' "$S/mangle"
    ;;
'-t mangle -S PREROUTING')
    grep '^-A PREROUTING ' "$S/mangle"
    ;;
'-t mangle -X _CUST_BYPASS_WA_')
    grep -qx -- '-N _CUST_BYPASS_WA_' "$S/mangle" || exit 1
    grep -q '^-A _CUST_BYPASS_WA_ ' "$S/mangle" && exit 1
    grep -q ' -j _CUST_BYPASS_WA_$' "$S/mangle" && exit 1
    sed '/^-N _CUST_BYPASS_WA_$/d' "$S/mangle" > "$S/mangle.new" && mv "$S/mangle.new" "$S/mangle"
    ;;
'-t mangle -D '*)
    target=$(printf '%s' "$spec" | sed 's/^-t mangle -D /-A /')
    grep -Fxq -- "$target" "$S/mangle" || exit 1
    awk -v t="$target" '$0==t && !deleted {deleted=1; next} {print}' "$S/mangle" > "$S/mangle.new" && mv "$S/mangle.new" "$S/mangle"
    case "$target" in
        '-A _CUST_BYPASS_WA_ '*)
            if [ -n "${KAS_KILL_AFTER_RULE:-}" ]; then kill "-$KAS_KILL_AFTER_RULE" "$PPID"; fi ;;
    esac
    ;;
*) exit 40 ;;
esac
"""

OPKG = """#!/bin/sh
S=${KAS_FAKE_STATE:?}
case "$1" in
list-installed) cat "$S/installed" ;;
remove)
    [ -s "$KAS_FAKE_STATE/download_broken" ] && exit 1
    grep -v "^$2 " "$S/installed" > "$S/installed.new" && mv "$S/installed.new" "$S/installed"
    ;;
download)
    if [ -s "$KAS_FAKE_STATE/download_broken" ]; then exit 1; fi
    ver=$(awk -v p="$2" '$1 == p { print $3 }' "$S/installed")
    [ -n "$ver" ] || exit 1
    printf 'fixture-ipk:%s:%s\\n' "$2" "$ver" > "${2}_${ver}_aarch64.ipk"
    ;;
*) exit 40 ;;
esac
"""

PIDOF = """#!/bin/sh
S=${KAS_FAKE_STATE:?}
[ -s "$S/pids/$1" ] || exit 1
cat "$S/pids/$1"
"""


def posix(p):
    """Env values for the shell scripts need a POSIX absolute form on Windows hosts."""
    p = str(p)
    if os.name != "nt":
        return p
    out = subprocess.run(["cygpath", "-u", p], capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else p


def setup(td, ip_global=PROXY_350, extra_cron="", foreign_mangle=True):
    root = td / "root"
    for rel, body in BASE_FILES.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body)
    (root / "tmp").mkdir(exist_ok=True)
    (root / ".kas-uninstall-fixture").write_text("KAS_UNINSTALL_TEST_FIXTURE_V1\n")
    crontab = "*/5 * * * * root /opt/bin/run-parts /opt/etc/cron.5mins\n" + OWNED_CRON
    if extra_cron:
        crontab += extra_cron
    (root / "opt/etc/crontab").write_text(crontab)

    state = td / "state"
    state.mkdir()
    (state / "running-config").write_text(BASE_CONFIG.format(ip_global=ip_global))
    mangle = BASE_MANGLE + (FOREIGN_RULE + "\n" if foreign_mangle else "")
    (state / "mangle").write_text(mangle)
    (state / "installed").write_text("mihomo - 1.19.33-2\nmagitrickle - 0.8.2-1\ncurl - 8.0.0\n")
    (state / "pids").mkdir()
    (state / "ndmc.log").write_text("")

    toolbin = td / "bin"
    toolbin.mkdir(exist_ok=True)
    # File/journal mutations are real; fixture tests do not model power-loss
    # durability. Avoid syncing every unrelated filesystem on the CI host.
    for name, script in {"ndmc": NDMC, "iptables": IPTABLES, "opkg": OPKG, "pidof": PIDOF,
                         "sync": "#!/bin/sh\nexit 0\n"}.items():
        p = toolbin / name
        p.write_text(script)
        p.chmod(0o755)
    env = os.environ | {
        "KAS_AUDIT_ROOT": posix(root),
        "KAS_SNAPSHOT_ROOT": posix(root),
        "KAS_TXN_FIXTURE_ROOT": posix(root),
        "KAS_FAKE_STATE": posix(state),
        "PATH": str(toolbin) + os.pathsep + os.environ["PATH"],
    }
    files = dict(BASE_FILES)
    files["opt/etc/crontab"] = crontab
    return root, state, files, env


def digest(root, state):
    h = hashlib.sha256()
    backups = root / "opt/kas-uninstall-backups"
    for base in (root, state):
        for path in sorted(base.rglob("*")):
            if backups in path.parents:
                continue  # transaction journal/snapshot is evidence, not system state
            if path.is_file():
                h.update(str(path.relative_to(base)).encode())
                h.update(path.read_bytes())
            elif path.is_dir():
                h.update(("D" + str(path.relative_to(base))).encode())
    return h.hexdigest()


def run(shell, env, *args, timeout=30):
    # BusyBox ash may prefer compiled applets to PATH. Explicit function
    # redirection makes injected pidof failures and fixture sync effective in
    # BOTH shells; $0 remains the real production path for sibling scripts.
    fixture_commands = '''
pidof() { "$KAS_FAKE_STATE/../bin/pidof" "$@"; }
sync() { "$KAS_FAKE_STATE/../bin/sync"; }
sleep() {
    if [ -x "$KAS_FAKE_STATE/../bin/sleep" ]; then "$KAS_FAKE_STATE/../bin/sleep" "$@";
    else /bin/sleep "$@"; fi
}
. "$0"
'''
    return subprocess.run(shell + ['-c', fixture_commands, str(BASE / args[0])] + list(args[1:]),
                          env=env, capture_output=True, text=True, timeout=timeout)


def prepared_snapshot(shell, root, state, env, want_cache=True):
    if not want_cache:
        (state / "download_broken").write_text("1")
    p = run(shell, env, "uninstall-snapshot.sh", "--create")
    assert p.returncode == 0, p.stderr
    name = next((root / "opt/kas-uninstall-backups").iterdir()).name
    p = run(shell, env, "uninstall-transaction-gate.sh", "--check", name)
    assert p.returncode == 0, p.stderr
    p = run(shell, env, "uninstall-transaction.sh", "--prepare", name)
    assert p.returncode == 0, p.stderr
    return name


for shell in SHELLS:
    # ---- 1. happy path -------------------------------------------------
    with tempfile.TemporaryDirectory(prefix="kas-uninstall-remove-happy-") as temp:
        td = Path(temp)
        root, state, files, env = setup(td, extra_cron=FOREIGN_CRON)
        foreign_config = ('interface Proxy9\n    proxy upstream 127.0.0.1 1081\n!\n'
                          'ip policy foreign\n    permit global Bridge0\n!\n')
        rcfile = state / "running-config"
        rcfile.write_text(rcfile.read_text() + foreign_config)
        name = prepared_snapshot(shell, root, state, env)
        assert (root / f"opt/kas-uninstall-backups/{name}/packages/MANIFEST").is_file()
        p = run(shell, env, "uninstall-transaction.sh", "--remove", name)
        assert p.returncode == 0, (p.stdout, p.stderr)
        assert "[PASS] KAS removal transaction complete" in p.stdout
        assert "TEST_SECRET_MUST_NOT_PRINT" not in p.stdout + p.stderr
        # owned resources gone
        assert not (root / "opt/etc/cron.5mins/mihomo_watchdog").exists()
        assert not (root / "opt/bin/mihomo_watchdog.sh").exists()
        assert not (root / "opt/etc/ndm/netfilter.d/020-bypass_wa.sh").exists()
        assert not (root / "opt/etc/keenetic-auto-setup/ownership.v1").exists()
        assert not (root / "opt/etc/opkg/magitrickle.conf").exists()
        installed = (state / "installed").read_text()
        assert "mihomo" not in installed and "magitrickle" not in installed
        assert "curl - 8.0.0" in installed, "foreign package must survive"
        # foreign cron line preserved, owned line gone
        cron = (root / "opt/etc/crontab").read_text()
        assert OWNED_CRON not in cron and "run-parts /opt/etc/cron.5mins" in cron
        assert FOREIGN_CRON in cron
        # foreign mangle rule preserved, KAS chain gone
        mangle = (state / "mangle").read_text()
        assert "_CUST_BYPASS_WA_" not in mangle and FOREIGN_RULE in mangle
        # ndmc teardown + persistence, DNS intercept kept
        rc = (state / "running-config").read_text()
        assert "ip policy bypass_wa" not in rc and "interface Proxy0" not in rc
        assert "intercept enable" in rc
        assert foreign_config in rc
        assert "system configuration save" in (state / "ndmc.log").read_text()
        journal = (root / f"opt/kas-uninstall-backups/{name}/transaction/journal.v1").read_text()
        assert journal.rstrip().endswith("complete")
        print("[PASS]", shell, "full removal transaction")

    # ---- 2. idempotent second remove -----------------------------------
    with tempfile.TemporaryDirectory(prefix="kas-uninstall-remove-idem-") as temp:
        td = Path(temp)
        root, state, files, env = setup(td)
        name = prepared_snapshot(shell, root, state, env)
        assert run(shell, env, "uninstall-transaction.sh", "--remove", name).returncode == 0
        before = digest(root, state)
        p = run(shell, env, "uninstall-transaction.sh", "--remove", name)
        assert p.returncode == 0 and "idempotent" in p.stdout, (p.stdout, p.stderr)
        assert digest(root, state) == before
        print("[PASS]", shell, "second --remove is an idempotent no-op")

    # ---- 3. uninstall.sh delegation + already-removed fast path ---------
    with tempfile.TemporaryDirectory(prefix="kas-uninstall-remove-deleg-") as temp:
        td = Path(temp)
        root, state, files, env = setup(td)
        name = prepared_snapshot(shell, root, state, env)
        p = run(shell, env, "uninstall.sh", "--remove", name)
        assert p.returncode == 0, (p.stdout, p.stderr)
        p = run(shell, env, "uninstall.sh", "--remove")
        assert p.returncode == 0 and "idempotent" in p.stdout
        print("[PASS]", shell, "uninstall.sh --remove delegation + idempotent audit")

    # ---- 4. missing rollback cache refuses BEFORE any mutation ----------
    with tempfile.TemporaryDirectory(prefix="kas-uninstall-remove-nocache-") as temp:
        td = Path(temp)
        root, state, files, env = setup(td)
        name = prepared_snapshot(shell, root, state, env, want_cache=False)
        before = digest(root, state)
        p = run(shell, env, "uninstall-transaction.sh", "--remove", name)
        assert p.returncode == 3 and "rollback cache" in p.stderr, (p.stdout, p.stderr)
        assert digest(root, state) == before, "refusal must not mutate anything"
        print("[PASS]", shell, "missing rollback cache refuses without changes")

    # ---- 5. foreign cron consumer blocks -------------------------------
    with tempfile.TemporaryDirectory(prefix="kas-uninstall-remove-fcron-") as temp:
        td = Path(temp)
        root, state, files, env = setup(td, extra_cron="*/3 * * * * root /opt/x/mihomo_watchdog_extra\n")
        name = prepared_snapshot(shell, root, state, env)
        before = digest(root, state)
        p = run(shell, env, "uninstall-transaction.sh", "--remove", name)
        assert p.returncode == 3, (p.stdout, p.stderr)
        assert digest(root, state) == before
        print("[PASS]", shell, "foreign mihomo_watchdog cron consumer blocks removal")

    # ---- 6. post-prepare drift fails closed ----------------------------
    with tempfile.TemporaryDirectory(prefix="kas-uninstall-remove-drift-") as temp:
        td = Path(temp)
        root, state, files, env = setup(td)
        name = prepared_snapshot(shell, root, state, env)
        before = digest(root, state)
        # user adds a permit to the owned policy after PREPARE
        rc = (state / "running-config").read_text().replace(
            "    permit global Proxy0\n",
            "    permit global Proxy0\n    permit global Bridge0\n")
        (state / "running-config").write_text(rc)
        p = run(shell, env, "uninstall-transaction.sh", "--remove", name)
        assert p.returncode == 3, (p.stdout, p.stderr)
        assert "BLOCKED" in p.stderr
        # the only permitted delta is the user's own edit; nothing else moved
        (state / "running-config").write_text(
            (state / "running-config").read_text().replace("    permit global Bridge0\n", ""))
        assert digest(root, state) == before
        print("[PASS]", shell, "post-prepare configuration drift fails closed")

    # ---- 7. fault injection + resume ------------------------------------
    for fault in ("cron", "watchdog", "netfilter", "hook", "services", "policy", "proxy", "opkg", "feed", "ledger"):
        with tempfile.TemporaryDirectory(prefix="kas-uninstall-remove-fault2-") as temp:
            td = Path(temp)
            root, state, files, env = setup(td)
            name = prepared_snapshot(shell, root, state, env)
            env2 = env | {"KAS_TXN_TEST_FAIL_AT": fault}
            p = run(shell, env2, "uninstall-transaction.sh", "--remove", name)
            assert p.returncode == 3 and "fault injection" in p.stderr, (fault, p.stdout, p.stderr)
            journal = (root / f"opt/kas-uninstall-backups/{name}/transaction/journal.v1").read_text()
            assert "interrupted" in journal
            p2 = run(shell, env, "uninstall-transaction.sh", "--remove", name)
            assert p2.returncode == 0 and "Resuming" in p2.stdout, (fault, p2.stdout, p2.stderr)
            assert not (root / "opt/etc/keenetic-auto-setup/ownership.v1").exists()
            assert "_CUST_BYPASS_WA_" not in (state / "mangle").read_text()
            print("[PASS]", shell, "resume after interruption at", fault)

    # ---- 8. mid-step netfilter recovery ---------------------------------
    with tempfile.TemporaryDirectory(prefix="kas-uninstall-remove-midstep-") as temp:
        td = Path(temp)
        root, state, files, env = setup(td)
        name = prepared_snapshot(shell, root, state, env)
        snapdir = root / f"opt/kas-uninstall-backups/{name}"
        # simulate a consistent mid-step crash: cron and watchdog finished,
        # the netfilter jump was detached, the chain removal did not happen
        (root / "opt/etc/crontab").write_text(
            (root / "opt/etc/crontab").read_text().replace(OWNED_CRON, ""))
        (root / "opt/etc/cron.5mins/mihomo_watchdog").unlink()
        (root / "opt/bin/mihomo_watchdog.sh").unlink()
        (state / "mangle").write_text(
            (state / "mangle").read_text().replace(
                "-A PREROUTING -m mark --mark 0x0 -j _CUST_BYPASS_WA_\n", ""))
        (snapdir / "transaction/journal.v1").write_text(
            f"KAS_UNINSTALL_JOURNAL_V1\nbegin {name}\nintent cron\ndone cron\nintent watchdog\ndone watchdog\nintent netfilter\ninterrupted (signal or abort)\n")
        p = run(shell, env, "uninstall-transaction.sh", "--remove", name)
        assert p.returncode == 0, (p.stdout, p.stderr)
        assert "_CUST_BYPASS_WA_" not in (state / "mangle").read_text()
        assert FOREIGN_RULE in (state / "mangle").read_text()
        print("[PASS]", shell, "mid-step netfilter state recovers by audit")

    # Every resume drift must BLOCK without another system mutation.
    for drift in ("policy", "proxy", "cron", "netfilter", "ledger", "yaml", "feed", "packages", "consumer"):
        with tempfile.TemporaryDirectory(prefix="kas-uninstall-resume-drift-") as temp:
            root, state, files, env = setup(Path(temp))
            name = prepared_snapshot(shell, root, state, env)
            p = run(shell, env | {"KAS_TXN_TEST_FAIL_AT": "hook"}, "uninstall-transaction.sh", "--remove", name)
            assert p.returncode == 3, p.stderr
            if drift == "policy":
                f=state/"running-config"; f.write_text(f.read_text().replace("    permit global Proxy0", "    permit global Bridge0"))
            elif drift == "proxy":
                f=state/"running-config"; f.write_text(f.read_text().replace("127.0.0.1 7890", "127.0.0.1 1081"))
            elif drift == "consumer":
                f=state/"running-config"; f.write_text(f.read_text()+"ip policy foreign\n    permit global Proxy0\n!\n")
            elif drift == "netfilter":
                f=state/"mangle"; f.write_text(f.read_text()+"-A PREROUTING -j ACCEPT\n")
            elif drift == "packages":
                f=state/"installed"; f.write_text(f.read_text().replace("1.19.33-2", "1.20.0-1"))
            else:
                rel={"cron":"opt/etc/crontab", "ledger":"opt/etc/keenetic-auto-setup/ownership.v1", "yaml":"opt/etc/mihomo/config.yaml", "feed":"opt/etc/opkg/magitrickle.conf"}[drift]
                f=root/rel; f.write_text(f.read_text()+"# user edit\n")
            before=digest(root,state)
            p=run(shell,env,"uninstall-transaction.sh","--remove",name)
            assert p.returncode==3 and "BLOCKED" in p.stderr, (drift,p.stdout,p.stderr)
            assert digest(root,state)==before, drift
            print("[PASS]",shell,"resume preserves drift:",drift)

    # Actual -X contract: a nonempty owned chain cannot be deleted.
    with tempfile.TemporaryDirectory(prefix="kas-uninstall-nonempty-") as temp:
        root,state,files,env=setup(Path(temp))
        original_mangle=(state/"mangle").read_text()
        (state/"mangle").write_text(original_mangle.replace(
            "-A PREROUTING -m mark --mark 0x0 -j _CUST_BYPASS_WA_\n", ""))
        before=digest(root,state)
        p=subprocess.run([str(Path(temp)/"bin/iptables"),"-t","mangle","-X","_CUST_BYPASS_WA_"],env=env)
        assert p.returncode!=0 and digest(root,state)==before
        (state/"mangle").write_text(original_mangle)
        name=prepared_snapshot(shell,root,state,env)
        p=run(shell,env|{"KAS_TXN_TEST_FAIL_AT":"netfilter-rule"},"uninstall-transaction.sh","--remove",name)
        assert p.returncode==3, p.stderr
        p=run(shell,env,"uninstall-transaction.sh","--remove",name)
        assert p.returncode==0,(p.stdout,p.stderr)
        print("[PASS]",shell,"realistic -X and mid-rule resume")

    for code in (127,2,0):
        with tempfile.TemporaryDirectory(prefix="kas-uninstall-unknown-") as temp:
            root,state,files,env=setup(Path(temp))
            name=prepared_snapshot(shell,root,state,env)
            # 0 with empty output is UNKNOWN, as are 2 and command-not-found.
            (Path(temp)/"bin/pidof").write_text(f"#!/bin/sh\nexit {code}\n")
            before=digest(root,state)
            p=run(shell,env,"uninstall-transaction.sh","--remove",name)
            assert p.returncode==3 and "UNKNOWN" in p.stderr,(p.stdout,p.stderr)
            assert digest(root,state)==before
            print("[PASS]",shell,"process UNKNOWN blocks before mutation",code)

    for fault in ("netfilter-jump","netfilter-rule-1","netfilter-rule-2","netfilter-rule-3"):
        with tempfile.TemporaryDirectory(prefix="kas-uninstall-rule-fault-") as temp:
            root,state,files,env=setup(Path(temp))
            name=prepared_snapshot(shell,root,state,env)
            p=run(shell,env|{"KAS_TXN_TEST_FAIL_AT":fault},"uninstall-transaction.sh","--remove",name)
            assert p.returncode==3,(fault,p.stdout,p.stderr)
            p=run(shell,env,"uninstall.sh","--remove",name)
            assert p.returncode==0,(fault,p.stdout,p.stderr)
            assert FOREIGN_RULE in (state/"mangle").read_text()
            print("[PASS]",shell,"resume after",fault)

    for extra in ("-A _CUST_BYPASS_WA_ -j ACCEPT", "-A OUTPUT -j _CUST_BYPASS_WA_",
                  "-A _CUST_BYPASS_WA_ -p udp -m multiport --dports 1400,3478,3482 -j MARK --set-xmark 0x1/0xffffffff"):
        with tempfile.TemporaryDirectory(prefix="kas-uninstall-foreign-rule-") as temp:
            root,state,files,env=setup(Path(temp))
            f=state/"mangle";f.write_text(f.read_text()+extra+"\n")
            p=run(shell,env,"uninstall-snapshot.sh","--create")
            assert p.returncode==0,p.stderr
            name=next((root/"opt/kas-uninstall-backups").iterdir()).name
            before=digest(root,state)
            p=run(shell,env,"uninstall-transaction.sh","--prepare",name)
            assert p.returncode==3,(p.stdout,p.stderr)
            assert digest(root,state)==before
            print("[PASS]",shell,"foreign chain rule/reference preserved")

    for daemon in ("mihomo","magitrickled"):
        with tempfile.TemporaryDirectory(prefix="kas-uninstall-running-") as temp:
            root,state,files,env=setup(Path(temp))
            name=prepared_snapshot(shell,root,state,env)
            (state/"pids"/daemon).write_text("42\n")
            # Init stop returns success but deliberately leaves a live PID.
            (Path(temp)/"bin/sleep").write_text("#!/bin/sh\nexit 0\n")
            (Path(temp)/"bin/sleep").chmod(0o755)
            original=(state/"running-config").read_bytes(),(state/"installed").read_bytes()
            p=run(shell,env,"uninstall-transaction.sh","--remove",name)
            assert p.returncode==3 and "did not stop" in p.stderr,(daemon,p.stdout,p.stderr)
            assert ((state/"running-config").read_bytes(),(state/"installed").read_bytes())==original
            print("[PASS]",shell,"RUNNING prevents policy/package removal",daemon)

    for signal in ("TERM", "KILL"):
        with tempfile.TemporaryDirectory(prefix="kas-uninstall-real-signal-") as temp:
            root,state,files,env=setup(Path(temp))
            name=prepared_snapshot(shell,root,state,env)
            p=run(shell,env|{"KAS_KILL_AFTER_RULE":signal},"uninstall-transaction.sh","--remove",name)
            assert p.returncode in (143,-9), (signal,p.returncode,p.stdout,p.stderr)
            journal=root/f"opt/kas-uninstall-backups/{name}/transaction/journal.v1"
            assert "intent netfilter" in journal.read_text() and "complete" not in journal.read_text()
            p=run(shell,env,"uninstall-transaction.sh","--remove",name)
            assert p.returncode==0,(signal,p.stdout,p.stderr)
            assert FOREIGN_RULE in (state/"mangle").read_text()
            print("[PASS]",shell,"real signal and durable-intent resume",signal)

    for damage in ("journal","snapshot","resurrection"):
        with tempfile.TemporaryDirectory(prefix="kas-uninstall-evidence-drift-") as temp:
            root,state,files,env=setup(Path(temp))
            name=prepared_snapshot(shell,root,state,env)
            p=run(shell,env|{"KAS_TXN_TEST_FAIL_AT":"hook"},"uninstall-transaction.sh","--remove",name)
            assert p.returncode==3
            snap=root/f"opt/kas-uninstall-backups/{name}"
            if damage=="journal":
                f=snap/"transaction/journal.v1";f.write_text(f.read_text()+"done proxy\n")
            elif damage=="snapshot":
                f=snap/"files/opt/etc/keenetic-auto-setup/ownership.v1";f.write_text(f.read_text()+"owned|proxy|Proxy9\n")
            else:
                (root/"opt/etc/ndm/netfilter.d/020-bypass_wa.sh").write_text("# foreign hook\n")
            before=digest(root,state)
            p=run(shell,env,"uninstall-transaction.sh","--remove",name)
            assert p.returncode==3,(damage,p.stdout,p.stderr)
            assert digest(root,state)==before
            print("[PASS]",shell,"invalid recovery evidence blocks:",damage)

    with tempfile.TemporaryDirectory(prefix="kas-uninstall-package-data-") as temp:
        root,state,files,env=setup(Path(temp))
        name=prepared_snapshot(shell,root,state,env)
        # Model real package conffile unlink semantics, including init files.
        tool=Path(temp)/"bin/opkg"
        tool.write_text(OPKG.replace('remove)\n', 'remove)\n    rm -f "$KAS_TXN_FIXTURE_ROOT/opt/etc/mihomo/config.yaml" "$KAS_TXN_FIXTURE_ROOT/opt/var/lib/magitrickle/config.yaml" "$KAS_TXN_FIXTURE_ROOT/opt/etc/init.d/S99mihomo" "$KAS_TXN_FIXTURE_ROOT/opt/etc/init.d/S99magitrickle"\n'))
        tool.write_text(tool.read_text().replace(
            '    [ -s "$KAS_FAKE_STATE/download_broken" ] && exit 1',
            '    rmdir "$KAS_TXN_FIXTURE_ROOT/opt/etc/mihomo" "$KAS_TXN_FIXTURE_ROOT/opt/var/lib/magitrickle" 2>/dev/null || true\n    [ -s "$KAS_FAKE_STATE/download_broken" ] && exit 1'))
        p=run(shell,env,"uninstall-transaction.sh","--remove",name)
        assert p.returncode==0,(p.stdout,p.stderr)
        for rel in ("opt/etc/mihomo/config.yaml","opt/var/lib/magitrickle/config.yaml"):
            assert (root/rel).read_text()==files[rel]
        print("[PASS]",shell,"OPKG unlinks restore exact user YAML")

# ---- 9. gate: relaxed ip global contract -------------------------------
for shell in SHELLS:
    for label, ip_global, expect_ok in (
            ("allocator 350", PROXY_350, True),
            ("allocator 32767 (Ported)", PROXY_32767, True),
            ("missing ip global", "", False),
            ("non-numeric ip global", "    ip global auto!", False)):
        with tempfile.TemporaryDirectory(prefix="kas-uninstall-gate-ig-") as temp:
            td = Path(temp)
            root, state, files, env = setup(td, ip_global=ip_global)
            p = run(shell, env, "uninstall-snapshot.sh", "--create")
            name = next((root / "opt/kas-uninstall-backups").iterdir()).name
            p = run(shell, env, "uninstall-transaction-gate.sh", "--check", name)
            assert (p.returncode == 0) == expect_ok, (label, p.stdout, p.stderr)
            print("[PASS]", shell, "gate ip global:", label)

    # duplicated ip global must block
    with tempfile.TemporaryDirectory(prefix="kas-uninstall-gate-ig2-") as temp:
        td = Path(temp)
        cfg = BASE_CONFIG.format(ip_global=PROXY_32767).replace(
            PROXY_32767, PROXY_32767 + "\n" + PROXY_350)
        root, state, files, env = setup(td)
        (state / "running-config").write_text(cfg)
        p = run(shell, env, "uninstall-snapshot.sh", "--create")
        name = next((root / "opt/kas-uninstall-backups").iterdir()).name
        p = run(shell, env, "uninstall-transaction-gate.sh", "--check", name)
        assert p.returncode == 3 and "duplicate ip global" in p.stderr, p.stderr
        print("[PASS]", shell, "gate ip global: duplicate blocked")

print("[PASS] uninstall --remove regression suite complete")
