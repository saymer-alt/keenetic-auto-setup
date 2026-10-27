#!/usr/bin/env python3
"""Opt-in KAS Control Center lifecycle regression: isolated fake /opt only."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'kas-web-manage.sh'


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='kas-web-lifecycle-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'opt'
        self.root.mkdir()
        self.binary = Path(self.tmp.name) / 'fake-web'
        self.binary.write_text('#!/bin/sh\nwhile :; do sleep 1; done\n')
        self.binary.chmod(0o700)
        self.digest = hashlib.sha256(self.binary.read_bytes()).hexdigest()
        self.env = dict(os.environ, KAS_WEB_ROOT=str(self.root), KAS_WEB_LAB='1')
        self.init = self.root / 'etc/init.d/S98kas-control-center'
        self.manifest = self.root / 'etc/kas-control-center.web.sha256'
        self.target = self.root / 'bin/kas-control-center'
        self.pid = self.root / 'var/run/kas-control-center.pid'
        self.core = self.root / 'etc/mihomo/config.yaml'
        self.core.parent.mkdir(parents=True)
        self.core.write_text('mixed-port: 7890\n# CORE MUST NEVER CHANGE\n')

    def call(self, *args, code=0):
        p = subprocess.run(['sh', str(SCRIPT), *args], capture_output=True, text=True,
                           env=self.env, timeout=12)
        self.assertEqual(p.returncode, code, (args, p.stdout, p.stderr))
        return p.stdout

    def install(self):
        self.call('install', str(self.binary), self.digest)

    def test_install_status_stop_uninstall_is_independent(self):
        self.install()
        self.assertEqual(self.target.read_bytes(), self.binary.read_bytes())
        self.assertTrue(self.init.is_file())
        self.assertEqual(self.manifest.read_text().strip(), self.digest)
        self.assertEqual(self.call('status').strip(), 'NOT_RUNNING')
        try:
            self.call('start')
            self.assertEqual(self.call('status').strip(), 'RUNNING')
            self.call('stop')
            self.assertEqual(self.call('status').strip(), 'NOT_RUNNING')
        finally:
            # best-effort cleanup in case a previous assertion failed
            if self.pid.exists():
                p = int(self.pid.read_text())
                try:
                    os.kill(p, 15)
                except ProcessLookupError:
                    pass
                self.pid.unlink()
        self.call('remove')
        for path in (self.target, self.init, self.manifest):
            self.assertFalse(path.exists(), path)
        self.assertEqual(self.core.read_text(), 'mixed-port: 7890\n# CORE MUST NEVER CHANGE\n')

    def test_wrong_checksum_refuses_install_without_mutation(self):
        self.call('install', str(self.binary), '0'*64, code=2)
        self.assertFalse(self.target.exists())
        self.assertFalse(self.manifest.exists())
        self.assertEqual(self.core.read_text().splitlines()[-1], '# CORE MUST NEVER CHANGE')

    def test_foreign_init_is_never_overwritten(self):
        self.init.parent.mkdir(parents=True)
        self.init.write_text('#!/bin/sh\n# FOREIGN\n')
        self.call('install', str(self.binary), self.digest, code=2)
        self.assertEqual(self.init.read_text(), '#!/bin/sh\n# FOREIGN\n')
        self.assertFalse(self.target.exists())

    def test_symlinked_web_bin_directory_is_rejected(self):
        foreign = Path(self.tmp.name) / 'foreign'
        foreign.mkdir()
        (self.root / 'bin').symlink_to(foreign, target_is_directory=True)
        self.call('install', str(self.binary), self.digest, code=2)
        self.assertEqual(list(foreign.iterdir()), [])
        self.assertEqual(self.core.read_text().splitlines()[-1], '# CORE MUST NEVER CHANGE')

    def test_modified_owned_binary_cannot_be_uninstalled(self):
        self.install()
        self.target.write_text('#!/bin/sh\n# FOREIGN MODIFICATION\n')
        self.call('remove', code=2)
        self.assertTrue(self.init.exists())
        self.assertTrue(self.target.exists())

    def test_unverified_pid_cannot_be_killed(self):
        self.install()
        self.pid.write_text(str(os.getpid()) + '\n')
        self.call('status', code=2)
        self.call('stop', code=2)
        self.call('remove', code=2)
        self.assertTrue(self.target.exists())


if __name__ == '__main__':
    unittest.main()
