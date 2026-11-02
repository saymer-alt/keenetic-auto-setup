#!/bin/sh
# Disposable GitHub aarch64 CI VM only. Full panel self-update service lab:
# old daemon -> explicit Web check/apply -> detached session worker -> real
# Entware opkg install (preinst stops/drains the old daemon) -> explicit init
# start of the new payload -> private runtime receipt -> fresh authenticated
# runtime identity with the exact new version/SHA. Also exercises honest
# failures: space shortage, download failure, tampered index, tampered asset,
# wrong ABI, busy opkg lock, start failure plus explicit recovery, concurrent
# mutation denial and settings/config preservation.
#
# Network fixture: github.com and api.github.com resolve to a local HTTPS
# server whose lab CA is added to the VM trust stores. TLS/CA verification
# stays enabled and no project process is mocked; the worker, opkg, package
# hooks, init script and both daemons run as real processes.
# Disposable host fixture: NOT KeeneticOS firmware acceptance; it requires a
# native aarch64 runner so /proc/<pid>/exe identity checks are real.
set -eu
umask 077
fail() { echo "FAIL: $*" >&2; exit 1; }
[ "${KAS_SERVICE_LAB:-}" = 1 ] && [ "${GITHUB_ACTIONS:-}" = true ] || fail 'requires explicit disposable GitHub CI lab'
[ "$(id -u)" = 0 ] || fail 'run as root on the fresh CI VM'
[ "$(uname -m)" = aarch64 ] || fail 'native self-update fixture requires aarch64 (real /proc/<pid>/exe identity)'
[ -f /etc/os-release ] && grep -q '^ID=ubuntu$' /etc/os-release || fail 'Ubuntu CI VM required'
command -v openssl >/dev/null 2>&1 || fail 'openssl unavailable'
command -v update-ca-certificates >/dev/null 2>&1 || fail 'update-ca-certificates unavailable'
[ "$#" -eq 4 ] || [ "$#" -eq 5 ] || fail 'usage: test_panel_selfupdate_service.sh BINARY_OLD BINARY_NEW ENTWARE_OPKG SOURCE_SHA [BINARY_STABLE]'
OLD_BINARY=$1
NEW_BINARY=$2
OPKG=$3
SOURCE_SHA=$4
STABLE_BINARY=${5:-}
[ -f "$OLD_BINARY" ] && [ -x "$OLD_BINARY" ] || fail 'old panel binary unavailable'
[ -f "$NEW_BINARY" ] && [ -x "$NEW_BINARY" ] || fail 'new panel binary unavailable'
if [ -n "$STABLE_BINARY" ]; then
    [ -f "$STABLE_BINARY" ] && [ -x "$STABLE_BINARY" ] || fail 'stable panel binary unavailable'
fi
[ -f "$OPKG" ] && [ -x "$OPKG" ] || fail 'official opkg unavailable'
printf '%s' "$SOURCE_SHA" | grep -Eq '^[a-f0-9]{40}$' || fail 'source SHA must be 40 hex characters'
REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# All state touched below must be exclusively owned by this test. Parent dirs
# may already exist on the VM; never remove/rewrite their unrelated contents.
for path in /opt/bin/kas-control-center /opt/bin/opkg /opt/etc/init.d/S98kas-control-center \
    /opt/etc/kas-control-center.settings.json /opt/etc/kas-control-center.password \
    /opt/etc/kas-control-center.proxy-origin /opt/etc/kas-control-center.export-names \
    /opt/etc/kas-control-center.mihomo-api-secret /opt/etc/kas-control-center.web.sha256 \
    /opt/etc/kas-control-center-update /opt/etc/mihomo /opt/etc/ssl \
    /opt/share/kas-control-center /opt/lib/opkg /opt/etc/passwd /opt/etc/shadow \
    /opt/tmp/opkg.lock /opt/var/run/kas-control-center.ipk.startup /opt/etc/opkg.conf \
    /usr/local/share/ca-certificates/kas-selfupdate-lab.crt; do
    [ ! -e "$path" ] && [ ! -L "$path" ] || fail "test-owned path already exists: $path"
done
for path in /opt /opt/bin /opt/etc /opt/etc/init.d /opt/share /opt/lib /opt/var /opt/var/run /opt/tmp; do
    [ ! -L "$path" ] || fail "unsafe parent symlink: $path"
done
if ip link show br0 >/dev/null 2>&1; then fail 'br0 already exists'; fi
grep -q 'github\.com' /etc/hosts && fail '/etc/hosts already maps github.com'
LAB=$(mktemp -d /tmp/kas-selfupdate.XXXXXX)
BRIDGE_CREATED=0
cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    if [ -f /opt/etc/init.d/S98kas-control-center ]; then
        if ! sh /opt/etc/init.d/S98kas-control-center stop >/dev/null 2>&1; then
            echo 'FAIL: cleanup could not gracefully stop panel; retaining its files' >&2
            result=1
        fi
    fi
    if [ -f /opt/lib/opkg/status ]; then
        "$OPKG" -f "$LAB/opkg.conf" --tmp-dir "$LAB/opkg-tmp" remove kas-control-center >/dev/null 2>&1 || result=1
    fi
    umount /opt/tmp 2>/dev/null || :
    if [ -f "$LAB/hosts.backup" ]; then cat "$LAB/hosts.backup" > /etc/hosts; fi
    rm -f /usr/local/share/ca-certificates/kas-selfupdate-lab.crt
    update-ca-certificates >/dev/null 2>&1 || result=1
    rm -f /opt/etc/opkg.conf /opt/tmp/opkg.lock /opt/bin/opkg
    rm -rf /opt/var/run/kas-control-center.ipk.startup
    rm -f /opt/etc/kas-control-center.settings.json /opt/etc/passwd /opt/etc/shadow
    rm -rf /opt/etc/kas-control-center-update /opt/etc/mihomo /opt/etc/ssl
    rm -rf /opt/lib/opkg /opt/share/kas-control-center
    rm -rf /opt/tmp/.kas-panel-update-* || result=1
    if [ "$BRIDGE_CREATED" -eq 1 ]; then ip link delete br0 || result=1; fi
    rm -rf "$LAB"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
