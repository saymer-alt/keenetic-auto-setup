#!/usr/bin/env python3
"""Unified KAS Core updater (kas-update.sh) regression; no router/network.

kas-update.sh is exercised in redirected path fixtures with shell-function
overrides for id/curl/wget/sleep/opkg, following the established
maintenance-regression.py idiom. The transactional update-watchdog.sh is
never reimplemented here: the mocked "network" serves a prepared copy of the
real updater (path-rewritten, optionally identity-adapted for hosts without
native PID/proc namespaces), so kas-update's delegation flow is what runs.

Covered: check current/update/UNKNOWN classification, no-network and
invalid-candidate refusals, foreign/symlink preservation, absent-watchdog
no-op, wrapper creation, legacy full-watchdog preservation, busy lifecycle
lock, TTY confirmation requirement, updater validation failure, user-data
preservation, idempotent re-apply, and sh/dash/BusyBox ash dialects.
"""
import hashlib
import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]

OLD_BODY = b'#!/bin/sh\n# MIHOMO WATCHDOG SCRIPT\n# previous release body\nexit 0\n'
NEW_BODY = b'#!/bin/sh\n# MIHOMO WATCHDOG SCRIPT\n# next release body\nexit 0\n'
sha = lambda data: hashlib.sha256(data).hexdigest()

PROC_NATIVE = subprocess.run(['sh', '-c',
    'IFS=" " read -r actual rest < /proc/self/stat; [ "$actual" = "$$" ]']
    ).returncode == 0

# Real chmod/chown semantics only exist on POSIX hosts; elsewhere the
# harness emulates them (see UPDATER_PREFIX) and CI covers real modes.
POSIX_MODES = os.name == 'posix'

DOCUMENTED_COMMAND = ('curl -fSsL -o /tmp/kas-update.sh '
    'https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/kas-update.sh')


# Write LF + UTF-8 on every host so fixtures stay byte-identical for the
# POSIX shells and sha256 comparisons under test.
def write_lf(path, text):
    path.write_text(text, encoding='utf-8', newline='\n')


def path_rewrite(text, lab):
    posix = str(lab).replace('\\', '/')
    return text.replace('/tmp/', posix + '/tmp/').replace('/opt/', posix + '/opt/')


# Shell-function overrides shadow root check, network transports, sleeps and
# opkg only inside the process under test; the real sha256sum/mkdir/mv/cp/
# chmod are used. The same fetcher block is served inside the delegated
# updater payload, because the updater runs in its own shell process.
MOCK_FETCHERS = r'''
kas_mock_fetch() {
  [ -n "${2:-}" ] && [ -n "${1:-}" ] || return 91
  printf '%s\n' "$1" >> "$MOCK_LOG"
  _kf_base=${1##*/}; _kf_base=${_kf_base%%\?*}
  while IFS="	" read -r _kf_key _kf_path; do
    [ "$_kf_key" = "$_kf_base" ] || continue
    [ -f "$_kf_path" ] || return 92
    command cp "$_kf_path" "$2" || return 93
    return 0
  done < "$MANIFEST"
  return 91
}
curl() {
  _cu_dest=""; _cu_url=""; _cu_prev=""
  for _cu_a in "$@"; do
    if [ "$_cu_prev" = "-o" ]; then _cu_dest="$_cu_a"; fi
    case "$_cu_a" in http://*|https://*) [ -z "$_cu_url" ] && _cu_url="$_cu_a";; esac
    _cu_prev="$_cu_a"
  done
  kas_mock_fetch "$_cu_url" "$_cu_dest"
}
wget() {
  _wg_dest=""; _wg_url=""; _wg_prev=""
  for _wg_a in "$@"; do
    if [ "$_wg_prev" = "-qO" ]; then _wg_dest="$_wg_a"; fi
    case "$_wg_a" in http://*|https://*) [ -z "$_wg_url" ] && _wg_url="$_wg_a";; esac
    _wg_prev="$_wg_a"
  done
  kas_mock_fetch "$_wg_url" "$_wg_dest"
}
'''

PREFIX = r'''
id() { echo 0; }
sleep() { :; }
opkg() {
  if [ "${1:-}" = list-installed ]; then printf '%s\n' 'magitrickle 0.3.5-all'; return 0; fi
  return 1
}
''' + MOCK_FETCHERS

