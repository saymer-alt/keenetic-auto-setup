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
if __name__=='__main__':unittest.main()
