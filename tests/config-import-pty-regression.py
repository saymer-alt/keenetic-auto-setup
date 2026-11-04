#!/usr/bin/env python3
"""Config Import interactive reader PTY regression.

Field failure (NC-1812, 2026-10-18): an SSH tty with ICRNL disabled delivers
keyboard Enter as CR, so the reader's `read` never receives a newline. The
typed skip command appears swallowed: the prompt is re-printed once, later
keystrokes only echo, and no skip message ever appears. BusyBox shell line
editing handles CR itself, which is why the outer shell prompt still worked.

Pinned contracts (introduced with the fix):
  - the reader enforces ICRNL on /dev/tty for its own duration and restores
    the saved terminal settings on every exit path (cleanup);
  - every delivered line is CR-stripped before matching, so CRLF terminals
    and pasted CRLF text cannot poison the skip match;
  - blank lines before the first YAML line still re-prompt;
  - s/S/skip/SKIP still skip; a YAML first line still goes to the paste mode;
  - skipping leaves config.yaml byte-identical and never touches the service;
  - pasted shell commands are still rejected without execution.

Issue #320 recovery contracts (R1–R5, end-to-end section): a missing/empty
current config on an installed KAS no longer blocks the import with the
misleading "Run setup.sh first" hint — a recovery import proceeds and never
overwrites an existing good config.yaml.bak with unusable current content;
an invalid nonempty current config keeps a good backup too; a valid current
config still becomes the new backup exactly as before.

PR #325 review contracts (R6–R12, end-to-end section): candidate validity
and rollback validity are separate. No backup is ever created from unusable
content (R6); an existing unusable backup is kept for manual inspection but
never trusted as a rollback source (R7); a post-commit failure rolls back
only to a validated backup, verifies the restore and restarts the service
(R8); without a validated backup the importer fails closed with accurate
wording and retains every available byte, never claiming "previous config
restored" (R9); a valid current config replaces a stale unusable backup
(R10); an interruption at any point never damages the last good copy (R11);
recovery works with the service running and restores it (R12).

PR #325 final-review contracts (R13–R17): an unusable nonempty current
config is preserved BYTE-FOR-BYTE in a clearly marked non-rollback
recovery artifact (config.yaml.invalid[.N]) before the candidate replaces
it (R13), survives a post-commit failure unchanged (R14), and an
unverifiable preservation aborts the import before any change (R15, the
integrity check cmp is unavailable). Collisions choose the next free
name; symlinks are never renamed onto and outside files are never touched
(R16). A normal valid-current import creates no recovery artifact and no
new warnings (R17).

PR #325 no-clobber race contracts (R18–R20): the publication of the
recovery artifact is an atomic create-if-absent (POSIX hard-link ln),
so a name claimed by a racing writer between the name probe and the
publication is never overwritten (R18; the racing writer is injected by
a fake chmod immediately before publication). An already-occupied
regular name keeps its bytes and the artifact takes the next suffix
(R19). When hard-link creation itself fails (unsupported filesystem,
I/O error), the import fails closed BEFORE replacing config.yaml (R20).

The reader is extracted from the production script (same approach as
tests/doctor-ubi-regression.sh): the PTY reproduces the real tty behavior,
but no router is contacted and nothing outside the temporary fixture tree
is written. The end-to-end section runs only as root on a machine without
an existing /opt/etc/mihomo/config.yaml (CI or a disposable sandbox); on a
live router or a non-root host it is skipped.
"""

import fcntl
import hashlib
import os
import pty
import re
import select
import shutil
import subprocess

from mihomo_init_fixture import write_package_init
import sys
import tempfile
import termios
import time

ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
SCRIPT = os.path.join(ROOT, "config-import.sh")

failures = []


def check(name, ok, detail=""):
    if ok:
        print("[OK] %s" % name)
    else:
        print("[FAIL] %s%s" % (name, (": " + detail) if detail else ""))
        failures.append(name)


def sh_shells():
    shells = [["/bin/sh"]]
    if os.path.exists("/bin/busybox"):
        shells.append(["/bin/busybox", "sh"])
    return shells


def run_pty(argv, script, steps, icrnl=True, timeout=10, env_extra=None,
            cwd=None, keep_master=False):
    """Drive `argv + [script]` on a real PTY.

    steps: list of ops
      ("send", bytes)              write bytes to the tty
      ("wait_pat", bytes)          wait until bytes appear in output
      ("sleep", seconds)           wait before the next step
    Returns (returncode_or_None, transcript_bytes, master_fd_or_None).
    returncode None means the child was still running at the deadline (hang).
    master_fd is returned only with keep_master=True (caller closes it).
    """
    master, slave = pty.openpty()
    attrs = termios.tcgetattr(master)
    if icrnl:
        attrs[0] |= termios.ICRNL
    else:
        attrs[0] &= ~termios.ICRNL
    termios.tcsetattr(master, termios.TCSANOW, attrs)

    def become_session_leader():
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

    env = dict(os.environ)
    env["NO_COLOR"] = "1"
    env["TERM"] = "dumb"
    if env_extra:
        env.update(env_extra)
    proc = subprocess.Popen(argv + [script], stdin=slave, stdout=slave,
                            stderr=slave, close_fds=True, cwd=cwd, env=env,
                            preexec_fn=become_session_leader)
    os.close(slave)

    buf = b""
    deadline = time.time() + timeout
    si = 0
    wait_until = 0.0
    while time.time() < deadline:
        ready, _, _ = select.select([master], [], [], 0.1)
        if ready:
            try:
                data = os.read(master, 65536)
            except OSError:
                data = b""
            if data:
                buf += data
        if si < len(steps):
            op, payload = steps[si]
            if op == "wait_pat":
                if payload in buf:
                    si += 1
                continue
            if op == "sleep":
                if wait_until == 0.0:
                    wait_until = time.time() + payload
                if time.time() >= wait_until:
                    si += 1
                    wait_until = 0.0
                continue
            if op == "send":
                os.write(master, payload)
                si += 1
                continue
        if proc.poll() is not None:
            ready, _, _ = select.select([master], [], [], 0.3)
            got = False
            if ready:
                try:
                    data = os.read(master, 65536)
                    if data:
                        buf += data
                        got = True
                except OSError:
                    pass
            if not got:
                if keep_master:
                    return proc.returncode, buf, master
                try:
                    os.close(master)
                except OSError:
                    pass
                return proc.returncode, buf, None
    if proc.poll() is None:
        try:
            os.write(master, b"\x03")
        except OSError:
            pass
        time.sleep(0.3)
        proc.kill()
        proc.wait()
    if keep_master:
        return None, buf, master
    try:
        os.close(master)
    except OSError:
        pass
    return None, buf, None


