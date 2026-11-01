#!/usr/bin/env python3
"""Offline dry-run of the KAS WEB Pages deploy workflow (.github/workflows/updates-pages-deploy.yml).

Every `run:` block is executed for real (bash + python3 + curl) against:
  - a mock `gh` serving fixture run/tag/release metadata and CI artifacts;
  - a mock Pages HTTP server with per-path state (missing/stale/corrupt/5xx).

The three deployment actions (configure-pages / upload-pages-artifact /
deploy-pages) are simulated: the last one copies the workspace `site/` tree
into the mock Pages store, exactly mirroring their real semantics.

Scenarios cover the independent review findings: first bootstrap, beta
roll-forward preserving published Stable, bootstrap with Stable unpublished,
missing registry without bootstrap (fail closed), unreachable registry,
stale HTTP-200 CDN bytes retried on content, corrupted candidate metadata,
failed final gate, idempotent re-publication. Also a syntax gate: every
`run:` block passes `bash -n` and every Python heredoc parses (ast).
"""
import ast
import base64
import hashlib
import http.server
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
import threading
import functools

import yaml

REPO = pathlib.Path(__file__).resolve().parent.parent
WORKFLOW = REPO / '.github/workflows/updates-pages-deploy.yml'

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
_pub = __import__('publish-transaction-dryrun')  # reuses find_bash, build_ipk

SOURCE_SHA = 'b' * 40
RUN_ID = '424242'
CHANNEL = 'experimental'
RELEASE_TAG = 'v0.1.0-beta.4'
VERSION = '0.1.0~beta.4-1'
PREFIX = 'kas-web-beta4'
ARCHES = ['aarch64-3.10', 'armv7-3.2', 'mipsel-3.4', 'mips-3.4']
CORE_LATEST = 'v1.8.5'


def load_blocks():
    d = yaml.safe_load(WORKFLOW.read_text(encoding='utf-8'))
    return [(s.get('name', s.get('uses', '?')), s.get('uses'), s.get('run'), s.get('env', {}))
            for s in d['jobs']['deploy']['steps']]


def syntax_gate(failures):
    """Every run block must pass bash -n; every Python heredoc must parse."""
    bash = _pub.find_bash()
    blocks = load_blocks()
    for name, _, run, _ in blocks:
        if run is None:
            continue
        r = subprocess.run([bash, '-n'], input=run.encode('utf-8'), capture_output=True)
        if r.returncode != 0:
            failures.append('bash -n failed for %s: %s' % (name, r.stderr.decode()[-400:]))
        for body in re.findall(r"<<'PY'\n(.*?)\nPY\n", run, re.S):
            try:
                ast.parse(body)
            except SyntaxError as error:
                failures.append('python heredoc in %s does not parse: %s' % (name, error))


def build_artifacts(root):
    """Fixture CI artifacts identical in shape to the candidate workflow output."""
    store = {}
    for arch in ARCHES:
        d = root / arch
        d.mkdir(parents=True, exist_ok=True)
        name = 'kas-control-center_%s_%s.ipk' % (VERSION, arch)
        payload = _pub.build_ipk(arch, VERSION, SOURCE_SHA)
        (d / name).write_bytes(payload)
        (d / 'SHA256SUMS').write_bytes(
            hashlib.sha256(payload).hexdigest().encode() + b'  ./' + name.encode() + b'\n')
        manifest = subprocess.run(
            [sys.executable, str(REPO / 'web/control-center/packaging/update-manifest.py'),
             '--channel', CHANNEL, '--tag', RELEASE_TAG, str(d / name)],
            capture_output=True, check=True)
        (d / 'manifest-canonical.json').write_bytes(manifest.stdout)
        store['%s-%s-%s' % (PREFIX, arch, SOURCE_SHA)] = {
            f.name: base64.b64encode(f.read_bytes()).decode() for f in sorted(d.iterdir())}
    return store


