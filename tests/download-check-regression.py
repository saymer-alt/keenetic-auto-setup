#!/usr/bin/env python3
"""Offline regression for kas-download-check.sh: real tool, fake network only.

A mock curl/wget/nslookup directory is injected via PATH. The tool runs for
real; every networked stage is served from a per-test plan. No sockets are
opened, no bytes are executed, no KeeneticOS is emulated. Shell dialect runs
under /bin/sh and BusyBox ash when a busybox binary is available.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "kas-download-check.sh"

VALID_SETUP = ("#!/bin/sh\nPROJECT_API_CONTENTS=1\n"
               "download_project_script() { :; }\n")
VALID_IMPORT = ("#!/bin/sh\n# BEGIN MIHOMO LIFECYCLE LOCK v1\n"
                "printf 'Example start: mixed-port: 7890\\n'\n")

MOCK_CURL = r"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
lab = Path(os.environ["LAB"])
log = lab / "curl_calls.json"
calls = json.loads(log.read_text()) if log.exists() else []
calls.append(sys.argv[1:])
log.write_text(json.dumps(calls))
plan = json.loads((lab / "plan.json").read_text())

args = sys.argv[1:]
if "--version" in args:
    print("mockcurl 8.0.0")
    sys.exit(0)
if "--help" in args:
    text = "Usage: curl [options]\n"
    if plan.get("curl_help_curves"):
        text += "     --curves <list>  set TLS key exchange curves\n"
    print(text)
    sys.exit(0)

url = next(a for a in args if "://" in a)
outfile = args[args.index("-o") + 1] if "-o" in args else os.devnull

if url.startswith("telnet://"):
    # A healthy TCP connect is reported by the tool as a curl timeout while
    # waiting for telnet data; a refused/unreachable peer exits 7.
    if plan.get("tcp", "pass") == "fail":
        print("mockcurl: (7) simulated TCP refusal", file=sys.stderr)
        sys.exit(7)
    sys.exit(28)
elif "--curves" in args:
    action = plan.get("raw_compat", "pass")
elif "raw.githubusercontent.com" in url:
    action = plan.get("raw", "pass")
elif "api.github.com" in url:
    action = plan.get("api", "pass")
elif url.startswith(os.environ.get("MOSHUB_URL", "https://moshub.example/")):
    action = plan.get("moshub", "pass")
else:
    action = "pass"

bodies = {
    "pass": ("SETUP", 0, "200 74 0.05"),
    "pass_import": ("IMPORT", 0, "200 88 0.05"),
    "html": ("<html>blocked</html>", 0, "200 17 0.05"),
    "empty": ("", 0, "200 0 0.05"),
    "http404": ("<html>404</html>", 0, "404 13 0.05"),
    "http500": ("<html>500</html>", 0, "500 13 0.05"),
    "exit6": ("", 6, ""),
    "exit7": ("", 7, ""),
    "exit18": ("#!/bin/sh\nPROJECT_API_C", 18, ""),
    "exit22": ("", 22, ""),
    "exit28": ("", 28, ""),
    "exit35": ("", 35, ""),
    "exit47": ("", 47, ""),
    "exit60": ("", 60, ""),
}
if action not in bodies:
    raise RuntimeError("unknown action: " + action)
kind, rc, wout = bodies[action]
if kind == "SETUP":
    text = "#!/bin/sh\nPROJECT_API_CONTENTS=1\ndownload_project_script() { :; }\n"
elif kind == "IMPORT":
    text = "#!/bin/sh\n# BEGIN MIHOMO LIFECYCLE LOCK v1\nprintf 'Example start: mixed-port: 7890\\n'\n"
else:
    text = kind
Path(outfile).write_text(text)
if wout:
    print(wout)
if rc:
    print("mockcurl: simulated failure %s" % action, file=sys.stderr)
sys.exit(rc)
"""

MOCK_WGET = r"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
lab = Path(os.environ["LAB"])
plan = json.loads((lab / "plan.json").read_text())
args = sys.argv[1:]
outfile = args[args.index("-O") + 1] if "-O" in args else os.devnull
action = plan.get("wget", "pass")
if action == "pass":
    text = "#!/bin/sh\nPROJECT_API_CONTENTS=1\ndownload_project_script() { :; }\n"
elif action == "pass_import":
    text = "#!/bin/sh\n# BEGIN MIHOMO LIFECYCLE LOCK v1\nprintf 'Example start: mixed-port: 7890\\n'\n"
else:
    sys.exit(4)
