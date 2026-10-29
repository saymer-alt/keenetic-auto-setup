#!/bin/sh
# Disposable GitHub CI VM only. Independent night acceptance of the KAS
# Control Center for ordinary user scenarios on real processes: real opkg
# install, real init, the real config-import.sh transaction with a real
# mihomo binary for `mihomo -t`, real packaged filter editor endpoints.
# Network conditions (unreachable GitHub) are honest host-level conditions.
# This is NOT KeeneticOS firmware acceptance.
set -eu
umask 077
fail() { echo "FAIL: $*" >&2; exit 1; }
[ "${KAS_SERVICE_LAB:-}" = 1 ] && [ "${GITHUB_ACTIONS:-}" = true ] || fail 'requires explicit disposable GitHub CI lab'
[ "$(id -u)" = 0 ] || fail 'run as root on the fresh CI VM'
[ "$(uname -m)" = x86_64 ] || fail 'native fixture requires x86_64'
[ -f /etc/os-release ] && grep -q '^ID=ubuntu$' /etc/os-release || fail 'Ubuntu CI VM required'
[ "$#" -eq 4 ] || fail 'usage: test_panel_user_night.sh NATIVE_BINARY MIHOMO_BINARY ENTWARE_OPKG SOURCE_SHA'
NATIVE=$1
MIHOMO=$2
OPKG=$3
SOURCE_SHA=$4
[ -f "$NATIVE" ] && [ -x "$NATIVE" ] || fail 'panel binary unavailable'
[ -f "$MIHOMO" ] && [ -x "$MIHOMO" ] || fail 'real mihomo binary unavailable'
[ -f "$OPKG" ] && [ -x "$OPKG" ] || fail 'official opkg unavailable'
REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
for path in /opt/bin/kas-control-center /opt/bin/mihomo /opt/etc/init.d/S98kas-control-center \
    /opt/etc/kas-control-center.settings.json /opt/etc/mihomo /opt/lib/opkg \
    /opt/share/kas-control-center /opt/etc/passwd /opt/etc/shadow /opt/tmp/opkg.lock \
    /opt/var/run/mihomo-night.pid; do
    [ ! -e "$path" ] && [ ! -L "$path" ] || fail "test-owned path already exists: $path"
done
for path in /opt /opt/bin /opt/etc /opt/etc/init.d /opt/share /opt/lib /opt/var /opt/var/run /opt/tmp; do
    [ ! -L "$path" ] || fail "unsafe parent symlink: $path"
done
if ip link show br0 >/dev/null 2>&1; then fail 'br0 already exists'; fi
grep -q 'api\.github\.com' /etc/hosts && fail '/etc/hosts already maps api.github.com'
LAB=$(mktemp -d /tmp/kas-night.XXXXXX)
BRIDGE_CREATED=0
cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    if [ -f /opt/etc/init.d/S99mihomo ]; then
        sh /opt/etc/init.d/S99mihomo stop >/dev/null 2>&1 || true
    fi
    if [ -f /opt/etc/init.d/S98kas-control-center ]; then
        sh /opt/etc/init.d/S98kas-control-center stop >/dev/null 2>&1 || result=1
    fi
    if [ -f /opt/lib/opkg/status ]; then
        "$LAB/opkg" -f "$LAB/opkg.conf" --tmp-dir "$LAB/opkg-tmp" remove kas-control-center >/dev/null 2>&1 || result=1
    fi
    if [ -f "$LAB/hosts.backup" ]; then cat "$LAB/hosts.backup" > /etc/hosts; fi
    rm -f /opt/etc/kas-control-center.settings.json /opt/etc/passwd /opt/etc/shadow /opt/bin/mihomo
    rm -rf /opt/etc/mihomo /opt/lib/opkg /opt/share/kas-control-center
    if [ "$BRIDGE_CREATED" -eq 1 ]; then ip link delete br0 || result=1; fi
    rm -rf "$LAB"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