mkdir -p /opt/bin /opt/etc /opt/etc/init.d /opt/share /opt/lib /opt/var /opt/var/run /opt/tmp "$LAB/opkg-tmp" "$LAB/serve"
# The runner image may ship a world-writable /opt/lib; the panel refuses
# group/world-writable inventory parents by design, so normalize the tree to
# the Entware layout this fixture models.
chmod 755 /opt /opt/bin /opt/etc /opt/etc/init.d /opt/share /opt/lib /opt/var /opt/var/run /opt/tmp
printf 'dest root /\narch all 1\narch aarch64-3.10 10\n' > "$LAB/opkg.conf"
# The worker runs plain `opkg install` without -f; mirror the router feed file.
printf 'dest root /\narch all 1\narch aarch64-3.10 10\n' > /opt/etc/opkg.conf
ip link add br0 type bridge
BRIDGE_CREATED=1
ip address add 192.168.254.1/24 dev br0
ip link set br0 up
# Lab TLS trust: the panel and worker keep standard certificate verification.
openssl req -x509 -newkey rsa:2048 -keyout "$LAB/ca.key" -out "$LAB/ca.crt" -days 2 -nodes   -subj '/CN=KAS Selfupdate Lab CA'   -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' >/dev/null 2>&1
openssl req -newkey rsa:2048 -keyout "$LAB/server.key" -out "$LAB/server.csr" -nodes -subj '/CN=github.com' -addext 'subjectAltName=DNS:github.com,DNS:api.github.com,DNS:saymer-alt.github.io' >/dev/null 2>&1
printf 'subjectAltName=DNS:github.com,DNS:api.github.com,DNS:saymer-alt.github.io\n' > "$LAB/server.ext"
openssl x509 -req -in "$LAB/server.csr" -CA "$LAB/ca.crt" -CAkey "$LAB/ca.key" -CAcreateserial -out "$LAB/server.crt" -days 2 -extfile "$LAB/server.ext" >/dev/null 2>&1
cat "$LAB/ca.crt" > /usr/local/share/ca-certificates/kas-selfupdate-lab.crt
update-ca-certificates >/dev/null 2>&1
CA_HASH=$(openssl x509 -in /usr/local/share/ca-certificates/kas-selfupdate-lab.crt -noout -hash 2>/dev/null)
[ -e "/etc/ssl/certs/$CA_HASH.0" ] || fail 'lab CA missing from the system bundle'
mkdir -p /opt/etc/ssl/certs
cat "$LAB/ca.crt" > /opt/etc/ssl/certs/ca-certificates.crt
cp /etc/hosts "$LAB/hosts.backup"
printf '\n127.0.0.1 github.com\n127.0.0.1 api.github.com\n127.0.0.1 saymer-alt.github.io\n' >> /etc/hosts
install -m 755 "$OPKG" /opt/bin/opkg
python3 - "$REPO" "$LAB" "$SOURCE_SHA" "$OLD_BINARY" "$NEW_BINARY" "$STABLE_BINARY" <<'PY'
import base64
import fcntl
import hashlib
import http.server
import json
import os
from pathlib import Path
import socket
import ssl
import stat
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

repo, lab, sha, old_binary, new_binary, stable_binary = sys.argv[1:7]
# Optional stable-channel payload: a third build compiled with
# panelBuildVersion=0.0.1-1 and panelBuildChannel=stable. When present, the
# lab finishes with the explicit experimental→stable migration legs.
stable_binary = stable_binary or None
stable_tag = 'kas-web-v0.0.1'
stable_asset = 'kas-control-center_0.0.1-1_aarch64-3.10.ipk'
# The hosted runner image may hand this process a permissive umask; the lab
# models the router layout, where daemon- and driver-created private files
# are 0600/0700. Pin it so every fixture mode is deterministic.
print('DRIVER-UMASK was', oct(os.umask(0o077)), flush=True)
lab = Path(lab)
serve = lab / 'serve'
init = Path('/opt/etc/init.d/S98kas-control-center')
settings = Path('/opt/etc/kas-control-center.settings.json')
update_dir = Path('/opt/etc/kas-control-center-update')
address = '192.168.254.1'
tag = 'kas-web-ipk-' + sha[:12]
asset = 'kas-control-center_0.0.0~selftest-2_aarch64-3.10.ipk'
password = 'ci-selfupdate-panel-password'
credentials = ('kas', password)
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
holder = None

def ok(marker):
    print('[OK] ' + marker, flush=True)

def require(condition, marker):
    if not condition:
        raise RuntimeError(marker)

def run(args, expected=0, cwd=None, env=None):
    result = subprocess.run(list(map(str, args)), capture_output=True, text=True, timeout=180, cwd=cwd, env=env)
    if result.returncode != expected:
        print('FAIL-ARGS: ' + ' '.join(map(str, args)), flush=True)
        print('FAIL-STDOUT: ' + result.stdout[-2000:], flush=True)
        print('FAIL-STDERR: ' + result.stderr[-2000:], flush=True)
    require(result.returncode == expected, 'command failed: ' + Path(str(args[0])).name)
    return result

def pkg(*args):
    return run([str(Path('/opt/bin/opkg')), '-f', lab / 'opkg.conf', '--tmp-dir', lab / 'opkg-tmp', *args])

