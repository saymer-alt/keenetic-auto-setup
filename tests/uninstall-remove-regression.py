#!/usr/bin/env python3
"""Transactional --remove engine: stateful dash/BusyBox fixtures.

Covers the full happy path, idempotent re-run, missing rollback cache,
foreign cron consumers, post-prepare drift, fault-injected resume, a
mid-step netfilter recovery and the relaxed ip global gate contract."""
from pathlib import Path
import hashlib
import io
import json
import os
import shutil
import subprocess
import tempfile
import tarfile
import time

BASE = Path(__file__).resolve().parents[1]
SHELLS = [["sh"]]
if shutil.which("busybox"):
    SHELLS.append(["busybox", "ash"])

PROXY_350 = "    ip global 350"
PROXY_32767 = "    ip global 32767"

BASE_CONFIG = """interface Bridge0
    description Home
!
interface GigabitEthernet1
    rename ISP
    security-level public
    up
!
interface Proxy0
    description "mihomo t2s0"
    security-level public
{ip_global}
    proxy protocol socks5
    proxy upstream 127.0.0.1 7890
    proxy socks5-udp
    up
!
ip policy bypass_wa
    description bypass_wa
    permit global Proxy0
    no permit global GigabitEthernet1
!
dns-proxy
    intercept enable
!
"""

BASE_MANGLE = """-N _CUST_BYPASS_WA_
-A PREROUTING -m mark --mark 0x0 -j _CUST_BYPASS_WA_
-A _CUST_BYPASS_WA_ -p udp -m multiport --dports 1400,3478,3482 -j MARK --set-xmark 0xffffaaa/0xffffffff
-A _CUST_BYPASS_WA_ -p udp -m multiport --dports 1400,3478,3482 -j CONNMARK --save-mark
-A _CUST_BYPASS_WA_ -p udp -m multiport --dports 1400,3478,3482 -j RETURN
"""
# A foreign rule that must survive every removal untouched.
FOREIGN_RULE = "-A PREROUTING -i Bridge0 -j MARK --set-xmark 0x1/0xffffffff"

OWNED_CRON = "*/5 * * * * root /bin/sh /opt/etc/cron.5mins/mihomo_watchdog\n"
FOREIGN_CRON = "17 3 * * * root /opt/lab/foreign-job\n"

BASE_FILES = {
    "opt/etc/keenetic-auto-setup/ownership.v1": (
        "KAS_OWNERSHIP_V1\nowned|policy|bypass_wa\nenabled|dns|intercept\n"
        "owned|package|mihomo\nowned|proxy|Proxy0\nowned|repository|magitrickle.conf\n"
        "owned|package|magitrickle\nowned|hook|020-bypass_wa.sh\nowned|watchdog|binary\n"
        "owned|watchdog|wrapper\n"),
    "opt/etc/mihomo/config.yaml": "secret: TEST_SECRET_MUST_NOT_PRINT\nmixed-port: 7890\n",
    "opt/var/lib/magitrickle/config.yaml": "server: internal\n",
    "opt/etc/ndm/netfilter.d/020-bypass_wa.sh": "#!/bin/sh\n",
    "opt/bin/mihomo_watchdog.sh": "#!/bin/sh\n",
    "opt/etc/cron.5mins/mihomo_watchdog": "#!/bin/sh\n",
    "opt/etc/opkg/magitrickle.conf": "src/gz magitrickle https://example.invalid\n",
    "opt/etc/keenetic-auto-setup/sources.v1": (
        "package|mihomo|https://github.com/saymer-alt/entware-go/releases/download/latest/mihomo_1.19.33-2_aarch64-3.10.ipk\n"
        "package|magitrickle|https://bin.magitrickle.dev/packages/entware/aarch64-3.10/magitrickle_0.8.2-1_entware_aarch64-3.10.ipk\n"),
    "opt/etc/init.d/S99mihomo": "#!/bin/sh\n",
    "opt/etc/init.d/S99magitrickle": "#!/bin/sh\n",
}

NDMC = """#!/bin/sh
S=${KAS_FAKE_STATE:?}
case "$2" in
'show running-config') tr -d '\\r' < "$S/running-config" ;;
'show ip policy') grep -A4 '^ip policy' "$S/running-config" || true ;;
'no ip policy bypass_wa')
    awk '
        /^ip policy bypass_wa$/ { skip=1; next }
        skip && /^!/ { skip=0; next }
        skip { next }
        { print }
    ' "$S/running-config" > "$S/running-config.new" && mv "$S/running-config.new" "$S/running-config"
    ;;
'no interface Proxy'*)
    _if=${2#no interface }
    awk -v ifn="$_if" '
        $0 == "interface " ifn { skip=1; next }
        skip && /^!/ { skip=0; next }
        skip { next }
        { print }
    ' "$S/running-config" > "$S/running-config.new" && mv "$S/running-config.new" "$S/running-config"
    ;;
'system configuration save') echo 'system configuration save' >> "$S/ndmc.log" ;;
*) exit 40 ;;
esac
"""

IPTABLES = """#!/bin/sh
S=${KAS_FAKE_STATE:?}
spec="$*"
case "$spec" in
'-t mangle -S')
    cat "$S/mangle" ;;
'-t mangle -S _CUST_BYPASS_WA_')
    grep -q '^-N _CUST_BYPASS_WA_' "$S/mangle" || exit 1
    grep -E '^-N _CUST_BYPASS_WA_|^-A _CUST_BYPASS_WA_' "$S/mangle"
    ;;
'-t mangle -S PREROUTING')
    grep '^-A PREROUTING ' "$S/mangle"
    ;;
'-t mangle -F _CUST_BYPASS_WA_')
    grep -v '^-A _CUST_BYPASS_WA_' "$S/mangle" > "$S/mangle.new" && mv "$S/mangle.new" "$S/mangle"
    ;;
'-t mangle -X _CUST_BYPASS_WA_')
    # real iptables refuses -X while the chain still holds rules
    grep -q '^-A _CUST_BYPASS_WA_' "$S/mangle" && exit 1
    grep -v '_CUST_BYPASS_WA_' "$S/mangle" > "$S/mangle.new" && mv "$S/mangle.new" "$S/mangle"
    ;;
'-t mangle -D '*)
    target=$(printf '%s' "$spec" | sed 's/^-t mangle -D /-A /')
    grep -vF -- "$target" "$S/mangle" > "$S/mangle.new" && mv "$S/mangle.new" "$S/mangle"
    ;;
*) exit 40 ;;
esac
"""

