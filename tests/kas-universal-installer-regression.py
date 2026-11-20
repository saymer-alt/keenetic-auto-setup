#!/usr/bin/env python3
"""Offline regression for kas-universal-install.sh (hermetic mock Entware).

Every scenario runs the launcher against a private PATH holding only local
mocks and copies of read-only host tools, so no scenario can reach the
network or the host package manager: the mock curl serves staged bytes only
and the mock opkg logs mutating subcommands instead of running them.

Focus of the suite:
- static pin integrity: the launcher's commit URL and SHA256 constants must
  stay exactly the values verified against the real v1.8.8 blobs;
- check and doctor never run `opkg update`/`opkg install`;
- doctor without a usable curl refuses with actionable instructions;
- doctor with curl performs only the single pinned diagnostic download;
- launcher-fetched scripts (bootstrap.sh, mihomo-doctor.sh) execute only
  after passing the pinned SHA256 gate: tampered (marker-passing but
  malicious), HTML, empty and oversized payloads must all be refused with
  zero opkg mutations and none of the payload bytes running;
- installing modes (all|core|web) keep the permitted curl bootstrap, and
  the Web SHA-256 gate stays fail-closed;
- an existing user YAML is backed up before the first download attempt
  and survives transport failure and tampered-payload refusal, while a
  symlinked config.yaml is refused with the target untouched and no
  backup taken. Every scenario runs against a private stand-in directory
  for /opt/etc/mihomo (empty unless the scenario stages user YAML), so no
  run depends on or mutates the host /opt; the canonical path, the symlink
  guard and the backup-before-download order are pinned statically.
"""
from pathlib import Path
import base64
import hashlib
import os
import re
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

# Ground truth for the pre-execution authenticity pins, verified 2026-11-09
# against tag v1.8.8 (a lightweight tag resolving to CORE_COMMIT): the
# bootstrap.sh / mihomo-doctor.sh bytes were fetched through two independent
# channels (GitHub Contents API base64 and raw.githubusercontent.com), are
# byte-identical across channels (cmp), and hash to the digests below. The
# static test refuses any launcher edit that drifts these constants without
# consciously re-verifying the pinned blobs.
REAL_CORE_COMMIT = 'c80e47c7050a31f70f65312dcd8999bfb13c9bef'
REAL_BOOTSTRAP_SHA256 = ('853e4badf57ee3a2065953a87caed3000'
                         '93adc68c971294a973d93f531dc697c')
REAL_DOCTOR_SHA256 = ('10cb06803ed712cb50cc1be44a8d3fa75ce5a'
                      '58dbbcf65ed99a60f671f5e0fb1')

