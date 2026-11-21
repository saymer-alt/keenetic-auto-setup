#!/usr/bin/env python3
"""Offline first-fetch regression: real bootstrap under dash/BusyBox, fake curl only.

No network, router, GitHub API credentials, opkg, or system config is touched.
Run: python3 tests/bootstrap-regression.py

Covers (issue #232): GitHub transport fallbacks, the full-content EOF/size
contract (sentinel '# KAS_EOF_V1', min size, markers, sh -n), curl exit 0
with a partial body, 16KB/20KB early cuts, and the verified GitLab mirror
fallback with local size + SHA256 + git-blob binding, mirror drift and
fail-closed behaviour, plus the loopback-only mock endpoint override gate.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

# Every positive fixture is at least 5KB and ends with the exact sentinel
# line, mirroring the released scripts' full-content EOF/size contract. The
# main fixture is larger than 20KB so the 16KB/20KB early-cut scenarios
# genuinely truncate a full-looking candidate.
PAD = "# " + "A" * 21500 + "\n"


def with_sentinel(body):
    return body + "# KAS_EOF_V1\n"


GOOD = with_sentinel(
    "#!/bin/sh\n"
    "PROJECT_API_CONTENTS='https://api.github.com/repos/test/contents'\n"
    "download_project_script() { :; }\n"
    + PAD +
    "printf 'SETUP_RAN\\n'\n"
)
BAD_SYNTAX = GOOD + "if then\n"
GOOD_IMPORT = with_sentinel(
    "#!/bin/sh\n"
    "# BEGIN MIHOMO LIFECYCLE LOCK v1\n"
    + PAD +
    "printf 'IMPORT_RAN\\n'\n"
    "printf 'Example start: mixed-port: 7890\\n'\n"
)
BAD_IMPORT_SYNTAX = GOOD_IMPORT + "if then\n"
GOOD_UPDATE = with_sentinel(
    "#!/bin/sh\n"
    "BINARY_STATE='/opt/etc/keenetic-auto-setup-mihomo.state'\n"
    "# BEGIN MIHOMO INIT RESOLUTION v1\n"
    + PAD +
    "printf 'UPDATE_RAN\\n'\n"
)
GOOD_DOCTOR = with_sentinel(
    "#!/bin/sh\n"
    "# BEGIN MIHOMO INIT RESOLUTION v1\n"
    "resolve_mihomo_init() { :; }\n"
    + PAD +
    "printf 'DOCTOR_RAN\\n'\n"
)

# Sentinels stripped but otherwise valid: simulates a mid-stream cut that
# still left curl exit 0 (or a tampered copy without the marker).
GOOD_NO_EOF = GOOD[: -len("# KAS_EOF_V1\n")] + "printf 'TAMPERED_TAIL\\n'\n"
GOOD_CUT_16K = GOOD[:16384]
GOOD_CUT_20K = GOOD[:20480]
GOOD_IMPORT_NO_EOF = GOOD_IMPORT[: -len("# KAS_EOF_V1\n")] + "printf 'TAMPERED_TAIL\\n'\n"

MOCK = r"""#!/usr/bin/env python3
import hashlib, json, os, sys
from pathlib import Path
args=sys.argv[1:]
assert '-fSsL' in args and '--connect-timeout' in args and '--max-time' in args
assert args[args.index('--connect-timeout')+1]=='7'
assert args[args.index('--max-time')+1]=='25'
assert '-k' not in args and '--insecure' not in args
url=next(a for a in args if a.startswith('http'))
dst=Path(args[args.index('-o')+1]) if '-o' in args else None
lab=Path(os.environ['LAB'])
count=lab/'curl_calls.json'
log=json.loads(count.read_text()) if count.exists() else []
phase=('gl_meta' if '/repository/files/' in url else
       'gl_raw' if '/-/raw/' in url else
       'api' if ('api.github.com' in url or '/contents/' in url) else
       'ipv4' if '--curves' in args else 'raw')
if phase=='ipv4':
    assert '-4' in args and args[args.index('--curves')+1]=='X25519'
if phase=='api':
    assert '-4' in args
    assert 'Accept: application/vnd.github.raw+json' in args
    assert 'X-GitHub-Api-Version: 2022-11-28' in args
