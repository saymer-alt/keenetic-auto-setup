#!/usr/bin/env python3
"""Real processes + extracted production helpers; no router or network required.

Only /tmp and /opt paths are redirected. Init, pidof and ELF actions are stubs.
The full watchdog is also run with failed WAN transports. Shells are mandatory.
"""
from pathlib import Path
import argparse
import os
import shlex
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
FILES = ["update-mihomo.sh", "config-import.sh", "migrate-mihomo-mips.sh",
         "migrate-mihomo-tun.sh", "mihomo-watchdog.sh", "install.sh", "mihomo-doctor.sh"]
BEGIN = "# BEGIN MIHOMO LIFECYCLE LOCK v1"
END = "# END MIHOMO LIFECYCLE LOCK v1"


def source(name):
    return (ROOT / name).read_text()


def block(name):
    t = source(name)
    return t[t.index(BEGIN):t.index(END) + len(END)] + "\n"


def process_block(name):
    t = source(name)
    return t[t.index("# BEGIN MIHOMO PROCESS STATE v1"):t.index("# END MIHOMO PROCESS STATE v1")] + "\n"


def function(name, fn):
    t = source(name)
    a = t.index(fn + "() {")
    return t[a:t.index("\n}", a) + 2] + "\n"


def wait_file(path, proc):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if path.exists():
            return
        if proc.poll() is not None:
            raise AssertionError((proc.returncode, proc.stdout.read(), proc.stderr.read()))
        time.sleep(.01)
    raise AssertionError(f"barrier timed out: {path}")


class Fixture:
    def __init__(self, shell):
        self.shell = shell
        self.tmp = tempfile.TemporaryDirectory(prefix="mihomo-lock-test-")
        self.path = Path(self.tmp.name)
        self.children = []
        self.serial = 0
        (self.path / "opt/etc/init.d").mkdir(parents=True)
        (self.path / "opt/var/log").mkdir(parents=True)
        init = self.path / "init"
        init.write_text('''#!/bin/sh
echo "$1" >> "$LAB/actions"
case "$1" in stop) rm -f "$LAB/running" ;; start|restart) touch "$LAB/running" ;; esac
''')
        init.chmod(0o700)
        (self.path / "opt/etc/init.d/S99mihomo").symlink_to(init)

    def __enter__(self):
        return self

    def __exit__(self, *args):
        for p in self.children:
            if p.poll() is None:
                os.killpg(p.pid, signal.SIGKILL)
            p.wait()
        self.tmp.cleanup()

    def redirect(self, text):
        return text.replace("/tmp/", str(self.path) + "/").replace("/opt/", str(self.path / "opt") + "/")

    def script(self, name, body):
        return "#!/bin/sh\nset -e\n" + self.redirect(block(name)) + process_block(name) + f'''
LAB={shlex.quote(str(self.path))}; export LAB
cd "$LAB"
log() {{ :; }}
warn() {{ :; }}
error() {{ echo "$1" >&2; exit 1; }}
pidof() {{ [ -f "$LAB/running" ] || return 1; echo 4242; }}
sleep() {{ :; }}
INIT_SCRIPT="$LAB/init"
TMP_DIR="$LAB"; MIHOMO_DIR="$LAB/opt/bin"; STAGE_BIN="$LAB/stage"
STAGE_CONFIG="$LAB/config-stage"; BACKUP_STAGE="$LAB/config-backup-stage"
ROLLBACK_STAGE="$LAB/config-rollback-stage"; TEST_LOG="$LAB/test-log"
TMP_NEW="$LAB/new-config"; RUN_BACKUP="$LAB/run-backup"; VALIDATE_ERR="$LAB/validate"
GATE_HOME="$LAB/gate-home"
SERVICE_WAS_RUNNING=0; SERVICE_WAS_STOPPED=0; SERVICE_STOPPED_BY_US=0
REPLACEMENT_STARTED=0; REPLACEMENT_DONE=0; RECOVERY_FAILED=0
CONFIG_REPLACED=0; CONFIG_COMMIT_STARTED=0
''' + self.redirect(body)

    def run(self, name, body, rc=0):
        p = subprocess.run(self.shell, input=self.script(name, body), text=True,
                           capture_output=True, timeout=10)
        assert p.returncode == rc, (name, p.returncode, rc, p.stdout, p.stderr)
        return p

    def start(self, name, body, mode="stdin"):
        self.serial += 1
        script = self.script(name, body)
        args = self.shell[:]
        if mode == "file":
            path = self.path / f"child-{self.serial}.sh"
            path.write_text(script)
            args.append(str(path))
        p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True, start_new_session=True)
        self.children.append(p)
        if mode == "stdin":
            p.stdin.write(script)
        p.stdin.close()
        return p

    def actions(self):
        p = self.path / "actions"
        return p.read_text().splitlines() if p.exists() else []