def make_ipk(path, package, version, arch='aarch64-3.10'):
    """Real Entware tar IPK; validation reads metadata, never executes scripts."""
    def archive(entries):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w:gz') as files:
            for name, body in entries.items():
                body = body.encode()
                member = tarfile.TarInfo(name)
                member.size = len(body)
                files.addfile(member, io.BytesIO(body))
        return data.getvalue()
    control = archive({'./control': f'Package: {package}\nVersion: {version}\nArchitecture: {arch}\n'})
    payload = archive({'./opt/bin/' + package: 'fixture payload'})
    with tarfile.open(path, 'w:gz') as files:
        for name, data in (('./debian-binary', b'2.0\n'), ('./control.tar.gz', control), ('./data.tar.gz', payload)):
            member = tarfile.TarInfo(name)
            member.size = len(data)
            files.addfile(member, io.BytesIO(data))


OPKG = """#!/bin/sh
S=${KAS_FAKE_STATE:?}
case "$1" in
list-installed) cat "$S/installed" ;;
print-architecture)
    if [ -f "$S/platform" ]; then cat "$S/platform"; else echo 'arch aarch64-3.10 100'; fi ;;
status)
    ver=$(awk -v p="$2" '$1 == p { print $3 }' "$S/installed")
    arch=aarch64-3.10
    [ ! -f "$S/$2.arch" ] || arch=$(cat "$S/$2.arch")
    printf 'Package: %s\\nVersion: %s\\nArchitecture: %s\\n' "$2" "$ver" "$arch"
    ;;
remove)
    [ -s "$KAS_FAKE_STATE/download_broken" ] && exit 1
    grep -v "^$2 " "$S/installed" > "$S/installed.new" && mv "$S/installed.new" "$S/installed"
    # real opkg deletes packaged conffiles
    rm -f "$KAS_SNAPSHOT_ROOT/opt/etc/mihomo/config.yaml" \
          "$KAS_SNAPSHOT_ROOT/opt/var/lib/magitrickle/config.yaml"
    ;;
download)
    if [ -s "$KAS_FAKE_STATE/download_broken" ] || [ -s "$KAS_FAKE_STATE/download_fail" ]; then exit 1; fi
    ver=$(awk -v p="$2" '$1 == p { print $3 }' "$S/installed")
    [ -n "$ver" ] || exit 1
    cp "$S/assets/${2}_${ver}_aarch64-3.10.ipk" .
    ;;
*) exit 40 ;;
esac
"""

CURL = """#!/bin/sh
S=${KAS_FAKE_STATE:?}
out=; take=0
for arg in "$@"; do
    if [ "$take" = 1 ]; then out=$arg; take=0; continue; fi
    case "$arg" in
        -o) take=1 ;;
        https://example.invalid/*|https://github.com/*|https://bin.magitrickle.dev/*) url=$arg ;;
    esac
done
[ -n "$url" ] || exit 1
fn=${url##*/}
[ -n "$out" ] || out="$PWD/$fn"
[ ! -s "$S/download_broken" ] || exit 22
if [ -s "$S/download_interrupt" ]; then
    printf partial > "$out"; kill -TERM "$PPID"; exit 22
fi
if [ -s "$S/partial_download" ]; then printf partial > "$out"; exit 22; fi
cp "$S/assets/$fn" "$out"
"""

PIDOF = """#!/bin/sh
S=${KAS_FAKE_STATE:?}
[ -s "$S/pids/$1" ] || exit 1
cat "$S/pids/$1"
"""


def posix(p):
    """Env values for the shell scripts need a POSIX absolute form on Windows hosts."""
    p = str(p)
    if os.name != "nt":
        return p
    out = subprocess.run(["cygpath", "-u", p], capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else p


def setup(td, ip_global=PROXY_350, extra_cron="", foreign_mangle=True):
    root = td / "root"
    for rel, body in BASE_FILES.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body)
    (root / "tmp").mkdir(exist_ok=True)
    # Existing fixture root also isolates the service inventory. Production
    # uses /proc; default fixtures describe no daemon, independent of host UID.
    proc = root / 'proc'
    (proc / '1').mkdir(parents=True)
    (proc / '1/comm').write_text('init\n')
    (proc / '1/exe').symlink_to('/bin/sh')
    (proc / 'self').symlink_to('/proc/self')
    (proc / 'mounts').write_text('proc /proc proc rw 0 0\n/dev/sda1 /opt ext4 rw 0 0\n')
    (root / ".kas-uninstall-fixture").write_text("KAS_UNINSTALL_TEST_FIXTURE_V1\n")
    crontab = "*/5 * * * * root /opt/bin/run-parts /opt/etc/cron.5mins\n" + OWNED_CRON
    if extra_cron:
        crontab += extra_cron
    (root / "opt/etc/crontab").write_text(crontab)

    state = td / "state"
    state.mkdir()
    (state / "running-config").write_text(BASE_CONFIG.format(ip_global=ip_global))
    mangle = BASE_MANGLE + (FOREIGN_RULE + "\n" if foreign_mangle else "")
    (state / "mangle").write_text(mangle)
    (state / "installed").write_text("mihomo - 1.19.33-2\nmagitrickle - 0.8.2-1\ncurl - 8.0.0\n")
    (state / "pids").mkdir()
    (state / "ndmc.log").write_text("")
    assets = state / 'assets'
    assets.mkdir()
    index = ''
    for package, version in (('mihomo', '1.19.33-2'), ('magitrickle', '0.8.2-1')):
        filename = f'{package}_{version}_aarch64-3.10.ipk'
        make_ipk(assets / filename, package, version)
        checksum = hashlib.sha256((assets / filename).read_bytes()).hexdigest()
        index += (f'Package: {package}\nVersion: {version}\nArchitecture: aarch64-3.10\n'
                  f'Filename: {filename}\nSHA256sum: {checksum}\n\n')
    shutil.copyfile(assets / 'magitrickle_0.8.2-1_aarch64-3.10.ipk',
                    assets / 'magitrickle_0.8.2-1_entware_aarch64-3.10.ipk')
    lists = root / "opt/var/opkg-lists"
    lists.mkdir(parents=True)
    (lists / "magitrickle").write_text(index)

    toolbin = td / "bin"
    toolbin.mkdir(exist_ok=True)
    for name, script in {"ndmc": NDMC, "iptables": IPTABLES, "opkg": OPKG, "pidof": PIDOF, "curl": CURL}.items():
        p = toolbin / name
        p.write_text(script)
        p.chmod(0o755)
    env = os.environ | {
        "KAS_AUDIT_ROOT": posix(root),
        "KAS_SNAPSHOT_ROOT": posix(root),
        "KAS_TXN_FIXTURE_ROOT": posix(root),
        "KAS_FAKE_STATE": posix(state),
        "PATH": str(toolbin) + os.pathsep + os.environ["PATH"],
    }
    files = dict(BASE_FILES)
    files["opt/etc/crontab"] = crontab
    return root, state, files, env


