#!/usr/bin/env python3
"""Offline regression for kas-exposure-check.sh: real tool, synthetic evidence.

The tool's /proc, config and Controller URL are redirected to a temporary
laboratory via its documented environment overrides. No sockets are opened,
no KeeneticOS is emulated, and no secret value is ever expected in the output
(the fixtures deliberately embed secrets that must NOT appear verbatim).

Semantics under test (issue #159 owner contract, 2026-11-01):
- An open, passwordless Mihomo Controller is an accepted KAS deployment
  contract. The audit reports FACTS (socket binds, local unauthenticated
  access) and never treats them as violations.
- YAML null secret forms (`secret:`, `secret: null`, `secret: ~`,
  `secret: ""`) mean DISABLED authentication; a *quoted* string "null" is a
  real password and means ENABLED.
- The only FAIL/exit 1 is a contradiction between the declared authentication
  state and the live unauthenticated probe.
- Wildcard/non-loopback binds are facts with explicit "external reachability
  NOT verified" caveats, not counted as vulnerabilities.
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
assert "--noproxy" in args and args[args.index("--noproxy") + 1] == "*", args
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

# Accepted KAS deployment contract: open controller, no usable secret.
CONTRACT_CONFIG = """mixed-port: 7890
allow-lan: true
external-controller: 0.0.0.0:9090
"""


def config_with_secret(secret_line):
    return "mixed-port: 7890\nexternal-controller: 127.0.0.1:9090\n" + secret_line + "\n"


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

    # --- declared ENABLED + probe rejects: consistent, exit 0 -----------------
    exercise("loopback_enabled_401_consistent", 0,
             tcp4=tcp_row("0100007F", "1ED2") + tcp_row("0100007F", "2382"),
             config=BASE_CONFIG, plan={"controller_http": "401"},
             expect_in_out=("loopback 127.0.0.1", "port 7890", "port 9090",
                            "Mihomo mixed/proxy port", "Mihomo Controller",
                            "Controller authentication: ENABLED",
                            "Local unauthenticated API access: REJECTED",
                            "authentication enforced, consistent with declared ENABLED",
                            "Audit complete"),
             expect_not_in_out=(SECRET, "SUPERSECRET", "port 1ED2", "port 2382"))

    # --- YAML null secret forms mean DISABLED; 200 is consistent, exit 0 ------
    exercise("secret_yaml_null_is_disabled", 0,
             tcp4=tcp_row("0100007F", "1ED2"),
             config=config_with_secret("secret: null"), plan={"controller_http": "200"},
             expect_in_out=("Controller authentication: DISABLED",
                            "Local unauthenticated API access: CONFIRMED",
                            "consistent with declared DISABLED",
                            "accepted KAS deployment contract",
                            "NOT verified"),
             expect_not_in_out=(SECRET, "[FAIL]", "port 1ED2"))

    exercise("secret_bare_colon_is_disabled", 0,
             tcp4=tcp_row("0100007F", "1ED2"),
             config=config_with_secret("secret:"), plan={"controller_http": "200"},
             expect_in_out=("Controller authentication: DISABLED",),
             expect_not_in_out=("[FAIL]",))

    exercise("secret_tilde_is_disabled", 0,
             tcp4=tcp_row("0100007F", "1ED2"),
             config=config_with_secret("secret: ~"), plan={"controller_http": "200"},
             expect_in_out=("Controller authentication: DISABLED",),
             expect_not_in_out=("[FAIL]",))

    exercise("secret_empty_dquotes_is_disabled", 0,
             tcp4=tcp_row("0100007F", "1ED2"),
             config=config_with_secret('secret: ""'), plan={"controller_http": "200"},
             expect_in_out=("Controller authentication: DISABLED",),
             expect_not_in_out=("[FAIL]",))

    exercise("secret_empty_squotes_is_disabled", 0,
             tcp4=tcp_row("0100007F", "1ED2"),
             config=config_with_secret("secret: ''"), plan={"controller_http": "200"},
             expect_in_out=("Controller authentication: DISABLED",),
             expect_not_in_out=("[FAIL]",))

    exercise("secret_absent_is_disabled", 0,
             tcp4=tcp_row("0100007F", "1ED2"),
             config="mixed-port: 7890\nexternal-controller: 127.0.0.1:9090\n",
             plan={"controller_http": "200"},
             expect_in_out=("Controller authentication: DISABLED",
                            "no top-level secret line",
                            "accepted KAS deployment contract"),
             expect_not_in_out=("[FAIL]",))

    # --- quoted "null" is a real password: ENABLED ----------------------------
    exercise("secret_squoted_null_is_enabled_contradiction", 1,
             tcp4=tcp_row("0100007F", "1ED2"),
             config=config_with_secret("secret: 'null'"), plan={"controller_http": "200"},
             expect_in_out=("Controller authentication: ENABLED",
                            "not being enforced"),
             expect_not_in_out=("accepted KAS deployment contract",))

    exercise("secret_dquoted_null_is_enabled_contradiction", 1,
             tcp4=tcp_row("0100007F", "1ED2"),
             config=config_with_secret('secret: "null"'), plan={"controller_http": "200"},
             expect_in_out=("Controller authentication: ENABLED",
                            "not being enforced"),
             expect_not_in_out=("[FAIL] Controller secret",))

    # --- comments and quoting corner cases ------------------------------------
    exercise("secret_quoted_hash_is_enabled", 1,
             tcp4=tcp_row("0100007F", "1ED2"),
             config=config_with_secret("secret: 'pa#ss'"), plan={"controller_http": "200"},
             expect_in_out=("Controller authentication: ENABLED", "not being enforced"),
             expect_not_in_out=("pa#ss",))

    exercise("secret_unquoted_with_comment_is_enabled", 1,
             tcp4=tcp_row("0100007F", "1ED2"),
             config=config_with_secret("secret: realvalue # set manually"),
             plan={"controller_http": "200"},
             expect_in_out=("Controller authentication: ENABLED", "not being enforced"),
             expect_not_in_out=("realvalue",))

    exercise("secret_null_with_comment_is_disabled", 0,
             tcp4=tcp_row("0100007F", "1ED2"),
             config=config_with_secret("secret: null # legacy placeholder"),
             plan={"controller_http": "200"},
             expect_in_out=("Controller authentication: DISABLED",),
             expect_not_in_out=("[FAIL]",))

    exercise("secret_unbalanced_quote_is_unknown", 0,
             tcp4=tcp_row("0100007F", "1ED2"),
             config=config_with_secret('secret: "oops'), plan={"controller_http": "200"},
             expect_in_out=("Controller secret: UNKNOWN",
                            "Controller authentication: UNKNOWN"),
             expect_not_in_out=("[FAIL]", "oops"))

    # --- open contract deployment: wildcard binds are facts, exit 0 -----------
    exercise("wildcard_v4_is_fact_not_vulnerability", 0,
             tcp4=tcp_row("00000000", "1ED2"),
             config=CONTRACT_CONFIG, plan={"controller_http": "200"},
             expect_in_out=("wildcard 0.0.0.0", "port 7890", "NOT verified",
                            "Controller authentication: DISABLED",
                            "Local unauthenticated API access: CONFIRMED"),
             expect_not_in_out=("[FAIL]", "risky binding"))

    exercise("wildcard_v6_is_fact_not_vulnerability", 0,
             tcp6=tcp_row("00000000000000000000000000000000", "1ED2"),
             config=CONTRACT_CONFIG, plan={"controller_http": "200"},
             expect_in_out=("wildcard ::", "port 7890", "NOT verified"),
             expect_not_in_out=("[FAIL]", "risky binding"))

    exercise("allow_lan_is_intended_info", 0,
             tcp4=tcp_row("0100007F", "1ED2"),
             config=config_with_secret("secret: null").replace(
                 "mixed-port: 7890\n", "mixed-port: 7890\nallow-lan: true\n"),
             plan={"controller_http": "200"},
             expect_in_out=("allow-lan: true", "Controller authentication: DISABLED"),
             expect_not_in_out=("[FAIL]",))

    exercise("nonloopback_controller_is_info", 0,
             tcp4=tcp_row("0100007F", "1ED2"),
             config=config_with_secret("secret: null").replace(
                 "external-controller: 127.0.0.1:9090",
                 "external-controller: 0.0.0.0:9090"),
             plan={"controller_http": "200"},
             expect_in_out=("Controller authentication: DISABLED",),
             expect_not_in_out=("[FAIL]",))

    # --- contradictions are the only FAIL/exit 1 ------------------------------
    exercise("declared_enabled_but_200_contradiction", 1,
             tcp4=tcp_row("0100007F", "1ED2"),
             config=BASE_CONFIG, plan={"controller_http": "200"},
             expect_in_out=("Controller authentication: ENABLED",
                            "Local unauthenticated API access: CONFIRMED",
                            "not being enforced"),
             expect_not_in_out=(SECRET, "accepted KAS deployment contract"))

    exercise("declared_disabled_but_401_contradiction", 1,
             tcp4=tcp_row("0100007F", "1ED2"),
             config=CONTRACT_CONFIG, plan={"controller_http": "401"},
             expect_in_out=("Contradiction", "DISABLED", "different config"))

    # --- unknown / unavailable probe keeps facts, exit 0 ----------------------
    exercise("controller_down_declared_state_kept", 0,
             tcp4=tcp_row("0100007F", "1ED2"),
             config=BASE_CONFIG, plan={"controller_down": True},
             expect_in_out=("Controller authentication: ENABLED",
                            "Local unauthenticated API access: UNKNOWN",
                            "could not connect"))

    exercise("controller_5xx_is_unknown", 0,
             tcp4=tcp_row("0100007F", "1ED2"),
             config=config_with_secret("secret: null"), plan={"controller_http": "500"},
             expect_in_out=("Local unauthenticated API access: UNKNOWN",),
             expect_not_in_out=("[FAIL]",))

    # --- inconclusive / non-socket paths keep prior exit codes ----------------
    exercise("no_proc_evidence_inconclusive_exit3", 3,
             expect_in_out=("inconclusive",),
             cli_env={"KAS_EXPOSURE_CONTROLLER_URL": ""})

    exercise("specific_bind_unknown", 0,
             tcp4=tcp_row("0100A8C0", "1ED2"),
             config=BASE_CONFIG, plan={"controller_http": "401"},
             expect_in_out=("specific 192.168.0.1", "[UNKNOWN]"))

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