class PagesState:
    """Mock Pages: path -> (status_code, bytes), plus optional read counters
    for simulating stale CDN bytes and transient failures."""

    def __init__(self):
        self.store = {}
        self.lock = threading.Lock()
        # Per-path scripted behaviors: {path, times, action}. The action MUST
        # return a concrete (status_code, bytes) pair — the point is to model
        # real HTTP answers (stale 200s, 503s), not broken connections.
        self.script = []
        self.reads = {}  # path -> {status_code: count}

    def serve(self, path):
        with self.lock:
            scripted = any(item['path'] == path and item['times'] > 0
                           for item in self.script)
            for item in self.script:
                if item['path'] == path and item['times'] > 0:
                    item['times'] -= 1
                    code, body = item['action']()
                    self.reads.setdefault(path, {}).setdefault(code, 0)
                    self.reads[path][code] += 1
                    if item['times'] == 0 and getattr(self, 'post_read', None):
                        self.post_read()  # script exhausted: restore real bytes
                    return code, body
            if scripted and getattr(self, 'post_read', None):
                self.post_read()
            if path not in self.store:
                self.reads.setdefault(path, {}).setdefault(404, 0)
                self.reads[path][404] += 1
                return 404, b'not found'
            code, body = self.store[path]
            self.reads.setdefault(path, {}).setdefault(code, 0)
            self.reads[path][code] += 1
            return code, body

    def publish_site(self, site_dir):
        with self.lock:
            self.store = {}
            for f in pathlib.Path(site_dir).rglob('*'):
                if f.is_file():
                    key = '/keenetic-auto-setup/' + f.relative_to(site_dir).as_posix()
                    self.store[key] = 200, f.read_bytes()
            self.script = []


def make_pages_server(state):
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            code, body = state.serve(self.path)
            self.send_response(code)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Content-Type',
                             'application/json' if self.path.endswith('.json') else 'application/octet-stream')
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.handle_error = lambda *args: None  # stale-read crashes are the scenario
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


GH_MOCK = r"""#!/usr/bin/env python3
import base64, json, os, sys
STATE = os.environ['MOCK_STATE']
args = sys.argv[1:]
while args and args[0] == '--repo':
    del args[0:2]
state = json.load(open(STATE))
if args[0] == 'api':
    path = args[1]
    jq = args[args.index('--jq') + 1] if '--jq' in args else None
    m = path.rsplit('/', 1)[-1]
    if '/actions/runs/' in path:
        run = state['runs'][m]
        if jq == '.head_sha':
            print(run['head_sha'])
        elif jq == '.conclusion':
            print(run['conclusion'])
        else:
            print(json.dumps({'head_sha': run['head_sha'], 'conclusion': run['conclusion']}))
    elif '/git/ref/tags/' in path:
        if jq == '.object.sha':
            print(state['tags'][m])
        else:
            print(json.dumps({'object': {'sha': state['tags'][m]}}))
    elif '/releases/tags/' in path:
        print(json.dumps(state['releases'][m]))
    else:
        sys.exit(2)
elif args[:2] == ['run', 'download']:
    name = args[args.index('--name') + 1]
    directory = args[args.index('--dir') + 1]
    os.makedirs(directory, exist_ok=True)
    for filename, b64 in state['artifacts'][name].items():
        open(os.path.join(directory, filename), 'wb').write(base64.b64decode(b64))
else:
    sys.exit(2)
"""


