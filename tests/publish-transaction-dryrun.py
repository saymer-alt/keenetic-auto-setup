#!/usr/bin/env python3
"""Dry-run the beta.3 publishing transaction against a mock `gh`.

Executes every `run:` step of .github/workflows/ops-publish-kas-web-beta3-20261031.yml
in order, with a fixture GitHub state and controlled failure injections, and
asserts the FACTUAL final modeled state (release draft flag, assets, channel
index bytes, Latest tag) — not just exit codes. The one-shot workflow is never
triggered against the real GitHub Releases by this test.

Scenarios and their expected end states are listed in SCENARIOS; see also the
review contract on PR #304: the restore trap must stay armed through every
final publication assertion, including the GitHub Latest invariant.
"""
import base64
import hashlib
import io
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

import yaml

REPO = pathlib.Path(__file__).resolve().parent.parent
WORKFLOW = REPO / '.github/workflows/ops-publish-kas-web-beta3-20261031.yml'

SOURCE_SHA = 'b' * 40
RUN_ID = '424242'
BETA_TAG = 'v0.1.0-beta.3'
CHANNEL_TAG = 'kas-web-channel-experimental'
BETA_VERSION = '0.1.0~beta.3-1'
ARCHES = ['aarch64-3.10', 'armv7-3.2', 'mipsel-3.4', 'mips-3.4']
BETA2_INDEX = json.dumps({'schema': 1, 'channel': 'experimental',
                          'tag': 'v0.1.0-beta.2', 'packages': []}).encode()
CORE_LATEST = 'v1.8.5'
HIJACKED_LATEST = 'v0.0.0-hijacked'


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


def write_artifact_fixture(root, arch):
    """Materialize one CI artifact exactly as web-beta3-build.yml uploads it."""
    directory = root / arch
    directory.mkdir(parents=True, exist_ok=True)
    name = 'kas-control-center_%s_%s.ipk' % (BETA_VERSION, arch)
    payload = build_ipk(arch, BETA_VERSION, SOURCE_SHA)
    (directory / name).write_bytes(payload)
    # Same command as the build workflow: names carry the "./" prefix.
    (directory / 'SHA256SUMS').write_bytes(
        hashlib.sha256(payload).hexdigest().encode() + b'  ./' + name.encode() + b'\n')
    manifest = subprocess.run(
        [sys.executable, str(REPO / 'web/control-center/packaging/update-manifest.py'),
         '--channel', 'experimental', '--tag', BETA_TAG, str(directory / name)],
        capture_output=True, check=True)
    (directory / 'manifest-canonical.json').write_bytes(manifest.stdout)
    return directory


def asset_obj(name, data, tag, untagged=None):
    # GitHub serves draft assets under a temporary untagged-<id> directory
    # until the release is published; the canonical tag path appears only
    # after --draft=false (incident 2 of the beta.3 publication).
    return {'name': name, 'size': len(data), 'state': 'uploaded',
            'digest': 'sha256:' + hashlib.sha256(data).hexdigest(),
            'browser_download_url': 'https://github.com/saymer-alt/keenetic-auto-setup/releases/download/'
                + (untagged or tag) + '/' + name,
            'bytes_b64': base64.b64encode(data).decode()}