HOLD = '''
ml_lifecycle_acquire || exit 7
trap 'ml_lifecycle_release || true' EXIT
trap 'exit 143' TERM
echo "$ML_ID" > ready
while [ ! -e go ]; do command sleep 0.02; done
'''


def test_ownership(shell):
    for name in FILES:
        for mode in ("file", "stdin"):
            with Fixture(shell) as f:
                p = f.start(name, HOLD, mode)
                wait_file(f.path / "ready", p)
                f.run(name, "ml_lifecycle_acquire || exit 7", 7)
                assert p.poll() is None
                (f.path / "go").touch()
                assert p.wait(timeout=5) == 0
                f.run(name, "ml_lifecycle_acquire\nml_lifecycle_release\n")
                assert not (f.path / "mihomo.maintenance").exists()
    print("[OK] file/stdin owners exclude contenders in all seven consumers")

    with Fixture(shell) as f:
        p = f.start(FILES[0], HOLD)
        wait_file(f.path / "ready", p)
        os.killpg(p.pid, signal.SIGKILL)
        p.wait()
        f.run(FILES[1], "ml_lifecycle_acquire\nml_lifecycle_release\n")
    print("[OK] dead owner and marker recovered without reboot")

    with Fixture(shell) as f:
        p = f.start(FILES[0], HOLD)
        wait_file(f.path / "ready", p)
        os.killpg(p.pid, signal.SIGKILL)
        p.wait()
        (f.path / "ready").unlink()
        contenders = [f.start(FILES[i % 4], HOLD) for i in range(8)]
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            live = [q for q in contenders if q.poll() is None]
            if (f.path / "ready").exists() and len(live) == 1:
                break
            time.sleep(.01)
        assert len(live) == 1
        assert all(q.poll() == 7 for q in contenders if q is not live[0])
        (f.path / "go").touch()
        assert live[0].wait(timeout=5) == 0
    print("[OK] simultaneous stale recoverers admit exactly one owner")

    with Fixture(shell) as f:
        f.run(FILES[0], '''
ml_identity
mkdir "$MIHOMO_LIFECYCLE_LOCK"
echo "$$ 999999999999999" > "$MIHOMO_LIFECYCLE_LOCK/owner"
echo "$$ 1 999999999999999" > "$MAINT_MARKER"
ml_lifecycle_acquire
[ "$(cat "$MIHOMO_LIFECYCLE_LOCK/owner")" = "$ML_ID" ]
ml_lifecycle_release
''')
        f.run(FILES[0], '''
mkdir "$MIHOMO_LIFECYCLE_LOCK"
echo 'malformed owner' > "$MIHOMO_LIFECYCLE_LOCK/owner"
ml_lifecycle_acquire || exit 7
''', 7)
    print("[OK] PID reuse/starttime mismatch reclaimed; malformed identity fails closed")

    for name in FILES[:4]:
        cleanup = "cleanup_tmp" if name in (FILES[0], FILES[2]) else "cleanup"
        with Fixture(shell) as f:
            p = f.start(name, function(name, cleanup) + '''
ml_lifecycle_acquire
echo "$ML_ID" > ready
trap 'CLEANUP; exit 143' TERM
while [ ! -e go ]; do command sleep 0.02; done
CLEANUP
'''.replace("CLEANUP", cleanup))
            wait_file(f.path / "ready", p)
            owner = f.path / "mihomo-lifecycle.lock.d/owner"
            marker = f.path / "mihomo.maintenance"
            owner.write_text("1 123456789\n")
            marker.write_text("1 2 123456789\n")
            p.send_signal(signal.SIGTERM)
            assert p.wait(timeout=5) == 143
            assert owner.read_text() == "1 123456789\n"
            assert marker.read_text() == "1 2 123456789\n"
    print("[OK] actual mutator cleanup on TERM preserves foreign lock and marker")

    with Fixture(shell) as f:
        f.run(FILES[0], '''
mkdir "$MIHOMO_LIFECYCLE_LOCK.guard"
ml_lifecycle_acquire || exit 7
''', 7)
        assert (f.path / "mihomo-lifecycle.lock.d.guard").is_dir()
    print("[OK] ambiguous metadata guard is never stolen")

    with Fixture(shell) as f:
        p = f.start(FILES[0], '''
ml_identity
ml_gate_enter "$MIHOMO_LIFECYCLE_LOCK"
touch ready
while :; do command sleep 0.02; done
''')
        wait_file(f.path / "ready", p)
        os.killpg(p.pid, signal.SIGKILL)
        p.wait()
        f.run(FILES[4], "ml_lifecycle_acquire || exit 7", 7)
    print("[OK] SIGKILL inside metadata critical section fails closed")


