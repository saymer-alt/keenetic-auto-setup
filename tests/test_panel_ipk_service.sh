#!/bin/sh
# Disposable Ubuntu CI only. Real Linux processes/sockets and real Entware opkg.
# The native amd64 fixture IPK uses aarch64 package metadata solely to exercise
# hooks; this is NOT architecture/ABI or Keenetic firmware acceptance.
set -eu
umask 077
fail() { echo "FAIL: $*" >&2; exit 1; }
[ "${KAS_SERVICE_LAB:-}" = 1 ] && [ "${GITHUB_ACTIONS:-}" = true ] || fail 'requires explicit disposable GitHub CI lab'
[ "$(id -u)" = 0 ] || fail 'run as root on the fresh CI VM'
[ "$(uname -m)" = x86_64 ] || fail 'native fixture requires x86_64'
[ -f /etc/os-release ] && grep -q '^ID=ubuntu$' /etc/os-release || fail 'Ubuntu CI VM required'
[ "$#" -eq 3 ] || fail 'usage: test_panel_ipk_service.sh NATIVE_BINARY ENTWARE_OPKG SOURCE_SHA'
NATIVE=$1
OPKG=$2
SOURCE_SHA=$3
[ -f "$NATIVE" ] && [ -x "$NATIVE" ] || fail 'native fixture binary unavailable'
[ -f "$OPKG" ] && [ -x "$OPKG" ] || fail 'official opkg unavailable'
REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# All state touched below must be exclusively owned by this test. Parent dirs
# may already exist on Ubuntu; never remove/rewrite their unrelated contents.
for path in /opt/bin/kas-control-center /opt/etc/init.d/S98kas-control-center \
    /opt/etc/kas-control-center.settings.json /opt/etc/kas-control-center.password \
    /opt/etc/kas-control-center.proxy-origin /opt/etc/kas-control-center.export-names \
    /opt/etc/kas-control-center.mihomo-api-secret /opt/etc/kas-control-center.web.sha256 \
    /opt/share/kas-control-center /opt/lib/opkg /opt/etc/mihomo \
    /opt/etc/passwd /opt/etc/shadow /opt/tmp/opkg.lock; do
    [ ! -e "$path" ] && [ ! -L "$path" ] || fail "test-owned path already exists: $path"
done
for path in /opt /opt/bin /opt/etc /opt/etc/init.d /opt/share /opt/lib /opt/var /opt/var/run /opt/tmp; do
    [ ! -L "$path" ] || fail "unsafe parent symlink: $path"
done
for path in /opt/var/run/kas-control-center.ipk.* /opt/var/run/.kas-control-center.ipk-startup.*; do
    [ ! -e "$path" ] && [ ! -L "$path" ] || fail 'preexisting service runtime state'
done
if ip link show br0 >/dev/null 2>&1; then fail 'br0 already exists'; fi
LAB=$(mktemp -d /tmp/kas-ipk-service.XXXXXX)
BRIDGE_CREATED=0
cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    stopped=1
    if [ -f /opt/etc/init.d/S98kas-control-center ]; then
        if ! sh /opt/etc/init.d/S98kas-control-center stop; then
            echo 'FAIL: cleanup could not gracefully stop panel; retaining its files' >&2
            stopped=0
            result=1
        fi
    fi
    if [ "$stopped" -eq 1 ]; then
        if [ -f /opt/lib/opkg/status ]; then
            "$OPKG" -f "$LAB/opkg.conf" --tmp-dir "$LAB/opkg-tmp" remove kas-control-center >/dev/null 2>&1 || result=1
        fi
        # Exactly the fixtures created after the exclusive preflight above.
        rm -f /opt/etc/kas-control-center.settings.json /opt/etc/passwd /opt/etc/shadow
        rm -f /opt/etc/mihomo/kas-ipk-service.sentinel /opt/etc/mihomo/config.yaml
        rmdir /opt/etc/mihomo 2>/dev/null || :
        rm -f /opt/var/run/kas-control-center.ipk.startup /opt/var/run/kas-control-center.ipk.pid
        rmdir /opt/var/run/kas-control-center.ipk.lock 2>/dev/null || :
        rm -rf /opt/lib/opkg
    fi
    if [ "$BRIDGE_CREATED" -eq 1 ]; then ip link delete br0 || result=1; fi
    rm -rf "$LAB"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
