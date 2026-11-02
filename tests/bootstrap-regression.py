#!/usr/bin/env python3
"""Offline first-fetch regression: real bootstrap under dash/BusyBox, fake curl only.

No network, router, GitHub API credentials, opkg, or system config is touched.
Run: python3 tests/bootstrap-regression.py
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
GOOD = """#!/bin/sh
PROJECT_API_CONTENTS='https://api.github.com/repos/test/contents'
download_project_script() { :; }
printf 'SETUP_RAN\\n'
"""
BAD_SYNTAX = GOOD + "if then\n"
GOOD_IMPORT = """#!/bin/sh
# BEGIN MIHOMO LIFECYCLE LOCK v1
printf 'IMPORT_RAN\\n'
printf 'Example start: mixed-port: 7890\\n'
"""
BAD_IMPORT_SYNTAX = GOOD_IMPORT + "if then\n"
MOCK = r"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args=sys.argv[1:]
assert '-fSsL' in args and '--connect-timeout' in args and '--max-time' in args
assert args[args.index('--connect-timeout')+1]=='7'
assert args[args.index('--max-time')+1]=='25'
assert '-k' not in args and '--insecure' not in args
assert '-o' in args
url=next(a for a in args if a.startswith('https://'))
dst=Path(args[args.index('-o')+1])
lab=Path(os.environ['LAB'])
count=lab/'curl_calls.json'
log=json.loads(count.read_text()) if count.exists() else []
phase=('api' if 'api.github.com' in url else
       'ipv4' if '--curves' in args else 'raw')
if phase=='ipv4':
    assert '-4' in args and args[args.index('--curves')+1]=='X25519'
if phase=='api':
    assert '-4' in args
    assert 'Accept: application/vnd.github.raw+json' in args
    assert 'X-GitHub-Api-Version: 2022-11-28' in args
assert url.startswith('https://')
assert 'test-ref/' in url or url.endswith('?ref=test-ref')
log.append(phase)
count.write_text(json.dumps(log))
plan=json.loads((lab/'plan.json').read_text())
action=plan.get(phase,'fail')
good=os.environ.get('GOOD_IMPORT') if os.environ.get('SCRIPT_MODE')=='import' else os.environ['GOOD_SCRIPT']
bad=os.environ.get('BAD_IMPORT_SYNTAX') if os.environ.get('SCRIPT_MODE')=='import' else os.environ['BAD_SYNTAX']
if action=='fail':
    dst.write_text('#!/bin/sh\\necho PARTIAL_SHOULD_NEVER_RUN\\n')
    sys.exit(28)
if action=='good':
    dst.write_text(good)
elif action=='bad_syntax':
    dst.write_text(bad)
elif action=='html':
    dst.write_text('<html>not a shell script</html>')
elif action=='json':
    dst.write_text('{"content":"base64"}')
elif action=='empty':
    dst.write_text('')
elif action=='wrong_script':
    dst.write_text(os.environ['GOOD_SCRIPT'])
elif action=='exit7':
    mark=os.environ.get('RUN_MARK') or 'SETUP_RAN'
    dst.write_text(good.replace("printf '"+mark+"\\n'", "printf '"+mark+"\\n'; exit 7"))
else:
    raise RuntimeError(action)
"""


def exercise(shell, title, plan, want_calls, want_exit, want_run, cli_args=(),
             script_mode=None, run_marker="SETUP_RAN", script_name="setup.sh"):
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
            "GOOD_IMPORT": GOOD_IMPORT,
            "BAD_IMPORT_SYNTAX": BAD_IMPORT_SYNTAX,
            "KAS_BOOTSTRAP_REF": "test-ref",
            "NO_COLOR": "1",
            "TERM": "dumb",
        })
        if script_mode:
            env["SCRIPT_MODE"] = script_mode
            env["RUN_MARK"] = run_marker
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
        if want_exit == 1 and not want_run:
            assert ("Could not fetch valid KAS " + script_name) in r.stderr, (title, r.stderr)
        print("PASS", shell, title)


def main():
    shells = [["/bin/sh"]]
    bb = shutil.which("busybox")
    if bb:
        shells.append([bb, "ash"])
    for shell in shells:
        exercise(shell, "raw_good", {"raw": "good"}, ["raw"], 0, True)
        exercise(shell, "safe_check_only", {"raw": "good"}, ["raw"], 0, False,
                 cli_args=("--check",))
        exercise(shell, "invalid_raw_then_ipv4_good", {"raw": "html", "ipv4": "good"},
                 ["raw", "ipv4"], 0, True)
        exercise(shell, "raw_ipv4_fail_api_good", {"api": "good"},
                 ["raw", "ipv4", "api"], 0, True)
        exercise(shell, "partial_all_fail", {},
                 ["raw", "ipv4", "api"], 1, False)
        exercise(shell, "api_json_rejected", {"raw": "json", "ipv4": "empty", "api": "json"},
                 ["raw", "ipv4", "api"], 1, False)
        exercise(shell, "bad_shell_syntax_rejected", {"raw": "bad_syntax",
                                                     "ipv4": "bad_syntax",
                                                     "api": "bad_syntax"},
                 ["raw", "ipv4", "api"], 1, False)
        exercise(shell, "exit_propagation", {"raw": "exit7"}, ["raw"], 7, True)
        import_args = ("--script", "config-import.sh")
        exercise(shell, "import_raw_reset_then_ipv4_good",
                 {"raw": "fail", "ipv4": "good"}, ["raw", "ipv4"], 0, True,
                 cli_args=import_args, script_mode="import", run_marker="IMPORT_RAN",
                 script_name="config-import.sh")
        exercise(shell, "import_all_sources_fail", {},
                 ["raw", "ipv4", "api"], 1, False,
                 cli_args=import_args, script_mode="import",
                 script_name="config-import.sh")
        exercise(shell, "import_html_rejected", {"raw": "html", "ipv4": "html", "api": "html"},
                 ["raw", "ipv4", "api"], 1, False,
                 cli_args=import_args, script_mode="import",
                 script_name="config-import.sh")
        exercise(shell, "import_wrong_script_rejected",
                 {"raw": "wrong_script", "ipv4": "wrong_script", "api": "wrong_script"},
                 ["raw", "ipv4", "api"], 1, False,
                 cli_args=import_args, script_mode="import",
                 script_name="config-import.sh")
        exercise(shell, "import_bad_shell_rejected",
                 {"raw": "bad_syntax", "ipv4": "bad_syntax", "api": "bad_syntax"},
                 ["raw", "ipv4", "api"], 1, False,
                 cli_args=import_args, script_mode="import",
                 script_name="config-import.sh")
        exercise(shell, "import_check_only", {"raw": "good"}, ["raw"], 0, False,
                 cli_args=("--check", *import_args), script_mode="import",
                 run_marker="IMPORT_RAN", script_name="config-import.sh")
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
