import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
class PanelManifest(unittest.TestCase):
 def test_uses_actual_control_version_not_sanitized_filename(self):
  with tempfile.TemporaryDirectory() as td:
   td=Path(td);(td/'binary').write_bytes(b'fixture')
   subprocess.run(['python3',str(ROOT/'web/control-center/packaging/build-ipk.py'),'--arch','mipsel-3.4','--version','0.0.1~test16.aaaaaaaaaaaa-1','--source-sha','a'*40,'--binary',str(td/'binary'),'--output',str(td)],check=True,capture_output=True)
   package=next(td.glob('*.ipk'));renamed=td/package.name.replace('~','.')
   package.rename(renamed)
   result=subprocess.run(['python3',str(ROOT/'web/control-center/packaging/update-manifest.py'),'--channel','experimental','--tag','kas-web-ipk-aaaaaaa',str(renamed)],capture_output=True,text=True)
   self.assertEqual(result.returncode,0,result.stderr)
   item=json.loads(result.stdout)['packages'][0]
   self.assertEqual(item['version'],'0.0.1~test16.aaaaaaaaaaaa-1')
   self.assertEqual(item['name'],renamed.name)
   self.assertEqual(item['architecture'],'mipsel-3.4')
   self.assertGreater(item['unpacked_size'],len(b'fixture'))
 def accepts_tag(self,channel,tag):
  with tempfile.TemporaryDirectory() as td:
   td=Path(td);(td/'binary').write_bytes(b'fixture')
   subprocess.run(['python3',str(ROOT/'web/control-center/packaging/build-ipk.py'),'--arch','mipsel-3.4','--version','0.1.0~beta.2-1','--source-sha','a'*40,'--binary',str(td/'binary'),'--output',str(td)],check=True,capture_output=True)
   package=next(td.glob('*.ipk'))
   return subprocess.run(['python3',str(ROOT/'web/control-center/packaging/update-manifest.py'),'--channel',channel,'--tag',tag,str(package)],capture_output=True,text=True)
 def test_experimental_index_accepts_canonical_beta_tags(self):
  for tag in ('v0.1.0-beta.2','kas-web-v0.1.0-beta.2'):
   result=self.accepts_tag('experimental',tag)
   self.assertEqual(result.returncode,0,result.stderr)
   self.assertEqual(json.loads(result.stdout)['tag'],tag)
 def test_channel_tag_mismatches_are_rejected(self):
  for channel,tag in (('experimental','kas-web-v0.1.0'),('experimental','v0.1.0'),('experimental','v0.1.0-beta'),('stable','v0.1.0-beta.2'),('stable','kas-web-ipk-aaaaaaa'),('stable','kas-web-v0.1.0-beta.2')):
   result=self.accepts_tag(channel,tag)
   self.assertNotEqual(result.returncode,0,f'{channel} must reject {tag}')
   self.assertIn('tag does not match channel',result.stderr)
if __name__=='__main__':unittest.main()