mkdir -p /opt/tmp "$LAB/opkg-tmp"
printf 'dest root /\narch all 1\narch aarch64-3.10 10\n' > "$LAB/opkg.conf"
ip link add br0 type bridge
BRIDGE_CREATED=1
ip address add 192.168.254.1/24 dev br0
ip link set br0 up
python3 - "$REPO" "$LAB" "$NATIVE" "$OPKG" "$SOURCE_SHA" <<'PY'
import base64
import hashlib
import json
from pathlib import Path
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

repo, lab, native, opkg, sha = sys.argv[1:]
lab = Path(lab)
init = Path('/opt/etc/init.d/S98kas-control-center')
settings = Path('/opt/etc/kas-control-center.settings.json')
address = '192.168.254.1'
# Synthetic credentials stay in private fixtures/in-memory HTTP requests only.
panel_password = 'ci-separate-panel-password'
root_password = 'router-password'
root_hash = '$6$saltsalt$62yB5ThboPKIynD0rklPtaSK6o8vfyzPbifv6nVTIsf/6IrXa/El/Mv/SMNl2rvDklKI1/y2mOsLiriFCQeqh1'
secret_fixture = lab / 'credentials.json'
secret_fixture.write_text(json.dumps({'panel': panel_password, 'root': root_password}))
secret_fixture.chmod(0o600)
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
foreign = None

def ok(marker):
    print('[OK] ' + marker, flush=True)

def require(condition, marker):
    if not condition:
        raise RuntimeError(marker)

def run(args, expected=0):
    result = subprocess.run(list(map(str, args)), capture_output=True, text=True, timeout=90)
    require(result.returncode == expected, 'command failed: ' + Path(str(args[0])).name)
    return result

def pkg(*args):
    return run([opkg, '-f', lab / 'opkg.conf', '--tmp-dir', lab / 'opkg-tmp', *args])

def request(port, credentials=None, body=None, expected=200):
    headers = {}
    if credentials:
        headers['Authorization'] = 'Basic ' + base64.b64encode((':'.join(credentials)).encode()).decode()
    payload = None
    if body is not None:
        payload = json.dumps(body).encode()
        headers.update({'Content-Type': 'application/json', 'Origin': f'http://{address}:{port}',
                        'X-KAS-Confirm': 'settings'})
    req = urllib.request.Request(f'http://{address}:{port}/api/settings', data=payload, headers=headers)
    try:
        response = opener.open(req, timeout=5)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        require(response.status == expected, f'HTTP status mismatch on port {port}: expected {expected}, got {response.status}')
        data = response.read()
    if expected == 200:
        require(panel_password.encode() not in data and root_password.encode() not in data, 'credential leaked in HTTP response')
        return json.loads(data)

def wait_port(port, open_expected):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((address, port), timeout=0.3):
                opened = True
        except OSError:
            opened = False
        if opened == open_expected:
            return
        time.sleep(0.1)
    raise RuntimeError(f'listener state mismatch on port {port}')

def build(version):
    run(['python3', repo + '/web/control-center/packaging/build-ipk.py', '--arch', 'aarch64-3.10',
         '--version', version, '--binary', native, '--source-sha', sha, '--output', lab])
    return lab / f'kas-control-center_{version}_aarch64-3.10.ipk'

def read_shadow(locked=False):
    path = Path('/opt/etc/shadow')
    path.write_text('root:' + ('!' if locked else '') + root_hash + ':19000:0:99999:7:::\n')
    path.chmod(0o600)

