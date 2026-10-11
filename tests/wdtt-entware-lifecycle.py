#!/usr/bin/env python3
"""Real files/processes in private /tmp. No /opt, router, mount or network writes.

The shipped admission remains CLOSED. This test redirects fixed paths in a
private copy and substitutes a synthetic native C worker admission, explicitly
not hardware/ABI/license approval. Read-only admission has its own fixture test.
"""
import hashlib, json, os, pathlib, subprocess, tempfile, time
base=pathlib.Path(__file__).resolve().parents[1]/'experimental/wdtt'
source=(base/'service.sh').read_text()
fixture=r'''
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int n,char **v){
 if(n==2&&!strcmp(v[1],"-h")){puts(VERSION);return 0;}
 if(n!=3||strcmp(v[1],"-config-file"))return 78;
 FILE *f=fopen(v[2],"r");char b[256]={0};if(!f)return 78;fgets(b,256,f);fclose(f);
 if(strstr(b,"fatal"))return 78;
 fprintf(stderr,"SYNTHETIC_SECRET_CANARY\n");for(;;)pause();
}
'''
for shell in [['sh'],['busybox','ash']]:
    subprocess.run(shell+['-n',str(base/'service.sh')],check=True)
    subprocess.run(shell+['-n',str(base/'init.d')],check=True)
    refused=subprocess.run(shell+[str(base/'service.sh'),'install'],capture_output=True,text=True)
    assert refused.returncode==78 and 'INSTALL_BLOCKED' in refused.stderr
    with tempfile.TemporaryDirectory(prefix='wdtt-entware-test-') as temp:
        d=pathlib.Path(temp);d.chmod(0o700);opt=d/'opt';opt.mkdir();(opt/'etc/init.d').mkdir(parents=True)
        root=opt/'wdtt-experimental';state=d/'runtime';init=opt/'etc/init.d/S98wdtt-lab'
        scripts=d/'scripts';scripts.mkdir();c=d/'worker.c';c.write_text(fixture)
        bins=[]
        for v in ['ONE','TWO']:
            exe=d/v;subprocess.run(['gcc',str(c),'-DVERSION="'+v+'"','-o',str(exe)],check=True)
            bins.append((exe,hashlib.sha256(exe.read_bytes()).hexdigest()))
        text=source.replace('INSTALL_ADMITTED=no','INSTALL_ADMITTED=yes')
        text=text.replace('/opt/wdtt-experimental',str(root)).replace('/tmp/wdtt-runtime-$(id -u)',str(state)).replace('/opt/etc/init.d/S98wdtt-lab',str(init))
        start=text.index('admission() {');end=text.index('\nROOT=',start)
        text=text[:start]+'''admission() {
 [ "${WDTT_FIXTURE_DENY-}" != yes ] &&
 [ -f "$1" ] && [ ! -L "$1" ] &&
 [ "$(sha256sum "$1" | awk '{print $1}')" = "$2" ]
}
''' + text[end:]
        # /tmp on the host is not a Keenetic tmpfs; fixture reset below models
        # volatile state without mounting anything or claiming hardware proof.
        text=text.replace('runtime_mount_ok || fail VOLATILE_RUNTIME_REQUIRED','true # synthetic fixture runtime, never the shipped check')
        # CI fixtures own their temporary files as the runner UID, without root.
        # Only the copied install-root requirement is bypassed, never ownership checks.
        text=text.replace('[ "$(id -u)" = 0 ] || fail ROOT_REQUIRED','true # unprivileged private fixture only')
        text='''mv() {
 if [ "${WDTT_FIXTURE_FAIL_COMMIT-}" = yes ] && [ "$2" = "$ROOT/service.sh" ] && [ ! -f "$STATE/fault-fired" ]; then
   : > "$STATE/fault-fired"; return 1
 fi
 command mv "$@"
}
''' + text
        (scripts/'service.sh').write_text(text)
        # Keep the actual init logic; only its fixed service path is redirected.
        (scripts/'init.d').write_text((base/'init.d').read_text().replace('/opt/wdtt-experimental',str(root)))
        def run(action,binary=None,ok=True,env=None,installed=False):
            args=shell+[str(root/'service.sh' if installed else scripts/'service.sh'),action]
            if binary:args += [str(binary[0]),binary[1],'SYNTHETIC-NATIVE','19000']
            p=subprocess.run(args,env=dict(os.environ,**(env or {})),capture_output=True,text=True,timeout=20)
            assert (p.returncode==0)==ok,(shell,action,p.returncode,p.stdout,p.stderr)
            assert 'SYNTHETIC_SECRET' not in p.stdout+p.stderr
            return p
        try:
            run('install',bins[0],env={'WDTT_FIXTURE_DENY':'yes'},ok=False);assert not root.exists()
            run('install',bins[0]);assert root.stat().st_mode&0o777==0o700
            cfg=root/'config.json';cfg.write_text(json.dumps({'listen':'127.0.0.1:19000'}));cfg.chmod(0o600)
            before=init.read_bytes()
            boot=subprocess.run(shell+[str(init),'start'],capture_output=True,text=True)
            assert boot.returncode==0 and 'AUTOSTART_DISABLED' in boot.stdout and not (state/'pid').exists()
            run('start',installed=True);pid=(state/'pid').read_text()
            stamp={p:p.stat().st_mtime_ns for p in [root/'current',root/'service.sh',init]}
            assert 'INSTALL_UNCHANGED' in run('install',bins[0]).stdout
            assert (state/'pid').read_text()==pid and all(p.stat().st_mtime_ns==t for p,t in stamp.items())
            run('install',(bins[1][0],'0'*64),ok=False)
            assert (state/'pid').read_text()==pid and run('status').stdout.strip()=='RUNNING_NOT_TUNNEL_PROOF'
            # Missing init source must fail before stopping a running old version.
            saved=(scripts/'init.d').read_bytes();(scripts/'init.d').unlink()
            run('install',bins[1],ok=False)
            assert (state/'pid').read_text()==pid and (root/'current').read_text().strip()==bins[0][1]
            (scripts/'init.d').write_bytes(saved)
            old_service=(root/'service.sh').read_bytes();old_init=init.read_bytes()
            failed=run('install',bins[1],ok=False,env={'WDTT_FIXTURE_FAIL_COMMIT':'yes'})
            assert 'INSTALL_RECOVERED_PREVIOUS_STOPPED' in failed.stderr
            assert (root/'current').read_text().strip()==bins[0][1]
            assert (root/'service.sh').read_bytes()==old_service and init.read_bytes()==old_init
            assert run('status').stdout.strip()=='STOPPED'
            time.sleep(2);run('start')
            run('install',bins[1]);assert run('status').stdout.strip()=='STOPPED'
            assert (root/'previous').read_text().strip()==bins[0][1]
            run('start');run('rollback');assert (root/'current').read_text().strip()==bins[0][1]
            run('start');run('stop')
            # Fixed future/past deadlines avoid wall-clock second-boundary races.
            (state/'retry').write_text('1 9999999999\n')
            assert 'BACKOFF' in run('start',ok=False).stderr
            (state/'retry').write_text('1 0\n');run('start');run('stop')
            foreign=subprocess.Popen(['sleep','60'])
            try:
                born=pathlib.Path(f'/proc/{foreign.pid}/stat').read_text().rsplit(') ',1)[1].split()[19]
                (state/'pid').write_text(f'{foreign.pid} {born} {bins[0][1]}\n');(state/'pid').chmod(0o600)
                run('stop',ok=False);assert foreign.poll() is None
            finally:foreign.terminate();foreign.wait();(state/'pid').unlink()
            # A volatile-state reset models reboot persistence, without rebooting.
            for p in state.iterdir():
                if p.is_file():p.unlink()
            state.rmdir()
            boot=subprocess.run(shell+[str(init),'start'],capture_output=True,text=True)
            assert boot.returncode==0 and not state.exists() and cfg.exists()
            run('start');run('stop')
            sentinel=root/'foreign.txt';sentinel.write_text('keep')
            cfg_contents=cfg.read_bytes();run('uninstall')
            assert not init.exists() and not (root/'versions').exists() and not (root/'service.sh').exists()
            assert cfg.read_bytes()==cfg_contents and sentinel.read_text()=='keep'
            run('install',bins[0]);cfg.write_text('{"listen":"127.0.0.1:19000","fatal":true}');cfg.chmod(0o600)
            run('start',ok=False);time.sleep(2)
            assert 'FATAL_CONFIG' in run('start',ok=False).stderr
            run('uninstall')
        finally:
            # Never let a failed assertion leak our own fixture child.
            if (state/'pid').exists():
                run('stop',ok=True)
    print('PASS Entware prototype:',shell,'closed real gate, native fixture lifecycle, repeat preserves PID/mtime, rollback, foreign PID, autostart disabled, volatile-state reset, own-only uninstall')
