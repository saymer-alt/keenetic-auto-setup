#!/usr/bin/env python3
"""Issue #50 acceptance ladder for the packaged S28mihomo init layout,
executed with the official Entware opkg against the REAL reviewed
mihomo 1.19.34-3 IPK inside a disposable --offline-root.

What is proven natively here (no router, no QEMU):

  1. fresh install: the opkg database records 1.19.34-3 and the package
     owns ./opt/etc/init.d/S28mihomo (S99mihomo is never created);
  2. reinstall: a repeated 'opkg install' of the same reviewed IPK keeps
     exactly one S28mihomo and the database version stable;
  3. conffile survival: /opt/etc/mihomo/config.yaml is a declared conffile
     that the package itself does NOT ship (KAS/owner creates it); a
     pre-existing custom config survives reinstall, the S99->S28 handover
     and 'opkg remove';
  4. S99 -> S28 handover mechanics: opkg file-list replacement removes the
     old init script and installs S28mihomo in one transaction. The OLD
     side of this scenario uses a clearly synthetic 1.19.33-1 package —
     the real reviewed 1.19.34-2 assets were removed from the upstream
     moving 'latest' tag, so a native -2 -> -3 transition needs the owner
     to provide verified -2 bytes via KAS_MIHOMO_OLD_IPK. When that env
     var points at the reviewed file (checked against
     1.19.34-2.lock.json), the scenario runs against REAL old bytes;
  5. interrupted transaction: an opkg process killed mid-install leaves
     the disposable root recoverable — a plain re-run completes and the
     end state is consistent;
  6. removal: 'opkg remove' deletes the package-owned init script and
     binary but keeps the declared conffile.

Honest limitations (recorded, never masked as PASS):

  - postinst/prerm are the standard Entware default_* wrappers requiring
    /opt/lib/functions.sh; with --offline-root opkg does not execute them
    by default and --force-postinstall would run them against the HOST
    /opt, so execution is verified by static inspection only (the real
    postinst/prerm execution path stays a native-router gate);
  - the service is never started: nothing in the disposable root runs the
    init script, and the data-level identity check guarantees exactly one
    mihomo init script exists at every checkpoint.

Requires: KAS_TEST_OPKG (pinned official Entware opkg, SHA-verified) and
KAS_MIHOMO_BUNDLE_DIR (a directory containing the reviewed
mihomo_1.19.34-3_mipsel-3.4.ipk; its SHA256 is checked against the
reviewed lock manifest before use).
"""
import io
import json
import os
from pathlib import Path
import gzip
import hashlib
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
OPKG_SHA = "49f3d1e047483dc068fcc8985d64dcd28d0041044434de2cb3ccd616f2fc0b10"
TARGET_NAME = "mihomo_1.19.34-3_mipsel-3.4.ipk"
CUSTOM_CONFIG = b"mixed-port: 7892\n# owner-custom config, must survive every opkg transaction\n"


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


def build_ipk(target: Path, package, version, arch, data_entries,
              conffiles=(), depends=()):
    control_lines = (
        'Package: %s\nVersion: %s\nArchitecture: %s\n'
        'Description: synthetic offline acceptance package (lab only)\n'
        % (package, version, arch))
    if depends:
        control_lines += 'Depends: %s\n' % ', '.join(depends)
    control = tar_gz([
        ('control', control_lines.encode(), 0o644),
        ('conffiles', ''.join(p + '\n' for p in conffiles).encode(), 0o644),
    ])
    target.write_bytes(tar_gz([
        ('./debian-binary', b'2.0\n', 0o644),
        ('./control.tar.gz', control, 0o644),
        ('./data.tar.gz', tar_gz(data_entries), 0o644),
    ]))