GH_MOCK = r'''#!/usr/bin/env python3
# Mock gh backed by a JSON state file; supports the beta.3 publish workflow.
import base64, hashlib, json, os, re, sys

STATE = os.environ['MOCK_STATE']
CALLS = os.environ['MOCK_CALLS']
CHANNEL_TAG = 'kas-web-channel-experimental'
HIJACKED_LATEST = 'v0.0.0-hijacked'
# MOCK_FAIL is a LIST of injection specs; each spec may carry "nth" counting
# ATTEMPTS of its phase (a failed attempt is recorded too).
FAILS = json.loads(os.environ.get('MOCK_FAIL', '[]'))
if isinstance(FAILS, dict):
    FAILS = [FAILS]


def load():
    with open(STATE, encoding='utf-8') as handle:
        return json.load(handle)


def save(state):
    with open(STATE, 'w', encoding='utf-8') as handle:
        json.dump(state, handle)


def record(call):
    with open(CALLS, encoding='utf-8') as handle:
        calls = json.load(handle)
    calls.append(call)
    with open(CALLS, 'w', encoding='utf-8') as handle:
        json.dump(calls, handle)


def matching_spec(phase):
    # Callers record the attempt BEFORE calling should_fail, so `seen` already
    # includes the current attempt and "nth" means the Nth attempt overall.
    for spec in FAILS:
        if spec.get('phase') != phase:
            continue
        nth = spec.get('nth', 0)
        if not nth:
            return spec
        with open(CALLS, encoding='utf-8') as handle:
            seen = sum(1 for c in json.load(handle) if c == phase)
        if seen == nth:
            return spec
    return None


def should_fail(phase):
    spec = matching_spec(phase)
    return spec.get('action', 'exit1') if spec else None


def public_release(release):
    return dict(release, assets=[{k: v for k, v in asset.items() if k != 'bytes_b64'}
                                 for asset in release['assets'].values()])


def asset_obj(name, data, tag, untagged=None):
    return {'name': name, 'size': len(data), 'state': 'uploaded',
            'digest': 'sha256:' + hashlib.sha256(data).hexdigest(),
            'browser_download_url': 'https://github.com/saymer-alt/keenetic-auto-setup/releases/download/'
                + (untagged or tag) + '/' + name,
            'bytes_b64': base64.b64encode(data).decode()}


def apply_jq(obj, program):
    program = program.strip()
    prefix = '.[] | select(.tag_name=="'
    if program.startswith(prefix) and program.endswith('")'):
        tag = program[len(prefix):-2]
        return [r for r in obj if r['tag_name'] == tag][0]
    for part in [p for p in program.strip('.').split('.') if p]:
        mm = re.fullmatch(r'(\w+)\[(\d+)\]', part)
        obj = obj[mm.group(1)][int(mm.group(2))] if mm else obj[part]
    return obj


def api(path, jq=None):
    record('api:' + path)
    if should_fail('api:' + path):
        sys.stderr.write('mock gh: injected api failure ' + path + '\n')
        sys.exit(1)
    state = load()
    obj = None
    m = re.match(r'repos/[^/]+/[^/]+/actions/runs/(\d+)$', path)
    tagm = re.match(r'repos/[^/]+/[^/]+/git/ref/tags/(.+)$', path)
    relm = re.match(r'repos/[^/]+/[^/]+/releases/tags/(.+)$', path)
    if m:
        run = state['runs'].get(m.group(1))
        obj = {'head_sha': run['head_sha'], 'conclusion': run['conclusion']} if run else None
    elif tagm:
        obj = {'object': {'sha': state['tags'][tagm.group(1)]}} if tagm.group(1) in state['tags'] else None
    elif relm:
        r = state['releases'].get(relm.group(1))
        obj = public_release(r) if r and not r['draft'] else None
    elif re.match(r'repos/[^/]+/[^/]+/releases\?per_page=100$', path):
        obj = [public_release(r) for r in state['releases'].values()]
        if state.get('hide_draft_until', 0) > 0:
            state['hide_draft_until'] -= 1
            save(state)
            obj = [r for r in obj if not r['draft']]
    elif re.match(r'repos/[^/]+/[^/]+/releases/latest$', path):
        obj = {'tag_name': state['latest']}
    if obj is None:
        sys.stderr.write('mock gh: HTTP 404 ' + path + '\n')
        sys.exit(1)
    if jq:
        obj = apply_jq(obj, jq)
    print(json.dumps(obj) if not isinstance(obj, str) else obj)


def main(argv):
    args = argv[1:]
    i = 0
    while i < len(args):
        if args[i] == '--repo':
            del args[i:i + 2]
        else:
            i += 1
    if not args:
        sys.exit(2)
    state = load()
    if args[0] == 'api':
        jq = args[args.index('--jq') + 1] if '--jq' in args else None
        api(args[1], jq)
        return
    if args[:2] == ['run', 'download']:
        name = args[args.index('--name') + 1]
        directory = args[args.index('--dir') + 1]
        record('artifact_download')
        if should_fail('artifact_download'):
            sys.stderr.write('mock gh: injected artifact download failure\n')
            sys.exit(1)
        os.makedirs(directory, exist_ok=True)
        for filename, b64 in state['artifacts'][name].items():
            with open(os.path.join(directory, filename), 'wb') as handle:
                handle.write(base64.b64decode(b64))
        return
    if args[:2] == ['release', 'create']:
        tag = args[2]
        record('release_create')
        if should_fail('release_create'):
            sys.stderr.write('mock gh: injected release create failure\n')
            sys.exit(1)
        state['releases'][tag] = {
            'tag_name': tag, 'target_commitish': args[args.index('--target') + 1],
            'draft': '--draft' in args, 'prerelease': '--prerelease' in args,
            'assets': {}, 'notes': args[args.index('--notes') + 1]}
        delay = matching_spec('draft_visibility_delay')
        if delay and state['releases'][tag]['draft']:
            state['hide_draft_until'] = delay.get('nth', 1)
        save(state)
        return
    if args[:2] == ['release', 'upload']:
        tag = args[2]
        files = [a for a in args[3:] if not a.startswith('--')]
        if tag == CHANNEL_TAG:
            record('channel_upload')
            if should_fail('channel_upload'):
                sys.stderr.write('mock gh: injected channel upload failure\n')
                sys.exit(1)
        release = state['releases'][tag]
        file_nth = 0
        for filename in files:
            file_nth += 1
            record('asset_upload_file')
            spec = matching_spec('asset_upload_file')
            if spec and (not spec.get('nth') or spec['nth'] == file_nth):
                save(state)
                sys.stderr.write('mock gh: injected asset upload failure (file %d)\n' % file_nth)
                sys.exit(1)
            with open(filename, 'rb') as handle:
                data = handle.read()
            untagged = 'untagged-' + tag if release['draft'] else None
            release['assets'][os.path.basename(filename)] = asset_obj(
                os.path.basename(filename), data, tag, untagged)
        if tag == CHANNEL_TAG:
            if should_fail('tamper_channel_asset'):
                release['assets']['panel-update.json'] = asset_obj(
                    'panel-update.json', b'tampered-index-bytes', tag)
            if should_fail('change_latest'):
                state['latest'] = HIJACKED_LATEST
        save(state)
        return
    if args[:2] == ['release', 'edit']:
        tag = args[2]
        if '--draft=false' in args:
            release = state['releases'][tag]
            release['draft'] = False
            state['tags'].setdefault(tag, release['target_commitish'])
            # Publishing finalizes the tag: asset URLs switch from the
            # temporary untagged-<id> directory to the canonical tag path.
            for name, asset in list(release['assets'].items()):
                release['assets'][name] = asset_obj(name, base64.b64decode(asset['bytes_b64']), tag)
        save(state)
        return
    if args[:2] == ['release', 'download']:
        tag = args[2]
        pattern = args[args.index('--pattern') + 1]
        directory = args[args.index('--dir') + 1]
        release = state['releases'].get(tag)
        if release is None:
            sys.exit(1)
        os.makedirs(directory, exist_ok=True)
        for name, asset in release['assets'].items():
            if name == pattern:
                with open(os.path.join(directory, name), 'wb') as handle:
                    handle.write(base64.b64decode(asset['bytes_b64']))
        return
    sys.stderr.write('mock gh: unsupported command %r\n' % (args[:2],))
    sys.exit(2)


if __name__ == '__main__':
    main(sys.argv)
'''