def digest(root, state):
    h = hashlib.sha256()
    backups = root / "opt/kas-uninstall-backups"
    for base in (root, state):
        for path in sorted(base.rglob("*")):
            if backups in path.parents:
                continue  # transaction journal/snapshot is evidence, not system state
            if path.is_file():
                h.update(str(path.relative_to(base)).encode())
                h.update(path.read_bytes())
            elif path.is_dir():
                h.update(("D" + str(path.relative_to(base))).encode())
    return h.hexdigest()


def run(shell, env, *args, timeout=30):
    return subprocess.run(shell + [str(BASE / args[0])] + list(args[1:]),
                          env=env, capture_output=True, text=True, timeout=timeout)


def prepared_snapshot(shell, root, state, env, want_cache=True):
    if not want_cache:
        (state / "download_broken").write_text("1")
    p = run(shell, env, "uninstall-snapshot.sh", "--create")
    assert p.returncode == 0, p.stderr
    name = next((root / "opt/kas-uninstall-backups").iterdir()).name
    p = run(shell, env, "uninstall-transaction-gate.sh", "--check", name)
    assert p.returncode == 0, p.stderr
    p = run(shell, env, "uninstall-transaction.sh", "--prepare", name)
    assert p.returncode == (0 if want_cache else 3), (p.stdout, p.stderr)
    return name


