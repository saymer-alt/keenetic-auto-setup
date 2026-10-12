import concurrent.futures, hashlib, json, os, pathlib, subprocess, tomllib, urllib.request
base=pathlib.Path(__file__).resolve().parent
lab=base/'lab'/'csqtt'; lab.mkdir(parents=True,exist_ok=True)
manifest=tomllib.loads((base/'evidence'/'rust-1.97.1.toml').read_text())
prefix=lab/'toolchain'
def linux(p):return '/mnt/'+p.drive[0].lower()+'/'+p.as_posix()[3:]
def wsl(args, timeout=None):
    return subprocess.run(['wsl','-e']+args,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=timeout)
def download(pkg):
    entry=manifest['pkg'][pkg]['target']['x86_64-unknown-linux-gnu']
    url=entry['xz_url'];archive=lab/url.rsplit('/',1)[1]
    if not archive.exists():urllib.request.urlretrieve(url,archive)
    sha=hashlib.sha256(archive.read_bytes()).hexdigest()
    if sha!=entry['xz_hash']:raise RuntimeError('digest '+pkg)
    r=wsl(['tar','-xJf',linux(archive),'-C',linux(lab)])
    if r.returncode:raise RuntimeError(r.stderr)
    return {'component':pkg,'url':url,'sha256':sha,'dir':archive.name[:-7]}
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
    downloads=list(pool.map(download,['rustc','cargo','rust-std']))
for d in downloads:
    r=wsl(['sh',linux(lab/d['dir']/'install.sh'),'--prefix='+linux(prefix),'--disable-ldconfig'])
    if r.returncode:raise RuntimeError(r.stderr)
(lab/'toolchain.json').write_text(json.dumps(downloads,indent=2),encoding='utf-8')
env=['env','CARGO_HOME='+linux(lab/'cargo-home'),'CARGO_TARGET_DIR='+linux(lab/'target'),
     'RUSTC='+linux(prefix/'bin'/'rustc'),'CARGO_BUILD_JOBS=4','PATH='+linux(prefix/'bin')+':/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin']
cmd=['sh','-c','cd "$1" && shift && exec "$@"','lab',linux(base/'repos'/'amurcanov__csqtt'/'rust-client')]+env+[linux(prefix/'bin'/'cargo'),'build','--locked','--release','--bin','client']
print('Rust toolchain installed in isolated lab; starting locked native client build.',flush=True)
r=wsl(cmd)
(lab/'build.log').write_text(r.stdout+r.stderr,encoding='utf-8')
result={'rc':r.returncode,'target':'x86_64-unknown-linux-gnu','log_tail':(r.stdout+r.stderr)[-7000:]}
out=lab/'target'/'release'/'client'
if out.exists():result.update(bytes=out.stat().st_size,sha256=hashlib.sha256(out.read_bytes()).hexdigest())
(lab/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
print(json.dumps(result,ensure_ascii=False),flush=True)
