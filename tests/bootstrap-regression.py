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
BAD_SYNTAX = GOOD + "if then\\n"
MOCK = r"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args=sys.argv[1:]
assert '-fSsL' in args and '--connect-timeout' in args and '--max-time' in args
assert args[args.index('--connect-timeout')+1]=='7'
assert args[args.index('--max-time')+1]=='25'
assert '-k' not in args and '--insecure' not in args
assert '-o' in args
url=args[-1]
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
if action=='fail':
    dst.write_text('#!/bin/sh\\necho PARTIAL_SHOULD_NEVER_RUN\\n')
    sys.exit(28)
if action=='good':
    dst.write_text(os.environ['GOOD_SCRIPT'])
elif action=='bad_syntax':
    dst.write_text(os.environ['BAD_SYNTAX'])
elif action=='html':
    dst.write_text('<html>not a shell script</html>')
elif action=='json':
    dst.write_text('{"content":"base64"}')
elif action=='empty':
    dst.write_text('')
elif action=='exit7':
    dst.write_text(os.environ['GOOD_SCRIPT'].replace(
        "printf 'SETUP_RAN\\n'","printf 'SETUP_RAN\\n'; exit 7"))
else:
    raise RuntimeError(action)
"""


def exercise(shell, title, plan, want_calls, want_exit, want_run):
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
            "KAS_BOOTSTRAP_REF": "test-ref",
            "NO_COLOR": "1",
            "TERM": "dumb",
        })
        r = subprocess.run(
            shell + [str(ROOT / "bootstrap.sh")],
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
        assert ("SETUP_RAN" in r.stdout) == want_run, (
            title, r.stdout, r.stderr)
        assert not list(lab.glob("kas-setup.*")), (title, "staged secret not removed")
        assert "PARTIAL_SHOULD_NEVER_RUN" not in r.stdout, title
        assert "Could not fetch valid KAS setup.sh" in r.stderr if not want_run and title != "invalid_ref" else True
        print("PASS", shell, title)


def main():
    shells = [["/bin/sh"]]
    bb = shutil.which("busybox")
    if bb:
        shells.append([bb, "ash"])
    for shell in shells:
        exercise(shell, "raw_good", {"raw": "good"}, ["raw"], 0, True)
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