class Sandbox:
    def __init__(self):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix='kas-publish-dryrun-'))
        self.ws = self.root / 'ws'
        self.tmp = self.root / 'runner-temp'
        self.bin = self.root / 'bin'
        self.fixtures = self.root / 'fixtures'
        for directory in (self.ws, self.tmp, self.bin, self.fixtures):
            directory.mkdir()
        self.state_path = self.root / 'mock-state.json'
        self.calls_path = self.root / 'mock-calls.json'
        self.github_env = self.root / 'github-env.txt'
        self.gh_path = self.bin / 'gh'
        self.gh_path.write_text(GH_MOCK, encoding='utf-8', newline='\n')
        self.gh_path.chmod(0o755)

    def reset_state(self, releases=None):
        artifacts = {}
        for arch in ARCHES:
            directory = write_artifact_fixture(self.fixtures / 'artifacts', arch)
            artifacts['kas-web-beta3-%s-%s' % (arch, SOURCE_SHA)] = {
                p.name: base64.b64encode(p.read_bytes()).decode()
                for p in sorted(directory.iterdir())}
        state = {
            'runs': {RUN_ID: {'head_sha': SOURCE_SHA, 'conclusion': 'success'}},
            'tags': {},
            'latest': CORE_LATEST,
            'artifacts': artifacts,
            'releases': releases if releases is not None else {
                CHANNEL_TAG: {'tag_name': CHANNEL_TAG, 'draft': False, 'prerelease': False,
                              'target_commitish': 'v0.1.0-beta.2-era',
                              'assets': {'panel-update.json': asset_obj('panel-update.json',
                                                                        BETA2_INDEX, CHANNEL_TAG)}},
            },
        }
        self.state_path.write_text(json.dumps(state), encoding='utf-8')
        self.calls_path.write_text('[]', encoding='utf-8')
        shutil.rmtree(self.ws / 'build', ignore_errors=True)

    def env(self, fail=None, source_sha=SOURCE_SHA, verified_run=RUN_ID):
        environ = dict(os.environ)
        environ.update({
            'PATH': str(self.bin) + os.pathsep + environ.get('PATH', ''),
            'GH_TOKEN': 'dryrun', 'GH_REPO': 'saymer-alt/keenetic-auto-setup',
            'SOURCE_SHA': source_sha, 'VERIFIED_RUN': verified_run,
            'BETA_TAG': BETA_TAG, 'PREVIOUS_TAG': 'v0.1.0-beta.2',
            'CHANNEL_TAG': CHANNEL_TAG, 'BETA_VERSION': BETA_VERSION,
            'RUNNER_TEMP': str(self.tmp), 'GITHUB_ENV': str(self.github_env),
            'MOCK_STATE': str(self.state_path), 'MOCK_CALLS': str(self.calls_path),
        })
        if fail:
            environ['MOCK_FAIL'] = json.dumps(fail)
        else:
            environ.pop('MOCK_FAIL', None)
        return environ

    def state(self):
        return json.loads(self.state_path.read_text(encoding='utf-8'))


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


