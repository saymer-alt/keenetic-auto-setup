#!/usr/bin/env python3
"""Print a channel index from reviewed release IPKs. Does not upload or install."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import tarfile

def fields(raw, separator):
    result = {}
    for line in raw.decode('utf-8').splitlines():
        if not line:
            continue
        key, value = line.split(separator, 1)
        if key in result or key != key.strip():
            raise ValueError('duplicate/invalid field')
        result[key] = value.strip()
    return result

def package_info(file):
    raw = file.read_bytes()
    if not 0 < len(raw) <= 16 * 1024 * 1024:
        raise ValueError('package size')
    with tarfile.open(fileobj=io.BytesIO(raw), mode='r:gz') as outer:
        control_gz = outer.extractfile('./control.tar.gz').read()
        data_gz = outer.extractfile('./data.tar.gz').read()
    with tarfile.open(fileobj=io.BytesIO(control_gz), mode='r:gz') as control:
        values = fields(control.extractfile('control').read(), ':')
    with tarfile.open(fileobj=io.BytesIO(data_gz), mode='r:gz') as data:
        size = sum(m.size for m in data.getmembers() if m.isfile())
        info = fields(data.extractfile('opt/share/kas-control-center/BUILD_INFO').read(), '=')
        binary_sha = hashlib.sha256(data.extractfile('opt/bin/kas-control-center').read()).hexdigest()
    if values['Package'] != 'kas-control-center' or any(k not in {'Package','Version','Architecture','Source','Maintainer','Section','Priority','Description','Installed-Size'} for k in values):
        raise ValueError('package ownership/dependencies')
    if any(values[a] != info[b] for a,b in [('Version','Version'),('Architecture','Architecture'),('Source','KAS_SOURCE_SHA')]) or binary_sha != info['Binary_SHA256']:
        raise ValueError('inconsistent package identity')
    return dict(version=values['Version'], source_sha=values['Source'], architecture=values['Architecture'], name=file.name,
                size=len(raw), sha256=hashlib.sha256(raw).hexdigest(), unpacked_size=size, binary_sha256=binary_sha)

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--channel', choices=['experimental','stable'], required=True)
    ap.add_argument('--tag', required=True)
    ap.add_argument('packages', type=Path, nargs='+')
    args = ap.parse_args()
    pattern = r'kas-web-ipk-[a-f0-9]{7,40}' if args.channel == 'experimental' else r'kas-web-v[0-9]+\.[0-9]+\.[0-9]+'
    if not re.fullmatch(pattern,args.tag):
        ap.error('tag does not match channel')
    items = [package_info(file) for file in args.packages]
    if len(items)>4 or len({item['architecture'] for item in items}) != len(items):
        ap.error('duplicate/too many architectures')
    print(json.dumps(dict(schema=1,channel=args.channel,tag=args.tag,packages=items),indent=2))

if __name__ == '__main__':
    main()
