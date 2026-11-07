#!/usr/bin/env python3
"""Issue #427: MagiTrickle post-install runtime health gate regression.

FIELD KN-3811: the installer reported 'MagiTrickle installed and started'
because the init script printed 'done' while the magitrickled daemon was
actually absent. The gate must derive RUNNING/STOPPED/UNKNOWN from the real
process table with a bounded wait, perform exactly one managed recovery
attempt on a proven stop, report every outcome, and never claim success
without a confirmed process. Process identity only - never DNS/Netfilter
functional health (the read-only Doctor owns that distinction).

The MAGITRICKLE RUNTIME STATE block is extracted from install.sh (production
logic, not a reimplementation) and exercised under every available shell
(dash, BusyBox ash) with stubbed pidof/init-script/decision helpers and real
/proc fixtures where the OS provides them.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
INSTALL = ROOT / 'install.sh'


def source():
    return INSTALL.read_text()


def block(text):
    return text[text.index('# BEGIN MAGITRICKLE RUNTIME STATE v1'):
                text.index('# END MAGITRICKLE RUNTIME STATE v1')]


def shells():
    out = []
    for path in ("/bin/sh", "/bin/dash", "/bin/busybox"):
        if os.path.exists(path):
            if path == "/bin/busybox":
                out.append(["/bin/busybox", "sh"])
            else:
                out.append([path])
    if not out:
        sh = shutil.which("sh")
        if sh:
            out.append([sh])
    return out


def run(shell, script, expected=0):
    p = subprocess.run(shell, input=script, text=True, capture_output=True, timeout=60)
    assert p.returncode == expected, (shell, expected, p.returncode, p.stdout, p.stderr)
    return p.stdout


def main():
    text = source()
    marker = block(text)
    # FIELD #427 acceptance: the unconditional success claim is gone; the
    # final checkpoint reports the explicit diagnostic codes.
    assert 'log "MagiTrickle installed and started"' not in text, \
        'unconditional MagiTrickle success claim must be replaced by confirmed-runtime reporting'
    for needle in (
        'MT_RUNTIME_STOPPED', 'MT_RUNTIME_UNKNOWN', 'MT_RUNTIME_RECOVERY',
        'MT_LISTENER_MISSING', 'MT_RUNTIME_ADVICE',
        'process check only, not DNS/Netfilter functional health',
    ):
        assert needle in text, needle
    count = 0
    shells_list = shells()
    assert shells_list, 'no POSIX shell found to run the regression'

    def check(label, script, expected=0, must=None, absent=None):
        nonlocal count
        for shell in shells_list:
            out = run(shell, script, expected)
            for needle in (must or []):
                assert needle in out, (shell, label, needle, out)
            for anti in (absent or []):
                assert anti not in out, (shell, label, anti, out)
            count += 1
        print('PASS', label, flush=True)

    base = marker + '\n'

    # mt_runtime_state contract: 0 running, 1 stopped, 2 unknown. Empty or
    # non-numeric pidof output is unknown, never absence.
    for output, rc, want in [('123', 0, 0), ('123 456', 0, 0), ('', 1, 1),
                             ('', 0, 2), ('garbage', 0, 2), ('0', 0, 2),
                             ('12 34x', 0, 2), ('   ', 0, 2)]:
        check('pidof %r rc=%d -> %d' % (output, rc, want),
              base + 'pidof() { echo "%s"; return %d; }\nmt_runtime_state\n' % (output, rc), want)

    # /proc fallback (no pidof): restricted views are unknown, absence is
    # proven only against a positively inspectable proc (kernel-thread PID 1
    # executes no userspace ELF, so absence is positively inspectable).
    with tempfile.TemporaryDirectory(prefix='mt-runtime-') as directory:
        lab = Path(directory)
        proc = lab / 'proc'; proc.mkdir()
        (proc / '1').mkdir()
        (proc / 'self').mkdir()
        (proc / 'self/stat').write_text('self\n')
        (proc / '1/stat').write_text('1 (kernel) S 0 0 0 0 0 2097152 0\n')
        (proc / 'mounts').write_text('proc /proc proc rw 0 0\n')
        h = marker.replace('command -v pidof', 'false').replace('/proc/', str(proc) + '/')
        check('no pidof, proven stopped', h + '\nmt_runtime_state\n', 1)
        (proc / 'mounts').write_text('proc /proc proc rw,hidepid=2 0 0\n')
        check('no pidof, hidepid view -> unknown', h + '\nmt_runtime_state\n', 2)
        (proc / 'mounts').write_text('proc /proc proc rw 0 0\n')
        (proc / '1' / 'stat').unlink()
        (proc / '1').rmdir()
        check('no pidof, restricted proc view -> unknown', h + '\nmt_runtime_state\n', 2)
        (proc / '1').mkdir()
        (proc / '1' / 'stat').write_text('1 (kernel) S 0 0 0 0 0 2097152 0\n')
        # A stable daemon fixture: the shell interpreter loop keeps the copy
        # alive, so /proc/<pid>/exe stays the lab binary named magitrickled.
        exe = lab / 'magitrickled'
        shutil.copy2('/bin/sh', exe)
        children = []
        try:
            child = subprocess.Popen(
                ['magitrickled', '-c', 'while :; do sleep 60; done'],
                executable=str(exe))
            children.append(child)
            (proc / str(child.pid)).symlink_to('/proc/%d' % child.pid)
            check('no pidof, real daemon via exe/comm', h + '\nmt_runtime_state\n', 0)
        finally:
            for child in children:
                child.kill()
                child.wait()

    # Bounded wait: immediate, delayed start (the normal startup race),
    # persistent stop and persistent unknown; sleeps are stubbed.
    stub_wait = base + 'sleep() { :; }\n'
    check('wait: immediate running',
          stub_wait + 'mt_runtime_state() { return 0; }\nmt_wait_runtime\n', 0)
    check('wait: delayed start (proven-stop probes then running)',
          stub_wait + 'n=0\nmt_runtime_state() { n=$((n+1)); [ "$n" -ge 3 ] && return 0; return 1; }\nmt_wait_runtime\n', 0)
    check('wait: persistent stop',
          stub_wait + 'mt_runtime_state() { return 1; }\nmt_wait_runtime\n', 1)
    check('wait: persistent unknown',
          stub_wait + 'mt_runtime_state() { return 2; }\nmt_wait_runtime\n', 2)

    # Effective DNS proxy port from the MagiTrickle config; package default
    # 3553 as fallback, non-numeric values never override it.
    check('dns port: default without config',
          base + 'magitrickle_dns_port\necho "$_mt_dns_port"\n', 0, must=['3553'])
    with tempfile.TemporaryDirectory(prefix='mt-cfg-') as directory:
        cfg = Path(directory) / 'config.yaml'
        cfg.write_text('application:\n  dnsProxy:\n    port: 9001\n  httpWeb:\n    port: 8080\n')
        check('dns port: effective config value',
              base + 'MT_CFG_PATH=%s\nmagitrickle_dns_port\necho "$_mt_dns_port"\n' % cfg,
              0, must=['9001'])
        cfg.write_text('application:\n  dnsProxy:\n    port: notanumber\n')
        check('dns port: non-numeric falls back to 3553',
              base + 'MT_CFG_PATH=%s\nmagitrickle_dns_port\necho "$_mt_dns_port"\n' % cfg,
              0, must=['3553'])

    # Listener detection with PATH shims: netstat, ss fallback, no tool.
    with tempfile.TemporaryDirectory(prefix='mt-shim-') as directory:
        shim = Path(directory)
        (shim / 'netstat-match').mkdir()
        (shim / 'netstat-match' / 'netstat').write_text(
            '#!/bin/sh\nprintf \'tcp 0 0 127.0.0.1:3553 0.0.0.0:* LISTEN\\n\'\n')
        os.chmod(shim / 'netstat-match' / 'netstat', 0o755)
        (shim / 'netstat-empty').mkdir()
        (shim / 'netstat-empty' / 'netstat').write_text('#!/bin/sh\nprintf \'tcp 0 0 127.0.0.1:9999 0.0.0.0:* LISTEN\\n\'\n')
        os.chmod(shim / 'netstat-empty' / 'netstat', 0o755)
        (shim / 'ss-only').mkdir()
        (shim / 'ss-only' / 'ss').write_text(
            '#!/bin/sh\nprintf \'LISTEN 0 128 127.0.0.1:3553 0.0.0.0:*\\n\'\n')
        os.chmod(shim / 'ss-only' / 'ss', 0o755)
        check('listener: netstat match',
              base + 'PATH=%s:$PATH\n_mt_dns_port=3553\nmagitrickle_dns_listening\n' % (shim / 'netstat-match'), 0)
        check('listener: netstat no match',
              base + 'PATH=%s:$PATH\n_mt_dns_port=3553\nmagitrickle_dns_listening\n' % (shim / 'netstat-empty'), 1)
        check('listener: ss fallback',
              base + 'PATH=%s:$PATH\n_mt_dns_port=3553\nmagitrickle_dns_listening\n' % (shim / 'ss-only'), 0)
        check('listener: no tool -> skip(2)',
              base + 'PATH=/nonexistent-mt-shim\n_mt_dns_port=3553\nmagitrickle_dns_listening\n', 2)

    # Post-start confirmation: every outcome reported, exactly one managed
    # recovery attempt on a proven stop, no restart on unknown, and the
    # success claim only with a confirmed process. The listener decision is
    # stubbed directly (the real tool detection is covered above); the init
    # fixture counts its invocations.
    with tempfile.TemporaryDirectory(prefix='mt-confirm-') as directory:
        lab = Path(directory)
        init = lab / 'S99magitrickle'
        init.write_text('#!/bin/sh\necho start >> "%s/calls.log"\nexit 0\n' % lab)
        os.chmod(init, 0o755)
        calls = 'printf \'calls=%%s\\n\' "$(cat "%s/calls.log" 2>/dev/null | wc -l)"\n' % lab
        prelude = base + 'MT_INIT_SCRIPT=%s\nlog() { echo "[setup] $1"; }\nwarn() { echo "[WARN] $1"; }\nsleep() { :; }\n_mt_dns_port=3553\nrm -f "%s/calls.log"\n' % (init, lab)

        check('confirm: running + listener confirmed, no restart',
              prelude + 'mt_wait_runtime() { return 0; }\nmagitrickle_dns_listening() { return 0; }\nmt_confirm_after_start; echo "rc=$?"\n' + calls,
              0, must=['installed and started', 'DNS listener on port 3553 confirmed', 'calls=0'],
              absent=['MT_RUNTIME_STOPPED'])
        check('confirm: running but listener missing -> explicit warn, no restart',
              prelude + 'mt_wait_runtime() { return 0; }\nmagitrickle_dns_listening() { return 1; }\nmt_confirm_after_start; echo "rc=$?"\n' + calls,
              0, must=['MT_LISTENER_MISSING', 'calls=0'],
              absent=['installed and started (magitrickled running, DNS listener'])
        check('confirm: running, listener tool unavailable -> honest log',
              prelude + 'mt_wait_runtime() { return 0; }\nmagitrickle_dns_listening() { return 2; }\nmt_confirm_after_start; echo "rc=$?"\n' + calls,
              0, must=['listener check unavailable', 'calls=0'])
        check('confirm: proven stop, one managed recovery succeeds',
              prelude + 'n=0\nmt_wait_runtime() { n=$((n+1)); [ "$n" -ge 2 ] && return 0; return 1; }\nmagitrickle_dns_listening() { return 0; }\nmt_confirm_after_start; echo "rc=$?"\n' + calls,
              0, must=['MT_RUNTIME_STOPPED', 'MT_RUNTIME_RECOVERY', 'MT_RUNTIME_RECOVERY_OK', 'calls=1'],
              absent=['MT_RUNTIME_STILL_STOPPED'])
        check('confirm: proven stop, recovery fails exactly once, no loop',
              prelude + 'mt_wait_runtime() { return 1; }\nmt_confirm_after_start; _mt_rc=$?; echo "rc=$_mt_rc"\n' + calls + 'exit "$_mt_rc"\n',
              1, must=['MT_RUNTIME_STOPPED', 'MT_RUNTIME_RECOVERY', 'MT_RUNTIME_STILL_STOPPED', 'MT_RUNTIME_ADVICE', 'calls=1'],
              absent=['installed and started'])
        check('confirm: unknown state, read-only, no restart',
              prelude + 'mt_wait_runtime() { return 2; }\nmt_confirm_after_start; _mt_rc=$?; echo "rc=$_mt_rc"\n' + calls + 'exit "$_mt_rc"\n',
              2, must=['MT_RUNTIME_UNKNOWN', 'calls=0'],
              absent=['MT_RUNTIME_RECOVERY'])

    print('PASS %d magitrickle runtime gate checks (%s)' % (
        count, ', '.join(' '.join(s) for s in shells_list)), flush=True)


if __name__ == '__main__':
    main()