def load_steps():
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding='utf-8'))
    return workflow['jobs']['publish']['steps']


def run_workflow(sandbox, steps, fail=None, source_sha=SOURCE_SHA, verified_run=RUN_ID):
    # Each workflow run gets a fresh GitHub runner: nothing in the workspace
    # survives from a previous attempt.
    shutil.rmtree(sandbox.ws / 'build', ignore_errors=True)
    sandbox.github_env.write_text('', encoding='utf-8')
    results = []
    for step in steps:
        if 'uses' in step:
            if step['uses'].startswith('actions/checkout'):
                packaging = sandbox.ws / 'web/control-center/packaging'
                packaging.mkdir(parents=True, exist_ok=True)
                shutil.copy(REPO / 'web/control-center/packaging/update-manifest.py',
                            packaging / 'update-manifest.py')
            results.append((step.get('name', step['uses']), 0, ''))
            continue
        environ = sandbox.env(fail=fail, source_sha=source_sha, verified_run=verified_run)
        # Bytes, not text=True: a text pipe on Windows would translate newlines
        # to CRLF and break every `set -euo pipefail` line.
        completed = subprocess.run([BASH, '-e'], input=step['run'].encode('utf-8'),
                                   cwd=sandbox.ws, env=environ, capture_output=True)
        results.append((step.get('name', '<unnamed>'), completed.returncode,
                        (completed.stdout + completed.stderr).decode('utf-8', 'replace')))
        if completed.returncode != 0:
            break
    return results


