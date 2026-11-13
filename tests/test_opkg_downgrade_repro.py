#!/usr/bin/env python3
"""Issue #320 stage A mechanism proof: the official Entware opkg applies a
feed "upgrade" based on its own (stale) database and replaces a newer
project-managed binary with an older feed ELF.

update-mihomo.sh replaces only /opt/bin/mihomo and never writes the opkg
database (documented in its header). This lab shows the consequence with the
pinned official opkg binary in a disposable offline root:

  1. feed package mihomo 1.19.23-1 installed through opkg (DB: 1.19.23-1);
  2. the binary is replaced with 1.19.33 outside opkg (what the updater does
     by design) -> the database is now stale;
  3. installing the feed's 1.19.27-1 prints "Upgrading mihomo ... from
     1.19.23-1 to 1.19.27-1" and downgrades the on-disk ELF 1.19.33 -> 1.19.27.

No live system is touched: everything happens under --offline-root. The test
is skipped unless KAS_TEST_OPKG points at the pinned official Entware opkg
(the kas-core-package-proof workflow provides it).
"""
import io
import os
from pathlib import Path
import gzip
import shutil
import subprocess
import tarfile
import tempfile
import unittest

OPKG_SHA = "49f3d1e047483dc068fcc8985d64dcd28d0041044434de2cb3ccd616f2fc0b10"


def tar_gz(entries):
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode='w', format=tarfile.USTAR_FORMAT) as tf:
        directories = sorted({str(parent) for name, _, _ in entries
                              for parent in Path(name).parents if str(parent) != '.'},
                             key=lambda p: (p.count('/'), p))
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


def build_mihomo_ipk(target: Path, version: str, config_body: bytes):
    control = tar_gz([
        ('control', (
            'Package: mihomo\n'
            'Version: ' + version + '\n'
            'Architecture: all\n'
            'Conffiles:\n'
            '/opt/etc/mihomo/config.yaml\n'
            'Description: synthetic issue-320 offline repro package (lab only)\n').encode(), 0o644),
    ])
    data = tar_gz([
        ('opt/bin/mihomo',
         ('#!/bin/sh\nprintf "mihomo %s\\n" ' + version.split('-')[0] + '\n').encode(), 0o755),
        ('opt/etc/mihomo/config.yaml', config_body, 0o644),
    ])
    target.write_bytes(tar_gz([
        ('./debian-binary', b'2.0\n', 0o644),
        ('./control.tar.gz', control, 0o644),
        ('./data.tar.gz', data, 0o644),
    ]))


class OpkgDowngradeReproTests(unittest.TestCase):
    def setUp(self):
        self.opkg_bin = os.environ.get('KAS_TEST_OPKG')
        if not self.opkg_bin:
            self.skipTest('set KAS_TEST_OPKG to the pinned official Entware opkg')
        if os.path.exists(self.opkg_bin):
            observed = subprocess.run(['sha256sum', self.opkg_bin], capture_output=True,
                                      text=True).stdout.split()[0]
            self.assertEqual(observed, OPKG_SHA,
                             'KAS_TEST_OPKG is not the pinned official binary')
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.base = Path(tmp.name)
        self.root = self.base / 'root'
        (self.root / 'opt/tmp').mkdir(parents=True)
        self.config = self.base / 'opkg.conf'
        self.config.write_text('dest root /\narch all 100\n')
        build_mihomo_ipk(self.base / 'mihomo_1.19.23-1.ipk', '1.19.23-1',
                         b'mixed-port: 7890\nold-config\n')
        build_mihomo_ipk(self.base / 'mihomo_1.19.27-1.ipk', '1.19.27-1',
                         b'mixed-port: 7890\nfeed-new-config\n')

    def opkg(self, *args):
        result = subprocess.run(
            [self.opkg_bin, '-f', str(self.config), '--offline-root', str(self.root),
             '--force-postinstall', '--tmp-dir', str(self.root / 'opt/tmp'),
             *map(str, args)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def db_version(self):
        status = self.root / 'opt/lib/opkg/status'
        for line in status.read_text().splitlines():
            if line.startswith('Version: '):
                return line.split(' ', 1)[1]
        self.fail('mihomo not in the opkg database')

    def on_disk_version(self):
        result = subprocess.run([str(self.root / 'opt/bin/mihomo')],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_stale_database_upgrade_downgrades_newer_binary(self):
        # 1. The feed package is opkg-installed: DB and ELF agree.
        self.opkg('install', self.base / 'mihomo_1.19.23-1.ipk')
        self.assertEqual(self.db_version(), '1.19.23-1')
        self.assertEqual(self.on_disk_version(), 'mihomo 1.19.23')

        # 2. The project updater replaces only the binary; the DB goes stale.
        binary = self.root / 'opt/bin/mihomo'
        binary.write_text('#!/bin/sh\nprintf "mihomo %s\\n" 1.19.33\n')
        binary.chmod(0o755)
        self.assertEqual(self.on_disk_version(), 'mihomo 1.19.33')
        self.assertEqual(self.db_version(), '1.19.23-1')

        # 3. opkg applies the feed "upgrade" and downgrades the newer ELF.
        output = self.opkg('install', self.base / 'mihomo_1.19.27-1.ipk')
        self.assertIn('Upgrading mihomo', output)
        self.assertIn('1.19.23-1', output)
        self.assertIn('1.19.27-1', output)
        self.assertEqual(self.db_version(), '1.19.27-1')
        self.assertEqual(self.on_disk_version(), 'mihomo 1.19.27',
                         'expected the feed ELF to replace the newer '
                         'project-managed binary (issue #320 mechanism)')


if __name__ == '__main__':
    unittest.main()
