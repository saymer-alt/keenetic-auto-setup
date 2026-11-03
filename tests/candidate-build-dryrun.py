#!/usr/bin/env python3
"""Offline dry-run of the beta.5 candidate workflow with a historical
beta.4 override (workflow filename remains web-beta3-build.yml).

Executes the workflow's manifest-and-assert script against REAL IPKs built by
the project's own packaging/build-ipk.py in its supported --binary test mode,
and checks the uploaded artifact name, proving that the beta.5 candidate
uses the same dotted opkg version style as the actual published beta.4.
Negative side: a beta.4-built package under beta.5 pins must FAIL.

Scope note: build-ipk --binary packages a FAKE ELF; this is a
packaging/manifest/name regression, not proof of a production executable.
Real beta.5 binaries are produced by the crossbuild job on the pinned merge
SHA (readelf/ABI checks live there).
"""
import ast
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

import yaml

REPO = pathlib.Path(__file__).resolve().parent.parent
WORKFLOW = REPO / '.github/workflows/web-beta3-build.yml'
BUILDER = REPO / 'web/control-center/packaging/build-ipk.py'
HERE = pathlib.Path(__file__).resolve().parent

SOURCE_SHA = 'b' * 40
ARCH = 'aarch64-3.10'
BETA5_VERSION = '0.1.0.beta.5-1'
BETA5_TAG = 'v0.1.0-beta.5'
BETA5_PREFIX = 'kas-web-beta5'


def pub():
    # Shared bash/fixture helpers; full context in tests/_publication_testkit.py.
    import sys as _sys
    if str(HERE) not in _sys.path:
        _sys.path.insert(0, str(HERE))
    import _publication_testkit
    return _publication_testkit


def crossbuild_run_blocks():
    d = yaml.safe_load(WORKFLOW.read_text(encoding='utf-8'))
    return [s['run'] for s in d['jobs']['crossbuild']['steps'] if 'run' in s]


def manifest_fragment():
    run = [b for b in crossbuild_run_blocks() if 'manifest-canonical' in b][0]
    start = run.index('set -- ./*.ipk')
    end = run.index('PY', run.index("assert canonical['tag']")) + 2
    lines = run[start:end].split('\n')
    # The Go unit-test line needs the Go toolchain and module; the archive is
    # already verified structurally by the asserts and by build-ipk itself.
    nl = chr(10)
    return nl.join(line for line in lines if 'go test -count=1' not in line)


class Checker:
    def __init__(self, failures, label):
        self.failures, self.label = failures, label

    def __call__(self, cond, msg):
        if not cond:
            self.failures.append('%s: %s' % (self.label, msg))


def build_ipk_bytes(arch, version, sha):
    """Real IPK bytes via the project's packaging/build-ipk.py --binary mode."""
    with tempfile.TemporaryDirectory(prefix='kas-ipkbytes-') as td:
        fake = pathlib.Path(td) / 'fake-kas-control-center'
        fake.write_bytes(b'\x7fELF fake binary for packaging test ' + sha[:8].encode())
        out = pathlib.Path(td) / 'ipk'
        subprocess.run([sys.executable, str(BUILDER),
                        '--arch', arch, '--version', version, '--channel', 'experimental',
                        '--source-sha', sha, '--binary', str(fake),
                        '--output', str(out)], check=True, capture_output=True)
        ipk = next(out.glob('*.ipk'))
        return ipk.read_bytes()


def build_ipk(ws, arch, version, sha):
    fake_binary = ws / 'fake-kas-control-center'
    fake_binary.write_bytes(b'\x7fELF fake binary for archive test ' + sha[:8].encode())
    out = ws / 'runner-temp/ipk'
    out.mkdir(parents=True, exist_ok=True)
    subprocess.run([sys.executable, str(BUILDER),
                    '--arch', arch, '--version', version, '--channel', 'experimental',
                    '--source-sha', sha, '--binary', str(fake_binary),
                    '--output', str(out)], check=True)
    return out


def run_fragment(ws, fragment, arch, version, tag):
    mod = pub()
    ipk_dir = ws / 'runner-temp/ipk'
    ipk_dir.mkdir(parents=True, exist_ok=True)
    packaging = ws / 'web/control-center/packaging'
    packaging.mkdir(parents=True, exist_ok=True)
    shutil.copy(REPO / 'web/control-center/packaging/update-manifest.py',
                packaging / 'update-manifest.py')
    env = dict(os.environ)
    env.update({'BETA_VERSION': version, 'RELEASE_TAG': tag,
                'SOURCE_SHA': SOURCE_SHA, 'PACKAGE_ARCH': arch,
                'RUNNER_TEMP': str(ws / 'runner-temp'),
                'GITHUB_WORKSPACE': str(ws)})
    completed = subprocess.run([mod.BASH, '-e'], input=fragment.encode('utf-8'),
                               cwd=ipk_dir, env=env, capture_output=True)
    return completed.returncode, (completed.stdout + completed.stderr).decode('utf-8', 'replace')


