#!/usr/bin/env python3
"""Pre-opkg checks run before any database or package hook can write."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import test_core_ipk as core


class PreflightTests(unittest.TestCase):
    setUp = core.CoreIPKTests.setUp
    build = core.CoreIPKTests.build

    def launch(self, *args, root=None):
        opkg = os.environ.get('KAS_TEST_OPKG')
        if not opkg:
            self.skipTest('set KAS_TEST_OPKG to official Entware opkg')
        return subprocess.run(['sh', str(core.REPO / 'packaging/core/lab-opkg.sh'),
            str(root or self.root), opkg, *map(str, args)], capture_output=True, text=True)

    def test_verified_opkg_install_upgrade_remove(self):
        for operation, target in [('install', self.build()), ('install', self.build('0.0.0~proof1-2')), ('remove', 'kas-core')]:
            result = self.launch(operation, target)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / 'opt/libexec/kas/mihomo-doctor.sh').exists())
        self.assertEqual(list(self.root.glob('.kas-core-opkg.*')), [])

    def test_database_symlink_is_refused_before_database_initialization(self):
        external = self.base / 'external'
        external.mkdir()
        (self.root / 'opt/lib').mkdir()
        (self.root / 'opt/lib/opkg').symlink_to(external)
        result = self.launch('install', self.build())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('PREFLIGHT', result.stderr)
        self.assertEqual(list(external.iterdir()), [])

    def test_status_symlink_is_refused_without_touching_target(self):
        external = self.base / 'status'
        external.write_text('sentinel\n')
        (self.root / 'opt/lib/opkg').mkdir(parents=True)
        (self.root / 'opt/lib/opkg/status').symlink_to(external)
        result = self.launch('install', self.build())
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(external.read_text(), 'sentinel\n')
        self.assertFalse((self.root / 'opt/lib/opkg/info').exists())

    def test_writable_database_member_is_refused_before_opkg(self):
        info = self.root / 'opt/lib/opkg/info'
        info.mkdir(parents=True)
        target = info / 'custom.control'
        target.write_text('sentinel\n')
        target.chmod(0o666)
        result = self.launch('install', self.build())
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'opt/lib/opkg/status').exists())
        self.assertEqual(target.read_text(), 'sentinel\n')

    def test_existing_lab_transaction_lock_is_not_stolen(self):
        lock = self.root / '.kas-core-opkg.lock'
        lock.mkdir()
        result = self.launch('install', self.build())
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(lock.is_dir())
        self.assertFalse((self.root / 'opt/lib/opkg').exists())

    def test_temporary_directory_symlink_is_refused(self):
        external = self.base / 'external'
        external.mkdir()
        (self.root / 'opt/tmp').rmdir()
        (self.root / 'opt/tmp').symlink_to(external)
        result = self.launch('install', self.build())
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(external.iterdir()), [])
        self.assertFalse((self.root / 'opt/lib/opkg').exists())

    def test_live_root_and_aliases_are_refused_before_opkg(self):
        package = self.build()
        for root in ['/', '/.', '/tmp/..', '////']:
            with self.subTest(root=root):
                result = self.launch('install', package, root=root)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('PREFLIGHT', result.stderr)

    def test_opkg_flags_and_foreign_package_remove_are_refused(self):
        for args in [('--force-overwrite', 'kas-core'), ('remove', 'mihomo'),
                     ('install', '--offline-root=/'), ('remove', 'kas-core', '--force-removal-of-dependent-packages')]:
            with self.subTest(args=args):
                result = self.launch(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / 'opt/lib/opkg').exists())


if __name__ == '__main__':
    unittest.main()
