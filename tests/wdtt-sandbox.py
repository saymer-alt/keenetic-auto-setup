#!/usr/bin/env python3
"""Real local files/processes; no router, opkg, routes, DNS or firewall."""
import hashlib,os,pathlib,subprocess,tempfile,time
script=pathlib.Path(__file__).resolve().parents[1]/'experimental/wdtt/sandbox-lifecycle.sh'
fixture=r'''
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int n,char **v){
 if(n==2 && !strcmp(v[1],"-h")){puts(VERSION);return 0;}
 if(n!=3 || strcmp(v[1],"-config-file"))return 78;
 FILE *f=fopen(v[2],"r");char b[64]={0};if(!f)return 78;fgets(b,64,f);fclose(f);
 if(strstr(b,"fatal"))return 78;
 fprintf(stderr,"SYNTHETIC_SECRET_NEVER_LOG\n");
 for(;;)pause();
}
'''
for shell in [['sh'],['busybox','ash']]:
 with tempfile.TemporaryDirectory(prefix='wdtt-sandbox-') as d,tempfile.TemporaryDirectory(prefix='wdtt-fixtures-') as f:
    root=pathlib.Path(d);root.chmod(0o700);fixtures=pathlib.Path(f)
    c=fixtures/'worker.c';c.write_text(fixture)
    bins=[]
    for version in ['ONE','TWO']:
        exe=fixtures/version;subprocess.run(['gcc',str(c),'-DVERSION="'+version+'"','-o',str(exe)],check=True)
        bins.append((exe,hashlib.sha256(exe.read_bytes()).hexdigest()))
    def call(action,source=None,digest=None,ok=True):
        env=os.environ.copy()
        if source:env['WDTT_SANDBOX_SOURCE']=str(source)
        if digest:env['WDTT_SANDBOX_SHA256']=digest
        p=subprocess.run(shell+[str(script),str(root),action],env=env,capture_output=True,text=True,timeout=20)
        assert (p.returncode==0)==ok,(action,p.returncode,p.stdout,p.stderr)
        assert 'SYNTHETIC_SECRET' not in p.stdout+p.stderr
        return p
    call('install',*bins[0]);assert (root/'current').read_text().strip()==bins[0][1]
    config=root/'config.json';config.write_text('{}');config.chmod(0o600)
    call('start');assert call('status').stdout.strip()=='RUNNING_NOT_TUNNEL_PROOF'
    call('install',bins[1][0],'0'*64,ok=False)
    assert call('status').stdout.strip()=='RUNNING_NOT_TUNNEL_PROOF' # failed preflight keeps old service
    broken=fixtures/'broken';broken.write_bytes(b'not an executable\n');broken.chmod(0o700)
    call('install',broken,hashlib.sha256(broken.read_bytes()).hexdigest(),ok=False)
    assert (root/'current').read_text().strip()==bins[0][1]
    assert call('status').stdout.strip()=='RUNNING_NOT_TUNNEL_PROOF'
    call('install',*bins[1]);assert call('status').stdout.strip()=='STOPPED'
    assert (root/'previous').read_text().strip()==bins[0][1]
    call('start');call('rollback');assert (root/'current').read_text().strip()==bins[0][1]
    call('start');call('stop');call('start',ok=False) # manual restart backoff is enforced
    time.sleep(2);call('start');call('stop')
    # A foreign process, even with a fabricated PID record, cannot be killed.
    foreign=subprocess.Popen(['sleep','60'])
    try:
        fields=pathlib.Path(f'/proc/{foreign.pid}/stat').read_text().rsplit(') ',1)[1].split()
        (root/'pid').write_text(f'{foreign.pid} {fields[19]} {bins[0][1]}\n')
        call('stop',ok=False);assert foreign.poll() is None
    finally:foreign.terminate();foreign.wait();(root/'pid').unlink()
    sentinel=root/'foreign.txt';sentinel.write_text('keep')
    call('uninstall');assert sentinel.read_text()=='keep' and config.read_text()=='{}'
    assert not (root/'versions').exists()
    call('install',*bins[0]);config.write_text('fatal');config.chmod(0o600)
    call('start',ok=False);time.sleep(2)
    assert 'FATAL_CONFIG' in call('start',ok=False).stderr
    call('uninstall')
    # Never follow a forged private status path.
    (root/'status').symlink_to(sentinel);call('status',ok=False);assert sentinel.read_text()=='keep'
 print('PASS',shell,'checksum failure preserves running worker; install/start/stop/rollback; backoff; foreign PID and symlink refusal; own-only uninstall')