PROMPT = b"YAML (or s to skip): "
SKIPMSG = b"Config import skipped."


def reader_source_block():
    src = open(SCRIPT, encoding="utf-8").read()
    match = re.search(
        r'^    printf "YAML \(or s to skip\): " > /dev/tty\n.*?^    done\n',
        src, re.S | re.M)
    if not match:
        return None
    return match.group(0)


def build_reader_script(workdir):
    """Standalone script containing the production reader block verbatim."""
    block = reader_source_block()
    if block is None:
        return None
    path = os.path.join(workdir, "reader.sh")
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(
            "#!/bin/sh\n"
            "set -e\n"
            'CI_TTY_STTY_SAVE=""\n'
            'log() { printf "[config] %s\\n" "$1"; }\n'
            + block
            + 'printf "YAML_FIRST\\n" > /dev/tty\n')
    os.chmod(path, 0o755)
    return path


def test_reader_scenarios():
    with tempfile.TemporaryDirectory(prefix="kas-ci-pty-") as workdir:
        reader = build_reader_script(workdir)
        if reader is None:
            check("reader block extraction", False,
                  "interactive reader block not found in config-import.sh")
            return
        check("reader block extraction", True)

        for argv in sh_shells():
            shell_name = " ".join(argv)

            # T1 — THE field regression: ICRNL off, one queued LF (as from a
            # pasted command), then keyboard Enter (CR) with `s`, repeated.
            # Pre-fix this hung forever with no skip message.
            rc, out, _master = run_pty(
                argv, reader,
                [("send", b"\n"), ("wait_pat", PROMPT), ("sleep", 0.5),
                 ("send", b"s\r"), ("sleep", 0.6), ("send", b"s\r"),
                 ("sleep", 0.6), ("send", b"s\r"), ("sleep", 1.2)],
                icrnl=False)
            check("T1 icrnl-off keyboard CR skip (%s)" % shell_name,
                  rc == 0 and SKIPMSG in out,
                  "rc=%r" % (rc,))

            # T2 — ICRNL off, terminal sends CRLF: the delivered line is
            # "s\r" and must still skip (pre-fix it fell into paste mode).
            rc, out, _master = run_pty(
                argv, reader,
                [("wait_pat", PROMPT), ("sleep", 0.5), ("send", b"s\r\n"),
                 ("sleep", 1.5)],
                icrnl=False)
            check("T2 icrnl-off CRLF terminal skip (%s)" % shell_name,
                  rc == 0 and SKIPMSG in out, "rc=%r" % (rc,))

            # T3 — CR-strip fallback must not depend on stty: PATH with only
            # tr available, ICRNL off, CRLF delivery.
            binroot = os.path.join(
                workdir, "bin-%d-%s" % (os.getpid(), argv[-1]))
            os.makedirs(binroot, exist_ok=True)
            tr_target = os.path.join(binroot, "tr")
            if not os.path.exists(tr_target):
                os.symlink(shutil.which("tr"), tr_target)
            rc, out, _master = run_pty(
                argv, reader,
                [("wait_pat", PROMPT), ("sleep", 0.5), ("send", b"s\r\n"),
                 ("sleep", 1.5)],
                icrnl=False, env_extra={"PATH": binroot})
            check("T3 no-stty CR-strip fallback (%s)" % shell_name,
                  rc == 0 and SKIPMSG in out, "rc=%r" % (rc,))

            # T4 — blank-line tolerance still re-prompts and skips (ICRNL on).
            rc, out, _master = run_pty(
                argv, reader,
                [("send", b"\n\n"), ("wait_pat", PROMPT), ("sleep", 0.5),
                 ("send", b"s\n"), ("sleep", 1.5)],
                icrnl=True)
            check("T4 blank Enter tolerance then skip (%s)" % shell_name,
                  rc == 0 and SKIPMSG in out and out.count(PROMPT) >= 2,
                  "rc=%r" % (rc,))

            # T5 — direct skip variants.
            for token in (b"S\n", b"skip\n", b"SKIP\n"):
                rc, out, _master = run_pty(
                    argv, reader,
                    [("wait_pat", PROMPT), ("sleep", 0.4), ("send", token),
                     ("sleep", 1.5)],
                    icrnl=True)
                check("T5 skip token %r (%s)" % (token, shell_name),
                      rc == 0 and SKIPMSG in out, "rc=%r" % (rc,))

            # T6 — a real YAML first line still enters paste mode.
            rc, out, _master = run_pty(
                argv, reader,
                [("wait_pat", PROMPT), ("sleep", 0.4),
                 ("send", b"mixed-port: 7890\n"), ("sleep", 1.2)],
                icrnl=True)
            check("T6 YAML first line enters paste mode (%s)" % shell_name,
                  rc == 0 and b"YAML_FIRST" in out and SKIPMSG not in out,
                  "rc=%r" % (rc,))

def e2e_possible():
    """Full-script cases need a writable disposable /opt without a real KAS."""
    try:
        if os.geteuid() != 0:
            return False, "not root"
    except AttributeError:
        return False, "no euid"
    if os.path.exists("/opt/etc/mihomo/config.yaml"):
        return False, "existing /opt/etc/mihomo/config.yaml (real install?)"
    if any(os.path.lexists("/opt/etc/init.d/" + name)
           for name in ("S28mihomo", "S99mihomo", "rc.func")):
        return False, "existing Mihomo init or Entware rc.func"
    return True, ""


