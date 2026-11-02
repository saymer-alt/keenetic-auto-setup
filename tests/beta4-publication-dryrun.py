#!/usr/bin/env python3
"""Offline dry-run of the split beta.4 publication.

  Stage A — ops-publish-kas-web-beta4.yml (release only): publishes the
            v0.1.0-beta.4 Release draft-first and must NOT touch the legacy
            channel, Pages, or any update index.
  Stage C — ops-switch-legacy-channel-beta4.yml: switches the legacy
            kas-web-channel-experimental index to beta.4, but ONLY after
            verifying that GitHub Pages serves the beta.4 index; refuses on
            unknown legacy state; restores on failure; gates on Latest.

Executes real shell steps (bash, python3, curl) against a mock gh and a
local mock Pages HTTP server. IPKs are real archives built by the project's
packaging/build-ipk.py --binary mode. Scenarios map to the required review
list:
  - successful Release publication with no channel changes;
  - IPK upload failure and retry;
  - SHA256 mismatch;
  - unexpected Latest change;
  - Pages not serving beta.4 before the legacy switch;
  - legacy switch attempted while Pages still serves beta.3;
  - tampered (replaced) published release IPK after Stage A;
  - unknown legacy index state;
  - switch failure and restore;
  - idempotent rerun after success.
"""
import ast
import base64
import hashlib
import http.server
import importlib.util
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import threading

import yaml

REPO = pathlib.Path(__file__).resolve().parent.parent
HERE = pathlib.Path(__file__).resolve().parent
RELEASE_WF = REPO / '.github/workflows/ops-publish-kas-web-beta4.yml'
SWITCH_WF = REPO / '.github/workflows/ops-switch-legacy-channel-beta4.yml'
PAGES_ROOT = '/keenetic-auto-setup'
CANON_BASE = 'https://github.com/saymer-alt/keenetic-auto-setup'

SOURCE_SHA = 'c' * 40
RUN_ID = '525252'
ARCHES = ['aarch64-3.10', 'armv7-3.2', 'mipsel-3.4', 'mips-3.4']
BETA4_VERSION = '0.1.0~beta.4-1'
BETA4_TAG = 'v0.1.0-beta.4'
PREVIOUS_TAG = 'v0.1.0-beta.3'
PREFIX = 'kas-web-beta4'
CHANNEL_TAG = 'kas-web-channel-experimental'
CORE_LATEST = 'v1.8.4'
HIJACKED_LATEST = 'v0.0.0-hijacked'

failures = []

_spec = importlib.util.spec_from_file_location('pub', HERE / 'publish-transaction-dryrun.py')
pub = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pub)
BASH = pub.BASH


def sha(data):
    return hashlib.sha256(data).hexdigest()


def ipk_name(arch):
    return ('kas-control-center_%s_%s.ipk' % (BETA4_VERSION, arch)).replace('~', '.')


def asset_obj(name, data, tag, untagged=None, base=CANON_BASE):
    return {'name': name, 'size': len(data), 'state': 'uploaded',
            'digest': 'sha256:' + sha(data),
            'browser_download_url': '%s/releases/download/%s/%s'
                % (base, untagged or tag, name),
            'bytes_b64': base64.b64encode(data).decode()}


def build_artifacts(root):
    """Fixture CI artifacts: REAL IPKs via build-ipk --binary, dot-named like
    GitHub release assets, plus per-arch manifests and SHA256SUMS."""
    root = pathlib.Path(root)
    shutil.rmtree(root, ignore_errors=True)
    for arch in ARCHES:
        d = root / arch
        d.mkdir(parents=True)
        fake = d / 'fake-kas-control-center'
        fake.write_bytes(b'\x7fELF fake binary for packaging test ' + SOURCE_SHA[:8].encode())
        out = d / 'ipk'
        subprocess.run([sys.executable, str(REPO / 'web/control-center/packaging/build-ipk.py'),
                        '--arch', arch, '--version', BETA4_VERSION,
                        '--channel', 'experimental', '--source-sha', SOURCE_SHA,
                        '--binary', str(fake), '--output', str(out)],
                       check=True, capture_output=True)
        ipk = next(out.glob('*.ipk'))
        shutil.move(str(ipk), str(d / ipk_name(arch)))
        shutil.rmtree(out, ignore_errors=True)
        manifest = subprocess.run(
            [sys.executable, str(REPO / 'web/control-center/packaging/update-manifest.py'),
             '--channel', 'experimental', '--tag', BETA4_TAG, str(d / ipk_name(arch))],
            capture_output=True, check=True)
        (d / 'manifest-canonical.json').write_bytes(manifest.stdout)
        (d / 'SHA256SUMS').write_bytes(
            (sha((d / ipk_name(arch)).read_bytes()).encode() + b'  ./' + ipk_name(arch).encode() + b'\n'))


