#!/usr/bin/env python3
"""C2/C3/C4/C6/C7: production code with kernel/network/ownership fixtures.

No mounts, network or root privileges required. File bytes, modes and atomic
renames are real; UID/GID observations model a root-owned router filesystem.
"""
from pathlib import Path
import json
import hashlib
import os
import shlex
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def source(name):
    return (ROOT / name).read_text()


def function(text, name):
    a = text.index(name + '() {')
    return text[a:text.index('\n}', a) + 2] + '\n'


def run(shell, text, env=None, rc=0):
    p = subprocess.run(shell, input=text, text=True, capture_output=True,
                       env=env, timeout=15)
    assert p.returncode == rc, (shell, rc, p.returncode, p.stdout, p.stderr)
    return p


def package_versions(shell):
    installer = source('install.sh')
    selector = function(installer, 'select_mihomo_asset')
    assets = json.loads((ROOT / 'tests/fixtures/mihomo-assets.json').read_text())
    urls = [a['browser_download_url'] for a in assets]
    for suffix in ['aarch64-3.10', 'armv7-3.2', 'mipsel-3.4', 'mips-3.4']:
        good = next(u for u in urls if '/mihomo_1.' in u and u.endswith('_'+suffix+'.ipk'))
        for values, rc in [(urls, 0), ([good, good], 0),
                           ([good, good.replace('1.19.31', '1.19.32')], 2),
                           (['https://host/foreign_'+good.rsplit('/', 1)[1]], 1),
                           ([good.replace(suffix, 'wrong-arch')], 1), ([], 1),
                           ([good.replace('1.19.31', '1.19.32-rc.1')], 0)]:
            code = selector + f'\nIPK_SUFFIX={suffix}\nprintf "%s\\n" ' + shlex.quote('\n'.join(values)) + ' | select_mihomo_asset\n'
            p = run(shell, code, rc=rc)
            if rc == 0:
                assert len(p.stdout.splitlines()) == 1
                assert 'nohf' not in p.stdout
    updater = source('update-mihomo.sh')
    funcs = function(updater, 'valid_version') + function(updater, 'ver_compare')
    for a, b, expected in [('1.20.0', '1.19.31', 'gt'), ('1.19.31', '1.19.31', 'eq'),
                            ('1.19.30', '1.19.31', 'lt'), ('2.bad', '1.0', 'unknown'),
                            ('1..20', '1.19', 'unknown'), ('1.2.', '1.2', 'unknown'),
                            ('2.0-rc.1', '1.0', 'unknown'), ('999999999999999', '1', 'unknown')]:
        assert run(shell, funcs+f'\nver_compare {shlex.quote(a)} {shlex.quote(b)}\n').stdout.strip() == expected
    # Exercise the actual early and deferred decision blocks: force never
    # permits older/incomparable versions; empty runtime remains documented repair.
    early = updater[updater.index('if [ -n "$CURRENT_VER" ]; then'):updater.index('# Remember whether Mihomo')]
    deferred = updater[updater.index('if [ "$DEFER_VERSION_DECISION" -eq 1 ]; then\n  INSTALLED_VER='):updater.index('# 13. Runtime pre-flight')]
    for current, available, force, want in [('1.19.31','1.19.32',0,True), ('1.19.31','1.19.31',0,False),
                                           ('1.19.31','1.19.31',1,True), ('1.19.31','1.19.30',1,False),
                                           ('1.19.31','2.0-rc.1',1,False), ('','1.19.32',0,True)]:
        setup = funcs+f'''
CURRENT_VER={shlex.quote(current)}; AVAILABLE_VER={shlex.quote(available)}; FORCE_UPDATE={force}
log() {{ :; }}; warn() {{ :; }}; error() {{ exit 9; }}; preflight_fail() {{ exit 9; }}
restore_stopped_service() {{ echo RESTORE; }}
fake_binary() {{ echo 'Mihomo Meta {current}'; }}
MIHOMO_PATH=fake_binary; SERVICE_WAS_STOPPED=1
'''
        for decision, mode in [(early, 0), (deferred, 1)]:
            p=run(shell, setup+f'DEFER_VERSION_DECISION={mode}\n'+decision+'\necho PROCEED\n')
            assert ('PROCEED' in p.stdout) == want, (current, available, force, mode, p.stdout)
        p=run(shell, setup+'DEFER_VERSION_DECISION=1\n'+early+'\necho DEFERRED\n')
        assert 'DEFERRED' in p.stdout
    for bad in ['1..2', '.', '1.2.', 'nonsense', '2.bad']:
        run(shell, funcs+f'\nvalid_version {shlex.quote(bad)}\n', rc=1)
    preflight=updater[updater.index('if ! PACKAGE_OUTPUT='):updater.index('log "Package binary version verified:')]
    run(shell, '''fake() { echo 'Mihomo Meta 1.19.32'; return 1; }
STAGE_BIN=fake; AVAILABLE_VER=1.19.32
preflight_fail() { exit 9; }
'''+preflight, rc=9)
    print('PASS', shell, 'C6 selectors and C7 version/force/deferred/probe fixtures')


