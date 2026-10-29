#!/usr/bin/env python3
"""Build the optional Entware package; never install or publish it."""
import argparse
import gzip
import hashlib
import io
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile

ARCHES = {'aarch64-3.10': {'GOARCH': 'arm64'}, 'armv7-3.2': {'GOARCH': 'arm', 'GOARM': '7'},
          'mipsel-3.4': {'GOARCH': 'mipsle', 'GOMIPS': 'softfloat'},
          'mips-3.4': {'GOARCH': 'mips', 'GOMIPS': 'softfloat'}}
HERE = Path(__file__).resolve().parent


def archive(entries):
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode='w', format=tarfile.USTAR_FORMAT) as tf:
        directories = sorted({str(parent) for name, _, _ in entries for parent in Path(name).parents if str(parent) != '.'}, key=lambda p: (p.count('/'), p))
        for directory in directories:
            ti = tarfile.TarInfo(directory + '/')
            ti.type, ti.mode, ti.mtime = tarfile.DIRTYPE, 0o755, 0
            ti.uname = ti.gname = 'root'
            tf.addfile(ti)
        for name, data, mode in entries:
            ti = tarfile.TarInfo(name)
            ti.size, ti.mode, ti.mtime = len(data), mode, 0
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = 'root'
            tf.addfile(ti, io.BytesIO(data))
    return gzip.compress(raw.getvalue(), mtime=0)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--arch', choices=ARCHES, required=True)
    ap.add_argument('--version', required=True)
    ap.add_argument('--source-sha', required=True)
    ap.add_argument('--channel', choices=['experimental', 'stable'], default='experimental')
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--binary', type=Path, help='use an already built binary (archive tests only)')
    args = ap.parse_args()
    if not re.fullmatch(r'[0-9][A-Za-z0-9.+~-]*', args.version):
        ap.error('invalid package version')
    if not re.fullmatch(r'[a-f0-9]{40}', args.source_sha):
        ap.error('source-sha must be a full commit SHA')
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as td:
        binary = args.binary or Path(td) / 'kas-control-center'
        if not args.binary:
            env = {**os.environ, 'CGO_ENABLED': '0', 'GOOS': 'linux', **ARCHES[args.arch]}
            subprocess.run(['go', 'generate', './...'], cwd=HERE.parent, env=env, check=True)
            subprocess.run(['go', 'build', '-mod=readonly', '-trimpath', '-ldflags=-s -w -X main.panelBuildVersion=' + args.version + ' -X main.panelBuildSHA=' + args.source_sha + ' -X main.panelBuildChannel=' + args.channel,
                            '-o', str(binary), '.'], cwd=HERE.parent, env=env, check=True)
        payload = binary.read_bytes()
        info = ('Version=' + args.version + '\nKAS_SOURCE_SHA=' + args.source_sha + '\nArchitecture=' + args.arch + '\nChannel=' + args.channel + '\nCGO_ENABLED=0\n' +
                ''.join(k + '=' + v + '\n' for k, v in ARCHES[args.arch].items()) +
                'Binary_SHA256=' + hashlib.sha256(payload).hexdigest() + '\n')
        data = archive([('opt/bin/kas-control-center', payload, 0o755),
                        ('opt/etc/init.d/S98kas-control-center', (HERE / 'S98kas-control-center').read_bytes(), 0o755),
                        ('opt/share/kas-control-center/BUILD_INFO', info.encode(), 0o644),
                        ('opt/share/kas-control-center/THIRD_PARTY_NOTICES', (HERE / 'third-party-notices.txt').read_bytes(), 0o644)])
        control = ('Package: kas-control-center\nVersion: ' + args.version + '\nArchitecture: ' + args.arch +
                   '\nMaintainer: KAS maintainers\nSection: utils\nPriority: optional\n' +
                   'Description: Optional experimental KAS Control Center (manual activation)\n' +
                   'Source: ' + args.source_sha + '\nInstalled-Size: ' + str((len(payload) + 1023) // 1024) + '\n')
        entries = [('control', control.encode(), 0o644)]
        common = (HERE / 'hook-common.sh').read_text()
        for hook in ['preinst', 'postinst', 'prerm']:
            entries.append((hook, ('#!/bin/sh\nset -eu\numask 077\n' + common + '\n' +
                                  (HERE / (hook + '.sh')).read_text()).encode(), 0o755))
        output = args.output / ('kas-control-center_' + args.version + '_' + args.arch + '.ipk')
        # Entware opkg expects a gzip tar outer archive, not Debian's ar format.
        output.write_bytes(archive([('./debian-binary', b'2.0\n', 0o644),
                                    ('./control.tar.gz', archive(entries), 0o644),
                                    ('./data.tar.gz', data, 0o644)]))
        print(output)

if __name__ == '__main__':
    main()