def expected_index_bytes(fixture_root):
    """The index the workflow rebuilds from the pinned artifacts: update-manifest
    over the dot-named IPKs in the same sorted order as the shell glob."""
    fixture_root = pathlib.Path(fixture_root)
    ipks = sorted((p for a in ARCHES for p in (fixture_root / a).glob('*.ipk')),
                  key=lambda p: p.name)
    manifest = subprocess.run(
        [sys.executable, str(REPO / 'web/control-center/packaging/update-manifest.py'),
         '--channel', 'experimental', '--tag', BETA4_TAG] + [str(p) for p in ipks],
        capture_output=True, check=True)
    return manifest.stdout


def prev_index_bytes():
    return json.dumps({'schema': 1, 'channel': 'experimental',
                       'tag': PREVIOUS_TAG, 'packages': []}).encode()


def release_sums_bytes(fixture_root):
    """The combined build/ipk/SHA256SUMS the workflow regenerates (glob order)."""
    entries = sorted(((ipk_name(a), (pathlib.Path(fixture_root) / a / ipk_name(a)).read_bytes())
                      for a in ARCHES), key=lambda e: e[0])
    return ''.join('%s  ./%s\n' % (sha(data), name) for name, data in entries).encode()


def load_blocks(path):
    d = yaml.safe_load(path.read_text(encoding='utf-8'))
    job = 'publish' if 'publish' in d['jobs'] else 'switch'
    return [(s.get('name', s.get('uses', '?')), s.get('uses'), s.get('run'))
            for s in d['jobs'][job]['steps']]


def syntax_gate(failures):
    for path in (RELEASE_WF, SWITCH_WF):
        d = yaml.safe_load(path.read_text(encoding='utf-8'))
        job = 'publish' if 'publish' in d['jobs'] else 'switch'
        for step in d['jobs'][job]['steps']:
            if 'run' not in step:
                continue
            r = subprocess.run([BASH, '-n'], input=step['run'].encode('utf-8'),
                               capture_output=True)
            if r.returncode != 0:
                failures.append('bash -n failed for %s (%s): %s' % (
                    path.name, step.get('name', '?'), r.stderr.decode()[-300:]))
            for body in re.findall(r"<<'PY'\n(.*?)\nPY\n", step['run'], re.S):
                try:
                    ast.parse(body)
                except SyntaxError as error:
                    failures.append('python heredoc in %s does not parse: %s'
                                    % (path.name, error))


