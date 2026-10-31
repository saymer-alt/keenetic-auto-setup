#!/usr/bin/env python3
"""Offline regression for kas-exposure-check.sh: real tool, synthetic evidence.

The tool's /proc, config and Controller URL are redirected to a temporary
laboratory via its documented environment overrides. No sockets are opened,
no KeeneticOS is emulated, and no secret value is ever expected in the output
(the fixtures deliberately embed a secret that must NOT appear verbatim).
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "kas-exposure-check.sh"

SECRET = "SUPERSECRETVALUE9"

# /proc/net/tcp fixture rows: sl local_address rem_address st ...
def tcp_row(addr, port, st="0A"):
    return f"   0: {addr}:{port} 00000000:0000 {st} 00000000:00000000 00:00000000 00000000     0        0 0 1 0000000000000000 100 0 0 10 0\n"


MOCK_CURL = r"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
plan = json.loads((Path(os.environ["LAB"]) / "plan.json").read_text())
args = sys.argv[1:]
url = next(a for a in args if a.startswith("http"))
code = plan.get("controller_http", "200")
if plan.get("controller_down"):
    print("mockcurl: (7) down", file=sys.stderr)
    sys.exit(7)
print(code)
sys.exit(0)
"""

MOCK_NDMC = r"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
plan = json.loads((Path(os.environ["LAB"]) / "plan.json").read_text())
if plan.get("ndmc_proxy"):
    print("interface Proxy0")
    print("\tproxy protocol socks5")
    print("\tproxy upstream 127.0.0.1 7890")