def test_e2e_full_script():
    ok, why = e2e_possible()
    if not ok:
        print("[SKIP] end-to-end full-script cases (%s)" % why)
        return

    created = []

    def ensure_dir(path):
        if not os.path.isdir(path):
            os.makedirs(path)
            created.append(path)

    for path in ("/opt", "/opt/sbin", "/opt/etc", "/opt/etc/init.d",
                 "/opt/etc/mihomo"):
        ensure_dir(path)

    fake_bin = "/opt/sbin/mihomo"
    fake_init = "/opt/etc/init.d/S99mihomo"
    calls_log = "/opt/etc/init.d/.fake-mihomo-calls"
    config_path = "/opt/etc/mihomo/config.yaml"
    backup_path = "/opt/etc/mihomo/config.yaml.bak"
    created.extend([fake_bin, fake_init, "/opt/etc/init.d/rc.func"])

    with open(fake_bin, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("#!/bin/sh\nexit 0\n")
    write_package_init(fake_init, '#!/bin/sh\nprintf "%s\\n" "$*" >> ' + calls_log
                 + "\nexit 0\n")
    os.chmod(fake_bin, 0o755)
    os.chmod(fake_init, 0o755)

    original_config = "mixed-port: 7890\nmode: rule\n"
    try:
        for argv in sh_shells():
            shell_name = " ".join(argv)

            # E1 — skip: config byte-identical, service never touched.
            with open(config_path, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(original_config)
            if os.path.exists(calls_log):
                os.remove(calls_log)
            rc, out, _master = run_pty(
                argv, SCRIPT,
                [("send", b"\n"), ("wait_pat", PROMPT), ("sleep", 0.5),
                 ("send", b"s\n"), ("sleep", 3.0)],
                icrnl=True)
            after = open(config_path, "rb").read()
            calls = b""
            if os.path.exists(calls_log):
                calls = open(calls_log, "rb").read()
            check("E1 skip leaves config identical (%s)" % shell_name,
                  rc == 0 and after.decode() == original_config
                  and b"start" not in calls and not os.path.exists(backup_path),
                  "rc=%r calls=%r" % (rc, calls[:80]))

            # T7 — the full script restores the saved terminal settings on
            # every exit path: start with ICRNL off, skip, verify it is off.
            master, slave = pty.openpty()
            attrs = termios.tcgetattr(master)
            attrs[0] &= ~termios.ICRNL
            termios.tcsetattr(master, termios.TCSANOW, attrs)

            def become_session_leader():
                os.setsid()
                fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

            env = dict(os.environ)
            env["NO_COLOR"] = "1"
            env["TERM"] = "dumb"
            proc = subprocess.Popen(argv + [SCRIPT], stdin=slave,
                                    stdout=slave, stderr=slave, close_fds=True,
                                    env=env, preexec_fn=become_session_leader)
            os.close(slave)
            buf = b""
            sent = False
            deadline = time.time() + 10
            while time.time() < deadline:
                ready, _, _ = select.select([master], [], [], 0.1)
                if ready:
                    try:
                        data = os.read(master, 65536)
                    except OSError:
                        data = b""
                    if data:
                        buf += data
                if PROMPT in buf and not sent:
                    time.sleep(0.4)
                    os.write(master, b"s\n")
                    sent = True
                if sent and SKIPMSG in buf and proc.poll() is not None:
                    break
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            restored_off = False
            try:
                now = termios.tcgetattr(master)
                restored_off = (now[0] & termios.ICRNL) == 0
                os.close(master)
            except OSError:
                pass
            check("T7 full-script tty restore after skip (%s)" % shell_name,
                  SKIPMSG in buf and restored_off,
                  "skip=%s restored=%s" % (SKIPMSG in buf, restored_off))

            # E2 — YAML paste to Ctrl+D installs the candidate.
            if os.path.exists(backup_path):
                os.remove(backup_path)
            rc, out, _master = run_pty(
                argv, SCRIPT,
                [("send", b"\n"), ("wait_pat", PROMPT), ("sleep", 0.5),
                 ("send", b"mixed-port: 7890\nfoo: bar\n"),
                 ("sleep", 0.5), ("send", b"\x04"), ("sleep", 3.0)],
                icrnl=True)
            after = open(config_path, "rb").read()
            check("E2 YAML paste installs candidate (%s)" % shell_name,
                  rc == 0 and b"foo: bar" in after
                  and os.path.exists(backup_path),
                  "rc=%r tail=%r" % (rc, out[-120:]))

            # E3 — pasted shell command is rejected without execution.
            with open(config_path, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(original_config)
            if os.path.exists(backup_path):
                os.remove(backup_path)
            rc, out, _master = run_pty(
                argv, SCRIPT,
                [("send", b"\n"), ("wait_pat", PROMPT), ("sleep", 0.5),
                 ("send", b"opkg update\n"), ("sleep", 0.5),
                 ("send", b"\x04"), ("sleep", 3.0)],
                icrnl=True)
            after = open(config_path, "rb").read()
            check("E3 shell paste rejected unchanged config (%s)" % shell_name,
                  rc is not None and rc != 0
                  and b"Shell commands were pasted" in out
                  and after.decode() == original_config,
                  "rc=%r" % (rc,))
    finally:
        # E3 intentionally leaves a config behind; remove the fixture files
        # so later E2E sections pass their "no real install" precondition.
        for path in (config_path, backup_path, calls_log):
            try:
                os.remove(path)
            except OSError:
                pass
        for path in reversed(created):
            try:
                os.remove(path)
            except OSError:
                shutil.rmtree(path, ignore_errors=True)
        for path in ("/opt/etc/mihomo", "/opt/etc/init.d", "/opt/etc",
                     "/opt/sbin", "/opt"):
            try:
                os.rmdir(path)
            except OSError:
                pass


def test_e2e_recovery_cases():
    """Issue #320 stage B: recovery import over an empty/missing/invalid
    current config, and protection of a good .bak from invalid content.

    Contracts under test:
      - an installed KAS (init script + binary present) with a missing or
        empty config.yaml allows a recovery import; the misleading
        "Run setup.sh first" error is gone;
      - a nonempty but invalid current config never overwrites an existing
        good config.yaml.bak (the backup keeps the last known-good YAML);
      - recovery mode leaves an existing backup untouched;
      - a candidate containing `secret: null` (empty Controller secret — an
        accepted KAS deployment contract) imports without a YAML error;
      - a valid current config still produces the previous-config backup
        (unchanged historical behavior).
    """
    ok, why = e2e_possible()
    if not ok:
        print("[SKIP] end-to-end recovery cases (%s)" % why)
        return

    created = []

    def ensure_dir(path):
        if not os.path.isdir(path):
            os.makedirs(path)
            created.append(path)

    for path in ("/opt", "/opt/sbin", "/opt/etc", "/opt/etc/init.d",
                 "/opt/etc/mihomo"):
        ensure_dir(path)

    fake_bin = "/opt/sbin/mihomo"
    fake_init = "/opt/etc/init.d/S99mihomo"
    config_path = "/opt/etc/mihomo/config.yaml"
    backup_path = "/opt/etc/mihomo/config.yaml.bak"
    created.extend([fake_bin, fake_init, "/opt/etc/init.d/rc.func"])

    # Content-aware validator: rejects any -t target containing the marker,
    # so the tests can distinguish a valid config from a corrupt one.
    with open(fake_bin, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("#!/bin/sh\n"
                 "f=\"\"\nprev=\"\"\n"
                 "for a in \"$@\"; do\n"
                 "  [ \"$prev\" = \"-f\" ] && f=\"$a\"\n"
                 "  prev=\"$a\"\n"
                 "done\n"
                 "[ -n \"$f\" ] || f=\"/opt/etc/mihomo/config.yaml\"\n"
                 "if [ -f \"$f\" ] && grep -q MAKE_MIHOMO_FAIL \"$f\" 2>/dev/null; then\n"
                 "  echo \"synthetic mihomo: config rejected\" >&2\n"
                 "  exit 1\n"
                 "fi\n"
                 "exit 0\n")
    write_package_init(fake_init, "#!/bin/sh\nexit 0\n")
    os.chmod(fake_bin, 0o755)
    os.chmod(fake_init, 0o755)

    GOOD_OLD = "mixed-port: 7890\nmode: rule\nsecret: real-old\n"
    CANDIDATE = b"mixed-port: 7890\nmode: rule\nsecret: null\nrecovery: yes\n"

    def reset(config_bytes, bak_bytes):
        for path in (config_path, backup_path):
            if os.path.exists(path):
                os.remove(path)
        if config_bytes is not None:
            with open(config_path, "wb") as fh:
                fh.write(config_bytes)
        if bak_bytes is not None:
            with open(backup_path, "wb") as fh:
                fh.write(bak_bytes)

    def paste_candidate(shell_argv):
        return run_pty(
            shell_argv, SCRIPT,
            [("send", b"\n"), ("wait_pat", PROMPT), ("sleep", 0.5),
             ("send", CANDIDATE), ("sleep", 0.5), ("send", b"\x04"),
             ("sleep", 3.0)],
            icrnl=True)

    for argv in sh_shells():
        shell_name = " ".join(argv)
        try:
            # R1 — empty current config: recovery import proceeds, no
            # misleading "Run setup.sh first", candidate installed
            # (secret: null is NOT a YAML error — accepted KAS contract).
            reset(b"", None)
            rc, out, _master = paste_candidate(argv)
            after = open(config_path, "rb").read() if os.path.exists(config_path) else b""
            check("R1 empty config recovery import (%s)" % shell_name,
                  rc == 0 and after == CANDIDATE
                  and b"Run setup.sh first" not in out
                  and b"recovery" in out.lower(),
                  "rc=%r tail=%r" % (rc, out[-160:]))

            # R2 — empty current config + existing good backup: the backup
            # must survive the recovery import byte-identically.
            reset(b"", GOOD_OLD.encode())
            rc, out, _master = paste_candidate(argv)
            after = open(config_path, "rb").read() if os.path.exists(config_path) else b""
            bak = open(backup_path, "rb").read() if os.path.exists(backup_path) else b""
            check("R2 empty config recovery preserves good .bak (%s)" % shell_name,
                  rc == 0 and after == CANDIDATE and bak == GOOD_OLD.encode(),
                  "rc=%r bak=%r" % (rc, bak[:60]))

            # R3 — nonempty invalid current config + good backup: the invalid
            # content must NOT replace the good backup (issue #320 hazard).
            reset(b"mixed-port: 7890\nMAKE_MIHOMO_FAIL\n", GOOD_OLD.encode())
            rc, out, _master = paste_candidate(argv)
            after = open(config_path, "rb").read() if os.path.exists(config_path) else b""
            bak = open(backup_path, "rb").read() if os.path.exists(backup_path) else b""
            check("R3 invalid current keeps good .bak (%s)" % shell_name,
                  rc == 0 and after == CANDIDATE and bak == GOOD_OLD.encode()
                  and b"preserved" in out,
                  "rc=%r bak=%r" % (rc, bak[:60]))

            # R4 — missing current config entirely: recovery import works.
            reset(None, None)
            rc, out, _master = paste_candidate(argv)
            after = open(config_path, "rb").read() if os.path.exists(config_path) else b""
            check("R4 missing config recovery import (%s)" % shell_name,
                  rc == 0 and after == CANDIDATE,
                  "rc=%r tail=%r" % (rc, out[-160:]))

            # R5 — valid current config: historical behavior — previous
            # config becomes the new backup (regression guard).
            reset(b"mixed-port: 7890\nmode: rule\nold: yes\n", None)
            rc, out, _master = paste_candidate(argv)
            after = open(config_path, "rb").read() if os.path.exists(config_path) else b""
            bak = open(backup_path, "rb").read() if os.path.exists(backup_path) else b""
            check("R5 valid current still backed up (%s)" % shell_name,
                  rc == 0 and after == CANDIDATE
                  and bak == b"mixed-port: 7890\nmode: rule\nold: yes\n",
                  "rc=%r bak=%r" % (rc, bak[:60]))
        finally:
            for path in (config_path, backup_path):
                if os.path.exists(path):
                    os.remove(path)

    for path in reversed(created):
        try:
            os.remove(path)
        except OSError:
            shutil.rmtree(path, ignore_errors=True)
    for path in ("/opt/etc/mihomo", "/opt/etc/init.d", "/opt/etc",
                 "/opt/sbin", "/opt"):
        try:
            os.rmdir(path)
        except OSError:
            pass


FAKE_MIHOMO_TWO_RULES = """#!/bin/sh
f=""
prev=""
for a in "$@"; do
  [ "$prev" = "-f" ] && f="$a"
  prev="$a"
done
if [ -n "$f" ]; then
  if [ -f "$f" ] && grep -q MAKE_MIHOMO_FAIL "$f" 2>/dev/null; then
    echo "synthetic mihomo: config rejected" >&2
    exit 1
  fi
  exit 0
fi
# No -f: the post-install re-check of the installed canonical config.
# A candidate marked POST_COMMIT_FAIL passes its own -t staging check but
# fails after the commit, which deterministically drives the rollback path.
if [ -f /opt/etc/mihomo/config.yaml ] && grep -q POST_COMMIT_FAIL /opt/etc/mihomo/config.yaml 2>/dev/null; then
  echo "synthetic mihomo: installed config rejected" >&2
  exit 1
fi
exit 0
"""

# A named background daemon: a python3 copy named exactly "mihomo" listening
# on 7890, so `pidof mihomo` sees it and the contract port is genuinely
# bound. start/stop mirror the real init contract. python3 is used because
# minimal images (Ubuntu busybox) ship no nc applet.
FAKE_INIT_DAEMON = """#!/bin/sh
PIDFILE=/tmp/.kas-test-mihomo.pid
BIN=/tmp/mihomo
case "$1" in
  start)
    cp "$(command -v python3)" "$BIN" 2>/dev/null || exit 1
    chmod 755 "$BIN"
    # setsid detaches the daemon from the test PTY session, so it survives
    # the importer exit the way a real init-started daemon would.
    setsid "$BIN" -c 'import socket
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 7890))
s.listen(5)
while 1:
    c, _ = s.accept()
    c.close()
' </dev/null >/dev/null 2>&1 &
    echo $! > "$PIDFILE"
    ;;
  stop)
    [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null
    rm -f "$PIDFILE"
    ;;
esac
exit 0
"""


def daemon_running():
    result = subprocess.run(["pidof", "mihomo"], capture_output=True, text=True)
    return result.returncode == 0 and result.stdout.strip() != ""


def daemon_hard_stop(fake_init):
    subprocess.run([fake_init, "stop"], capture_output=True)
    subprocess.run(["pkill", "-x", "mihomo"], capture_output=True)
    try:
        os.remove("/tmp/mihomo")
    except OSError:
        pass
    time.sleep(0.3)


def test_e2e_rollback_contracts():
    """PR #325 review (2026-11-01): candidate validity and rollback validity
    are separate contracts. The importer must
      - validate the current config regardless of any existing backup and
        never create a backup from unusable content (R6, R7);
      - validate an existing backup before trusting it as a rollback source
        and keep unusable files on disk for manual inspection (R7);
      - roll back only to a validated backup and verify the restored config
        (R8), keeping the service state contract (R12);
      - fail closed with accurate wording when no validated backup exists,
        retaining every available byte for manual recovery and never
        claiming "previous config restored" (R9);
      - overwrite a stale unusable backup with a validated current config
        (R10);
      - never damage the last good copy on interruption at any point (R11).
    """
    ok, why = e2e_possible()
    if not ok:
        print("[SKIP] end-to-end rollback contracts (%s)" % why)
        return
    if not (os.path.exists("/bin/busybox") and daemon_capable()):
        check("rollback contracts prerequisites", False,
              "/bin/busybox (shell matrix) and python3 (named daemon "
              "emulation) are required")
        return

    created = []

    def ensure_dir(path):
        if not os.path.isdir(path):
            os.makedirs(path)
            created.append(path)

    for path in ("/opt", "/opt/sbin", "/opt/etc", "/opt/etc/init.d",
                 "/opt/etc/mihomo"):
        ensure_dir(path)

    fake_bin = "/opt/sbin/mihomo"
    fake_init = "/opt/etc/init.d/S99mihomo"
    config_path = "/opt/etc/mihomo/config.yaml"
    backup_path = "/opt/etc/mihomo/config.yaml.bak"
    created.extend([fake_bin, fake_init, "/opt/etc/init.d/rc.func"])

    with open(fake_bin, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(FAKE_MIHOMO_TWO_RULES)
    write_package_init(fake_init, FAKE_INIT_DAEMON)
    os.chmod(fake_bin, 0o755)
    os.chmod(fake_init, 0o755)

    CANDIDATE = b"mixed-port: 7890\nmode: rule\nsecret: null\nrecovery: yes\n"
    FAIL_CANDIDATE = b"mixed-port: 7890\nmode: rule\nPOST_COMMIT_FAIL\n"
    GARBAGE_A = b"mixed-port: 7890\nMAKE_MIHOMO_FAIL\nplace-A\n"
    GARBAGE_B = b"mixed-port: 7890\nMAKE_MIHOMO_FAIL\nplace-B\n"
    VALID_PREV = b"mixed-port: 7890\nmode: rule\nold: yes\n"

    def reset(config_bytes, bak_bytes):
        daemon_hard_stop(fake_init)
        for path in (config_path, backup_path):
            if os.path.exists(path):
                os.remove(path)
        if config_bytes is not None:
            with open(config_path, "wb") as fh:
                fh.write(config_bytes)
        if bak_bytes is not None:
            with open(backup_path, "wb") as fh:
                fh.write(bak_bytes)

    def paste(shell_argv, candidate, timeout=40, wait_after=1.0):
        return run_pty(
            shell_argv, SCRIPT,
            [("send", b"\n"), ("wait_pat", PROMPT), ("sleep", 0.5),
             ("send", candidate), ("sleep", 0.5), ("send", b"\x04"),
             ("sleep", wait_after)],
            icrnl=True, timeout=timeout)

    def read_file(path):
        return open(path, "rb").read() if os.path.exists(path) else None

    for argv in sh_shells():
        shell_name = " ".join(argv)
        try:
            # R6 — invalid nonempty current config, no backup: no unusable
            # .bak may be created and no "[OK] backup" may be claimed.
            reset(GARBAGE_A, None)
            rc, out, _master = paste(argv, CANDIDATE)
            check("R6 invalid current + no backup stays backup-free (%s)" % shell_name,
                  rc == 0 and read_file(config_path) == CANDIDATE
                  and read_file(backup_path) is None
                  and b"[OK] Previous configuration backup" not in out
                  and b"no previous-config backup exists" in out,
                  "rc=%r bak=%r tail=%r" % (rc, read_file(backup_path), out[-140:]))

            # R7 — invalid current + unusable existing backup: the backup is
            # kept byte-identically for manual inspection, never trusted,
            # and no rollback capability is claimed.
            reset(GARBAGE_A, GARBAGE_B)
            rc, out, _master = paste(argv, CANDIDATE)
            check("R7 invalid backup kept but not trusted (%s)" % shell_name,
                  rc == 0 and read_file(config_path) == CANDIDATE
                  and read_file(backup_path) == GARBAGE_B
                  and b"cannot be used for automatic rollback" in out
                  and b"[OK] Previous configuration backup" not in out,
                  "rc=%r bak=%r tail=%r" % (rc, read_file(backup_path), out[-140:]))

            # R8 — post-commit failure with a validated backup: rollback
            # restores the known-good config and restarts the service.
            reset(VALID_PREV, None)
            subprocess.run([fake_init, "start"], capture_output=True)
            check("R8 daemon preconditions (%s)" % shell_name, daemon_running())
            rc, out, _master = paste(argv, FAIL_CANDIDATE)
            after = read_file(config_path)
            bak = read_file(backup_path)
            check("R8 post-commit failure rolls back to validated backup (%s)" % shell_name,
                  rc == 1 and after == VALID_PREV and bak == VALID_PREV
                  and b"previous config restored" in out
                  and daemon_running(),
                  "rc=%r after=%r bak=%r daemon=%s" % (rc, after, bak, daemon_running()))

            # R9 — post-commit failure with no validated backup: fail closed,
            # retain the candidate bytes, never claim a restore.
            reset(GARBAGE_A, None)
            rc, out, _master = paste(argv, FAIL_CANDIDATE)
            after = read_file(config_path)
            check("R9 no validated backup fails closed (%s)" % shell_name,
                  rc == 1 and after == FAIL_CANDIDATE
                  and b"no validated previous-config backup" in out
                  and b"Previous config restored." not in out
                  and read_file(backup_path) is None,
                  "rc=%r after=%r tail=%r" % (rc, after, out[-160:]))

            # R10 — valid current config replaces a stale unusable backup.
            reset(b"mixed-port: 7890\nmode: rule\nold-two\n", GARBAGE_B)
            rc, out, _master = paste(argv, CANDIDATE)
            check("R10 valid current overwrites stale unusable backup (%s)" % shell_name,
                  rc == 0 and read_file(config_path) == CANDIDATE
                  and read_file(backup_path)
                  == b"mixed-port: 7890\nmode: rule\nold-two\n",
                  "rc=%r bak=%r" % (rc, read_file(backup_path)))

            # R11 — interruption near the commit window must never damage
            # the last good copy: config.yaml is either the untouched
            # previous config or a fully installed candidate; the backup is
            # either absent or byte-identical to the previous config.
            prev3 = b"mixed-port: 7890\nmode: rule\nold-three\n"
            reset(prev3, None)
            rc, out, _master = run_pty(
                argv, SCRIPT,
                [("send", b"\n"), ("wait_pat", PROMPT), ("sleep", 0.5),
                 ("send", CANDIDATE), ("sleep", 0.5), ("send", b"\x04"),
                 ("wait_pat", b"Mihomo config test passed."), ("sleep", 0.3),
                 ("send", b"\x03"), ("sleep", 4.0)],
                icrnl=True, timeout=40)
            after = read_file(config_path)
            bak = read_file(backup_path)
            allowed_config = (after in (prev3, CANDIDATE))
            allowed_bak = bak in (None, prev3)
            check("R11 interruption never damages the last good copy (%s)" % shell_name,
                  allowed_config and allowed_bak,
                  "rc=%r after=%r bak=%r" % (rc, after, bak))

            # R12 — recovery import with the service running: daemon stopped
            # for the import, started again afterwards, backup untouched.
            reset(b"", b"mixed-port: 7890\nmode: rule\nsecret: real-old\n")
            subprocess.run([fake_init, "start"], capture_output=True)
            check("R12 daemon preconditions (%s)" % shell_name, daemon_running())
            rc, out, _master = paste(argv, CANDIDATE)
            check("R12 recovery with running service (%s)" % shell_name,
                  rc == 0 and read_file(config_path) == CANDIDATE
                  and read_file(backup_path)
                  == b"mixed-port: 7890\nmode: rule\nsecret: real-old\n"
                  and daemon_running(),
                  "rc=%r daemon=%s tail=%r" % (rc, daemon_running(), out[-140:]))
        finally:
            daemon_hard_stop(fake_init)
            for path in (config_path, backup_path):
                if os.path.exists(path):
                    os.remove(path)

    for path in reversed(created):
        try:
            os.remove(path)
        except OSError:
            shutil.rmtree(path, ignore_errors=True)
    for path in ("/opt/etc/mihomo", "/opt/etc/init.d", "/opt/etc",
                 "/opt/sbin", "/opt"):
        try:
            os.rmdir(path)
        except OSError:
            pass


def daemon_capable():
    """The daemon emulation needs python3 to copy-and-rename as a named
    listening process."""
    return shutil.which("python3") is not None


def sha256_of(path):
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def test_e2e_invalid_preservation_cases():
    """PR #325 final review: an unusable NONEMPTY current config.yaml must
    never be silently destroyed by the atomic candidate replacement. The
    importer preserves it byte-for-byte in a clearly marked NON-rollback
    recovery artifact (config.yaml.invalid[.N], mode 0600), fails closed
    when preservation cannot be verified, never renames onto symlinks,
    never overwrites an existing recovery file, and never creates the
    artifact on a normal valid-current import. Assertions compare real
    file bytes and SHA256 digests, not output strings.
    """
    ok, why = e2e_possible()
    if not ok:
        print("[SKIP] end-to-end invalid preservation cases (%s)" % why)
        return

    created = []

    def ensure_dir(path):
        if not os.path.isdir(path):
            os.makedirs(path)
            created.append(path)

    for path in ("/opt", "/opt/sbin", "/opt/etc", "/opt/etc/init.d",
                 "/opt/etc/mihomo"):
        ensure_dir(path)

    fake_bin = "/opt/sbin/mihomo"
    fake_init = "/opt/etc/init.d/S99mihomo"
    config_path = "/opt/etc/mihomo/config.yaml"
    backup_path = "/opt/etc/mihomo/config.yaml.bak"
    recovery_base = "/opt/etc/mihomo/config.yaml.invalid"
    outside = "/tmp/.kas-test-outside-target"
    created.extend([fake_bin, fake_init, "/opt/etc/init.d/rc.func", outside])

    with open(fake_bin, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(FAKE_MIHOMO_TWO_RULES)
    write_package_init(fake_init, "#!/bin/sh\nexit 0\n")
    os.chmod(fake_bin, 0o755)
    os.chmod(fake_init, 0o755)

    GARBAGE_A = b"mixed-port: 7890\nMAKE_MIHOMO_FAIL\nplace-A\n"
    OLD_RECOVERY = b"mixed-port: 7890\nMAKE_MIHOMO_FAIL\nolder-recovery\n"
    RACE_BYTES = b"racing-writer-claimed-this-name\n"
    OUTSIDE_BYTES = b"outside-target-must-never-change\n"
    CANDIDATE = b"mixed-port: 7890\nmode: rule\nsecret: null\nrecovery: yes\n"
    FAIL_CANDIDATE = b"mixed-port: 7890\nmode: rule\nPOST_COMMIT_FAIL\n"
    VALID_PREV = b"mixed-port: 7890\nmode: rule\nold: yes\n"

    def reset(config_bytes):
        for path in (config_path, backup_path):
            if os.path.exists(path) or os.path.islink(path):
                os.remove(path)
        n = ""
        while True:
            name = recovery_base + (".%s" % n if n else "")
            if not os.path.exists(name) and not os.path.islink(name):
                break
            os.remove(name)
            n = str(int(n or "0") + 1)
        if config_bytes is not None:
            with open(config_path, "wb") as fh:
                fh.write(config_bytes)

    def paste(shell_argv, candidate, timeout=40, env_extra=None):
        return run_pty(
            shell_argv, SCRIPT,
            [("send", b"\n"), ("wait_pat", PROMPT), ("sleep", 0.5),
             ("send", candidate), ("sleep", 0.5), ("send", b"\x04"),
             ("sleep", 1.0)],
            icrnl=True, timeout=timeout, env_extra=env_extra)

    def read_file(path):
        return open(path, "rb").read() if os.path.exists(path) else None

    def digest(path):
        return sha256_of(path) if os.path.exists(path) else None

    def recovery_names():
        found = []
        n = ""
        while True:
            name = recovery_base + (".%s" % n if n else "")
            if os.path.exists(name) or os.path.islink(name):
                found.append(name)
            else:
                break
            n = str(int(n or "0") + 1)
        return found

    def stage_leftovers():
        d = os.path.dirname(config_path)
        return [n for n in sorted(os.listdir(d)) if n.startswith(".config.yaml")]

    try:
        for argv in sh_shells():
            shell_name = " ".join(argv)
            try:
                # R13 — invalid nonempty current, no backup: the damaged
                # YAML survives byte-for-byte in the recovery artifact,
                # the .bak is not created, the path is reported without
                # the content.
                reset(GARBAGE_A)
                want = sha256_of(config_path)
                rc, out, _master = paste(argv, CANDIDATE)
                names = recovery_names()
                after = read_file(config_path)
                check("R13 damaged YAML preserved byte-for-byte (%s)" % shell_name,
                      rc == 0 and after == CANDIDATE and names == [recovery_base]
                      and digest(recovery_base) == want
                      and read_file(backup_path) is None
                      and b"config.yaml.invalid" in out
                      and b"MAKE_MIHOMO_FAIL" not in out and b"place-A" not in out,
                      "rc=%r names=%r" % (rc, names))

                # R14 — post-commit failure: the preserved original is
                # unchanged, no restore is claimed, the path is reported.
                reset(GARBAGE_A)
                want = sha256_of(config_path)
                rc, out, _master = paste(argv, FAIL_CANDIDATE)
                check("R14 recovery artifact survives post-commit failure (%s)" % shell_name,
                      rc == 1 and digest(recovery_base) == want
                      and read_file(config_path) == FAIL_CANDIDATE
                      and b"no validated previous-config backup" in out
                      and b"Previous config restored." not in out
                      and b"config.yaml.invalid" in out,
                      "rc=%r digest=%r" % (rc, digest(recovery_base)))

                # R15 — unverifiable preservation (cmp unavailable): the
                # import must abort BEFORE replacing the original; nothing
                # is lost, the reason is printed.
                reset(GARBAGE_A)
                want = sha256_of(config_path)
                fakebin = os.path.join(
                    tempfile.gettempdir(), "kas-test-nocmp-%d-%s"
                    % (os.getpid(), argv[-1]))
                os.makedirs(fakebin, exist_ok=True)
                with open(os.path.join(fakebin, "cmp"), "w") as fh:
                    fh.write("#!/bin/sh\nexit 1\n")
                os.chmod(os.path.join(fakebin, "cmp"), 0o755)
                rc, out, _master = paste(
                    argv, CANDIDATE,
                    env_extra={"PATH": fakebin + os.pathsep + os.environ["PATH"]})
                after = read_file(config_path)
                check("R15 unverifiable preservation refuses the commit (%s)" % shell_name,
                      rc == 1 and after == GARBAGE_A and digest(config_path) == want
                      and recovery_names() == []
                      and b"Cannot safely preserve" in out,
                      "rc=%r after=%r tail=%r" % (rc, after, out[-160:]))

                # R16 — collisions and symlinks: a symlink at the base name
                # is skipped (never renamed onto, outside file untouched),
                # an occupied regular name is skipped, the next free name
                # is chosen; existing files keep their bytes. The probe
                # order is base, .1, .2, ... so base and .1 are occupied
                # and .2 is the expected fresh artifact.
                reset(GARBAGE_A)
                with open(outside, "wb") as fh:
                    fh.write(OUTSIDE_BYTES)
                os.symlink(outside, recovery_base)
                with open(recovery_base + ".1", "wb") as fh:
                    fh.write(OLD_RECOVERY)
                rc, out, _master = paste(argv, CANDIDATE)
                names = recovery_names()
                check("R16 collisions choose a safe name, symlinks untouched (%s)" % shell_name,
                      rc == 0 and read_file(config_path) == CANDIDATE
                      and os.path.islink(recovery_base)
                      and read_file(outside) == OUTSIDE_BYTES
                      and digest(recovery_base + ".1") == sha256_of_bytes(OLD_RECOVERY)
                      and names == [recovery_base, recovery_base + ".1",
                                    recovery_base + ".2"]
                      and digest(recovery_base + ".2") == sha256_of_bytes(GARBAGE_A),
                      "rc=%r names=%r" % (rc, names))
                for extra in (".2", ".1"):
                    if os.path.lexists(recovery_base + extra):
                        os.remove(recovery_base + extra)
                if os.path.lexists(recovery_base):
                    os.remove(recovery_base)
                if os.path.lexists(outside):
                    os.remove(outside)

                # R17 — normal valid-current import: no recovery artifact,
                # no preservation warnings, classic backup contract.
                reset(VALID_PREV)
                rc, out, _master = paste(argv, CANDIDATE)
                check("R17 normal import creates no recovery artifact (%s)" % shell_name,
                      rc == 0 and read_file(config_path) == CANDIDATE
                      and recovery_names() == []
                      and read_file(backup_path) == VALID_PREV
                      and b"not a valid Mihomo config" not in out
                      and b"preserved verbatim" not in out,
                      "rc=%r tail=%r" % (rc, out[-140:]))

                # R18 — no-clobber race at publication: a racing writer
                # claims config.yaml.invalid AFTER the importer chose the
                # name and immediately BEFORE publication (injected by a
                # fake chmod, the last operation before publication). The
                # publication must be an atomic create-if-absent: the
                # racing writer's file keeps its bytes and the artifact
                # takes the next suffix; nothing is overwritten.
                reset(GARBAGE_A)
                racebin = os.path.join(
                    tempfile.gettempdir(), "kas-test-racebin-%d-%s"
                    % (os.getpid(), argv[-1]))
                os.makedirs(racebin, exist_ok=True)
                with open(os.path.join(racebin, "chmod"), "w") as fh:
                    fh.write(
                        "#!/bin/sh\n"
                        "for a in \"$@\"; do\n"
                        "    case \"$a\" in\n"
                        "        *.config.yaml.invalid.new.*)\n"
                        "            d=${a%/*}\n"
                        "            if [ ! -e \"$d/config.yaml.invalid\" ] && "
                        "[ ! -L \"$d/config.yaml.invalid\" ]; then\n"
                        "                printf 'racing-writer-claimed-this-name\\n' "
                        "> \"$d/config.yaml.invalid\"\n"
                        "            fi\n"
                        "            ;;\n"
                        "    esac\n"
                        "done\n"
                        "PATH=/usr/bin:/bin\n"
                        "export PATH\n"
                        "exec chmod \"$@\"\n")
                os.chmod(os.path.join(racebin, "chmod"), 0o755)
                rc, out, _master = paste(
                    argv, CANDIDATE,
                    env_extra={"PATH": racebin + os.pathsep + os.environ["PATH"]})
                names = recovery_names()
                after = read_file(config_path)
                shutil.rmtree(racebin, ignore_errors=True)
                check("R18 racing writer never clobbered at publication (%s)" % shell_name,
                      rc == 0 and after == CANDIDATE
                      and names == [recovery_base, recovery_base + ".1"]
                      and digest(recovery_base) == sha256_of_bytes(RACE_BYTES)
                      and digest(recovery_base + ".1") == sha256_of_bytes(GARBAGE_A)
                      and (os.stat(recovery_base + ".1").st_mode & 0o777) == 0o600
                      and not stage_leftovers()
                      and b"MAKE_MIHOMO_FAIL" not in out
                      and b"racing-writer" not in out,
                      "rc=%r names=%r" % (rc, names))

                # R19 — normal-path GREEN for the no-overwrite guarantee:
                # an occupied REGULAR recovery name keeps its bytes, the
                # artifact takes the next suffix, and the occupied file's
                # content is never printed.
                reset(GARBAGE_A)
                want = sha256_of(config_path)
                with open(recovery_base, "wb") as fh:
                    fh.write(OLD_RECOVERY)
                rc, out, _master = paste(argv, CANDIDATE)
                names = recovery_names()
                check("R19 occupied recovery name keeps its bytes (%s)" % shell_name,
                      rc == 0 and read_file(config_path) == CANDIDATE
                      and names == [recovery_base, recovery_base + ".1"]
                      and digest(recovery_base) == sha256_of_bytes(OLD_RECOVERY)
                      and digest(recovery_base + ".1") == sha256_of_bytes(GARBAGE_A)
                      and (os.stat(recovery_base + ".1").st_mode & 0o777) == 0o600
                      and not stage_leftovers()
                      and b"older-recovery" not in out,
                      "rc=%r names=%r" % (rc, names))
                if os.path.lexists(recovery_base + ".1"):
                    os.remove(recovery_base + ".1")
                if os.path.lexists(recovery_base):
                    os.remove(recovery_base)

                # R20 — unsupported hard links: when the atomic
                # create-if-absent publication itself fails (link(2)
                # unsupported, cross-device, I/O error — simulated by a
                # fake ln that always refuses), the import fails closed
                # BEFORE replacing config.yaml: the original bytes stay in
                # place and no recovery artifact is published.
                reset(GARBAGE_A)
                want = sha256_of(config_path)
                nolnbin = os.path.join(
                    tempfile.gettempdir(), "kas-test-noln-%d-%s"
                    % (os.getpid(), argv[-1]))
                os.makedirs(nolnbin, exist_ok=True)
                with open(os.path.join(nolnbin, "ln"), "w") as fh:
                    fh.write(
                        "#!/bin/sh\n"
                        "case \"$2\" in\n"
                        "    */config.yaml.invalid*) exit 3 ;;\n"
                        "esac\n"
                        "PATH=/usr/bin:/bin\n"
                        "export PATH\n"
                        "exec ln \"$@\"\n")
                os.chmod(os.path.join(nolnbin, "ln"), 0o755)
                rc, out, _master = paste(
                    argv, CANDIDATE,
                    env_extra={"PATH": nolnbin + os.pathsep + os.environ["PATH"]})
                shutil.rmtree(nolnbin, ignore_errors=True)
                check("R20 hard-link publication failure fails closed (%s)" % shell_name,
                      rc == 1 and read_file(config_path) == GARBAGE_A
                      and digest(config_path) == want
                      and recovery_names() == []
                      and not stage_leftovers()
                      and b"Cannot safely preserve" in out,
                      "rc=%r tail=%r" % (rc, out[-160:]))
            finally:
                for path in (config_path, backup_path):
                    if os.path.exists(path) or os.path.islink(path):
                        os.remove(path)
                n = ""
                while True:
                    name = recovery_base + (".%s" % n if n else "")
                    if not os.path.exists(name) and not os.path.islink(name):
                        break
                    os.remove(name)
                    n = str(int(n or "0") + 1)
                if os.path.exists(outside) or os.path.islink(outside):
                    os.remove(outside)

    finally:
        for path in reversed(created):
            try:
                os.remove(path)
            except OSError:
                shutil.rmtree(path, ignore_errors=True)
        for path in ("/opt/etc/mihomo", "/opt/etc/init.d", "/opt/etc",
                     "/opt/sbin", "/opt"):
            try:
                os.rmdir(path)
            except OSError:
                pass


def sha256_of_bytes(data):
    return hashlib.sha256(data).hexdigest()


def main():
    if not os.path.exists(SCRIPT):
        print("[FAIL] config-import.sh not found under %s" % ROOT)
        return 1
    test_reader_scenarios()
    test_e2e_full_script()
    test_e2e_recovery_cases()
    test_e2e_rollback_contracts()
    test_e2e_invalid_preservation_cases()
    if failures:
        print("[FAIL] config-import PTY reader regression: %d failure(s)"
              % len(failures))
        return 1
    print("[OK] config-import PTY reader regression passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
