import concurrent.futures, hashlib, json, pathlib, re, subprocess, time, urllib.request
base=pathlib.Path(__file__).resolve().parent
lab=base/'lab'/'obfuscator'; lab.mkdir(parents=True,exist_ok=True)
src=base/'repos'/'ClusterM__wg-obfuscator'
prefix='https://github.com/cross-tools/musl-cross/releases/download/20250520/'
def linux(p):return '/mnt/'+p.drive[0].lower()+'/'+p.as_posix()[3:]
def run(args):
    p=subprocess.run(['wsl','-e']+args,capture_output=True,text=True,encoding='utf-8',errors='replace')
    return {'rc':p.returncode,'out':p.stdout,'err':p.stderr}
def build(target):
    arch,triplet=target
    rec={'arch':arch,'source':'7008e0ce1ea71a39ce4b50ec9c10d2ce50e9183f'}
    flags=[]
    if triplet:
        name=triplet+'.tar.xz'; archive=lab/name
        expected=urllib.request.urlopen(prefix+name+'.sha256').read().decode().split()[0]
        if not archive.exists():urllib.request.urlretrieve(prefix+name,archive)
        actual=hashlib.sha256(archive.read_bytes()).hexdigest()
        if actual!=expected:raise RuntimeError('toolchain digest mismatch '+arch)
        rec.update(toolchain_url=prefix+name,toolchain_sha256=actual)
        extracted=lab/triplet
        if not extracted.exists():
            r=run(['tar','-xJf',linux(archive),'-C',linux(lab)])
            if r['rc']:raise RuntimeError(r)
        cc=linux(extracted/'bin'/(triplet+'-gcc'))
        if arch in ['mips','mipsel']:flags=['-march=mips32','-mabi=32','-msoft-float']
    else:cc='gcc'
    out=lab/f'wg-obfuscator-linux-{arch}'
    args=[cc,'-O2','-Wall','-pthread','-static','-s']+flags+['-o',linux(out)]+[linux(src/f) for f in ['wg-obfuscator.c','config.c','masking.c','masking_stun.c','obfuscation.c','logging.c']]
    r=run(args);rec.update(r);rec['cmd']=args
    (lab/f'{arch}.log').write_text(r['out']+r['err'],encoding='utf-8')
    if out.exists():
        rec.update(bytes=out.stat().st_size,sha256=hashlib.sha256(out.read_bytes()).hexdigest())
        rec['elf']=run(['readelf','-h','-A','-l',linux(out)])
    (lab/f'{arch}.json').write_text(json.dumps(rec,indent=2),encoding='utf-8')
    print(json.dumps({k:v for k,v in rec.items() if k not in ['cmd','elf','out']},ensure_ascii=False),flush=True)
    return rec
targets=[('amd64',None),('arm64','aarch64-unknown-linux-musl'),('mipsel','mipsel-unknown-linux-muslsf'),('mips','mips-unknown-linux-muslsf')]
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    results=list(pool.map(build,targets))
(lab/'results.json').write_text(json.dumps(results,indent=2),encoding='utf-8')