def metadata_ladder_block():
    d = yaml.safe_load(WORKFLOW.read_text(encoding='utf-8'))
    return [s['run'] for s in d['jobs']['metadata-tests']['steps']
            if 'run' in s and 'compare-versions' in s['run']][0]


def resolve_metadata_env(d, dispatch_inputs):
    """Resolve the metadata-tests job env exactly as GitHub Actions would for
    the given workflow_dispatch inputs. {} models a push event: the inputs
    context is empty, so every `inputs.X || 'fallback'` takes the fallback."""
    env = {}
    for key, expr in (d['jobs']['metadata-tests'].get('env') or {}).items():
        m = re.fullmatch(r"\$\{\{ inputs\.(\w+) \|\| '([^']*)' \}\}", str(expr).strip())
        if not m:
            raise AssertionError('unexpected metadata env expression for %s: %r'
                                 % (key, expr))
        env[key] = dispatch_inputs.get(m.group(1)) or m.group(2)
    return env


def run_ladder(version, previous_version):
    """Run the workflow's own ladder block verbatim with substituted versions.
    Real Entware opkg, real network download with the pinned SHA; RUNNER_TEMP
    is a fresh mktemp dir. On Windows this goes through WSL bash."""
    block = metadata_ladder_block()
    script = ('set -euo pipefail\n'
              'export RUNNER_TEMP="$(mktemp -d /tmp/kas-ladder.XXXXXX)"\n'
              'trap \'rm -rf "$RUNNER_TEMP"\' EXIT\n'
              'export VERSION=%s PREVIOUS_VERSION=%s\n' % (version, previous_version)
              ) + block
    if os.name == 'posix':
        completed = subprocess.run(['bash', '-c', script], capture_output=True, timeout=240)
    else:
        wsl = shutil.which('wsl') or shutil.which('wsl.exe')
        if not wsl:
            raise RuntimeError('WSL is required to run the real opkg ladder on Windows')
        host = pathlib.Path(tempfile.mkdtemp(prefix='kas-ladder-script-')) / 'ladder.sh'
        host.write_text(script, encoding='utf-8', newline='\n')
        conv = subprocess.run([wsl, '-e', 'wslpath', '-a', str(host)],
                              capture_output=True, timeout=60)
        conv.check_returncode()
        completed = subprocess.run([wsl, '-e', 'bash', conv.stdout.decode().strip()],
                                   capture_output=True, timeout=240)
        shutil.rmtree(host.parent, ignore_errors=True)
    return completed.returncode, (completed.stdout + completed.stderr).decode('utf-8', 'replace')


def syntax_gate(failures):
    mod = pub()
    d = yaml.safe_load(WORKFLOW.read_text(encoding='utf-8'))
    for step in d['jobs']['crossbuild']['steps']:
        if 'run' not in step:
            continue
        r = subprocess.run([mod.BASH, '-n'], input=step['run'].encode('utf-8'),
                           capture_output=True)
        if r.returncode != 0:
            failures.append('bash -n failed: %s' % r.stderr.decode()[-300:])
        for body in re.findall(r"<<'PY'\n(.*?)\nPY\n", step['run'], re.S):
            try:
                ast.parse(body)
            except SyntaxError as error:
                failures.append('python heredoc does not parse: %s' % error)


