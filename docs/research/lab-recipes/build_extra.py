import hashlib,json,os,pathlib,subprocess
base=pathlib.Path(__file__).resolve().parent
lab=base/'lab'/'wdtt';src=base/'repos'/'hoaxisr__proxy-turn-vk-android'
env=os.environ.copy();env.update(GOOS='linux',GOARCH='amd64',CGO_ENABLED='0',GOTOOLCHAIN='local',GOPATH=str(base/'lab'/'gopath'),GOCACHE=str(base/'lab'/'gocache'))
results={}
for name,cwd,extra in [('repeat-client',src/'go_client',['-mod=readonly']),('server',src,['-mod=mod','-modfile='+str(lab/'server.go.mod')])]:
    if name=='server':(lab/'server.go.mod').write_bytes((src/'go.mod').read_bytes())
    out=lab/(name+'-linux-amd64')
    cmd=['go','build']+extra+['-trimpath','-buildvcs=false','-ldflags=-s -w -buildid=','-o',str(out),'.']
    p=subprocess.run(cmd,cwd=cwd,env=env,capture_output=True,text=True,encoding='utf-8',errors='replace')
    (lab/(name+'.log')).write_text(p.stdout+p.stderr,encoding='utf-8')
    r={'rc':p.returncode,'log_tail':(p.stdout+p.stderr)[-2500:]}
    if out.exists():r.update(bytes=out.stat().st_size,sha256=hashlib.sha256(out.read_bytes()).hexdigest())
    if name=='repeat-client' and out.exists():r['equal_first']=out.read_bytes()==(lab/'wt-client-linux-amd64').read_bytes()
    results[name]=r;print(json.dumps({name:r}),flush=True)
(lab/'extra.json').write_text(json.dumps(results,indent=2),encoding='utf-8')
