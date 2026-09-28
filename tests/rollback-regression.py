#!/usr/bin/env python3
"""B3/B4 fault tests: production shell code, real files and delivered signals.

MIPS runs end-to-end. Updater runs its production transaction from staging on,
with acquisition inputs supplied by fixtures. Init/process/ELF are recorded
stubs, not a Keenetic emulator; copy/chmod/rename operate on real files.
"""
from pathlib import Path
import os
import subprocess
import tempfile
import shlex
import shutil

ROOT = Path(__file__).resolve().parents[1]


def source(name):
    return (ROOT / name).read_text()


def function(text, name):
    a = text.index(name + '() {')
    return text[a:text.index('\n}', a) + 2] + '\n'


WRAPPERS = r'''
sleep() { :; }
pidof() {
  [ -f "$LAB/running" ] || return 1
  echo 4242
}
stat() {
  case "$*" in
    *'/proc/4242/exe'*) cat "$LAB/running"; return ;;
  esac
  command stat "$@"
}
curl() {
  case "$CASE" in runtime-fail) return 1 ;; esac
  return 0
}
cp() {
  for dest do :; done
  case "$dest" in
    */opt/bin/mihomo) echo DIRECT-CANONICAL-COPY >> "$LAB/actions" ;;
    *rollback.*)
      echo stage >> "$LAB/actions"
      [ "$CASE" != copy-fail ] || { echo partial > "$dest"; return 1; }
      if [ "$CASE" = signal-recovery ]; then kill -TERM "$$"; kill -HUP "$$"; fi
      ;;
  esac
  command cp "$@"
}
chmod() {
  case "$*" in *mihomo.rollback.*)
    echo chmod >> "$LAB/actions"
    [ "$CASE" != chmod-fail ] || return 1 ;;
  esac
  command chmod "$@"
}
mv() {
  case "$*" in
    *state.rollback.*)
      echo state >> "$LAB/actions"
      [ "$CASE" != state-fail ] || return 1 ;;
    *mihomo.rollback.*|*mips-rollback.*)
      echo rename >> "$LAB/actions"
      [ "$CASE" != rename-fail ] || return 1 ;;
    *mihomo.new.*|*mips-tmp*)
      echo commit >> "$LAB/actions"
      [ "$CASE" != commit-fail ] || return 1
      command mv "$@" || return
      case "$CASE" in
        term-commit) kill -TERM "$$" ;;
        int-commit) kill -INT "$$" ;;
        hup-commit) kill -HUP "$$" ;;
      esac
      return 0 ;;
  esac
  command mv "$@"
}
'''

INIT = r'''#!/bin/sh
case "$1" in
stop)
  echo stop >> "$LAB/actions"
  if [ "$CASE" = stop-fail ] && [ -f "$LAB/new-started" ]; then exit 1; fi
  rm -f "$LAB/running" ;;
start|restart)
  if [ "$KIND" = mips ]; then
    if grep -q 'stack: gvisor' "$LAB/opt/etc/mihomo/config.yaml"; then gen=old; else gen=new; fi
  else
    gen=$(tail -1 "$LAB/opt/bin/mihomo")
  fi
  echo "start:$gen" >> "$LAB/actions"
  if [ "$gen" = new ] && [ "$CASE" = start-fail ]; then exit 1; fi
  if [ "$gen" = old ] && [ "$CASE" = restored-start-fail ]; then exit 1; fi
  stat -L -c '%d:%i' "$LAB/opt/bin/mihomo" > "$LAB/running"
  if [ "$gen" = old ] && [ "$CASE" = wrong-runtime ]; then echo '0:0' > "$LAB/running"; fi
  if [ "$gen" = new ]; then
    touch "$LAB/new-started"
    case "$CASE" in
      term-start|copy-fail|chmod-fail|rename-fail|state-fail|restored-start-fail|wrong-runtime|stop-fail|signal-recovery)
        kill -TERM "$PPID" ;;
      int-start) kill -INT "$PPID" ;;
      hup-start) kill -HUP "$PPID" ;;
    esac
  fi ;;
esac
'''