def service_functions(name):
    if name == FILES[0]:
        names = ["restore_stopped_service", "preflight_fail", "stop_mihomo_confirmed"]
        restore = "restore_stopped_service"
    elif name == FILES[1]:
        names = ["mihomo_running", "stop_mihomo_confirmed", "start_mihomo_confirmed", "restore_old_service"]
        restore = "restore_old_service"
    elif name == FILES[2]:
        names = ["stop_mihomo_confirmed", "restore_stopped_service"]
        restore = "restore_stopped_service"
    else:
        names = ["stop_mihomo_confirmed", "restore_service_if_needed"]
        restore = "restore_service_if_needed"
    return "".join(function(name, n) for n in names), restore


def transaction_body(name, hold=False):
    functions, restore = service_functions(name)
    return functions + '''
wait_for_contract_port() { return 0; }
wait_mihomo_confirmed() { pidof mihomo; }
ml_lifecycle_acquire || exit 7
trap 'ml_lifecycle_release || true' EXIT
if pidof mihomo; then SERVICE_WAS_RUNNING=1; stop_mihomo_confirmed; fi
''' + ('''touch ready
while [ ! -e go ]; do command sleep 0.02; done
''' if hold else '') + '''
# Fake ELF refuses a second runtime; stop/restore functions above are production.
[ ! -f running ] || exit 99
echo probe >> actions
''' + restore + "\n"


def test_interleaving(shell):
    for other in FILES[1:4]:
        with Fixture(shell) as f:
            (f.path / "running").touch()
            p = f.start(FILES[0], transaction_body(FILES[0], hold=True))
            wait_file(f.path / "ready", p)
            marker = (f.path / "mihomo.maintenance").read_text()
            f.run(other, transaction_body(other), 7)
            assert f.actions() == ["stop"], (other, f.actions())
            assert (f.path / "mihomo.maintenance").read_text() == marker
            (f.path / "go").touch()
            assert p.wait(timeout=5) == 0
            assert f.actions() == ["stop", "probe", "start"], f.actions()
            f.run(other, transaction_body(other))
            assert f.actions() == ["stop", "probe", "start"] * 2, (other, f.actions())
    print("[OK] updater x import/MIPS/TUN: stop/probe/restore recorded, loser takes no action")

    for name in FILES[:4]:
        with Fixture(shell) as f:
            f.run(name, transaction_body(name))
            assert f.actions() == ["probe"], (name, f.actions())
            assert not (f.path / "running").exists()
    print("[OK] previously stopped service stays stopped in every transaction fixture")

    with Fixture(shell) as f:
        p = f.start(FILES[0], function(FILES[0], "cleanup_tmp") + '''
ml_lifecycle_acquire
cleanup_tmp
touch released
while [ ! -e go ]; do command sleep 0.02; done
cleanup_tmp
''')
        wait_file(f.path / "released", p)
        q = f.start(FILES[1], HOLD.replace("go", "release-next"))
        wait_file(f.path / "ready", q)
        (f.path / "mihomo.backup.next").write_text("keep")
        marker = (f.path / "mihomo.maintenance").read_text()
        (f.path / "go").touch()
        assert p.wait(timeout=5) == 0
        assert (f.path / "mihomo.backup.next").read_text() == "keep"
        assert (f.path / "mihomo.maintenance").read_text() == marker
        (f.path / "release-next").touch()
        assert q.wait(timeout=5) == 0
    print("[OK] delayed duplicate updater cleanup preserves subsequent owner's state")