if phase in ('gl_meta','gl_raw'):
    assert '/projects/saymer-alt%2Fkeenetic-auto-setup/' in url or '/-/raw/' in url
    assert '?ref=test-ref' in url or '/test-ref/' in url
assert url.startswith('http://') or url.startswith('https://')
log.append(phase)
count.write_text(json.dumps(log))
plan=json.loads((lab/'plan.json').read_text())
action=plan.get(phase,'fail')
if os.environ.get('SCRIPT_MODE')=='import':
    good=os.environ['GOOD_IMPORT']
    good_no_eof=os.environ['GOOD_IMPORT_NO_EOF']
elif os.environ.get('SCRIPT_MODE')=='update':
    good=os.environ['GOOD_UPDATE']
    good_no_eof=os.environ['GOOD_UPDATE_NO_EOF']
elif os.environ.get('SCRIPT_MODE')=='doctor':
    good=os.environ['GOOD_DOCTOR']
    good_no_eof=os.environ['GOOD_DOCTOR_NO_EOF']
else:
    good=os.environ['GOOD_SCRIPT']
    good_no_eof=os.environ['GOOD_NO_EOF']

def attest(data):
    # GitLab API v4 attests the exact repository content: git blob id, byte
    # size and SHA256. Returns a dict; callers serialize compactly because
    # the real API emits JSON without spaces after separators.
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

if action=='fail':
    if dst is not None:
        dst.write_text('#!/bin/sh\necho PARTIAL_SHOULD_NEVER_RUN\n')
    else:
        sys.stdout.write('')
    sys.exit(28)
if action=='good':
    emit(good.encode())
elif action=='no_eof':
    emit(good_no_eof.encode())
elif action=='cut16k':
    emit(good.encode()[:16384])
elif action=='cut20k':
    emit(good.encode()[:20480])
elif action=='bad_syntax':
    emit((good + 'if then\n').encode())
elif action=='html':
    emit('<html>not a shell script</html>')
elif action=='json':
    emit('{"content":"base64"}')
elif action=='empty':
    emit('')
elif action=='wrong_script':
    emit(os.environ['GOOD_SCRIPT'].encode())
elif action=='exit7':
    mark=os.environ.get('RUN_MARK') or 'SETUP_RAN'
    emit(good.replace("printf '"+mark+"\\n'", "printf '"+mark+"\\n'; exit 7").encode())
elif action=='meta_good':
    emit_meta(attest(good.encode()))
elif action=='meta_drift_sha':
    a=attest(good.encode()); a['content_sha256']='0'*64
    emit_meta(a)
elif action=='meta_drift_blob':
    a=attest(good.encode()); a['blob_id']='0'*40
    emit_meta(a)
elif action=='meta_drift_size':
    a=attest(good.encode()); a['size']=a['size']+10
    emit_meta(a)
elif action=='meta_wrong_content':
    emit_meta(attest(b'#!/bin/sh\nnot the real script\n'))
elif action=='meta_html':
    emit('<html>rate limited</html>')
elif action=='meta_incomplete':
    emit_meta({'blob_id':'a'*40, 'commit_id':'x'})
else:
    raise RuntimeError(action)