# Exact bootstrap.sh bytes served for CORE_COMMIT (4214 bytes), embedded so
# the suite can re-hash the real pinned content offline and prove the pin
# stays source-grounded. mihomo-doctor.sh (173483 bytes) is too large to
# embed; its digest literal is anchored by expect_static_pins instead.
REAL_BOOTSTRAP_B64 = '''
IyEvYmluL3NoCiMgS0FTX0ZJUlNURkVUQ0hfVjEKIyBLQVMgcHVibGljIGVudHJ5IHBvaW50LiBU
aGUgc2hvcnQgSFRUUFMgaW5zdGFsbGF0aW9uIGNvbW1hbmQgc3RyZWFtcyBUSElTCiMgaW5pdGlh
bCBsYXVuY2hlciB0byBzaCAoYW4gZXhwbGljaXRseSBhY2NlcHRlZCBmaXJzdC1mZXRjaCByaXNr
KS4KIyBUaGlzIGxhdW5jaGVyIGRvd25sb2FkcyBzZXR1cC5zaCBpbnRvIGEgcHJpdmF0ZSB0ZW1w
b3JhcnkgZmlsZSwgdmFsaWRhdGVzCiMgdGhlIGZ1bGwgY2FuZGlkYXRlIGJlZm9yZSBleGVjdXRp
b24sIGFuZCB1c2VzIEdpdEh1YiB0cmFuc3BvcnQgZmFsbGJhY2tzLgojIE5vIHNldHVwLnNoIHJl
bW90ZSBieXRlcyBhcmUgcGlwZWQgZGlyZWN0bHkgaW50byBzaC4KIyAtLXNjcmlwdCBjb25maWct
aW1wb3J0LnNoIHNlbGVjdHMgdGhlIHN0YW5kYWxvbmUgWUFNTCBpbXBvcnRlciBpbnN0ZWFkOgoj
IHRoZSBzYW1lIHByaXZhdGUgc3RhZ2luZywgdHJhbnNwb3J0IGZhbGxiYWNrcyBhbmQgcHJlLWV4
ZWN1dGlvbiBjaGVja3MsCiMgc28gYSBtaWQtc3RyZWFtIGZhaWx1cmUgb2YgdGhlIGxhcmdlIGlt
cG9ydGVyIGNhbiBubyBsb25nZXIgZXhlY3V0ZSBhcyBhCiMgcGFydGlhbGx5IGRlbGl2ZXJlZCBj
dXJsLXRvLXNoIHN0cmVhbSAoaXNzdWUgIzI1NSkuCnNldCAtdQoKQ0hFQ0tfT05MWT0wClNDUklQ
VD1zZXR1cC5zaAp3aGlsZSBbICIkIyIgLWd0IDAgXTsgZG8KICAgIGNhc2UgIiQxIiBpbgogICAg
ICAgIC0tY2hlY2spIENIRUNLX09OTFk9MSA7OwogICAgICAgIC0tc2NyaXB0KQogICAgICAgICAg
ICBpZiBbICIkIyIgLWx0IDIgXTsgdGhlbgogICAgICAgICAgICAgICAgcHJpbnRmICdbRVJST1Jd
IC0tc2NyaXB0IHJlcXVpcmVzIGEgc2NyaXB0IG5hbWVcbicgPiYyCiAgICAgICAgICAgICAgICBl
eGl0IDIKICAgICAgICAgICAgZmkKICAgICAgICAgICAgY2FzZSAiJDIiIGluCiAgICAgICAgICAg
ICAgICBjb25maWctaW1wb3J0LnNoKSBTQ1JJUFQ9Y29uZmlnLWltcG9ydC5zaCA7OwogICAgICAg
ICAgICAgICAgKikKICAgICAgICAgICAgICAgICAgICBwcmludGYgJ1tFUlJPUl0gVW5zdXBwb3J0
ZWQgLS1zY3JpcHQ6ICVzXG4nICIkMiIgPiYyCiAgICAgICAgICAgICAgICAgICAgZXhpdCAyCiAg
ICAgICAgICAgICAgICAgICAgOzsKICAgICAgICAgICAgZXNhYwogICAgICAgICAgICBzaGlmdAog
ICAgICAgICAgICA7OwogICAgICAgICopIHByaW50ZiAnW0VSUk9SXSBVc2FnZTogYm9vdHN0cmFw
LnNoIFstLWNoZWNrXSBbLS1zY3JpcHQgY29uZmlnLWltcG9ydC5zaF1cbicgPiYyOyBleGl0IDIg
OzsKICAgIGVzYWMKICAgIHNoaWZ0CmRvbmUKClJFRj0ke0tBU19CT09UU1RSQVBfUkVGOi1zdGFi
bGV9CmNhc2UgIiRSRUYiIGluCiAgICAnJ3wvKnwqL3wqLi4qfCpbIUEtWmEtejAtOS5fLy1dKikK
ICAgICAgICBwcmludGYgJ1tFUlJPUl0gSW52YWxpZCBLQVNfQk9PVFNUUkFQX1JFRlxuJyA+JjIK
ICAgICAgICBleGl0IDIKICAgICAgICA7Owplc2FjCgpSQVc9Imh0dHBzOi8vcmF3LmdpdGh1YnVz
ZXJjb250ZW50LmNvbS9zYXltZXItYWx0L2tlZW5ldGljLWF1dG8tc2V0dXAvJFJFRi8kU0NSSVBU
IgpBUEk9Imh0dHBzOi8vYXBpLmdpdGh1Yi5jb20vcmVwb3Mvc2F5bWVyLWFsdC9rZWVuZXRpYy1h
dXRvLXNldHVwL2NvbnRlbnRzLyRTQ1JJUFQ/cmVmPSRSRUYiCgpjb21tYW5kIC12IGN1cmwgPi9k
ZXYvbnVsbCAyPiYxIHx8IHsKICAgIHByaW50ZiAnW0VSUk9SXSBjdXJsIGlzIHJlcXVpcmVkOiBv
cGtnIHVwZGF0ZSAmJiBvcGtnIGluc3RhbGwgY3VybFxuJyA+JjIKICAgIGV4aXQgMQp9CmNvbW1h
bmQgLXYgbWt0ZW1wID4vZGV2L251bGwgMj4mMSB8fCB7CiAgICBwcmludGYgJ1tFUlJPUl0gbWt0
ZW1wIGlzIHJlcXVpcmVkIGZvciBhIHByaXZhdGUgZG93bmxvYWRcbicgPiYyCiAgICBleGl0IDEK
fQoKdW1hc2sgMDc3ClNUQUdFPSQobWt0ZW1wICIke1RNUERJUjotL3RtcH0va2FzLXNldHVwLlhY
WFhYWFhYIikgfHwgewogICAgcHJpbnRmICdbRVJST1JdIENhbm5vdCBjcmVhdGUgcHJpdmF0ZSBz
ZXR1cCBzdGFnaW5nIGZpbGVcbicgPiYyCiAgICBleGl0IDEKfQp0cmFwICdybSAtZiAiJFNUQUdF
IicgMAp0cmFwICdleGl0IDEyOScgSFVQCnRyYXAgJ2V4aXQgMTMwJyBJTlQKdHJhcCAnZXhpdCAx
NDMnIFRFUk0KCnZhbGlkX3NjcmlwdCgpIHsKICAgIFsgLXMgIiRTVEFHRSIgXSB8fCByZXR1cm4g
MQogICAgWyAiJChoZWFkIC1uIDEgIiRTVEFHRSIgMj4vZGV2L251bGwpIiA9ICcjIS9iaW4vc2gn
IF0gfHwgcmV0dXJuIDEKICAgICMgVmVyaWZ5IHRoZSByZXR1cm5lZCBmaWxlIGlzIHRoaXMgcHJv
amVjdCdzIHJlYWwgZW50cnkgcG9pbnQsCiAgICAjIG5vdCBhbiBIVE1MLCBKU09OLCBvciB1bnJl
bGF0ZWQgc3ludGFjdGljYWxseSB2YWxpZCBzaGVsbCByZXNwb25zZS4KICAgICMgRWFjaCBzdXBw
b3J0ZWQgc2NyaXB0IGtlZXBzIGl0cyBvd24gc3RhYmxlIG1hcmtlcnMuCiAgICBjYXNlICIkU0NS
SVBUIiBpbgogICAgICAgIHNldHVwLnNoKQogICAgICAgICAgICBncmVwIC1GcSAnUFJPSkVDVF9B
UElfQ09OVEVOVFM9JyAiJFNUQUdFIiB8fCByZXR1cm4gMQogICAgICAgICAgICBncmVwIC1GcSAn
ZG93bmxvYWRfcHJvamVjdF9zY3JpcHQnICIkU1RBR0UiIHx8IHJldHVybiAxCiAgICAgICAgICAg
IDs7CiAgICAgICAgY29uZmlnLWltcG9ydC5zaCkKICAgICAgICAgICAgZ3JlcCAtRnEgJ0JFR0lO
IE1JSE9NTyBMSUZFQ1lDTEUgTE9DSyB2MScgIiRTVEFHRSIgfHwgcmV0dXJuIDEKICAgICAgICAg
ICAgZ3JlcCAtRnEgJ21peGVkLXBvcnQ6IDc4OTAnICIkU1RBR0UiIHx8IHJldHVybiAxCiAgICAg
ICAgICAgIDs7CiAgICBlc2FjCiAgICBzaCAtbiAiJFNUQUdFIiA+L2Rldi9udWxsIDI+JjEgfHwg
cmV0dXJuIDEKfQoKZmV0Y2goKSB7CiAgICBfbGFiZWw9JDEKICAgIHNoaWZ0CiAgICA6ID4gIiRT
VEFHRSIgfHwgcmV0dXJuIDEKICAgIHByaW50ZiAnW2Jvb3RzdHJhcF0gRG93bmxvYWRpbmcgJXMg
dmlhICVzIChjb25uZWN0IDdzLCB0b3RhbCAyNXMpLi4uXG4nICIkU0NSSVBUIiAiJF9sYWJlbCIK
ICAgIGN1cmwgLWZTc0wgLS1jb25uZWN0LXRpbWVvdXQgNyAtLW1heC10aW1lIDI1ICIkQCIgLW8g
IiRTVEFHRSIKICAgIF9yYz0kPwogICAgaWYgWyAiJF9yYyIgLW5lIDAgXTsgdGhlbgogICAgICAg
IHByaW50ZiAnW1dBUk5dICVzOiBjdXJsIGZhaWxlZCAoZXhpdCAlcylcbicgIiRfbGFiZWwiICIk
X3JjIiA+JjIKICAgICAgICByZXR1cm4gMQogICAgZmkKICAgIGlmICEgdmFsaWRfc2NyaXB0OyB0
aGVuCiAgICAgICAgcHJpbnRmICdbV0FSTl0gJXM6IGVtcHR5L2ludmFsaWQgcmVzcG9uc2Ugb3Ig
c2hlbGwgc3ludGF4OyByZWZ1c2luZyBleGVjdXRpb25cbicgIiRfbGFiZWwiID4mMgogICAgICAg
IHJldHVybiAxCiAgICBmaQogICAgcHJpbnRmICdbYm9vdHN0cmFwXSBWYWxpZGF0ZWQgc291cmNl
IGZyb20gJXNcbicgIiRfbGFiZWwiCiAgICByZXR1cm4gMAp9CgppZiBmZXRjaCAnR2l0SHViIHJh
dycgIiRSQVciIHx8CiAgIGZldGNoICdHaXRIdWIgcmF3IElQdjQvWDI1NTE5JyAtNCAtLWN1cnZl
cyBYMjU1MTkgIiRSQVciIHx8CiAgIGZldGNoICdHaXRIdWIgQ29udGVudHMgQVBJJyAtNCAtSCAn
QWNjZXB0OiBhcHBsaWNhdGlvbi92bmQuZ2l0aHViLnJhdytqc29uJyBcCiAgICAgICAtSCAnWC1H
aXRIdWItQXBpLVZlcnNpb246IDIwMjItMTEtMjgnICIkQVBJIjsgdGhlbgogICAgaWYgWyAiJENI
RUNLX09OTFkiIC1lcSAxIF07IHRoZW4KICAgICAgICBwcmludGYgJ1tib290c3RyYXBdIENIRUNL
X09OTFk6ICVzIHZlcmlmaWVkIGZvciByZWYgJXM7IG5vdGhpbmcgZXhlY3V0ZWRcbicgIiRTQ1JJ
UFQiICIkUkVGIgogICAgICAgIGV4aXQgMAogICAgZmkKICAgIHByaW50ZiAnW2Jvb3RzdHJhcF0g
RXhlY3V0aW5nIHZhbGlkYXRlZCAlcyAocmVmOiAlcylcbicgIiRTQ1JJUFQiICIkUkVGIgogICAg
c2ggIiRTVEFHRSIKICAgIF9yYz0kPwogICAgcHJpbnRmICdbYm9vdHN0cmFwXSAlcyBmaW5pc2hl
ZCAoZXhpdCAlcylcbicgIiRTQ1JJUFQiICIkX3JjIgogICAgZXhpdCAiJF9yYyIKZmkKCnByaW50
ZiAnW0VSUk9SXSBDb3VsZCBub3QgZmV0Y2ggdmFsaWQgS0FTICVzIGZyb20gcmF3IG9yIENvbnRl
bnRzIEFQSTsgbm8gc2NyaXB0IGV4ZWN1dGVkLlxuJyAiJFNDUklQVCIgPiYyCmV4aXQgMQo='''
REAL_BOOTSTRAP_CONTENT = base64.b64decode(''.join(REAL_BOOTSTRAP_B64.split()))

