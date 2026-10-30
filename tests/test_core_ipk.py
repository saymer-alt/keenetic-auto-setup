#!/usr/bin/env python3
"""Lab-only qualification using real Entware opkg in disposable offline roots."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
BUILDER = REPO / 'packaging/core/build-ipk.py'
SOURCE_SHA = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=REPO, text=True).strip()
spec = importlib.util.spec_from_file_location('panel_ipk', REPO / 'web/control-center/packaging/build-ipk.py')
archive_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(archive_module)
archive = archive_module.archive


class CoreIPKTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.base = Path(tmp.name)
        self.root = self.base / 'root'
        (self.root / 'opt/tmp').mkdir(parents=True)
        self.config = self.base / 'opkg.conf'
        self.config.write_text('dest root /\narch all 100\n')

    def build(self, version='0.0.0~proof1-1'):
        result = subprocess.run(['python3', str(BUILDER), '--version', version,
            '--source-sha', SOURCE_SHA,
            '--output', str(self.base)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return self.base / ('kas-core_' + version + '_all.ipk')

    def opkg(self, *args, success=True):
        opkg = os.environ.get('KAS_TEST_OPKG')
        if not opkg:
            self.skipTest('set KAS_TEST_OPKG to the pinned official Entware opkg')
        result = subprocess.run([opkg, '-f', str(self.config), '--offline-root',
            str(self.root), '--force-postinstall', '--tmp-dir', str(self.root / 'opt/tmp'),
            *map(str, args)], capture_output=True, text=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def members(self, package, member):
        with tarfile.open(package) as outer:
            content = outer.extractfile('./' + member).read()
        with tarfile.open(fileobj=io.BytesIO(content)) as inner:
            return {m.name: inner.extractfile(m).read() for m in inner if m.isfile()}

    def synthetic(self, version, postinst=b'#!/bin/sh\nexit 0\n'):
        control = archive([('control', ('Package: kas-direct-file-probe\nVersion: ' + version +
            '\nArchitecture: all\nDescription: synthetic offline qualification only\n').encode(), 0o644),
            ('postinst', postinst, 0o755)])
        data = archive([('opt/bin/mihomo_watchdog.sh', ('#!/bin/sh\necho ' + version + '\n').encode(), 0o755)])
        target = self.base / ('direct-' + version + '.ipk')
        target.write_bytes(archive([('./debian-binary', b'2.0\n', 0o644),
            ('./control.tar.gz', control, 0o644), ('./data.tar.gz', data, 0o644)]))
        return target

    def test_real_opkg_failed_postinst_does_not_restore_operational_payload(self):
        self.opkg('install', self.synthetic('0.1-1'))
        watchdog = self.root / 'opt/bin/mihomo_watchdog.sh'
        old = watchdog.read_bytes()
        # This is only a characterization of opkg: no KAS lock helpers are run.
        (self.root / 'tmp/mihomo-lifecycle.lock.d').mkdir(parents=True)
        result = self.opkg('install', self.synthetic('0.1-2', b'#!/bin/sh\nexit 1\n'), success=False)
        self.assertIn('postinst', result.stdout + result.stderr)
        self.assertNotEqual(watchdog.read_bytes(), old)
        self.assertEqual(watchdog.read_bytes(), b'#!/bin/sh\necho 0.1-2\n')
        self.opkg('remove', 'kas-direct-file-probe')
        self.assertFalse(watchdog.exists(), 'opkg removes operational files it owns')

    def test_catalogue_contains_only_source_ancestor_watchdog_blobs(self):
        files = self.members(self.build(), 'data.tar.gz')
        catalogue = files['opt/share/kas-core/watchdog-history.tsv'].decode().splitlines()
        digests = set()
        for row in catalogue:
            digest, revision = row.split('\t')
            self.assertEqual(len(digest), 64)
            self.assertNotIn(digest, digests)
            digests.add(digest)
            result = subprocess.run(['git', 'merge-base', '--is-ancestor', revision, SOURCE_SHA], cwd=REPO)
            self.assertEqual(result.returncode, 0)
            body = subprocess.check_output(['git', 'show', revision + ':mihomo-watchdog.sh'], cwd=REPO)
            self.assertEqual(hashlib.sha256(body).hexdigest(), digest)
        self.assertIn(hashlib.sha256((REPO / 'mihomo-watchdog.sh').read_bytes()).hexdigest(), digests)
        manifest = json.loads(files['opt/share/kas-core/scripts.json'])
        self.assertEqual(manifest['watchdog_catalogue_sha256'], hashlib.sha256(files['opt/share/kas-core/watchdog-history.tsv']).hexdigest())

    def test_archive_contains_unmodified_scripts_and_no_active_paths(self):
        files = self.members(self.build(), 'data.tar.gz')
        expected = {p.name for p in REPO.glob('*.sh')} | {'S00ubifs'}
        scripts = {name.removeprefix('opt/libexec/kas/') for name in files if name.startswith('opt/libexec/kas/')}
        self.assertEqual(scripts, expected | {'kas-core-watchdog.sh'})
        for name in expected:
            self.assertEqual(files['opt/libexec/kas/' + name], (REPO / name).read_bytes())
        self.assertFalse(any(name.startswith(('opt/bin/', 'opt/etc/')) for name in files))
        manifest = json.loads(files['opt/share/kas-core/scripts.json'])
        self.assertEqual(manifest['activation'], 'explicit-watchdog-lab')
        for entry in manifest['scripts'] + manifest['tools']:
            self.assertEqual(entry['sha256'], hashlib.sha256(files[entry['path'].lstrip('/')]).hexdigest())
        self.assertEqual(files['opt/share/kas-core/LICENSE'], (REPO / 'LICENSE').read_bytes())
        self.assertIn(b'Architecture: all\n', self.members(self.build(), 'control.tar.gz')['control'])


    def test_live_root_installation_is_explicitly_blocked(self):
        controls = self.members(self.build(), 'control.tar.gz')
        hook = self.base / 'preinst'
        hook.write_bytes(controls['preinst'])
        environment = {key: value for key, value in os.environ.items() if key not in ['IPKG_INSTROOT', 'PKG_ROOT']}
        result = subprocess.run(['sh', str(hook)], env=environment, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('live installation is blocked', result.stderr)

    def test_live_root_aliases_are_blocked(self):
        controls = self.members(self.build(), 'control.tar.gz')
        hook = self.base / 'alias-preinst'
        hook.write_bytes(controls['preinst'])
        root_link = self.base / 'root-link'
        root_link.symlink_to('/')
        # preinst is read-only even on the red path; no opkg extraction here.
        for alias in ['/.', '////', '/tmp/..', str(root_link / '.') + '/.']:
            with self.subTest(alias=alias):
                environment = {**os.environ, 'IPKG_INSTROOT': alias}
                result = subprocess.run(['sh', str(hook)], env=environment, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0, 'live root alias accepted: ' + alias)

    def test_nonqualification_version_is_rejected(self):
        result = subprocess.run(['python3', str(BUILDER), '--version', '1.0.0-1',
            '--source-sha', SOURCE_SHA, '--output', str(self.base)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(self.base.glob('*.ipk')), [])

    def test_real_bundle_lifecycle_preserves_operational_files(self):
        paths = {'opt/bin/mihomo_watchdog.sh': b'old operational watchdog\n',
                 'opt/etc/cron.5mins/mihomo_watchdog': b'existing cron\n',
                 'opt/etc/mihomo/config.yaml': b'existing private YAML\n',
                 'opt/etc/kas-control-center.settings.json': b'existing private settings\n'}
        for name, value in paths.items():
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(value)
        self.opkg('install', self.build())
        installed = self.root / 'opt/libexec/kas/mihomo-doctor.sh'
        self.assertEqual(installed.read_bytes(), (REPO / 'mihomo-doctor.sh').read_bytes())
        self.opkg('install', self.build('0.0.0~proof1-2'))
        self.opkg('remove', 'kas-core')
        self.assertFalse(installed.exists())
        for name, value in paths.items():
            self.assertEqual((self.root / name).read_bytes(), value)

    def test_real_bundle_refuses_unowned_existing_files(self):
        target = self.root / 'opt/libexec/kas/mihomo-doctor.sh'
        target.parent.mkdir(parents=True)
        target.write_bytes(b'foreign script\n')
        self.opkg('install', self.build(), success=False)
        self.assertEqual(target.read_bytes(), b'foreign script\n')

    def test_real_bundle_refuses_changed_file_on_upgrade_and_remove(self):
        self.opkg('install', self.build())
        target = self.root / 'opt/libexec/kas/mihomo-doctor.sh'
        target.write_bytes(b'user modification\n')
        self.opkg('install', self.build('0.0.0~proof1-2'), success=False)
        self.assertEqual(target.read_bytes(), b'user modification\n')
        self.opkg('remove', 'kas-core', success=False)
        self.assertEqual(target.read_bytes(), b'user modification\n')

    def test_real_bundle_refuses_added_unowned_file(self):
        self.opkg('install', self.build())
        target = self.root / 'opt/libexec/kas/custom.sh'
        target.write_bytes(b'user addition\n')
        self.opkg('install', self.build('0.0.0~proof1-2'), success=False)
        self.assertEqual(target.read_bytes(), b'user addition\n')

    def test_real_opkg_initializes_database_before_package_preinst(self):
        external = self.base / 'external-database'
        external.mkdir()
        (self.root / 'opt/lib').mkdir(parents=True)
        (self.root / 'opt/lib/opkg').symlink_to(external)
        result = self.opkg('install', self.build(), success=False)
        self.assertIn('symlink directory refused', result.stdout + result.stderr)
        self.assertTrue((external / 'status').exists(), 'opkg initializes DB before the package hook')
        self.assertFalse((self.root / 'opt/libexec/kas').exists(), 'hook must still prevent payload writes')

    def test_real_bundle_refuses_symlink_parent(self):
        external = self.base / 'external'
        external.mkdir()
        (self.root / 'opt/libexec').symlink_to(external)
        self.opkg('install', self.build(), success=False)
        self.assertEqual(list(external.iterdir()), [])

    def test_real_bundle_refuses_symlink_replacing_owned_script(self):
        self.opkg('install', self.build())
        external = self.base / 'external'
        external.write_bytes(b'outside file\n')
        target = self.root / 'opt/libexec/kas/mihomo-doctor.sh'
        target.unlink()
        target.symlink_to(external)
        self.opkg('install', self.build('0.0.0~proof1-2'), success=False)
        self.assertEqual(external.read_bytes(), b'outside file\n')
        self.assertTrue(target.is_symlink())


if __name__ == '__main__':
    unittest.main()