def mounts(shell):
    text=source('S00ubifs')
    for case in ['success','already','first-fail','partial','conflict','status-fail','disabled']:
        with tempfile.TemporaryDirectory() as directory:
            lab=Path(directory); table=lab/'mounts'; table.write_text('')
            dirs=[str(lab/x) for x in ['tmp','log','run']]
            if case=='already': table.write_text(''.join(f'tmpfs {d} tmpfs rw 0 0\n' for d in dirs))
            if case=='conflict': table.write_text(f'disk {dirs[0]} ext4 rw 0 0\n')
            code=text.replace('/opt/tmp',dirs[0]).replace('/opt/var/log',dirs[1]).replace('/opt/var/run',dirs[2]).replace('/proc/mounts',str(table))
            if case=='disabled': code=code.replace('ENABLED=yes', 'ENABLED=no')
            prefix='''mount() {
 for dest do :; done
 echo "$dest" >> "$LAB/actions"
 [ "$CASE" != first-fail ] || return 1
 if [ "$CASE" = partial ] && [ "$dest" = "$LAB/log" ]; then return 1; fi
 echo "tmpfs $dest tmpfs rw 0 0" >> "$LAB/mounts"
}
'''
            action='status' if case=='status-fail' else 'start'
            p=run(shell,prefix+'set -- '+action+'\n'+code,dict(os.environ,LAB=str(lab),CASE=case),0 if case in ['success','already','disabled'] else 1)
            actions=(lab/'actions').read_text().splitlines() if (lab/'actions').exists() else []
            assert len(actions)=={'success':3,'already':0,'first-fail':1,'partial':2,'conflict':0,'status-fail':0,'disabled':0}[case]
            if case=='partial': assert table.read_text().count('tmpfs')==2
    print('PASS',shell,'C4 mount success/failure/partial/idempotency/conflict/status')