# Payloads the mock curl serves per scenario. The happy payloads carry the
# execution markers the expect_* helpers assert on; run() patches the
# launcher's pinned digests to the SHA256 of the exact payloads below, so
# "served bytes" and "pinned bytes" always agree per scenario.
HAPPY_BOOTSTRAP = b'#!/bin/sh\n# KAS_FIRSTFETCH_V1\necho CORE_BOOTSTRAP_MOCK_RAN\n'
HAPPY_DOCTOR = b'#!/bin/sh\necho DOCTOR_MOCK_RAN\n'
# Tampered payloads keep whatever cheaper checks would accept (the bootstrap
# marker) but carry live canaries: if a single byte of them ever ran, the
# mock opkg would log `update` and stdout would show TAMPER_EXECUTED.
TAMPERED_BOOTSTRAP = b'#!/bin/sh\n# KAS_FIRSTFETCH_V1\nopkg update\necho TAMPER_EXECUTED\n'
TAMPERED_DOCTOR = b'#!/bin/sh\nopkg update\necho DOCTOR_TAMPERED\n'
HTML_PAYLOAD = b'<html><body>503 Service Unavailable</body></html>\n'
OVERSIZE_TAIL = b'#' * (1 << 20)
OVERSIZE_BOOTSTRAP = HAPPY_BOOTSTRAP + OVERSIZE_TAIL
OVERSIZE_DOCTOR = HAPPY_DOCTOR + OVERSIZE_TAIL

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
# the output path alone cannot identify it) and copies the per-scenario
# served-payload file the Python harness staged. The launcher's pin is
# patched to the digest of the scenario's legitimate payload, so tamper/
# HTML/empty/oversize scenarios serve bytes that differ from the pin and
# exercise the real refusal path. Trailing '*' is required: case patterns
# are end-anchored and curl argv ends with the -o path, not the URL.
# TEST_FAILCURL=1 emulates curl exit 22 without network. The mock does not
# emulate curl's --max-filesize, so oversize scenarios exercise the
# launcher's own byte-count gate. Call arguments are logged before the
# simulated failure, so bounded-retry behavior stays observable even when
# every attempt fails.
CURL_MOCK = '''#!/bin/sh
ARGS="$*"
printf '%s\\n' "$ARGS" >> "$TEST_CURL_LOG"
if [ "$TEST_FAILCURL" = 1 ]; then exit 22; fi
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then
    shift
    case "$ARGS" in
      *mihomo-doctor.sh*) cp "$TEST_DOCTOR_PAYLOAD" "$1" ;;
      *bootstrap.sh*) cp "$TEST_BOOTSTRAP_PAYLOAD" "$1" ;;
      *.ipk*) printf 'badipk' > "$1" ;;
      *) printf 'unexpected-download-target' > "$1" ;;
    esac
    break
  fi
  shift
done
exit 0
'''

