#!/usr/bin/env python3
"""Offline exercise of the actual install snippet shared by ten project docs."""
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOCS = [
    "README.md", "docs/EN/README.md", "docs/02-quick-start.md",
    "docs/03-install.md", "docs/14-setup.md", "docs/EN/SETUP.md",
    "docs/HOWTO_RU.md", "docs/HOWTO.md", "docs/16-entware-external-storage.md",
    "docs/EN/ENTWARE_EXTERNAL_STORAGE.md",
]
COMMAND = re.compile(r"\x60{3}bash\n(opkg update && opkg install curl && sh -c '\n[\s\S]*?\n')\n\x60{3}")
QUICK_COMMAND = re.compile(r"\x60{3}bash\n(opkg update && opkg install curl && sh -c '[^\n]*')\n\x60{3}")
GOOD = "#!/bin/sh\n# KAS_FIRSTFETCH_V1\nprintf 'LAUNCHER_RAN\\n'\n"
MOCK = r"""#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
a=sys.argv[1:]
assert '-fSsL' in a and '--connect-timeout' in a and '--max-time' in a
assert a[a.index('--connect-timeout')+1]=='7' and a[a.index('--max-time')+1]=='25'
assert '-k' not in a and '--insecure' not in a
dest=Path(a[a.index('-o')+1])
url=next(x for x in a if x.startswith('https://'))
assert 'saymer-alt/keenetic-auto-setup' in url
assert url.endswith('/stable/bootstrap.sh') or url.endswith('/contents/bootstrap.sh?ref=stable')
phase='api' if 'api.github.com' in url else 'ipv4' if '--curves' in a else 'raw'
if phase=='ipv4':
    assert '-4' in a and a[a.index('--curves')+1]=='X25519'
if phase=='api':
    assert '-4' in a
    assert 'Accept: application/vnd.github.raw+json' in a
lab=Path(os.environ['LAB'])
f=lab/'calls.json'
log=json.loads(f.read_text()) if f.exists() else []
log.append(phase);f.write_text(json.dumps(log))
kind=json.loads((lab/'plan.json').read_text()).get(phase,'fail')
dest.write_text({'good':os.environ['GOOD'],'html':'<html>bad</html>',
'json':'{"content":"abc"}','bad':'#!/bin/sh\n# KAS_FIRSTFETCH_V1\nif then\n',
'fail':'#!/bin/sh\n# KAS_FIRSTFETCH_V1\necho PARTIAL_NOT_EXECUTED\n'}[kind])
if kind=='fail':sys.exit(28)
"""

def extract():
    """Full installer remains identical in all ten guides; README shortcuts are short and fail closed."""
    source = None
    quick_source = None
    for path in DOCS:
        text=(ROOT/path).read_text()
        matches=COMMAND.findall(text)
        assert matches, (path,'no install command')
        if path in ("README.md", "docs/EN/README.md"):
            assert len(matches) == 1, (path,'expected full fallback installer')
            compact = QUICK_COMMAND.findall(text)
            assert len(compact) == 1, (path,'must have exactly one single-line quick install')
            quick = compact[0]
            full = matches[0]
            assert '\\n' not in quick and len(quick) <= 400, (path,'quick install must be one reasonable line')
            for required in (
                'opkg update && opkg install curl',
                'umask 077', 'mktemp /tmp/kas.', 'trap ', '--connect-timeout 7 --max-time 25',
                '[ -s "$f" ]', 'head -n 1 "$f"', 'KAS_FIRSTFETCH_V1',
                'sh -n "$f"', 'sh "$f"'
            ):
                assert required in quick, (path,'unsafe or missing compact first-fetch check',required)
            assert ' | sh' not in quick and '--insecure' not in quick
            assert 'full' not in quick
            assert 'GitHub API' in text or 'GitHub Contents API' in text
            if quick_source is None: quick_source = quick
            assert quick_source == quick, (path,'RU/EN compact installer differ')
            matches = [full]
        if source is None: source=matches[0]
        assert all(x==source for x in matches), (path,'detailed full-fallback installer differs')
    assert 'fetch -4 --curves X25519 "$RAW"' in source
    assert 'sh -n "$f"' in source
    return source, quick_source

def trial(sh,source,plan,calls,works):
    with tempfile.TemporaryDirectory(prefix='kas-readme-') as d:
        lab=Path(d);bin=lab/'bin';bin.mkdir()
        (bin/'curl').write_text(MOCK);(bin/'curl').chmod(0o700)
        (bin/'mktemp').write_text('#!/bin/sh\ntouch "$LAB/stage" || exit 1\nprintf "%s\\n" "$LAB/stage"\n')
        (bin/'mktemp').chmod(0o700)
        (bin/'opkg').write_text('#!/bin/sh\nexit 0\n');(bin/'opkg').chmod(0o700)
        (lab/'plan.json').write_text(json.dumps(plan))
        env=os.environ.copy()
        env.update(PATH=str(bin)+os.pathsep+os.environ.get('PATH',''),LAB=d,GOOD=GOOD)
        r=subprocess.run(sh+['-c',source],cwd=ROOT,env=env,capture_output=True,text=True,timeout=15)
        got=json.loads((lab/'calls.json').read_text())
        assert got==calls,(sh,plan,got,r.stdout,r.stderr)
        assert (r.returncode==0)==works,(sh,plan,r.returncode,r.stdout,r.stderr)
        assert ('LAUNCHER_RAN' in r.stdout)==works,(sh,plan,r.stdout)
        assert 'PARTIAL_NOT_EXECUTED' not in r.stdout,(sh,plan)
        assert not (lab/'stage').exists(),(sh,plan,'temp file remains')
        print('PASS',sh,plan)

def main():
    source, quick = extract()
    shells=[['/bin/sh']]
    if shutil.which('busybox'):shells.append([shutil.which('busybox'),'ash'])
    for sh in shells:
        for kind, works in [('good',True),('html',False),('json',False),('bad',False),('fail',False)]:
            trial(sh,quick,{'raw':kind},['raw'],works)
        trial(sh,source,{'raw':'good'},['raw'],True)
        trial(sh,source,{'raw':'html','ipv4':'good'},['raw','ipv4'],True)
        trial(sh,source,{'api':'good'},['raw','ipv4','api'],True)
        trial(sh,source,{'raw':'bad','ipv4':'bad','api':'bad'},['raw','ipv4','api'],False)
        trial(sh,source,{},['raw','ipv4','api'],False)
    print('PASS: RU/EN safe compact command + full three-path fallback across all 10 docs')

if __name__=='__main__':main()
