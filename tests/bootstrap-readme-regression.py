#!/usr/bin/env python3
"""Exercise documented KAS quick launch and separate staged advanced first-fetch.

The project owner explicitly accepted the first-stream curl | sh risk (#180).
This test does NOT pretend to validate streamed script before execution.
Everything is offline: fake curl and opkg; no router/network is touched.
"""
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
QUICK = re.compile(r"(?m)^opkg update && opkg install curl && curl -fSsL[^\n]* \| sh$")
ADVANCED = re.compile(
    r"\x60{3}bash\n(opkg update && opkg install curl && sh -c '\n[\s\S]*?\n')\n\x60{3}"
)
GOOD = "#!/bin/sh\n# KAS_FIRSTFETCH_V1\nprintf 'LAUNCHER_RAN\\n'\n"
MOCK = r"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
a = sys.argv[1:]
assert '-fSsL' in a
if '-o' in a:
    assert '--connect-timeout' in a and a[a.index('--connect-timeout')+1] == '7'
    assert '--max-time' in a and a[a.index('--max-time')+1] == '25'
else:
    assert '--connect-timeout' not in a and '--max-time' not in a
assert '--insecure' not in a and '-k' not in a
url = next(x for x in a if x.startswith('https://'))
assert url.endswith('/stable/bootstrap.sh') or url.endswith('/contents/bootstrap.sh?ref=stable')
phase = 'api' if 'api.github.com' in url else 'ipv4' if '--curves' in a else 'raw'
if phase == 'ipv4':
    assert '-4' in a and a[a.index('--curves')+1] == 'X25519'
if phase == 'api':
    assert '-4' in a and 'Accept: application/vnd.github.raw+json' in a
if '-o' in a:
    assert '-fSsL' in a
else:
    assert '-fSsL' in a
lab = Path(os.environ['LAB'])
f = lab/'calls.json'
log = json.loads(f.read_text()) if f.exists() else []
log.append(phase); f.write_text(json.dumps(log))
kind = json.loads((lab/'plan.json').read_text()).get(phase, 'fail')
payload = {
    'good':os.environ['GOOD'],
    'html':'<html>bad</html>',
    'json':'{"content":"base64"}',
    'bad':'#!/bin/sh\n# KAS_FIRSTFETCH_V1\nif then\n',
    'empty':'',
    'fail':'',
}[kind]
if '-o' in a:
    Path(a[a.index('-o')+1]).write_text(payload)
else:
    sys.stdout.write(payload); sys.stdout.flush()
if kind == 'fail':
    print('curl: (28) Operation timed out', file=sys.stderr)
    sys.exit(28)
"""

def extract():
    quick = None
    for path in DOCS:
        text = (ROOT/path).read_text()
        found = QUICK.findall(text)
        is_readme = path in ('README.md', 'docs/EN/README.md')
        expected_count = 2 if is_readme else 1
        assert len(found) == expected_count, (path, 'missing or duplicated install command', found)
        cmd = found[0]
        assert all(candidate == cmd for candidate in found), (path, 'inconsistent repeated install commands')
        if is_readme:
            assert len(text) <= 8000, (path, 'README grew beyond the owner-approved quick-start budget', len(text))
            headings = ('## Частые команды', '## 1. Установка') if path == 'README.md' else ('## Common commands', '## 1. Installation')
            first, second = (text.index(heading) for heading in headings)
            assert first < second, (path, 'readme section order changed')
            assert cmd in text[first:second], (path, 'missing command under Common commands')
            assert cmd in text[second:text.index('## 2.', second)], (path, 'missing command in Installation section')
        assert len(cmd) <= 190, (path, len(cmd))
        for item in ('opkg update && opkg install curl', 'curl -fSsL https://',
                     '/stable/bootstrap.sh', ' | sh'):
            assert item in cmd, (path, 'missing', item)
        assert 'https://' in cmd and '--insecure' not in cmd and 'http://' not in cmd
        assert '--connect-timeout' not in cmd and '--max-time' not in cmd and ' -m ' not in cmd, (path, 'quick command must not use explicit timeouts')
        if quick is None: quick = cmd
        assert quick == cmd, (path, 'inconsistent quick command')
        if path != 'docs/03-install.md':
            assert not ADVANCED.search(text), (path, 'advanced-only command duplicated')
    advanced = ADVANCED.findall((ROOT/'docs/03-install.md').read_text())
    assert len(advanced) == 1, 'advanced three-source fallback must stay available'
    full = advanced[0]
    assert 'fetch -4 --curves X25519 "$RAW"' in full
    assert 'KAS_FIRSTFETCH_V1' in full and 'sh -n "$f"' in full
    assert 'api.github.com' in full
    return quick, full

def trial(shell, command, plan, calls, expected_status, starts, expect_curl_error=False):
    with tempfile.TemporaryDirectory(prefix='kas-quick-firstfetch-') as d:
        lab = Path(d)
        bin_dir = lab/'bin'
        bin_dir.mkdir()
        (bin_dir/'curl').write_text(MOCK)
        (bin_dir/'curl').chmod(0o700)
        (bin_dir/'opkg').write_text('#!/bin/sh\nexit 0\n')
        (bin_dir/'opkg').chmod(0o700)
        (bin_dir/'mktemp').write_text(
            '#!/bin/sh\ntouch "$LAB/stage" || exit 1\nprintf "%s\\n" "$LAB/stage"\n'
        )
        (bin_dir/'mktemp').chmod(0o700)
        (lab/'plan.json').write_text(json.dumps(plan))
        env = dict(os.environ, LAB=d, GOOD=GOOD,
                   PATH=str(bin_dir)+os.pathsep+os.environ.get('PATH', ''))
        proc = subprocess.run(shell+['-c', command], cwd=ROOT, env=env,
                              capture_output=True, text=True, timeout=15)
        got = json.loads((lab/'calls.json').read_text()) if (lab/'calls.json').exists() else []
        assert got == calls, (shell, plan, got, calls)
        assert proc.returncode == expected_status, (shell, plan, proc.returncode, proc.stderr)
        assert ('LAUNCHER_RAN' in proc.stdout) == starts, (shell, plan, proc.stdout, proc.stderr)
        assert not (lab/'stage').exists(), (shell, 'advanced temp remains')
        if expect_curl_error:
            assert 'curl: (28)' in proc.stderr, (shell, proc.stderr)
        print('PASS', shell, 'quick' if ' | sh' in command else 'staged', plan)

def main():
    short, full = extract()
    shells = [['/bin/sh']]
    bb = shutil.which('busybox')
    if bb:
        shells.append([bb, 'ash'])
    for sh in shells:
        trial(sh, short, {'raw':'good'}, ['raw'], 0, True)
        trial(sh, short, {'raw':'empty'}, ['raw'], 0, False)
        # Accepted pipeline limitation: empty failed first-fetch can return 0
        # from sh even when curl returned 28; the error remains visible on stderr.
        trial(sh, short, {'raw':'fail'}, ['raw'], 0, False, expect_curl_error=True)
        trial(sh, full, {'raw':'good'}, ['raw'], 0, True)
        trial(sh, full, {'raw':'html', 'ipv4':'good'}, ['raw','ipv4'], 0, True)
        trial(sh, full, {'api':'good'}, ['raw','ipv4','api'], 0, True)
        trial(sh, full, {}, ['raw','ipv4','api'], 1, False, expect_curl_error=True)
    print('PASS: 10 consistent short HTTPS commands; advanced first-fetch retained.')
    print('KNOWN LIMITATION: POSIX curl | sh can mask failed/empty first-fetch exit status.')

if __name__ == '__main__':
    main()