try:
    package = build('0.0.0~service-test-1')
    pkg('install', package)
    require(not settings.exists(), 'install unexpectedly created settings')
    wait_port(8081, False)
    ok('real opkg installation stays stopped until explicit start')
    run(['sh', init, 'start'])
    wait_port(8081, True)
    require(request(8081)['port'] == 8081, 'default port differs from 8081')
    ok('actual package init starts Go on default port 8081')
    config = Path('/opt/etc/mihomo/config.yaml')
    config.parent.mkdir(exist_ok=True)
    config.write_text('proxy-providers:\n  P:\n    type: http\n    url: https://subscription.invalid/private-token\n    path: ./proxy_provider/P.yaml\n')
    config.chmod(0o600)
    with opener.open(f'http://{address}:8081/api/filter/providers', timeout=5) as response:
        data = response.read()
        require(response.status == 200, 'packaged editor disabled without legacy export flag')
    require(b'private-token' not in data and b'subscription.invalid' not in data, 'editor leaked subscription URL')
    require(json.loads(data)['providers'][0]['name'] == 'P', 'editor did not inspect HTTP provider')
    config.unlink()
    ok('actual package service enables subscription editor without legacy flag; URLs stay private')
    request(8081, body={'port': 8081, 'auth_mode': 'panel', 'password': panel_password})
    request(8081, expected=401)
    request(8081, ('kas', panel_password))
    request(8081, ('kas', 'wrong'), expected=401)
    request(8081, ('kas', panel_password))
    request(8081, ('kas', panel_password), body={'port': 8082, 'auth_mode': 'panel', 'current_password': panel_password})
    wait_port(8082, True)
    wait_port(8081, False)
    require(request(8082, ('kas', panel_password))['port'] == 8082, 'new port not effective')
    ok('panel password enforced; authenticated port change moves live listener to 8082')
    passwd = Path('/opt/etc/passwd')
    passwd.write_text('root:x:0:0:root:/root:/bin/sh\n')
    passwd.chmod(0o600)
    read_shadow()
    request(8082, ('kas', panel_password), body={'port': 8082, 'auth_mode': 'entware',
            'current_password': panel_password, 'password': root_password})
    request(8082, ('root', root_password))
    request(8082, ('root', 'wrong'), expected=401)
    read_shadow(True)
    request(8082, ('root', root_password), expected=401)
    read_shadow()
    request(8082, ('root', root_password))
    request(8082, ('root', root_password), body={'port': 8082, 'auth_mode': 'panel',
            'current_password': root_password, 'password': panel_password})
    ok('real Entware fixture auth accepts root proof, rejects wrong and locked accounts')
    before = settings.read_bytes()
    require(panel_password.encode() not in before and root_password.encode() not in before, 'plaintext settings credential')
    require(settings.stat().st_mode & 0o777 == 0o600, 'settings permissions not 0600')
    run(['sh', init, 'stop'])
    wait_port(8082, False)
    foreign = subprocess.Popen([sys.executable, '-m', 'http.server', '8082', '--bind', address,
                                '--directory', str(lab)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    wait_port(8082, True)
    failed = subprocess.run(['sh', str(init), 'start'], capture_output=True, text=True, timeout=15)
    require(failed.returncode != 0 and 'PORT_BIND_FAILED:' in failed.stderr, 'occupied port did not return visible bind failure')
    require(foreign.poll() is None, 'foreign listener was stopped')
    require(not Path('/opt/var/run/kas-control-center.ipk.pid').exists(), 'confirmed dead failed-start PID was retained')
    require(settings.read_bytes() == before, 'bind failure changed settings')
    ok('occupied port fails clearly while foreign listener and settings survive')
    foreign.terminate()
    foreign.wait(timeout=10)
    foreign = None
    run(['sh', init, 'start'])
    request(8082, ('kas', panel_password))
    sentinel = Path('/opt/etc/mihomo/kas-ipk-service.sentinel')
    sentinel.parent.mkdir()
    sentinel.write_bytes(b'core settings sentinel: never mutate\n')
    core_before = sentinel.read_bytes()
    upgraded = build('0.0.0~service-test-2')
    pkg('install', upgraded)
    wait_port(8082, False)
    require(settings.read_bytes() == before, 'upgrade changed panel settings')
    require(sentinel.read_bytes() == core_before, 'upgrade changed core sentinel')
    run(['sh', init, 'start'])
    request(8082, expected=401)
    request(8082, ('kas', panel_password))
    ok('actual opkg upgrade drains/stops service and preserves port and credentials')
    pkg('remove', 'kas-control-center')
    wait_port(8082, False)
    require(not Path('/opt/bin/kas-control-center').exists() and not init.exists(), 'opkg removal retained payload')
    require(settings.read_bytes() == before and sentinel.read_bytes() == core_before, 'removal changed user/core settings')
    print('[OK] settings preserved SHA256=' + hashlib.sha256(before).hexdigest(), flush=True)
    ok('actual opkg remove gracefully stops service, removes payload, preserves core sentinel')
finally:
    if foreign is not None and foreign.poll() is None:
        foreign.terminate()
        foreign.wait(timeout=10)
PY
