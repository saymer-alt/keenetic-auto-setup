#!/usr/bin/env python3
"""Execute the real Doctor availability section with reordered release fixtures.

No network, process probes, router files or commands: only metadata and report text.
"""
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
doctor = (ROOT / 'mihomo-doctor.sh').read_text()
updater = (ROOT / 'update-mihomo.sh').read_text()

def block(text):
    start = text.index('# BEGIN MIHOMO PACKAGE SELECTION')
    end = text.index('# END MIHOMO PACKAGE SELECTION', start)
    return text[start:end]

def function(text, name):
    start = text.index(name + '() {')
    return text[start:text.index('\n}', start) + 2] + '\n'

section = doctor[doctor.index('hdr "10. entware-go package availability"'):doctor.index('# Summary\n')]
helpers = block(updater) + '\n' + function(doctor, 'ver_compare')
prefix = 'https://github.com/saymer-alt/entware-go/releases/download/latest/'

def asset(version, arch='mipsel-3.4', package='mihomo'):
    return f'{package}_{version}_{arch}.ipk'

def run(shell, names, expected, jq_enabled=True):
    assets = [dict(id=i+1, name=name, browser_download_url=prefix+name,
                   state='uploaded', size=123) for i, name in enumerate(names)]
    raw = json.dumps(dict(tag_name='latest', assets=assets))
    setup = helpers + '\n' + '''
NET_GITHUB=1; IPK_SUFFIX=mipsel-3.4; ENTWARE_REPO=saymer-alt/entware-go; BIN_VER=1.19.33
hdr(){ :; }; ok(){ printf 'OK %s\\n' "$*"; }; info(){ printf 'INFO %s\\n' "$*"; }; warn(){ printf 'WARN %s\\n' "$*"; }
RELEASE_JSON=$(cat <<'FIXTURE_JSON'
''' + raw + '\nFIXTURE_JSON\n)\n'
    if not jq_enabled:
        setup += 'command(){ return 1; }\n'  # section only queries command -v jq
    p = subprocess.run(shell, input=setup+section, text=True, capture_output=True, timeout=10)
    assert p.returncode == 0, (shell, p.stdout, p.stderr)
    if expected:
        assert f'available in saymer-alt/entware-go:latest - {expected}' in p.stdout, (shell, jq_enabled, p.stdout)
        if expected == asset('1.19.33-2'):
            assert 'Installed version matches entware-go:latest (1.19.33)' in p.stdout, p.stdout
    else:
        assert 'OK Package for' not in p.stdout, (shell, jq_enabled, p.stdout)

shells = [['sh']]
if shutil.which('busybox'):
    shells.append(['busybox', 'ash'])
else:
    print('SKIP: BusyBox unavailable locally; CI installs it and executes this test')

for shell in shells:
    for jq_enabled in (True, False):
        for names, expected in [
            ([asset('1.19.32-2'), asset('1.19.33-2')], asset('1.19.33-2')),
            ([asset('1.19.33-2'), asset('1.19.32-2')], asset('1.19.33-2')),
            ([asset('1.19.33-2'), asset('1.19.33-10')], asset('1.19.33-10')),
            ([asset('1.9.0-9'), asset('1.10.0-1')], asset('1.10.0-1')),
            ([asset('1.20.0-1', 'aarch64-3.10'), asset('1.20.0-1', package='mihomo_nohf'), asset('1.19.33-2')], asset('1.19.33-2')),
            ([asset('1.19.33-2'), asset('1.19.33-2')], None),
            ([asset('1.19.33-0')], None),
            ([asset('1.20.0-1', 'mips-3.4')], None),
        ]:
            run(shell, names, expected, jq_enabled)
    print('PASS:', shell, 'Doctor exact availability section: jq/no-jq, reversed versions, numeric release, ABI/nohf, ambiguity')

assert block(doctor) == block(updater), 'Doctor selector diverged from canonical updater'
assert block(doctor) == block((ROOT / 'install.sh').read_text()), 'Doctor selector diverged from installer'
