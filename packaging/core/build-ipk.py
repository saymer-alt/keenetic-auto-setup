#!/usr/bin/env python3
"""Build a LAB-ONLY kas-core archive; live installation/activation is blocked."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
spec = importlib.util.spec_from_file_location('panel_ipk_archive', REPO / 'web/control-center/packaging/build-ipk.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
archive = module.archive


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--source-sha', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'0\.0\.0~proof[0-9]+-[0-9]+', args.version):
        parser.error('qualification builds require 0.0.0~proofN-N version')
    if not re.fullmatch('[a-f0-9]{40}', args.source_sha):
        parser.error('source-sha must be a full commit SHA')
    # Never stamp a supplied SHA on different script bytes.
    result = subprocess.run(['git', 'ls-tree', '--name-only', args.source_sha], cwd=REPO,
                            capture_output=True, text=True, check=True)
    names = sorted(name for name in result.stdout.splitlines() if name.endswith('.sh') or name == 'S00ubifs')
    if subprocess.check_output(['git', 'rev-parse', '--is-shallow-repository'], cwd=REPO, text=True).strip() != 'false':
        parser.error('complete Git history is required for the watchdog baseline catalogue')
    revisions = subprocess.check_output(['git', 'log', '--format=%H', args.source_sha, '--', 'mihomo-watchdog.sh'], cwd=REPO, text=True).splitlines()
    known = {}
    for revision in revisions:
        blob = subprocess.run(['git', 'show', revision + ':mihomo-watchdog.sh'], cwd=REPO, capture_output=True)
        if blob.returncode == 0:
            known.setdefault(hashlib.sha256(blob.stdout).hexdigest(), revision)
    catalogue = ''.join(digest + '\t' + revision + '\n' for digest, revision in known.items()).encode()
    if not known:
        parser.error('watchdog history is unavailable')
    entries, scripts = [], []
    for name in names:
        if not re.fullmatch('[A-Za-z0-9_.-]+', name):
            parser.error('unsafe source filename')
        committed = subprocess.check_output(['git', 'show', args.source_sha + ':' + name], cwd=REPO)
        if committed != (REPO / name).read_bytes():
            parser.error('source differs from supplied commit: ' + name)
        path = 'opt/libexec/kas/' + name
        entries.append((path, committed, 0o755))
        scripts.append({'name': name, 'path': '/' + path,
                        'sha256': hashlib.sha256(committed).hexdigest()})
    if not names or 'mihomo-watchdog.sh' not in names:
        parser.error('incomplete KAS source tree')
    tool_source = 'packaging/core/kas-core-watchdog.sh'
    tool = subprocess.check_output(['git', 'show', args.source_sha + ':' + tool_source], cwd=REPO)
    if tool != (REPO / tool_source).read_bytes():
        parser.error('activation tool differs from supplied commit')
    tool_path = 'opt/libexec/kas/kas-core-watchdog.sh'
    entries.append((tool_path, tool, 0o755))
    manifest = {'schema': 1, 'version': args.version, 'source_sha': args.source_sha,
                'activation': 'explicit-watchdog-lab', 'scripts': scripts,
                'tools': [{'name': 'kas-core-watchdog.sh', 'source_path': tool_source,
                           'path': '/' + tool_path, 'sha256': hashlib.sha256(tool).hexdigest()}],
                'watchdog_catalogue_sha256': hashlib.sha256(catalogue).hexdigest()}
    license_bytes = subprocess.check_output(['git', 'show', args.source_sha + ':LICENSE'], cwd=REPO)
    entries.extend([
        ('opt/share/kas-core/LICENSE', license_bytes, 0o644),
        ('opt/share/kas-core/watchdog-history.tsv', catalogue, 0o644),
        ('opt/share/kas-core/BUILD_INFO', ('KAS_CORE_LAB_ONLY=1\nVersion=' + args.version +
         '\nKAS_SOURCE_SHA=' + args.source_sha + '\nArchitecture=all\n').encode(), 0o644),
        ('opt/share/kas-core/scripts.json', (json.dumps(manifest, indent=2) + '\n').encode(), 0o644)])
    entries.append(('opt/share/kas-core/SHA256SUMS', ''.join(
        hashlib.sha256(data).hexdigest() + '  ' + name + '\n' for name, data, _ in entries).encode(), 0o644))
    control = ('Package: kas-core\nVersion: ' + args.version + '\nArchitecture: all\n'
               'Maintainer: KAS maintainers\nSection: utils\nPriority: optional\n'
               'Description: LAB ONLY KAS scripts; offline-root only, no activation\n'
               'Source: ' + args.source_sha + '\n')
    controls = [('control', control.encode(), 0o644), ('md5sums', ''.join(
        hashlib.md5(data).hexdigest() + '  ' + name + '\n' for name, data, _ in entries).encode(), 0o644)]
    common = (HERE / 'hook-common.sh').read_text()
    for hook in ['preinst', 'postinst', 'prerm']:
        controls.append((hook, ('#!/bin/sh\nset -eu\numask 077\n' + common + '\n' +
                                (HERE / (hook + '.sh')).read_text()).encode(), 0o755))
    args.output.mkdir(parents=True, exist_ok=True)
    target = args.output / ('kas-core_' + args.version + '_all.ipk')
    target.write_bytes(archive([('./debian-binary', b'2.0\n', 0o644),
        ('./control.tar.gz', archive(controls), 0o644), ('./data.tar.gz', archive(entries), 0o644)]))
    print(target)


if __name__ == '__main__':
    main()
