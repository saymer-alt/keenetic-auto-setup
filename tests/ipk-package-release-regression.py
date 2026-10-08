#!/usr/bin/env python3
"""EG-02: package release decisions in both actual updater paths."""
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
text = (ROOT/'update-mihomo.sh').read_text()
def function(name):
    start=text.index(name+'() {')
    return text[start:text.index('\n}',start)+2]+'\n'
functions=''.join(function(name) for name in ('valid_version','ver_compare','same_version_package_action'))
early=text[text.index('if [ -n "$CURRENT_VER" ]; then'):text.index('# Remember whether Mihomo')]
deferred=text[text.index('if [ "$DEFER_VERSION_DECISION" -eq 1 ]; then\n  INSTALLED_VER='):text.index('# 13. Runtime pre-flight')]
with tempfile.TemporaryDirectory() as directory:
    root=Path(directory)
    binary=root/'mihomo';binary.write_bytes(b'core\n')
    state=root/'state'
    for shell in (['sh'], ['busybox','ash']):
        for release, force, action in [('1',0,'proceed'),('2',0,'skip'),('2',1,'proceed'),('3',0,'skip'),('3',1,'skip'),('10',1,'skip'),('bad',1,'invalid')]:
            state.write_text(f'''state_format=1
runtime_version=1.19.32
source=entware-go-binary-updater
asset=mihomo_1.19.32-{release}_mipsel-3.4.ipk
package_release={release}
binary_size_bytes=5
''')
            for mode, decision in ((0,early),(1,deferred)):
                setup=functions+f'''
BINARY_STATE={shlex.quote(str(state))}
MIHOMO_PATH={shlex.quote(str(binary))}
AVAILABLE_VER=1.19.32; CURRENT_VER=1.19.32; PACKAGE_RELEASE=2; IPK_SUFFIX=mipsel-3.4
FORCE_UPDATE={force}; DEFER_VERSION_DECISION={mode}; SERVICE_WAS_STOPPED=1
log() {{ :; }}; warn() {{ :; }}; error() {{ exit 9; }}; preflight_fail() {{ exit 9; }}
restore_stopped_service() {{ echo RESTORE; }}
'''
                # Deferred path normally calls the installed ELF only after stop. Fixture it.
                deferred_code=decision.replace('"$MIHOMO_PATH" -v', "printf 'Mihomo Meta 1.19.32\\n'")
                p=subprocess.run(shell,input=setup+deferred_code+'\necho PROCEED\n',text=True,capture_output=True,timeout=10)
                assert p.returncode == (9 if action=='invalid' else 0),(shell,release,force,mode,p.stdout,p.stderr)
                assert ('PROCEED' in p.stdout) == (action=='proceed'),(shell,release,force,mode,p.stdout)
                if mode==1 and action=='skip':
                    assert 'RESTORE' in p.stdout
        original=state.read_text().replace('bad','1')
        for bad in (original.replace('binary_size_bytes=5','binary_size_bytes=6'),
                    original.replace('runtime_version=1.19.32','runtime_version=1.19.31'),
                    original+'package_release=1\n', original.replace('mipsel-3.4','mips-3.4')):
            state.write_text(bad)
            setup=functions+f'\nBINARY_STATE={shlex.quote(str(state))}; MIHOMO_PATH={shlex.quote(str(binary))}; AVAILABLE_VER=1.19.32; IPK_SUFFIX=mipsel-3.4; PACKAGE_RELEASE=2\n'
            p=subprocess.run(shell,input=setup+'same_version_package_action\n',text=True,capture_output=True)
            assert p.stdout.strip()=='invalid',(shell,p.stdout,p.stderr)
        print('PASS',shell,'EG-02 same-runtime package release: early/deferred upgrade, no downgrade even force, state identity/malformed metadata')