Path(outfile).write_text(text)
sys.exit(0)
"""

MOCK_NSLOOKUP = r"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
lab = Path(os.environ["LAB"])
plan = json.loads((lab / "plan.json").read_text())
sys.exit(0 if plan.get("dns", "pass") == "pass" else 1)
"""

MOCKS = (("curl", MOCK_CURL), ("wget", MOCK_WGET), ("nslookup", MOCK_NSLOOKUP))


def make_lab(lab, plan):
    fakebin = lab / "bin"
    fakebin.mkdir(parents=True)
    for name, body in MOCKS:
        p = fakebin / name
        p.write_text(body)
        p.chmod(0o755)
    (lab / "plan.json").write_text(json.dumps(plan))
    return fakebin


def base_env(lab, fakebin):
    env = dict(os.environ)
    env.update({
        "LAB": str(lab),
        "PATH": str(fakebin) + os.pathsep + env.get("PATH", ""),
        "TMPDIR": str(lab),
        "NO_COLOR": "1",
        "TERM": "dumb",
    })
    env.pop("KAS_MOSHUB_URL", None)
    return env


def run_tool(shell, cli_args, env):
    return subprocess.run(
        [*shell, str(TOOL), *cli_args],
        text=True, capture_output=True, timeout=30, env=env, cwd=str(ROOT),
        check=False, encoding="utf-8", errors="replace",
    )


def exercise(shell, title, plan, want_exit, expect_in_out=(), expect_not_in_out=(),
             cli_args=(), env_extra=None, want_calls=None):
    with tempfile.TemporaryDirectory(prefix="kas-dlcheck-test-") as tmp:
        lab = Path(tmp)
        fakebin = make_lab(lab, plan)
        env = base_env(lab, fakebin)
        if env_extra:
            env.update(env_extra)
        r = run_tool(shell, cli_args, env)
        out = r.stdout + r.stderr
        if r.returncode != want_exit:
            raise AssertionError((title, r.returncode, want_exit, r.stdout, r.stderr))
        for needle in expect_in_out:
            assert needle in out, (title, needle, out[-1200:])
        for needle in expect_not_in_out:
            assert needle not in out, (title, needle, out[-1200:])
        if want_calls is not None:
            calls = json.loads((lab / "curl_calls.json").read_text())
            assert len(calls) == want_calls, (title, len(calls), want_calls)
        # the private stage and error sidecars are always cleaned up
        leftovers = [p.name for p in lab.iterdir() if p.name.startswith("kas-dl-check.")]
        assert not leftovers, (title, leftovers)
        # downloaded bytes must never be executed
        assert "SETUP_RAN" not in r.stdout, title
        print("PASS", " ".join(shell), title)


def exercise_nocurl(shell, title, want_exit, expect_in_out):
    """Run the tool with a PATH that has no curl at all."""
    with tempfile.TemporaryDirectory(prefix="kas-dlcheck-nocurl-") as tmp:
        lab = Path(tmp)
        fakebin = lab / "bin"
        fakebin.mkdir(parents=True)
        for name, body in MOCKS[1:]:
            p = fakebin / name
            p.write_text(body)
            p.chmod(0o755)
        (lab / "plan.json").write_text(json.dumps({}))
        env = base_env(lab, fakebin)
        # strict isolation: the system PATH must not leak a real curl in
        env["PATH"] = str(fakebin)
        r = run_tool(shell, [], env)
        out = r.stdout + r.stderr
        assert r.returncode == want_exit, (title, r.returncode, out[-800:])
        for needle in expect_in_out:
            assert needle in out, (title, needle, out[-800:])
        print("PASS", " ".join(shell), title)


def report_file_case(shell):
    with tempfile.TemporaryDirectory(prefix="kas-dlcheck-rep-") as tmp:
        lab = Path(tmp)
        rep = lab / "r.txt"
        fakebin = make_lab(lab, {"curl_help_curves": True, "raw": "exit35",
                                 "raw_compat": "exit35", "wget": "fail",
                                 "api": "exit35"})
        env = base_env(lab, fakebin)
        r = run_tool(shell, ["--report", str(rep), "--ref", "test-ref"], env)
        assert r.returncode == 1, r.returncode
        text = rep.read_text()
        assert "kas-download-check.sh" in text and "test-ref" in text
        assert "exit=35" in text and "RAW normal TLS" in text
        assert len(text) < 100000
        print("PASS", " ".join(shell), "report_file_written")


