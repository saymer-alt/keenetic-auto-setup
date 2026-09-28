#!/usr/bin/env python3
"""Run the production installer downloader with recorded partial transports.

Real temp files, shell validation and rename; only curl/wget and retry sleep
are stubbed. Contents API uses raw media in production, not a JSON decoder.
"""
from pathlib import Path
import json
import os
import subprocess
import tempfile
import sys

ROOT = Path(__file__).resolve().parents[1]
PARTIAL = '#!/bin/sh\necho truncated\n'
COMPLETE = '#!/bin/sh\necho complete\necho end\n'
ORIGINAL = '#!/bin/sh\necho original\n'
TRANSPORT = r'''
import json, os, sys
from pathlib import Path
lab=Path(os.environ['LAB']); args=sys.argv[2:]; method=sys.argv[1]
url=next(a for a in args if a.startswith('https://'))
base_method=method
if 'api.github.com' in url:
    base_method='api'
    assert 'Accept: application/vnd.github.raw+json' in args
    assert 'X-GitHub-Api-Version: 2022-11-28' in args
    assert url.endswith('?ref=fixture-ref')
else:
    assert '/fixture-ref/helper.sh' in url
method=base_method + ('-x25519' if '--curves' in args else '')
if '--curves' in args:
    assert args[args.index('--curves')+1] == 'X25519'
    assert '-4' in args
    assert '--connect-timeout' in args and '--max-time' in args
dest=Path(args[args.index('-o' if base_method != 'wget' else '-qO')+1])
plan=json.loads((lab/'plan').read_text())
counter=lab/('count-'+method)
n=int(counter.read_text()) if counter.exists() else 0
counter.write_text(str(n+1))
actions=plan.get(method, plan.get(base_method, ['fail']))
action=actions[min(n,len(actions)-1)]
with (lab/'events').open('a') as f:
    f.write(json.dumps(dict(method=method,action=action,existed=dest.exists()))+'\n')
if action=='partial':
    dest.write_text('#!/bin/sh\necho truncated\n'); sys.exit(18 if base_method!='wget' else 4)
if action=='fail': sys.exit(18)
if action=='complete': dest.write_text('#!/bin/sh\necho complete\necho end\n')
if action=='invalid': dest.write_text('#!/bin/sh\nif then\n')
if action=='no-shebang': dest.write_text('echo complete\n')
sys.exit(0)
'''


def function(text, name):
    start=text.index(name+'() {')
    return text[start:text.index('\n}',start)+2]+'\n'