class Sandbox:
    def __init__(self, bootstrap=False, published_stable=False):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix='kas-pages-dryrun-'))
        self.ws = self.root / 'ws'
        self.tmp = self.root / 'runner-temp'
        self.bin = self.root / 'bin'
        self.fixtures = self.root / 'fixtures'
        for d in (self.ws, self.tmp, self.bin, self.fixtures):
            d.mkdir()
        self.state_path = self.root / 'mock-state.json'
        self.gh_path = self.bin / 'gh'
        self.gh_path.write_text(GH_MOCK, encoding='utf-8', newline='\n')
        self.gh_path.chmod(0o755)
        self.pages = PagesState()
        self.httpd = make_pages_server(self.pages)
        self.port = self.httpd.server_address[1]
        if published_stable:
            self._seed_published_stable()
        self.bootstrap = bootstrap

    def _seed_published_stable(self):
        # A previously published stable channel on the live site.
        stable_index = json.dumps({'schema': 1, 'channel': 'stable',
                                   'tag': 'kas-web-v0.0.1',
                                   'packages': [{'name': 'kas-control-center_0.0.1_stable_%s.ipk' % a,
                                                 'architecture': a, 'sha256': '0' * 64,
                                                 'size': 1, 'source_sha': '0' * 40}
                                                for a in ARCHES]}).encode()
        registry = json.dumps({'schema': 1, 'channels': {
            'experimental': {'published': False, 'tag': ''},
            'stable': {'published': True, 'tag': 'kas-web-v0.0.1'}}}).encode()
        self.pages.store['/keenetic-auto-setup/updates/stable/panel-update.json'] = 200, stable_index
        self.pages.store['/keenetic-auto-setup/updates/channels.json'] = 200, registry

    def state(self):
        return json.loads(self.state_path.read_text(encoding='utf-8'))

    def env(self):
        environ = dict(os.environ)
        environ.update({
            'PATH': str(self.bin) + os.pathsep + environ.get('PATH', ''),
            'GH_TOKEN': 'dryrun', 'GH_REPO': 'saymer-alt/keenetic-auto-setup',
            'PAGES_BASE': 'http://127.0.0.1:%d/keenetic-auto-setup' % self.port,
            'CHANNEL': CHANNEL, 'RELEASE_TAG': RELEASE_TAG,
            'VERIFIED_RUN': RUN_ID, 'EXPECTED_SOURCE_SHA': SOURCE_SHA,
            'ARTIFACT_PREFIX': PREFIX, 'BOOTSTRAP': 'true' if self.bootstrap else 'false',
            'RUNNER_TEMP': str(self.tmp),
            'MOCK_STATE': str(self.state_path),
        })
        return environ

    def reset_state(self):
        artifacts = build_artifacts(self.fixtures / 'artifacts')
        release_assets = [
            {'name': 'kas-control-center_0.1.0.beta.4-1_%s.ipk' % a, 'state': 'uploaded'}
            for a in ARCHES] + [{'name': 'SHA256SUMS', 'state': 'uploaded'}]
        self.state_path.write_text(json.dumps({
            'runs': {RUN_ID: {'head_sha': SOURCE_SHA, 'conclusion': 'success'}},
            'tags': {RELEASE_TAG: SOURCE_SHA},
            'releases': {RELEASE_TAG: {'tag_name': RELEASE_TAG, 'draft': False,
                                       'target_commitish': SOURCE_SHA,
                                       'prerelease': True, 'assets': release_assets}},
            'artifacts': artifacts,
        }), encoding='utf-8')


def run_workflow(sandbox, blocks, stop_at_gate=False):
    """Execute the workflow steps; returns (ok, last_output)."""
    sandbox.reset_state()
    shutil.rmtree(sandbox.ws / 'build', ignore_errors=True)
    shutil.rmtree(sandbox.ws / 'site', ignore_errors=True)
    last = ''
    for name, uses, run, stepenv in blocks:
        if uses:
            if uses.startswith('actions/checkout'):
                packaging = sandbox.ws / 'web/control-center/packaging'
                packaging.mkdir(parents=True, exist_ok=True)
                shutil.copy(REPO / 'web/control-center/packaging/update-manifest.py',
                            packaging / 'update-manifest.py')
            elif uses.startswith('actions/deploy-pages'):
                sandbox.pages.publish_site(sandbox.ws / 'site')
            continue
        environ = sandbox.env()
        for key, value in (stepenv or {}).items():
            match = re.fullmatch(r'\$\{\{ inputs\.(\w+) \}\}', value)
            environ[key] = ('true' if sandbox.bootstrap else 'false') if match and match.group(1) == 'bootstrap' \
                else sandbox.env()[match.group(1).upper()] if match else environ.get(key, '')
        completed = subprocess.run([_pub.BASH, '-e'], input=run.encode('utf-8'),
                                   cwd=sandbox.ws, env=environ, capture_output=True)
        last = (completed.stdout + completed.stderr).decode('utf-8', 'replace')
        if completed.returncode != 0:
            return False, name + ': ' + last
        if stop_at_gate and name.startswith('Verify the local site tree'):
            return True, last
    return True, last


def public_state(sandbox):
    out = {}
    for rel in ('/keenetic-auto-setup/updates/channels.json', '/keenetic-auto-setup/updates/experimental/panel-update.json',
                '/keenetic-auto-setup/updates/stable/panel-update.json'):
        code, body = sandbox.pages.serve(rel)
        out[rel] = None if code != 200 else json.loads(body)
    return out


class Checker:
    def __init__(self, failures, label):
        self.failures, self.label = failures, label

    def __call__(self, cond, msg):
        if not cond:
            self.failures.append('%s: %s' % (self.label, msg))


def expect_index(check, state, tag=RELEASE_TAG):
    idx = state['/keenetic-auto-setup/updates/experimental/panel-update.json']
    check(idx is not None, 'experimental index missing')
    if idx:
        check(idx['tag'] == tag, 'index tag %r' % idx.get('tag'))
        check(len(idx['packages']) == 4, 'index packages')


