#!/usr/bin/env python3
"""EG-02: execute the shared standalone consumer contract under dash/BusyBox."""
import json
from pathlib import Path
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[1]
texts = [(ROOT / name).read_text() for name in ('install.sh', 'update-mihomo.sh')]
def block(text):
    a = text.index('# BEGIN MIHOMO PACKAGE SELECTION')
    b = text.index('# END MIHOMO PACKAGE SELECTION', a)
    return text[a:b]
assert block(texts[0]) == block(texts[1]), 'Installer/updater selector diverged'
helpers = block(texts[0])
PREFIX = 'https://github.com/saymer-alt/entware-go/releases/download/latest/'
def url(version, suffix='mipsel-3.4', package='mihomo'):
    return PREFIX + f'{package}_{version}_{suffix}.ipk'
def run(shell, data, command, rc=0, expected=None, suffix='mipsel-3.4'):
    script = helpers + '\nIPK_SUFFIX='+suffix+'\nprintf "%s\\n" ' + shlex.quote(data) + ' | ' + command
    p = subprocess.run(shell, input=script, text=True, capture_output=True, timeout=10)
    assert p.returncode == rc, (shell, command, rc, p.returncode, p.stdout, p.stderr, data)
    if expected is not None:
        assert p.stdout.strip() == expected, (p.stdout, expected)

