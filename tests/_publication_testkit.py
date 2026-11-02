#!/usr/bin/env python3
"""Shared fixtures for the surviving publication dry-run suites.

Extracted from tests/publish-transaction-dryrun.py during the 2026-11-02
post-beta.4 cleanup: the one-shot publisher/switch workflows and their suites
were retired, but tests/pages-deploy-dryrun.py and tests/candidate-build-dryrun.py
still rely on these helpers. Nothing here is workflow-specific.
"""
import hashlib
import io
import os
import shutil
import subprocess
import tarfile


def find_bash():
    """A bash that actually receives this process's environment.

    On Windows, a bare 'bash' from PATH is often the WSL launcher, which does
    not inherit Windows env vars (except WSLENV) — the dry-run needs Git Bash.
    On CI Linux the plain 'bash' is correct.
    """
    candidates = [os.environ.get('KAS_DRYRUN_BASH')]
    if os.name == 'nt':
        for base in (os.environ.get('ProgramFiles', r'C:\Program Files'),
                     os.environ.get('ProgramFiles(x86)', r'C:\Program Files (x86)')):
            candidates += [base + r'\Git\bin\bash.exe', base + r'\Git\usr\bin\bash.exe']
    candidates.append(shutil.which('bash'))
    for candidate in candidates:
        if not candidate or not os.path.exists(candidate):
            continue
        release = subprocess.run([candidate, '-c', 'uname -r'], capture_output=True,
                                 text=True).stdout.lower()
        if 'microsoft' not in release:
            return candidate
    raise RuntimeError('no suitable bash found (WSL bash cannot receive the test environment)')


BASH = find_bash()


def build_ipk(arch, version, sha):
    """Minimal IPK that satisfies packaging/update-manifest.py without Go."""
    binary = ('fake-kas-control-center:%s:%s' % (version, sha)).encode()
    build_info = ('Version=%s\nArchitecture=%s\nKAS_SOURCE_SHA=%s\nBinary_SHA256=%s\n'
                  % (version, arch, sha, hashlib.sha256(binary).hexdigest())).encode()

    def tgz(members):
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode='w:gz') as tar:
            for name, data in members:
                info = tarfile.TarInfo(name)
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
        return buf.getvalue()

    control = ('Package: kas-control-center\nVersion: %s\nArchitecture: %s\nSource: %s\n'
               'Maintainer: KAS dry-run fixture\nSection: net\nPriority: optional\n'
               'Description: dry-run fixture package (never published)\nInstalled-Size: 1\n'
               % (version, arch, sha)).encode()
    data = tgz([('opt/share/kas-control-center/BUILD_INFO', build_info),
                ('opt/bin/kas-control-center', binary)])
    return tgz([('./control.tar.gz', tgz([('control', control)])),
                ('./data.tar.gz', data)])