def release_asset_bytes(state_path, tag, name):
    try:
        state = json.loads(pathlib.Path(state_path).read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return None
    release = state.get('releases', {}).get(tag)
    asset = release.get('assets', {}).get(name) if release else None
    return None if asset is None else base64.b64decode(asset['bytes_b64'])


class PagesState:
    def __init__(self):
        self.store = {}
        self.lock = threading.Lock()

    def set(self, rel, code, body):
        with self.lock:
            self.store[PAGES_ROOT + rel] = code, body

    def serve(self, path):
        with self.lock:
            return self.store.get(path, (404, b'not found'))

    def get(self, rel):
        with self.lock:
            return self.store.get(PAGES_ROOT + rel)

    def digest(self, rel):
        with self.lock:
            item = self.store.get(PAGES_ROOT + rel)
            return None if item is None else sha(item[1])


def make_pages_server(pages, state_path):
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            m = re.match(r'^' + re.escape(PAGES_ROOT) + r'/releases/download/([^/]+)/([^/]+)$',
                         self.path)
            if m:
                data = release_asset_bytes(state_path, m.group(1), m.group(2))
                code, body = (404, b'not found') if data is None else (200, data)
            else:
                code, body = pages.serve(self.path)
            self.send_response(code)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.handle_error = lambda *args: None
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


GH_MOCK = r'''#!/usr/bin/env python3
import base64, hashlib, json, os, re, sys
STATE = os.environ['MOCK_STATE']
CALLS = os.environ['MOCK_CALLS']
CHANNEL_TAG = 'kas-web-channel-experimental'
BETA_TAG = os.environ['MOCK_BETA_TAG']
HIJACKED_LATEST = 'v0.0.0-hijacked'
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


def download_base(tag):
    if tag == CHANNEL_TAG:
        return os.environ['MOCK_DL_BASE']
    return 'https://github.com/saymer-alt/keenetic-auto-setup'


def asset_obj(name, data, tag, untagged=None):
    return {'name': name, 'size': len(data), 'state': 'uploaded',
            'digest': 'sha256:' + hashlib.sha256(data).hexdigest(),
            'browser_download_url': '%s/releases/download/%s/%s'
                % (download_base(tag), untagged or tag, name),
            'bytes_b64': base64.b64encode(data).decode()}


def public_release(release):
    return dict(release, assets=[{k: v for k, v in asset.items() if k != 'bytes_b64'}
                                 for asset in release['assets'].values()])


def apply_jq(obj, program):
    program = program.strip()
    prefix = '.[] | select(.tag_name=="'
    if program.startswith(prefix) and program.endswith('")'):
        tag = program[len(prefix):-2]
        matches = [r for r in obj if r['tag_name'] == tag]
        if not matches:
            sys.exit(1)
        return matches[0]
    for part in [p for p in program.strip('.').split('.') if p]:
        mm = re.fullmatch(r'(\w+)\[(\d+)\]', part)
        obj = obj[mm.group(1)][int(mm.group(2))] if mm else obj[part]
    return obj


def api(path, jq=None):
    record('api:' + path)
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
    elif re.match(r'repos/[^/]+/[^/]+/releases/latest$', path):
        obj = {'tag_name': state['latest']}
    if obj is None:
        sys.stderr.write('mock gh: HTTP 404 ' + path + '\n')
        sys.exit(1)
    if jq:
        obj = apply_jq(obj, jq)
    print(obj if isinstance(obj, str) else json.dumps(obj))


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
        state['tags'].setdefault(tag, state['releases'][tag]['target_commitish'])
        save(state)
        return
    if args[:2] == ['release', 'upload']:
        tag = args[2]
        # Parse like the real gh: file operands stop at the first flag, and
        # --filename takes a value that must never be treated as a file.
        files, override = [], None
        rest, i = args[3:], 0
        while i < len(rest):
            arg = rest[i]
            if arg == '--filename' and i + 1 < len(rest):
                override = rest[i + 1]
                i += 2
                continue
            if arg.startswith('--'):
                i += 1
                continue
            files.append(arg)
            i += 1
        record('release_upload:' + tag)
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
            name = override if (override and len(files) == 1) else os.path.basename(filename)
            untagged = 'untagged-' + tag if release['draft'] else None
            release['assets'][name] = asset_obj(name, data, tag, untagged)
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
            for name, asset in list(release['assets'].items()):
                release['assets'][name] = asset_obj(
                    name, base64.b64decode(asset['bytes_b64']), tag)
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
        self.root = pathlib.Path(tempfile.mkdtemp(prefix='kas-b4pub-dryrun-'))
        self.ws = self.root / 'ws'
        self.bin = self.root / 'bin'
        self.fixture_root = self.root / 'fixtures'
        for d in (self.ws, self.bin):
            d.mkdir()
        (self.ws / 'runner-temp').mkdir()
        self.state_path = self.root / 'mock-state.json'
        self.calls_path = self.root / 'mock-calls.json'
        gh = self.bin / 'gh'
        gh.write_text(GH_MOCK, encoding='utf-8', newline='\n')
        gh.chmod(0o755)
        self.pages = PagesState()
        self.server = make_pages_server(self.pages, self.state_path)
        self.port = self.server.server_address[1]
        self.pages_base = 'http://127.0.0.1:%d%s' % (self.port, PAGES_ROOT)

    def cleanup(self):
        self.server.shutdown()
        shutil.rmtree(self.root, ignore_errors=True)

    def reset_state(self, include_beta4=False):
        shutil.rmtree(self.ws / 'build', ignore_errors=True)
        (self.ws / 'runner-temp').mkdir(parents=True, exist_ok=True)
        build_artifacts(self.fixture_root)
        artifacts = {}
        for arch in ARCHES:
            d = self.fixture_root / arch
            artifacts['%s-%s-%s' % (PREFIX, arch, SOURCE_SHA)] = {
                f.name: base64.b64encode(f.read_bytes()).decode()
                for f in sorted(d.iterdir())}
        assets = {}
        for arch in ARCHES:
            p = self.fixture_root / arch / ipk_name(arch)
            assets[p.name] = asset_obj(p.name, p.read_bytes(), BETA4_TAG)
        assets['SHA256SUMS'] = asset_obj('SHA256SUMS', release_sums_bytes(self.fixture_root),
                                         BETA4_TAG)
        releases = {
            CHANNEL_TAG: {'tag_name': CHANNEL_TAG, 'draft': False,
                          'prerelease': True, 'target_commitish': PREVIOUS_TAG,
                          'assets': {'panel-update.json': asset_obj(
                              'panel-update.json', prev_index_bytes(), CHANNEL_TAG,
                              base=self.pages_base)}},
        }
        if include_beta4:
            releases[BETA4_TAG] = {'tag_name': BETA4_TAG, 'draft': False,
                                   'prerelease': True, 'target_commitish': SOURCE_SHA,
                                   'assets': assets}
        state = {
            'runs': {RUN_ID: {'head_sha': SOURCE_SHA, 'conclusion': 'success'}},
            'tags': {BETA4_TAG: SOURCE_SHA},
            'latest': CORE_LATEST,
            'artifacts': artifacts,
            'releases': releases,
        }
        self.state_path.write_text(json.dumps(state), encoding='utf-8')
        self.calls_path.write_text('[]', encoding='utf-8')

    def state(self):
        return json.loads(self.state_path.read_text(encoding='utf-8'))

    def env(self):
        environ = dict(os.environ)
        environ.update({
            'PATH': str(self.bin) + os.pathsep + environ.get('PATH', ''),
            'GH_TOKEN': 'dryrun', 'GH_REPO': 'saymer-alt/keenetic-auto-setup',
            'SOURCE_SHA': SOURCE_SHA, 'VERIFIED_RUN': RUN_ID,
            'BETA_TAG': BETA4_TAG, 'PREVIOUS_TAG': PREVIOUS_TAG,
            'CHANNEL_TAG': CHANNEL_TAG, 'BETA_VERSION': BETA4_VERSION,
            'ARTIFACT_PREFIX': PREFIX,
            'PAGES_BASE': self.pages_base,
            'RUNNER_TEMP': 'runner-temp',
            'GITHUB_ENV': str(self.ws / 'github-env'),
            'NO_PROXY': '127.0.0.1,localhost', 'no_proxy': '127.0.0.1,localhost',
            'MOCK_STATE': str(self.state_path), 'MOCK_CALLS': str(self.calls_path),
            'MOCK_BETA_TAG': BETA4_TAG, 'MOCK_DL_BASE': self.pages_base,
        })
        return environ


def run_steps(sandbox, blocks, fail=None):
    shutil.rmtree(sandbox.ws / 'build', ignore_errors=True)
    results = []
    for name, uses, run in blocks:
        if uses:
            if uses.startswith('actions/checkout'):
                packaging = sandbox.ws / 'web/control-center/packaging'
                packaging.mkdir(parents=True, exist_ok=True)
                shutil.copy(REPO / 'web/control-center/packaging/update-manifest.py',
                            packaging / 'update-manifest.py')
            results.append((name, 0, ''))
            continue
        environ = sandbox.env()
        if fail:
            environ['MOCK_FAIL'] = json.dumps(fail if isinstance(fail, list) else [fail])
        else:
            environ.pop('MOCK_FAIL', None)
        completed = subprocess.run([BASH, '-e'], input=run.encode('utf-8'),
                                   cwd=sandbox.ws, env=environ, capture_output=True)
        results.append((name, completed.returncode,
                        (completed.stdout + completed.stderr).decode('utf-8', 'replace')))
        if completed.returncode != 0:
            break
    return results


def last_result(results):
    return results[-1][1], results[-1][2]


class Checker:
    def __init__(self, label):
        self.label = label

    def __call__(self, cond, msg):
        if not cond:
            failures.append('%s: %s' % (self.label, msg))


def legacy_asset(sandbox):
    return sandbox.state()['releases'][CHANNEL_TAG]['assets']['panel-update.json']


def legacy_index(sandbox):
    return json.loads(base64.b64decode(legacy_asset(sandbox)['bytes_b64']))


def legacy_bytes(sandbox):
    return base64.b64decode(legacy_asset(sandbox)['bytes_b64'])


def pages_serving(sandbox, tag, index_bytes):
    sandbox.pages.set('/updates/channels.json', 200, json.dumps({
        'schema': 1, 'channels': {
            'experimental': {'published': True, 'tag': tag},
            'stable': {'published': False, 'tag': ''}}}).encode())
    sandbox.pages.set('/updates/experimental/panel-update.json', 200, index_bytes)


def pages_beta4_serving(sandbox):
    pages_serving(sandbox, BETA4_TAG, expected_index_bytes(sandbox.fixture_root))


def pages_beta3_serving(sandbox):
    pages_serving(sandbox, PREVIOUS_TAG, prev_index_bytes())


# --- Stage A (release-only) scenarios ---------------------------------------


def scenario_release_happy(sandbox, release_blocks, switch_blocks, fail):
    sandbox.reset_state()
    code, output = last_result(run_steps(sandbox, release_blocks, None))
    check = Checker('release-only happy')
    check(code == 0, 'workflow failed: %s' % output[-700:])
    if not code:
        return
    beta = sandbox.state()['releases'][BETA4_TAG]
    check(beta['draft'] is False and beta['prerelease'] is True, 'published as prerelease')
    check(beta['target_commitish'] == SOURCE_SHA, 'target commit')
    check(len(beta['assets']) == 5, '5 assets')
    check(legacy_index(sandbox)['tag'] == PREVIOUS_TAG, 'legacy channel tag unchanged')
    check(sandbox.pages.get('/updates/channels.json') is None,
          'Pages must not be touched by Stage A')
    check(sandbox.state()['latest'] == CORE_LATEST, 'Latest unchanged')


def scenario_release_partial_retry(sandbox, release_blocks, switch_blocks, fail):
    sandbox.reset_state()
    code, _ = last_result(run_steps(sandbox, release_blocks,
                                    fail={'phase': 'asset_upload_file', 'nth': 2}))
    check = Checker('release partial upload then retry')
    check(code != 0, 'workflow must fail on partial upload')
    beta = sandbox.state()['releases'][BETA4_TAG]
    check(beta['draft'] is True, 'release stays an invisible draft')
    check(len(beta['assets']) < 5, 'only part of the assets uploaded')
    check(legacy_index(sandbox)['tag'] == PREVIOUS_TAG, 'legacy untouched on failure')
    code, output = last_result(run_steps(sandbox, release_blocks, None))
    check(code == 0, 'retry must succeed: %s' % output[-500:])
    if code == 0:
        beta = sandbox.state()['releases'][BETA4_TAG]
        check(beta['draft'] is False and len(beta['assets']) == 5,
              'retry publishes the complete release')


def scenario_release_corrupt(sandbox, release_blocks, switch_blocks, fail):
    sandbox.reset_state()
    state = sandbox.state()
    name = '%s-aarch64-3.10-%s' % (PREFIX, SOURCE_SHA)
    manifest = json.loads(base64.b64decode(state['artifacts'][name]['manifest-canonical.json']))
    manifest['packages'][0]['sha256'] = 'f' * 64
    state['artifacts'][name]['manifest-canonical.json'] = base64.b64encode(
        json.dumps(manifest).encode()).decode()
    sandbox.state_path.write_text(json.dumps(state), encoding='utf-8')
    code, output = last_result(run_steps(sandbox, release_blocks, None))
    check = Checker('release corrupt artifact refused')
    check(code != 0, 'workflow must fail on candidate/manifest SHA256 mismatch: %s'
          % output[-400:])
    check(BETA4_TAG not in sandbox.state()['releases'],
          'a failed hash gate must not publish the release')


def scenario_release_latest_hijacked(sandbox, release_blocks, switch_blocks, fail):
    sandbox.reset_state()
    code, _ = last_result(run_steps(sandbox, release_blocks,
                                    fail=[{'phase': 'change_latest'}]))
    check = Checker('release Latest hijacked mid-upload')
    check(code != 0, 'workflow must fail when Latest changes externally')
    check(sandbox.state()['latest'] == HIJACKED_LATEST,
          'workflow must never rewrite Latest itself')
    beta = sandbox.state()['releases'][BETA4_TAG]
    check(beta['draft'] is False, 'published release stays for inspection')
    check(legacy_index(sandbox)['tag'] == PREVIOUS_TAG, 'legacy channel untouched')


def scenario_release_idempotent(sandbox, release_blocks, switch_blocks, fail):
    sandbox.reset_state()
    run_steps(sandbox, release_blocks, None)
    first = sandbox.state()['releases'][BETA4_TAG]['assets']
    code, output = last_result(run_steps(sandbox, release_blocks, None))
    check = Checker('release idempotent rerun')
    check(code == 0, 'second identical run must succeed: %s' % output[-500:])
    check(sandbox.state()['releases'][BETA4_TAG]['assets'] == first,
          'release assets byte-stable across identical runs')


# --- Stage C (legacy switch) scenarios --------------------------------------


def scenario_switch_happy(sandbox, release_blocks, switch_blocks, fail):
    sandbox.reset_state(include_beta4=True)
    pages_beta4_serving(sandbox)
    code, output = last_result(run_steps(sandbox, switch_blocks, None))
    check = Checker('legacy switch happy')
    check(code == 0, 'switch failed: %s' % output[-700:])
    if code == 0:
        check(legacy_index(sandbox)['tag'] == BETA4_TAG, 'legacy index tag is beta.4')
        check(sha(legacy_bytes(sandbox)) == sha(expected_index_bytes(sandbox.fixture_root)),
              'legacy index bytes match the Pages beta.4 index')
        check(sandbox.state()['latest'] == CORE_LATEST, 'Latest unchanged')


def scenario_switch_pages_still_beta3(sandbox, release_blocks, switch_blocks, fail):
    sandbox.reset_state(include_beta4=True)
    pages_beta3_serving(sandbox)
    code, _ = last_result(run_steps(sandbox, switch_blocks, None))
    check = Checker('legacy switch refused while Pages serves beta.3')
    check(code != 0, 'workflow must refuse when Pages does not serve beta.4')
    check(legacy_index(sandbox)['tag'] == PREVIOUS_TAG, 'legacy index must stay on beta.3')


def scenario_switch_pages_missing(sandbox, release_blocks, switch_blocks, fail):
    sandbox.reset_state(include_beta4=True)
    code, _ = last_result(run_steps(sandbox, switch_blocks, None))
    check = Checker('legacy switch refused while Pages is unreachable')
    check(code != 0, 'workflow must fail closed when Pages cannot be verified')
    check(legacy_index(sandbox)['tag'] == PREVIOUS_TAG, 'legacy index must stay on beta.3')


def scenario_switch_pages_mismatch(sandbox, release_blocks, switch_blocks, fail):
    sandbox.reset_state(include_beta4=True)
    # Registry declares beta.4 while the served index still carries beta.3
    # bytes: an inconsistent pair must be refused, not copied to legacy.
    pages_serving(sandbox, BETA4_TAG, prev_index_bytes())
    code, _ = last_result(run_steps(sandbox, switch_blocks, None))
    check = Checker('Pages registry/index mismatch refused')
    check(code != 0, 'workflow must refuse on Pages registry/index mismatch')
    check(legacy_index(sandbox)['tag'] == PREVIOUS_TAG, 'legacy index must stay on beta.3')


def scenario_switch_release_tampered(sandbox, release_blocks, switch_blocks, fail):
    sandbox.reset_state(include_beta4=True)
    pages_beta4_serving(sandbox)
    # Stage A published, then one release IPK asset was replaced with
    # different bytes (same name): Stage C must abort and never reach the
    # legacy channel, even though Pages still serves a valid beta.4 index.
    state = sandbox.state()
    rel = state['releases'][BETA4_TAG]
    name = ipk_name('aarch64-3.10')
    old = base64.b64decode(rel['assets'][name]['bytes_b64'])
    rel['assets'][name] = asset_obj(name, old[:-1] + bytes([old[-1] ^ 0xFF]), BETA4_TAG)
    sandbox.state_path.write_text(json.dumps(state), encoding='utf-8')
    code, _ = last_result(run_steps(sandbox, switch_blocks, None))
    check = Checker('tampered beta.4 release asset refused')
    check(code != 0, 'workflow must fail when a published release asset drifted')
    check(legacy_index(sandbox)['tag'] == PREVIOUS_TAG,
          'legacy index must stay on beta.3 after a tampered-release refusal')


def scenario_switch_legacy_unknown(sandbox, release_blocks, switch_blocks, fail):
    sandbox.reset_state(include_beta4=True)
    pages_beta4_serving(sandbox)
    unknown = json.dumps({'schema': 1, 'channel': 'experimental',
                          'tag': 'v0.9.9', 'packages': []}).encode()
    state = sandbox.state()
    state['releases'][CHANNEL_TAG]['assets']['panel-update.json'] = asset_obj(
        'panel-update.json', unknown, CHANNEL_TAG, base=sandbox.pages_base)
    sandbox.state_path.write_text(json.dumps(state), encoding='utf-8')
    code, _ = last_result(run_steps(sandbox, switch_blocks, None))
    check = Checker('legacy unknown state refused')
    check(code != 0, 'workflow must refuse an unknown legacy state')
    check(legacy_index(sandbox)['tag'] == 'v0.9.9', 'unknown legacy state must stay untouched')


def scenario_switch_failure_restores(sandbox, release_blocks, switch_blocks, fail):
    sandbox.reset_state(include_beta4=True)
    pages_beta4_serving(sandbox)
    prev, prev_digest = legacy_bytes(sandbox), sha(legacy_bytes(sandbox))
    code, _ = last_result(run_steps(sandbox, switch_blocks,
                                    fail={'phase': 'channel_upload', 'nth': 1}))
    check = Checker('switch failure restores beta.3')
    check(code != 0, 'workflow must fail on the injected channel upload failure')
    check(legacy_bytes(sandbox) == prev and sha(legacy_bytes(sandbox)) == prev_digest,
          'legacy index restored to the beta.3 bytes')


def scenario_switch_latest_changed(sandbox, release_blocks, switch_blocks, fail):
    sandbox.reset_state(include_beta4=True)
    pages_beta4_serving(sandbox)
    code, _ = last_result(run_steps(sandbox, switch_blocks,
                                    fail=[{'phase': 'change_latest'}]))
    check = Checker('Latest changed during switch')
    check(code != 0, 'workflow must fail when Latest changes')
    check(sha(legacy_bytes(sandbox)) == sha(prev_index_bytes()),
          'legacy index restored to beta.3 bytes')
    check(sandbox.state()['latest'] == HIJACKED_LATEST,
          'workflow must never rewrite Latest itself')


def scenario_switch_idempotent(sandbox, release_blocks, switch_blocks, fail):
    sandbox.reset_state(include_beta4=True)
    pages_beta4_serving(sandbox)
    run_steps(sandbox, switch_blocks, None)
    first = legacy_bytes(sandbox)
    code, output = last_result(run_steps(sandbox, switch_blocks, None))
    check = Checker('switch idempotent rerun')
    check(code == 0, 'second identical run must succeed: %s' % output[-500:])
    check(legacy_bytes(sandbox) == first, 'legacy index byte-stable across identical runs')
    check(sandbox.state()['latest'] == CORE_LATEST, 'Latest unchanged')


SCENARIOS = [
    ('release-only happy: channels untouched', 'release_happy', None),
    ('release partial upload then retry', 'release_partial',
     {'phase': 'asset_upload_file', 'nth': 2}),
    ('release corrupt artifact refused', 'release_corrupt', None),
    ('release Latest hijacked: refuses, channels untouched', 'release_latest_hijack',
     [{'phase': 'change_latest'}]),
    ('release idempotent rerun', 'release_idem', None),
    ('legacy switch happy (Pages serves beta.4)', 'switch_happy', None),
    ('legacy switch refused while Pages serves beta.3', 'switch_beta3', None),
    ('legacy switch refused while Pages unreachable', 'switch_pages_missing', None),
    ('Pages registry/index mismatch refused', 'switch_mismatch', None),
    ('tampered beta.4 release asset refused', 'switch_tampered', None),
    ('legacy unknown state refused', 'switch_unknown', None),
    ('legacy switch failure restores beta.3', 'switch_restore',
     {'phase': 'channel_upload', 'nth': 1}),
    ('Latest changed during switch restores legacy', 'switch_latest',
     [{'phase': 'change_latest'}]),
    ('legacy switch idempotent rerun', 'switch_idem', None),
]

RELEASE_FNS = {
    'release_happy': scenario_release_happy,
    'release_partial': scenario_release_partial_retry,
    'release_corrupt': scenario_release_corrupt,
    'release_latest_hijack': scenario_release_latest_hijacked,
    'release_idem': scenario_release_idempotent,
}
SWITCH_FNS = {
    'switch_happy': scenario_switch_happy,
    'switch_beta3': scenario_switch_pages_still_beta3,
    'switch_pages_missing': scenario_switch_pages_missing,
    'switch_mismatch': scenario_switch_pages_mismatch,
    'switch_tampered': scenario_switch_release_tampered,
    'switch_unknown': scenario_switch_legacy_unknown,
    'switch_restore': scenario_switch_failure_restores,
    'switch_latest': scenario_switch_latest_changed,
    'switch_idem': scenario_switch_idempotent,
}


def main():
    print('== syntax gate: bash -n and python heredocs (both workflows) ==')
    before = len(failures)
    syntax_gate(failures)
    print('%-58s %s' % ('both workflow files', 'PASS' if len(failures) == before else 'FAIL'))

    release_blocks = load_blocks(RELEASE_WF)
    switch_blocks = load_blocks(SWITCH_WF)
    print('== scenarios (real steps, mock gh + mock Pages) ==')
    for label, key, fail in SCENARIOS:
        before = len(failures)
        sandbox = Sandbox()
        try:
            (RELEASE_FNS.get(key) or SWITCH_FNS[key])(
                sandbox, release_blocks, switch_blocks, fail)
        except Exception as error:
            failures.append('%s: harness error: %r' % (label, error))
        finally:
            sandbox.cleanup()
        print('%-58s %s' % (label[:58], 'PASS' if len(failures) == before else 'FAIL'))

    for failure in failures:
        print('FAIL: %s' % failure)
    print('%d scenario(s) + syntax gate, %d assertion(s) failed'
          % (len(SCENARIOS), len(failures)))
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
