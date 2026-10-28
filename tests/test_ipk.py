#!/usr/bin/env python3
"""Inspect real Entware tar IPKs and execute their extracted maintainer hooks."""
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[1]
PACK = REPO / 'web/control-center/packaging'

class IPKTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        binary = self.base / 'binary'
        binary.write_bytes(b'package-test-binary\n')
        result = subprocess.run(['python3', str(PACK / 'build-ipk.py'), '--arch', 'aarch64-3.10',
            '--version', '0.1.0-1', '--binary', str(binary), '--output', str(self.base),
            '--source-sha', 'a' * 40], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.ipk = next(self.base.glob('*.ipk'))
        with tarfile.open(self.ipk) as outer:
            self.assertEqual(outer.getnames(), ['./debian-binary', './control.tar.gz', './data.tar.gz'])
            self.assertEqual(outer.extractfile('./debian-binary').read(), b'2.0\n')
        self.control = self.base / 'control'
        self.control.mkdir()
        self.root = self.base / 'root'
        self.root.mkdir()
        for name, dest in [('control.tar.gz', self.control), ('data.tar.gz', self.root)]:
            with tarfile.open(self.ipk) as outer:
                archive = outer.extractfile('./' + name).read()
            with tarfile.open(fileobj=io.BytesIO(archive)) as tf:
                tf.extractall(dest, filter='data')

    def hook(self, name):
        return subprocess.run(['sh', str(self.control / name)], env={**os.environ,
            'IPKG_INSTROOT': str(self.root)}, capture_output=True, text=True)

    @unittest.skipUnless(os.environ.get('KAS_TEST_OPKG'), 'Entware opkg unavailable; set KAS_TEST_OPKG for real offline-root transaction')
    def test_real_opkg_offline_install_upgrade_remove(self):
        # Separate empty root: setUp's root was populated to test extracted hooks.
        root = self.base / 'opkg-root'
        root.mkdir()
        (root / 'opt/tmp').mkdir(parents=True)
        config = self.base / 'opkg.conf'
        config.write_text('dest root /\narch all 1\narch aarch64-3.10 10\n')
        def opkg(*args, expected=0):
            result = subprocess.run([os.environ['KAS_TEST_OPKG'], '-f', str(config),
                '--offline-root', str(root), '--force-postinstall', '--tmp-dir', str(root / 'opt/tmp'), *map(str, args)], capture_output=True, text=True)
            if expected == 0:
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            else:
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('preexisting', result.stdout + result.stderr)
        foreign = root / 'opt/bin/kas-control-center'
        foreign.parent.mkdir(parents=True)
        foreign.write_bytes(b'foreign manual binary\n')
        opkg('install', self.ipk, expected=1)
        self.assertEqual(foreign.read_bytes(), b'foreign manual binary\n')
        foreign.unlink()
        opkg('install', self.ipk)
        binary = root / 'opt/bin/kas-control-center'
        self.assertEqual(binary.read_bytes(), b'package-test-binary\n')
        settings = root / 'opt/etc/kas-control-center.settings.json'
        settings.write_text('{"port":18081}')
        # A second actual package exercises opkg's upgrade ordering and records.
        updated = self.base / 'updated'
        updated.write_bytes(b'upgraded-test-binary\n')
        result = subprocess.run(['python3', str(PACK / 'build-ipk.py'), '--arch', 'aarch64-3.10',
            '--version', '0.1.0-2', '--binary', str(updated), '--output', str(self.base),
            '--source-sha', 'b' * 40], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        opkg('install', self.base / 'kas-control-center_0.1.0-2_aarch64-3.10.ipk')
        self.assertEqual(binary.read_bytes(), b'upgraded-test-binary\n')
        opkg('remove', 'kas-control-center')
        self.assertFalse(binary.exists())
        self.assertEqual(settings.read_text(), '{"port":18081}')

    def test_background_reader_does_not_hold_service_caller_pipes(self):
        init = (PACK / 'S98kas-control-center').read_text()
        prefix = self.base / 'reader-functions.sh'
        prefix.write_text(init.split('\ncheck_dirs\n')[0] + '\n')
        line = next(line.strip() for line in init.splitlines()
                    if line.strip().startswith(('filter_startup_log "$STARTUP"', 'read_startup_pipe "$STARTUP"')) and line.rstrip().endswith('&'))
        fifo = self.base / 'reader.fifo'
        os.mkfifo(fifo)
        log = self.base / 'bounded-status'
        log.touch()
        command = '. "$1"; STARTUP=$2; fifo=$3; ' + line + '\nprintf RETURNED'
        proc = subprocess.Popen(['sh', '-c', command, 'sh', str(prefix), str(log), str(fifo)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            try:
                output, error = proc.communicate(timeout=1)
            except subprocess.TimeoutExpired:
                self.fail('background log reader retained caller stdout/stderr pipes')
            self.assertEqual(proc.returncode, 0, error)
            self.assertEqual(output, 'RETURNED')
        finally:
            # Release the orphaned FIFO reader safely even on the red path.
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                try:
                    fd = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
                    os.close(fd)
                    break
                except OSError:
                    time.sleep(.02)
            proc.communicate(timeout=2)

    def test_verified_process_exit_during_stop_is_not_foreign_pid(self):
        init = (PACK / 'S98kas-control-center').read_text()
        prefix = self.base / 'stop-functions.sh'
        prefix.write_text(init.split('\ncheck_dirs\n')[0] + '\n')
        pidfile = self.base / 'service.pid'
        pidfile.write_text('424242\n')
        # Deterministically model the verified process exiting between the
        # loop's kill-0 and executable identity check. Never signal a real PID.
        command = '. "$1"; PID=$2; identity_calls=0; alive_calls=0; identity(){ identity_calls=$((identity_calls+1)); [ "$identity_calls" -eq 1 ]; }; alive(){ alive_calls=$((alive_calls+1)); [ "$alive_calls" -lt 3 ]; }; kill(){ return 0; }; stop_service'
        result = subprocess.run(['sh', '-c', command, 'sh', str(prefix), str(pidfile)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(pidfile.exists())

    def test_startup_capture_exposes_only_bounded_sanitized_markers(self):
        init = (PACK / 'S98kas-control-center').read_text()
        prefix = self.base / 'init-functions.sh'
        prefix.write_text(init.split('\ncheck_dirs\n')[0] + '\n')
        log = self.base / 'startup'
        raw = ('private password secret from arbitrary error\n' +
            '2026/10/28 PORT_BIND_FAILED: panel address 192.168.1.1:8081 is unavailable; secret=bad\n' +
            'Home-address HTTP 192.168.1.1:18081; Home-only restriction=true; no app password\n') * 100
        result = subprocess.run(['sh', '-c', '. "$1"; filter_startup_log "$2"', 'sh', str(prefix), str(log)],
            input=raw, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '')
        captured = log.read_text()
        self.assertNotIn('secret', captured)
        self.assertNotIn('password', captured)
        self.assertIn('PORT_BIND_FAILED:', captured)
        self.assertIn('192.168.1.1:18081', captured)
        self.assertLess(len(captured), 256)

    def test_payload_and_metadata(self):
        metadata = (self.control / 'control').read_text()
        self.assertIn('Package: kas-control-center\n', metadata)
        self.assertIn('Architecture: aarch64-3.10\n', metadata)
        files = {str(p.relative_to(self.root)) for p in self.root.rglob('*') if p.is_file()}
        self.assertEqual(files, {'opt/bin/kas-control-center', 'opt/etc/init.d/S98kas-control-center',
            'opt/share/kas-control-center/BUILD_INFO', 'opt/share/kas-control-center/THIRD_PARTY_NOTICES'})
        self.assertIn('a' * 40, (self.root / 'opt/share/kas-control-center/BUILD_INFO').read_text())

    def test_preinst_refuses_manual_and_foreign_payload(self):
        result = self.hook('preinst')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('preexisting', result.stderr)
        self.assertEqual((self.root / 'opt/bin/kas-control-center').read_bytes(), b'package-test-binary\n')

    def test_fresh_install_hooks_and_configuration_survive_remove(self):
        # preinst runs BEFORE payload extraction.
        for p in [self.root / 'opt/bin/kas-control-center', self.root / 'opt/etc/init.d/S98kas-control-center',
                  self.root / 'opt/share/kas-control-center/BUILD_INFO', self.root / 'opt/share/kas-control-center/THIRD_PARTY_NOTICES']:
            p.unlink()
        self.assertEqual(self.hook('preinst').returncode, 0)
        settings = self.root / 'opt/etc/kas-control-center.settings.json'
        settings.write_text('{"port":18081}')
        core = self.root / 'opt/etc/mihomo/config.yaml'
        core.parent.mkdir()
        core.write_text('core sentinel\n')
        secret = self.root / 'opt/etc/kas-control-center.mihomo-api-secret'
        secret.write_text('private sentinel\n')
        self.assertEqual(self.hook('postinst').returncode, 0)
        self.assertEqual(self.hook('prerm').returncode, 0)
        self.assertEqual(settings.read_text(), '{"port":18081}')
        self.assertEqual(core.read_text(), 'core sentinel\n')
        self.assertEqual(secret.read_text(), 'private sentinel\n')

    def test_upgrade_requires_opkg_ownership_and_package_init(self):
        info = self.root / 'opt/lib/opkg/info'
        info.mkdir(parents=True)
        (info / 'kas-control-center.list').write_text('/opt/bin/kas-control-center\n/opt/etc/init.d/S98kas-control-center\n/opt/share/kas-control-center/BUILD_INFO\n/opt/share/kas-control-center/THIRD_PARTY_NOTICES\n')
        self.assertEqual(self.hook('preinst').returncode, 0)
        (info / 'kas-control-center.list').write_text('/opt/bin/kas-control-center\n/opt/etc/init.d/S98kas-control-center\n')
        self.assertNotEqual(self.hook('preinst').returncode, 0)
        (self.root / 'opt/etc/init.d/S98kas-control-center').write_text('#!/bin/sh\n# KAS-CONTROL-CENTER-MANAGED-v1\n')
        self.assertNotEqual(self.hook('preinst').returncode, 0)

if __name__ == '__main__':
    unittest.main()