def api(port, method, path, body=None, confirm=None, expected=200, creds=credentials):
    headers = {}
    if creds:
        headers['Authorization'] = 'Basic ' + base64.b64encode((':'.join(creds)).encode()).decode()
    data = None
    if confirm is not None:
        headers['X-KAS-Confirm'] = confirm
    if body is not None or confirm is not None:
        data = json.dumps(body if body is not None else {}).encode()
        headers['Content-Type'] = 'application/json'
        headers['Origin'] = f'http://{address}:{port}'
    req = urllib.request.Request(f'http://{address}:{port}{path}', data=data, headers=headers, method=method)
    try:
        response = opener.open(req, timeout=15)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        raw = response.read()
        if response.status != expected:
            print(f'FAIL-BODY on {path}: expected {expected}, got {response.status}: '
                  + raw[:500].decode('utf-8', 'replace'), flush=True)
            require(False, f'HTTP status mismatch on {path}: expected {expected}, got {response.status}')
    try:
        return json.loads(raw)
    except ValueError:
        return raw

def wait_port(port, open_expected, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((address, port), timeout=0.3):
                opened = True
        except OSError:
            opened = False
        if opened == open_expected:
            return
        time.sleep(0.1)
    raise RuntimeError(f'listener state mismatch on port {port}: expected open={open_expected}')

def reset_update_state():
    if update_dir.exists():
        run(['rm', '-rf', update_dir])

def operation():
    return api(8081, 'GET', '/api/updates/panel/operation')

def integrity_replica():
    import stat as stat_module
    def walk(relative, max_size):
        target = Path('/opt') / relative
        directory = target.parent
        while True:
            st = os.lstat(directory)
            safe = (not (st.st_mode & 0o200022) and (st.st_mode & 0o170000) == 0o040000
                    and not stat_module.S_ISLNK(st.st_mode) and st.st_uid == 0 and st.st_gid == 0)
            print(f'REPLICA dir {directory}: mode={oct(st.st_mode)} uid={st.st_uid} safe={safe}', flush=True)
            if not safe or directory == Path('/opt'):
                break
            directory = directory.parent
        st = os.lstat(target)
        print(f'REPLICA file {target}: mode={oct(st.st_mode)} uid={st.st_uid} size={st.st_size}', flush=True)
        return target.read_bytes()

    control = walk('lib/opkg/info/kas-control-center.control', 65536).decode()
    fields = dict(line.partition(': ')[::2] for line in control.splitlines() if ': ' in line)
    print('REPLICA control package=', fields.get('Package'), 'version=', fields.get('Version'), flush=True)
    build_info = walk('share/kas-control-center/BUILD_INFO', 8192).decode()
    info = dict(line.partition('=')[::2] for line in build_info.splitlines() if '=' in line)
    digest = hashlib.sha256(walk('bin/kas-control-center', 32 << 20)).hexdigest()
    print('REPLICA binary digest match=', digest == info.get('Binary_SHA256'), flush=True)
    init_script = walk('etc/init.d/S98kas-control-center', 128 << 10)
    print('REPLICA init marker=', b'# KAS-CONTROL-CENTER-IPK-v1' in init_script, flush=True)
    listing = walk('lib/opkg/info/kas-control-center.list', 65536).decode()
    for entry in ('/opt/bin/kas-control-center', '/opt/etc/init.d/S98kas-control-center',
                  '/opt/share/kas-control-center/BUILD_INFO'):
        found = (chr(10) + listing + chr(10)).find(chr(10) + entry + chr(10)) >= 0
        print('REPLICA list has', entry, '=', found, flush=True)

def poll_operation(state, timeout=150):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            last = operation()
        except (urllib.error.URLError, OSError):
            # The daemon is legitimately down between preinst stop and start;
            # the private state file is the documented source of truth then.
            last = None
            job_path = update_dir / 'job.json'
            if job_path.exists():
                try:
                    job = json.loads(job_path.read_text())
                    last = {'ID': job.get('id'), 'State': job.get('state'),
                            'Phase': job.get('phase'), 'ErrorCode': job.get('error_code'),
                            'Gate': (update_dir / 'gate').exists()}
                except ValueError:
                    last = None
        if isinstance(last, dict) and last.get('State') == state:
            return last
        time.sleep(1)
    raise RuntimeError(f'operation never reached {state}: {last}')

def write_index(packages):
    (serve / 'index.json').write_text(json.dumps(
        {'schema': 1, 'channel': 'experimental', 'tag': tag, 'packages': packages}, indent=2))

def restore_good_index():
    (serve / 'index.json').write_bytes((serve / 'index.good.json').read_bytes())

def write_asset(corrupt):
    source = serve / ('candidate.corrupt.ipk' if corrupt else 'candidate.ipk')
    (serve / asset).write_bytes(source.read_bytes())

def start_old_daemon():
    run(['sh', init, 'start'])
    wait_port(8081, 1)

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split('?')[0]
        prefix = '/saymer-alt/keenetic-auto-setup/releases/download/'
        tags_api = '/repos/saymer-alt/keenetic-auto-setup/releases/tags/'
        if path == '/keenetic-auto-setup/updates/channels.json':
            # Registry for the Pages-based source (beta.4): both channels are
            # marked published so the lab exercises the real update cycle.
            body = json.dumps({'schema': 1, 'generated': 'lab',
                'channels': {'experimental': {'published': True, 'tag': tag},
                             'stable': {'published': True, 'tag': stable_tag}}}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path == '/keenetic-auto-setup/updates/experimental/panel-update.json':
            target = serve / 'index.json'
        elif path == '/keenetic-auto-setup/updates/stable/panel-update.json':
            target = serve / 'index-stable.json'
        elif path == prefix + 'kas-web-channel-experimental/panel-update.json':
            target = serve / 'index.json'
        elif path == prefix + 'kas-web-channel-stable/panel-update.json':
            target = serve / 'index-stable.json'
        elif path == tags_api + tag:
            target = serve / 'release.json'
        elif path == tags_api + stable_tag:
            target = serve / 'release-stable.json'
        elif path == prefix + tag + '/' + asset:
            target = serve / asset
        elif path == prefix + stable_tag + '/' + stable_asset:
            target = serve / 'stable.ipk'
        else:
            self.send_error(404)
            return
        if not target.is_file():
            self.send_error(404)
            return
        body = target.read_bytes()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json' if target.suffix == '.json' else 'application/octet-stream')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass

httpd = http.server.ThreadingHTTPServer(('127.0.0.1', 443), Handler)
tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.load_cert_chain(lab / 'server.crt', lab / 'server.key')
httpd.socket = tls.wrap_socket(httpd.socket, server_side=True)
threading.Thread(target=httpd.serve_forever, daemon=True).start()

try:
    # Real IPKs from the two fixture binaries with the real packager; the
    # channel index is generated from the actual candidate archive.
    run(['python3', repo + '/web/control-center/packaging/build-ipk.py', '--arch', 'aarch64-3.10',
         '--version', '0.0.0~selftest-1', '--channel', 'experimental',
         '--binary', old_binary, '--source-sha', sha, '--output', lab])
    run(['python3', repo + '/web/control-center/packaging/build-ipk.py', '--arch', 'aarch64-3.10',
         '--version', '0.0.0~selftest-2', '--channel', 'experimental',
         '--binary', new_binary, '--source-sha', sha, '--output', lab])
    manifest = run(['python3', repo + '/web/control-center/packaging/update-manifest.py',
                    '--channel', 'experimental', '--tag', tag,
                    lab / asset]).stdout
    (serve / 'index.json').write_text(manifest)
    (serve / 'index.good.json').write_text(manifest)
    index = json.loads(manifest)
    if stable_binary:
        run(['python3', repo + '/web/control-center/packaging/build-ipk.py', '--arch', 'aarch64-3.10',
             '--version', '0.0.1-1', '--channel', 'stable',
             '--binary', stable_binary, '--source-sha', sha, '--output', lab])
        stable_manifest = run(['python3', repo + '/web/control-center/packaging/update-manifest.py',
                               '--channel', 'stable', '--tag', stable_tag,
                               lab / stable_asset]).stdout
        (serve / 'index-stable.json').write_text(stable_manifest)
        (serve / 'index-stable.good.json').write_text(stable_manifest)
        stable_index = json.loads(stable_manifest)
        stable_entry = stable_index['packages'][0]
        (serve / 'release-stable.json').write_text(json.dumps({
            'tag_name': stable_tag, 'draft': False, 'prerelease': False,
            'assets': [{'name': stable_entry['name'], 'size': stable_entry['size'],
                        'digest': 'sha256:' + stable_entry['sha256'],
                        'browser_download_url': 'https://github.com/saymer-alt/keenetic-auto-setup/releases/download/' + stable_tag + '/' + stable_entry['name'],
                        'state': 'uploaded'}]}))
        (serve / 'stable.ipk').write_bytes((lab / stable_asset).read_bytes())
    entry = index['packages'][0]
    (serve / 'release.json').write_text(json.dumps({
        'tag_name': tag, 'draft': False, 'prerelease': True,
        'assets': [{'name': entry['name'], 'size': entry['size'], 'digest': 'sha256:' + entry['sha256'],
                    'browser_download_url': 'https://github.com/saymer-alt/keenetic-auto-setup/releases/download/' + tag + '/' + entry['name'],
                    'state': 'uploaded'}]}))
    (serve / 'candidate.ipk').write_bytes((lab / asset).read_bytes())
    write_asset(False)

    # Old daemon: real opkg install, explicit start, panel password.
    pkg('install', lab / 'kas-control-center_0.0.0~selftest-1_aarch64-3.10.ipk')
    require(not settings.exists(), 'install unexpectedly created settings')
    wait_port(8081, 0, timeout=5)
    info = Path('/opt/lib/opkg/info')
    listing = sorted(entry.name for entry in info.iterdir()) if info.is_dir() else 'MISSING'
    print('INFO-DIR:', listing, flush=True)
    for probe in ('/opt', '/opt/lib', '/opt/lib/opkg', '/opt/lib/opkg/info',
                  '/opt/lib/opkg/info/kas-control-center.control'):
        stat_result = os.stat(probe)
        print(f'OPT-STAT {probe}: mode={oct(stat_result.st_mode)} uid={stat_result.st_uid} '
              f'gid={stat_result.st_gid} size={stat_result.st_size}', flush=True)
    ok('old version installed by real opkg and stays stopped until explicit start')
    start_old_daemon()
    api(8081, 'POST', '/api/settings', body={'port': 8081, 'auth_mode': 'panel', 'password': password},
        confirm='settings')
    api(8081, 'GET', '/api/settings', creds=None, expected=401)
    require(api(8081, 'GET', '/api/settings')['port'] == 8081, 'settings port mismatch')
    settings_before = settings.read_bytes()
    require(password.encode() not in settings_before, 'plaintext panel password stored')
    sentinel = Path('/opt/etc/mihomo/config.yaml')
    sentinel.parent.mkdir(parents=True, exist_ok=True)
    sentinel.write_text('# self-update settings sentinel: never mutate\n')
    # Deterministic modes regardless of any inherited process mask.
    sentinel.parent.chmod(0o700)
    sentinel.chmod(0o600)
    sentinel_before = sentinel.read_bytes()
    old_pid = int(Path('/opt/var/run/kas-control-center.ipk.pid').read_text())
    ok('old daemon authenticated on port 8081; credentials live outside the package')

    # Network fixture probe: name resolution and TLS must reach the lab server
    # exactly as the Go client will; print evidence for a cheap CI bisect.
    resolved = {entry[4][0] for entry in socket.getaddrinfo('github.com', 443, type=socket.SOCK_STREAM)}
    print('DNS github.com ->', sorted(resolved), flush=True)
    with opener.open('https://github.com/saymer-alt/keenetic-auto-setup/releases/download/'
                     'kas-web-channel-experimental/panel-update.json', timeout=10) as probe:
        probe_body = probe.read()
        require(b'kas-web-ipk-' in probe_body and b'"channel": "experimental"' in probe_body,
                'lab index not served over TLS: ' + probe_body[:120].decode('utf-8', 'replace'))
    ok('lab TLS server serves the channel index with verification enabled')

    # A. Space shortage before download must fail safe on the touched filesystem.
    run(['mount', '-t', 'tmpfs', '-o', 'size=8M', 'tmpfs', '/opt/tmp'])
    api(8081, 'POST', '/api/updates/panel/check', confirm='check-panel')
    result = api(8081, 'POST', '/api/updates/panel/apply', confirm='update-panel', expected=503)
    require(result.get('error_code') == 'PANEL_INSUFFICIENT_SPACE', f'unexpected space result: {result}')
    api(8081, 'GET', '/api/settings')
    require(not (update_dir / 'gate').exists(), 'space failure retained the gate')
    ok('space shortage refuses apply before download and keeps the old daemon')
    run(['umount', '/opt/tmp'])

    # B. Asset download failure inside the worker fails safe without a gate.
    (serve / asset).unlink()
    check = api(8081, 'POST', '/api/updates/panel/check', confirm='check-panel')
    require(check.get('relation') == 'newer' and check.get('available_version') == '0.0.0~selftest-2',
            f'unexpected check: {check}')
    api(8081, 'POST', '/api/updates/panel/apply', confirm='update-panel', expected=202)
    final = poll_operation('FAIL')
    integrity_replica()
    probe = run(['go', 'test', '-count=1', '-run', '^TestPanelLabInventoryProbe$', '-v', '.'],
                cwd=repo + '/web/control-center', env={**os.environ, 'KAS_LAB_PROBE': '1'})
    for line in probe.stdout.splitlines():
        if line.strip() and ('panel_update_labprobe_test.go' in line or line.startswith('---') or 'PASS' in line or 'FAIL' in line):
            print('LAB-PROBE', line.strip(), flush=True)
    require(final.get('ErrorCode') == 'PANEL_DOWNLOAD_FAILED', f'expected download failure, got {final}')
    require(final.get('Gate') is False, 'download failure retained the gate')
    api(8081, 'GET', '/api/settings')
    ok('download failure reports FAIL, releases the gate and keeps the old daemon')
    write_asset(False)

    # C. Tampered channel index fails the check before any job exists.
    reset_update_state()
    tampered = json.loads((serve / 'index.good.json').read_text())
    first = tampered['packages'][0]['sha256'][0]
    tampered['packages'][0]['sha256'] = ('0' if first != '0' else '1') + tampered['packages'][0]['sha256'][1:]
    write_index(tampered['packages'])
    error = api(8081, 'POST', '/api/updates/panel/check', confirm='check-panel', expected=502)
    require(error.get('error_code') == 'PANEL_METADATA_INVALID', f'unexpected tamper result: {error}')
    require(not update_dir.exists(), 'tampered index created private state')
    api(8081, 'GET', '/api/settings')
    ok('index/manifest mismatch refuses the check without touching the service')
    restore_good_index()

    # D. Wrong-ABI index is rejected for this runtime architecture.
    wrong_abi = json.loads((serve / 'index.good.json').read_text())
    wrong_abi['packages'][0]['architecture'] = 'mipsel-3.4'
    wrong_abi['packages'][0]['name'] = wrong_abi['packages'][0]['name'].replace('aarch64-3.10', 'mipsel-3.4')
    write_index(wrong_abi['packages'])
    error = api(8081, 'POST', '/api/updates/panel/check', confirm='check-panel', expected=502)
    require(error.get('error_code') == 'PANEL_PACKAGE_INVALID', f'unexpected ABI result: {error}')
    restore_good_index()
    ok('foreign ABI index is refused on this runtime')

    # E. Tampered asset bytes fail inside the worker after a real download.
    data = bytearray((serve / 'candidate.ipk').read_bytes())
    data[len(data) // 2] ^= 0xFF
    (serve / 'candidate.corrupt.ipk').write_bytes(bytes(data))
    write_asset(True)
    api(8081, 'POST', '/api/updates/panel/check', confirm='check-panel')
    api(8081, 'POST', '/api/updates/panel/apply', confirm='update-panel', expected=202)
    final = poll_operation('FAIL')
    require(final.get('ErrorCode') == 'PANEL_PACKAGE_INVALID', f'expected corrupt asset failure, got {final}')
    require(final.get('Gate') is False, 'corrupt asset retained the gate')
    api(8081, 'GET', '/api/settings')
    control = Path('/opt/lib/opkg/info/kas-control-center.control').read_text()
    require('Version: 0.0.0~selftest-1' in control, 'tampered asset mutated the package')
    ok('corrupt asset fails validation inside the worker; installed package untouched')
    write_asset(False)

    # F. Busy real opkg lock: worker reports failure, keeps gate, recovery works.
    # compare-versions inside the panel uses --offline-root and never touches
    # this lock; only the worker's real install does.
    holder = subprocess.Popen([sys.executable, '-c',
        'import fcntl,time\nf=open("/opt/tmp/opkg.lock","a+")\nfcntl.lockf(f,fcntl.LOCK_EX)\ntime.sleep(120)\n'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.5)
    api(8081, 'POST', '/api/updates/panel/check', confirm='check-panel')
    api(8081, 'POST', '/api/updates/panel/apply', confirm='update-panel', expected=202)
    final = poll_operation('FAIL', timeout=90)
    try:
        served = hashlib.sha256((serve / asset).read_bytes()).hexdigest()
        job = json.loads((update_dir / 'job.json').read_text())
        index_entry = json.loads((serve / 'index.json').read_text())['packages'][0]
        print(f'BUSY-DIAG served_sha={served[:16]} index_sha={index_entry["sha256"][:16]} '
              f'job_candidate_sha={job["candidate"]["sha256"][:16]} '
              f'job_candidate_name={job["candidate"]["name"]} '
              f'stage_left={sorted(entry.name for entry in Path("/opt/tmp").glob(".kas-panel-update-*"))}',
              flush=True)
    except Exception as error:
        print('BUSY-DIAG failed:', error, flush=True)
    require(final.get('ErrorCode') == 'PANEL_OPKG_FAILED', f'unexpected opkg-busy result: {final}')
    require(final.get('Phase') == 'recovery_required', f'busy opkg must require recovery: {final}')
    require(final.get('Gate') is True, 'failed install must retain the gate')
    require(Path('/opt/tmp/opkg.lock').exists(), 'worker deleted the opkg lock file')
    busy = api(8081, 'POST', '/api/settings', confirm='settings',
               body={'port': 8081, 'auth_mode': 'panel', 'current_password': password}, expected=409)
    require(busy.get('error_code') == 'PANEL_UPDATE_BUSY', f'mutation allowed during failed update: {busy}')
    require(api(8081, 'GET', '/api/settings')['port'] == 8081, 'old daemon lost during busy-opkg failure')
    ok('busy opkg lock fails the install without OK, keeps gate and foreign lock')
    holder.terminate()
    holder.wait(timeout=10)
    holder = None
    recovery = subprocess.run(['/opt/bin/kas-control-center', '-recover-panel-update'],
                             capture_output=True, text=True, timeout=180)
    if recovery.returncode != 0:
        print('RECOVERY-FAIL rc=', recovery.returncode, 'stderr=', recovery.stderr.strip(), flush=True)
        status = subprocess.run(['sh', str(init), 'status'], capture_output=True, text=True)
        print('RECOVERY-DIAG status rc=', status.returncode, 'out=', status.stdout.strip(),
              'err=', status.stderr.strip(), flush=True)
        for entry in sorted(os.listdir('/opt/var/run')):
            entry_path = Path('/opt/var/run') / entry
            st = os.lstat(entry_path)
            content = ''
            if entry_path.is_file() and st.st_size < 64:
                content = entry_path.read_text().strip()
            print(f'RECOVERY-DIAG {entry}: mode={oct(st.st_mode)} size={st.st_size} {content}', flush=True)
        pid_text = ''
        pid_path = Path('/opt/var/run/kas-control-center.ipk.pid')
        if pid_path.is_file():
            pid_text = pid_path.read_text().strip()
            try:
                exe = os.readlink('/proc/' + pid_text + '/exe')
                st = os.stat('/opt/bin/kas-control-center')
                import posix
                print('RECOVERY-DIAG pid', pid_text, 'exe=', exe, 'bin_ino=', st.st_ino, flush=True)
            except OSError as error:
                print('RECOVERY-DIAG pid', pid_text, 'dead-or-unreadable:', error, flush=True)
        raise RuntimeError('recovery failed: rc=%d stderr=%s' % (recovery.returncode, recovery.stderr.strip()))

    final = operation()
    require(final.get('State') == 'FAIL' and final.get('Phase') == 'recovered' and final.get('Gate') is False,
            f'recovery did not complete cleanly: {final}')
    require(api(8081, 'GET', '/api/settings')['port'] == 8081, 'recovered daemon not serving')
    api(8081, 'POST', '/api/settings', confirm='settings',
        body={'port': 8081, 'auth_mode': 'panel', 'current_password': password})
    require('Version: 0.0.0~selftest-1' in Path('/opt/lib/opkg/info/kas-control-center.control').read_text(),
            'recovery changed the installed payload')
    ok('explicit recovery restarts the verified payload and releases the gate only after receipt')
    reset_update_state()

    # G. Start failure after a real install is FAIL/START_FAILED, never OK.
    # Corrupted runtime startup state is a real init refusal cause; it makes
    # the post-install start fail deterministically while the preinst stop,
    # payload install and gate retention all run for real.
    startup = Path('/opt/var/run/kas-control-center.ipk.startup')
    startup.unlink()
    startup.mkdir()
    api(8081, 'POST', '/api/updates/panel/check', confirm='check-panel')
    api(8081, 'POST', '/api/updates/panel/apply', confirm='update-panel', expected=202)
    final = poll_operation('FAIL', timeout=150)
    if final.get('ErrorCode') != 'PANEL_START_FAILED':
        ctl = Path('/opt/lib/opkg/info/kas-control-center.control')
        print('G-DIAG control=', ctl.read_text().replace(chr(10), ' | ') if ctl.exists() else 'MISSING', flush=True)
        print('G-DIAG binary sha=', hashlib.sha256(Path('/opt/bin/kas-control-center').read_bytes()).hexdigest()[:16], flush=True)
        status = Path('/opt/lib/opkg/status')
        if status.exists():
            print('G-DIAG status tail=', status.read_text()[-400:].replace(chr(10), ' | '), flush=True)
        print('G-DIAG init marker=', b'KAS-CONTROL-CENTER-IPK-v1' in Path('/opt/etc/init.d/S98kas-control-center').read_bytes(), flush=True)
        print('G-DIAG var-run=', sorted(os.listdir('/opt/var/run')), flush=True)
        print('G-DIAG tmp=', sorted(entry.name for entry in Path('/opt/tmp').iterdir()), flush=True)
        lock_path = Path('/opt/tmp/opkg.lock')
        if lock_path.exists():
            print('G-DIAG opkg.lock mode=', oct(os.lstat(lock_path).st_mode & 0o777), flush=True)
            try:
                probe_lock = open(lock_path, 'a+')
                fcntl.lockf(probe_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                print('G-DIAG opkg.lock is FREE', flush=True)
                fcntl.lockf(probe_lock, fcntl.LOCK_UN)
            except OSError as error:
                print('G-DIAG opkg.lock is HELD:', error, flush=True)
        stage_dir = Path('/opt/tmp/.kas-panel-update-' + final.get('ID', ''))
        candidate_ipk = stage_dir / 'candidate.ipk'
        if candidate_ipk.exists():
            dry = subprocess.run(['/opt/bin/opkg', '--tmp-dir', str(stage_dir), '--noaction', 'install', str(candidate_ipk)],
                                 capture_output=True, text=True, timeout=60)
            print('G-DIAG noaction rc=', dry.returncode, flush=True)
            print('G-DIAG noaction stdout=', dry.stdout[-500:], flush=True)
            print('G-DIAG noaction stderr=', dry.stderr[-500:], flush=True)
    require(final.get('ErrorCode') == 'PANEL_START_FAILED', f'unexpected start-failure result: {final}')
    require(final.get('Gate') is True, 'start failure must retain the gate')
    require('Version: 0.0.0~selftest-2' in Path('/opt/lib/opkg/info/kas-control-center.control').read_text(),
            'start failure scenario did not actually install the new payload')
    wait_port(8081, 0, timeout=10)
    ok('start failure after real install reports START_FAILED and keeps the gate')
    run(['rm', '-rf', startup])
    run(['/opt/bin/kas-control-center', '-recover-panel-update'])
    wait_port(8081, 1, timeout=60)
    final = operation()
    require(final.get('Phase') == 'recovered' and final.get('Gate') is False,
            f'recovery after start failure: {final}')
    require(api(8081, 'GET', '/api/components')['panel']['version'] == '0.0.0~selftest-2',
            'recovery did not boot the installed payload')
    reset_update_state()
    ok('recovery after start failure boots the installed payload under receipt')

    # Back to the old version for the final full cycle (settings survive).
    pkg('remove', 'kas-control-center')
    wait_port(8081, 0, timeout=10)
    pkg('install', lab / 'kas-control-center_0.0.0~selftest-1_aarch64-3.10.ipk')
    start_old_daemon()
    require(api(8081, 'GET', '/api/settings')['port'] == 8081, 'settings did not survive the package cycle')
    require(settings.read_bytes() == settings_before, 'settings changed across remove/reinstall')
    ok('user settings survive opkg remove/reinstall while returning to the old version')

    # H. The full cycle with a lost browser: apply, stop polling, reconnect.
    old_pid = int(Path('/opt/var/run/kas-control-center.ipk.pid').read_text())
    api(8081, 'POST', '/api/updates/panel/check', confirm='check-panel')
    accepted = api(8081, 'POST', '/api/updates/panel/apply', confirm='update-panel', expected=202)
    operation_id = accepted.get('id')
    require(operation_id, 'apply did not return an operation id')
    # While the browser is "gone": observe the detached session worker, the
    # stop of the old daemon and the start of the new one.
    worker_seen = None
    stopped = False
    started = False
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline and not (stopped and started):
        if worker_seen is None:
            for entry in os.listdir('/proc'):
                if not entry.isdigit():
                    continue
                try:
                    cmdline = Path(f'/proc/{entry}/cmdline').read_bytes()
                    stat = Path(f'/proc/{entry}/stat').read_text()
                except OSError:
                    continue
                if b'-panel-update-worker' not in cmdline:
                    continue
                tail = stat[stat.rindex(') ') + 2:].split()
                if len(tail) < 5:
                    continue
                worker_seen = {'pid': int(entry), 'session': int(tail[3])}
                break
        try:
            with socket.create_connection((address, 8081), timeout=0.3):
                opened = True
        except OSError:
            opened = False
        if not opened:
            stopped = True
        elif stopped:
            started = True
        time.sleep(0.3)
    require(worker_seen is not None, 'detached worker process was never observed')
    require(worker_seen['session'] == worker_seen['pid'], 'worker does not lead its own session')
    require(stopped and started, f'listener transition not observed (stopped={stopped}, started={started})')
    final = poll_operation('OK')
    require(final.get('ID') == operation_id, 'operation identity changed across reconnect')
    require(final.get('Version') == '0.0.0~selftest-2' and final.get('Gate') is False,
            f'unexpected final operation: {final}')
    ok('detached session worker survived the old daemon shutdown and completed the update')

    require(not Path(f'/proc/{old_pid}').exists(), 'old daemon process survived the update')
    new_pid = int(Path('/opt/var/run/kas-control-center.ipk.pid').read_text())
    require(new_pid != old_pid, 'pid file was not renewed by the new daemon')
    # Fresh authenticated browser identity with the exact target version/SHA.
    components = api(8081, 'GET', '/api/components')
    require(components['panel']['version'] == '0.0.0~selftest-2',
            f'installed version mismatch: {components.get("panel")}')
    require(components['panel']['source_sha'] == sha, 'installed source SHA mismatch')
    check = api(8081, 'POST', '/api/updates/panel/check', confirm='check-panel')
    require(check.get('runtime_version') == '0.0.0~selftest-2' and check.get('installed_version') == '0.0.0~selftest-2',
            f'fresh runtime identity mismatch: {check}')
    require(check.get('relation') == 'not_newer', 'recheck still offers the same version as newer')
    # Private state, stage cleanup and preservation.
    job = json.loads((update_dir / 'job.json').read_text())
    require(job['state'] == 'OK' and job['phase'] == 'complete' and job['worker_pid'] > 1,
            f'unexpected job state: {job}')
    require(not (update_dir / 'gate').exists(), 'gate survived a successful update')
    receipt = json.loads((update_dir / 'runtime.json').read_text())
    require(receipt['pid'] == new_pid and receipt['version'] == '0.0.0~selftest-2',
            f'unexpected receipt: {receipt}')
    require(oct(os.stat(update_dir / 'job.json').st_mode & 0o777) == '0o600', 'job state is not private 0600')
    require(not list(Path('/opt/tmp').glob('.kas-panel-update-*')), 'worker stage survived a successful update')
    require(settings.read_bytes() == settings_before, 'update changed panel settings')
    require(sentinel.read_bytes() == sentinel_before, 'update changed core YAML config')
    require(api(8081, 'GET', '/api/settings')['port'] == 8081, 'port setting lost')
    ok('runtime receipt binds the new process; settings, port and YAML preserved byte-for-byte')

    if stable_binary:
        # I. Explicit user-selected channel: an experimental panel migrates to
        # stable through the dedicated stable index. Selection alone never
        # checks or installs; every package check still applies to the stable
        # candidate and opkg must see it as strictly newer.
        require(run(['/opt/bin/opkg', '-f', lab / 'opkg.conf', '--tmp-dir', lab / 'opkg-tmp',
                     'compare-versions', '0.0.1-1', '>>', '0.0.0~selftest-2'],
                    expected=0).returncode == 0, 'stable candidate is not strictly newer')
        selected = api(8081, 'POST', '/api/updates/panel/channel',
                       body={'channel': 'stable'}, confirm='set-panel-channel')
        require(selected.get('channel') == 'stable' and selected.get('build_channel') == 'experimental',
                f'unexpected selection result: {selected}')
        channel_path = update_dir / 'channel'
        require(channel_path.is_file() and channel_path.read_text() == 'stable\n',
                'channel selection not persisted as expected')
        require(oct(os.stat(channel_path).st_mode & 0o777) == '0o600', 'channel selection is not private 0600')
        require(not (update_dir / 'gate').exists(), 'channel switch created an update gate')
        require(not list(Path('/opt/tmp').glob('.kas-panel-update-*')), 'channel switch created a worker stage')
        state = api(8081, 'GET', '/api/updates/panel/channel')
        require(state.get('channel') == 'stable' and state.get('build_channel') == 'experimental'
                and sorted(state.get('allowed', [])) == ['experimental', 'stable'],
                f'unexpected channel state: {state}')
        check = api(8081, 'POST', '/api/updates/panel/check', confirm='check-panel')
        require(check.get('channel') == 'stable' and check.get('relation') == 'newer'
                and check.get('available_version') == '0.0.1-1', f'unexpected stable check: {check}')
        accepted = api(8081, 'POST', '/api/updates/panel/apply', confirm='update-panel', expected=202)
        final = poll_operation('OK', timeout=180)
        require(final.get('Version') == '0.0.1-1' and final.get('Gate') is False,
                f'unexpected migration result: {final}')
        require(json.loads((update_dir / 'job.json').read_text())['channel'] == 'stable',
                'migration job lost its stable channel')
        control = Path('/opt/lib/opkg/info/kas-control-center.control').read_text()
        require('Version: 0.0.1-1' in control, 'migration did not install the stable payload')
        build_info = dict(line.partition('=')[::2] for line in
                          Path('/opt/share/kas-control-center/BUILD_INFO').read_text().splitlines() if '=' in line)
        require(build_info.get('Channel') == 'stable', f'stable payload carries wrong channel: {build_info}')
        components = api(8081, 'GET', '/api/components')
        require(components['panel']['version'] == '0.0.1-1', 'running panel is not the stable payload')
        require(settings.read_bytes() == settings_before, 'migration changed panel settings')
        require(sentinel.read_bytes() == sentinel_before, 'migration changed core YAML config')
        ok('explicit experimental-to-stable migration installs, boots and receipts the stable payload')

        # J. Cross-channel opt-in back to experimental must be allowed but must
        # not offer a downgrade, and the stable index stays tamper-checked.
        tampered_stable = json.loads((serve / 'index-stable.good.json').read_text())
        first = tampered_stable['packages'][0]['sha256'][0]
        tampered_stable['packages'][0]['sha256'] = ('0' if first != '0' else '1') + tampered_stable['packages'][0]['sha256'][1:]
        (serve / 'index-stable.json').write_text(json.dumps(
            {'schema': 1, 'channel': 'stable', 'tag': stable_tag, 'packages': tampered_stable['packages']}, indent=2))
        error = api(8081, 'POST', '/api/updates/panel/check', confirm='check-panel', expected=502)
        require(error.get('error_code') == 'PANEL_METADATA_INVALID', f'unexpected stable tamper result: {error}')
        (serve / 'index-stable.json').write_bytes((serve / 'index-stable.good.json').read_bytes())
        api(8081, 'POST', '/api/updates/panel/check', confirm='check-panel')
        back = api(8081, 'POST', '/api/updates/panel/channel',
                   body={'channel': 'experimental'}, confirm='set-panel-channel')
        require(back.get('channel') == 'experimental' and back.get('build_channel') == 'stable',
                f'unexpected opt-in back result: {back}')
        require((update_dir / 'channel').read_text() == 'experimental\n', 'backward selection not persisted')
        stale = api(8081, 'POST', '/api/updates/panel/check', confirm='check-panel')
        require(stale.get('channel') == 'experimental' and stale.get('relation') == 'not_newer',
                f'experimental recheck must refuse the older beta: {stale}')
        api(8081, 'POST', '/api/updates/panel/channel', body={'channel': 'stable'}, confirm='set-panel-channel')
        ok('stable build re-selects experimental only as opt-in; opkg refuses the older beta candidate')
finally:
    if holder is not None and holder.poll() is None:
        holder.terminate()
        holder.wait(timeout=10)
    httpd.shutdown()
PY