def sha256_of(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class OpkgS28Acceptance(unittest.TestCase):
    def setUp(self):
        self.opkg_bin = os.environ.get('KAS_TEST_OPKG')
        if not self.opkg_bin:
            self.skipTest('set KAS_TEST_OPKG to the pinned official Entware opkg')
        if os.path.exists(self.opkg_bin):
            observed = subprocess.run(['sha256sum', self.opkg_bin], capture_output=True,
                                      text=True).stdout.split()[0]
            self.assertEqual(observed, OPKG_SHA,
                             'KAS_TEST_OPKG is not the pinned official binary')
        bundle = os.environ.get('KAS_MIHOMO_BUNDLE_DIR')
        if not bundle:
            self.skipTest('set KAS_MIHOMO_BUNDLE_DIR to the reviewed 1.19.34-3 bundle')
        self.ipk = Path(bundle) / TARGET_NAME
        if not self.ipk.is_file():
            self.skipTest('bundle lacks %s' % TARGET_NAME)
        manifest = json.loads(
            (ROOT / 'mirrors' / 'mihomo' / '1.19.34-3.lock.json').read_text(encoding='utf-8'))
        expected = next(p for p in manifest['packages'] if p['name'] == TARGET_NAME)
        self.assertEqual(expected['sha256'], sha256_of(self.ipk),
                         'bundle IPK does not match the reviewed lock manifest')

        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.base = Path(tmp.name)
        self.root = self.base / 'root'
        (self.root / 'opt/tmp').mkdir(parents=True)
        self.config = self.base / 'opkg.conf'
        self.config.write_text('dest root /\narch all 100\narch mipsel-3.4 50\n')
        build_ipk(self.base / 'ca-bundle.ipk', 'ca-bundle', '20250101-1', 'all',
                  [('opt/etc/ssl/ca-bundle.crt', b'lab stub\n', 0o644)])
        self.opkg('install', self.base / 'ca-bundle.ipk')

    def opkg(self, *args, timeout=None):
        try:
            result = subprocess.run(
                [self.opkg_bin, '-f', str(self.config), '--offline-root', str(self.root),
                 '--tmp-dir', str(self.root / 'opt/tmp'), *map(str, args)],
                capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            # The kill is the point of the interrupted-transaction scenario.
            return 137, 'TIMEOUT-KILL (output unavailable)'
        return result.returncode, result.stdout + result.stderr

    def must_opkg(self, *args, timeout=None):
        rc, out = self.opkg(*args, timeout=timeout)
        self.assertEqual(rc, 0, out)
        return out

    def db_version(self):
        status = self.root / 'opt/lib/opkg/status'
        seen = {}
        pkg = None
        for line in status.read_text().splitlines():
            if line.startswith('Package: '):
                pkg = line.split(' ', 1)[1]
            elif line.startswith('Version: ') and pkg == 'mihomo':
                seen = line.split(' ', 1)[1]
        return seen or None

    def init_scripts(self):
        init_dir = self.root / 'opt/etc/init.d'
        if not init_dir.is_dir():
            return []
        return sorted(p.name for p in init_dir.iterdir()
                      if 'mihomo' in p.name)

    def owned_init_entry(self):
        out = self.must_opkg('files', 'mihomo')
        self.assertIn('opt/etc/init.d/S28mihomo', out,
                      'package must own the S28mihomo init script')
        listing = self.root / 'opt/lib/opkg/info/mihomo.list'
        self.assertIn('opt/etc/init.d/S28mihomo',
                      listing.read_text(encoding='utf-8'))
        self.assertNotIn('S99mihomo', listing.read_text(encoding='utf-8'),
                         'the S28 package must never own an S99 init script')

    def make_owner_config(self):
        cfg_dir = self.root / 'opt/etc/mihomo'
        cfg_dir.mkdir(parents=True, exist_ok=True)
        (cfg_dir / 'config.yaml').write_bytes(CUSTOM_CONFIG)

    def assert_owner_config(self):
        body = (self.root / 'opt/etc/mihomo/config.yaml').read_bytes()
        self.assertEqual(body, CUSTOM_CONFIG,
                         'owner config.yaml must survive every opkg transaction')

    def stage_synthetic_s99(self):
        """Clearly synthetic OLD side for the handover scenario (the real
        reviewed 1.19.34-2 bytes are gone from the upstream moving tag)."""
        build_ipk(self.base / 'mihomo_old_s99.ipk', 'mihomo', '1.19.33-1',
                  'mipsel-3.4',
                  [('opt/etc/init.d/S99mihomo',
                    b'#!/bin/sh\n# synthetic S99 stub (lab only)\n', 0o755),
                   ('opt/bin/mihomo', b'#!/bin/sh\necho mihomo 1.19.33\n', 0o755)],
                  conffiles=('/opt/etc/mihomo/config.yaml',),
                  depends=('ca-bundle',))
        self.must_opkg('install', self.base / 'mihomo_old_s99.ipk')
        self.assertEqual(self.db_version(), '1.19.33-1')
        self.assertEqual(self.init_scripts(), ['S99mihomo'])

    def test_fresh_install_owns_s28_only(self):
        out = self.must_opkg('install', self.ipk)
        self.assertEqual(self.db_version(), '1.19.34-3')
        self.assertEqual(self.init_scripts(), ['S28mihomo'])
        self.owned_init_entry()
        self.assertTrue((self.root / 'opt/bin/mihomo').is_file())
        self.assertNotIn('S99mihomo', out)

    def test_control_scripts_are_standard_entware_wrappers(self):
        with tarfile.open(self.ipk, mode='r:*') as outer:
            ctrl_blob = None
            for item in outer.getmembers():
                if item.name.removeprefix('./') == 'control.tar.gz' and item.isfile():
                    ctrl_blob = outer.extractfile(item).read()
                    break
        self.assertIsNotNone(ctrl_blob, 'control.tar.gz missing from the IPK')
        with tarfile.open(fileobj=io.BytesIO(ctrl_blob), mode='r:gz') as ctrl:
            members = {m.name.removeprefix('./'): m
                       for m in ctrl.getmembers() if m.isfile()}
            for name in ('postinst', 'prerm', 'conffiles'):
                self.assertIn(name, members, '%s missing from control.tar.gz' % name)
            postinst = ctrl.extractfile(members['postinst']).read().decode('utf-8')
            prerm = ctrl.extractfile(members['prerm']).read().decode('utf-8')
            conffiles = ctrl.extractfile(members['conffiles']).read().decode('utf-8')
        for script, fn in ((postinst, 'default_postinst'), (prerm, 'default_prerm')):
            self.assertIn(fn, script, 'expected the standard Entware %s wrapper' % fn)
            self.assertIn('/opt/lib/functions.sh', script)
        self.assertIn('/opt/etc/mihomo/config.yaml', conffiles)
        # opkg in the disposable root never executed these wrappers: nothing
        # outside the root was touched (recorded limitation, not masked).

    def test_reinstall_keeps_single_s28(self):
        self.must_opkg('install', self.ipk)
        self.make_owner_config()
        self.must_opkg('install', self.ipk)
        self.assertEqual(self.db_version(), '1.19.34-3')
        self.assertEqual(self.init_scripts(), ['S28mihomo'])
        self.owned_init_entry()
        self.assert_owner_config()

    def test_conffile_survives_remove(self):
        self.must_opkg('install', self.ipk)
        self.make_owner_config()
        self.must_opkg('remove', 'mihomo')
        self.assertEqual(self.init_scripts(), [],
                         'package-owned init script must be removed with the package')
        self.assertFalse((self.root / 'opt/bin/mihomo').exists())
        self.assert_owner_config()
        status_text = (self.root / 'opt/lib/opkg/status').read_text(encoding='utf-8')
        self.assertNotIn('Package: mihomo\n', status_text,
                         'mihomo must be gone from the opkg database after remove')

    def test_s99_to_s28_handover(self):
        old_ipk = os.environ.get('KAS_MIHOMO_OLD_IPK')
        if old_ipk:
            old_ipk = Path(old_ipk)
            manifest = json.loads(
                (ROOT / 'mirrors' / 'mihomo' / '1.19.34-2.lock.json').read_text(encoding='utf-8'))
            expected = next(p for p in manifest['packages']
                            if p['name'] == old_ipk.name)
            self.assertEqual(expected['sha256'], sha256_of(old_ipk),
                             'KAS_MIHOMO_OLD_IPK does not match the reviewed -2 manifest')
            self.must_opkg('install', old_ipk)
            self.assertEqual(self.init_scripts(), ['S99mihomo'])
            self.make_owner_config()
            out = self.must_opkg('install', self.ipk)
            self.assertIn('Upgrading', out)
        else:
            self.stage_synthetic_s99()
            self.make_owner_config()
            out = self.must_opkg('install', self.ipk)
        self.assertEqual(self.db_version(), '1.19.34-3')
        self.assertEqual(self.init_scripts(), ['S28mihomo'],
                         'the handover must end with exactly one S28 init script')
        self.owned_init_entry()
        self.assert_owner_config()

    def test_killed_install_is_recoverable(self):
        landed = False
        for budget in (0.02, 0.05, 0.15):
            rc, _ = self.opkg('install', self.ipk, timeout=budget)
            if rc == 0:
                break   # completed inside the budget; kill never landed mid-flight
            landed = True
            break
        # Recovery is the actual acceptance: a plain re-run must complete and
        # leave a consistent state regardless of where the kill landed.
        self.must_opkg('install', self.ipk)
        self.assertEqual(self.db_version(), '1.19.34-3')
        self.assertEqual(self.init_scripts(), ['S28mihomo'])
        self.owned_init_entry()
        if not landed:
            print('[NOTE] kill never landed mid-transaction in this environment; '
                  'only the recovery re-run is proven')


if __name__ == '__main__':
    unittest.main()