UPDATER_PREFIX = r'''
id() { echo 0; }
sleep() { :; }
# Host-independence overrides for the delegated updater, mirroring
# maintenance-regression.py: managed files must verify as root:root even on
# CI runners and non-root hosts. On hosts with a no-op chmod (MSYS/NTFS
# mounts) the requested mode is recorded in a .kas-mode sidecar and
# synthesized back by the ls -ldn override; on normal hosts the real chmod
# still runs and the Python-level stat assertions verify real modes.
chown() { :; }
chmod() {
  _ch_mode=$1; shift
  command chmod "$@" 2>/dev/null
  for _ch_f in "$@"; do
    printf '%s\n' "$_ch_mode" > "$_ch_f.kas-mode" 2>/dev/null
  done
  return 0
}
ls() {
  if [ "${1:-}" = -ldn ]; then
    _ls_file=${2:-}
    if [ -f "$_ls_file" ] && [ ! -L "$_ls_file" ] && [ -f "$_ls_file.kas-mode" ]; then
      _ls_mode=$(cat "$_ls_file.kas-mode")
      case "$_ls_mode" in
        755) _ls_perms='-rwxr-xr-x' ;;
        600) _ls_perms='-rw-------' ;;
        *) _ls_perms='-rw-r--r--' ;;
      esac
      printf '%s 1 0 0 0 Nov 1 00:00 %s\n' "$_ls_perms" "$_ls_file"
      return 0
    fi
    command ls "$@" | awk '{$3=0; $4=0; print}'
  else
    command ls "$@"
  fi
}
''' + MOCK_FETCHERS


