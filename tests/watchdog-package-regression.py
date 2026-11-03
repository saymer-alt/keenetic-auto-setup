#!/usr/bin/env python3
"""Full canonical updater in redirected fixtures; no router/network or watchdog run."""
import hashlib
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[1]
OLD = b'#!/bin/sh\n# MIHOMO WATCHDOG SCRIPT\n# previous recognized fixture\nexit 0\n'
NEW = b'#!/bin/sh\n# MIHOMO WATCHDOG SCRIPT\n# next package fixture\nexit 0\n'
sha = lambda value: hashlib.sha256(value).hexdigest()
PROC_NATIVE = subprocess.run(['sh', '-c', 'IFS=" " read -r actual rest < /proc/self/stat; [ "$actual" = "$$" ]']).returncode == 0


class PackageWatchdogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if os.environ.get('KAS_REQUIRE_NATIVE_PROC') == '1' and not PROC_NATIVE:
            raise RuntimeError('native PID/proc namespace is required by this CI gate')
        if not PROC_NATIVE:
            print('NOTE: host PID/proc namespaces differ; fixture seeds the real host identity cache. Native identity/locking is a separate mandatory CI gate.', flush=True)

    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix='kas-package-watchdog-')
        self.addCleanup(tmp.cleanup)
        self.lab = Path(tmp.name)
        for part in ['opt/bin', 'opt/etc/cron.5mins', 'tmp', 'tools']:
            (self.lab / part).mkdir(parents=True)
        self.binary = self.lab / 'opt/bin/mihomo_watchdog.sh'
        self.binary.write_bytes(OLD)
        self.binary.chmod(0o755)
        self.wrapper = self.lab / 'opt/etc/cron.5mins/mihomo_watchdog'
        self.wrapper.write_text('#!/bin/sh\nexec ' + str(self.binary) + ' "$@"\n')
        self.wrapper.chmod(0o755)
        self.crontab = self.lab / 'opt/etc/crontab'
        self.crontab.write_text('*/5 * * * * root /bin/sh ' + str(self.wrapper) + '\n')
        self.crontab.chmod(0o644)
        self.candidate = self.lab / 'candidate.sh'
        self.candidate.write_bytes(NEW)
        self.candidate.chmod(0o644)
        self.script = self.lab / 'update-watchdog.sh'
        source = (REPO / 'update-watchdog.sh').read_text()
        source = source.replace('/tmp/', str(self.lab / 'tmp') + '/').replace('/opt/', str(self.lab / 'opt') + '/')
        if not PROC_NATIVE:
            # Test-only adaptation of the already supported identity cache.
            # Real /proc starttime/owner checks still run. Production is unchanged.
            source = source.replace('ml_lifecycle_acquire || {',
                'IFS=" " read -r fixture_host_pid fixture_rest < /proc/self/stat\n'
                'ML_ID="$fixture_host_pid $(ml_starttime "$fixture_host_pid")"\n'
                'ml_lifecycle_acquire || {')
        self.script.write_text(source)
        self.env = {**os.environ, 'LAB': str(self.lab), 'NO_COLOR': '1',
                    'PATH': str(self.lab / 'tools') + ':' + os.environ['PATH']}
        sleep = self.lab / 'tools/sleep'
        sleep.write_text('#!/bin/sh\nexit 0\n')
        sleep.chmod(0o755)
        for name in ['curl', 'wget']:
            tool = self.lab / 'tools' / name
            tool.write_text('#!/bin/sh\necho network >> "$LAB/network-called"\nexit 91\n')
            tool.chmod(0o755)

    def command(self, candidate_sha=None, installed_sha=None):
        return shlex.split(os.environ.get('KAS_WATCHDOG_TEST_SHELL', 'sh')) + [str(self.script), '--package-candidate', str(self.candidate), candidate_sha or sha(NEW), installed_sha or sha(OLD)]

    def run_update(self, **kwargs):
        result = subprocess.run(self.command(**kwargs), env=self.env, capture_output=True, text=True, timeout=10)
        self.assertFalse((self.lab / 'network-called').exists(), 'local activation must not use a downloader')
        return result

    def assert_old(self):
        self.assertEqual(self.binary.read_bytes(), OLD)
        self.assertEqual(self.binary.stat().st_mode & 0o777, 0o755)

    def fault_tool(self, name, body):
        real = shutil.which(name)
        target = self.lab / 'tools' / name
        target.write_text('#!/bin/sh\n' + body.replace('@REAL@', real))
        target.chmod(0o755)

    def test_local_candidate_updates_and_repeated_apply_does_not_rewrite(self):
        original_cron = self.crontab.read_bytes()
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.binary.read_bytes(), NEW)
        self.assertEqual(self.crontab.read_bytes(), original_cron)
        inode, mtime = self.binary.stat().st_ino, self.binary.stat().st_mtime_ns
        result = self.run_update(installed_sha=sha(NEW))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.binary.stat().st_ino, self.binary.stat().st_mtime_ns), (inode, mtime))
        self.assertEqual(list((self.lab / 'opt/bin').glob('.*package-backup*')), [])

    def test_interrupted_transaction_backup_is_preserved_and_blocks_retry(self):
        pending = self.lab / 'opt/bin/.mihomo_watchdog.sh.package-backup.424242'
        pending.write_bytes(OLD)
        pending.chmod(0o600)
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assert_old()
        self.assertEqual(pending.read_bytes(), OLD)

    def test_concurrent_updater_cannot_enter_held_lifecycle(self):
        self.fault_tool('cp', 'case "$2" in *mihomo_watchdog.sh.new.*) touch "$LAB/ready"; while [ ! -f "$LAB/continue" ]; do /bin/sleep .02; done;; esac\nexec @REAL@ "$@"\n')
        process = subprocess.Popen(self.command(), env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 5
            while not (self.lab / 'ready').exists():
                if process.poll() is not None:
                    self.fail('first updater failed before lock barrier: ' + str(process.communicate()))
                if time.monotonic() > deadline:
                    self.fail('stage barrier timeout')
                time.sleep(.01)
            second = self.run_update()
            self.assertNotEqual(second.returncode, 0)
            self.assertIn('lifecycle busy', second.stdout + second.stderr)
            self.assert_old()
        finally:
            (self.lab / 'continue').touch()
            output, error = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 0, output + error)
        self.assertEqual(self.binary.read_bytes(), NEW)

    def test_default_network_updater_still_uses_existing_download_path(self):
        tool = self.lab / 'tools/curl'
        tool.write_text('#!/bin/sh\necho network >> "$LAB/network-called"\n'
                        'while [ "$#" -gt 0 ]; do if [ "$1" = -o ]; then shift; cp "$LAB/candidate.sh" "$1"; exit $?; fi; shift; done\nexit 92\n')
        tool.chmod(0o755)
        command = shlex.split(os.environ.get('KAS_WATCHDOG_TEST_SHELL', 'sh')) + [str(self.script)]
        result = subprocess.run(command, env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.binary.read_bytes(), NEW)
        self.assertEqual((self.lab / 'network-called').read_text(), 'network\n')
        self.assertEqual(list((self.lab / 'opt/bin').glob('.*package-backup*')), [])

    def test_preexisting_stage_symlink_does_not_touch_unrelated_file(self):
        victim = self.lab / 'victim'
        victim.write_bytes(b'unrelated sentinel\n')
        victim.chmod(0o600)
        self.script.write_text(self.script.read_text().replace('    if wd_package_activate;',
            '    ln -s "$LAB/victim" "$STAGE_FILE"\n    if wd_package_activate;'))
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assert_old()
        self.assertEqual(victim.read_bytes(), b'unrelated sentinel\n')
        self.assertEqual(victim.stat().st_mode & 0o777, 0o600)
        self.assertTrue(any(p.is_symlink() for p in (self.lab / 'opt/bin').glob('.*new.*')))

    def test_second_signal_at_recovery_entry_cannot_release_lock_early(self):
        # Deterministic signal at the previously vulnerable reentrancy assignment.
        self.script.write_text(self.script.read_text().replace('    PACKAGE_RECOVERING=1\n',
            '    PACKAGE_RECOVERING=1\n    kill -TERM "$$"\n'))
        self.fault_tool('mv', 'case "$*" in *mihomo_watchdog.sh.new.*)\n if [ ! -f "$LAB/committed" ]; then touch "$LAB/committed"; @REAL@ "$@"; exit 42; fi;; esac\n[ -f "$LAB/tmp/mihomo-lifecycle.lock.d/owner" ] || exit 93\nexec @REAL@ "$@"\n')
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assert_old()
        self.assertIn('RECOVERED:', result.stdout + result.stderr)

    def assert_private_alias_refused(self, variable):
        victim = self.lab / 'victim'
        victim.write_bytes(b'unrelated sentinel\n')
        victim.chmod(0o600)
        self.script.write_text(self.script.read_text().replace('    if wd_package_activate;',
            '    ln -s "$LAB/victim" "$' + variable + '"\n    if wd_package_activate;'))
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assert_old()
        self.assertEqual(victim.read_bytes(), b'unrelated sentinel\n')
        self.assertEqual(victim.stat().st_mode & 0o777, 0o600)

    def test_preexisting_input_symlink_does_not_touch_unrelated_file(self):
        self.assert_private_alias_refused('TMP_FILE')

    def test_preexisting_backup_symlink_does_not_touch_unrelated_file(self):
        self.assert_private_alias_refused('PACKAGE_BACKUP')

    def test_recovery_stage_alias_is_preserved_with_private_backup(self):
        victim = self.lab / 'victim'
        victim.write_bytes(b'unrelated sentinel\n')
        victim.chmod(0o600)
        self.fault_tool('mv', 'case "$*" in *mihomo_watchdog.sh.new.*)\n if [ ! -f "$LAB/committed" ]; then touch "$LAB/committed"; stage=$2; @REAL@ "$@"; ln -s "$LAB/victim" "$stage"; exit 42; fi;; esac\nexec @REAL@ "$@"\n')
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(victim.read_bytes(), b'unrelated sentinel\n')
        self.assertEqual(victim.stat().st_mode & 0o777, 0o600)
        self.assertIn('RECOVERY_FAILED', result.stdout + result.stderr)
        self.assertNotIn('RECOVERED:', result.stdout + result.stderr)
        backups = list((self.lab / 'opt/bin').glob('.*package-backup*'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), OLD)

    def test_wrong_candidate_hash_preserves_old(self):
        result = self.run_update(candidate_sha='0' * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assert_old()

    def test_stale_or_unrecognized_installed_hash_preserves_old(self):
        result = self.run_update(installed_sha='0' * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assert_old()

    def test_foreign_cron_is_not_migrated_by_package_mode(self):
        self.wrapper.write_text('#!/bin/sh\necho user cron\n')
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assert_old()
        self.assertIn('user cron', self.wrapper.read_text())

    def test_duplicate_schedule_is_refused_without_normalization(self):
        before = self.crontab.read_bytes() * 2
        self.crontab.write_bytes(before)
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assert_old()
        self.assertEqual(self.crontab.read_bytes(), before)

    def test_source_symlink_is_refused(self):
        actual = self.lab / 'actual.sh'
        self.candidate.rename(actual)
        self.candidate.symlink_to(actual)
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assert_old()

    def test_unverifiable_lifecycle_owner_is_not_stolen(self):
        lock = self.lab / 'tmp/mihomo-lifecycle.lock.d'
        lock.mkdir()
        (lock / 'owner').write_text('unknown owner\n')
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assert_old()
        self.assertEqual((lock / 'owner').read_text(), 'unknown owner\n')

    def test_stage_copy_failure_preserves_old(self):
        self.fault_tool('cp', 'case "$2" in *mihomo_watchdog.sh.new.*) exit 42;; esac\nexec @REAL@ "$@"\n')
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assert_old()

    def test_commit_error_after_rename_restores_verified_old(self):
        self.fault_tool('mv', 'case "$*" in *mihomo_watchdog.sh.new.*)\n if [ ! -f "$LAB/committed" ]; then touch "$LAB/committed"; @REAL@ "$@"; exit 42; fi;; esac\nexec @REAL@ "$@"\n')
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assert_old()
        self.assertIn('RECOVERED', result.stdout + result.stderr)
        self.assertEqual(list((self.lab / 'opt/bin').glob('.*package-backup*')), [])

    def test_term_after_commit_restores_verified_old(self):
        self.fault_tool('mv', 'case "$*" in *mihomo_watchdog.sh.new.*)\n if [ ! -f "$LAB/committed" ]; then touch "$LAB/committed"; @REAL@ "$@"; kill -TERM "$PPID"; exit 0; fi;; esac\nexec @REAL@ "$@"\n')
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        self.assert_old()
        self.assertIn('RECOVERED', result.stdout + result.stderr)

    def test_recovery_failure_retains_private_backup_and_reports_failure(self):
        self.fault_tool('mv', 'case "$*" in *mihomo_watchdog.sh.new.*)\n if [ ! -f "$LAB/committed" ]; then touch "$LAB/committed"; @REAL@ "$@"; fi\n exit 42;; esac\nexec @REAL@ "$@"\n')
        result = self.run_update()
        self.assertNotEqual(result.returncode, 0)
        backups = list((self.lab / 'opt/bin').glob('.*package-backup*'))
        self.assertEqual(len(backups), 1, result.stdout + result.stderr)
        self.assertEqual(backups[0].read_bytes(), OLD)
        self.assertEqual(backups[0].stat().st_mode & 0o777, 0o600)
        self.assertIn('RECOVERY_FAILED', result.stdout + result.stderr)
        self.assertNotIn('RECOVERED:', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
