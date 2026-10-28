#!/usr/bin/env python3
"""Core catalogue/receipt adapter over the full redirected canonical updater."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import unittest

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('watchdog_fixture', REPO / 'tests/watchdog-package-regression.py')
wd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wd)
sha = lambda data: hashlib.sha256(data).hexdigest()


class CoreActivationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        wd.PackageWatchdogTests.setUpClass()

    def setUp(self):
        self.fixture = wd.PackageWatchdogTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.lab = self.fixture.lab
        self.bundle = self.lab / 'opt/libexec/kas'
        self.meta = self.lab / 'opt/share/kas-core'
        self.info = self.lab / 'opt/lib/opkg/info'
        for directory in [self.bundle, self.meta, self.info]:
            directory.mkdir(parents=True)
        self.tool = self.bundle / 'kas-core-watchdog.sh'
        source = (REPO / 'packaging/core/kas-core-watchdog.sh').read_text()
        self.tool.write_text(source.replace('/opt/', str(self.lab / 'opt') + '/'))
        self.tool.chmod(0o755)
        shutil.copyfile(self.fixture.script, self.bundle / 'update-watchdog.sh')
        shutil.copyfile(self.fixture.candidate, self.bundle / 'mihomo-watchdog.sh')
        for name in ['update-watchdog.sh', 'mihomo-watchdog.sh']:
            (self.bundle / name).chmod(0o755)
        self.version = '0.0.0~proof2-1'
        self.source = 'a' * 40
        catalogue = (sha(wd.OLD) + '\t' + 'b' * 40 + '\n' + sha(wd.NEW) + '\t' + self.source + '\n').encode()
        (self.meta / 'watchdog-history.tsv').write_bytes(catalogue)
        manifest = {'schema': 1, 'version': self.version, 'source_sha': self.source,
            'activation': 'explicit-watchdog-lab', 'watchdog_catalogue_sha256': sha(catalogue),
            'scripts': [{'name': name, 'path': str(self.bundle / name),
                         'sha256': sha((self.bundle / name).read_bytes())} for name in ['update-watchdog.sh', 'mihomo-watchdog.sh']],
            'tools': [{'name': self.tool.name, 'path': str(self.tool), 'sha256': sha(self.tool.read_bytes())}]}
        (self.meta / 'scripts.json').write_text(json.dumps(manifest) + '\n')
        files = list(self.bundle.iterdir()) + list(self.meta.iterdir())
        (self.meta / 'SHA256SUMS').write_text(''.join(sha(p.read_bytes()) + '  ' + str(p) + '\n' for p in files))
        files.append(self.meta / 'SHA256SUMS')
        for path in self.meta.iterdir():
            path.chmod(0o644)
        (self.info / 'kas-core.list').write_text(''.join(str(path) + '\n' for path in files))
        (self.info / 'kas-core.md5sums').write_text(''.join(hashlib.md5(p.read_bytes()).hexdigest() + '  ' + str(p) + '\n' for p in files))
        self.receipt = self.lab / 'opt/etc/kas-core/watchdog.json'

    def run_tool(self, action='status'):
        return subprocess.run(shlex.split(os.environ.get('KAS_WATCHDOG_TEST_SHELL','sh')) + [str(self.tool), action], env=self.fixture.env,
                              capture_output=True, text=True, timeout=15)

    def status(self):
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def seed_receipt(self, digest=None):
        self.receipt.parent.mkdir(exist_ok=True)
        self.receipt.parent.chmod(0o700)
        self.receipt.write_text(json.dumps({'schema': 1, 'component': 'watchdog',
            'bundle_version': '0.0.0~proof1-1', 'source_sha': 'b' * 40,
            'watchdog_sha256': digest or sha(wd.OLD)}) + '\n')
        self.receipt.chmod(0o600)

    def test_status_is_read_only_and_reports_recognized_unrecorded_copy(self):
        before = self.fixture.binary.read_bytes()
        status = self.status()
        self.assertEqual(status['state'], 'unrecorded')
        self.assertTrue(status['recognized'])
        self.assertEqual(status['installed_sha256'], sha(wd.OLD))
        self.assertEqual(self.fixture.binary.read_bytes(), before)
        self.assertFalse(self.receipt.parent.exists())

    def test_apply_uses_guarded_updater_and_commits_private_truthful_receipt(self):
        result = self.run_tool('apply')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        status = json.loads(result.stdout)
        self.assertEqual(status['state'], 'current')
        self.assertEqual(self.fixture.binary.read_bytes(), wd.NEW)
        receipt = json.loads(self.receipt.read_text())
        self.assertEqual(receipt['bundle_version'], self.version)
        self.assertEqual(receipt['source_sha'], self.source)
        self.assertEqual(receipt['watchdog_sha256'], sha(wd.NEW))
        self.assertEqual(self.receipt.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.receipt.parent.stat().st_mode & 0o777, 0o700)
        self.assertFalse((self.lab / 'network-called').exists())
        original = (self.receipt.stat().st_ino, self.receipt.stat().st_mtime_ns)
        result = self.run_tool('apply')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.receipt.stat().st_ino, self.receipt.stat().st_mtime_ns), original)

    def test_concurrent_package_change_cannot_report_current_for_old_bundle(self):
        upgrade = self.lab / 'package-upgrade.py'
        upgrade.write_text('import hashlib,json\nfrom pathlib import Path\n' +
            'meta=Path(' + repr(str(self.meta)) + ')\n' +
            'manifest=json.loads((meta/"scripts.json").read_text());manifest["version"]="0.0.0~proof3-1";manifest["source_sha"]="c"*40\n' +
            '(meta/"scripts.json").write_text(json.dumps(manifest)+"\\n")\n' +
            'bundle=Path(' + repr(str(self.bundle)) + ')\n' +
            'files=list(bundle.iterdir())+[p for p in meta.iterdir() if p.name!="SHA256SUMS"]\n' +
            '(meta/"SHA256SUMS").write_text("".join(hashlib.sha256(p.read_bytes()).hexdigest()+"  "+str(p)+"\\n" for p in files))\n' +
            'files.append(meta/"SHA256SUMS")\n' +
            'Path(' + repr(str(self.info / 'kas-core.md5sums')) + ').write_text("".join(hashlib.md5(p.read_bytes()).hexdigest()+"  "+str(p)+"\\n" for p in files))\n')
        self.fixture.fault_tool('mv', 'case "$*" in *mihomo_watchdog.sh.new.*) @REAL@ "$@"; python3 "$LAB/package-upgrade.py"; exit $?;; esac\nexec @REAL@ "$@"\n')
        result = self.run_tool('apply')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        if result.stdout.strip(): self.assertNotEqual(json.loads(result.stdout)['state'], 'current')
        self.assertEqual(self.status()['state'], 'bundle_changed')
        self.assertEqual(json.loads(self.receipt.read_text())['bundle_version'], self.version)

    def test_unknown_local_watchdog_is_preserved(self):
        self.fixture.binary.write_bytes(b'local custom watchdog\n')
        status = self.status()
        self.assertFalse(status['recognized'])
        result = self.run_tool('apply')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.fixture.binary.read_bytes(), b'local custom watchdog\n')
        self.assertFalse(self.receipt.exists())

    def test_tampered_catalogue_cannot_authorize_a_foreign_file(self):
        self.fixture.binary.write_bytes(b'foreign\n')
        with (self.meta / 'watchdog-history.tsv').open('a') as stream:
            stream.write(sha(b'foreign\n') + '\t' + self.source + '\n')
        result = self.run_tool('apply')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.fixture.binary.read_bytes(), b'foreign\n')
        self.assertFalse(self.receipt.exists())

    def test_modified_canonical_file_invalidates_existing_receipt(self):
        self.seed_receipt()
        self.fixture.binary.write_bytes(b'user changes after activation\n')
        self.assertEqual(self.status()['state'], 'stale')

    def test_old_bundle_receipt_is_not_current_for_new_package(self):
        self.fixture.binary.write_bytes(wd.NEW)
        self.seed_receipt(sha(wd.NEW))
        self.assertEqual(self.status()['state'], 'bundle_changed')

    def test_failed_receipt_commit_is_reported_and_retry_reconciles_actual_file(self):
        self.seed_receipt()
        old_receipt = self.receipt.read_bytes()
        self.fixture.fault_tool('mv', 'case "$*" in *watchdog.json*) exit 42;; esac\nexec @REAL@ "$@"\n')
        result = self.run_tool('apply')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.fixture.binary.read_bytes(), wd.NEW)
        self.assertEqual(self.receipt.read_bytes(), old_receipt)
        self.assertEqual(self.status()['state'], 'stale')
        inode = self.fixture.binary.stat().st_ino
        (self.lab / 'tools/mv').unlink()
        result = self.run_tool('apply')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.status()['state'], 'current')
        self.assertEqual(self.fixture.binary.stat().st_ino, inode)

    def test_updater_failure_does_not_replace_previous_receipt(self):
        self.seed_receipt()
        old_receipt = self.receipt.read_bytes()
        self.fixture.wrapper.write_text('#!/bin/sh\necho foreign cron\n')
        result = self.run_tool('apply')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.fixture.binary.read_bytes(), wd.OLD)
        self.assertEqual(self.receipt.read_bytes(), old_receipt)

    def test_receipt_symlink_is_refused_without_touching_target(self):
        self.seed_receipt()
        self.receipt.unlink()
        victim = self.lab / 'victim'
        victim.write_text('unrelated\n')
        self.receipt.symlink_to(victim)
        result = self.run_tool('apply')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(victim.read_text(), 'unrelated\n')
        self.assertEqual(self.fixture.binary.read_bytes(), wd.OLD)


if __name__ == '__main__':
    unittest.main()
