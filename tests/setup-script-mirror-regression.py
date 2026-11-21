#!/usr/bin/env python3
"""Offline regression: real setup.sh installer chain under dash/BusyBox, fake curl/wget.

Exercises setup.sh end to end with a mocked /proc/mounts classification, a
fake opkg, and a plan-driven fake curl/wget on PATH. No network, router, or
system state is touched. Run: python3 tests/setup-script-mirror-regression.py

Covers (issue #232): the full-content EOF/size contract for install.sh
(sentinel + markers + sh -n, curl exit 0 with a partial body), and the
verified GitLab mirror fallback with size + SHA256 + git-blob binding,
mirror drift and fail-closed behaviour, plus the loopback-only mock
endpoint override gate.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

# The install.sh fixture is larger than 20KB so the 16KB/20KB early-cut
# scenarios genuinely truncate a full-looking candidate.
PAD = "# " + "A" * 21500 + "\n"
SENTINEL = "# KAS_EOF_V1\n"

# A valid install.sh-shaped candidate: shebang, install markers, sentinel.
GOOD_INSTALL = (
    "#!/bin/sh\n"
    'MIHOMO_LIFECYCLE_LOCK="/tmp/mihomo-lifecycle.lock.d"\n'
    "# begin magitrickle stage\n"
    + PAD +
    "printf 'INSTALL_RAN\\n'\n" + SENTINEL
)
GOOD_IMPORT = (
    "#!/bin/sh\n"
    "# BEGIN MIHOMO LIFECYCLE LOCK v1\n"
    + PAD +
    "printf 'Example start: mixed-port: 7890\\n'\n" + SENTINEL
)
GOOD_NO_EOF = GOOD_INSTALL[: -len(SENTINEL)] + "printf 'TAMPERED_TAIL\\n'\n"
GOOD_IMPORT_NO_EOF = GOOD_IMPORT[: -len(SENTINEL)] + "printf 'TAMPERED_TAIL\\n'\n"
GOOD_CUT_16K = GOOD_INSTALL[:16384]
GOOD_CUT_20K = GOOD_INSTALL[:20480]

MOUNTS = "/dev/sda1 /opt ext4 rw 0 0\n"

MOCK_CURL = r"""#!/usr/bin/env python3
import hashlib, json, os, sys
from pathlib import Path
args = sys.argv[1:]
assert '-fSsL' in args and '-k' not in args and '--insecure' not in args
url = next(a for a in args if a.startswith('http'))
dst = Path(args[args.index('-o') + 1]) if '-o' in args else None
lab = Path(os.environ['LAB'])
good = os.environ['GOOD']
good_import = os.environ['GOOD_IMPORT']
good_no_eof = os.environ['GOOD_NO_EOF']
good_import_no_eof = os.environ['GOOD_IMPORT_NO_EOF']
log = json.loads((lab / 'curl_calls.json').read_text()) if (lab / 'curl_calls.json').exists() else []
stage = ('config-import.sh'
         if url.split('?')[0].rstrip('/').endswith('/config-import.sh')
         else 'install.sh')
phase = ('gl_meta' if '/repository/files/' in url else
         'gl_raw' if '/-/raw/' in url else
         'api' if ('api.github.com' in url or '/contents/' in url) else
         'ipv4' if '--curves' in args else 'raw') + ':' + stage
# Consecutive duplicates are collapsed: retry loops must not change the
# observed source sequence.
if not log or log[-1] != phase:
    log.append(phase)
(lab / 'curl_calls.json').write_text(json.dumps(log))
plan = json.loads((lab / 'plan.json').read_text())
action = plan.get(phase, 'fail')
if stage == 'config-import.sh':
    good = good_import
    good_no_eof = good_import_no_eof

def attest(data):
    return {
        'blob_id': hashlib.sha1(b'blob %d\x00' % len(data) + data).hexdigest(),
        'content_sha256': hashlib.sha256(data).hexdigest(),
        'size': len(data),
        'commit_id': 'attested-commit',
    }

def emit(data):
    if dst is None:
        sys.stdout.write(data.decode() if isinstance(data, bytes) else data)
    else:
        dst.write_bytes(data if isinstance(data, bytes) else data.encode())

def emit_meta(obj):
    emit(json.dumps(obj, separators=(',', ':')))

if action == 'fail':
    if dst is not None:
        dst.write_text('#!/bin/sh\necho PARTIAL_SHOULD_NEVER_RUN\n')
    sys.exit(28)
if action == 'good':
    emit(good.encode())
elif action == 'no_eof':
    emit(good_no_eof.encode())
elif action == 'cut16k':
    emit(good.encode()[:16384])
elif action == 'cut20k':
    emit(good.encode()[:20480])
elif action == 'html':
    emit('<html>not a shell script</html>')
elif action == 'empty':
    emit('')
