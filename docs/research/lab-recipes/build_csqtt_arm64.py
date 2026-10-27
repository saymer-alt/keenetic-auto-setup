import hashlib,json,pathlib,subprocess,tomllib,urllib.request
base=pathlib.Path(__file__).resolve().parent;lab=base/'lab'/'csqtt';prefix=lab/'toolchain';target='aarch64-unknown-linux-musl'
def linux(p):return '/mnt/'+p.drive[0].lower()+'/'+p.as_posix()[3:]
def run(args):return subprocess.run(['wsl','-e']+args,capture_output=True,text=True,encoding='utf-8',errors='replace')
m=tomllib.loads((base/'evidence'/'rust-1.97.1.toml').read_text());entry=m['pkg']['rust-std']['target'][target];url=entry['xz_url'];archive=lab/url.rsplit('/',1)[1]
if not archive.exists():urllib.request.urlretrieve(url,archive)
sha=hashlib.sha256(archive.read_bytes()).hexdigest()
assert sha==entry['xz_hash']
r=run(['tar','-xJf',linux(archive),'-C',linux(lab)]);assert r.returncode==0,r.stderr
r=run(['sh',linux(lab/archive.name[:-7]/'install.sh'),'--prefix='+linux(prefix),'--disable-ldconfig']);assert r.returncode==0,r.stderr
cc=base/'lab'/'obfuscator'/target/'bin'/(target+'-gcc');ar=cc.parent/(target+'-ar');assert cc.exists(),cc
env=['env','CARGO_HOME='+linux(lab/'cargo-home'),'CARGO_TARGET_DIR='+linux(lab/'target'),'RUSTC='+linux(prefix/'bin'/'rustc'),'CARGO_BUILD_JOBS=4','PATH='+linux(prefix/'bin')+':/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin','CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER='+linux(cc),'CC_aarch64_unknown_linux_musl='+linux(cc),'AR_aarch64_unknown_linux_musl='+linux(ar)]
cmd=['sh','-c','cd "$1" && shift && exec "$@"','lab',linux(base/'repos'/'amurcanov__csqtt'/'rust-client')]+env+[linux(prefix/'bin'/'cargo'),'build','--locked','--release','--bin','client','--target',target]
print('Starting isolated ARM64 musl client build.',flush=True);r=run(cmd)
(lab/'arm64-build.log').write_text(r.stdout+r.stderr,encoding='utf-8')
result={'rc':r.returncode,'target':target,'rust_std':{'url':url,'sha256':sha},'log_tail':(r.stdout+r.stderr)[-6000:]}
out=lab/'target'/target/'release'/'client'
if out.exists():
    result.update(bytes=out.stat().st_size,sha256=hashlib.sha256(out.read_bytes()).hexdigest())
    result['elf']=run(['readelf','-h','-l','-A',linux(out)]).stdout
    p=run(['qemu-aarch64',linux(out),'--help']);result['startup']={'rc':p.returncode,'out':p.stdout+p.stderr,'scope':'CLI parser only; --help disabled in upstream clap build'}
(lab/'arm64-result.json').write_text(json.dumps(result,indent=2),encoding='utf-8');print(json.dumps(result,ensure_ascii=False),flush=True)