def main():
    shells = []
    sh_path = shutil.which("sh")
    if sh_path:
        shells.append([sh_path])
    bb = shutil.which("busybox")
    if bb:
        shells.append([bb, "ash"])
    if not shells:
        print("FAIL no POSIX shell found for the regression")
        return 1
    for shell in shells:
        cases = [
            ("all_sources_good", {"curl_help_curves": True}, 0,
             {"expect_in_out": ("RAW normal TLS", "GitHub Contents API"),
              "want_calls": 7}),
            ("raw35_compat_good", {"curl_help_curves": True,"raw": "exit35", "raw_compat": "pass",
                                   "wget": "fail", "api": "exit35"}, 0,
             {"expect_in_out": ("exit 35 — TLS handshake",
                                "RAW IPv4 + X25519 compatibility", "[PASS]"),
              "expect_not_in_out": ("SETUP_RAN",)}),
            ("all_fail_35", {"curl_help_curves": True,"raw": "exit35", "raw_compat": "exit35",
                             "wget": "fail", "api": "exit35"}, 1,
             {"expect_in_out": ("No delivery source", "TLS handshake"),
              "expect_not_in_out": ("SETUP_RAN",)}),
            ("dns_fail", {"dns": "fail", "raw": "exit6", "raw_compat": "exit6",
                          "wget": "fail", "api": "exit6"}, 1,
             {"expect_in_out": ("[FAIL]", "resolver failure")}),
            ("tcp_fail", {"tcp": "fail", "raw": "exit7", "raw_compat": "exit7",
                          "wget": "fail", "api": "exit7"}, 1,
             {"expect_in_out": ("TCP connection failed",)}),
            ("cert_error_60", {"raw": "exit60", "raw_compat": "exit60",
                               "wget": "fail", "api": "exit60"}, 1,
             {"expect_in_out": ("certificate verification",)}),
            ("html_all_sources", {"raw": "html", "raw_compat": "html",
                                  "wget": "fail", "api": "html"}, 1,
             {"expect_in_out": ("does not look like the KAS",)}),
            ("http_404", {"raw": "http404", "raw_compat": "http404",
                          "wget": "fail", "api": "http404"}, 1,
             {"expect_in_out": ("HTTP 404",)}),
            ("http_500", {"curl_help_curves": True,"raw": "http500", "raw_compat": "exit35",
                          "wget": "fail", "api": "exit35"}, 1,
             {"expect_in_out": ("HTTP 500",)}),
            ("partial_transfer", {"curl_help_curves": True,"raw": "exit18", "raw_compat": "exit18",
                                  "wget": "fail", "api": "exit18"}, 1,
             {"expect_in_out": ("mid-transfer",)}),
            ("curl_without_curves", {"curl_help_curves": False}, 0,
             {"expect_in_out": ("UNSUPPORTED", "--curves", "RAW normal TLS"),
              "want_calls": 6}),
            ("moshub_without_url", {"curl_help_curves": True}, 0,
             {"expect_in_out": ("KAS_MOSHUB_URL is not set",),
              "cli_args": ("--moshub",)}),
            ("moshub_probe_pass", {"curl_help_curves": True, "moshub": "pass"}, 0,
             {"expect_in_out": ("Optional mirror (KAS_MOSHUB_URL)",),
              "cli_args": ("--moshub",),
              "env_extra": {"KAS_MOSHUB_URL": "https://moshub.example/kas/bootstrap.sh"}}),
            ("one_route_good_other_fail", {"curl_help_curves": True,"raw": "exit35", "raw_compat": "exit35",
                                           "wget": "fail", "api": "pass"}, 0,
             {"expect_in_out": ("exit 35 — TLS handshake", "GitHub Contents API"),
              "expect_not_in_out": ("SETUP_RAN",)}),
            ("import_script_markers", {"curl_help_curves": True,
                                       "raw": "pass_import",
                                       "raw_compat": "pass_import",
                                       "wget": "pass_import", "api": "pass_import"}, 0,
             {"cli_args": ("--script", "config-import.sh", "--ref", "test-ref")}),
            ("import_markers_wrong_script", {"curl_help_curves": True}, 1,
             {"cli_args": ("--script", "config-import.sh"),
              "expect_in_out": ("does not look like the KAS config-import.sh",)}),
            ("usage_error", {}, 2, {"cli_args": ("--bogus",)}),
            ("bad_script_arg", {}, 2, {"cli_args": ("--script", "evil.sh")}),
            ("bad_ref_arg", {}, 2, {"cli_args": ("--ref", "a b")}),
        ]
        for title, plan, want_exit, opts in cases:
            if plan.get("__nocurl__"):
                exercise_nocurl(shell, title, want_exit, opts.get("expect_in_out", ()))
                continue
            exercise(shell, title, plan, want_exit, **opts)
        exercise_nocurl(shell, "curl_missing", 1, ("curl is not installed",))
        report_file_case(shell)
    print("ALL OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