def run(shell, name, plan, success, baseline=False):
    text=(subprocess.check_output(['git','show','fa3a45f208bf5a8a841f6269d668d471a4fead02:install.sh'],cwd=ROOT,text=True)
          if baseline else (ROOT/'install.sh').read_text())
    names=['retry_silent','project_script_candidate_ok','project_script_download']
    if 'project_script_transfer() {' in text:
        names.insert(1,'project_script_transfer')
    if 'project_script_curl_retry() {' in text:
        names.insert(2,'project_script_curl_retry')
    functions=''.join(function(text,n) for n in names)
    with tempfile.TemporaryDirectory(prefix='mihomo-download-') as directory:
        lab=Path(directory)
        (lab/'transport.py').write_text(TRANSPORT)
        (lab/'plan').write_text(json.dumps(plan))
        (lab/'canonical').write_text(ORIGINAL)
        (lab/'original').write_text(ORIGINAL)
        inode=(lab/'canonical').stat().st_ino
        body='''set -e
TMP_DIR="$LAB"
PROJECT_REF=fixture-ref
PROJECT_RAW_BASE=https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/$PROJECT_REF
PROJECT_API_CONTENTS=https://api.github.com/repos/saymer-alt/keenetic-auto-setup/contents
sleep() { :; }
warn() { echo "$1"; }
curl() { python3 "$LAB/transport.py" curl "$@"; }
wget() { python3 "$LAB/transport.py" wget "$@"; }
sh() { echo "validate:$2" >> "$LAB/order"; command sh "$@"; }
mv() {
    cmp -s "$LAB/canonical" "$LAB/original" || exit 92
    echo "commit:$2" >> "$LAB/order"
    command mv "$@"
}
'''+functions+'''
# A stale valid prefix from a previous call must also be invalidated.
printf '#!/bin/sh\\necho stale\\n' > "$TMP_DIR/.keenetic-auto-setup-download.$$"
project_script_download helper.sh "$LAB/canonical"
'''
        p=subprocess.run(shell,input=body,env=dict(os.environ,LAB=str(lab)),text=True,capture_output=True,timeout=20)
        dest=(lab/'canonical').read_text()
        events=[json.loads(line) for line in (lab/'events').read_text().splitlines()]
        order=(lab/'order').read_text().splitlines() if (lab/'order').exists() else []
        detail=(shell,name,p.returncode,dest,events,order,p.stdout,p.stderr)
        if baseline:
            assert p.returncode==0 and dest==PARTIAL,detail
            print('CONFIRMED B5',shell,'rc=0; canonical replaced by valid-shell partial after API rc=18',flush=True)
            return
        assert (p.returncode==0)==success,detail
        assert dest==(COMPLETE if success else ORIGINAL),detail
        assert not list(lab.glob('.keenetic-auto-setup-download.*')),detail
        assert not list(lab.glob('canonical.new.*')),detail
        assert all(not event['existed'] for event in events),detail
        if success:
            assert order[-1].startswith('commit:'),detail
            assert order[-2]=='validate:'+order[-1].split(':',1)[1],detail
            assert Path(order[-1].split(':',1)[1]).parent==lab,detail
            assert (lab/'canonical').stat().st_ino!=inode,detail
        else:
            assert not any(event.startswith('commit:') for event in order),detail
            assert (lab/'canonical').stat().st_ino==inode,detail
        # Normal transports retain three attempts. The X25519 compatibility
        # retry is a single bounded attempt before advancing to wget/API.
        methods=[e['method'] for e in events]
        order_methods=['curl','curl-x25519','wget','api','api-x25519']
        assert methods==sorted(methods,key=order_methods.index),detail
        for method in ['curl','wget','api']:
            used=[e for e in events if e['method']==method]
            if used and used[-1]['action'] in {'partial','fail'}:
                assert len(used)==3,detail
        for method in ['curl-x25519','api-x25519']:
            used=[e for e in events if e['method']==method]
            assert len(used)<=1,detail
        assert p.stderr=='',detail
        print('PASS','/'.join(shell),name,flush=True)


def main():
    for shell in [['sh'],['busybox','ash']]:
        if '--baseline' in sys.argv:
            run(shell,'baseline',dict(curl=['partial'],wget=['partial'],api=['partial']),False,True)
            continue
        cases=[
            ('curl partial', ['partial'], ['fail'], ['fail'], False),
            ('wget partial', ['fail'], ['partial'], ['fail'], False),
            ('API partial', ['fail'], ['fail'], ['partial'], False),
            ('all partial', ['partial'], ['partial'], ['partial'], False),
            ('curl complete', ['complete'], ['fail'], ['fail'], True),
            ('wget complete after curl partial', ['partial'], ['complete'], ['fail'], True),
            ('API complete after raw partials', ['partial'], ['partial'], ['complete'], True),
            ('all invalid syntax', ['invalid'], ['invalid'], ['invalid'], False),
            ('all missing shebang', ['no-shebang'], ['no-shebang'], ['no-shebang'], False),
            ('curl retry complete', ['partial','complete'], ['fail'], ['fail'], True),
            ('wget retry complete', ['fail'], ['partial','complete'], ['fail'], True),
            ('API retry complete', ['fail'], ['fail'], ['partial','complete'], True),
            ('curl retry no output', ['partial','empty-success'], ['fail'], ['fail'], False),
            ('wget retry no output', ['fail'], ['partial','empty-success'], ['fail'], False),
            ('API retry no output', ['fail'], ['fail'], ['partial','empty-success'], False),
        ]
        for name,curl,wget,api,success in cases:
            run(shell,name,dict(curl=curl,wget=wget,api=api),success)
        run(shell,'curl X25519 compatibility',
            dict(curl=['fail'], **{'curl-x25519':['complete']}, wget=['fail'], api=['fail']), True)
        run(shell,'API X25519 compatibility',
            dict(curl=['fail'], **{'curl-x25519':['fail']}, wget=['fail'],
                 api=['fail'], **{'api-x25519':['complete']}), True)


if __name__=='__main__':
    main()