def binary(generation):
    return r'''#!/bin/sh
if [ -f "$LAB/running" ]; then
  echo SECOND-PROBE >> "$LAB/actions"; exit 99
fi
echo "probe:'''+generation+r'''" >> "$LAB/actions"
case "$0" in *mihomo.rollback.*) echo validate >> "$LAB/actions" ;; esac
if [ "$CASE" = post-commit ] && [ "'''+generation+r'''" = new ] && [ "$0" = "$LAB/opt/bin/mihomo" ]; then exit 1; fi
echo "Mihomo Meta '''+('1.19.31' if generation == 'old' else '1.19.32')+'''"
exit 0
'''+generation+'\n'


def run(shell, kind, case, running=True, historical=True, state=True, no_pidof=False):
    with tempfile.TemporaryDirectory(prefix='mihomo-rollback-') as directory:
        lab = Path(directory)
        for d in ['opt/bin', 'opt/etc/init.d', 'opt/etc/mihomo', 'tmp']:
            (lab / d).mkdir(parents=True, exist_ok=True)
        cfg = lab / 'opt/etc/mihomo/config.yaml'
        cfg.write_text('# B current\ntun:\n  stack: gvisor\n')
        cfg.chmod(0o640)
        oldcfg = cfg.read_bytes()
        hist = Path(str(cfg) + '.pre-mips')
        if historical:
            hist.write_text('A historical\n')
        oldbin = binary('old')
        exe = lab / 'opt/bin/mihomo'
        exe.write_text(oldbin); exe.chmod(0o750)
        candidate = lab / 'candidate'
        candidate.write_text(binary('new')); candidate.chmod(0o750)
        metadata = lab / 'opt/etc/keenetic-auto-setup-mihomo.state'
        if state:
            metadata.write_text('runtime_version=1.19.31\n'); metadata.chmod(0o640)
        init = lab / 'opt/etc/init.d/S99mihomo'
        init.write_text(INIT); init.chmod(0o700)
        if running:
            (lab / 'running').write_text('original\n')
        # Confirm a later run/cleanup does not erase manual recovery artifacts.
        survivor = lab / 'tmp/mihomo.backup.previous'
        survivor.write_text('manual-recovery')
        if kind == 'mips':
            text = source('migrate-mihomo-mips.sh')
        else:
            full = source('update-mihomo.sh')
            text = full[:full.index('\nacquire_lock\n')]
            text += '\nacquire_lock\ntrap cleanup_tmp EXIT\n'
            text += "trap 'signal_handler INT' INT\ntrap 'signal_handler TERM' TERM\ntrap 'signal_handler HUP' HUP\n"
            text += f'''
MIHOMO_PATH=/opt/bin/mihomo
MIHOMO_DIR=/opt/bin
TMP_DIR="$LAB/tmp"
TMP_NEW="$LAB/candidate"
INIT_SCRIPT=/opt/etc/init.d/S99mihomo
SERVICE_WAS_RUNNING={int(running)}
CURRENT_VER=1.19.31
DEFER_VERSION_DECISION=0
AVAILABLE_VER=1.19.32
ASSET_NAME=fixture.ipk
PACKAGE_RELEASE=1
opkg() {{ echo 'mihomo - 1.19.31-1'; }}
'''
            text += full[full.index('NEW_SIZE_BYTES=$(wc -c < "$TMP_NEW")'):]
        text = text.replace('/tmp/', str(lab / 'tmp') + '/').replace('/opt/', str(lab / 'opt') + '/')
        wrappers = WRAPPERS
        if no_pidof:
            # Kernel observation seam only: the same real-file service fixture
            # now feeds /proc discovery instead of pidof. B3/B4 assertions stay.
            proc=lab/'proc'
            (proc/'self').mkdir(parents=True);(proc/'1').mkdir();(proc/'4242').mkdir()
            (proc/'self/stat').write_text('self\n')
            (proc/'mounts').write_text('proc /proc proc rw 0 0\n')
            (proc/'1/stat').write_text('1 (kernel) S 0 0 0 0 0 2097152 0\n')
            a=text.index('# BEGIN MIHOMO PROCESS STATE v1');b=text.index('# END MIHOMO PROCESS STATE v1')
            text=text[:a]+text[a:b].replace('/proc/',str(proc)+'/').replace('command -v pidof', 'false')+text[b:]
            wrappers += r'''
readlink() {
  case "$1" in *'/proc/4242/exe')
    [ -f "$LAB/running" ] || return 1
    echo "$LAB/opt/bin/mihomo"; return 0 ;;
  esac
  env readlink "$@"
}
cat() {
  case "$1" in *'/proc/4242/stat')
    [ ! -f "$LAB/running" ] || return 1
    echo '4242 (exited) Z 1 1 1 0 0 0 0'; return 0 ;;
  esac
  env cat "$@"
}
'''
        script = lab / 'run.sh'
        script.write_text('#!/bin/sh\n'+wrappers+'\n'+text)
        env = dict(os.environ, LAB=str(lab), CASE=case, KIND=kind)
        p = subprocess.run(shell+[str(script)], env=env, capture_output=True, text=True, timeout=20)
        events = (lab / 'actions').read_text().splitlines() if (lab / 'actions').exists() else []
        context = (shell, kind, case, running, p.returncode, events, p.stdout, p.stderr)
        assert 'SECOND-PROBE' not in events, context
        assert 'DIRECT-CANONICAL-COPY' not in events, context
        assert not (lab / 'tmp/mihomo-lifecycle.lock.d').exists(), context
        assert not (lab / 'tmp/mihomo.maintenance').exists(), context
        assert survivor.read_text() == 'manual-recovery', context
        if kind == 'mips':
            assert cfg.stat().st_mode & 0o777 == 0o640, context
            assert hist.read_bytes() == (b'A historical\n' if historical else oldcfg), context
            if case == 'success':
                assert p.returncode == 0 and b'stack: mips' in cfg.read_bytes(), context
            elif case in {'copy-fail', 'rename-fail'}:
                assert p.returncode != 0 and b'stack: mips' in cfg.read_bytes(), context
                assert 'rollback FAILED' in p.stdout, context
            else:
                assert p.returncode != 0 and cfg.read_bytes() == oldcfg, context
            failed = case in {'copy-fail', 'rename-fail'}
            assert (lab / 'running').exists() == (running and not failed), context
            backups = list(cfg.parent.glob('.config.yaml.mips-backup.*'))
            assert bool(backups) == failed, context
            if failed:
                assert backups[0].read_bytes() == oldcfg, context
        elif case == 'success':
            assert p.returncode == 0 and exe.read_text() == binary('new'), context
            assert 'runtime_version=1.19.32' in metadata.read_text(), context
        else:
            assert p.returncode != 0, context
            failures = {'copy-fail','chmod-fail','rename-fail','state-fail','restored-start-fail','wrong-runtime','stop-fail'}
            failed = case in failures
            assert ('RECOVERY FAILED' in p.stdout) == failed, context
            own_backups = [f for f in (lab / 'tmp').glob('mihomo.backup.*') if f != survivor]
            if failed:
                assert len(own_backups) == 1 and own_backups[0].read_text() == oldbin, context
                state_backups = list((lab / 'tmp').glob('mihomo-binary-state.backup.*'))
                assert len(state_backups) == 1 and state_backups[0].read_text() == 'runtime_version=1.19.31\n', context
                assert 'Rollback successful.' not in p.stdout, context
                assert (lab / 'running').exists() == (case == 'stop-fail'), context
            else:
                assert not own_backups, context
                assert (lab / 'running').exists() == running, context
            restored = case not in {'copy-fail','chmod-fail','rename-fail','stop-fail'}
            assert (exe.read_text() == oldbin) == restored, context
            if restored:
                assert exe.stat().st_mode & 0o777 == 0o750, context
                assert events.index('stage') < events.index('validate') < events.index('rename'), context
            if case != 'state-fail' and restored:
                if state:
                    assert metadata.read_text() == 'runtime_version=1.19.31\n', context
                    assert metadata.stat().st_mode & 0o777 == 0o640, context
                else:
                    assert not metadata.exists(), context
            if case == 'state-fail':
                assert 'runtime_version=1.19.32' in metadata.read_text(), context
                assert 'start:old' not in events, context
            if 'start:old' in events:
                assert events.index('rename') < events.index('start:old'), context
                if 'state' in events:
                    assert events.index('rename') < events.index('state') < events.index('start:old'), context
            if 'start:new' in events and restored and case != 'start-fail':
                assert events.index('start:new') < events.index('stop', events.index('start:new')) < events.index('stage'), context
            if case in {'copy-fail','chmod-fail','rename-fail','stop-fail'}:
                assert 'state' not in events and 'start:old' not in events, context
        print('PASS', '/'.join(shell), kind, case, 'running='+str(running), 'historical='+str(historical), 'state='+str(state), 'no_pidof='+str(no_pidof), flush=True)