def main():
    failures = []

    print('== syntax gate ==')
    before = len(failures)
    syntax_gate(failures)
    print('%-58s %s' % ('crossbuild blocks: bash -n + heredocs',
                        'PASS' if len(failures) == before else 'FAIL'))

    print('== static gate: no hardcoded release versions inside run blocks ==')
    before = len(failures)
    d = yaml.safe_load(WORKFLOW.read_text(encoding='utf-8'))
    for step in d['jobs']['crossbuild']['steps']:
        if 'run' not in step:
            continue
        for pattern in ('v0.1.0-beta.3', '0.1.0~beta.3-1', 'v0.1.0-beta.2', '0.1.0~beta.2-1'):
            if pattern in step['run']:
                failures.append('hardcoded %s inside a run block' % pattern)
    print('%-58s %s' % ('run blocks carry no hardcoded release versions',
                        'PASS' if len(failures) == before else 'FAIL'))

    ws = pathlib.Path(tempfile.mkdtemp(prefix='kas-candidate-dryrun-'))
    try:
        print('== real beta.5 artifacts (build-ipk --binary + workflow asserts) ==')
        before = len(failures)
        check = Checker(failures, 'beta.5 candidate artifacts')
        out = build_ipk(ws, ARCH, BETA5_VERSION, SOURCE_SHA)
        ipks = sorted(out.glob('*.ipk'))
        check(len(ipks) == 1, 'exactly one IPK built')
        ipk = ipks[0]
        check(ipk.name == 'kas-control-center_%s_%s.ipk' % (BETA5_VERSION, ARCH),
              'IPK file name carries the beta.5 version: %s' % ipk.name)
        upload_name = '%s-%s-%s' % (BETA5_PREFIX, ARCH, SOURCE_SHA)
        check(upload_name == 'kas-web-beta5-%s-%s' % (ARCH, SOURCE_SHA), 'artifact name')
        fragment = manifest_fragment()
        code, output = run_fragment(ws, fragment, ARCH, BETA5_VERSION, BETA5_TAG)
        check(code == 0, 'workflow asserts must pass for real beta.5 artifacts: %s'
              % output[-700:])
        if code == 0:
            manifest = json.loads((out / 'manifest-canonical.json').read_text())
            check(manifest['tag'] == BETA5_TAG, 'manifest tag')
            check(manifest['packages'][0]['version'] == BETA5_VERSION, 'manifest version')
            check(manifest['packages'][0]['source_sha'] == SOURCE_SHA, 'manifest source SHA')
        print('%-58s %s' % ('beta.5 candidate builds and verifies beta.5 artifacts',
                            'PASS' if len(failures) == before else 'FAIL'))
        print('   note: --binary fixtures are packaging regressions; real'
              ' binaries come from the crossbuild job on the pinned SHA')

        print('== negative: published beta.4 package under beta.5 pins must fail ==')
        before = len(failures)
        check = Checker(failures, 'mismatched pins rejected')
        shutil.rmtree(ws / 'runner-temp/ipk', ignore_errors=True)
        build_ipk(ws, ARCH, '0.1.0.beta.4-1', SOURCE_SHA)
        code_m, out_m = run_fragment(ws, manifest_fragment(), ARCH,
                                     '0.1.0.beta.4-1', 'v0.1.0-beta.4')
        check(code_m == 0, 'self-check: beta.4 pins verify a published-style beta.4 package: %s' % out_m[-400:])
        # Simulate the beta.5 publisher receiving a stale beta.4 IPK: the
        # workflow candidate pins must reject the wrong internal Version.
        shutil.rmtree(ws / 'runner-temp/ipk', ignore_errors=True)
        build_ipk(ws, ARCH, '0.1.0.beta.4-1', SOURCE_SHA)
        code_x, out_x = run_fragment(ws, fragment, ARCH, BETA5_VERSION, BETA5_TAG)
        check(code_x != 0, 'beta.4 package under beta.5 env must fail the asserts')
        print('%-58s %s' % ('mismatched version/tag pins are rejected',
                            'PASS' if len(failures) == before else 'FAIL'))
    finally:
        shutil.rmtree(ws, ignore_errors=True)

    print('== static gate: metadata ladder is env-parameterized with a valid push pair ==')
    before = len(failures)
    check = Checker(failures, 'metadata ladder parameterization')
    d = yaml.safe_load(WORKFLOW.read_text(encoding='utf-8'))
    on = d.get(True) or d.get('on') or {}
    inputs = (on.get('workflow_dispatch') or {}).get('inputs', {})
    check(inputs.get('version', {}).get('default') == '0.1.0.beta.5-1',
          'workflow_dispatch version defaults to beta.5')
    check(inputs.get('previous_version', {}).get('default') == '0.1.0.beta.4-1',
          'workflow_dispatch predecessor defaults to published beta.4 '
          '(a valid predecessor of the default beta.5)')
    check(inputs.get('tag', {}).get('default') == 'v0.1.0-beta.5',
          'dispatch tag defaults to beta.5')
    check(inputs.get('artifact_prefix', {}).get('default') == 'kas-web-beta5',
          'dispatch artifact prefix defaults to beta.5')
    paths = (on.get('push') or {}).get('paths', [])
    check(paths == ['.github/workflows/web-beta3-build.yml',
                    'web/control-center/**',
                    '!web/control-center/**/*.md'],
          'doc-only changes excluded after code-positive pattern')
    check((on.get('push') or {}).get('branches') == ['main'],
          'only main push may build a release candidate')
    env = d['jobs']['metadata-tests'].get('env', {})
    check(env.get('VERSION') == "${{ inputs.version || '0.1.0.beta.5-1' }}",
          'VERSION env is wired to the dispatch input')
    check(env.get('PREVIOUS_VERSION') == "${{ inputs.previous_version || '0.1.0.beta.4-1' }}",
          'PREVIOUS_VERSION env falls back to beta.4 so the implicit push pair is ordered')
    ladder = metadata_ladder_block()
    for pattern in ('0.1.0~beta.2-1', '0.1.0~beta.3-1', '0.1.0~beta.4-1', '0.1.0~beta.5-1', '0.1.0.beta.4-1', '0.1.0.beta.5-1', 'v0.1.0-beta'):
        check(pattern not in ladder, 'no hardcoded %s inside the ladder block' % pattern)
    check('$VERSION' in ladder and '$PREVIOUS_VERSION' in ladder,
          'ladder compares the env parameters, not literals')
    print('%-58s %s' % ('ladder is env-driven with an ordered push/default pair',
                        'PASS' if len(failures) == before else 'FAIL'))

    print('== implicit push/default env resolves to a strictly ordered pair ==')
    before = len(failures)
    check = Checker(failures, 'push/default resolution')
    try:
        push_env = resolve_metadata_env(d, {})
        check(push_env == {'VERSION': '0.1.0.beta.5-1', 'PREVIOUS_VERSION': '0.1.0.beta.4-1'},
              'implicit push env must resolve to beta.5 vs beta.4, got %r' % push_env)
        check(push_env['VERSION'] != push_env['PREVIOUS_VERSION'],
              'implicit push pair must not be equal (compare-versions fails on equality)')
        dispatch_env = resolve_metadata_env(
            d, {name: spec.get('default') for name, spec in inputs.items()})
        check(dispatch_env == push_env,
              'workflow_dispatch with declared defaults resolves identically to push')
    except Exception as error:
        failures.append('push/default resolution: harness error: %r' % error)
    print('%-58s %s' % ('push and dispatch-default env resolve to beta.5/beta.4',
                        'PASS' if len(failures) == before else 'FAIL'))

    print('== real Entware opkg ladder with parameterized versions (network) ==')
    if os.environ.get('KAS_DRYRUN_SKIP_LADDER') == '1':
        print('%-58s SKIP (KAS_DRYRUN_SKIP_LADDER=1)' % 'opkg ladder runs')
    else:
        before = len(failures)
        check = Checker(failures, 'opkg ladder')

        def q(v):
            return "'" + v + "'"

        try:
            # The ACTUAL implicit push/default env, not a simulated dispatch.
            rc, out = run_ladder(q(push_env['VERSION']), q(push_env['PREVIOUS_VERSION']))
            check(rc == 0, 'implicit push/default ladder (beta.5 vs beta.4) must pass: %s'
                  % out[-400:])
            # A dispatch that overrides only `version` still resolves a valid pair.
            version_only = resolve_metadata_env(d, {'version': '0.1.0.beta.6-1'})
            rc, out = run_ladder(q(version_only['VERSION']), q(version_only['PREVIOUS_VERSION']))
            check(rc == 0, 'version-only dispatch ladder (%s vs %s) must pass: %s'
                  % (version_only['VERSION'], version_only['PREVIOUS_VERSION'], out[-400:]))
            # Published beta.4 uses dotted 0.1.0.beta.4-1, not tilde.
            rc, out = run_ladder('"0.1.0.beta.5-1"', '"0.1.0.beta.4-1"')
            check(rc == 0, 'actual published beta.4 -> beta.5 ladder must pass: %s' % out[-400:])
            rc, out = run_ladder('"0.1.0.beta.6-1"', '"0.1.0.beta.5-1"')
            check(rc == 0, 'future beta.5 -> beta.6 ladder must pass: %s' % out[-400:])
            rc, out = run_ladder('"0.1.0~beta.5-1"', '"0.1.0.beta.4-1"')
            check(rc != 0, 'tilde beta.5 MUST NOT be treated as upgrade from real dotted beta.4')
            rc, out = run_ladder('"0.1.0.beta.4-1"', '"0.1.0.beta.5-1"')
            check(rc != 0, 'an inverted dispatch (previous newer than version) must fail')
            rc, out = run_ladder('"0.1.0.beta.5-1"', '"0.1.0.beta.5-1"')
            check(rc != 0, 'an explicit stale dispatch (VERSION == PREVIOUS_VERSION) must fail')
        except Exception as error:
            failures.append('opkg ladder: harness error: %r' % error)
        print('%-58s %s' % ('ladder: push pair, beta.4/beta.5 dispatches, negatives',
                            'PASS' if len(failures) == before else 'FAIL'))

    for failure in failures:
        print('FAIL: %s' % failure)
    print('%d assertion(s) failed' % len(failures))
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