sys.exit(0)
"""


def write_proc(lab, tcp4=None, tcp6=None):
    p = lab / "proc" / "net"
    p.mkdir(parents=True)
    if tcp4 is not None:
        (p / "tcp").write_text(tcp4)
    if tcp6 is not None:
        (p / "tcp6").write_text(tcp6)


def write_config(lab, body):
    (lab / "config.yaml").write_text(body)


BASE_CONFIG = f"""mixed-port: 7890
external-controller: 127.0.0.1:9090
secret: '{SECRET}'
"""

OPEN_CONFIG = """mixed-port: 7890
allow-lan: true
external-controller: 0.0.0.0:9090
"""


def exercise(title, want_exit, tcp4=None, tcp6=None, config=None,
             plan=None, expect_in_out=(), expect_not_in_out=(), cli_env=None):
    with tempfile.TemporaryDirectory(prefix="kas-exposure-test-") as tmp:
        lab = Path(tmp)
        fakebin = lab / "bin"
        fakebin.mkdir()
        for name, body in (("curl", MOCK_CURL), ("ndmc", MOCK_NDMC)):
            p = fakebin / name
            p.write_text(body)
            p.chmod(0o755)
        write_proc(lab, tcp4, tcp6)
        if config is not None:
            write_config(lab, config)
        (lab / "plan.json").write_text(json.dumps(plan or {}))
        env = dict(os.environ)
        env.update({
            "LAB": str(lab),
            "PATH": str(fakebin) + os.pathsep + env.get("PATH", ""),
            "TMPDIR": str(lab),
            "NO_COLOR": "1",
            "TERM": "dumb",
            "KAS_EXPOSURE_PROC_ROOT": str(lab / "proc"),
            "KAS_EXPOSURE_CONFIG": str(lab / "config.yaml"),
            "KAS_EXPOSURE_CONTROLLER_URL": "http://127.0.0.1:9090/version",
        })
        if cli_env:
            env.update(cli_env)
        r = subprocess.run(
            [shutil.which("sh") or "/bin/sh", str(TOOL)],
            text=True, capture_output=True, timeout=30, env=env, cwd=str(ROOT),
            check=False, encoding="utf-8", errors="replace",
        )
        out = r.stdout + r.stderr
        if r.returncode != want_exit:
            raise AssertionError((title, r.returncode, want_exit, out[-1500:]))
        for needle in expect_in_out:
            assert needle in out, (title, needle, out[-1500:])
        for needle in expect_not_in_out:
            assert needle not in out, (title, needle, out[-1500:])
        leftovers = [p.name for p in lab.iterdir() if p.name.startswith("kas-exposure.")]
        assert not leftovers, (title, leftovers)
        print("PASS", title)


def main():
    sh_path = shutil.which("sh")
    if not sh_path:
        print("FAIL no POSIX shell found")
        return 1

    # synthetic loopback-only service: clean audit
    exercise("loopback_only_clean", 0,
             tcp4=tcp_row("0100007F", "1ED2") + tcp_row("0100007F", "2382"),
             config=BASE_CONFIG, plan={"controller_http": "401"},
             expect_in_out=("loopback 127.0.0.1", "Controller secret: SET",
                            "authentication enforced", "No unauthenticated"),
             expect_not_in_out=(SECRET, "SUPERSECRET"))

    # wildcard IPv4 listener -> risky
    exercise("wildcard_v4_risky", 1,
             tcp4=tcp_row("00000000", "1ED2"),
             config=BASE_CONFIG,
             expect_in_out=("wildcard 0.0.0.0", "[FAIL]"))

    # wildcard IPv6 listener -> risky
    exercise("wildcard_v6_risky", 1,
             tcp6=tcp_row("00000000000000000000000000000000", "1ED2"),
             config=BASE_CONFIG,
             expect_in_out=("wildcard ::",))

    # IPv6 loopback only + open controller config -> risky via config
    exercise("open_controller_config", 1,
             tcp6=tcp_row("00000000000000000000000001000000", "2382"),
             config=OPEN_CONFIG,
             expect_in_out=("allow-lan is enabled", "non-loopback address"))

    # unauthenticated controller (HTTP 200) -> risky
    exercise("unauthenticated_controller", 1,
             tcp4=tcp_row("0100007F", "1ED2"),
             config=BASE_CONFIG, plan={"controller_http": "200"},
             expect_in_out=("WITHOUT authentication",))

    # controller down -> UNKNOWN, not a clean PASS claim about auth
    exercise("controller_down_unknown", 0,
             tcp4=tcp_row("0100007F", "1ED2"),
             config=BASE_CONFIG, plan={"controller_down": True},
             expect_in_out=("could not connect",))

    # empty secret '' -> treated as empty
    exercise("empty_secret", 1,
             tcp4=tcp_row("0100007F", "1ED2"),
             config="external-controller: 127.0.0.1:9090\nsecret: ''\n",
             plan={"controller_http": "401"},
             expect_in_out=("present but empty",))

    # no secret line at all -> risky
    exercise("no_secret", 1,
             tcp4=tcp_row("0100007F", "1ED2"),
             config="external-controller: 127.0.0.1:9090\n",
             expect_in_out=("not found in config",))

    # specific non-loopback bind -> UNKNOWN, not silently clean
    exercise("specific_bind_unknown", 0,
             tcp4=tcp_row("0100A8C0", "1ED2"),
             config=BASE_CONFIG, plan={"controller_http": "401"},
             expect_in_out=("specific 192.168.0.1", "[UNKNOWN]"))

    # missing /proc tables + missing config -> inconclusive exit 3
    exercise("no_evidence_inconclusive", 3,
             expect_in_out=("inconclusive",),
             cli_env={"KAS_EXPOSURE_CONTROLLER_URL": ""})

    # ndmc ProxyN evidence appears filtered, without secrets
    exercise("ndmc_proxyn_filtered", 0,
             tcp4=tcp_row("0100007F", "1ED2"),
             config=BASE_CONFIG, plan={"controller_http": "401", "ndmc_proxy": True},
             expect_in_out=("ProxyN: interface Proxy0",))

    # usage error
    with tempfile.TemporaryDirectory(prefix="kas-exposure-bad-") as tmp:
        lab = Path(tmp)
        env = dict(os.environ)
        env.update({"NO_COLOR": "1", "TERM": "dumb",
                    "KAS_EXPOSURE_PROC_ROOT": str(lab / "proc")})
        r = subprocess.run(
            [sh_path, str(TOOL), "--bogus"],
            text=True, capture_output=True, timeout=15, env=env, cwd=str(ROOT),
            check=False, encoding="utf-8", errors="replace",
        )
        assert r.returncode == 2, r.returncode
        print("PASS", "usage_error")

    print("ALL OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