def watchdog_functions():
    return function(FILES[4], "can_restart") + '''
RESTART_STATE="$LAB/restart-state"; MIN_RESTART_INTERVAL=300
reset_healthy_heartbeat() { :; }
'''


def test_watchdog_doctor(shell):
    with Fixture(shell) as f:
        p = f.start(FILES[4], watchdog_functions() + '''
if ml_marker_busy; then exit 98; fi
touch checked
while [ ! -e decide ]; do command sleep 0.02; done
can_restart test || :
''')
        wait_file(f.path / "checked", p)
        q = f.start(FILES[0], HOLD)
        wait_file(f.path / "ready", q)
        (f.path / "decide").touch()
        assert p.wait(timeout=5) == 0
        assert f.actions() == []
        assert not (f.path / "restart-state").exists()
        (f.path / "go").touch()
        assert q.wait(timeout=5) == 0
        f.run(FILES[4], watchdog_functions() + "can_restart test\n")
        assert f.actions() == ["restart"]
    print("[OK] watchdog late restart excludes new maintenance; uncontended restart works")

    with Fixture(shell) as f:
        # Entire production watchdog: all WAN transports fail, no runtime action.
        text = f.redirect(source(FILES[4]))
        pre = f'LAB={shlex.quote(str(f.path))}; export LAB\n'
        pre += 'curl() { return 1; }; wget() { return 1; }; sleep() { :; }\n'
        p = subprocess.run(shell, input=pre + text, text=True, capture_output=True, timeout=10)
        assert p.returncode == 0, (p.returncode, p.stderr)
        assert f.actions() == []
        assert not (f.path / "mihomo_watchdog.restart").exists()
    print("[OK] full watchdog WAN outage never restarts")

    with Fixture(shell) as f:
        body = function(FILES[6], "doctor_mihomo_probe") + '''
observe_mihomo_procs() { MIHOMO_PROCS=1; }
run_with_timeout() { echo ELF >> actions; RUN_RC=0; }
doctor_mihomo_probe 15 fake -v
[ "$RUN_RC" -eq 125 ]
'''
        f.run(FILES[6], body)
        assert f.actions() == []
        p = f.start(FILES[0], HOLD)
        wait_file(f.path / "ready", p)
        f.run(FILES[6], body.replace("MIHOMO_PROCS=1", "MIHOMO_PROCS=0"))
        assert f.actions() == []
        (f.path / "go").touch()
        assert p.wait(timeout=5) == 0
        f.run(FILES[6], body.replace("MIHOMO_PROCS=1", "MIHOMO_PROCS=0").replace('"$RUN_RC" -eq 125', '"$RUN_RC" -eq 0'))
        assert f.actions() == ["ELF"]
    print("[OK] Doctor re-observes under lock; busy/running skips ELF without service mutation")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--shell", action="append", help="sh or 'busybox ash'; repeatable")
    args = parser.parse_args()
    reference = block(FILES[0])
    assert all(block(name) == reference for name in FILES), "embedded helpers drifted"
    for value in args.shell or ["sh", "busybox ash"]:
        shell = shlex.split(value)
        subprocess.run(shell + ["-c", ":"], check=True)
        print(f"=== {' '.join(shell)} ===", flush=True)
        test_ownership(shell)
        test_interleaving(shell)
        test_watchdog_doctor(shell)
    print("[OK] Lifecycle behavioural regressions passed")


if __name__ == "__main__":
    main()