def runtime_identity(shell):
    # Exercise the production /proc inode check against a real Linux process.
    with tempfile.TemporaryDirectory(prefix='mihomo-runtime-') as directory:
        # Preserve argv[0] for distributions with multicall coreutils.
        exe = Path(directory) / 'sleep'
        shutil.copy2('/bin/sleep', exe)
        p = subprocess.Popen([str(exe), '30'])
        try:
            full = source('update-mihomo.sh')
            body = full[full.index('# BEGIN MIHOMO PROCESS STATE v1'):full.index('# END MIHOMO PROCESS STATE v1')]
            body += function(full, 'restored_runtime_ok')
            body += f'\nMIHOMO_PATH={shlex.quote(str(exe))}\npidof() {{ echo {p.pid}; }}\nrestored_runtime_ok\n'
            assert subprocess.run(shell, input=body, text=True).returncode == 0
            replacement = Path(directory) / 'replacement'
            shutil.copy2('/bin/sleep', replacement)
            replacement.replace(exe)
            assert subprocess.run(shell, input=body, text=True).returncode != 0
        finally:
            p.terminate(); p.wait()
    print('PASS', '/'.join(shell), 'real /proc runtime inode identity', flush=True)


def main():
    for shell in [['sh'], ['busybox', 'ash']]:
        runtime_identity(shell)
        for running in [True, False]:
            for case in ['success','commit-fail','term-commit','int-commit','hup-commit']:
                run(shell, 'mips', case, running)
            run(shell, 'mips', 'success', running, historical=False)
        for case in ['runtime-fail','start-fail','term-start','int-start','hup-start','copy-fail','rename-fail','signal-recovery']:
            run(shell, 'mips', case)
        for case in ['success','post-commit','commit-fail','term-commit','int-commit','hup-commit','start-fail','term-start','int-start','hup-start','copy-fail','chmod-fail','rename-fail','state-fail','restored-start-fail','wrong-runtime','stop-fail','signal-recovery']:
            run(shell, 'updater', case)
        for case in ['success','post-commit','term-commit']:
            run(shell, 'updater', case, running=False)
        run(shell, 'updater', 'term-start', state=False)
        for kind in ['mips','updater']:
            for running in [True,False]:
                for case in ['success','term-commit']:
                    run(shell,kind,case,running=running,no_pidof=True)
        run(shell,'updater','wrong-runtime',no_pidof=True)
    print('All B3/B4 behavioural rollback tests passed (dash and BusyBox ash).')


if __name__ == '__main__':
    main()
