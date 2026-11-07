import json,pathlib,subprocess
base=pathlib.Path(__file__).resolve().parent;lab=base/'lab'/'csqtt'
def linux(p):return '/mnt/'+p.drive[0].lower()+'/'+p.as_posix()[3:]
prefix=lab/'toolchain'
args=['wsl','-e','sh','-c','cd "$1" && shift && exec "$@"','lab',linux(base/'repos'/'amurcanov__csqtt'/'rust-client'),'env','CARGO_HOME='+linux(lab/'cargo-home'),'CARGO_TARGET_DIR='+linux(lab/'target'),'RUSTC='+linux(prefix/'bin'/'rustc'),'CARGO_BUILD_JOBS=2','PATH='+linux(prefix/'bin')+':/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',linux(prefix/'bin'/'cargo'),'test','--locked','--release','--bin','client','single_byte_tamper']
p=subprocess.run(args,capture_output=True,text=True,encoding='utf-8',errors='replace');(lab/'tamper-test.log').write_text(p.stdout+p.stderr,encoding='utf-8')
r={'rc':p.returncode,'out':p.stdout,'err_tail':p.stderr[-3500:],'scope':'upstream two single-byte tamper unit tests, not independent crypto audit'}
(lab/'tamper-test.json').write_text(json.dumps(r,indent=2),encoding='utf-8');print(json.dumps(r),flush=True)