def last_result(results):
    return results[-1][1], results[-1][2]


def channel_bytes(sandbox):
    return base64.b64decode(
        sandbox.state()['releases'][CHANNEL_TAG]['assets']['panel-update.json']['bytes_b64'])


def index_bytes_from_workspace(sandbox):
    return (sandbox.ws / 'build/panel-update.json').read_bytes()


def asset_bytes(sandbox, tag, name):
    return base64.b64decode(sandbox.state()['releases'][tag]['assets'][name]['bytes_b64'])


class Checker:
    def __init__(self, failures, label):
        self.failures = failures
        self.label = label

    def __call__(self, condition, message):
        if not condition:
            self.failures.append('%s: %s' % (self.label, message))


def assert_final(sandbox, check, *, channel, release_present, release_draft,
                 latest, tag_sha=None, target=SOURCE_SHA):
    state = sandbox.state()
    check(channel_bytes(sandbox) == channel, 'channel index bytes mismatch')
    beta = state['releases'].get(BETA_TAG)
    if not release_present:
        check(beta is None, 'beta.3 release should not exist')
        return
    check(beta is not None, 'beta.3 release missing')
    if beta is None:
        return
    check(beta['draft'] == release_draft, 'draft flag is %s' % beta['draft'])
    check(beta['prerelease'] is True, 'prerelease flag')
    check(beta['target_commitish'] == target, 'target commit')
    check(state['latest'] == latest, 'Latest is %r, want %r' % (state['latest'], latest))
    if tag_sha is not None:
        check(state['tags'].get(BETA_TAG) == tag_sha, 'tag sha')


def scenario_happy_path(sandbox, steps, failures):
    sandbox.reset_state()
    code, output = last_result(run_workflow(sandbox, steps))
    check = Checker(failures, 'happy path')
    check(code == 0, 'workflow failed: %s' % output[-800:])
    if code != 0:
        return
    new_index = index_bytes_from_workspace(sandbox)
    assert_final(sandbox, check, channel=new_index, release_present=True,
                 release_draft=False, latest=CORE_LATEST, tag_sha=SOURCE_SHA)
    assets = sandbox.state()['releases'][BETA_TAG]['assets']
    # GitHub normalizes '~' to '.' in release asset names.
    check(sorted(assets) == sorted(['SHA256SUMS'] + [
        'kas-control-center_0.1.0.beta.3-1_%s.ipk' % a for a in ARCHES]), 'asset set')
    for entry in json.loads(new_index)['packages']:
        name = entry['name']
        check(hashlib.sha256(asset_bytes(sandbox, BETA_TAG, name)).hexdigest()
              == entry['sha256'], '%s digest vs manifest' % name)


def scenario_placeholders(sandbox, steps, failures):
    for label, kwargs in [('missing VERIFIED_RUN', dict(verified_run='0')),
                          ('placeholder SOURCE_SHA', dict(source_sha='0' * 40)),
                          ('short SOURCE_SHA', dict(source_sha='abc'))]:
        sandbox.reset_state()
        code, _ = last_result(run_workflow(sandbox, steps, **kwargs))
        check = Checker(failures, label)
        check(code != 0, 'workflow must refuse')
        assert_final(sandbox, check, channel=BETA2_INDEX, release_present=False,
                     release_draft=False, latest=CORE_LATEST)