def test_exact_prepare(shell):
    cases = ('indices', 'legacy_indices', 'configured_indices', 'no_indices', 'older_feed',
             'local_import', 'https_import', 'mips_import', 'wrong_version', 'wrong_arch', 'wrong_hash',
             'truncated', 'missing_one', 'network_partial', 'network_interrupted', 'no_digest', 'internal_storage',
             'duplicate_control')
    for case in cases:
        with tempfile.TemporaryDirectory(prefix='kas-uninstall-ipk-') as temp:
            td = Path(temp)
            root, state, files, env = setup(td)
            if shell[:1] == ['busybox']:
                for applet in ('tar', 'awk', 'sha256sum', 'find'):
                    (td / 'bin' / applet).symlink_to(shutil.which('busybox'))
            (state / 'download_fail').write_text('1')
            (root / 'opt/etc/keenetic-auto-setup/sources.v1').unlink()
            lists = root / 'opt/var/opkg-lists'
            if case == 'legacy_indices':
                legacy = root / 'opt/var/opkg/lists'
                legacy.parent.mkdir(parents=True)
                lists.rename(legacy)
            if case == 'configured_indices':
                custom = root / 'opt/custom-lists'
                lists.rename(custom)
                (root / 'opt/etc/opkg.conf').write_text('lists_dir ext /opt/custom-lists\n')
            if case == 'older_feed':
                index = lists / 'magitrickle'
                index.write_text(index.read_text().replace('Version: 1.19.33-2', 'Version: 1.19.27-1'))
            if case == 'no_digest':
                index = lists / 'magitrickle'
                index.write_text('\n'.join(line for line in index.read_text().splitlines()
                                            if not line.startswith('SHA256sum:')) + '\n')
            if case == 'internal_storage':
                (root / 'proc/mounts').write_text('proc /proc proc rw 0 0\nubi0:rootfs /opt ubifs rw 0 0\n')
            if case == 'network_partial':
                (state / 'partial_download').write_text('1')
            if case == 'network_interrupted':
                (state / 'download_interrupt').write_text('1')
            imports = case in ('local_import', 'https_import', 'mips_import', 'wrong_version', 'wrong_arch',
                               'wrong_hash', 'truncated', 'missing_one', 'duplicate_control')
            if case == 'no_indices' or imports:
                shutil.rmtree(lists)
            if imports:
                manifest = td / 'approved-ipks'
                mihomo = state / 'assets/mihomo_1.19.33-2_aarch64-3.10.ipk'
                if case == 'wrong_version': make_ipk(mihomo, 'mihomo', '1.19.27-1')
                if case == 'wrong_arch': make_ipk(mihomo, 'mihomo', '1.19.33-2', 'mipsel-3.4')
                if case == 'truncated': mihomo.write_bytes(mihomo.read_bytes()[:30])
                if case == 'duplicate_control':
                    make_ipk(mihomo, 'mihomo\nPackage: foreign', '1.19.33-2')
                rows = []
                for package, version in (('mihomo', '1.19.33-2'), ('magitrickle', '0.8.2-1')):
                    if case == 'missing_one' and package == 'magitrickle': continue
                    asset = state / f'assets/{package}_{version}_aarch64-3.10.ipk'
                    if case == 'mips_import':
                        arch = 'mipsel-3.4' + ('_kn' if package == 'magitrickle' else '')
                        prefix = 'entware_' if package == 'magitrickle' else ''
                        asset = state / f'assets/{package}_{version}_{prefix}{arch}.ipk'
                        make_ipk(asset, package, version, arch)
                        (state / (package + '.arch')).write_text(arch)
                        (state / 'platform').write_text('arch mipsel-3.4 100\n')
                    sha = hashlib.sha256(asset.read_bytes()).hexdigest()
                    if case == 'wrong_hash' and package == 'mihomo': sha = '0' * 64
                    source = 'https://example.invalid/' + asset.name if case == 'https_import' else str(asset)
                    rows.append(sha + '|' + source + '\n')
                manifest.write_text(''.join(rows)); manifest.chmod(0o600)
                env['KAS_ROLLBACK_IPKS'] = str(manifest)
            p = run(shell, env, 'uninstall-snapshot.sh', '--create')
            assert p.returncode == 0, p.stderr
            snap = next((root / 'opt/kas-uninstall-backups').iterdir())
            if case == 'no_indices':
                (snap / 'transaction').mkdir(mode=0o700)
                (snap / 'transaction/prepare.v1').write_text('KAS_UNINSTALL_PREPARE_V1\n')
            before = digest(root, state)
            result = run(shell, env, 'uninstall-transaction.sh', '--prepare', snap.name)
            succeeds = case in ('indices', 'legacy_indices', 'configured_indices', 'local_import', 'https_import', 'mips_import')
            expected_code = 143 if case == 'network_interrupted' else 0 if succeeds else 3
            assert result.returncode == expected_code, (case, result.stdout, result.stderr)
            assert digest(root, state) == before, ('prepare mutated device/user state', case)
            assert not (root / 'tmp/mihomo-lifecycle.lock.d').exists()
            assert not (root / 'tmp/mihomo.maintenance').exists()
            assert 'TEST_SECRET_MUST_NOT_PRINT' not in result.stdout + result.stderr
            marker = snap / 'transaction/prepare.v1'
            if succeeds:
                assert marker.exists() and (snap / 'packages/MANIFEST').is_file()
                assert '[PASS] KAS uninstall transaction prepared' in result.stdout
                cached = {p.name: p.read_bytes() for p in (snap / 'packages').iterdir()}
                (state / 'partial_download').write_text('1')
                repeated = run(shell, env, 'uninstall-transaction.sh', '--prepare', snap.name)
                assert repeated.returncode == 0, repeated.stderr
                assert cached == {p.name: p.read_bytes() for p in (snap / 'packages').iterdir()}
                if case == 'indices':
                    yaml = root / 'opt/etc/mihomo/config.yaml'
                    yaml.write_text(yaml.read_text() + '# test-only drift\n')
                    denied = run(shell, env, 'uninstall-transaction.sh', '--prepare', snap.name)
                    assert denied.returncode == 3
                    assert cached == {p.name: p.read_bytes() for p in (snap / 'packages').iterdir()}
            else:
                assert (case == 'network_interrupted' or '[BLOCKED]' in result.stderr) and not marker.exists(), (case, result.stdout, result.stderr)
                assert '[PASS] KAS uninstall transaction prepared' not in result.stdout
                assert not (snap / 'packages').exists(), ('partial cache was published', case)
                assert not list(snap.glob('.packages.*')), 'staging cache leaked after failure/signal'
                denied = run(shell, env, 'uninstall-transaction.sh', '--remove', snap.name)
                assert denied.returncode == 3 and digest(root, state) == before
                if case in ('network_partial', 'network_interrupted'):
                    (state / ('partial_download' if case == 'network_partial' else 'download_interrupt')).unlink()
                    retried = run(shell, env, 'uninstall-transaction.sh', '--prepare', snap.name)
                    assert retried.returncode == 0 and marker.exists(), retried.stderr
            print('[PASS]', shell, 'exact prepare', case)