for shell in (['sh'], ['busybox', 'ash']):
    matrix = [
        ([url('1.9.0-1')], 0, url('1.9.0-1')),
        ([url('1.9.0-1'), url('1.10.0-1')], 0, url('1.10.0-1')),
        ([url('1.19.31-2'), url('1.19.32-1'), url('1.19.32-1', 'aarch64-3.10')], 0, url('1.19.32-1')),
        ([url('1.19.32-1'), url('1.19.31-2')], 0, url('1.19.32-1')),
        ([url('1.19.32-1'), url('1.19.32-2')], 0, url('1.19.32-2')),
        ([url('1.19.32-1'), url('1.19.32-1')], 2, ''),
        ([url('1.19.32-1'), url('1.19.32-1').replace('https://github.com','')], 2, ''),
        ([url('1.19.32+a-1'), url('1.19.32+b-1')], 2, ''),
        ([url('1.19.32-rc.2-1'), url('1.19.32-rc.10-1')], 0, url('1.19.32-rc.10-1')),
        ([url('1.19.32-rc.10-1'), url('1.19.32-1')], 0, url('1.19.32-1')),
        ([url('1.19.33-100-1'), url('1.19.33-1e2-1')], 0, url('1.19.33-1e2-1')),
        ([url('1.19.33-1e2-1'), url('1.19.33-100-1')], 0, url('1.19.33-1e2-1')),
        ([url('1.19.33-rc.1.a-1'), url('1.19.33-rc.1.b-1')], 0, url('1.19.33-rc.1.b-1')),
        ([url('1.19.33-rc.1.b-1'), url('1.19.33-rc.1.a-1')], 0, url('1.19.33-rc.1.b-1')),
        ([url('1.19.33-rc.9-1'), url('1.19.33-rc.10-1')], 0, url('1.19.33-rc.10-1')),
        ([url('1.19.33-rc.10-1'), url('1.19.33-rc.9-1')], 0, url('1.19.33-rc.10-1')),
        ([url('1.19.33-1'), url('1.19.33-rc.1-1')], 0, url('1.19.33-1')),
        ([url('1.19.33-rc.1-1'), url('1.19.33-1')], 0, url('1.19.33-1')),
        ([url('1.19.33-100-1'), url('1.19.33-100-2')], 0, url('1.19.33-100-2')),
        ([url('1.19.33-100-2'), url('1.19.33-100-1')], 0, url('1.19.33-100-2')),
        ([url('1.19.33-100-1'), url('1.19.33-100-1')], 2, ''),
        ([url('1.19.33-1000000000000000000001-1'), url('1.19.33-1000000000000000000002-1')], 0, url('1.19.33-1000000000000000000002-1')),
        ([url('1.19.32-1', package='mihomo_nohf')], 1, ''),
        ([url('1.19.32-1', 'mips-3.4')], 1, ''),
        ([url('1.19.32-1', 'mipsel-5.10')], 1, ''),
        ([url('1.bad-1')], 3, ''),
        ([url('01.19.32-1')], 3, ''),
        ([url('1.19.32-rc.01-1')], 3, ''),
        ([url('1.19.32-0')], 3, ''),
        ([url('1.19.32-1').replace('github.com', 'evil.example')], 3, ''),
        ([], 1, ''),
    ]
    for urls, rc, selected in matrix:
        run(shell, '\n'.join(urls), 'select_mihomo_asset', rc, selected)
        assets = [dict(name=u.rsplit('/',1)[1], browser_download_url=u, state='uploaded', size=123) for u in urls]
        # Empty releases have no usable candidate and must fail closed.
        run(shell, json.dumps(dict(tag_name='latest', assets=assets)), 'release_mihomo_asset', 3 if not urls else rc, selected)
    valid = dict(tag_name='latest', assets=[dict(name=url('1.19.32-1').rsplit('/',1)[1], browser_download_url=url('1.19.32-1'), size=1, state='uploaded')])
    for invalid in ('{', '{}', json.dumps(dict(valid, tag_name='foreign')), json.dumps(dict(valid, assets={})),
                    json.dumps(dict(valid, assets=[dict(valid['assets'][0], name='wrong.ipk')])),
                    json.dumps(dict(valid, assets=[dict(valid['assets'][0], size=0)]))):
        run(shell, invalid, 'release_mihomo_asset', 3, '')
    for arch in ('aarch64-3.10','armv7-3.2','mipsel-3.4','mips-3.4'):
        run(shell, f'arch all 1\narch {arch}_kn 10\narch {arch} 20', 'detect_mihomo_package_arch', 0, arch)
    for invalid in ('arch mipsel-5.10 10', 'arch arm-3.2 10', 'arch all 1',
                    'arch mips-3.4 10\narch mipsel-3.4 10'):
        run(shell, invalid, 'detect_mihomo_package_arch', 1, '')
    # Actual acquisition/selection call sites use these helpers, never head/grep on JSON.
    for text in texts:
        assert '| release_mihomo_asset)' in text
        assert 'opkg print-architecture | detect_mihomo_package_arch)' in text
    assert 'select_mihomo_asset) || err' in texts[0]  # HTML fallback
    assert 'GitHub Mihomo package unavailable, trying Entware feed fallback' in texts[0]
    assert 'Failed to fetch release information' in texts[1]
    acquisition = texts[0][texts[0].index('    API_URL="https://api.github.com/repos/'):texts[0].index('    # GitHub Releases are')]
    new = url('1.19.32-1')
    good_json = json.dumps(dict(tag_name='latest', assets=[dict(name=new.rsplit('/',1)[1], browser_download_url=new, size=1, state='uploaded')]))
    for metadata, html, rc, expected in [
        (good_json, '', 0, new),
        ('{', '<a href="'+new.replace('https://github.com','')+'">', 9, ''),
        ('', '<a href="'+new.replace('https://github.com','')+'">', 0, new),
        ('', '', 0, ''),  # API/HTML down: initial installation may use its existing feed fallback.
        (good_json.replace('mipsel-3.4','mips-3.4'), '', 9, ''),
    ]:
        script = helpers + '\nIPK_SUFFIX=mipsel-3.4\nREPO_OWNER=saymer-alt\nREPO_NAME=entware-go\n'
        script += 'MOCK_JSON='+shlex.quote(metadata)+'\nMOCK_HTML='+shlex.quote(html)+'\n'
        script += '''log() { :; }
err() { exit 9; }
fetch_url_text() {
 case "$1" in
  https://api.github.com/*) [ -n "$MOCK_JSON" ] || return 1; printf '%s' "$MOCK_JSON" ;;
  *) [ -n "$MOCK_HTML" ] || return 1; printf '%s' "$MOCK_HTML" ;;
 esac
}
'''+acquisition+'\nprintf "%s" "$DOWNLOAD_URL"\n'
        p = subprocess.run(shell, input=script, text=True, capture_output=True, timeout=10)
        assert p.returncode == rc and p.stdout == expected, (shell, p.returncode, p.stdout, p.stderr)
    fetch = texts[1][texts[1].index('RELEASE_JSON=$(fetch_text_with_fallback'):texts[1].index('# 5. Find currently installed mihomo')]
    p = subprocess.run(shell, input='error() { exit 9; }; log() { :; }; fetch_text_with_fallback() { return 1; }; REPO=saymer-alt/entware-go\n'+fetch,
                       text=True, capture_output=True, timeout=10)
    assert p.returncode == 9, 'Updater must stop on unavailable GitHub metadata'
    print('PASS', shell, 'EG-02 version/ABI/overlap/duplicates/metadata/API-unavailable paths')

    def healthy(version, arch, identity=1, package='mihomo'):
        u = url(version, arch, package)
        return dict(id=identity, name=u.rsplit('/',1)[1], browser_download_url=u, size=123,
                    state='uploaded', digest='sha256:'+'a'*64)

    def starter(arch, package='mihomo'):
        return dict(healthy('1.19.33-2', arch, 99, package), state='starter', size=0, digest=None)

    abis = ('aarch64-3.10','armv7-3.2','mipsel-3.4','mips-3.4')
    for arch in abis:
        good = healthy('1.19.32-2', arch)
        for other in abis:
            pending = starter(other)
            # Both asset orders, including an incomplete newer candidate of this ABI.
            for assets in ([good, pending], [pending, good]):
                run(shell, json.dumps(dict(tag_name='latest', assets=assets)), 'release_mihomo_asset',
                    0, good['browser_download_url'], arch)
        run(shell, json.dumps(dict(tag_name='latest', assets=[starter(arch)])), 'release_mihomo_asset', 1, '', arch)
        run(shell, json.dumps(dict(tag_name='latest', assets=[good, starter('armv7-3.2','mihomo_nohf')])),
            'release_mihomo_asset', 0, good['browser_download_url'], arch)
        run(shell, json.dumps(dict(tag_name='latest', assets=[good, good])), 'release_mihomo_asset', 2, '', arch)
        pending = starter(arch)
        for assets in ([good, pending, dict(pending,id=199)], [good,dict(pending,id=good['id'])],
                       [dict(good,name=pending['name'],browser_download_url=pending['browser_download_url']),pending]):
            run(shell, json.dumps(dict(tag_name='latest', assets=assets)), 'release_mihomo_asset', 3, '', arch)
        for change in (dict(id=0), dict(id=True), dict(size=1), dict(state='unknown'),
                       dict(digest='sha256:'+'a'*64), dict(name='mihomo_bad.ipk'),
                       dict(browser_download_url='https://evil.example/'+pending['name'])):
            run(shell, json.dumps(dict(tag_name='latest', assets=[good, dict(pending,**change)])),
                'release_mihomo_asset', 3, '', arch)
    # Exercise the actual acquisition section, not only the standalone selector.
    mixed = json.dumps(dict(tag_name='latest', assets=[healthy('1.19.32-2','mipsel-3.4'),starter('aarch64-3.10')]))
    script = helpers + '\nIPK_SUFFIX=mipsel-3.4\nREPO_OWNER=saymer-alt\nREPO_NAME=entware-go\n'
    script += 'MOCK_JSON='+shlex.quote(mixed)+'\nlog() { :; }; err() { exit 9; }; fetch_url_text() { printf "%s" "$MOCK_JSON"; };\n'
    p = subprocess.run(shell, input=script+acquisition+'\nprintf "%s" "$DOWNLOAD_URL"', text=True,capture_output=True,timeout=10)
    assert p.returncode == 0 and p.stdout == url('1.19.32-2'), (p.returncode,p.stdout,p.stderr)
    print('PASS', shell, 'F2 four-ABI starter isolation/strict metadata; F3 order-independent prerelease')