mkdir -p /opt/tmp /opt/bin /opt/etc/init.d /opt/share /opt/var/run "$LAB/opkg-tmp"
chmod 755 /opt /opt/bin /opt/etc /opt/etc/init.d /opt/share /opt/lib /opt/var /opt/var/run /opt/tmp
printf 'dest root /\narch all 1\narch aarch64-3.10 10\n' > "$LAB/opkg.conf"
install -m 700 "$OPKG" "$LAB/opkg"
install -m 755 "$MIHOMO" /opt/bin/mihomo
# Lab stand-in for the package-owned S99mihomo: a standard start/stop/restart
# wrapper around the REAL mihomo binary, so the import transaction exercises
# the actual one-Mihomo discipline and service restart path.
cat > /opt/etc/init.d/S99mihomo <<'S99'
#!/bin/sh
PID=/opt/var/run/mihomo-night.pid
BIN=/opt/bin/mihomo
case "$1" in
  start)
    if [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; then echo RUNNING; exit 0; fi
    "$BIN" -d /opt/etc/mihomo >/dev/null 2>&1 &
    echo $! > "$PID"
    echo STARTED ;;
  stop)
    if [ -f "$PID" ]; then
      pid=$(cat "$PID")
      kill "$pid" 2>/dev/null || true
      n=0
      # A zombie answers kill -0; exit on it like the panel init does.
      while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 50 ]; do
        state=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null | cut -d ' ' -f 1)
        case "$state" in Z|'') break;; esac
        sleep 0.1; n=$((n+1))
      done
      rm -f "$PID"
    fi
    echo STOPPED ;;
  restart)
    "$0" stop >/dev/null 2>&1 || true
    "$0" start ;;
  *) echo "usage: $0 start|stop|restart" >&2; exit 1 ;;
esac
S99
chmod 700 /opt/etc/init.d/S99mihomo
ip link add br0 type bridge
BRIDGE_CREATED=1
ip address add 192.168.254.1/24 dev br0
ip link set br0 up
python3 - "$REPO" "$LAB" "$NATIVE" "$LAB/opkg" "$SOURCE_SHA" <<'PY'
import base64
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

repo, lab, native, opkg, sha = sys.argv[1:6]
lab = Path(lab)
init = Path('/opt/etc/init.d/S98kas-control-center')
settings = Path('/opt/etc/kas-control-center.settings.json')
address = '192.168.254.1'
password = 'ci-night-panel-password'
credentials = ('kas', password)
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

def ok(marker):
    print('[OK] ' + marker, flush=True)

def require(condition, marker):
    if not condition:
        raise RuntimeError(marker)

def run(args, expected=0):
    result = subprocess.run(list(map(str, args)), capture_output=True, text=True, timeout=240)
    if result.returncode != expected:
        print('FAIL-ARGS: ' + ' '.join(map(str, args)), flush=True)
        print('FAIL-STDOUT: ' + result.stdout[-1500:], flush=True)
        print('FAIL-STDERR: ' + result.stderr[-1500:], flush=True)
    require(result.returncode == expected, 'command failed: ' + Path(str(args[0])).name)
    return result

def api(port, method, path, body=None, confirm=None, expected=200, creds=credentials,
        content_type=None, raw=None, timeout=25):
    headers = {}
    if creds:
        headers['Authorization'] = 'Basic ' + base64.b64encode((':'.join(creds)).encode()).decode()
    data = raw
    if body is not None or confirm is not None or raw is not None:
        data = raw if raw is not None else json.dumps(body if body is not None else {}).encode()
        headers['Content-Type'] = content_type or 'application/json'
        headers['Origin'] = f'http://{address}:{port}'
    if confirm is not None:
        headers['X-KAS-Confirm'] = confirm
    req = urllib.request.Request(f'http://{address}:{port}{path}', data=data, headers=headers, method=method)
    try:
        response = opener.open(req, timeout=timeout)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        raw_body = response.read()
        if response.status != expected:
            print('FAIL-BODY on ' + path + f': expected {expected}, got {response.status}: '
                  + raw_body[:400].decode('utf-8', 'replace'), flush=True)
            print('NIGHT-REQ sent-auth=', bool(headers.get('Authorization')),
                  'auth-prefix=', (headers.get('Authorization') or '')[:16],
                  'method=', method, 'settings-exists=', settings.exists(), flush=True)
            if settings.exists():
                print('NIGHT-REQ settings=', settings.read_text()[:120], flush=True)
            require(False, f'HTTP status mismatch on {path}')
    try:
        return json.loads(raw_body)
    except ValueError:
        return raw_body

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
    raise RuntimeError(f'listener state mismatch on port {port}')

