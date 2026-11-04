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
no-op, wrapper creation, busy lifecycle lock, TTY confirmation requirement,
updater validation failure, user-data preservation, idempotent re-apply,
sh/dash/BusyBox ash dialects, plus the post-review safety contracts:
- customized watchdog body with an intact sanity marker is UNRECOGNIZED and
  requires explicit approval (--allow-unrecognized-base) before overwrite;
- recognized managed-release baselines apply with plain --yes;
- a candidate/updater payload drift (post-apply SHA mismatch) is a failure,
  never a green result;
- a foreign cron slot is REVIEW REQUIRED: --check exits 2 and --apply
  refuses with both files preserved (current and outdated binary variants).
"""
import hashlib
import os
import re
import shutil
import subprocess
import tempfile
import time
import unittest
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]

# Tiny marker-valid bodies used as channel candidates and mismatch payloads.
OLD_BODY = b'#!/bin/sh\n# MIHOMO WATCHDOG SCRIPT\n# previous release body\nexit 0\n'
NEW_BODY = b'#!/bin/sh\n# MIHOMO WATCHDOG SCRIPT\n# next release body\nexit 0\n'
DRIFT_BODY = b'#!/bin/sh\n# MIHOMO WATCHDOG SCRIPT\n# drifted channel body\nexit 0\n'
UNVERIFIED_NOTE = 're-run kas-update --check to re-assess the actual state'
sha = lambda data: hashlib.sha256(data).hexdigest()

PROC_NATIVE = subprocess.run(['sh', '-c',
    'IFS=" " read -r actual rest < /proc/self/stat; [ "$actual" = "$$" ]']
    ).returncode == 0

# Real-file permission semantics only exist on POSIX hosts; elsewhere the
# harness emulates them (see UPDATER_PREFIX) and CI covers real modes.
POSIX_MODES = os.name == 'posix'

DOCUMENTED_COMMAND = ('curl -fSsL -o /tmp/kas-update.sh '
    'https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/kas-update.sh')

BODY_CACHE = {}

# The five known legacy watchdog bodies are pinned by kas-update's
# KNOWN_LEGACY_HASHES (= update-watchdog.sh LEGACY_HASHES). For fixtures we
# recover the exact historical bytes: local git history first, then the
# immutable raw URL of the historical commit (works on depth-1 CI checkouts).
LEGACY_COMMITS = {
    'a660e191909664b79f3d6d5fa0211ea85ad5609ab20e090e7309ee89d122d9ff':
        'f6ac99aec95d8b00a2297eef6ffb49b1a4895cf5',
    '7c8b6969fd4474e355d51801d6379d06281525140e74c8ca2d85e02dca5a8715':
        '69acc361091fa356cdb0b00c979557b553891bbf',
    '39c5a07ff74d9bc922678e06ecb7def97c0c5ab66641b2d41aedba741b9fbee6':
        '2e08ce18e7da08e26fe9f5daf2c969a20fbb87d2',
    'a37fbd888bb6b7149922c3603b1fc26f6478e3e5c88f91945f31f0552c7c163a':
        'c273a6acc0ac057f61b24b816b012b5276928ca8',
    '122d17d8fa40cc9d6a4c1879094cdcf299c5e6e5a4e00c83a8bb807a7749bd80':
        '66959c0d23ec452fe7094808b5f8987b7fdbf822',
}


def release_body(tag):
    """Bytes of mihomo-watchdog.sh at a release tag; its sha256 must be in
    kas-update's KNOWN_RELEASE_HASHES catalogue (recognition fixture)."""
    if tag in BODY_CACHE:
        return BODY_CACHE[tag]
    data = None
    try:
        out = subprocess.run(['git', '-C', str(REPO), 'show', '%s:mihomo-watchdog.sh' % tag],
                             capture_output=True)
        if out.returncode == 0 and out.stdout:
            data = out.stdout
    except OSError:
        pass
    if data is None:
        # Checkout without tags (e.g. plain CI fetch): take the exact
        # release bytes from raw.githubusercontent.com instead.
        url = 'https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/%s/mihomo-watchdog.sh' % tag
        with urllib.request.urlopen(url, timeout=30) as response:
            data = response.read()
    BODY_CACHE[tag] = data
    return data


def legacy_body(digest):
    """Exact historical bytes of one known legacy watchdog body."""
    key = 'legacy:%s' % digest
    if key in BODY_CACHE:
        return BODY_CACHE[key]
    commit = LEGACY_COMMITS[digest]
    data = None
    try:
        out = subprocess.run(['git', '-C', str(REPO), 'show', '%s:mihomo_watchdog.sh' % commit],
                             capture_output=True)
        if out.returncode == 0 and out.stdout:
            data = out.stdout
    except OSError:
        pass
    if data is None:
        url = 'https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/%s/mihomo_watchdog.sh' % commit
        with urllib.request.urlopen(url, timeout=30) as response:
            data = response.read()
    assert sha(data) == digest, 'legacy fixture bytes mismatch for %s' % digest[:12]
    BODY_CACHE[key] = data
    return data