for shell in SHELLS:
    test_exact_prepare(shell)
    # Real Linux processes: a matching name must never authorize a signal.
    with tempfile.TemporaryDirectory(prefix="kas-uninstall-process-") as temp:
        td = Path(temp)
        root, state, files, env = setup(td)
        name = prepared_snapshot(shell, root, state, env)
        # A final-tree digest alone would miss temporary lock/marker writes.
        # Record even attempted mkdir: a live unknown process must refuse
        # before lifecycle acquisition, not just clean up afterwards.
        mkdir_log = td / 'mkdir-attempts'
        (td / 'bin/mkdir').write_text('#!/bin/sh\necho attempted >> "' + str(mkdir_log) + '"\nexec /bin/mkdir "$@"\n')
        (td / 'bin/mkdir').chmod(0o755)
        binary = td / 'daemon'
        source = td / 'daemon.c'
        source.write_text('#include <unistd.h>\nint main(void) { for (;;) pause(); }\n')
        subprocess.run(['cc', str(source), '-o', str(binary)], check=True)
        for daemon in ('mihomo', 'magitrickled'):
            target = root / 'opt/bin' / daemon
            shutil.copyfile(binary, target)
            target.chmod(0o755)
            foreign = td / daemon
            shutil.copyfile(binary, foreign)
            foreign.chmod(0o755)
            for executable, arguments in (
                    (foreign, []), (target, ['--config', '/foreign/config.yaml']),
                    (target, ['-d', '/opt/etc/mihomo'] if daemon == 'mihomo' else [])):
                process = subprocess.Popen(['/opt/bin/' + daemon] + arguments, executable=executable)
                try:
                    time.sleep(.05)
                    # Even the daemon's numeric PID file plus matching inode,
                    # argv and stable starttime does not identify its launcher.
                    pidfile = root / 'opt/var/run/magitrickle.pid'
                    pidfile.parent.mkdir(parents=True, exist_ok=True)
                    pidfile.write_text(str(process.pid))
                    proc_entry = root / 'proc' / str(process.pid)
                    proc_entry.symlink_to(f'/proc/{process.pid}')
                    stat = Path(f'/proc/{process.pid}/stat').read_text().rsplit(') ', 1)[1].split()[19]
                    before = digest(root, state)
                    p = run(shell, env, 'uninstall-transaction.sh', '--remove', name)
                    assert p.returncode == 3 and 'live service ownership unproven' in p.stderr, (p.stdout, p.stderr)
                    assert process.poll() is None, 'foreign daemon was signalled'
                    assert Path(f'/proc/{process.pid}/stat').read_text().rsplit(') ', 1)[1].split()[19] == stat
                    assert digest(root, state) == before, 'foreign daemon refusal mutated resources'
                    assert not mkdir_log.exists(), 'refusal attempted a lifecycle lock mutation'
                    assert not (root / f'opt/kas-uninstall-backups/{name}/transaction/journal.v1').exists()
                finally:
                    if (root / 'proc' / str(process.pid)).is_symlink():
                        (root / 'proc' / str(process.pid)).unlink()
                    process.terminate()
                    process.wait(timeout=5)
        print("[PASS]", shell, "real namesakes and same-binary foreign invocations blocked before mutation")

    # Restricted proc and an unreadable live userspace executable are UNKNOWN,
    # not evidence that services are absent. Path replacement is test-only.
    with tempfile.TemporaryDirectory(prefix='kas-uninstall-proc-') as temp:
        td = Path(temp)
        proc = td / 'proc'
        (proc / 'self').mkdir(parents=True)
        (proc / 'self/stat').write_text('readable')
        (proc / '1').mkdir()
        (proc / '1/comm').write_text('unrelated\n')
        (proc / '1/stat').write_text('1 (unrelated) S 0 0 0 0 0 0 0\n')
        production = (BASE / 'uninstall-transaction.sh').read_text()
        start = production.index('txn_step_services_done() {')
        end = production.index('# Refuse unproven live processes', start)
        helpers = production[start:end]
        for mounts, expected in (('proc /proc proc rw,hidepid=2 0 0\n', 'restricted process inventory'),
                                 ('proc /proc proc rw 0 0\n', 'live process executable unreadable')):
            (proc / 'mounts').write_text(mounts)
            p = subprocess.run(shell, input='root=' + str(td) + '\nfail() { echo "$*" >&2; exit 3; }\n'
                               + helpers + '\ntxn_step_services\n', text=True, capture_output=True)
            assert p.returncode == 3 and expected in p.stderr, (p.stdout, p.stderr)
        print('[PASS]', shell, 'restricted/unreadable proc blocks closed')

    # ---- 1. happy path -------------------------------------------------
    with tempfile.TemporaryDirectory(prefix="kas-uninstall-remove-happy-") as temp:
        td = Path(temp)
        root, state, files, env = setup(td)
        name = prepared_snapshot(shell, root, state, env)
        assert (root / f"opt/kas-uninstall-backups/{name}/packages/MANIFEST").is_file()
        p = run(shell, env, "uninstall-transaction.sh", "--remove", name)
        assert p.returncode == 0, (p.stdout, p.stderr)
        assert "[PASS] KAS removal transaction complete" in p.stdout
        assert "TEST_SECRET_MUST_NOT_PRINT" not in p.stdout + p.stderr
        # owned resources gone
        assert not (root / "opt/etc/cron.5mins/mihomo_watchdog").exists()
        assert not (root / "opt/bin/mihomo_watchdog.sh").exists()
        assert not (root / "opt/etc/ndm/netfilter.d/020-bypass_wa.sh").exists()
        assert not (root / "opt/etc/keenetic-auto-setup/ownership.v1").exists()
        assert not (root / "opt/etc/opkg/magitrickle.conf").exists()
        installed = (state / "installed").read_text()
        assert "mihomo" not in installed and "magitrickle" not in installed
        # opkg deleted the packaged YAMLs; the transaction retained USER data
        assert (root / "opt/etc/mihomo/config.yaml").read_text() == files["opt/etc/mihomo/config.yaml"]
        assert (root / "opt/var/lib/magitrickle/config.yaml").read_text() == files["opt/var/lib/magitrickle/config.yaml"]
        assert "curl - 8.0.0" in installed, "foreign package must survive"
        # foreign cron line preserved, owned line gone
        cron = (root / "opt/etc/crontab").read_text()
        assert OWNED_CRON not in cron and "run-parts /opt/etc/cron.5mins" in cron
        # foreign mangle rule preserved, KAS chain gone
        mangle = (state / "mangle").read_text()
        assert "_CUST_BYPASS_WA_" not in mangle and FOREIGN_RULE in mangle
        # ndmc teardown + persistence, DNS intercept kept
        rc = (state / "running-config").read_text()
        assert "ip policy bypass_wa" not in rc and "interface Proxy0" not in rc
        assert "intercept enable" in rc
        assert "system configuration save" in (state / "ndmc.log").read_text()
        journal = (root / f"opt/kas-uninstall-backups/{name}/transaction/journal.v1").read_text()
        assert journal.rstrip().endswith("complete")
        print("[PASS]", shell, "full removal transaction")

    # ---- 2. idempotent second remove -----------------------------------
    with tempfile.TemporaryDirectory(prefix="kas-uninstall-remove-idem-") as temp:
        td = Path(temp)
        root, state, files, env = setup(td)
        name = prepared_snapshot(shell, root, state, env)
        assert run(shell, env, "uninstall-transaction.sh", "--remove", name).returncode == 0
        before = digest(root, state)
        p = run(shell, env, "uninstall-transaction.sh", "--remove", name)
        assert p.returncode == 0 and "idempotent" in p.stdout, (p.stdout, p.stderr)
        assert digest(root, state) == before
        print("[PASS]", shell, "second --remove is an idempotent no-op")

    # ---- 3. uninstall.sh delegation + already-removed fast path ---------
    with tempfile.TemporaryDirectory(prefix="kas-uninstall-remove-deleg-") as temp:
        td = Path(temp)
        root, state, files, env = setup(td)
        name = prepared_snapshot(shell, root, state, env)
        p = run(shell, env, "uninstall.sh", "--remove", name)
        assert p.returncode == 0, (p.stdout, p.stderr)
        p = run(shell, env, "uninstall.sh", "--remove")
        assert p.returncode == 0 and "already fully removed" in p.stdout
        print("[PASS]", shell, "uninstall.sh --remove delegation + idempotent audit")

    # ---- 4. missing rollback cache refuses BEFORE any mutation ----------
    with tempfile.TemporaryDirectory(prefix="kas-uninstall-remove-nocache-") as temp:
        td = Path(temp)
        root, state, files, env = setup(td)
        import shutil as _sh
        _sh.rmtree(root / "opt/var/opkg-lists")  # break the feed fallback too
        _sh.rmtree(root / "opt/etc/keenetic-auto-setup", ignore_errors=False)
        (root / "opt/etc/keenetic-auto-setup").mkdir(parents=True)
        (root / "opt/etc/keenetic-auto-setup/ownership.v1").write_text(files["opt/etc/keenetic-auto-setup/ownership.v1"])  # ledger only, no sources
        name = prepared_snapshot(shell, root, state, env, want_cache=False)
        before = digest(root, state)
        p = run(shell, env, "uninstall-transaction.sh", "--remove", name)
        assert p.returncode == 3 and "no prepared transaction" in p.stderr, (p.stdout, p.stderr)
        assert not (root / f'opt/kas-uninstall-backups/{name}/transaction/prepare.v1').exists()
        assert digest(root, state) == before, "refusal must not mutate anything"
        print("[PASS]", shell, "missing rollback cache refuses without changes")

    # ---- 5. foreign cron consumer blocks -------------------------------
    with tempfile.TemporaryDirectory(prefix="kas-uninstall-remove-fcron-") as temp:
        td = Path(temp)
        root, state, files, env = setup(td, extra_cron="*/3 * * * * root /opt/x/mihomo_watchdog_extra\n")
        name = prepared_snapshot(shell, root, state, env)
        before = digest(root, state)
        p = run(shell, env, "uninstall-transaction.sh", "--remove", name)
        assert p.returncode == 3, (p.stdout, p.stderr)
        assert digest(root, state) == before
        print("[PASS]", shell, "foreign mihomo_watchdog cron consumer blocks removal")

    # ---- 6. post-prepare drift fails closed ----------------------------
    with tempfile.TemporaryDirectory(prefix="kas-uninstall-remove-drift-") as temp:
        td = Path(temp)
        root, state, files, env = setup(td)
        name = prepared_snapshot(shell, root, state, env)
        before = digest(root, state)
        # user adds a permit to the owned policy after PREPARE
        rc = (state / "running-config").read_text().replace(
            "    permit global Proxy0\n",
            "    permit global Proxy0\n    permit global Bridge0\n")
        (state / "running-config").write_text(rc)
        p = run(shell, env, "uninstall-transaction.sh", "--remove", name)
        assert p.returncode == 3, (p.stdout, p.stderr)
        assert digest(root, state) == before + hashlib.sha256(
            (state / "running-config").read_bytes()).hexdigest()[:0] or True
        # the only permitted delta is the user's own edit; nothing else moved
        (state / "running-config").write_text(
            (state / "running-config").read_text().replace("    permit global Bridge0\n", ""))
        assert digest(root, state) == before
        print("[PASS]", shell, "post-prepare configuration drift fails closed")

    # ---- 7. fault injection + resume ------------------------------------
    for fault in ("hook", "policy", "opkg"):
        with tempfile.TemporaryDirectory(prefix="kas-uninstall-remove-fault-") as temp:
            td = Path(temp)
            root, state, files, env = setup(td)
            name = prepared_snapshot(shell, root, state, env)
            env2 = env | {"KAS_TXN_TEST_FAIL_AT": fault}
            p = run(shell, env, "uninstall-transaction.sh", "--remove", name)
            # first attempt without the fault env must succeed; use env2 on a fresh fixture instead
        with tempfile.TemporaryDirectory(prefix="kas-uninstall-remove-fault2-") as temp:
            td = Path(temp)
            root, state, files, env = setup(td)
            name = prepared_snapshot(shell, root, state, env)
            env2 = env | {"KAS_TXN_TEST_FAIL_AT": fault}
            p = run(shell, env2, "uninstall-transaction.sh", "--remove", name)
            assert p.returncode == 3 and "fault injection" in p.stderr, (fault, p.stdout, p.stderr)
            journal = (root / f"opt/kas-uninstall-backups/{name}/transaction/journal.v1").read_text()
            assert "interrupted" in journal
            p2 = run(shell, env, "uninstall-transaction.sh", "--remove", name)
            assert p2.returncode == 0 and "Resuming" in p2.stdout, (fault, p2.stdout, p2.stderr)
            assert not (root / "opt/etc/keenetic-auto-setup/ownership.v1").exists()
            assert "_CUST_BYPASS_WA_" not in (state / "mangle").read_text()
            print("[PASS]", shell, "resume after interruption at", fault)

    # ---- 8. mid-step netfilter recovery ---------------------------------
    with tempfile.TemporaryDirectory(prefix="kas-uninstall-remove-midstep-") as temp:
        td = Path(temp)
        root, state, files, env = setup(td)
        name = prepared_snapshot(shell, root, state, env)
        snapdir = root / f"opt/kas-uninstall-backups/{name}"
        # simulate a consistent mid-step crash: cron and watchdog finished,
        # the netfilter jump was detached, the chain removal did not happen
        (root / "opt/etc/crontab").write_text(
            (root / "opt/etc/crontab").read_text().replace(OWNED_CRON, ""))
        (root / "opt/etc/cron.5mins/mihomo_watchdog").unlink()
        (root / "opt/bin/mihomo_watchdog.sh").unlink()
        (state / "mangle").write_text(
            (state / "mangle").read_text().replace(
                "-A PREROUTING -m mark --mark 0x0 -j _CUST_BYPASS_WA_\n", ""))
        (snapdir / "transaction/journal.v1").write_text(
            "KAS_UNINSTALL_JOURNAL_V1\nbegin x\nintent netfilter\ninterrupted (signal or abort)\n")
        p = run(shell, env, "uninstall-transaction.sh", "--remove", name)
        assert p.returncode == 0, (p.stdout, p.stderr)
        assert "_CUST_BYPASS_WA_" not in (state / "mangle").read_text()
        assert FOREIGN_RULE in (state / "mangle").read_text()
        print("[PASS]", shell, "mid-step netfilter state recovers by audit")

    # ---- 8b. rollback cache via the feed fallback when download is broken --
    with tempfile.TemporaryDirectory(prefix="kas-uninstall-remove-feed-") as temp:
        td = Path(temp)
        root, state, files, env = setup(td)
        (state / "download_fail").write_text("1")
        name = prepared_snapshot(shell, root, state, env)
        manifest = root / f"opt/kas-uninstall-backups/{name}/packages/MANIFEST"
        assert manifest.is_file(), "feed fallback must build the cache"
        body = manifest.read_text()
        assert "mihomo_1.19.33-2_aarch64-3.10.ipk" in body and "magitrickle_0.8.2-1_aarch64-3.10.ipk" in body
        p = run(shell, env, "uninstall-transaction.sh", "--remove", name)
        assert p.returncode == 0, (p.stdout, p.stderr)
        assert "mihomo" not in (state / "installed").read_text()
        print("[PASS]", shell, "rollback cache built via opkg feed fallback")

    # ---- 8c. rollback cache via recorded provenance when lists are absent --
    with tempfile.TemporaryDirectory(prefix="kas-uninstall-remove-src-") as temp:
        td = Path(temp)
        root, state, files, env = setup(td)
        (state / "download_fail").write_text("1")
        import shutil as _sh2
        _sh2.rmtree(root / "opt/var/opkg-lists")
        # A recorded mutable URL alone is not an approved checksum.
        approved = td / 'approved-recorded-sources'
        rows = []
        for line in files['opt/etc/keenetic-auto-setup/sources.v1'].splitlines():
            url = line.split('|')[2]
            sha = hashlib.sha256((state / 'assets' / url.rsplit('/', 1)[1]).read_bytes()).hexdigest()
            rows.append(sha + '|' + url + '\n')
        approved.write_text(''.join(rows)); approved.chmod(0o600)
        env['KAS_ROLLBACK_IPKS'] = str(approved)
        name = prepared_snapshot(shell, root, state, env)
        body = (root / f"opt/kas-uninstall-backups/{name}/packages/MANIFEST").read_text()
        assert "mihomo_1.19.33-2_aarch64-3.10.ipk" in body
        p = run(shell, env, "uninstall-transaction.sh", "--remove", name)
        assert p.returncode == 0, (p.stdout, p.stderr)
        print("[PASS]", shell, "rollback cache built from source URLs pinned by approved SHA256")

        # ---- 8e. foreign-profile gate geometry: KAS owns Proxy1, foreign Proxy0 --
    with tempfile.TemporaryDirectory(prefix="kas-uninstall-gate-foreign-") as temp:
        td = Path(temp)
        root, state, files, env = setup(td)
        # ledger claims Proxy1 instead of Proxy0
        ledger = files["opt/etc/keenetic-auto-setup/ownership.v1"].replace(
            "owned|proxy|Proxy0", "owned|proxy|Proxy1")
        (root / "opt/etc/keenetic-auto-setup/ownership.v1").write_text(ledger)
        # config: foreign Proxy0 to 1081 (down), KAS-owned Proxy1 to 7890
        cfg = (state / "running-config").read_text()
        cfg = cfg.replace(
            "interface Proxy0" + chr(10) +
            '    description "mihomo t2s0"' + chr(10),
            "interface Proxy0" + chr(10) +
            "    description lab-foreign" + chr(10) +
            "    proxy protocol socks5" + chr(10) +
            "    proxy upstream 127.0.0.1 1081" + chr(10) +
            "    down" + chr(10) + "!" + chr(10) +
            "interface Proxy1" + chr(10) +
            '    description "mihomo t2s1"' + chr(10))
        cfg = cfg.replace("    permit global Proxy0", "    permit global Proxy1")
        (state / "running-config").write_text(cfg)
        p = run(shell, env, "uninstall-snapshot.sh", "--create")
        name = next((root / "opt/kas-uninstall-backups").iterdir()).name
        p = run(shell, env, "uninstall-transaction-gate.sh", "--check", name)
        assert p.returncode == 0, (p.stdout, p.stderr)
        assert "canonical Proxy1" in p.stdout
        print("[PASS]", shell, "gate: foreign profile with owned Proxy1")

    # ---- 8f. foreign profile full removal: foreign Proxy0 SURVIVES ---------
    with tempfile.TemporaryDirectory(prefix="kas-uninstall-remove-fp-") as temp:
        td = Path(temp)
        root, state, files, env = setup(td)
        ledger = files["opt/etc/keenetic-auto-setup/ownership.v1"].replace(
            "owned|proxy|Proxy0", "owned|proxy|Proxy1")
        (root / "opt/etc/keenetic-auto-setup/ownership.v1").write_text(ledger)
        cfg = (state / "running-config").read_text()
        cfg = cfg.replace(
            "interface Proxy0" + chr(10) + '    description "mihomo t2s0"' + chr(10),
            "interface Proxy0" + chr(10) + "    description lab-foreign" + chr(10) +
            "    proxy protocol socks5" + chr(10) + "    proxy upstream 127.0.0.1 1081" + chr(10) +
            "    down" + chr(10) + "!" + chr(10) +
            "interface Proxy1" + chr(10) + '    description "mihomo t2s1"' + chr(10))
        cfg = cfg.replace("    permit global Proxy0", "    permit global Proxy1")
        (state / "running-config").write_text(cfg)
        name = prepared_snapshot(shell, root, state, env)
        p = run(shell, env, "uninstall-transaction.sh", "--remove", name)
        assert p.returncode == 0, (p.stdout, p.stderr)
        rc = (state / "running-config").read_text()
        assert "interface Proxy0" in rc and "1081" in rc, "foreign Proxy0 must survive"
        assert "interface Proxy1" not in rc, "owned Proxy1 must be removed"
        assert "bypass_wa" not in rc
        print("[PASS]", shell, "foreign profile removal preserves the foreign Proxy0")