# User YAML fixture for the preservation scenarios. The launcher hard-codes
# /opt/etc/mihomo, so run() always patches every occurrence in the test copy
# to a private stand-in directory inside the scenario temp root; yaml_fixture
# stages the fixture bytes there. The real canonical path, its symlink guard
# and the backup-before-download order stay pinned on the unpatched source by
# expect_static_yaml_guards.
YAML_CONFIG = b'proxies: []\nproxy-groups: []\nrules: []\nmixed-port: 7890\n'
YAML_FIXTURE_FILE = {'config': YAML_CONFIG}      # plain existing user YAML
YAML_FIXTURE_SYMLINK = {'symlink': YAML_CONFIG}  # config.yaml -> real.yaml

# Post-run byte snapshot of the most recent yaml_fixture stand-in directory
# (name -> bytes, or 'symlink-><target>'), captured inside run() before the
# temp root vanishes. Only safe because the scenario loop is strictly
# sequential: each yaml_* expect_ helper reads it immediately after its own
# run() call. Cleared on every yaml_fixture run.
YAML_STATE = {}


def snapshot_yaml_dir(cfg_dir):
    """Byte snapshot of the private YAML stand-in before the temp root dies."""
    snap = {}
    for entry in sorted(cfg_dir.iterdir()):
        if entry.is_symlink():
            snap[entry.name] = 'symlink->' + os.readlink(entry)
        elif entry.is_file():
            snap[entry.name] = entry.read_bytes()
    return snap


