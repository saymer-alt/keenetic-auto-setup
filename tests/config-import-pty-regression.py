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

The reader is extracted from the production script (same approach as
tests/doctor-ubi-regression.sh): the PTY reproduces the real tty behavior,
but no router is contacted and nothing outside the temporary fixture tree
is written. The end-to-end section runs only as root on a machine without
an existing /opt/etc/mihomo/config.yaml (CI or a disposable sandbox); on a
live router or a non-root host it is skipped.
"""

import fcntl
import os
import pty
import re
import select
import shutil
import subprocess
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
    created.extend([fake_bin, fake_init])

    with open(fake_bin, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("#!/bin/sh\nexit 0\n")
    with open(fake_init, "w", encoding="utf-8", newline="\n") as fh:
        fh.write('#!/bin/sh\nprintf "%s\\n" "$*" >> ' + calls_log
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


def main():
    if not os.path.exists(SCRIPT):
        print("[FAIL] config-import.sh not found under %s" % ROOT)
        return 1
    test_reader_scenarios()
    test_e2e_full_script()
    if failures:
        print("[FAIL] config-import PTY reader regression: %d failure(s)"
              % len(failures))
        return 1
    print("[OK] config-import PTY reader regression passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
