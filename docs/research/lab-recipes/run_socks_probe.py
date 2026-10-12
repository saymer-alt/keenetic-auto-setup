import json,os,pathlib,subprocess
b=pathlib.Path(__file__).resolve().parent;d=b/'lab'/'socks';d.mkdir(exist_ok=True)
(d/'main.go').write_bytes((b/'socks_probe.go').read_bytes());(d/'go.mod').write_text('module lab-socks\n\ngo 1.27\n\nrequire github.com/armon/go-socks5 v0.0.0-20160902184237-e75332964ef5\n',encoding='utf-8')
env=os.environ.copy();env.update(GOPATH=str(b/'lab'/'gopath'),GOCACHE=str(b/'lab'/'gocache'),GOTOOLCHAIN='local',GOPROXY='https://proxy.golang.org')
p=subprocess.run(['go','run','-mod=mod','.'],cwd=d,env=env,capture_output=True,text=True,encoding='utf-8',errors='replace');r={'rc':p.returncode,'out':p.stdout,'err':p.stderr};(d/'result.json').write_text(json.dumps(r,indent=2),encoding='utf-8');print(json.dumps(r),flush=True)