def run(mode, abi='mipsel-3.4', curl=True, failcurl=False,
        bootstrap_payload=HAPPY_BOOTSTRAP, doctor_payload=HAPPY_DOCTOR,
        bootstrap_served=None, doctor_served=None, interpreter=('sh',),
        yaml_fixture=None):
    """Run one launcher scenario against a hermetic mock root.

    *_payload is the scenario's legitimate expected content: the launcher's
    pinned digest constants are patched to its SHA256. *_served is what the
    mock curl actually delivers (defaults to the payload); a served value
    that differs from the pin drives the tamper/HTML/empty/oversize refusal
    paths. Every scenario runs against a private stand-in for the hard-coded
    /opt/etc/mihomo: all canonical-path occurrences are patched to a private
    temp directory, keeping runs off the host /opt whatever exists there;
    yaml_fixture stages user YAML into that stand-in (YAML_FIXTURE_FILE:
    plain config bytes; YAML_FIXTURE_SYMLINK: symlinked config.yaml) and its
    post-run bytes land in YAML_STATE. Returns (returncode,
    combined output, opkg mutation events, curl call argument lines); the
    lists are empty unless the scenario actually mutated Entware or invoked
    curl. Logs are read before the temp dir is removed.
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
        bootstrap_payload_file = root / 'bootstrap-payload'
        bootstrap_payload_file.write_bytes(bootstrap_payload)
        doctor_payload_file = root / 'doctor-payload'
        doctor_payload_file.write_bytes(doctor_payload)
        served_bootstrap_file = root / 'bootstrap-served'
        served_bootstrap_file.write_bytes(
            bootstrap_served if bootstrap_served is not None else bootstrap_payload)
        served_doctor_file = root / 'doctor-served'
        served_doctor_file.write_bytes(
            doctor_served if doctor_served is not None else doctor_payload)
        patched = SRC.replace(PATH_LINE, 'PATH=%s' % bin_dir)
        assert patched != SRC, 'PATH shim site not found in launcher source'
        patched, n = re.subn(r'CORE_BOOTSTRAP_SHA256=[0-9a-f]{64}',
                             'CORE_BOOTSTRAP_SHA256=%s'
                             % hashlib.sha256(bootstrap_payload).hexdigest(),
                             patched)
        assert n == 1, 'bootstrap digest pin site not found in launcher source'
        patched, n = re.subn(r'CORE_DOCTOR_SHA256=[0-9a-f]{64}',
                             'CORE_DOCTOR_SHA256=%s'
                             % hashlib.sha256(doctor_payload).hexdigest(),
                             patched)
        assert n == 1, 'doctor digest pin site not found in launcher source'
        cfg_dir = root / 'opt-etc-mihomo'
        cfg_dir.mkdir()
        if yaml_fixture is not None:
            if 'config' in yaml_fixture:
                (cfg_dir / 'config.yaml').write_bytes(yaml_fixture['config'])
            if 'symlink' in yaml_fixture:
                (cfg_dir / 'real.yaml').write_bytes(yaml_fixture['symlink'])
                (cfg_dir / 'config.yaml').symlink_to('real.yaml')
        assert patched.count('/opt/etc/mihomo') >= 1, \
            'canonical YAML path missing from launcher source'
        patched = patched.replace('/opt/etc/mihomo', str(cfg_dir))
        script = root / 'installer.sh'
        script.write_text(patched)
        opkg_log = root / 'opkg-mutations.log'
        curl_log = root / 'curl-calls.log'
        env = dict(os.environ, TEST_ABI=abi, TEST_LOG=str(opkg_log),
                   TEST_CURL_LOG=str(curl_log), TEST_MOCK_BIN=str(bin_dir),
                   TEST_CURL_TEMPLATE=str(curl_template),
                   TEST_BOOTSTRAP_PAYLOAD=str(served_bootstrap_file),
                   TEST_DOCTOR_PAYLOAD=str(served_doctor_file),
                   TEST_FAILCURL='1' if failcurl else '0')
        proc = subprocess.run(list(interpreter) + [str(script), mode],
                              capture_output=True, text=True, env=env,
                              timeout=30)
        if yaml_fixture is not None:
            YAML_STATE.clear()
            YAML_STATE.update(snapshot_yaml_dir(cfg_dir))
        events = opkg_log.read_text().split() if opkg_log.exists() else []
        calls = curl_log.read_text().splitlines() if curl_log.exists() else []
        return proc.returncode, proc.stdout + proc.stderr, events, calls


def expect_static_pins():
    """Offline integrity anchors, no launcher execution involved: the pinned
    constants must stay the verified v1.8.8 values, script downloads must
    use the immutable commit URL (never the mutable tag), and the embedded
    real bootstrap bytes must still hash to the pinned digest."""
    m = re.search(r'^CORE_COMMIT=([0-9a-f]{40})$', SRC, re.M)
    assert m and m.group(1) == REAL_CORE_COMMIT, 'CORE_COMMIT drifted'
    m = re.search(r'^CORE_BOOTSTRAP_SHA256=([0-9a-f]{64})$', SRC, re.M)
    assert m and m.group(1) == REAL_BOOTSTRAP_SHA256, 'bootstrap pin drifted'
    m = re.search(r'^CORE_DOCTOR_SHA256=([0-9a-f]{64})$', SRC, re.M)
    assert m and m.group(1) == REAL_DOCTOR_SHA256, 'doctor pin drifted'
    assert 'RAW/$CORE_COMMIT/bootstrap.sh' in SRC, 'bootstrap download not commit-pinned'
    assert 'RAW/$CORE_COMMIT/mihomo-doctor.sh' in SRC, 'doctor download not commit-pinned'
    assert '$CORE_REF/bootstrap.sh' not in SRC, 'mutable-tag bootstrap download present'
    assert '$CORE_REF/mihomo-doctor.sh' not in SRC, 'mutable-tag doctor download present'
    assert 'KAS_BOOTSTRAP_REF="$CORE_COMMIT" KEENETIC_AUTO_SETUP_REF="$CORE_COMMIT"' in SRC, (
        'downstream setup/install refs must be pinned to immutable Core commit')
    assert 'KAS_BOOTSTRAP_REF="$CORE_REF" KEENETIC_AUTO_SETUP_REF="$CORE_REF"' not in SRC, (
        'mutable release tag must not be forwarded to bootstrap')
    assert hashlib.sha256(REAL_BOOTSTRAP_CONTENT).hexdigest() == REAL_BOOTSTRAP_SHA256
    assert b'KAS_FIRSTFETCH_V1' in REAL_BOOTSTRAP_CONTENT


def expect_static_yaml_guards():
    """The unpatched launcher must keep the YAML-preservation contract on the
    canonical Entware path: symlink refusal and a collision-guarded backup
    taken strictly before the first download attempt, with the retry loop
    bounded at three attempts. The dynamic yaml_* scenarios run against a
    patched stand-in directory; this check pins the production path itself."""
    assert SRC.count('/opt/etc/mihomo') == 4, 'canonical YAML path sites drifted'
    at = SRC.index('[ -f /opt/etc/mihomo/config.yaml ]')
    link = SRC.index("[ ! -L /opt/etc/mihomo/config.yaml ] || fail "
                     "'Mihomo config.yaml is a symlink")
    cp = SRC.index('cp -p /opt/etc/mihomo/config.yaml')
    dl = SRC.index('Downloading pinned KAS Core bootstrap')
    assert at < link < cp < dl, \
        'symlink guard and backup must precede the bootstrap download'
    assert 'Backup already exists' in SRC, 'backup collision guard missing'
    assert 'Saved existing Mihomo YAML' in SRC, 'backup confirmation missing'
    assert 'Core bootstrap download failed after three attempts' in SRC, \
        'bootstrap retry bound drifted'


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
    assert REAL_CORE_COMMIT in calls[0] and 'mihomo-doctor.sh' in calls[0], calls


def expect_doctor_download_fail(rc, out, events, calls):
    assert rc != 0 and 'Doctor download failed' in out, (rc, out)
    assert events == [], out


def expect_core_bootstrap(rc, out, events, calls):
    assert rc == 0 and 'CORE_BOOTSTRAP_MOCK_RAN' in out, (rc, out)
    assert events == ['update', 'install'], out
    assert len(calls) == 1, calls
    assert REAL_CORE_COMMIT in calls[0] and 'bootstrap.sh' in calls[0], calls


def expect_core_no_bootstrap(rc, out, events, calls):
    assert rc == 0 and 'CORE_BOOTSTRAP_MOCK_RAN' in out, (rc, out)
    assert events == [], out
    assert len(calls) == 1, calls
    assert REAL_CORE_COMMIT in calls[0] and 'bootstrap.sh' in calls[0], calls


def expect_bootstrap_digest_refusal(rc, out, events, calls):
    assert rc != 0 and 'Bootstrap SHA-256 mismatch' in out, (rc, out)
    assert 'TAMPER_EXECUTED' not in out, out
    assert events == [], out  # tampered payload contained `opkg update`
    assert len(calls) == 1, calls


def expect_doctor_digest_refusal(rc, out, events, calls):
    assert rc != 0 and 'Doctor SHA-256 mismatch' in out, (rc, out)
    assert 'DOCTOR_TAMPERED' not in out, out
    assert events == [], out  # tampered payload contained `opkg update`
    assert len(calls) == 1, calls


def expect_bootstrap_html_refusal(rc, out, events, calls):
    assert rc != 0 and 'HTML/404 error page' in out, (rc, out)
    assert events == [], out
    assert len(calls) == 1, calls


def expect_doctor_html_refusal(rc, out, events, calls):
    assert rc != 0 and 'HTML/404 error page' in out, (rc, out)
    assert events == [], out
    assert len(calls) == 1, calls


def expect_bootstrap_empty_refusal(rc, out, events, calls):
    assert rc != 0 and 'Empty bootstrap' in out, (rc, out)
    assert events == [], out
    assert len(calls) == 1, calls


def expect_bootstrap_oversize_refusal(rc, out, events, calls):
    assert rc != 0 and 'over the size limit' in out, (rc, out)
    assert events == [], out
    assert len(calls) == 1, calls


def expect_doctor_oversize_refusal(rc, out, events, calls):
    assert rc != 0 and 'over the size limit' in out, (rc, out)
    assert events == [], out
    assert len(calls) == 1, calls


def expect_all_bootstrap_and_hash_gate(rc, out, events, calls):
    assert rc != 0 and 'IPK SHA-256 mismatch' in out, (rc, out)
    assert events == ['update', 'install'], out
    assert len(calls) == 2, calls
    assert REAL_CORE_COMMIT in calls[0] and 'bootstrap.sh' in calls[0], calls
    assert '.ipk' in calls[1], calls


def expect_web_hash_gate(rc, out, events, calls):
    assert rc != 0 and 'IPK SHA-256 mismatch' in out, (rc, out)
    assert events == [], out


def expect_web_curl_fail(rc, out, events, calls):
    assert rc != 0 and 'No verified Web IPK obtained' in out, (rc, out)
    assert events == [], out


def expect_real_bootstrap_gate(rc, out, events, calls):
    """Real v1.8.8 bootstrap bytes against the real pin (the patched digest
    equals the launcher's static constant): the gate must accept them and
    hand over to bootstrap execution. The trust boundary stays visible:
    bootstrap's own setup.sh fetch uses the forwarded immutable commit ref
    and is refused by the mock transport, so the run fails before any opkg
    mutation — acceptance of bootstrap bytes does not imply downstream
    setup.sh payload bytes were individually SHA256-checked."""
    assert rc != 0, (rc, out)
    assert 'bootstrap.sh: OK' in out and 'SHA-256 mismatch' not in out, out
    assert '[bootstrap] Downloading setup.sh' in out, out
    assert events == [], out
    assert len(calls) == 4, calls  # pinned bootstrap + 3 setup.sh transports
    assert REAL_CORE_COMMIT in calls[0], calls
    assert REAL_CORE_COMMIT + '/setup.sh' in calls[1], calls  # immutable ref
    assert 'v1.8.8/setup.sh' not in calls[1], calls


def expect_yaml_preserved_transport_fail(rc, out, events, calls):
    """Transport failure during bootstrap download: the user YAML was saved
    before the first attempt and is untouched afterwards, exactly one
    backup holds its original bytes, and the wait is bounded at the three
    announced attempts (no fourth curl call)."""
    assert rc != 0 and 'Core bootstrap download failed after three attempts' in out, (rc, out)
    assert 'Saved existing Mihomo YAML' in out, out
    assert 'CORE_BOOTSTRAP_MOCK_RAN' not in out, out
    assert events == [], out
    assert len(calls) == 3, calls
    assert all('bootstrap.sh' in c and REAL_CORE_COMMIT in c for c in calls), calls
    snap = YAML_STATE
    assert snap.get('config.yaml') == YAML_CONFIG, snap
    backups = [k for k in snap if k.startswith('config.yaml.pre-kas-')]
    assert len(backups) == 1 and snap[backups[0]] == YAML_CONFIG, snap
    assert len(snap) == 2, snap  # no stray files written into the config dir


def expect_yaml_preserved_tamper_refusal(rc, out, events, calls):
    """Tampered bootstrap payload: refusal happens before execution and the
    pre-download backup plus the user YAML both survive byte-identical (the
    served payload carried a live `opkg update` canary that must not fire)."""
    assert rc != 0 and 'Bootstrap SHA-256 mismatch' in out, (rc, out)
    assert 'TAMPER_EXECUTED' not in out, out
    assert events == [], out
    assert len(calls) == 1, calls
    snap = YAML_STATE
    assert snap.get('config.yaml') == YAML_CONFIG, snap
    backups = [k for k in snap if k.startswith('config.yaml.pre-kas-')]
    assert len(backups) == 1 and snap[backups[0]] == YAML_CONFIG, snap


def expect_yaml_symlink_refusal(rc, out, events, calls):
    """config.yaml as a symlink: refused before ANY download, the link and
    its target are untouched, and no unsafe backup is created."""
    assert rc != 0 and 'symlink' in out and 'manual backup' in out, (rc, out)
    assert events == [], out
    assert calls == [], out
    snap = YAML_STATE
    assert str(snap.get('config.yaml', '')).startswith('symlink->'), snap
    assert snap.get('real.yaml') == YAML_CONFIG, snap
    assert not any(k.startswith('config.yaml.pre-kas-') for k in snap), snap
    assert len(snap) == 2, snap


expect_static_pins()
print('static pin integrity PASS')
expect_static_yaml_guards()
print('static YAML-preservation guards PASS')

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
    ('doctor tampered payload refused before execution',
     dict(mode='doctor', doctor_served=TAMPERED_DOCTOR),
     expect_doctor_digest_refusal),
    ('doctor HTML payload refused',
     dict(mode='doctor', doctor_served=HTML_PAYLOAD), expect_doctor_html_refusal),
    ('doctor oversized payload refused',
     dict(mode='doctor', doctor_served=OVERSIZE_DOCTOR),
     expect_doctor_oversize_refusal),
    ('core bootstrap retained without curl',
     dict(mode='core', curl=False), expect_core_bootstrap),
    ('core with-curl skips bootstrap',
     dict(mode='core', curl=True), expect_core_no_bootstrap),
    ('core real pinned bootstrap passes digest gate',
     dict(mode='core', bootstrap_payload=REAL_BOOTSTRAP_CONTENT),
     expect_real_bootstrap_gate),
    ('core tampered bootstrap refused before execution',
     dict(mode='core', bootstrap_served=TAMPERED_BOOTSTRAP),
     expect_bootstrap_digest_refusal),
    ('core HTML bootstrap refused',
     dict(mode='core', bootstrap_served=HTML_PAYLOAD),
     expect_bootstrap_html_refusal),
    ('core empty bootstrap refused',
     dict(mode='core', bootstrap_served=b''), expect_bootstrap_empty_refusal),
    ('core oversized bootstrap refused',
     dict(mode='core', bootstrap_served=OVERSIZE_BOOTSTRAP),
     expect_bootstrap_oversize_refusal),
    ('core user YAML backed up before download, preserved on transport failure',
     dict(mode='core', curl=True, failcurl=True, yaml_fixture=YAML_FIXTURE_FILE),
     expect_yaml_preserved_transport_fail),
    ('core user YAML + backup survive tampered bootstrap refusal',
     dict(mode='core', curl=True, bootstrap_served=TAMPERED_BOOTSTRAP,
          yaml_fixture=YAML_FIXTURE_FILE),
     expect_yaml_preserved_tamper_refusal),
    ('core symlinked config.yaml refused, target untouched, no unsafe backup',
     dict(mode='core', curl=True, failcurl=True, yaml_fixture=YAML_FIXTURE_SYMLINK),
     expect_yaml_symlink_refusal),
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
