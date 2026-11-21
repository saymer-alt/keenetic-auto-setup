#!/usr/bin/env python3
"""Offline KAS Web channel installer checks (mocked curl/opkg, no network)."""
from __future__ import annotations
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'kas-web-install.sh'
TAG = 'v0.1.0-beta.9'
VER = '0.1.0~beta.9-1'
NAME = 'kas-control-center_0.1.0.beta.9-1_mipsel-3.4.ipk'
DATA = b'fixture-only-not-a-real-ipk\n'
SHA = hashlib.sha256(DATA).hexdigest()
URL = 'https://github.com/saymer-alt/keenetic-auto-setup/releases/download/' + TAG + '/' + NAME

class InstallerTest(unittest.TestCase):
    def run_case(self, variant='normal', current='', args=('beta','--check')):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            bindir = root / 'bin'
            bindir.mkdir()
            fixtures = root / 'fixtures'
            fixtures.mkdir()
            reg = {'schema':1,'channels':{'experimental':{'published':True,'tag':TAG},'stable':{'published':False,'tag':''}}}
            pkg = {'name':NAME,'architecture':'mipsel-3.4','version':VER,'size':len(DATA),'sha256':SHA}
            idx = {'schema':1,'channel':'experimental','tag':TAG,'packages':[pkg]}
            asset = {'name':NAME,'size':len(DATA),'state':'uploaded',
                     'digest':'sha256:'+SHA,'browser_download_url':URL}
            release = {'tag_name':TAG,'draft':False,'prerelease':True,'assets':[asset]}
            if variant == 'wrong_release_digest': asset['digest']='sha256:'+'0'*64
            if variant == 'html_index': idx='<html>sign in</html>'
            if variant == 'stale_registry': reg['channels']['experimental']['tag']='v0.1.0-beta.8'
            if variant == 'duplicate_arch': idx['packages'].append(dict(pkg))
            if variant == 'wrong_arch': idx['packages'][0]['architecture']='aarch64-3.10'
            if variant == 'invalid_tag': reg['channels']['experimental']['tag']=idx['tag']=TAG+'/escape'
            if variant == 'invalid_version': idx['packages'][0]['version']=VER+'/escape'
            if variant == 'invalid_sha256': idx['packages'][0]['sha256']='g'+SHA[1:]
            if variant == 'invalid_name': idx['packages'][0]['name']=NAME+'.wrong'
            for label,content in [('registry',reg),('index',idx),('release',release)]:
                (fixtures/(label+'.json')).write_text(json.dumps(content),encoding='utf-8')
            wrong = b'bad-data'.ljust(len(DATA),b'X')
            (fixtures/'asset.ipk').write_bytes(wrong if variant == 'bad_ipk_digest' else DATA)
            curl = bindir/'curl'
            curl.write_text("""#!/bin/sh
if [ "$1" = "-V" ]; then
  if [ "${FAKE_BROKEN_CURL:-0}" = 1 ] && [ "${LD_BIND_NOW:-}" = 1 ]; then
    echo 'curl: symbol lookup error: curl: undefined symbol: curl_multi_get_offt' >&2
    exit 127
  fi
  echo 'curl 8.23.0 libcurl/8.23.0'
  exit 0
fi
out=; url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift; out="$1" ;;
    https://*) url="$1" ;;
  esac
  shift
done
case "$url" in
  */updates/channels.json) src="$FAKE_FILES/registry.json" ;;
  */updates/experimental/panel-update.json) src="$FAKE_FILES/index.json" ;;
  */releases/tags/v0.1.0-beta.9) src="$FAKE_FILES/release.json" ;;
  */releases/download/v0.1.0-beta.9/*) src="$FAKE_FILES/asset.ipk" ;;
  *) exit 22 ;;
esac
cp "$src" "$out" || exit 9
""",encoding='utf8')
            opkg = bindir/'opkg'
            opkg.write_text("""#!/bin/sh
case "$1" in
 print-architecture) printf 'arch all 1\\narch mipsel-3.4 10\\narch mipsel-3.4_kn 15\\n' ;;
 status)
   case "$2" in
     curl)
       if [ -n "$FAKE_CURL_VER" ]; then
         printf 'Package: %s\\nVersion: %s\\nStatus: %s\\n' \
           "$FAKE_CURL_PACKAGE" "$FAKE_CURL_VER" "$FAKE_CURL_STATUS"
       fi ;;
     libcurl)
       if [ -n "$FAKE_LIBCURL_VER" ]; then
         printf 'Package: libcurl\\nVersion: %s\\nStatus: install ok installed\\n' \
           "$FAKE_LIBCURL_VER"
         if [ "$FAKE_DUPLICATE_LIBCURL" = 1 ]; then
           printf 'Version: %s\\n' "$FAKE_LIBCURL_VER"
         fi
       fi ;;
     *) if [ -n "$FAKE_CURRENT" ]; then printf 'Package: kas-control-center\\nVersion: %s\\nStatus: install ok installed\\n' "$FAKE_CURRENT"; fi ;;
   esac ;;
 compare-versions)
   if [ "$3" = '=' ]; then [ "$2" = "$4" ]
   elif [ "$3" = '<' ]; then [ "$2" = '0.1.0~beta.8-1' ]
   else exit 1; fi ;;
 install) echo "INSTALL ATTEMPT" >> "$FAKE_MARKER"; exit 87 ;;
 *) exit 67 ;;
esac
""",encoding='utf8')
            curl.chmod(0o755)
            opkg.chmod(0o755)
            # Real Entware jq can lack ONIGURUMA. Simulate that build and
            # fail whenever a future installer reintroduces jq regex calls.
            real_jq = shutil.which('jq')
            if not real_jq:
                raise RuntimeError('jq needed for offline regression')
            jq_shim = bindir / 'jq'
            jq_shim.write_text("""#!/bin/sh
for arg in "$@"; do
  case "$arg" in
    *'test('*|*'match('*|*'gsub('*|*'sub('*) echo 'jq: no ONIGURUMA: regex functions unavailable' >&2; exit 3 ;;
  esac
done
exec "$REAL_JQ" "$@"
""", encoding='utf8')
            jq_shim.chmod(0o755)
            env = dict(os.environ,PATH=str(bindir)+os.pathsep+os.environ['PATH'],TMPDIR=tmp,
                       FAKE_FILES=str(fixtures),FAKE_CURRENT=current,FAKE_MARKER=str(root/'installed'),
                       REAL_JQ=real_jq, FAKE_BROKEN_CURL='1' if variant in ('broken_curl_loader', 'skewed_versions_broken_curl') else '0',
                       FAKE_CURL_VER='' if variant in ('missing_curl_record', 'missing_both_records') else '8.23.0-1',
                       FAKE_LIBCURL_VER='' if variant in ('missing_libcurl_record', 'missing_both_records') else
                            ('8.15.0-2' if variant in ('skewed_versions', 'skewed_versions_broken_curl') else '8.23.0-1'),
                       FAKE_CURL_PACKAGE='another-package' if variant == 'wrong_curl_package' else 'curl',
                       FAKE_CURL_STATUS='deinstall ok config-files' if variant == 'uninstalled_curl_record' else 'install ok installed',
                       FAKE_DUPLICATE_LIBCURL='1' if variant == 'duplicate_libcurl_version' else '0')
            result = subprocess.run(['sh',str(SCRIPT),*args],capture_output=True,text=True,env=env,timeout=30)
            return result.returncode, result.stdout+result.stderr, (root/'installed').exists()

    def test_broken_curl_libcurl_loader_fails_closed_before_download(self):
        # Field bug #254: curl binary upgraded, old libcurl missing symbol.
        # A shell mock mimics a lazy symbol: curl -V alone passes,
        # but LD_BIND_NOW=1 curl -V fails. A real ELF/OPKG
        # reproduction belongs to the isolated router-emulator gate.
        code, log, installed = self.run_case(variant='broken_curl_loader')
        self.assertNotEqual(code, 0, log)
        self.assertIn('curl cannot start', log)
        self.assertIn('curl/libcurl ABI mismatch', log)
        self.assertIn('repair libcurl manually', log)
        self.assertNotIn('Channel: ', log)  # no metadata/IPK download attempt
        self.assertFalse(installed)

    def test_skewed_curl_libcurl_versions_fail_closed_before_download(self):
        # Root cause of #254 (real Entware metadata, 2026-11-18): curl declares
        # 'Depends: ..., libcurl' with NO version bound, so opkg upgrades curl
        # alone. The package-database comparison catches the skew even when
        # curl -V happens to start (mismatch classes the probe cannot see).
        code, log, installed = self.run_case(variant='skewed_versions')
        self.assertNotEqual(code, 0, log)
        self.assertIn('version skew detected (8.23.0-1 vs 8.15.0-2)', log)
        self.assertIn('opkg install libcurl', log)
        self.assertNotIn('Channel: ', log)
        self.assertFalse(installed)

    def test_version_skew_is_reported_before_broken_loader(self):
        # On aarch64 curl -V can fail before the version check unless
        # the package database is inspected first. Use the more precise error.
        code, log, installed = self.run_case(variant='skewed_versions_broken_curl')
        self.assertNotEqual(code, 0, log)
        self.assertIn('version skew detected (8.23.0-1 vs 8.15.0-2)', log)
        self.assertNotIn('curl cannot start', log)
        self.assertNotIn('Channel: ', log)
        self.assertFalse(installed)

    def test_missing_or_unreliable_opkg_records_fail_closed(self):
        # curl -V success does not establish the integrity of the OPKG DB.
        variants = (
            'missing_curl_record', 'missing_libcurl_record',
            'missing_both_records', 'wrong_curl_package',
            'uninstalled_curl_record', 'duplicate_libcurl_version',
        )
        for variant in variants:
            with self.subTest(variant=variant):
                code, log, installed = self.run_case(variant=variant)
                self.assertNotEqual(code, 0, log)
                self.assertIn('installed-package records missing, malformed or unconfirmed', log)
                self.assertNotIn('Channel: ', log)
                self.assertFalse(installed)

    def test_current_beta(self):
        code,log,installed=self.run_case()
        self.assertEqual(code,0,log)
        self.assertFalse(installed)
        self.assertIn(VER,log)
    def test_install_stages_verified_ipk(self):
        code,log,installed=self.run_case(args=('beta',))
        self.assertNotEqual(code,0)
        self.assertTrue(installed)  # mock opkg intentionally returns 87
        self.assertIn('IPK SHA256 and size verified',log)
    def test_same_version_noop(self):
        code,_,installed=self.run_case(current=VER,args=('beta',))
        self.assertEqual(code,0)
        self.assertFalse(installed)
    def test_no_downgrade(self):
        code,log,installed=self.run_case(current='9.9.9',args=('beta',))
        self.assertNotEqual(code,0)
        self.assertFalse(installed)
        self.assertIn('Refusing downgrade',log)
    def test_stable_unpublished(self):
        code,log,installed=self.run_case(args=('stable',))
        self.assertNotEqual(code,0)
        self.assertFalse(installed)
        self.assertIn('not published',log)
    def test_no_release_digest_drift(self):
        code,_,installed=self.run_case(variant='wrong_release_digest',args=('beta',))
        self.assertNotEqual(code,0)
        self.assertFalse(installed)
    def test_bad_ipk_rejected(self):
        code,log,installed=self.run_case(variant='bad_ipk_digest',args=('beta',))
        self.assertNotEqual(code,0)
        self.assertFalse(installed)
        self.assertIn('SHA256 mismatch',log)
    def test_html_index_rejected(self):
        code,_,installed=self.run_case(variant='html_index')
        self.assertNotEqual(code,0)
        self.assertFalse(installed)
    def test_stale_registry_rejected(self):
        code,_,installed=self.run_case(variant='stale_registry')
        self.assertNotEqual(code,0)
        self.assertFalse(installed)
    def test_duplicate_arch_rejected(self):
        code,_,installed=self.run_case(variant='duplicate_arch')
        self.assertNotEqual(code,0)
        self.assertFalse(installed)
    def test_wrong_arch_rejected(self):
        code,_,installed=self.run_case(variant='wrong_arch')
        self.assertNotEqual(code,0)
        self.assertFalse(installed)
    def test_jq_without_oniguruma_beta_check(self):
        code, log, installed = self.run_case()
        self.assertEqual(code, 0, log)
        self.assertIn('Check only: metadata verified, no install', log)
        self.assertFalse(installed)
    def test_bad_tag_rejected_without_regex(self):
        code, _, installed = self.run_case(variant='invalid_tag')
        self.assertNotEqual(code, 0)
        self.assertFalse(installed)
    def test_bad_version_rejected_without_regex(self):
        code, _, installed = self.run_case(variant='invalid_version')
        self.assertNotEqual(code, 0)
        self.assertFalse(installed)
    def test_bad_sha256_rejected_without_regex(self):
        code, _, installed = self.run_case(variant='invalid_sha256')
        self.assertNotEqual(code, 0)
        self.assertFalse(installed)
    def test_bad_filename_rejected_without_regex(self):
        code, _, installed = self.run_case(variant='invalid_name')
        self.assertNotEqual(code, 0)
        self.assertFalse(installed)

if __name__ == '__main__':
    unittest.main(verbosity=2)
