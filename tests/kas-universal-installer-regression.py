from pathlib import Path
import tempfile, subprocess, os, textwrap
SRC=(Path(__file__).resolve().parents[1] / 'kas-universal-install.sh').read_text()
ABIS=['aarch64-3.10','armv7-3.2','mipsel-3.4','mips-3.4','mipsel-3.4_kn','unsupported-x','multiple']

def run(abi, mode='check', failcurl=False, corrupt=False):
    with tempfile.TemporaryDirectory() as td:
        root=Path(td); bin=root/'bin';bin.mkdir()
        cmd=(SRC.replace('PATH=/opt/bin:/opt/sbin:/usr/bin:/usr/sbin:/bin:/sbin',f'PATH={bin}:/usr/bin:/bin:/sbin:/usr/sbin'))
        path=root/'installer.sh';path.write_text(cmd)
        (bin/'opkg').write_text('#!/bin/sh\ncase "$1" in\n print-architecture) case "$TEST_ABI" in multiple) printf "arch all 1\\narch aarch64-3.10 10\\narch mipsel-3.4 10\\n" ;; *) printf "arch all 1\\narch %s 10\\n" "$TEST_ABI" ;; esac;;\n status) exit 0;;\n install) echo install >> "$TEST_LOG";;\n *) echo unexpected-opkg-$1 >&2;exit 91;;\nesac\n')
        (bin/'opkg').chmod(0o755)
        if mode=='web':
            (bin/'curl').write_text('#!/bin/sh\nif [ "$TEST_FAILCURL" = 1 ]; then exit 22; fi\nwhile [ "$#" -gt 0 ]; do\n  if [ "$1" = -o ]; then shift; printf "badipk" > "$1";break;fi\n  shift\ndone\nexit 0\n')
            (bin/'curl').chmod(0o755)
            (bin/'sleep').write_text('#!/bin/sh\nexit 0\n');(bin/'sleep').chmod(0o755)
        env=dict(os.environ, TEST_ABI=abi,TEST_LOG=str(root/'install.log'),TEST_FAILCURL='1' if failcurl else '0')
        p=subprocess.run(['sh',str(path),mode],capture_output=True,text=True,env=env,timeout=5)
        return p.returncode,(p.stdout+p.stderr), (root/'install.log').exists()

for abi in ABIS:
    rc,out,installed=run(abi)
    expected=abi not in ['unsupported-x','multiple']
    assert (rc==0)==expected,(abi,rc,out)
    assert not installed,abi
    if expected:assert f'Entware ABI: {abi.removesuffix("_kn")}' in out
    print(abi, 'PASS')
for failcurl in [True,False]:
    rc,out,installed=run('mipsel-3.4','web',failcurl=failcurl)
    assert rc!=0 and not installed,(rc,out,installed)
    print('web curl-failure' if failcurl else 'web invalid-hash','PASS')