def scenario_unverified_run(sandbox, steps, failures):
    for label, run in [('failing CI run', {'head_sha': SOURCE_SHA, 'conclusion': 'failure'}),
                       ('wrong-head CI run', {'head_sha': 'c' * 40, 'conclusion': 'success'})]:
        sandbox.reset_state()
        state = sandbox.state()
        state['runs'][RUN_ID] = run
        sandbox.state_path.write_text(json.dumps(state), encoding='utf-8')
        code, _ = last_result(run_workflow(sandbox, steps))
        check = Checker(failures, label)
        check(code != 0, 'workflow must refuse')
        assert_final(sandbox, check, channel=BETA2_INDEX, release_present=False,
                     release_draft=False, latest=CORE_LATEST)


def scenario_corrupt_artifact(sandbox, steps, failures):
    sandbox.reset_state()
    state = sandbox.state()
    name = 'kas-web-beta3-mips-3.4-%s' % SOURCE_SHA
    ipk = [key for key in state['artifacts'][name] if key.endswith('.ipk')][0]
    raw = bytearray(base64.b64decode(state['artifacts'][name][ipk]))
    raw[len(raw) // 2] ^= 0xFF
    state['artifacts'][name][ipk] = base64.b64encode(bytes(raw)).decode()
    sandbox.state_path.write_text(json.dumps(state), encoding='utf-8')
    code, _ = last_result(run_workflow(sandbox, steps))
    check = Checker(failures, 'corrupt artifact')
    check(code != 0, 'workflow must fail')
    assert_final(sandbox, check, channel=BETA2_INDEX, release_present=False,
                 release_draft=False, latest=CORE_LATEST)


def scenario_manifest_mismatch(sandbox, steps, failures):
    sandbox.reset_state()
    state = sandbox.state()
    name = 'kas-web-beta3-aarch64-3.10-%s' % SOURCE_SHA
    manifest = json.loads(base64.b64decode(state['artifacts'][name]['manifest-canonical.json']))
    manifest['packages'][0]['sha256'] = 'f' * 64
    state['artifacts'][name]['manifest-canonical.json'] = base64.b64encode(
        json.dumps(manifest).encode()).decode()
    sandbox.state_path.write_text(json.dumps(state), encoding='utf-8')
    code, _ = last_result(run_workflow(sandbox, steps))
    check = Checker(failures, 'manifest mismatch')
    check(code != 0, 'workflow must fail')
    assert_final(sandbox, check, channel=BETA2_INDEX, release_present=False,
                 release_draft=False, latest=CORE_LATEST)


def scenario_existing_mismatched_release(sandbox, steps, failures):
    sandbox.reset_state()
    state = sandbox.state()
    state['releases'][BETA_TAG] = {'tag_name': BETA_TAG, 'draft': False, 'prerelease': True,
                                   'target_commitish': 'd' * 40, 'assets': {}}
    sandbox.state_path.write_text(json.dumps(state), encoding='utf-8')
    code, _ = last_result(run_workflow(sandbox, steps))
    check = Checker(failures, 'mismatched existing release')
    check(code != 0, 'workflow must refuse')
    beta = sandbox.state()['releases'][BETA_TAG]
    check(not beta['assets'], 'existing release assets untouched')
    assert_final(sandbox, check, channel=BETA2_INDEX, release_present=True,
                 release_draft=False, latest=CORE_LATEST, target='d' * 40)


def scenario_unknown_live_index(sandbox, steps, failures):
    sandbox.reset_state()
    state = sandbox.state()
    foreign = json.dumps({'schema': 1, 'channel': 'experimental',
                          'tag': 'kas-web-ipk-92e301d', 'packages': []}).encode()
    state['releases'][CHANNEL_TAG]['assets']['panel-update.json'] = asset_obj(
        'panel-update.json', foreign, CHANNEL_TAG)
    sandbox.state_path.write_text(json.dumps(state), encoding='utf-8')
    code, _ = last_result(run_workflow(sandbox, steps))
    check = Checker(failures, 'unknown live index')
    check(code != 0, 'workflow must refuse')
    check(channel_bytes(sandbox) == foreign, 'foreign index must not be clobbered')
    assert_final(sandbox, check, channel=foreign, release_present=False,
                 release_draft=False, latest=CORE_LATEST)


def scenario_partial_ipk_upload_then_retry(sandbox, steps, failures):
    sandbox.reset_state()
    code, _ = last_result(run_workflow(sandbox, steps,
                                       fail={'phase': 'asset_upload_file', 'nth': 2}))
    check = Checker(failures, 'partial IPK upload')
    check(code != 0, 'workflow must fail')
    state = sandbox.state()
    beta = state['releases'][BETA_TAG]
    check(beta['draft'] is True, 'release stays an invisible draft')
    check(len(beta['assets']) < 5, 'only part of the assets uploaded')
    assert_final(sandbox, check, channel=BETA2_INDEX, release_present=True,
                 release_draft=True, latest=CORE_LATEST)
    code, output = last_result(run_workflow(sandbox, steps))
    check2 = Checker(failures, 'retry after partial upload')
    check2(code == 0, 'workflow must succeed: %s' % output[-800:])
    if code == 0:
        assert_final(sandbox, check2, channel=index_bytes_from_workspace(sandbox),
                     release_present=True, release_draft=False, latest=CORE_LATEST,
                     tag_sha=SOURCE_SHA)


def scenario_channel_upload_fail_restored(sandbox, steps, failures):
    sandbox.reset_state()
    code, output = last_result(run_workflow(sandbox, steps,
                                            fail={'phase': 'channel_upload', 'nth': 1}))
    check = Checker(failures, 'channel upload failure')
    check(code != 0, 'workflow must fail')
    check('RESTORED' in output, 'restore attempted')
    assert_final(sandbox, check, channel=BETA2_INDEX, release_present=True,
                 release_draft=False, latest=CORE_LATEST, tag_sha=SOURCE_SHA)


def scenario_tampered_index_parallel_change(sandbox, steps, failures):
    sandbox.reset_state()
    code, output = last_result(run_workflow(sandbox, steps,
                                            fail={'phase': 'tamper_channel_asset'}))
    check = Checker(failures, 'tampered index')
    check(code != 0, 'workflow must fail')
    check('RESTORE SKIPPED' in output, 'must refuse to clobber a parallel change')
    check(channel_bytes(sandbox) == b'tampered-index-bytes', 'parallel change left alone')


def scenario_latest_changed_restores_channel(sandbox, steps, failures):
    sandbox.reset_state()
    code, output = last_result(run_workflow(sandbox, steps, fail={'phase': 'change_latest'}))
    check = Checker(failures, 'Latest changed')
    check(code != 0, 'workflow must fail')
    check('FATAL' in output, 'loud manual-intervention message required')
    assert_final(sandbox, check, channel=BETA2_INDEX, release_present=True,
                 release_draft=False, latest=HIJACKED_LATEST, tag_sha=SOURCE_SHA)


def scenario_latest_api_error_restores_channel(sandbox, steps, failures):
    sandbox.reset_state()
    fail = {'phase': 'api:repos/saymer-alt/keenetic-auto-setup/releases/latest', 'nth': 2}
    code, _ = last_result(run_workflow(sandbox, steps, fail=fail))
    check = Checker(failures, 'Latest API error')
    check(code != 0, 'workflow must fail')
    assert_final(sandbox, check, channel=BETA2_INDEX, release_present=True,
                 release_draft=False, latest=CORE_LATEST, tag_sha=SOURCE_SHA)


def scenario_restore_itself_fails(sandbox, steps, failures):
    sandbox.reset_state()
    fail = [{'phase': 'change_latest'},            # force the final-gate failure
            {'phase': 'channel_upload', 'nth': 2}]  # then break the restore upload
    code, output = last_result(run_workflow(sandbox, steps, fail=fail))
    check = Checker(failures, 'restore failure')
    check(code != 0, 'workflow must fail')
    check('RESTORE FAILED' in output, 'loud manual message required')
    check(channel_bytes(sandbox) != BETA2_INDEX,
          'channel stays switched (documented manual state)')


def scenario_idempotent_rerun_after_success(sandbox, steps, failures):
    sandbox.reset_state()
    run_workflow(sandbox, steps)
    first = channel_bytes(sandbox)
    code, output = last_result(run_workflow(sandbox, steps))
    check = Checker(failures, 'rerun after success')
    check(code == 0, 'must stay green: %s' % output[-500:])
    check(channel_bytes(sandbox) == first, 'channel byte-identical')
    assert_final(sandbox, check, channel=first, release_present=True,
                 release_draft=False, latest=CORE_LATEST, tag_sha=SOURCE_SHA)


def scenario_draft_listing_delay_retried(sandbox, steps, failures):
    # Incident 1 (beta.3 publication, run 41229787313): the fresh draft was
    # missing from the releases listing right after create and set -e killed
    # the step. The bounded read-only retry must overcome a delayed listing.
    sandbox.reset_state()
    code, output = last_result(run_workflow(
        sandbox, steps, fail={'phase': 'draft_visibility_delay', 'nth': 3}))
    check = Checker(failures, 'draft listing delay')
    check(code == 0, 'bounded retry must overcome the listing delay: %s' % output[-600:])
    if code == 0:
        assert_final(sandbox, check, channel=index_bytes_from_workspace(sandbox),
                     release_present=True, release_draft=False,
                     latest=CORE_LATEST, tag_sha=SOURCE_SHA)


SCENARIOS = [
    ('draft listing delay retried read-only', scenario_draft_listing_delay_retried),
    ('happy path', scenario_happy_path),
    ('placeholders refused', scenario_placeholders),
    ('unverified CI run refused', scenario_unverified_run),
    ('corrupt artifact refused', scenario_corrupt_artifact),
    ('manifest mismatch refused', scenario_manifest_mismatch),
    ('existing mismatched release refused', scenario_existing_mismatched_release),
    ('unknown live index refused', scenario_unknown_live_index),
    ('partial IPK upload then retry', scenario_partial_ipk_upload_then_retry),
    ('channel upload failure restores beta.2', scenario_channel_upload_fail_restored),
    ('tampered index treated as parallel change', scenario_tampered_index_parallel_change),
    ('Latest changed restores channel, never rewrites Latest', scenario_latest_changed_restores_channel),
    ('Latest API error restores channel', scenario_latest_api_error_restores_channel),
    ('restore itself failing escalates', scenario_restore_itself_fails),
    ('idempotent rerun after success', scenario_idempotent_rerun_after_success),
]


BASH = find_bash()


def main():
    if not WORKFLOW.exists():
        print('workflow missing: %s' % WORKFLOW)
        return 2
    steps = load_steps()
    failures = []
    sandbox = Sandbox()
    try:
        for label, scenario in SCENARIOS:
            before = len(failures)
            try:
                scenario(sandbox, steps, failures)
            except Exception as error:  # a broken scenario is a failed scenario
                failures.append('%s: harness error: %r' % (label, error))
            print('%-52s %s' % (label, 'PASS' if len(failures) == before else 'FAIL'))
    finally:
        shutil.rmtree(sandbox.root, ignore_errors=True)
    for failure in failures:
        print('FAIL: %s' % failure)
    print('%d scenario(s), %d assertion(s) failed' % (len(SCENARIOS), len(failures)))
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