def scenario_bootstrap_fresh(sandbox, blocks, failures):
    code, output = run_workflow(sandbox, blocks)
    check = Checker(failures, 'bootstrap fresh')
    check(code, 'workflow failed: %s' % output[-700:])
    if not code:
        return
    state = public_state(sandbox)
    check(state['/keenetic-auto-setup/updates/channels.json']['channels']['experimental'] ==
          {'published': True, 'tag': RELEASE_TAG}, 'registry experimental entry')
    check(state['/keenetic-auto-setup/updates/channels.json']['channels']['stable'] ==
          {'published': False, 'tag': ''}, 'registry stable stays unpublished')
    expect_index(check, state)


def scenario_roll_forward_preserves_stable(sandbox, blocks, failures):
    sandbox._seed_published_stable()
    code, output = run_workflow(sandbox, blocks, stop_at_gate=True)
    check = Checker(failures, 'roll-forward preserves stable')
    check(code, 'pre-deploy gates failed: %s' % output[-700:])
    if not code:
        return
    reg = json.loads((sandbox.ws / 'site/updates/channels.json').read_text())
    check(reg['channels']['stable'] == {'published': True, 'tag': 'kas-web-v0.0.1'},
          'stable entry must stay verbatim')
    carried = json.loads((sandbox.ws / 'site/updates/stable/panel-update.json').read_text())
    check(carried['tag'] == 'kas-web-v0.0.1', 'stable index carried byte-for-byte')


def scenario_missing_registry_fails_closed(sandbox, blocks, failures):
    code, output = run_workflow(sandbox, blocks)
    check = Checker(failures, 'missing registry fails closed')
    check(not code, 'workflow must fail without bootstrap when the registry is missing')
    check('refusing to overwrite an unknown site state' in output,
          'explicit fail-closed message required')
    check(sandbox.pages.store.get('/keenetic-auto-setup/updates/experimental/panel-update.json') is None,
          'nothing may be published on a failed gate')


def scenario_registry_unreachable_fails_closed(sandbox, blocks, failures):
    """HTTP 503 on the exact registry path: the workflow must classify it as
    unreachable (not as a missing registry) and refuse to continue."""
    sandbox.pages.store['/keenetic-auto-setup/updates/channels.json'] = 503, b'busy'
    code, output = run_workflow(sandbox, blocks)
    check = Checker(failures, 'unreachable registry (503) fails closed')
    check(not code, 'workflow must fail on an unreadable registry')
    check('live registry is unreachable' in output,
          'must classify 503 as unreachable, got: %s' % output[-400:])
    check(sandbox.pages.store.get(
        '/keenetic-auto-setup/updates/experimental/panel-update.json') is None,
        'nothing may be published on a failed gate')


def scenario_bootstrap_unreachable_registry_still_fails(sandbox, blocks, failures):
    """bootstrap=true relaxes ONLY a confirmed-empty site (404); a transient
    server error stays a hard failure even in bootstrap mode."""
    sandbox.pages.store['/keenetic-auto-setup/updates/channels.json'] = 503, b'busy'
    code, output = run_workflow(sandbox, blocks)
    check = Checker(failures, 'bootstrap with 503 registry still fails')
    check(not code, 'bootstrap must not proceed over a 503 registry')
    check('live registry is unreachable' in output, 'must report unreachability')


def scenario_bootstrap_existing_registry_aborts(sandbox, blocks, failures):
    """bootstrap=true asserts an empty site; an existing live registry makes
    the assertion false, so the run aborts and must be re-dispatched with
    bootstrap=false."""
    sandbox._seed_published_stable()
    code, output = run_workflow(sandbox, blocks)
    check = Checker(failures, 'bootstrap with existing registry aborts')
    check(not code, 'workflow must abort: bootstrap asserts an empty site')
    check('rerun with bootstrap=false' in output, 'explicit remediation message required')
    check(sandbox.pages.store.get(
        '/keenetic-auto-setup/updates/experimental/panel-update.json') is None,
        'nothing may be published on a failed gate')