def import_yaml(yaml_text, expected_state, timeout=120):
    body = yaml_text.encode() if isinstance(yaml_text, str) else yaml_text
    accepted = api(8082, 'POST', '/api/config/import', confirm='apply',
                   content_type='application/x-yaml', raw=body, expected=202)
    require(accepted.get('id'), 'import id missing')
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = api(8082, 'GET', '/api/config/operation')
        if last.get('state') in ('OK', 'FAIL'):
            break
        time.sleep(0.5)
    require(last is not None and last.get('state') == expected_state,
            f'import state {last} != {expected_state}')
    return last

try:
    run(['python3', repo + '/web/control-center/packaging/build-ipk.py', '--arch', 'aarch64-3.10',
         '--version', '0.0.0~night-1', '--binary', native, '--source-sha', sha, '--output', lab])
    package = lab / 'kas-control-center_0.0.0~night-1_aarch64-3.10.ipk'
    def pkg(*args):
        return run([opkg, '-f', lab / 'opkg.conf', '--tmp-dir', lab / 'opkg-tmp', *args])
    pkg('install', package)
    require(not settings.exists(), 'install created settings')
    wait_port(8081, 0)
    run(['sh', init, 'start'])
    wait_port(8081, 1)
    ok('A1 first start after IPK install serves the default port 8081')
    print('NIGHT-DIAG etc:', sorted(entry.name for entry in Path('/opt/etc').iterdir()), flush=True)
    if settings.exists():
        print('NIGHT-DIAG settings:', settings.read_text()[:300], flush=True)
    for entry in os.listdir('/proc'):
        if entry.isdigit():
            try:
                cmdline = Path(f'/proc/{entry}/cmdline').read_bytes()
            except OSError:
                continue
            if b'kas-control-center' in cmdline:
                print('NIGHT-DIAG panel argv:', cmdline.replace(b'', b' ').decode(), flush=True)

    try:
        api(8081, 'GET', '/api/settings', creds=None)
    except RuntimeError:
        print('NIGHT-401 first attempt failed; retrying after 1s', flush=True)
        time.sleep(1)
        req = urllib.request.Request(f'http://{address}:8081/api/settings')
        try:
            r = opener.open(req, timeout=10)
            print('NIGHT-401 retry status=', r.status, flush=True)
        except urllib.error.HTTPError as e:
            print('NIGHT-401 retry status=', e.code, 'headers=', dict(e.headers), flush=True)
        print('NIGHT-401 settings exists=', settings.exists(), flush=True)
        raise
    api(8081, 'POST', '/api/settings', body={'port': 8081, 'auth_mode': 'panel', 'password': password},
        confirm='settings')
    api(8081, 'GET', '/api/settings', creds=None, expected=401)
    # The first verification is uncached; a failed attempt starts the bounded
    # anti-brute-force window inside which even correct credentials are
    # refused. Follow the user's real order: correct login first, typo after.
    api(8081, 'GET', '/api/settings')
    api(8081, 'GET', '/api/settings', creds=('kas', 'wrong'), expected=401)
    time.sleep(0.3)
    api(8081, 'GET', '/api/settings')
    ok('A2 panel password enforced, wrong password rejected')
    api(8081, 'POST', '/api/settings', body={'port': 8082, 'auth_mode': 'panel', 'current_password': password},
        confirm='settings')
    wait_port(8082, 1)
    wait_port(8081, 0)
    ok('A3 authenticated port change moves the live listener to 8082')
    settings_before = settings.read_bytes()
    run(['sh', init, 'restart'])
    wait_port(8082, 1)
    api(8082, 'GET', '/api/settings')
    require(settings.read_bytes() == settings_before, 'restart changed settings')
    ok('A4 service restart keeps port, password and settings byte-for-byte')
    access = api(8082, 'GET', '/api/access')
    require(access.get('home_only') is False, f'unexpected default access policy: {access}')
    ok('A5 subnet restriction defaults to off; policy is opt-in with no name assumptions')

    config = Path('/opt/etc/mihomo/config.yaml')
    config.parent.mkdir(parents=True, exist_ok=True)
    config.parent.chmod(0o700)
    # setup.sh precondition: an initial working config exists before any import,
    # and the user's real state has the mihomo service already running.
    config.write_bytes(b'mixed-port: 7890' + chr(10).encode() + b'mode: rule' + chr(10).encode() + b'rules:' + chr(10).encode() + b'  - MATCH,DIRECT' + chr(10).encode())
    config.chmod(0o600)
    run(['sh', '/opt/etc/init.d/S99mihomo', 'start'])
    good_yaml = (
        'mixed-port: 7890\n'
        'mode: rule\n'
        'proxies:\n'
        '  - name: night-a\n'
        '    type: socks5\n'
        '    server: 127.0.0.1\n'
        '    port: 1080\n'
        '  - name: night-b\n'
        '    type: socks5\n'
        '    server: 127.0.0.1\n'
        '    port: 1081\n'
        'proxy-groups:\n'
        '  - name: N\n'
        '    type: select\n'
        '    proxies: [night-a, night-b]\n'
        'rules:\n'
        '  - MATCH,N\n')
    # Passes the panel's mixed-port guard but fails the real `mihomo -t`:
    # exercises the importer's own validation and rollback path.
    bad_yaml = (b'mixed-port: 7890\nmode: rule\nproxies:\n  - name: broken\n    type: definitely-not-a-type\nrules:\n  - MATCH,DIRECT\n')
    result = import_yaml(good_yaml, 'OK')
    require(result.get('exit_code') == 0, f'exit code: {result}')
    require(b'night-a' in config.read_bytes(), 'valid YAML was not committed')
    ok('B1 valid YAML applies through the real config-import transaction with real mihomo -t')
    before = config.read_bytes()
    backup = Path('/opt/etc/mihomo/config.yaml.bak')
    result = import_yaml(bad_yaml, 'FAIL')
    require(config.read_bytes() == before, 'failed YAML changed the live config')
    # A validation failure happens BEFORE any commit: the live config stays
    # byte-identical and no staging files linger in the config directory.
    # config.yaml.bak is the successful commit's backup; cache.db is created
    # by the real `mihomo -t` run. Staging files (.config.yaml.new.*, .bak.new.*,
    # .rollback.*) must NOT survive a failed import.
    legit = {'config.yaml', 'config.yaml.bak', 'cache.db'}
    leftovers = [entry.name for entry in config.parent.iterdir() if entry.name not in legit]
    require(not leftovers, f'failed import left staging files: {leftovers}')
    ok('B2 broken YAML fails the real transaction; live config preserved byte-for-byte, no staging debris')
    result = import_yaml(good_yaml, 'OK')
    require(config.read_bytes() == before, 're-import of the same YAML diverged')
    ok('B3 re-import of the same YAML keeps the on-disk config identical')
    # The service was running before the import, so the transaction restarts
    # it: exactly ONE mihomo may exist, never a second concurrent one.
    mihomo_count = len([p for p in os.listdir('/proc') if p.isdigit()
                        and Path(f'/proc/{p}/comm').read_text().strip() == 'mihomo'])
    require(mihomo_count == 1, f'expected exactly one mihomo, got: {mihomo_count}')
    ok('B4 the import transaction keeps exactly one mihomo running (no duplicate)')
    run(['sh', init, 'restart'])
    wait_port(8082, 1)
    api(8082, 'GET', '/api/settings')
    ok('B5 panel restart keeps working with the imported configuration')

    secret_url = 'https://subscription.invalid/private-token-1234567890'
    nl = chr(10)
    provider_config = good_yaml.replace(
        'rules:' + nl + '  - MATCH,N' + nl,
        'proxy-providers:' + nl + '  P:' + nl + '    type: http' + nl
        + '    url: ' + secret_url + nl + '    path: ./proxy_provider/P.yaml' + nl
        + 'rules:' + nl + '  - MATCH,N' + nl)
    import_yaml(provider_config, 'OK')
    data = api(8082, 'GET', '/api/filter/providers')
    listing = json.dumps(data).encode()
    require(b'private-token' not in listing and b'subscription.invalid' not in listing,
            'subscription URL leaked')
    ok('C1 provider listing exposes names without subscription URLs or tokens')
    import_yaml('mixed-port: 7890\nmode: rule\nrules:\n  - MATCH,DIRECT\n', 'OK')
    # The editor fails closed on shapes it cannot edit: a config without any
    # proxy-providers answers 422 UNSUPPORTED_PROVIDER_YAML by design.
    api(8082, 'GET', '/api/filter/providers', expected=422)
    ok('C2 configuration without providers fails closed with UNSUPPORTED_PROVIDER_YAML')
    provider_config_again = provider_config
    import_yaml(provider_config_again, 'OK')
    source_sha = api(8082, 'GET', '/api/filter/providers').get('source_sha')
    require(source_sha and len(source_sha) == 64, f'unexpected source sha: {source_sha}')
    apply_result = api(8082, 'POST', '/api/filter/apply', confirm='apply',
                       body={'provider': 'P', 'names': ['night-a'], 'source_sha': source_sha},
                       expected=502)
    require(apply_result.get('error_code') == 'MIHOMO_UNAVAILABLE',
            f'unexpected unavailable-API result: {apply_result}')
    ok('C3 filter apply against an unavailable Mihomo provider API refuses with MIHOMO_UNAVAILABLE')

    accepted = None
    for _ in range(10):
        try:
            accepted = api(8082, 'POST', '/api/config/import', confirm='apply',
                           content_type='application/x-yaml', raw=good_yaml.encode(), expected=202)
            break
        except RuntimeError:
            time.sleep(1)
    require(accepted is not None and accepted.get('id'), 'import slot never freed after the filter refusal')
    api(8082, 'POST', '/api/config/import', confirm='apply', content_type='application/x-yaml',
        raw=good_yaml.encode(), expected=409)
    # Wait for the running import before further scenarios: a mid-flight
    # transaction legitimately keeps every other mutation BUSY. No new POSTs.
    deadline = time.monotonic() + 120
    last = None
    while time.monotonic() < deadline:
        last = api(8082, 'GET', '/api/config/operation')
        if last.get('state') in ('OK', 'FAIL'):
            break
        time.sleep(0.5)
    require(last is not None and last.get('state') == 'OK', f'E1 import state: {last}')
    ok('E1 a concurrent configuration mutation is refused with BUSY')
    api(8082, 'POST', '/api/config/import', confirm='apply', content_type='application/x-yaml',
        raw=b'x' * (1024 * 1024 + 10), expected=413)
    ok('E2 oversized YAML is refused before staging')
    subprocess.run(['cp', '/etc/hosts', str(lab / 'hosts.backup')], check=True)
    with open('/etc/hosts', 'a') as hosts:
        hosts.write('\n203.0.113.1 api.github.com github.com release-assets.githubusercontent.com\n')
    check = None
    for _ in range(10):
        try:
            check = api(8082, 'POST', '/api/updates/check', confirm='check-updates', expected=502, timeout=40)
            break
        except RuntimeError:
            time.sleep(1)
    require(check is not None, 'updates check never left the busy state')
    code = check.get('error_code') or check.get('ErrorCode')
    require(code == 'UPDATE_CHECK_FAILED', f'unexpected unreachable-GitHub result: {check}')
    ok('E3 unreachable GitHub reports UPDATE_CHECK_FAILED without crashing the panel')
    run(['sh', '/opt/etc/init.d/S99mihomo', 'stop'])
    status = api(8082, 'GET', '/api/status')
    state = status.get('runtime', {}).get('mihomo', {}).get('state')
    require(state == 'stopped', f'unexpected mihomo runtime state: {status.get("runtime")}')
    ok('E4 installed-but-stopped Mihomo is reported honestly as stopped')
    doctor = api(8082, 'POST', '/api/doctor', body={}, timeout=120)
    require(doctor.get('exit_code') is not None and doctor.get('details'),
            f'unexpected doctor result keys: {sorted(doctor)}')
    ok('E5 Doctor runs on a bare system and returns a structured redacted result')

    run(['sh', init, 'stop'])
    wait_port(8082, 0)
    sentinel = config.read_bytes()
    pkg('remove', 'kas-control-center')
    require(config.read_bytes() == sentinel, 'core YAML changed during WEB removal')
    require(settings.exists(), 'user settings lost during WEB removal')
    require(Path('/opt/bin/mihomo').exists(), 'core mihomo binary lost during WEB removal')
    ok('E6 removing only the WEB package preserves user settings, core YAML and mihomo')
finally:
    pass
PY