"""


def exercise(shell, title, plan, want_calls, want_exit, want_run, cli_args=(),
             script_mode=None, run_marker="SETUP_RAN", script_name="setup.sh",
             env_extra=None, want_stderr=None):
    with tempfile.TemporaryDirectory(prefix="kas-bootstrap-test-") as tmp:
        lab = Path(tmp)
        fakebin = lab / "bin"
        fakebin.mkdir()
        curl = fakebin / "curl"
        curl.write_text(MOCK)
        curl.chmod(0o700)
        (lab / "plan.json").write_text(json.dumps(plan))
        env = os.environ.copy()
        env.update({
            "PATH": str(fakebin) + os.pathsep + os.environ.get("PATH", ""),
            "TMPDIR": tmp,
            "LAB": tmp,
            "GOOD_SCRIPT": GOOD,
            "BAD_SYNTAX": BAD_SYNTAX,
            "GOOD_NO_EOF": GOOD_NO_EOF,
            "GOOD_IMPORT": GOOD_IMPORT,
            "GOOD_IMPORT_NO_EOF": GOOD_IMPORT_NO_EOF,
            "BAD_IMPORT_SYNTAX": BAD_IMPORT_SYNTAX,
            "GOOD_UPDATE": GOOD_UPDATE,
            "GOOD_UPDATE_NO_EOF": GOOD_UPDATE[:-len("# KAS_EOF_V1\n")] + "printf 'TAMPERED_TAIL\\n'\n",
            "GOOD_DOCTOR": GOOD_DOCTOR,
            "GOOD_DOCTOR_NO_EOF": GOOD_DOCTOR[:-len("# KAS_EOF_V1\n")] + "printf 'TAMPERED_TAIL\\n'\n",
            "KAS_BOOTSTRAP_REF": "test-ref",
            "NO_COLOR": "1",
            "TERM": "dumb",
        })
        if script_mode:
            env["SCRIPT_MODE"] = script_mode
            env["RUN_MARK"] = run_marker
        if env_extra:
            env.update(env_extra)
        r = subprocess.run(
            shell + [str(ROOT / "bootstrap.sh"), *cli_args],
            text=True,
            capture_output=True,
            timeout=12,
            env=env,
            cwd=ROOT,
            check=False,
        )
        calls = json.loads((lab / "curl_calls.json").read_text()) if (
            lab / "curl_calls.json").exists() else []
        if r.returncode != want_exit:
            raise AssertionError((title, r.returncode, want_exit, r.stdout, r.stderr))
        assert calls == want_calls, (title, calls, want_calls, r.stdout, r.stderr)
        assert (run_marker in r.stdout) == want_run, (
            title, r.stdout, r.stderr)
        if title == "safe_check_only":
            assert "CHECK_ONLY" in r.stdout and "nothing executed" in r.stdout
        if title == "import_check_only":
            assert "CHECK_ONLY" in r.stdout and "nothing executed" in r.stdout
        assert not list(lab.glob("kas-setup.*")), (title, "staged secret not removed")
        assert "PARTIAL_SHOULD_NEVER_RUN" not in r.stdout, title
        assert "TAMPERED_TAIL" not in r.stdout, title
        if want_exit == 1 and not want_run:
            assert ("Could not fetch valid KAS " + script_name) in r.stderr, (title, r.stderr)
        if want_stderr and want_stderr not in r.stderr:
            raise AssertionError((title, want_stderr, r.stderr))
        print("PASS", shell, title)


GH_DOWN = {"raw": "fail", "ipv4": "fail", "api": "fail"}
GH_DOWN_CALLS = ["raw", "ipv4", "api"]
GL_GOOD = {"gl_meta": "meta_good", "gl_raw": "good"}


def main():
    shells = [["/bin/sh"]] if os.path.exists("/bin/sh") else []
    if not shells:
        # Non-POSIX host (e.g. Windows development checkout): fall back to a
        # resolvable POSIX sh. CI keeps /bin/sh exactly as before.
        sh_path = shutil.which("sh")
        if sh_path:
            shells.append([sh_path])
    bb = shutil.which("busybox")
    if bb:
        shells.append([bb, "ash"])
    for shell in shells:
        # GitHub primary paths (unchanged behaviour + EOF contract).
        exercise(shell, "raw_good", {"raw": "good"}, ["raw"], 0, True)
        exercise(shell, "safe_check_only", {"raw": "good"}, ["raw"], 0, False,
                 cli_args=("--check",))
        exercise(shell, "invalid_raw_then_ipv4_good", {"raw": "html", "ipv4": "good"},
                 ["raw", "ipv4"], 0, True)
        exercise(shell, "raw_ipv4_fail_api_good", {"api": "good"},
                 ["raw", "ipv4", "api"], 0, True)
        exercise(shell, "partial_all_fail", {},
                 GH_DOWN_CALLS + ["gl_meta"], 1, False)
        exercise(shell, "api_json_rejected", {"raw": "json", "ipv4": "empty", "api": "json"},
                 ["raw", "ipv4", "api", "gl_meta"], 1, False)
        exercise(shell, "bad_shell_syntax_rejected", {"raw": "bad_syntax",
                                                     "ipv4": "bad_syntax",
                                                     "api": "bad_syntax"},
                 ["raw", "ipv4", "api", "gl_meta"], 1, False)
        exercise(shell, "exit_propagation", {"raw": "exit7"}, ["raw"], 7, True)
        # curl exit 0 with a partial body on the primary path: no sentinel,
        # so the candidate is rejected on every GitHub transport.
        exercise(shell, "github_exit0_partial_rejected",
                 {"raw": "no_eof", "ipv4": "no_eof", "api": "no_eof"},
                 ["raw", "ipv4", "api", "gl_meta"], 1, False)
        exercise(shell, "github_cut16k_rejected",
                 {"raw": "cut16k", "ipv4": "cut16k", "api": "cut16k"},
                 ["raw", "ipv4", "api", "gl_meta"], 1, False)
        exercise(shell, "github_cut20k_rejected",
                 {"raw": "cut20k", "ipv4": "cut20k", "api": "cut20k"},
                 ["raw", "ipv4", "api", "gl_meta"], 1, False)

        # Verified GitLab mirror fallback (issue #232).
        exercise(shell, "github_down_gitlab_verified_good",
                 dict(GH_DOWN, **GL_GOOD),
                 GH_DOWN_CALLS + ["gl_meta", "gl_raw"], 0, True)
        exercise(shell, "github_down_gitlab_check_only",
                 dict(GH_DOWN, **GL_GOOD),
                 GH_DOWN_CALLS + ["gl_meta", "gl_raw"], 0, False,
                 cli_args=("--check",))
        # Mirror drift: every attestation mismatch must fail closed.
        exercise(shell, "gitlab_sha_drift_rejected",
                 dict(GH_DOWN, gl_meta="meta_drift_sha", gl_raw="good"),
                 GH_DOWN_CALLS + ["gl_meta", "gl_raw"], 1, False)
        exercise(shell, "gitlab_blob_drift_rejected",
                 dict(GH_DOWN, gl_meta="meta_drift_blob", gl_raw="good"),
                 GH_DOWN_CALLS + ["gl_meta", "gl_raw"], 1, False)
        exercise(shell, "gitlab_size_drift_rejected",
                 dict(GH_DOWN, gl_meta="meta_drift_size", gl_raw="good"),
                 GH_DOWN_CALLS + ["gl_meta", "gl_raw"], 1, False)
        exercise(shell, "gitlab_attests_wrong_content_rejected",
                 dict(GH_DOWN, gl_meta="meta_wrong_content", gl_raw="good"),
                 GH_DOWN_CALLS + ["gl_meta", "gl_raw"], 1, False)
        # Partial delivery from the mirror: curl exit 0 with a truncated
        # 16KB/20KB body, sentinel missing.
        exercise(shell, "gitlab_cut16k_rejected",
                 dict(GH_DOWN, gl_meta="meta_good", gl_raw="cut16k"),
                 GH_DOWN_CALLS + ["gl_meta", "gl_raw"], 1, False)
        exercise(shell, "gitlab_cut20k_rejected",
                 dict(GH_DOWN, gl_meta="meta_good", gl_raw="cut20k"),
                 GH_DOWN_CALLS + ["gl_meta", "gl_raw"], 1, False)
        exercise(shell, "gitlab_html_rejected",
                 dict(GH_DOWN, gl_meta="meta_good", gl_raw="html"),
                 GH_DOWN_CALLS + ["gl_meta", "gl_raw"], 1, False)
        exercise(shell, "gitlab_bad_syntax_rejected",
                 dict(GH_DOWN, gl_meta="meta_good", gl_raw="bad_syntax"),
                 GH_DOWN_CALLS + ["gl_meta", "gl_raw"], 1, False)
        # Attestation endpoint problems must fail closed, never fall back to
        # an unverified mirror download.
        exercise(shell, "gitlab_meta_fail_closed",
                 dict(GH_DOWN, gl_meta="fail", gl_raw="good"),
                 GH_DOWN_CALLS + ["gl_meta"], 1, False)
        exercise(shell, "gitlab_meta_html_closed",
                 dict(GH_DOWN, gl_meta="meta_html", gl_raw="good"),
                 GH_DOWN_CALLS + ["gl_meta"], 1, False)
        exercise(shell, "gitlab_meta_incomplete_closed",
                 dict(GH_DOWN, gl_meta="meta_incomplete", gl_raw="good"),
                 GH_DOWN_CALLS + ["gl_meta"], 1, False)
        exercise(shell, "gitlab_raw_fail_closed",
                 dict(GH_DOWN, gl_meta="meta_good", gl_raw="fail"),
                 GH_DOWN_CALLS + ["gl_meta", "gl_raw"], 1, False)

        # config-import.sh via the mirror with its own markers.
        import_args = ("--script", "config-import.sh")
        exercise(shell, "import_raw_reset_then_ipv4_good",
                 {"raw": "fail", "ipv4": "good"}, ["raw", "ipv4"], 0, True,
                 cli_args=import_args, script_mode="import", run_marker="IMPORT_RAN",
                 script_name="config-import.sh")
        exercise(shell, "import_all_sources_fail", {},
                 GH_DOWN_CALLS + ["gl_meta"], 1, False,
                 cli_args=import_args, script_mode="import",
                 script_name="config-import.sh")
        exercise(shell, "import_html_rejected", {"raw": "html", "ipv4": "html", "api": "html"},
                 ["raw", "ipv4", "api", "gl_meta"], 1, False,
                 cli_args=import_args, script_mode="import",
                 script_name="config-import.sh")
        exercise(shell, "import_wrong_script_rejected",
                 {"raw": "wrong_script", "ipv4": "wrong_script", "api": "wrong_script"},
                 ["raw", "ipv4", "api", "gl_meta"], 1, False,
                 cli_args=import_args, script_mode="import",
                 script_name="config-import.sh")
        exercise(shell, "import_bad_shell_rejected",
                 {"raw": "bad_syntax", "ipv4": "bad_syntax", "api": "bad_syntax"},
                 ["raw", "ipv4", "api", "gl_meta"], 1, False,
                 cli_args=import_args, script_mode="import",
                 script_name="config-import.sh")
        exercise(shell, "import_exit0_partial_rejected",
                 {"raw": "no_eof", "ipv4": "no_eof", "api": "no_eof"},
                 ["raw", "ipv4", "api", "gl_meta"], 1, False,
                 cli_args=import_args, script_mode="import",
                 script_name="config-import.sh")
        exercise(shell, "import_github_down_gitlab_good",
                 dict(GH_DOWN, **GL_GOOD),
                 GH_DOWN_CALLS + ["gl_meta", "gl_raw"], 0, True,
                 cli_args=import_args, script_mode="import", run_marker="IMPORT_RAN",
                 script_name="config-import.sh")
        exercise(shell, "import_gitlab_no_eof_rejected",
                 dict(GH_DOWN, gl_meta="meta_good", gl_raw="no_eof"),
                 GH_DOWN_CALLS + ["gl_meta", "gl_raw"], 1, False,
                 cli_args=import_args, script_mode="import",
                 script_name="config-import.sh")
        exercise(shell, "import_gitlab_wrong_script_rejected",
                 dict(GH_DOWN, gl_meta="meta_good", gl_raw="wrong_script"),
                 GH_DOWN_CALLS + ["gl_meta", "gl_raw"], 1, False,
                 cli_args=import_args, script_mode="import",
                 script_name="config-import.sh")
        exercise(shell, "import_check_only", {"raw": "good"}, ["raw"], 0, False,
                 cli_args=("--check", *import_args), script_mode="import",
                 run_marker="IMPORT_RAN", script_name="config-import.sh")

        # update-mihomo.sh: the mutating updater must never run from a
        # truncated stream either (issue #255 delivery contract extension).
        update_args = ("--script", "update-mihomo.sh")
        exercise(shell, "update_raw_good", {"raw": "good"}, ["raw"], 0, True,
                 cli_args=update_args, script_mode="update", run_marker="UPDATE_RAN",
                 script_name="update-mihomo.sh")
        exercise(shell, "update_exit0_partial_rejected",
                 {"raw": "no_eof", "ipv4": "no_eof", "api": "no_eof"},
                 ["raw", "ipv4", "api", "gl_meta"], 1, False,
                 cli_args=update_args, script_mode="update",
                 script_name="update-mihomo.sh")
        exercise(shell, "update_all_sources_fail", {},
                 GH_DOWN_CALLS + ["gl_meta"], 1, False,
                 cli_args=update_args, script_mode="update",
                 script_name="update-mihomo.sh")
        exercise(shell, "update_github_down_gitlab_good",
                 dict(GH_DOWN, **GL_GOOD),
                 GH_DOWN_CALLS + ["gl_meta", "gl_raw"], 0, True,
                 cli_args=update_args, script_mode="update", run_marker="UPDATE_RAN",
                 script_name="update-mihomo.sh")
        exercise(shell, "update_check_only", {"raw": "good"}, ["raw"], 0, False,
                 cli_args=("--check", *update_args), script_mode="update",
                 run_marker="UPDATE_RAN", script_name="update-mihomo.sh")

        # mihomo-doctor.sh: read-only diagnostics, same delivery contract.
        doctor_args = ("--script", "mihomo-doctor.sh")
        exercise(shell, "doctor_raw_good", {"raw": "good"}, ["raw"], 0, True,
                 cli_args=doctor_args, script_mode="doctor", run_marker="DOCTOR_RAN",
                 script_name="mihomo-doctor.sh")
        exercise(shell, "doctor_exit0_partial_rejected",
                 {"raw": "no_eof", "ipv4": "no_eof", "api": "no_eof"},
                 ["raw", "ipv4", "api", "gl_meta"], 1, False,
                 cli_args=doctor_args, script_mode="doctor",
                 script_name="mihomo-doctor.sh")
        exercise(shell, "doctor_github_down_gitlab_good",
                 dict(GH_DOWN, **GL_GOOD),
                 GH_DOWN_CALLS + ["gl_meta", "gl_raw"], 0, True,
                 cli_args=doctor_args, script_mode="doctor", run_marker="DOCTOR_RAN",
                 script_name="mihomo-doctor.sh")

        # Loopback-only mock endpoint override gate.
        exercise(shell, "mock_override_https_refused", {},
                 [], 2, False,
                 env_extra={"KAS_MOCK_GL_RAW_BASE": "https://gitlab.com/saymer-alt/keenetic-auto-setup"},
                 want_stderr="must be unset or a loopback http URL")
        exercise(shell, "mock_override_nonloopback_refused", {},
                 [], 2, False,
                 env_extra={"KAS_MOCK_GH_RAW_BASE": "http://10.0.0.9:9999"},
                 want_stderr="must be unset or a loopback http URL")
        exercise(shell, "mock_override_loopback_accepted_all_fail", {},
                 ["raw", "ipv4", "api", "gl_meta"], 1, False,
                 env_extra={
                     "KAS_MOCK_GH_RAW_BASE": "http://127.0.0.1:9",
                     "KAS_MOCK_GH_API_BASE": "http://127.0.0.1:9",
                     "KAS_MOCK_GL_RAW_BASE": "http://127.0.0.1:9",
                     "KAS_MOCK_GL_API_BASE": "http://127.0.0.1:9",
                 })

        # Security regression: a literal localhost prefix is NOT proof of
        # localhost URL authority. No curl invocation is allowed.
        for label, bad in (
            ("userinfo_host", "http://localhost:8080@evil.invalid"),
            ("userinfo_ip", "http://127.0.0.1:8080@evil.invalid"),
            ("bad_port", "http://localhost:evil"),
            ("query", "http://localhost:8080/?next=http://evil.invalid"),
            ("fragment", "http://localhost:8080/#foreign"),
            ("encoded", "http://127.0.0.1:8080%40evil.invalid"),
            ("backslash", "http://localhost:8080\\@evil.invalid"),
        ):
            exercise(shell, "mock_override_" + label + "_refused", {},
                     [], 2, False,
                     env_extra={"KAS_MOCK_GH_RAW_BASE": bad},
                     want_stderr="must be unset or a loopback http URL")

        with tempfile.TemporaryDirectory(prefix="kas-bootstrap-ref-") as tmp:
            env = os.environ.copy()
            env["KAS_BOOTSTRAP_REF"] = "../../attacker"
            env["TMPDIR"] = tmp
            env["PATH"] = "/usr/bin:/bin"
            r = subprocess.run(shell + [str(ROOT / "bootstrap.sh")], env=env,
                               capture_output=True, text=True, timeout=5)
            assert r.returncode == 2 and "Invalid KAS_BOOTSTRAP_REF" in r.stderr, (
                r.stdout, r.stderr)
        print("PASS", shell, "invalid_ref")
    print("PASS all first-fetch cases, never ran unverified response")


if __name__ == "__main__":
    main()
