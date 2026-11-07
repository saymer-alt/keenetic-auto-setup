import hashlib, json, os, pathlib, subprocess, time
base=pathlib.Path(__file__).resolve().parent
source=base/'repos'/'hoaxisr__proxy-turn-vk-android'/'go_client'
dest=base/'lab'/'wdtt'; dest.mkdir(parents=True,exist_ok=True)
results=[]
for arch in ['amd64','arm64','mipsle','mips']:
    env=os.environ.copy()
    env.update(GOOS='linux', GOARCH=arch, GOMIPS='softfloat', CGO_ENABLED='0', GOTOOLCHAIN='local',
               GOPATH=str(base/'lab'/'gopath'), GOCACHE=str(base/'lab'/'gocache'))
    out=dest/f'wt-client-linux-{arch}'
    args=['go','build','-mod=readonly','-trimpath','-buildvcs=false','-ldflags=-s -w -buildid=', '-o',str(out),'.']
    start=time.monotonic()
    p=subprocess.run(args,cwd=source,env=env,capture_output=True,text=True,encoding='utf-8',errors='replace')
    (dest/f'{arch}.log').write_text(p.stdout+p.stderr,encoding='utf-8')
    r={'arch':arch,'rc':p.returncode,'seconds':round(time.monotonic()-start,1),'cmd':args}
    if out.exists():r.update(bytes=out.stat().st_size,sha256=hashlib.sha256(out.read_bytes()).hexdigest())
    else:r['error']=(p.stdout+p.stderr)[-4000:]
    results.append(r);print(json.dumps(r,ensure_ascii=False),flush=True)
(dest/'results.json').write_text(json.dumps(results,indent=2),encoding='utf-8')
