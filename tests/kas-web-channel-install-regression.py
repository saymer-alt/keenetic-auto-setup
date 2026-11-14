#!/usr/bin/env python3
"""Offline KAS Web channel installer checks (mocked curl/opkg, no network)."""
from __future__ import annotations
import hashlib
import json
import os
import pathlib
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
            for label,content in [('registry',reg),('index',idx),('release',release)]:
                (fixtures/(label+'.json')).write_text(json.dumps(content),encoding='utf-8')
            wrong = b'bad-data'.ljust(len(DATA),b'X')
            (fixtures/'asset.ipk').write_bytes(wrong if variant == 'bad_ipk_digest' else DATA)
            curl = bindir/'curl'
            curl.write_text("""#!/bin/sh
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
 status) if [ -n "$FAKE_CURRENT" ]; then printf 'Package: kas-control-center\\nVersion: %s\\nStatus: install ok installed\\n' "$FAKE_CURRENT"; fi ;;
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
            env = dict(os.environ,PATH=str(bindir)+os.pathsep+os.environ['PATH'],TMPDIR=tmp,
                       FAKE_FILES=str(fixtures),FAKE_CURRENT=current,FAKE_MARKER=str(root/'installed'))
            result = subprocess.run(['sh',str(SCRIPT),*args],capture_output=True,text=True,env=env,timeout=30)
            return result.returncode, result.stdout+result.stderr, (root/'installed').exists()

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

if __name__ == '__main__':
    unittest.main(verbosity=2)