def scenario_unpublished_other_channel_503_fails_closed(sandbox, blocks, failures):
    """Registry says the other channel is unpublished, but its absence cannot
    be confirmed because the index path answers 503: the run must fail closed
    instead of treating the error as a confirmed 404. The run publishes
    experimental; the other (stable) channel is declared unpublished with a
    503 on its index path."""
    sandbox.pages.store['/keenetic-auto-setup/updates/channels.json'] = 200, json.dumps({
        'schema': 1, 'channels': {
            'experimental': {'published': True, 'tag': 'v0.1.0-beta.3'},
            'stable': {'published': False, 'tag': ''}}}).encode()
    sandbox.pages.store['/keenetic-auto-setup/updates/stable/panel-update.json'] = 503, b'busy'
    code, output = run_workflow(sandbox, blocks)
    check = Checker(failures, 'unpublished other channel 503 fails closed')
    check(not code, 'workflow must fail closed when absence is not confirmed by 404')
    check('absence could not be confirmed' in output,
          'explicit unverified-state message required, got: %s' % output[-400:])
    check(sandbox.pages.store.get(
        '/keenetic-auto-setup/updates/experimental/panel-update.json') is None,
        'nothing may be published on a failed gate')


def scenario_stale_cdn_retried(sandbox, blocks, failures):
    """After deploy the CDN serves the previous index as real HTTP 200 for
    exactly two reads; the final gate must retry on CONTENT and accept only
    fresh bytes."""
    sandbox._seed_published_stable()
    index_key = '/keenetic-auto-setup/updates/experimental/panel-update.json'
    stale_bytes = json.dumps({'schema': 1, 'channel': 'experimental',
                              'tag': 'v0.1.0-beta.3', 'packages': []}).encode()
    real_publish = sandbox.pages.publish_site

    def publish_with_cdn_delay(site_dir):
        real_publish(site_dir)
        fresh = sandbox.pages.store[index_key]

        def stale_twice():
            return 200, stale_bytes

        def restore_fresh():
            sandbox.pages.store[index_key] = fresh

        sandbox.pages.script = [
            {'path': index_key, 'times': 2, 'action': stale_twice},
            {'path': index_key, 'times': 0, 'action': restore_fresh}]

    sandbox.pages.publish_site = publish_with_cdn_delay
    code, output = run_workflow(sandbox, blocks)
    check = Checker(failures, 'stale CDN retried on bytes')
    check(code, 'bounded retry must defeat stale HTTP-200 bytes: %s' % output[-700:])
    check('not final yet' in output, 'stale attempts must be logged as retries')
    check(output.count('not final yet') == 2,
          'exactly two stale-200 retries expected, got %d' % output.count('not final yet'))
    # Two scripted stale reads must be real HTTP 200s, then fresh 200s.
    reads = sandbox.pages.reads.get(index_key, {})
    check(reads.get(200, 0) >= 3, 'stale and fresh bytes served as HTTP 200, saw %r' % reads)


def scenario_other_channel_tag_mismatch_fails_closed(sandbox, blocks, failures):
    """Registry declares the other channel published with tag T, but the live
    index carries a different tag: an inconsistent pair must not be copied
    into the next site — the run aborts before deployment."""
    sandbox._seed_published_stable()
    state = sandbox.pages.store['/keenetic-auto-setup/updates/channels.json']
    reg = json.loads(state[1])
    reg['channels']['stable']['tag'] = 'kas-web-v0.0.2'  # registry says 0.0.2
    sandbox.pages.store['/keenetic-auto-setup/updates/channels.json'] = 200, json.dumps(reg).encode()
    # live stable index still carries 0.0.1 (served from the seed)
    code, output = run_workflow(sandbox, blocks)
    check = Checker(failures, 'other-channel tag mismatch fails closed')
    check(not code, 'workflow must abort on registry/index tag disagreement')
    check('disagrees with the registry tag' in output,
          'explicit mismatch message required, got: %s' % output[-400:])
    check(sandbox.pages.store.get('/keenetic-auto-setup/updates/experimental/panel-update.json') is None,
          'nothing may be published on a failed gate')


def scenario_corrupt_metadata_fails_before_deploy(sandbox, blocks, failures):
    sandbox.reset_state()
    state = sandbox.state()
    name = '%s-aarch64-3.10-%s' % (PREFIX, SOURCE_SHA)
    manifest = json.loads(base64.b64decode(state['artifacts'][name]['manifest-canonical.json']))
    manifest['packages'][0]['sha256'] = 'f' * 64
    state['artifacts'][name]['manifest-canonical.json'] = base64.b64encode(
        json.dumps(manifest).encode()).decode()
    sandbox.state_path.write_text(json.dumps(state), encoding='utf-8')
    code, output = run_workflow(sandbox, blocks)
    check = Checker(failures, 'corrupt metadata fails pre-deploy')
    check(not code, 'workflow must fail on candidate/manifest mismatch')
    check(sandbox.pages.store.get('/keenetic-auto-setup/updates/experimental/panel-update.json') is None,
          'a failed build gate must never deploy')