def watchdog(shell):
    text=source('update-watchdog.sh')
    for marker in ['MIHOMO LIFECYCLE LOCK','WATCHDOG MANAGED FILES']:
        def block(s): return s[s.index('# BEGIN '+marker):s.index('# END '+marker)]
        assert block(text)==block(source('install.sh'))
    for case in ['update','current','drift','rename-fail','chmod-fail','chown-fail','backup','missing-wrapper','legacy-wrapper','busy','cron-comment','cron-duplicate','cron-custom']:
        with tempfile.TemporaryDirectory() as directory:
            lab=Path(directory)
            for d in ['opt/bin','opt/etc/cron.5mins','tmp']: (lab/d).mkdir(parents=True)
            binary=lab/'opt/bin/mihomo_watchdog.sh'; wrapper=lab/'opt/etc/cron.5mins/mihomo_watchdog'
            candidate='#!/bin/sh\n# MIHOMO WATCHDOG SCRIPT\n# new\n'
            binary.write_text(candidate if case in ['current','drift'] else candidate.replace('new','old')); binary.chmod(0o777 if case=='drift' else 0o755)
            canonical_wrapper='#!/bin/sh\nexec /opt/bin/mihomo_watchdog.sh "$@"\n'
            wrapper.write_text(canonical_wrapper.replace('/opt/',str(lab/'opt')+'/')); wrapper.chmod(0o600 if case=='drift' else 0o755)
            if case=='missing-wrapper': wrapper.unlink()
            if case=='legacy-wrapper': wrapper.write_text('#!/bin/sh\n# historical managed watchdog\n')
            cron=lab/'opt/etc/crontab'
            direct='*/5 * * * * root /bin/sh /opt/etc/cron.5mins/mihomo_watchdog'
            route='*/5 * * * * root run-parts /opt/etc/cron.5mins'
            contents=direct+'\n'
            if case=='cron-comment': contents='# '+route+'\n'
            if case=='cron-duplicate': contents=route+'\n'+route+'\n'+direct+'\n'+direct.replace(' ', '\t')+'\n'
            if case=='cron-custom': contents='*/2 * * * * root /bin/sh /opt/etc/cron.5mins/mihomo_watchdog\n'
            cron.write_text(contents.replace('/opt/',str(lab/'opt')+'/'));cron.chmod(0o640)
            if case=='backup':
                old=lab/'opt/etc/cron.5mins/mihomo_watchdog.legacy.bak';old.write_text('old');old.chmod(0o777)
            oldbytes=binary.read_bytes(); oldinode=binary.stat().st_ino
            (lab/'candidate').write_text(candidate)
            # Simulated owner drift with real file mode; chown failures remain fatal.
            if case=='drift': (lab/'wrong-owner').touch()
            prefix='''id() { echo 0; }
ls() {
 if [ "$1" = -ldn ]; then
   out=$(command ls "$@") || return
   if [ -f "$LAB/wrong-owner" ]; then
     printf '%s\n' "$out" | awk '{$3=1; $4=1; print}'
   else
     printf '%s\n' "$out"
   fi
 else
   command ls "$@"
 fi
}
chown() { [ "$CASE" != chown-fail ] || return 1; rm -f "$LAB/wrong-owner"; }
chmod() { [ "$CASE" != chmod-fail ] || return 1; command chmod "$@"; }
curl() { for dest do :; done; cp "$LAB/candidate" "$dest"; }
mv() { [ "$CASE" != rename-fail ] || return 1; command mv "$@"; }
'''
            script=prefix+text.replace('/tmp/',str(lab/'tmp')+'/').replace('/opt/',str(lab/'opt')+'/')
            if case=='legacy-wrapper':
                digest=hashlib.sha256(wrapper.read_bytes()).hexdigest()
                script=script.replace('LEGACY_HASHES="', 'LEGACY_HASHES="'+digest+' ')
            owner=None
            if case=='busy':
                lock=text[text.index('# BEGIN MIHOMO LIFECYCLE LOCK'):text.index('# END MIHOMO LIFECYCLE LOCK')]
                hold=lock.replace('/tmp/',str(lab/'tmp')+'/')+f'\nml_lifecycle_acquire || exit 1\necho ready > {lab}/ready\nread x\nml_lifecycle_release\n'
                # A file script keeps stdin available for the barrier read.
                holdfile=lab/'hold.sh';holdfile.write_text(hold)
                owner=subprocess.Popen(shell+[str(holdfile)],stdin=subprocess.PIPE,text=True)
                deadline=time.monotonic()+5
                while not (lab/'ready').exists():
                    assert time.monotonic()<deadline
                    time.sleep(.01)
                stage=lab/'opt/bin/.mihomo_watchdog.sh.new.owner';stage.write_text('active')
            try:
                fail=case in ['rename-fail','chmod-fail','chown-fail','busy','cron-custom']
                run(shell,script,dict(os.environ,LAB=str(lab),CASE=case),1 if fail else 0)
                if case in ['rename-fail','chmod-fail','chown-fail','busy']: assert binary.read_bytes()==oldbytes
                if not fail:
                    assert binary.read_text()==candidate and binary.stat().st_mode & 0o7777 == 0o755
                    assert wrapper.stat().st_mode & 0o7777 == 0o755
                    assert cron.stat().st_mode & 0o7777 == 0o640
                    if case=='current': assert binary.stat().st_ino==oldinode
                    if case=='cron-duplicate': assert cron.read_text().count('run-parts')==1 and 'mihomo_watchdog' not in cron.read_text()
                    if case=='cron-comment': assert cron.read_text().count('mihomo_watchdog')==1
                    snapshots=[(p.read_bytes(),p.stat().st_ino,p.stat().st_mtime_ns) for p in [binary,wrapper,cron]]
                    run(shell,script,dict(os.environ,LAB=str(lab),CASE='current'))
                    assert snapshots==[(p.read_bytes(),p.stat().st_ino,p.stat().st_mtime_ns) for p in [binary,wrapper,cron]]
                if case=='backup':
                    assert not old.exists()
                    assert (lab/'opt/etc/mihomo_watchdog.legacy.bak').stat().st_mode & 0o7777 == 0o600
                if case=='busy': assert stage.read_text()=='active'
                if case=='cron-custom': assert cron.read_text()==contents.replace('/opt/',str(lab/'opt')+'/')
            finally:
                if owner:
                    owner.communicate('\n',timeout=5)
    print('PASS',shell,'C2/C3 watchdog ownership/modes/faults/lock/cron/idempotency')


if __name__=='__main__':
    for shell in [['sh'],['busybox','ash']]:
        package_versions(shell)
        mounts(shell)
        watchdog(shell)