class KasUpdateRegression(unittest.TestCase):
    shells = [['sh'], ['dash']]
    if shutil.which('busybox'):
        shells.append(['busybox', 'ash'])

    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix='kas-update-regression-')
        self.addCleanup(tmp.cleanup)
        self.lab = Path(tmp.name)
        for part in ['opt/bin', 'opt/etc/cron.5mins', 'opt/etc/mihomo',
                     'opt/etc/ndm/netfilter.d', 'opt/etc/init.d', 'opt/etc/keenetic-auto-setup',
                     'tmp']:
            (self.lab / part).mkdir(parents=True)
        self.binary = self.lab / 'opt/bin/mihomo_watchdog.sh'
        self.wrapper = self.lab / 'opt/etc/cron.5mins/mihomo_watchdog'
        self.crontab = self.lab / 'opt/etc/crontab'
        self.config = self.lab / 'opt/etc/mihomo/config.yaml'
        self.manifest = self.lab / 'manifest.tsv'
        self.mock_log = self.lab / 'network.log'
        self.served_updater = self.lab / 'served-update-watchdog.sh'
        self.served_self = self.lab / 'served-kas-update.sh'
        self.env = {
            **os.environ,
            'LAB': str(self.lab),
            'NO_COLOR': '1',
            'TERM': 'dumb',
            'MANIFEST': str(self.manifest),
            'MOCK_LOG': str(self.mock_log),
        }

    # --- fixture helpers ---

    def install_watchdog(self, body=OLD_BODY):
        self.binary.write_bytes(body)
        self.binary.chmod(0o755)
        wrapper_exec = str(self.binary).replace('\\', '/')
        write_lf(self.wrapper, '#!/bin/sh\nexec ' + wrapper_exec + ' "$@"\n')
        self.wrapper.chmod(0o755)
        write_lf(self.crontab, '*/5 * * * * root /bin/sh ' + wrapper_exec + '\n')
        self.crontab.chmod(0o644)

    def prepare_updater_payload(self):
        """The mocked network serves the real updater, path-rewritten and,
        on hosts without native PID/proc namespaces, identity-adapted."""
        source = (REPO / 'update-watchdog.sh').read_text(encoding='utf-8')
        body = path_rewrite(source, self.lab)
        if not PROC_NATIVE:
            body = body.replace('ml_lifecycle_acquire || {',
                'IFS=" " read -r fixture_host_pid fixture_rest < /proc/self/stat\n'
                'ML_ID="$fixture_host_pid $(ml_starttime "$fixture_host_pid")"\n'
                'ml_lifecycle_acquire || {')
        write_lf(self.served_updater, UPDATER_PREFIX + body)

    def compose_self(self):
        """The script under test with mocked id/curl/wget/sleep/opkg, written
        to a file so quoting survives every host shell (see
        watchdog-package-regression.py for the same file-based idiom)."""
        script = self.lab / 'kas-update-under-test.sh'
        if not script.exists():
            write_lf(script, PREFIX + path_rewrite(
                (REPO / 'kas-update.sh').read_text(encoding='utf-8'), self.lab))
        return script

    def prepare_self_payload(self):
        write_lf(self.served_self, self.compose_self().read_text(encoding='utf-8'))

    def serve_default_network(self):
        write_lf(self.manifest, '\n'.join([
            'mihomo-watchdog.sh\t' + str(self.candidate_file()),
            'update-watchdog.sh\t' + str(self.served_updater),
            'kas-update.sh\t' + str(self.served_self),
        ]) + '\n')

    def candidate_file(self):
        path = self.lab / 'candidate-body.sh'
        if not path.exists():
            path.write_bytes(NEW_BODY)
        return path

    def run_kas_update(self, args, shell=None):
        shell = shell or ['sh']
        # stdin is always detached: check never reads it, and apply must see
        # a non-TTY stdin exactly like an operator piping or scheduling it.
        return subprocess.run(
            shell + [str(self.compose_self())] + list(args),
            env=self.env, stdin=subprocess.DEVNULL, capture_output=True,
            text=True, encoding='utf-8', errors='replace', timeout=60)

    def network_hits(self):
        if not self.mock_log.exists():
            return []
        return self.mock_log.read_text().splitlines()

    def updater_hits(self):
        return [line for line in self.network_hits() if 'update-watchdog.sh' in line]

    # --- scenarios ---

    def test_check_current(self):
        self.install_watchdog(NEW_BODY)
        self.prepare_updater_payload()
        self.prepare_self_payload()
        self.serve_default_network()
        result = self.run_kas_update(['--check'])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('already current', result.stdout)
        self.assertIn('nothing to apply', result.stdout)
        self.assertIn('(opkg): 0.3.5-all', result.stdout)
        self.assertIn('not run by kas-update', result.stdout)

    def test_check_update_available(self):
        self.install_watchdog(OLD_BODY)
        self.prepare_updater_payload()
        self.prepare_self_payload()
        self.serve_default_network()
        result = self.run_kas_update(['--check'])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('update available', result.stdout)
        self.assertIn(sha(OLD_BODY), result.stdout)
        self.assertIn(sha(NEW_BODY), result.stdout)
        self.assertIn('apply plan', result.stdout)
        self.assertIn('transactional update-watchdog.sh', result.stdout)

    def test_check_network_failure_is_unknown(self):
        self.install_watchdog(OLD_BODY)
        write_lf(self.manifest, '')  # every transport fails
        result = self.run_kas_update(['--check'])
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn('UNKNOWN', result.stdout)
        self.assertEqual(self.binary.read_bytes(), OLD_BODY)

    def test_check_invalid_candidate_is_unknown(self):
        self.install_watchdog(OLD_BODY)
        self.prepare_self_payload()
        bad = self.lab / 'bad-candidate.sh'
        write_lf(bad, '#!/bin/sh\n# no sanity marker\necho unrelated\n')
        write_lf(self.manifest, '\n'.join([
            'mihomo-watchdog.sh\t' + str(bad),
            'kas-update.sh\t' + str(self.served_self),
        ]) + '\n')
        result = self.run_kas_update(['--check'])
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn('UNKNOWN', result.stdout)
        self.assertEqual(self.binary.read_bytes(), OLD_BODY)

    def test_foreign_watchdog_preserved_and_apply_refused(self):
        self.install_watchdog()
        self.binary.write_text('#!/bin/sh\necho custom user watchdog\n')
        self.prepare_updater_payload()
        self.prepare_self_payload()
        self.serve_default_network()
        check = self.run_kas_update(['--check'])
        self.assertEqual(check.returncode, 2, check.stdout + check.stderr)
        self.assertIn('no KAS sanity marker', check.stdout)
        before = self.binary.read_bytes()
        apply_result = self.run_kas_update(['--apply', '--yes'])
        self.assertEqual(apply_result.returncode, 1, apply_result.stdout + apply_result.stderr)
        self.assertIn('nothing was changed', apply_result.stdout + apply_result.stderr)
        self.assertEqual(self.binary.read_bytes(), before)

    def test_not_installed_is_noop(self):
        self.prepare_updater_payload()
        self.prepare_self_payload()
        self.serve_default_network()
        check = self.run_kas_update(['--check'])
        self.assertEqual(check.returncode, 0, check.stdout + check.stderr)
        self.assertIn('is not installed', check.stdout)
        apply_result = self.run_kas_update(['--apply', '--yes'])
        self.assertEqual(apply_result.returncode, 0, apply_result.stdout + apply_result.stderr)
        self.assertIn('nothing to apply', apply_result.stdout)
        self.assertFalse(self.binary.exists())
        self.assertFalse(self.wrapper.exists())
        self.assertEqual(self.updater_hits(), [])

    def test_apply_update_transaction_and_idempotency(self):
        self.install_watchdog(OLD_BODY)
        self.prepare_updater_payload()
        self.prepare_self_payload()
        self.serve_default_network()
        self.config.write_bytes(b'proxies: []\n')
        result = self.run_kas_update(['--apply', '--yes'])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('apply verified', result.stdout)
        self.assertEqual(self.binary.read_bytes(), NEW_BODY)
        if POSIX_MODES:
            # Real-file permission checks are authoritative on POSIX hosts;
            # emulated-mode hosts (MSYS/NTFS) are covered by CI.
            self.assertEqual(self.binary.stat().st_mode & 0o7777, 0o755)
            # The delegated updater normalized permissions on the managed wrapper.
            self.assertEqual(self.wrapper.stat().st_mode & 0o7777, 0o755)
        self.assertEqual(self.config.read_bytes(), b'proxies: []\n')
        # Idempotent re-apply: nothing rewritten, no second updater invocation.
        hits_after_first = len(self.updater_hits())
        snapshot = (self.binary.read_bytes(), self.binary.stat().st_ino,
                    self.binary.stat().st_mtime_ns)
        second = self.run_kas_update(['--apply', '--yes'])
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertIn('nothing to apply', second.stdout)
        self.assertEqual(len(self.updater_hits()), hits_after_first)
        self.assertEqual((self.binary.read_bytes(), self.binary.stat().st_ino,
                          self.binary.stat().st_mtime_ns), snapshot)

    def test_apply_creates_missing_wrapper(self):
        self.install_watchdog(NEW_BODY)  # canonical already current
        self.wrapper.unlink()
        self.prepare_updater_payload()
        self.prepare_self_payload()
        self.serve_default_network()
        check = self.run_kas_update(['--check'])
        self.assertEqual(check.returncode, 1, check.stdout + check.stderr)
        self.assertIn('cron wrapper missing', check.stdout)
        result = self.run_kas_update(['--apply', '--yes'])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.wrapper.is_file())
        self.assertIn('exec ' + str(self.binary).replace('\\', '/'), self.wrapper.read_text())
        if POSIX_MODES:
            self.assertEqual(self.wrapper.stat().st_mode & 0o7777, 0o755)
        self.assertEqual(self.binary.read_bytes(), NEW_BODY)

    def test_foreign_full_watchdog_wrapper_is_preserved(self):
        self.install_watchdog(OLD_BODY)
        legacy_body = '#!/bin/sh\n# MIHOMO WATCHDOG SCRIPT\n# unknown full watchdog body\nexit 0\n'
        write_lf(self.wrapper, legacy_body)
        self.wrapper.chmod(0o755)
        self.prepare_updater_payload()
        self.prepare_self_payload()
        self.serve_default_network()
        check = self.run_kas_update(['--check'])
        self.assertEqual(check.returncode, 1, check.stdout + check.stderr)
        self.assertIn('unrecognized', check.stdout)
        result = self.run_kas_update(['--apply', '--yes'])
        # The transactional updater updates the canonical binary, preserves
        # the unrecognized full watchdog at the cron path, and deliberately
        # exits non-zero because the layout stays incomplete. kas-update must
        # report that honestly (exit 1) while the files show exactly this.
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('NOT a known managed version', result.stdout)
        self.assertIn('review the updater output above', result.stdout + result.stderr)
        self.assertEqual(self.wrapper.read_text(), legacy_body)
        self.assertEqual(self.binary.read_bytes(), NEW_BODY)

    def test_apply_requires_confirmation_without_tty(self):
        self.install_watchdog(OLD_BODY)
        self.prepare_updater_payload()
        self.prepare_self_payload()
        self.serve_default_network()
        result = self.run_kas_update(['--apply'])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('interactive confirmation', result.stdout + result.stderr)
        self.assertEqual(self.binary.read_bytes(), OLD_BODY)

    def test_apply_busy_lifecycle_lock(self):
        if not PROC_NATIVE:
            self.skipTest('native PID/proc namespace required for a live lock owner')
        self.install_watchdog(OLD_BODY)
        self.prepare_updater_payload()
        self.prepare_self_payload()
        self.serve_default_network()
        # A real live shell holds the shared lifecycle lock. The holder
        # computes its own pid+starttime inside its own /proc namespace and
        # writes the owner file itself (a spawned MSYS process has a different
        # pid space than Python on Windows hosts).
        holder_sh = self.lab / 'lock-holder.sh'
        owner_file = self.lab / 'tmp/mihomo-lifecycle.lock.d'
        ready = self.lab / 'holder-ready'
        write_lf(holder_sh, ''.join([
            '#!/bin/sh\n',
            'umask 077\n',
            'mkdir "' + str(owner_file) + '"\n',
            'data=$(cat "/proc/$$/stat")\n',
            'tail=${data##*) }\n',
            'start=$(printf \'%s\\n\' "$tail" | awk \'NF >= 20 && $20 ~ /^[0-9]+$/ { print $20; ok=1 } END { if (!ok) exit 1 }\') || exit 3\n',
            'printf \'%s %s\\n\' "$$" "$start" > "' + str(owner_file) + '/owner"\n',
            ': > "' + str(ready) + '"\n',
            'read x\n',
        ]))
        holder = subprocess.Popen(['sh', str(holder_sh)], stdin=subprocess.PIPE,
                                  text=True, encoding='utf-8', errors='replace')
        self.addCleanup(holder.kill)
        deadline = time.monotonic() + 5
        while not ready.exists():
            if time.monotonic() > deadline:
                holder.kill()
                self.skipTest('holder could not start; /proc starttime unavailable')
            time.sleep(0.01)
        try:
            check = self.run_kas_update(['--check'])
            self.assertEqual(check.returncode, 1, check.stdout + check.stderr)
            self.assertIn('BUSY', check.stdout)
            result = self.run_kas_update(['--apply', '--yes'])
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn('busy', result.stdout + result.stderr)
            self.assertEqual(self.binary.read_bytes(), OLD_BODY)
        finally:
            holder.communicate('\n', timeout=5)

    def test_apply_refuses_invalid_updater_payload(self):
        self.install_watchdog(OLD_BODY)
        self.prepare_self_payload()
        bad_updater = self.lab / 'bad-updater.sh'
        write_lf(bad_updater, '#!/bin/sh\necho not the updater\n')
        write_lf(self.manifest, '\n'.join([
            'mihomo-watchdog.sh\t' + str(self.candidate_file()),
            'update-watchdog.sh\t' + str(bad_updater),
            'kas-update.sh\t' + str(self.served_self),
        ]) + '\n')
        result = self.run_kas_update(['--apply', '--yes'])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('failed validation', result.stdout + result.stderr)
        self.assertEqual(self.binary.read_bytes(), OLD_BODY)

    def test_symlinked_canonical_refused(self):
        target = self.lab / 'opt/bin/user-real-watchdog.sh'
        target.write_text('#!/bin/sh\necho user content\n')
        self.binary.symlink_to(target)
        self.prepare_updater_payload()
        self.prepare_self_payload()
        self.serve_default_network()
        check = self.run_kas_update(['--check'])
        self.assertEqual(check.returncode, 2, check.stdout + check.stderr)
        self.assertIn('symlink', check.stdout)
        result = self.run_kas_update(['--apply', '--yes'])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertTrue(self.binary.is_symlink())
        self.assertEqual(target.read_text(), '#!/bin/sh\necho user content\n')

    def test_dialect_matrix_apply_flow(self):
        for shell in self.shells:
            with self.subTest(shell=' '.join(shell)):
                self.setUp()
                self.install_watchdog(OLD_BODY)
                self.prepare_updater_payload()
                self.prepare_self_payload()
                self.serve_default_network()
                check = self.run_kas_update(['--check'], shell=shell)
                self.assertEqual(check.returncode, 1, check.stdout + check.stderr)
                result = self.run_kas_update(['--apply', '--yes'], shell=shell)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('apply verified', result.stdout)
                self.assertEqual(self.binary.read_bytes(), NEW_BODY)

    def test_documented_contract_in_docs(self):
        updates = (REPO / 'docs' / '12-updates.md').read_text(encoding='utf-8')
        self.assertIn('kas-update.sh', updates)
        self.assertIn('--check', updates)
        self.assertIn('--apply', updates)
        self.assertIn(DOCUMENTED_COMMAND, updates)
        self.assertIn('read-only', updates.lower())
        scripts_ru = (REPO / 'docs' / 'SCRIPTS.md').read_text(encoding='utf-8')
        scripts_en = (REPO / 'docs' / 'EN' / 'SCRIPTS.md').read_text(encoding='utf-8')
        self.assertIn('kas-update.sh', scripts_ru)
        self.assertIn('kas-update.sh', scripts_en)
        changelog = (REPO / 'CHANGELOG.md').read_text(encoding='utf-8')
        self.assertIn('kas-update', changelog)


if __name__ == '__main__':
    print('NOTE: native PID/proc namespace: %s' % ('yes' if PROC_NATIVE else
          'no (busy-lock scenario skipped; identity adaptation is test-only)'))
    unittest.main(verbosity=2)