elif action == 'wrong_script':
    emit(good_import.encode())
elif action == 'meta_good':
    emit_meta(attest(good.encode()))
elif action == 'meta_drift_sha':
    a = attest(good.encode()); a['content_sha256'] = '0' * 64
    emit_meta(a)
elif action == 'meta_drift_blob':
    a = attest(good.encode()); a['blob_id'] = '0' * 40
    emit_meta(a)
elif action == 'meta_wrong_content':
    emit_meta(attest(b'#!/bin/sh\nnot the real script\n'))
elif action == 'meta_html':
    emit('<html>rate limited</html>')
else:
    raise RuntimeError(action)
"""

MOCK_WGET = r"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
assert '-qO' in args and '-T' in args
dst = Path(args[args.index('-qO') + 1])
lab = Path(os.environ['LAB'])
log = json.loads((lab / 'wget_calls.json').read_text()) if (lab / 'wget_calls.json').exists() else []
log.append(args[args.index('-T') + 1])
(lab / 'wget_calls.json').write_text(json.dumps(log))
dst.write_text('#!/bin/sh\necho PARTIAL_SHOULD_NEVER_RUN\n')
sys.exit(28)
"""

# Retry pacing itself is covered by setup-wget-regression; this suite
# asserts source ordering and integrity binding, so bounded sleeps are
# recorded (still bounded!) but not awaited.
MOCK_SLEEP = r"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
lab = Path(os.environ['LAB'])
value = float(sys.argv[1])
assert 0 < value <= 2, ('unbounded retry sleep requested', value)
log = json.loads((lab / 'sleeps.json').read_text()) if (lab / 'sleeps.json').exists() else []
log.append(value)
(lab / 'sleeps.json').write_text(json.dumps(log))
"""


def exercise(shell, title, plan, want_calls, want_exit, want_install,
             env_extra=None, want_stderr=None, want_wget_calls=None):
    with tempfile.TemporaryDirectory(prefix="kas-setup-mirror-") as tmp:
        lab = Path(tmp)
        fakebin = lab / "bin"
        fakebin.mkdir()
        for name, body in (("curl", MOCK_CURL), ("wget", MOCK_WGET),
                           ("opkg", "#!/bin/sh\nexit 0\n"),
                           ("sleep", MOCK_SLEEP)):
            f = fakebin / name
            f.write_text(body)
            f.chmod(0o700)
        mounts = lab / "mounts"
        mounts.write_text(MOUNTS)
        (lab / "plan.json").write_text(json.dumps(plan))
        env = os.environ.copy()
        env.update({
            "PATH": str(fakebin) + os.pathsep + os.environ.get("PATH", ""),
            "LAB": tmp,
            "SETUP_MOUNTS": str(mounts),
            "GOOD": GOOD_INSTALL,
            "GOOD_IMPORT": GOOD_IMPORT,
            "GOOD_NO_EOF": GOOD_NO_EOF,
            "GOOD_IMPORT_NO_EOF": GOOD_IMPORT_NO_EOF,
            "NO_COLOR": "1",
            "TERM": "dumb",
        })
        if env_extra:
            env.update(env_extra)
        r = subprocess.run(
            shell + [str(ROOT / "setup.sh")],
            text=True,
            capture_output=True,
            timeout=30,
            env=env,
            cwd=ROOT,
            check=False,
            stdin=subprocess.DEVNULL,
            # Detach the controlling terminal: without a tty, setup.sh must
            # skip the interactive config-import stage by design.
            start_new_session=True,
        )
        calls = json.loads((lab / "curl_calls.json").read_text()) if (
            lab / "curl_calls.json").exists() else []
        wget = json.loads((lab / "wget_calls.json").read_text()) if (
            lab / "wget_calls.json").exists() else []
        if want_wget_calls is not None:
            assert wget == want_wget_calls, (title, wget, want_wget_calls)
        sleeps = json.loads((lab / "sleeps.json").read_text()) if (
            lab / "sleeps.json").exists() else []
        # Bounded retry pacing must still be requested even though the stub
        # does not actually wait (each pause stays <= 2s by the stub assert).
        if want_exit == 1:
            assert sleeps, (title, "bounded retries never paced")
        if r.returncode != want_exit:
            raise AssertionError((title, r.returncode, want_exit, r.stdout, r.stderr))
        assert calls == want_calls, (title, calls, want_calls, r.stdout, r.stderr)
        assert ("INSTALL_RAN" in r.stdout) == want_install, (title, r.stdout, r.stderr)
        assert "PARTIAL_SHOULD_NEVER_RUN" not in r.stdout, title
        assert "TAMPERED_TAIL" not in r.stdout, title
        assert not list(Path("/tmp").glob("keenetic-auto-setup-install.*")), (
            title, "install staging file not removed")
        if want_stderr and want_stderr not in r.stderr:
            raise AssertionError((title, want_stderr, r.stderr))
        print("PASS", shell, title)


def main():
    shells = [["/bin/sh"]]
    bb = shutil.which("busybox")
    if bb:
        shells.append([bb, "ash"])
    for shell in shells:
        # GitHub primary path succeeds: the mirror must stay untouched.
        exercise(shell, "raw_good_gitlab_untouched",
                 {"raw:install.sh": "good", "raw:config-import.sh": "good"},
                 ["raw:install.sh", "raw:config-import.sh"], 0, True)
        # GitHub fully down: verified GitLab fallback delivers install.sh.
        exercise(shell, "github_down_gitlab_verified_good",
                 {"raw:install.sh": "fail", "wget:install.sh": "fail",
                  "api:install.sh": "fail",
                  "gl_meta:install.sh": "meta_good",
                  "gl_raw:install.sh": "good",
                  "raw:config-import.sh": "good"},
                 ["raw:install.sh", "ipv4:install.sh", "api:install.sh",
                  "gl_meta:install.sh", "gl_raw:install.sh",
                  "raw:config-import.sh"], 0, True,
                 want_wget_calls=["20", "20", "20"])
        # curl exit 0 with a partial body on the primary path, then mirror.
        exercise(shell, "github_exit0_partial_then_gitlab_good",
                 {"raw:install.sh": "no_eof", "wget:install.sh": "fail",
                  "api:install.sh": "fail",
                  "gl_meta:install.sh": "meta_good",
                  "gl_raw:install.sh": "good",
                  "raw:config-import.sh": "good"},
                 ["raw:install.sh", "api:install.sh",
                  "gl_meta:install.sh", "gl_raw:install.sh",
                  "raw:config-import.sh"], 0, True)
        exercise(shell, "github_cut16k_then_gitlab_good",
                 {"raw:install.sh": "cut16k", "wget:install.sh": "fail",
                  "api:install.sh": "fail",
                  "gl_meta:install.sh": "meta_good",
                  "gl_raw:install.sh": "good",
                  "raw:config-import.sh": "good"},
                 ["raw:install.sh", "api:install.sh",
                  "gl_meta:install.sh", "gl_raw:install.sh",
                  "raw:config-import.sh"], 0, True)
        exercise(shell, "github_cut20k_then_gitlab_good",
                 {"raw:install.sh": "cut20k", "wget:install.sh": "fail",
                  "api:install.sh": "fail",
                  "gl_meta:install.sh": "meta_good",
                  "gl_raw:install.sh": "good",
                  "raw:config-import.sh": "good"},
                 ["raw:install.sh", "api:install.sh",
                  "gl_meta:install.sh", "gl_raw:install.sh",
                  "raw:config-import.sh"], 0, True)
        # Wrong script delivered on GitHub, correct one via the mirror.
        exercise(shell, "github_wrong_script_then_gitlab_good",
                 {"raw:install.sh": "wrong_script", "wget:install.sh": "fail",
                  "api:install.sh": "wrong_script",
                  "gl_meta:install.sh": "meta_good",
                  "gl_raw:install.sh": "good",
                  "raw:config-import.sh": "good"},
                 ["raw:install.sh", "api:install.sh",
                  "gl_meta:install.sh", "gl_raw:install.sh",
                  "raw:config-import.sh"], 0, True)
        # Mirror drift: attestation mismatch must fail closed, never execute.
        exercise(shell, "gitlab_sha_drift_rejected",
                 {"raw:install.sh": "fail", "wget:install.sh": "fail",
                  "api:install.sh": "fail",
                  "gl_meta:install.sh": "meta_drift_sha",
                  "gl_raw:install.sh": "good"},
                 ["raw:install.sh", "ipv4:install.sh", "api:install.sh",
                  "gl_meta:install.sh", "gl_raw:install.sh"], 1, False)
        exercise(shell, "gitlab_blob_drift_rejected",
                 {"raw:install.sh": "fail", "wget:install.sh": "fail",
                  "api:install.sh": "fail",
                  "gl_meta:install.sh": "meta_drift_blob",
                  "gl_raw:install.sh": "good"},
                 ["raw:install.sh", "ipv4:install.sh", "api:install.sh",
                  "gl_meta:install.sh", "gl_raw:install.sh"], 1, False)
        exercise(shell, "gitlab_attests_wrong_content_rejected",
                 {"raw:install.sh": "fail", "wget:install.sh": "fail",
                  "api:install.sh": "fail",
                  "gl_meta:install.sh": "meta_wrong_content",
                  "gl_raw:install.sh": "good"},
                 ["raw:install.sh", "ipv4:install.sh", "api:install.sh",
                  "gl_meta:install.sh", "gl_raw:install.sh"], 1, False)
        # Partial or foreign content from the mirror.
        exercise(shell, "gitlab_exit0_partial_rejected",
                 {"raw:install.sh": "fail", "wget:install.sh": "fail",
                  "api:install.sh": "fail",
                  "gl_meta:install.sh": "meta_good",
                  "gl_raw:install.sh": "no_eof"},
                 ["raw:install.sh", "ipv4:install.sh", "api:install.sh",
                  "gl_meta:install.sh", "gl_raw:install.sh"], 1, False)
        exercise(shell, "gitlab_cut16k_rejected",
                 {"raw:install.sh": "fail", "wget:install.sh": "fail",
                  "api:install.sh": "fail",
                  "gl_meta:install.sh": "meta_good",
                  "gl_raw:install.sh": "cut16k"},
                 ["raw:install.sh", "ipv4:install.sh", "api:install.sh",
                  "gl_meta:install.sh", "gl_raw:install.sh"], 1, False)
        exercise(shell, "gitlab_html_rejected",
                 {"raw:install.sh": "fail", "wget:install.sh": "fail",
                  "api:install.sh": "fail",
                  "gl_meta:install.sh": "meta_good",
                  "gl_raw:install.sh": "html"},
                 ["raw:install.sh", "ipv4:install.sh", "api:install.sh",
                  "gl_meta:install.sh", "gl_raw:install.sh"], 1, False)
        # Attestation unavailable: fail closed without an unverified download.
        exercise(shell, "gitlab_meta_fail_closed",
                 {"raw:install.sh": "fail", "wget:install.sh": "fail",
                  "api:install.sh": "fail",
                  "gl_meta:install.sh": "fail",
                  "gl_raw:install.sh": "good"},
                 ["raw:install.sh", "ipv4:install.sh", "api:install.sh",
                  "gl_meta:install.sh"], 1, False)
        exercise(shell, "gitlab_meta_html_closed",
                 {"raw:install.sh": "fail", "wget:install.sh": "fail",
                  "api:install.sh": "fail",
                  "gl_meta:install.sh": "meta_html",
                  "gl_raw:install.sh": "good"},
                 ["raw:install.sh", "ipv4:install.sh", "api:install.sh",
                  "gl_meta:install.sh"], 1, False)
        exercise(shell, "gitlab_raw_fail_closed",
                 {"raw:install.sh": "fail", "wget:install.sh": "fail",
                  "api:install.sh": "fail",
                  "gl_meta:install.sh": "meta_good",
                  "gl_raw:install.sh": "fail"},
                 ["raw:install.sh", "ipv4:install.sh", "api:install.sh",
                  "gl_meta:install.sh", "gl_raw:install.sh"], 1, False)
        # Loopback-only mock endpoint override gate.
        exercise(shell, "mock_override_https_refused", {},
                 [], 2, False,
                 env_extra={"KAS_MOCK_GL_RAW_BASE": "https://gitlab.com/saymer-alt/keenetic-auto-setup"},
                 want_stderr="must be unset or a loopback http URL")
        exercise(shell, "mock_override_nonloopback_refused", {},
                 [], 2, False,
                 env_extra={"KAS_MOCK_GH_RAW_BASE": "http://192.0.2.1:9999"},
                 want_stderr="must be unset or a loopback http URL")
        # Same authority check must run in setup before the first request.
        for label, bad in (
            ("userinfo", "http://localhost:8888@evil.invalid"),
            ("bad_port", "http://127.0.0.1:port"),
            ("query", "http://localhost:9999/?redirect=http://evil.invalid"),
            ("encoding", "http://localhost:9999%40evil.invalid"),
        ):
            exercise(shell, "mock_override_" + label + "_refused", {},
                     [], 2, False,
                     env_extra={"KAS_MOCK_GL_API_BASE": bad},
                     want_stderr="must be unset or a loopback http URL")
        # Mock endpoints are loopback-only; wget cannot enforce the same
        # redirect restriction on BusyBox. Its fallback must be skipped.
        # The real GitLab curl stage may still validate a pinned candidate.
        exercise(shell, "mock_override_skips_wget_fallback",
                 {"raw:install.sh": "fail", "wget:install.sh": "good",
                  "api:install.sh": "fail",
                  "gl_meta:install.sh": "meta_good",
                  "gl_raw:install.sh": "good",
                  "raw:config-import.sh": "good"},
                 ["raw:install.sh", "ipv4:install.sh", "api:install.sh",
                  "gl_meta:install.sh", "gl_raw:install.sh",
                  "raw:config-import.sh"], 0, True,
                 env_extra={"KAS_MOCK_GH_RAW_BASE": "http://127.0.0.1:9"},
                 want_wget_calls=[])
    print("PASS all setup.sh script-mirror cases, never ran unverified response")


if __name__ == "__main__":
    main()