def scenario_failed_final_gate(sandbox, blocks, failures):
    sandbox._seed_published_stable()
    real_publish = sandbox.pages.publish_site

    def publish_then_freeze_stale(site_dir):
        real_publish(site_dir)
        sandbox.pages.store['/keenetic-auto-setup/updates/experimental/panel-update.json'] = 200, b'{"stale":true}'

    sandbox.pages.publish_site = publish_then_freeze_stale
    code, output = run_workflow(sandbox, blocks)
    check = Checker(failures, 'failed final gate')
    check(not code, 'workflow must fail when public bytes never match')
    check('never matched the built bytes' in output, 'explicit final-gate message required')


def scenario_idempotent_republication(sandbox, blocks, failures):
    sandbox.bootstrap = True  # first run initializes the empty site
    run_workflow(sandbox, blocks)
    sandbox.bootstrap = False  # second run is a normal roll-forward
    first = public_state(sandbox)
    code, output = run_workflow(sandbox, blocks)
    check = Checker(failures, 'idempotent republication')
    check(code, 'second identical run must succeed: %s' % output[-500:])
    second = public_state(sandbox)
    key = '/keenetic-auto-setup/updates/channels.json'
    check(first[key] == second[key], 'registry byte-stable across identical runs')


SCENARIOS = [
    ('bootstrap on an empty site', lambda: Sandbox(bootstrap=True), 'bootstrap_fresh'),
    ('beta roll-forward preserves published stable', lambda: Sandbox(), 'roll_forward'),
    ('missing registry without bootstrap fails closed', lambda: Sandbox(), 'missing_registry'),
    ('unreachable registry (503) fails closed', lambda: Sandbox(), 'unreachable_registry'),
    ('bootstrap with 503 registry still fails', lambda: Sandbox(bootstrap=True), 'bootstrap_unreachable'),
    ('bootstrap with existing registry aborts', lambda: Sandbox(bootstrap=True), 'bootstrap_existing'),
    ('unpublished other channel 503 fails closed', lambda: Sandbox(), 'unpublished_other_503'),
    ('other-channel tag mismatch fails closed', lambda: Sandbox(), 'other_tag_mismatch'),
    ('stale CDN HTTP-200 bytes retried', lambda: Sandbox(), 'stale_cdn'),
    ('corrupt candidate metadata fails pre-deploy', lambda: Sandbox(), 'corrupt_metadata'),
    ('failed final gate aborts loudly', lambda: Sandbox(), 'final_gate'),
    ('idempotent republication', lambda: Sandbox(), 'republication'),
]

DISPATCH = {
    'bootstrap_fresh': scenario_bootstrap_fresh,
    'roll_forward': scenario_roll_forward_preserves_stable,
    'missing_registry': scenario_missing_registry_fails_closed,
    'unreachable_registry': scenario_registry_unreachable_fails_closed,
    'bootstrap_unreachable': scenario_bootstrap_unreachable_registry_still_fails,
    'bootstrap_existing': scenario_bootstrap_existing_registry_aborts,
    'unpublished_other_503': scenario_unpublished_other_channel_503_fails_closed,
    'other_tag_mismatch': scenario_other_channel_tag_mismatch_fails_closed,
    'stale_cdn': scenario_stale_cdn_retried,
    'corrupt_metadata': scenario_corrupt_metadata_fails_before_deploy,
    'final_gate': scenario_failed_final_gate,
    'republication': scenario_idempotent_republication,
}


def main():
    blocks = load_blocks()
    failures = []
    print('== syntax gate: bash -n and Python heredocs ==')
    before = len(failures)
    syntax_gate(failures)
    print('%-52s %s' % ('all run blocks + python heredocs', 'PASS' if len(failures) == before else 'FAIL'))
    print('== deployment scenarios (offline mock Pages + mock gh) ==')
    for label, make, key in SCENARIOS:
        before = len(failures)
        sandbox = make()
        try:
            DISPATCH[key](sandbox, blocks, failures)
        except Exception as error:
            failures.append('%s: harness error: %r' % (label, error))
        finally:
            sandbox.httpd.shutdown()
            shutil.rmtree(sandbox.root, ignore_errors=True)
        print('%-52s %s' % (label[:52], 'PASS' if len(failures) == before else 'FAIL'))
    for failure in failures:
        print('FAIL: %s' % failure)
    print('%d scenario(s) + syntax gate, %d assertion(s) failed' % (len(SCENARIOS), len(failures)))
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
