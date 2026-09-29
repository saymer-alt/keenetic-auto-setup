#!/usr/bin/env python3
"""B6: real executable identity, restricted-proc fixtures and consumer barriers.

No router/network. Only paths and kernel observation are redirected; decisions
and stop/probe/restore functions are extracted from production, not reimplemented.
"""
from pathlib import Path
import os
import shlex
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FILES = ['install.sh', 'update-mihomo.sh', 'config-import.sh',
         'migrate-mihomo-mips.sh', 'migrate-mihomo-tun.sh',
         'mihomo-doctor.sh', 'mihomo-watchdog.sh']


def source(name):
    return (ROOT / name).read_text()


def block(text):
    return text[text.index('# BEGIN MIHOMO PROCESS STATE v1'):
                text.index('# END MIHOMO PROCESS STATE v1')]


def function(text, name):
    a = text.index(name + '() {')
    return text[a:text.index('\n}', a) + 2] + '\n'


def run(shell, text, expected=0):
    p = subprocess.run(shell, input=text, text=True, capture_output=True, timeout=15)
    assert p.returncode == expected, (shell, expected, p.returncode, p.stdout, p.stderr)
    return p.stdout


def main():
    helper = block(source(FILES[0]))
    for name in FILES:
        assert block(source(name)) == helper, name
    count = 0
    for shell in [['sh'], ['busybox', 'ash']]:
        n = 0
        def check(label, script, expected=0):
            nonlocal n
            run(shell, script, expected)
            n += 1
            print('PASS', '/'.join(shell), label, flush=True)

        for output, rc, want in [('123', 0, 0), ('', 1, 1), ('', 127, 2), ('', 0, 2), ('123 456', 0, 0), ('garbage', 0, 2), ('   ', 0, 2)]:
            check(f'pidof {output!r} rc={rc}', helper+f'\npidof() {{ echo "{output}"; return {rc}; }}\nmp_state\n', want)
        with tempfile.TemporaryDirectory(prefix='mihomo-process-') as directory:
            lab = Path(directory)
            proc = lab / 'proc'; proc.mkdir()
            (proc / '1').mkdir(); (proc / 'self').mkdir()
            (proc / 'self/stat').write_text('self\n')
            (proc / 'mounts').write_text('proc /proc proc rw 0 0\n')
            # PID 1 as a kernel-thread fixture so absence is positively inspectable.
            (proc / '1/stat').write_text('1 (kernel) S 0 0 0 0 0 2097152 0\n')
            # Mask only command availability; keep production fallback intact.
            h = helper.replace('command -v pidof', 'false').replace('/proc/', str(proc)+'/')
            check('no pidof, proven stopped', h+'\nmp_state\n', 1)
            exe = lab / 'mihomo'; shutil.copy2(shutil.which('busybox'), exe)
            children = []
            try:
                for i in range(2):
                    child = subprocess.Popen(['sleep', '60'], executable=str(exe))
                    children.append(child)
                    (proc / str(child.pid)).symlink_to(f'/proc/{child.pid}')
                    check(f'no pidof, {i+1} real daemon(s)', h+'\nmp_state\n')
                check('running cannot satisfy stopped gate', h+'\nmp_stopped\n', 1)
                for name,restore in [('update-mihomo.sh','restore_stopped_service'),('migrate-mihomo-mips.sh','restore_stopped_service'),('migrate-mihomo-tun.sh','restore_service_if_needed'),('config-import.sh','restore_old_service')]:
                    text=source(name)
                    fn=function(text,restore)
                    if name=='config-import.sh':fn+=function(text,'mihomo_running')+function(text,'start_mihomo_confirmed')
                    setup='''
SERVICE_WAS_RUNNING=1; SERVICE_WAS_STOPPED=1; INIT_SCRIPT=record_start
record_start() { echo SECOND-START; }
log() { :; }; warn() { :; }; sleep() { :; }
wait_for_contract_port() { return 0; }
'''
                    out=run(shell,h+fn+setup+restore+'\n')
                    assert 'SECOND-START' not in out
                    n+=1;print('PASS','/'.join(shell),name,'no second restore-start without pidof')
                # A real executable remains live on a deleted inode after rename.
                replacement = lab / 'replacement'; shutil.copy2(shutil.which('busybox'), replacement)
                replacement.replace(exe)
                check('deleted executable is still running', h+'\nmp_state\n')
                doctor = source('mihomo-doctor.sh')
                probe = function(doctor, 'observe_mihomo_procs') + function(doctor, 'doctor_mihomo_probe')
                stubs = '\nml_lifecycle_acquire() { return 0; }\nml_lifecycle_release() { :; }\nrun_with_timeout() { echo ELF; }\n'
                out = run(shell, h+probe+stubs+'doctor_mihomo_probe 1 unused\n[ "$PROBE_SKIPPED" -eq 1 ]\n')
                assert 'ELF' not in out
                n += 1; print('PASS', '/'.join(shell), 'Doctor no second ELF beside real daemon')
                # Unknown must block the same production Doctor reservation.
                ambiguous = proc/'999999'; ambiguous.mkdir()
                (ambiguous/'stat').write_text('999999 (mihomo) S 1 1 1 0 0 0 0\n')
                check('unreadable exe -> unknown even with known daemon', h+'\nmp_state\n', 2)
                check('unknown is not stopped', h+'\nmp_stopped\n', 1)
                watchdog = function(source('mihomo-watchdog.sh'), 'can_restart').replace('/opt/etc/init.d/S99mihomo restart', 'echo UNEXPECTED-RESTART')
                wdstate = lab/'restart-state'
                out = run(shell, h+watchdog+f'''
RESTART_STATE={shlex.quote(str(wdstate))}; MIN_RESTART_INTERVAL=0
reset_healthy_heartbeat() {{ :; }}
ml_lifecycle_acquire() {{ echo LOCK; }}
ml_lifecycle_release() {{ echo RELEASE; }}
log() {{ echo "$*"; }}
can_restart fixture
''', 1)
                assert 'UNEXPECTED-RESTART' not in out and not wdstate.exists(), out
                assert 'LOCK' in out and 'RELEASE' in out and '[SKIP]' in out, out
                n += 1
                out = run(shell, h+probe+stubs+'doctor_mihomo_probe 1 unused\n[ "$PROBE_SKIPPED" -eq 1 ]\n')
                assert 'ELF' not in out
                n += 1
                shutil.rmtree(ambiguous)
                # A readable exe is sufficient even when cmdline is inaccessible.
                candidate = proc/'999998'; candidate.mkdir()
                (candidate/'exe').symlink_to(f'/proc/{children[0].pid}/exe')
                (candidate/'cmdline').symlink_to(lab/'missing')
                check('exe identity sufficient without cmdline', h+'\nmp_state\n')
                shutil.rmtree(candidate)
            finally:
                for child in children:
                    child.terminate(); child.wait()
                    (proc/str(child.pid)).unlink()
            other = subprocess.Popen(['sh', '-c', 'while :; do :; done', 'unrelated-mihomo-name'])
            try:
                (proc/str(other.pid)).symlink_to(f'/proc/{other.pid}')
                check('unrelated argv containing mihomo is not daemon', h+'\nmp_state\n', 1)
            finally:
                other.terminate(); other.wait(); (proc/str(other.pid)).unlink()
            check('Doctor permits probe only when stopped', h+probe+stubs+'doctor_mihomo_probe 1 unused\n[ "$PROBE_SKIPPED" -eq 0 ]\n')
            (proc/'mounts').write_text('proc /proc proc rw,hidepid=2 0 0\n')
            check('restricted proc mount is unknown', h+'\nmp_state\n', 2)
            (proc/'mounts').write_text('proc /proc proc rw 0 0\n')
            for name in ['update-mihomo.sh','migrate-mihomo-mips.sh','migrate-mihomo-tun.sh','config-import.sh']:
                text=source(name)
                fn=function(text,'stop_mihomo_confirmed')
                if name=='config-import.sh': fn+=function(text,'mihomo_running')
                error='\nerror() { exit 9; }\npreflight_fail() { exit 9; }\nsleep() { :; }\n'
                ambiguous=proc/'999999'; ambiguous.mkdir()
                (ambiguous/'stat').write_text('999999 (unknown) S 1 1 1 0 0 0 0\n')
                check(name+' stop cannot confirm unknown', h+fn+error+'INIT_SCRIPT=/bin/true\nstop_mihomo_confirmed\n',9 if name=='update-mihomo.sh' else 1)
                shutil.rmtree(ambiguous)
                check(name+' confirms stopped without pidof',h+fn+error+'INIT_SCRIPT=/bin/true\nstop_mihomo_confirmed\n')
            for name,restore in [('update-mihomo.sh','restore_stopped_service'),('migrate-mihomo-mips.sh','restore_stopped_service'),('migrate-mihomo-tun.sh','restore_service_if_needed'),('config-import.sh','restore_old_service')]:
                text=source(name);fn=function(text,restore)
                if name=='config-import.sh':fn+=function(text,'mihomo_running')+function(text,'start_mihomo_confirmed')
                setup='''
SERVICE_WAS_RUNNING=1; SERVICE_WAS_STOPPED=1; INIT_SCRIPT=record_start
record_start() { echo START; }
log() { :; }; warn() { :; }; sleep() { :; }
wait_for_contract_port() { return 0; }
'''
                ambiguous=proc/'999999';ambiguous.mkdir()
                (ambiguous/'stat').write_text('999999 (unknown) S 1 1 1 0 0 0 0\n')
                out=run(shell,h+fn+setup+restore+'\n',1)
                assert 'START' not in out
                n+=1
                shutil.rmtree(ambiguous)
                check(name+' initially stopped remains stopped',h+fn+setup+'SERVICE_WAS_RUNNING=0; SERVICE_WAS_STOPPED=0\n'+restore+'\n')
                check(name+' absent process cannot confirm start',h+fn+setup+restore+'\n',1)
            # Strict B4 verifier: discovery via real /proc fallback, same inode required.
            exe=lab/'mihomo'; child=subprocess.Popen(['sleep','60'],executable=str(exe))
            (proc/str(child.pid)).symlink_to(f'/proc/{child.pid}')
            try:
                verifier=function(source('update-mihomo.sh'),'restored_runtime_ok').replace('/proc/',str(proc)+'/')
                code=h+verifier+f'\nMIHOMO_PATH={shlex.quote(str(exe))}\nrestored_runtime_ok\n'
                check('B4 real fallback correct inode',code)
                shutil.copy2(shutil.which('busybox'),lab/'new'); (lab/'new').replace(exe)
                check('B4 real fallback wrong inode rejected',code,1)
            finally:
                child.terminate();child.wait()
        count+=n
        print('Process scenarios:',n,'PASS on','/'.join(shell),flush=True)
    print('All',count,'B6 process scenarios passed.')


if __name__=='__main__':
    main()