def insert_local_tune_comment(body):
    """A locally edited release body: extra comment line after the shebang,
    sanity marker intact, SHA-256 no longer matching any managed release."""
    edited = body.replace(b'#!/bin/sh\n', b'#!/bin/sh\n# locally tuned\n', 1)
    assert edited != body and b'MIHOMO WATCHDOG SCRIPT' in edited
    return edited


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
# kas_mock_fetch rotates through repeated manifest entries per basename,
# advancing only on success (single-entry manifests behave identically).
MOCK_FETCHERS = r'''
kas_mock_fetch() {
  [ -n "${2:-}" ] && [ -n "${1:-}" ] || return 91
  _kf_base=${1##*/}; _kf_base=${_kf_base%%\?*}
  _kf_count_file="$MOCK_LOG.count.$_kf_base"
  _kf_idx=0
  if [ -f "$_kf_count_file" ]; then _kf_idx=$(cat "$_kf_count_file"); fi
  printf '%s\n' "$1" >> "$MOCK_LOG"
  _kf_total=0
  while IFS="	" read -r _kf_key _kf_path; do
    [ "$_kf_key" = "$_kf_base" ] || continue
    _kf_total=$(( _kf_total + 1 ))
  done < "$MANIFEST"
  [ "$_kf_total" -gt 0 ] || return 91
  _kf_pick=$_kf_idx
  if [ "$_kf_pick" -ge "$_kf_total" ]; then _kf_pick=$(( _kf_total - 1 )); fi
  _kf_n=0
  _kf_chosen=""
  while IFS="	" read -r _kf_key _kf_path; do
    [ "$_kf_key" = "$_kf_base" ] || continue
    if [ "$_kf_n" -eq "$_kf_pick" ]; then _kf_chosen="$_kf_path"; break; fi
    _kf_n=$(( _kf_n + 1 ))
  done < "$MANIFEST"
  [ -n "$_kf_chosen" ] && [ -f "$_kf_chosen" ] || return 92
  command cp "$_kf_chosen" "$2" || return 93
  if [ "$_kf_pick" -lt "$(( _kf_total - 1 ))" ]; then
    printf '%s\n' "$(( _kf_idx + 1 ))" > "$_kf_count_file"
  fi
  return 0
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

PREFIX = r'''#!/bin/sh
id() { echo 0; }
sleep() { :; }
opkg() {
  if [ "${1:-}" = list-installed ]; then
    printf '%s\n' "${MOCK_OPKG_LIST_INSTALLED:-magitrickle - 0.8.2-1}"
    return 0
  fi
  return 1
}
''' + MOCK_FETCHERS

# Host-independence mode overrides shared by the script under test and the
# delegated updater: managed files must verify as root:root even on CI
# runners and non-root hosts. On hosts with a no-op chmod (MSYS/NTFS
# mounts) the requested mode is recorded in a .kas-mode sidecar and
# synthesized back by the ls -ldn override; on normal hosts the real chmod
# still runs and the Python-level stat assertions verify real modes.
MODE_OVERRIDES = r'''
chown() { :; }
chmod() {
  # Real chmod runs with the full argument list; the sidecar only covers
  # hosts where the real chmod is a no-op (MSYS/NTFS).
  command chmod "$@" 2>/dev/null
  _ch_mode=$1
  shift
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
'''

UPDATER_PREFIX = '#!/bin/sh\n' + r'''
id() { echo 0; }
sleep() { :; }
''' + MODE_OVERRIDES + MOCK_FETCHERS

PREFIX = PREFIX + MODE_OVERRIDES


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

    def candidate_file(self, body=NEW_BODY):
        path = self.lab / ('candidate-%s.sh' % sha(body)[:8])
        if not path.exists():
            path.write_bytes(body)
        return path

    def serve_default_network(self):
        write_lf(self.manifest, '\n'.join([
            'mihomo-watchdog.sh\t' + str(self.candidate_file()),
            'update-watchdog.sh\t' + str(self.served_updater),
            'kas-update.sh\t' + str(self.served_self),
        ]) + '\n')

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
        self.assertIn('(opkg): 0.8.2-1', result.stdout)
        self.assertIn('not run by kas-update', result.stdout)
        self.assertNotIn('not shipped in historical Core tag', result.stdout)

    def test_opkg_two_field_version_is_supported(self):
        # Older/test fixtures sometimes omit the Entware separator.
        self.install_watchdog(NEW_BODY)
        self.env['MOCK_OPKG_LIST_INSTALLED'] = 'magitrickle 0.3.5-all'
        self.prepare_self_payload()
        self.serve_default_network()
        result = self.run_kas_update(['--check'])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('MagiTrickle (opkg): 0.3.5-all', result.stdout)

    def test_opkg_unparseable_version_is_unknown_not_dash(self):
        self.install_watchdog(NEW_BODY)
        self.env['MOCK_OPKG_LIST_INSTALLED'] = 'magitrickle -'
        self.prepare_self_payload()
        self.serve_default_network()
        result = self.run_kas_update(['--check'])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('version format is unknown', result.stdout)
        self.assertNotIn('MagiTrickle (opkg): -;', result.stdout)

    def test_opkg_absent_package_is_informational(self):
        self.install_watchdog(NEW_BODY)
        self.env['MOCK_OPKG_LIST_INSTALLED'] = 'other-pkg - 1.0'
        self.prepare_self_payload()
        self.serve_default_network()
        result = self.run_kas_update(['--check'])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('MagiTrickle: not found in the opkg package list', result.stdout)

    def test_historical_tag_skips_unavailable_selfcheck_without_retries(self):
        # v1.8.7 contains the watchdog, but never shipped kas-update.sh.
        # Candidate watchdog comparison must still run; no self-fetch
        # attempts should waste time on the guaranteed 404.
        self.install_watchdog(NEW_BODY)
        self.env['KEENETIC_AUTO_SETUP_REF'] = 'v1.8.7'
        self.serve_default_network()
        result = self.run_kas_update(['--check'])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('already current', result.stdout)
        self.assertIn('not shipped in historical Core tag v1.8.7', result.stdout)
        self.assertNotIn('curl download failed', result.stdout)
        self.assertFalse(any('kas-update.sh' in url for url in self.network_hits()))

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
        # OLD_BODY is a valid-marker body that matches no known release:
        # the check must name it as an unrecognized base, not a plain update.
        self.assertIn('UNRECOGNIZED', result.stdout)
        self.assertIn('--allow-unrecognized-base', result.stdout)
        self.assertIn('apply plan', result.stdout)
        self.assertIn('transactional update-watchdog.sh', result.stdout)

    def test_check_recognized_release_base_reports_plain_update(self):
        self.install_watchdog(release_body('v1.8.7'))
        self.prepare_updater_payload()
        self.prepare_self_payload()
        self.serve_default_network()
        result = self.run_kas_update(['--check'])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('update available', result.stdout)
        self.assertIn('recognized managed release body', result.stdout)
        self.assertNotIn('UNRECOGNIZED', result.stdout)
        self.assertNotIn('--allow-unrecognized-base', result.stdout)

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

    def test_custom_marker_base_requires_explicit_approval(self):
        # Locally customized watchdog that KEPT the sanity marker: hash
        # matches no known managed release. Never silently overwritten.
        custom = insert_local_tune_comment(release_body('v1.8.7'))
        self.install_watchdog(custom)
        self.prepare_updater_payload()
        self.prepare_self_payload()
        self.serve_default_network()
        check = self.run_kas_update(['--check'])
        self.assertEqual(check.returncode, 1, check.stdout + check.stderr)
        self.assertIn('UNRECOGNIZED', check.stdout)
        self.assertIn(sha(custom), check.stdout)
        # Plain --yes is NOT enough: the unrecognized base needs its own
        # explicit permission.
        refused = self.run_kas_update(['--apply', '--yes'])
        self.assertEqual(refused.returncode, 1, refused.stdout + refused.stderr)
        self.assertIn('not a known managed release', refused.stdout + refused.stderr)
        self.assertIn('--allow-unrecognized-base', refused.stdout + refused.stderr)
        self.assertEqual(self.binary.read_bytes(), custom)
        self.assertEqual(self.updater_hits(), [])
        # With the explicit flag the update proceeds through the updater.
        approved = self.run_kas_update(['--apply', '--yes', '--allow-unrecognized-base'])
        self.assertEqual(approved.returncode, 0, approved.stdout + approved.stderr)
        self.assertIn('apply verified', approved.stdout)
        self.assertEqual(self.binary.read_bytes(), NEW_BODY)

    def test_recognized_release_base_applies_without_extra_flag(self):
        # A real managed release body is recognized: the ordinary upgrade
        # path must not demand --allow-unrecognized-base.
        self.install_watchdog(release_body('v1.8.7'))
        self.prepare_updater_payload()
        self.prepare_self_payload()
        self.serve_default_network()
        result = self.run_kas_update(['--apply', '--yes'])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('apply verified', result.stdout)
        self.assertEqual(self.binary.read_bytes(), NEW_BODY)

    def test_recognized_previous_release_body(self):
        # Older release bodies are recognized too (cross-release upgrade).
        self.install_watchdog(release_body('v1.8.6'))
        self.prepare_updater_payload()
        self.prepare_self_payload()
        self.serve_default_network()
        check = self.run_kas_update(['--check'])
        self.assertEqual(check.returncode, 1, check.stdout + check.stderr)
        self.assertIn('recognized managed release body', check.stdout)
        self.assertNotIn('UNRECOGNIZED', check.stdout)

    def test_sha_mismatch_after_updater_is_a_failure(self):
        # Channel drift between kas-update's assessment download and the
        # updater's own download: the updater exits 0 having installed
        # different (still validated) bytes. kas-update must fail loudly,
        # never report a green apply.
        self.install_watchdog(release_body('v1.8.7'))
        self.prepare_updater_payload()
        self.prepare_self_payload()
        # Rotating manifest: assessment fetch serves NEW_BODY, the updater's
        # own candidate fetch then serves DRIFT_BODY.
        write_lf(self.manifest, '\n'.join([
            'mihomo-watchdog.sh\t' + str(self.candidate_file(NEW_BODY)),
            'mihomo-watchdog.sh\t' + str(self.candidate_file(DRIFT_BODY)),
            'update-watchdog.sh\t' + str(self.served_updater),
            'kas-update.sh\t' + str(self.served_self),
        ]) + '\n')
        result = self.run_kas_update(['--apply', '--yes'])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('apply did NOT verify', result.stdout + result.stderr)
        self.assertIn(sha(NEW_BODY), result.stdout + result.stderr)
        self.assertIn(sha(DRIFT_BODY), result.stdout + result.stderr)
        self.assertIn(UNVERIFIED_NOTE, result.stdout + result.stderr)
        self.assertEqual(self.binary.read_bytes(), DRIFT_BODY)
        # A follow-up check reassesses the actual state honestly: the drifted
        # body now IS the channel body in this fixture, so the state reports
        # current with the drifted hash — never the stale assessment.
        follow = self.run_kas_update(['--check'])
        self.assertEqual(follow.returncode, 0, follow.stdout + follow.stderr)
        self.assertIn('already current', follow.stdout)
        self.assertIn(sha(DRIFT_BODY), follow.stdout)

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
        self.install_watchdog(release_body('v1.8.7'))
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

    def test_foreign_wrapper_current_binary_requires_review(self):
        # Current canonical binary + unrecognized cron slot: NOT a green
        # "everything current"; the schedule is unverified content.
        foreign_body = '#!/bin/sh\n# MIHOMO WATCHDOG SCRIPT\n# unknown full watchdog body\nexit 0\n'
        self.install_watchdog(NEW_BODY)
        write_lf(self.wrapper, foreign_body)
        self.wrapper.chmod(0o755)
        self.prepare_updater_payload()
        self.prepare_self_payload()
        self.serve_default_network()
        check = self.run_kas_update(['--check'])
        self.assertEqual(check.returncode, 2, check.stdout + check.stderr)
        self.assertIn('REVIEW REQUIRED', check.stdout)
        self.assertIn('unrecognized', check.stdout)
        result = self.run_kas_update(['--apply', '--yes'])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('REVIEW REQUIRED', result.stdout + result.stderr)
        self.assertIn('update-watchdog.sh directly', result.stdout + result.stderr)
        self.assertEqual(self.binary.read_bytes(), NEW_BODY)
        self.assertEqual(self.wrapper.read_text(), foreign_body)
        self.assertEqual(self.updater_hits(), [])

    def test_foreign_wrapper_outdated_binary_requires_review(self):
        # Outdated canonical binary + unrecognized cron slot: kas-update
        # refuses instead of driving a transaction with an unreviewed
        # schedule; both files stay untouched.
        self.install_watchdog(OLD_BODY)
        foreign_body = '#!/bin/sh\n# MIHOMO WATCHDOG SCRIPT\n# another unknown body\nexit 0\n'
        write_lf(self.wrapper, foreign_body)
        self.wrapper.chmod(0o755)
        self.prepare_updater_payload()
        self.prepare_self_payload()
        self.serve_default_network()
        check = self.run_kas_update(['--check'])
        self.assertEqual(check.returncode, 2, check.stdout + check.stderr)
        self.assertIn('REVIEW REQUIRED', check.stdout)
        result = self.run_kas_update(['--apply', '--yes'])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.binary.read_bytes(), OLD_BODY)
        self.assertEqual(self.wrapper.read_text(), foreign_body)
        self.assertEqual(self.updater_hits(), [])

    def install_legacy_cron(self, body):
        """Legacy layout fixture: NO canonical binary; the full watchdog
        body sits directly at the cron path with the managed direct route."""
        self.wrapper.write_bytes(body)
        self.wrapper.chmod(0o755)
        wrapper_exec = str(self.wrapper).replace('\\', '/')
        write_lf(self.crontab, '*/5 * * * * root /bin/sh ' + wrapper_exec + '\n')
        self.crontab.chmod(0o644)

    def set_mode(self, path, mode):
        """Set a managed-file mode in a way every host shell under test can
        observe: the real chmod (effective on POSIX) plus the harness mode
        sidecar consumed by the ls -ldn override (covers no-op chmod hosts)."""
        path.chmod(mode)
        write_lf(Path(str(path) + '.kas-mode'), '%o\n' % mode)

    def assert_mode(self, path, mode):
        if POSIX_MODES:
            self.assertEqual(path.stat().st_mode & 0o7777, mode)
        else:
            sidecar = Path(str(path) + '.kas-mode')
            self.assertTrue(sidecar.is_file(), 'missing mode sidecar for %s' % path)
            self.assertEqual(sidecar.read_text(encoding='utf-8').strip(), '%o' % mode)

    def test_legacy_cron_full_body_migrates_when_canonical_absent(self):
        # canonical absent + recognized legacy full watchdog at the cron
        # path: kas-update plans the migration and the unchanged transactional
        # updater performs it (canonical + wrapper + one bounded backup).
        body = legacy_body('a37fbd888bb6b7149922c3603b1fc26f6478e3e5c88f91945f31f0552c7c163a')
        self.install_legacy_cron(body)
        self.prepare_updater_payload()
        self.prepare_self_payload()
        self.serve_default_network()
        check = self.run_kas_update(['--check'])
        self.assertEqual(check.returncode, 1, check.stdout + check.stderr)
        self.assertIn('recognized legacy full watchdog', check.stdout)
        self.assertNotIn('REVIEW REQUIRED', check.stdout)
        self.assertIn('apply plan', check.stdout)
        result = self.run_kas_update(['--apply', '--yes'])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('apply verified', result.stdout)
        # Canonical installed from the channel; cron slot became the wrapper.
        self.assertEqual(self.binary.read_bytes(), NEW_BODY)
        self.assertIn('exec ' + str(self.binary).replace('\\', '/'), self.wrapper.read_text())
        # One bounded legacy backup kept outside cron.5mins (updater contract).
        bak = self.lab / 'opt/etc/mihomo_watchdog.legacy.bak'
        self.assertTrue(bak.is_file())
        self.assertEqual(bak.read_bytes(), body)
        if POSIX_MODES:
            self.assertEqual(bak.stat().st_mode & 0o7777, 0o600)
        # Idempotent follow-up: everything recognized and current.
        follow = self.run_kas_update(['--check'])
        self.assertEqual(follow.returncode, 0, follow.stdout + follow.stderr)
        self.assertIn('already current', follow.stdout)

    def test_legacy_cron_with_canonical_binary_migrates(self):
        # Current canonical binary + a known legacy full watchdog at the
        # cron path: the updater converts the cron copy into the managed
        # wrapper with one bounded backup; the current binary is not rewritten.
        body = legacy_body('122d17d8fa40cc9d6a4c1879094cdcf299c5e6e5a4e00c83a8bb807a7749bd80')
        self.install_watchdog(NEW_BODY)
        self.wrapper.write_bytes(body)
        self.wrapper.chmod(0o755)
        self.prepare_updater_payload()
        self.prepare_self_payload()
        self.serve_default_network()
        check = self.run_kas_update(['--check'])
        self.assertEqual(check.returncode, 1, check.stdout + check.stderr)
        self.assertIn('recognized legacy full watchdog', check.stdout)
        result = self.run_kas_update(['--apply', '--yes'])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.binary.read_bytes(), NEW_BODY)
        self.assertIn('exec ' + str(self.binary).replace('\\', '/'), self.wrapper.read_text())
        bak = self.lab / 'opt/etc/mihomo_watchdog.legacy.bak'
        self.assertTrue(bak.is_file())
        self.assertEqual(bak.read_bytes(), body)

    def test_legacy_cron_unknown_body_requires_review_when_canonical_absent(self):
        # canonical absent + full watchdog body with the sanity marker but
        # an unknown hash: REVIEW, no writes, no updater invocation.
        self.install_legacy_cron(DRIFT_BODY)
        self.prepare_updater_payload()
        self.prepare_self_payload()
        self.serve_default_network()
        check = self.run_kas_update(['--check'])
        self.assertEqual(check.returncode, 2, check.stdout + check.stderr)
        self.assertIn('REVIEW REQUIRED', check.stdout)
        result = self.run_kas_update(['--apply', '--yes'])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('REVIEW REQUIRED', result.stdout + result.stderr)
        self.assertFalse(self.binary.exists())
        self.assertEqual(self.wrapper.read_text(), DRIFT_BODY.decode())
        self.assertEqual(self.updater_hits(), [])

    def test_canonical_absent_exact_wrapper_requires_repair_not_update(self):
        # canonical missing while an exact managed wrapper schedules it:
        # a broken layout. kas-update must not disguise the repair
        # (canonical installation) as an update: REVIEW with an explicit
        # reason, no writes, no updater invocation.
        self.install_watchdog(NEW_BODY)
        self.binary.unlink()
        self.prepare_updater_payload()
        self.prepare_self_payload()
        self.serve_default_network()
        check = self.run_kas_update(['--check'])
        self.assertEqual(check.returncode, 2, check.stdout + check.stderr)
        self.assertIn('REVIEW REQUIRED', check.stdout)
        self.assertIn('canonical file is missing', check.stdout)
        self.assertIn('install.sh', check.stdout)
        result = self.run_kas_update(['--apply', '--yes'])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('canonical file is missing', result.stdout + result.stderr)
        self.assertFalse(self.binary.exists())
        self.assertTrue(self.wrapper.is_file())
        self.assertEqual(self.updater_hits(), [])

    def test_legacy_hash_catalogue_matches_updater(self):
        # kas-update may only plan migrations the updater itself recognizes:
        # its KNOWN_LEGACY_HASHES must equal update-watchdog.sh LEGACY_HASHES.
        kas = (REPO / 'kas-update.sh').read_text(encoding='utf-8')
        upd = (REPO / 'update-watchdog.sh').read_text(encoding='utf-8')
        kas_list = re.search(r'KNOWN_LEGACY_HASHES="(.*?)"', kas, re.S).group(1)
        upd_list = re.search(r'LEGACY_HASHES="(.*?)"', upd, re.S).group(1)
        digest = lambda tokens: sorted(t for t in tokens.split()
                                       if re.fullmatch(r'[0-9a-f]{64}', t))
        self.assertEqual(digest(kas_list), digest(upd_list))

    # --- P1: no-op must not declare broken permissions/schedule healthy ---

    def test_non_executable_binary_gets_repair_not_noop(self):
        self.install_watchdog(NEW_BODY)
        self.set_mode(self.binary, 0o600)
        self.prepare_updater_payload()
        self.prepare_self_payload()
        self.serve_default_network()
        check = self.run_kas_update(['--check'])
        self.assertEqual(check.returncode, 1, check.stdout + check.stderr)
        self.assertIn('NOT executable', check.stdout)
        self.assertIn('repair', check.stdout)
        self.assertNotIn('nothing to apply', check.stdout)
        result = self.run_kas_update(['--apply', '--yes'])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        # Content-preserving repair: bytes untouched, mode fixed.
        self.assertEqual(self.binary.read_bytes(), NEW_BODY)
        self.assert_mode(self.binary, 0o755)
        follow = self.run_kas_update(['--check'])
        self.assertEqual(follow.returncode, 0, follow.stdout + follow.stderr)
        self.assertIn('nothing to apply', follow.stdout)

    def test_non_executable_wrapper_gets_repair_not_noop(self):
        self.install_watchdog(NEW_BODY)
        self.set_mode(self.wrapper, 0o600)
        self.prepare_updater_payload()
        self.prepare_self_payload()
        self.serve_default_network()
        check = self.run_kas_update(['--check'])
        self.assertEqual(check.returncode, 1, check.stdout + check.stderr)
        self.assertIn('NOT executable', check.stdout)
        result = self.run_kas_update(['--apply', '--yes'])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('exec ' + str(self.binary).replace('\\', '/'), self.wrapper.read_text())
        self.assert_mode(self.wrapper, 0o755)
        self.assertEqual(self.binary.read_bytes(), NEW_BODY)

    def test_missing_cron_route_gets_repair_not_noop(self):
        self.install_watchdog(NEW_BODY)
        write_lf(self.crontab, '')  # recognized pair, but nothing scheduled
        self.prepare_updater_payload()
        self.prepare_self_payload()
        self.serve_default_network()
        check = self.run_kas_update(['--check'])
        self.assertEqual(check.returncode, 1, check.stdout + check.stderr)
        self.assertIn('no active watchdog route', check.stdout)
        self.assertNotIn('nothing to apply', check.stdout)
        result = self.run_kas_update(['--apply', '--yes'])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        routes = [line for line in self.crontab.read_text().splitlines()
                  if line.strip()]
        self.assertEqual(len(routes), 1)
        self.assertIn('cron.5mins', routes[0])
        self.assertEqual(self.binary.read_bytes(), NEW_BODY)
        follow = self.run_kas_update(['--check'])
        self.assertEqual(follow.returncode, 0, follow.stdout + follow.stderr)

    def test_foreign_cron_route_requires_review_not_noop(self):
        wrapper_exec = str(self.binary).replace('\\', '/')
        self.install_watchdog(NEW_BODY)
        foreign = '*/2 * * * * root /bin/sh ' + wrapper_exec + '\n'
        write_lf(self.crontab, foreign)
        self.prepare_updater_payload()
        self.prepare_self_payload()
        self.serve_default_network()
        check = self.run_kas_update(['--check'])
        self.assertEqual(check.returncode, 2, check.stdout + check.stderr)
        self.assertIn('REVIEW REQUIRED', check.stdout)
        self.assertIn('never deletes foreign scheduling', check.stdout)
        self.assertNotIn('nothing to apply', check.stdout)
        result = self.run_kas_update(['--apply', '--yes'])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('REVIEW REQUIRED', result.stdout + result.stderr)
        # Foreign scheduling is never touched.
        self.assertEqual(self.crontab.read_text(), foreign)
        self.assertEqual(self.binary.read_bytes(), NEW_BODY)
        self.assertEqual(self.updater_hits(), [])

    def test_duplicate_recognized_routes_repaired(self):
        wrapper_exec = str(self.binary).replace('\\', '/')
        self.install_watchdog(NEW_BODY)
        write_lf(self.crontab, ''.join([
            '*/5 * * * * root /bin/sh ' + wrapper_exec + '\n',
            '*/5 * * * * root run-parts ' + str(self.lab).replace('\\', '/')
            + '/opt/etc/cron.5mins\n',
        ]))
        self.prepare_updater_payload()
        self.prepare_self_payload()
        self.serve_default_network()
        check = self.run_kas_update(['--check'])
        self.assertEqual(check.returncode, 1, check.stdout + check.stderr)
        self.assertIn('multiple recognized watchdog routes', check.stdout)
        result = self.run_kas_update(['--apply', '--yes'])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        routes = [line for line in self.crontab.read_text().splitlines()
                  if line.strip()]
        self.assertEqual(len(routes), 1)
        self.assertIn('run-parts', routes[0])
        follow = self.run_kas_update(['--check'])
        self.assertEqual(follow.returncode, 0, follow.stdout + follow.stderr)

    # --- P1: downloaded shell scripts must start with #!/bin/sh ----------

    def test_candidate_without_shebang_is_refused(self):
        self.install_watchdog(release_body('v1.8.7'))
        self.prepare_self_payload()
        no_shebang = self.lab / 'no-shebang-candidate.sh'
        no_shebang.write_bytes(NEW_BODY[len(b'#!/bin/sh\n'):])
        write_lf(self.manifest, '\n'.join([
            'mihomo-watchdog.sh\t' + str(no_shebang),
            'kas-update.sh\t' + str(self.served_self),
        ]) + '\n')
        check = self.run_kas_update(['--check'])
        self.assertEqual(check.returncode, 2, check.stdout + check.stderr)
        self.assertIn('UNKNOWN', check.stdout)
        result = self.run_kas_update(['--apply', '--yes'])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('nothing was changed', result.stdout + result.stderr)
        self.assertEqual(self.binary.read_bytes(), release_body('v1.8.7'))
        self.assertEqual(self.updater_hits(), [])

    def test_candidate_with_malformed_shebang_is_refused(self):
        self.install_watchdog(release_body('v1.8.7'))
        self.prepare_self_payload()
        malformed = self.lab / 'malformed-candidate.sh'
        malformed.write_bytes(b'#!/bin/bash\n' + NEW_BODY[len(b'#!/bin/sh\n'):])
        write_lf(self.manifest, '\n'.join([
            'mihomo-watchdog.sh\t' + str(malformed),
            'kas-update.sh\t' + str(self.served_self),
        ]) + '\n')
        check = self.run_kas_update(['--check'])
        self.assertEqual(check.returncode, 2, check.stdout + check.stderr)
        result = self.run_kas_update(['--apply', '--yes'])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(self.binary.read_bytes(), release_body('v1.8.7'))
        self.assertEqual(self.updater_hits(), [])

    def test_updater_without_shebang_is_refused(self):
        self.install_watchdog(release_body('v1.8.7'))
        self.prepare_self_payload()
        bad = self.lab / 'updater-no-shebang.sh'
        write_lf(bad, '# MIHOMO WATCHDOG UPDATER\necho not the updater\n')
        write_lf(self.manifest, '\n'.join([
            'mihomo-watchdog.sh\t' + str(self.candidate_file()),
            'update-watchdog.sh\t' + str(bad),
            'kas-update.sh\t' + str(self.served_self),
        ]) + '\n')
        result = self.run_kas_update(['--apply', '--yes'])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('failed validation', result.stdout + result.stderr)
        self.assertEqual(self.binary.read_bytes(), release_body('v1.8.7'))

    def test_apply_requires_confirmation_without_tty(self):
        self.install_watchdog(release_body('v1.8.7'))
        self.prepare_updater_payload()
        self.prepare_self_payload()
        self.serve_default_network()
        result = self.run_kas_update(['--apply'])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('interactive confirmation', result.stdout + result.stderr)
        self.assertEqual(self.binary.read_bytes(), release_body('v1.8.7'))

    def test_apply_busy_lifecycle_lock(self):
        if not PROC_NATIVE:
            self.skipTest('native PID/proc namespace required for a live lock owner')
        self.install_watchdog(release_body('v1.8.7'))
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
            self.assertEqual(self.binary.read_bytes(), release_body('v1.8.7'))
        finally:
            holder.communicate('\n', timeout=5)

    def test_apply_refuses_invalid_updater_payload(self):
        self.install_watchdog(release_body('v1.8.7'))
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
        self.assertEqual(self.binary.read_bytes(), release_body('v1.8.7'))

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
                self.install_watchdog(release_body('v1.8.7'))
                self.prepare_updater_payload()
                self.prepare_self_payload()
                self.serve_default_network()
                check = self.run_kas_update(['--check'], shell=shell)
                self.assertEqual(check.returncode, 1, check.stdout + check.stderr)
                result = self.run_kas_update(['--apply', '--yes'], shell=shell)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('apply verified', result.stdout)
                self.assertEqual(self.binary.read_bytes(), NEW_BODY)

    def test_dialect_matrix_review_refusal(self):
        # Review refusal and unrecognized-base refusal run on every dialect.
        custom = insert_local_tune_comment(release_body('v1.8.7'))
        for shell in self.shells:
            with self.subTest(shell=' '.join(shell)):
                self.setUp()
                self.install_watchdog(custom)
                self.prepare_updater_payload()
                self.prepare_self_payload()
                self.serve_default_network()
                refused = self.run_kas_update(['--apply', '--yes'], shell=shell)
                self.assertEqual(refused.returncode, 1, refused.stdout + refused.stderr)
                self.assertIn('not a known managed release', refused.stdout + refused.stderr)
                self.setUp()
                self.install_watchdog(NEW_BODY)
                write_lf(self.wrapper, '#!/bin/sh\n# MIHOMO WATCHDOG SCRIPT\n# alien body\nexit 0\n')
                self.wrapper.chmod(0o755)
                self.prepare_updater_payload()
                self.prepare_self_payload()
                self.serve_default_network()
                review = self.run_kas_update(['--apply', '--yes'], shell=shell)
                self.assertEqual(review.returncode, 1, review.stdout + review.stderr)
                self.assertIn('REVIEW REQUIRED', review.stdout + review.stderr)
                self.assertEqual(self.updater_hits(), [])

    def test_documented_contract_in_docs(self):
        updates = (REPO / 'docs' / '12-updates.md').read_text(encoding='utf-8')
        self.assertIn('kas-update.sh', updates)
        self.assertIn('--check', updates)
        self.assertIn('--apply', updates)
        self.assertIn('--allow-unrecognized-base', updates)
        self.assertIn('REVIEW', updates)
        self.assertIn('legacy', updates.lower())
        self.assertIn('bounded backup', updates)
        self.assertIn('исполняемость', updates)
        self.assertIn('#!/bin/sh', updates)
        updates_en = (REPO / 'docs' / 'EN' / 'UPDATES.md').read_text(encoding='utf-8')
        self.assertIn('executability', updates_en)
        self.assertIn('#!/bin/sh', updates_en)
        self.assertIn(DOCUMENTED_COMMAND, updates)
        self.assertIn('read-only', updates.lower())
        scripts_ru = (REPO / 'docs' / 'SCRIPTS.md').read_text(encoding='utf-8')
        scripts_en = (REPO / 'docs' / 'EN' / 'SCRIPTS.md').read_text(encoding='utf-8')
        self.assertIn('kas-update.sh', scripts_ru)
        self.assertIn('kas-update.sh', scripts_en)
        changelog = (REPO / 'CHANGELOG.md').read_text(encoding='utf-8')
        self.assertIn('kas-update', changelog)
        self.assertIn('--allow-unrecognized-base', changelog)


if __name__ == '__main__':
    print('NOTE: native PID/proc namespace: %s' % ('yes' if PROC_NATIVE else
          'no (busy-lock scenario skipped; identity adaptation is test-only)'))
    unittest.main(verbosity=2)
