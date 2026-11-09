#!/usr/bin/env python3
"""Offline regression for kas-universal-install.sh (hermetic mock Entware).

Every scenario runs the launcher against a private PATH holding only local
mocks and copies of read-only host tools, so no scenario can reach the
network or the host package manager: the mock curl serves staged bytes only
and the mock opkg logs mutating subcommands instead of running them.

Focus of the suite:
- check and doctor never run `opkg update`/`opkg install`;
- doctor without a usable curl refuses with actionable instructions;
- doctor with curl performs only the single pinned diagnostic download;
- installing modes (all|core|web) keep the permitted curl bootstrap, and
  the Web SHA-256 gate stays fail-closed.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

SRC = (Path(__file__).resolve().parents[1] / 'kas-universal-install.sh').read_text()
PATH_LINE = 'PATH=/opt/bin:/opt/sbin:/usr/bin:/usr/sbin:/bin:/sbin'

ABIS = ['aarch64-3.10', 'armv7-3.2', 'mipsel-3.4', 'mips-3.4',
        'mipsel-3.4_kn', 'unsupported-x', 'multiple']

# Read-only host tools the launcher may invoke. curl is deliberately NOT
# in this list: a "no curl" scenario must not see the host curl through
# PATH, and every download in every scenario comes from the local mock.
REAL_TOOLS = ['id', 'awk', 'sha256sum', 'df', 'grep', 'date', 'mktemp',
              'rm', 'rmdir', 'sh', 'wc', 'tr', 'cp', 'chmod']

OPKG_MOCK = '''#!/bin/sh
case "$1" in
  print-architecture)
    case "$TEST_ABI" in
      multiple) printf "arch all 1\\narch aarch64-3.10 10\\narch mipsel-3.4 10\\n" ;;
      *) printf "arch all 1\\narch %s 10\\n" "$TEST_ABI" ;;
    esac ;;
  status) exit 0 ;;
  update) echo update >> "$TEST_LOG" ;;
  install)
    echo install >> "$TEST_LOG"
    if [ "$2" = curl ] && [ -n "$TEST_MOCK_BIN" ] && [ -n "$TEST_CURL_TEMPLATE" ] \\
       && [ ! -x "$TEST_MOCK_BIN/curl" ]; then
      cp "$TEST_CURL_TEMPLATE" "$TEST_MOCK_BIN/curl"
      chmod 755 "$TEST_MOCK_BIN/curl"
    fi ;;
  *) echo "unexpected-opkg-$1" >&2; exit 91 ;;
esac
'''

# Dispatches on the requested URL basename (bootstrap.sh / web.ipk /
# mihomo-doctor.sh; the launcher stores doctor under WORK/doctor.sh, so
# the output path alone cannot identify it) and logs argv so tests can
# assert pinned refs and exact call counts. Trailing '*' is required:
# case patterns are end-anchored and curl argv ends with the -o path,
# not the URL. TEST_FAILCURL=1 emulates curl exit 22 without network.
CURL_MOCK = '''#!/bin/sh
if [ "$TEST_FAILCURL" = 1 ]; then exit 22; fi
ARGS="$*"
printf '%s\\n' "$ARGS" >> "$TEST_CURL_LOG"
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then
    shift
    case "$ARGS" in
      *mihomo-doctor.sh*) printf '#!/bin/sh\\necho DOCTOR_MOCK_RAN\\n' > "$1" ;;
      *bootstrap.sh*) printf '#!/bin/sh\\n# KAS_FIRSTFETCH_V1\\necho CORE_BOOTSTRAP_MOCK_RAN\\n' > "$1" ;;
      *.ipk*) printf 'badipk' > "$1" ;;
      *) printf 'unexpected-download-target' > "$1" ;;
    esac
    break
  fi
  shift
done
exit 0
'''


def run(mode, abi='mipsel-3.4', curl=True, failcurl=False, interpreter=('sh',)):
    """Run one launcher scenario against a hermetic mock root.

    Returns (returncode, combined output, opkg mutation events, curl call
    argument lines); the lists are empty unless the scenario actually
    mutated Entware or invoked curl. Logs are read before the temp dir is
    removed.
    """
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        bin_dir = root / 'bin'
        bin_dir.mkdir()
        for tool in REAL_TOOLS:
            host = shutil.which(tool)
            if not host:
                raise RuntimeError('host tool missing for hermetic PATH: %s' % tool)
            shutil.copy2(host, bin_dir / tool)
        (bin_dir / 'opkg').write_text(OPKG_MOCK)
        (bin_dir / 'opkg').chmod(0o755)
        curl_template = root / 'curl-template'
        curl_template.write_text(CURL_MOCK)
        if curl:
            shutil.copy2(curl_template, bin_dir / 'curl')
            (bin_dir / 'curl').chmod(0o755)
        # The launcher sleeps only between failed download retries; keep
        # it instant (busybox ash may bypass this shim and really sleep,
        # which the chosen ash scenarios never trigger).
        (bin_dir / 'sleep').write_text('#!/bin/sh\nexit 0\n')
        (bin_dir / 'sleep').chmod(0o755)
        patched = SRC.replace(PATH_LINE, 'PATH=%s' % bin_dir)
        assert patched != SRC, 'PATH shim site not found in launcher source'
        script = root / 'installer.sh'
        script.write_text(patched)
        opkg_log = root / 'opkg-mutations.log'
        curl_log = root / 'curl-calls.log'
        env = dict(os.environ, TEST_ABI=abi, TEST_LOG=str(opkg_log),
                   TEST_CURL_LOG=str(curl_log), TEST_MOCK_BIN=str(bin_dir),
                   TEST_CURL_TEMPLATE=str(curl_template),
                   TEST_FAILCURL='1' if failcurl else '0')
        proc = subprocess.run(list(interpreter) + [str(script), mode],
                              capture_output=True, text=True, env=env,
                              timeout=30)
        events = opkg_log.read_text().split() if opkg_log.exists() else []
        calls = curl_log.read_text().splitlines() if curl_log.exists() else []
        return proc.returncode, proc.stdout + proc.stderr, events, calls


def expect_check_read_only(abi):
    rc, out, events, calls = run('check', abi=abi, curl=False)
    expected = abi not in ('unsupported-x', 'multiple')
    assert (rc == 0) == expected, (abi, rc, out)
    assert events == [], abi
    assert calls == [], abi
    if expected:
        assert 'Entware ABI: %s' % abi.removesuffix('_kn') in out, (abi, out)


def expect_doctor_refusal(rc, out, events, calls):
    assert rc != 0, (rc, out)
    assert 'read-only' in out and 'curl' in out, out
    assert 'opkg update && opkg install curl' in out, out
    assert events == [], out
    assert calls == [], out


def expect_doctor_diagnostic(rc, out, events, calls):
    assert rc == 0, (rc, out)
    assert 'DOCTOR_MOCK_RAN' in out, out
    assert events == [], out
    assert len(calls) == 1, calls
    assert 'v1.8.8/mihomo-doctor.sh' in calls[0], calls


def expect_doctor_download_fail(rc, out, events, calls):
    assert rc != 0 and 'Doctor download failed' in out, (rc, out)
    assert events == [], out


def expect_core_bootstrap(rc, out, events, calls):
    assert rc == 0 and 'CORE_BOOTSTRAP_MOCK_RAN' in out, (rc, out)
    assert events == ['update', 'install'], out
    assert len(calls) == 1 and 'bootstrap.sh' in calls[0], calls


def expect_core_no_bootstrap(rc, out, events, calls):
    assert rc == 0 and 'CORE_BOOTSTRAP_MOCK_RAN' in out, (rc, out)
    assert events == [], out
    assert len(calls) == 1, out


def expect_all_bootstrap_and_hash_gate(rc, out, events, calls):
    assert rc != 0 and 'IPK SHA-256 mismatch' in out, (rc, out)
    assert events == ['update', 'install'], out
    assert len(calls) == 2, calls
    assert 'bootstrap.sh' in calls[0] and '.ipk' in calls[1], calls


def expect_web_hash_gate(rc, out, events, calls):
    assert rc != 0 and 'IPK SHA-256 mismatch' in out, (rc, out)
    assert events == [], out


def expect_web_curl_fail(rc, out, events, calls):
    assert rc != 0 and 'No verified Web IPK obtained' in out, (rc, out)
    assert events == [], out


for abi in ABIS:
    expect_check_read_only(abi)
    print(abi, 'PASS')

SCENARIOS = [
    ('doctor no-curl refusal',
     dict(mode='doctor', curl=False), expect_doctor_refusal),
    ('doctor with-curl diagnostic only',
     dict(mode='doctor', curl=True), expect_doctor_diagnostic),
    ('doctor download-failure stays read-only',
     dict(mode='doctor', curl=True, failcurl=True), expect_doctor_download_fail),
    ('core bootstrap retained without curl',
     dict(mode='core', curl=False), expect_core_bootstrap),
    ('core with-curl skips bootstrap',
     dict(mode='core', curl=True), expect_core_no_bootstrap),
    ('all bootstrap retained + web hash gate fail-closed',
     dict(mode='all', curl=False), expect_all_bootstrap_and_hash_gate),
    ('web invalid-hash fail-closed',
     dict(mode='web', curl=True), expect_web_hash_gate),
    ('web curl-failure fail-closed',
     dict(mode='web', curl=True, failcurl=True), expect_web_curl_fail),
]

for name, kwargs, check in SCENARIOS:
    check(*run(**kwargs))
    print(name, 'PASS')

# Key boundary scenarios again under BusyBox ash, when a busybox binary is
# available (POSIX sh paths are covered above).
if shutil.which('busybox'):
    for name, kwargs, check in SCENARIOS:
        check(*run(interpreter=('busybox', 'ash'), **kwargs))
        print(name, 'PASS (busybox ash)')
else:
    print('busybox ash: not available on this host; sh scenarios only')