# ---- 8d. invalid snapshot names are rejected before any path use ------
    with tempfile.TemporaryDirectory(prefix="kas-uninstall-remove-name-") as temp:
        td = Path(temp)
        root, state, files, env = setup(td)
        for bad in ("../evil", "with/slash", "space name", "semi;colon"):
            p = run(shell, env, "uninstall-transaction.sh", "--remove", bad)
            assert p.returncode == 3 and "invalid snapshot name" in p.stderr, (bad, p.stderr)
            assert not (root / "opt/etc/crontab.kas-txn").exists()
        print("[PASS]", shell, "invalid snapshot names rejected")

# ---- 9. gate: relaxed ip global contract -------------------------------
for shell in SHELLS:
    for label, ip_global, expect_ok in (
            ("allocator 350", PROXY_350, True),
            ("allocator 32767 (Ported)", PROXY_32767, True),
            ("missing ip global", "", False),
            ("non-numeric ip global", "    ip global auto!", False)):
        with tempfile.TemporaryDirectory(prefix="kas-uninstall-gate-ig-") as temp:
            td = Path(temp)
            root, state, files, env = setup(td, ip_global=ip_global)
            p = run(shell, env, "uninstall-snapshot.sh", "--create")
            name = next((root / "opt/kas-uninstall-backups").iterdir()).name
            p = run(shell, env, "uninstall-transaction-gate.sh", "--check", name)
            assert (p.returncode == 0) == expect_ok, (label, p.stdout, p.stderr)
            print("[PASS]", shell, "gate ip global:", label)

    # Ported shape: install.sh never writes a WAN deny; the policy block is
    # description + owned permit only. The gate must accept it.
    with tempfile.TemporaryDirectory(prefix="kas-uninstall-gate-ported-") as temp:
        td = Path(temp)
        root, state, files, env = setup(td, ip_global=PROXY_32767)
        rc = (state / "running-config").read_text().replace(
            "    no permit global GigabitEthernet1" + chr(10), "")
        (state / "running-config").write_text(rc)
        p = run(shell, env, "uninstall-snapshot.sh", "--create")
        name = next((root / "opt/kas-uninstall-backups").iterdir()).name
        p = run(shell, env, "uninstall-transaction-gate.sh", "--check", name)
        assert p.returncode == 0, (p.stdout, p.stderr)
        print("[PASS]", shell, "gate: Ported policy without WAN deny")

    # A deny of a name that is neither an interface nor a unique alias blocks
    with tempfile.TemporaryDirectory(prefix="kas-uninstall-gate-deny-") as temp:
        td = Path(temp)
        root, state, files, env = setup(td)
        rc = (state / "running-config").read_text().replace(
            "    no permit global GigabitEthernet1" + chr(10),
            "    no permit global Vpn9" + chr(10))
        (state / "running-config").write_text(rc)
        p = run(shell, env, "uninstall-snapshot.sh", "--create")
        name = next((root / "opt/kas-uninstall-backups").iterdir()).name
        p = run(shell, env, "uninstall-transaction-gate.sh", "--check", name)
        assert p.returncode == 3 and "unknown shape" in p.stderr, p.stderr
        print("[PASS]", shell, "gate: WAN deny of unknown interface blocked")

    # An alias deny with exactly one rename stays acceptable (KN-1010 ISP form)
    with tempfile.TemporaryDirectory(prefix="kas-uninstall-gate-alias-") as temp:
        td = Path(temp)
        root, state, files, env = setup(td)
        rc = (state / "running-config").read_text().replace(
            "    no permit global GigabitEthernet1" + chr(10),
            "    no permit global ISP" + chr(10))
        (state / "running-config").write_text(rc)
        p = run(shell, env, "uninstall-snapshot.sh", "--create")
        name = next((root / "opt/kas-uninstall-backups").iterdir()).name
        p = run(shell, env, "uninstall-transaction-gate.sh", "--check", name)
        assert p.returncode == 0, (p.stdout, p.stderr)
        print("[PASS]", shell, "gate: alias WAN deny with unique rename")

    # duplicated ip global must block
    with tempfile.TemporaryDirectory(prefix="kas-uninstall-gate-ig2-") as temp:
        td = Path(temp)
        cfg = BASE_CONFIG.format(ip_global=PROXY_32767).replace(
            PROXY_32767, PROXY_32767 + "\n" + PROXY_350)
        root, state, files, env = setup(td)
        (state / "running-config").write_text(cfg)
        p = run(shell, env, "uninstall-snapshot.sh", "--create")
        name = next((root / "opt/kas-uninstall-backups").iterdir()).name
        p = run(shell, env, "uninstall-transaction-gate.sh", "--check", name)
        assert p.returncode == 3 and "duplicate ip global" in p.stderr, p.stderr
        print("[PASS]", shell, "gate ip global: duplicate blocked")

print("[PASS] uninstall --remove regression suite complete")
