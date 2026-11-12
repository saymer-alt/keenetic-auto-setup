#!/usr/bin/env python3
"""Offline regression for kas-network-doctor.sh: real tool, fake network only.

A mock curl/nslookup/ndmc/netstat/jq/pgrep directory is injected via PATH.
The tool runs for real; every networked stage is served from a per-test
plan. No sockets are opened, no bytes are executed, no KeeneticOS is
emulated. Shell dialects: dash-compatible /bin/sh and BusyBox ash when a
busybox binary is available.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "kas-network-doctor.sh"

MOCK_CURL = r"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
lab = Path(os.environ["LAB"])
plan = json.loads((lab / "plan.json").read_text())
log = lab / "curl_calls.json"
calls = json.loads(log.read_text()) if log.exists() else []
calls.append(sys.argv[1:])
log.write_text(json.dumps(calls))

args = sys.argv[1:]
if "--version" in args:
    print("mockcurl 8.5.0 (mock) libcurl")
    print("Features: AsynchDNS IPv6 Largefile SSL UnixSockets")
    protocols = "dial file ftp ftps gopher http https imap mqtt pop3 rtsp sftp smb smtp telnet tftp ws"
    if plan.get("curl_no_telnet"):
        protocols = protocols.replace(" telnet", "")
    print("Protocols: " + protocols)
    sys.exit(0)

url = next(a for a in args if "://" in a)

if url.startswith("telnet://"):
    action = plan.get("tcp", "pass")
    if action == "refused":
        print("mockcurl: (7) simulated TCP refusal", file=sys.stderr)
        sys.exit(7)
    if action == "timeout":
        print("mockcurl: (28) connect timed out", file=sys.stderr)
        sys.exit(28)
    if action == "reset":
        print("mockcurl: (56) peer closed the probe connection", file=sys.stderr)
        sys.exit(56)
    sys.exit(0)  # connected, stdin EOF ends the probe

if "api.ipify.org" in url:
    if plan.get("egress", "pass") != "pass":
        print("mockcurl: (28) egress observation timed out", file=sys.stderr)
        sys.exit(28)
    via_socks = "--socks5-hostname" in args
    bound = args[args.index("--interface") + 1] if "--interface" in args else None
    if bound:
        per_if = plan.get("egress_by_interface", {})
        action = per_if.get(bound, per_if.get("*", "pass"))
        if action == "bind_error":
            print("mockcurl: (45) could not set interface bind", file=sys.stderr)
            sys.exit(45)
        addr = action
    else:
        addr = plan.get("egress_socks", "198.51.100.9") if via_socks else plan.get("egress_direct", "203.0.113.10")
    outfile = args[args.index("-o") + 1] if "-o" in args else None
    if outfile:
        Path(outfile).write_text(addr + "\n")
    else:
        print(addr)
    sys.exit(0)

if "127.0.0.1:9090" in url:
    if plan.get("controller_down"):
        print("mockcurl: (7) simulated controller refusal", file=sys.stderr)
        sys.exit(7)
    path = "proxies" if url.endswith("/proxies") else "version"
    code = str(plan.get("controller_" + path, plan.get("controller", 200)))
    if "--socks5-hostname" in args:
        code = str(plan.get("socks_probe", "pass"))
        if code == "pass":
            print("", end="")
            print("200|http://target.example/", end="")
            sys.exit(0)
        if code == "refused":
            print("mockcurl: (7) simulated SOCKS refusal", file=sys.stderr)
            sys.exit(7)
        print("mockcurl: (28) socks probe timed out", file=sys.stderr)
        sys.exit(28)
    if plan.get("controller_secret") and "-H" not in args:
        code = "401"
    print(code)
    sys.exit(0)

# target probe (http or https); socks probes hit the same URL but use
# their own plan key and never inherit the direct-target failure
is_socks = "--socks5-hostname" in args
if is_socks:
    code = str(plan.get("socks_probe", "pass"))
    if code == "pass":
        print("200|http://target.example/")
        sys.exit(0)
    if code == "refused":
        print("mockcurl: (7) simulated SOCKS refusal", file=sys.stderr)
        sys.exit(7)
    print("mockcurl: (28) socks probe timed out", file=sys.stderr)
    sys.exit(28)
action = plan.get("target", "pass")
bodies = {
    "pass": (0, "200|http://target.example/"),
    "http200": (0, "200|http://target.example/"),
    "http500": (0, "500|http://target.example/"),
    "http403": (0, "403|http://target.example/"),
    "redirect": (0, "302|http://target.example/|http://192.0.2.99/"),
    "portal": (0, "302|http://target.example/|http://192.168.88.1/login.html"),
    "redirect_secret": (0, "302|http://target.example/|https://user:secret@example.com/callback?token=TOPSECRET"),
    "redirect_path_secret": (0, "302|http://target.example/|https://192.0.2.99/dl/TOPSECRET/x"),
    "exit6": (6, ""),
    "exit7": (7, ""),
    "exit28": (28, ""),
    "exit35": (35, ""),
    "exit56": (56, ""),
    "exit60": (60, ""),
    "exit63": (63, "200|https://target.example/"),
}
if action not in bodies:
    raise RuntimeError("unknown target action: " + action)
rc, wout = bodies[action]
if wout:
    print(wout)   # real curl prints -w output even on failure exits
if rc:
    print("mockcurl: simulated target failure exit=%s" % rc, file=sys.stderr)
sys.exit(rc)
"""

MOCK_NSLOOKUP = r"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
lab = Path(os.environ["LAB"])
plan = json.loads((lab / "plan.json").read_text())
args = sys.argv[1:]
server = args[1] if len(args) > 1 else "system"
key = "dns_" + ("custom" if len(args) > 1 else "system")
action = plan.get(key, plan.get("dns", "pass"))
if action == "hang":
    import time
    time.sleep(45)
if action == "pass":
    print("Server:\t192.0.2.53")
    print("Address:\t192.0.2.53#53")
    print("")
    print("Name:      target.example")
    print("Address 1: 93.184.216.34")
    sys.exit(0)
if action == "nxdomain":
    print("Server:\t192.0.2.53")
    print("** server can't find target.example: NXDOMAIN", file=sys.stderr)
    sys.exit(1)
if action == "servfail":
    print("** server can't find target.example: SERVFAIL", file=sys.stderr)
    sys.exit(1)
if action == "refused":
    print("** server can't find target.example: REFUSED", file=sys.stderr)
    sys.exit(1)
if action == "timeout":
    print(";; connection timed out; no servers could be reached", file=sys.stderr)
    sys.exit(1)
if action == "tempfail":
    print("nslookup: can't resolve 'target.example': Temporary failure in name resolution", file=sys.stderr)
    sys.exit(1)
raise RuntimeError("unknown dns action: " + action)
"""

MOCK_NETSTAT = r"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
lab = Path(os.environ["LAB"])
plan = json.loads((lab / "plan.json").read_text())
if plan.get("socks_listening", True):
    print("tcp  0  0 127.0.0.1:7890  0.0.0.0:*  LISTEN")
sys.exit(0)
"""

MOCK_JQ = r"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
lab = Path(os.environ["LAB"])
plan = json.loads((lab / "plan.json").read_text())
if plan.get("jq_group_found", True):
    print(plan.get("sel_now", "PROXY-NODE-1"))
else:
    sys.exit(0)
"""

MOCK_NDMC = r"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
lab = Path(os.environ["LAB"])
plan = json.loads((lab / "plan.json").read_text())
if plan.get("ndmc", "bridge") == "bridge":
    print("interface Proxy0")
    print("\tproxy protocol socks5")
    print("\tproxy upstream 127.0.0.1:7890")
    print("\tdescription mihomo t2s0 PROVIDER-TOPSECRET")
elif plan.get("ndmc") == "none":
    print("interface Bridge0")
    print("\trole home")
sys.exit(0)
"""

MOCK_PGREP = r"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
lab = Path(os.environ["LAB"])
plan = json.loads((lab / "plan.json").read_text())
sys.exit(0 if plan.get("magitrickle_running", True) else 1)
"""

MOCK_IP = r"""#!/usr/bin/env python3
# Read-only mock of the `ip` applet for the interface-vantage fixtures
# (issue #323). Supports exactly what kas-network-doctor.sh queries:
# addr show (discovery) and route get (read-only route evidence).
import json, os, sys
from pathlib import Path
lab = Path(os.environ["LAB"])
plan = json.loads((lab / "plan.json").read_text())
cfg = plan.get("ip", {})
args = sys.argv[1:]
if "-4" in args and "-o" in args and "addr" in args:
    dev = args[args.index("dev") + 1] if "dev" in args else ""
    scope_global = "scope" in args and "global" in args
    lines = cfg.get("addr", {}).get(dev, [])
    if scope_global:
        lines = [l for l in lines if "scope global" in l]
    for line in lines:
        print(line)
    sys.exit(0)
if "route" in args and "get" in args:
    out = cfg.get("route_get", "")
    if out:
        print(out)
    sys.exit(0)
sys.exit(0)
"""

MOCKS = (
    ("curl", MOCK_CURL),
    ("nslookup", MOCK_NSLOOKUP),
    ("netstat", MOCK_NETSTAT),
    ("jq", MOCK_JQ),
    ("ndmc", MOCK_NDMC),
    ("pgrep", MOCK_PGREP),
    ("ip", MOCK_IP),
)


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
        "MIHOMO_API_SECRET": "",
        "MIHOMO_CONTROLLER_URL": "http://127.0.0.1:9090",
    })
    return env


def run_tool(shell, cli_args, env):
    return subprocess.run(
        [*shell, str(TOOL), *cli_args],
        text=True, capture_output=True, timeout=60, env=env, cwd=str(ROOT),
        check=False, encoding="utf-8", errors="replace",
    )


def exercise(shell, title, plan, want_exit, expect_in=(), expect_not_in=(),
             cli_args=None, env_extra=None, want_curl_calls=None):
    cli_args = list(cli_args or [])
    with tempfile.TemporaryDirectory(prefix="kas-netdoc-test-") as tmp:
        lab = Path(tmp)
        fakebin = make_lab(lab, plan)
        env = base_env(lab, fakebin)
        if env_extra:
            env.update(env_extra)
        r = run_tool(shell, cli_args, env)
        out = r.stdout + r.stderr
        if r.returncode != want_exit:
            raise AssertionError((title, r.returncode, want_exit, r.stdout, r.stderr))
        for needle in expect_in:
            assert needle in out, (title, needle, out[-1500:])
        for needle in expect_not_in:
            assert needle not in out, (title, needle, out[-1500:])
        if want_curl_calls is not None:
            calls = json.loads((lab / "curl_calls.json").read_text())
            assert len(calls) == want_curl_calls, (title, len(calls), want_curl_calls, calls)
        leftovers = [p.name for p in lab.iterdir() if p.name.startswith("kas-net-doctor.err.")]
        assert not leftovers, (title, leftovers)
        print("PASS", " ".join(shell), title)
        return out


def json_case(shell, title, plan, cli_args):
    with tempfile.TemporaryDirectory(prefix="kas-netdoc-json-") as tmp:
        lab = Path(tmp)
        jf = lab / "report.json"
        fakebin = make_lab(lab, plan)
        env = base_env(lab, fakebin)
        args = list(cli_args) + ["--json", str(jf)]
        r = run_tool(shell, args, env)
        out = r.stdout + r.stderr
        assert jf.exists(), (title, "json file missing", out[-800:])
        text = jf.read_text()
        data = json.loads(text)  # raises with a clear traceback if invalid
        assert data["schema"] == "network-diagnostics/v1", (title, data["schema"])
        assert data["verdict"]["summary"] in ("ok", "confirmed_failure", "inconclusive"), title
        assert isinstance(data["exit_code"], int), title
        assert data["budget"]["requests_used"] <= data["budget"]["requests_limit"], title
        allowed = {"PASS", "FAIL", "UNKNOWN", "NOT TESTED", "UNSUPPORTED"}
        ids_seen = []
        for chk in data["checks"]:
            assert chk["status"] in allowed, (title, chk)
            assert isinstance(chk["id"], str) and chk["id"], title
            ids_seen.append(chk["id"])
        assert len(ids_seen) == len(set(ids_seen)), (title, "duplicate check ids", ids_seen)
        counts = data["counts"]
        total = sum(counts.values())
        assert total == len(data["checks"]), (title, counts, len(data["checks"]))
        print("PASS", " ".join(shell), title, "(json ok, %d checks)" % len(ids_seen))
        return data, ids_seen, text


def make_vantage_sysfs(lab, plan):
    """Fake /sys/class/net tree driven by plan['sysfs']: {dev: state}."""
    root = lab / "sysfs" / "net"
    root.mkdir(parents=True)
    for dev, state in (plan.get("sysfs") or {}).items():
        d = root / dev
        d.mkdir()
        (d / "operstate").write_text(state + "\n")
    return root


def test_vantage_group(shell):
    """Issue #323 stage A/B fixtures: interface vantage selection with
    honest route proof. Positive: a second WAN with a distinct egress
    address proves the bound path (egress-distinct). Negative: missing
    interface, bind error, same-egress ambiguity, Mihomo-TUN/service
    devices excluded from ALL, budget scaling reported, --list-vantages
    probeless, and the static no-route-mutation guard."""
    if not shutil.which("python3") and not shutil.which("python"):
        print("SKIP vantage group (python3 required for the mocks)")
        return
    target_args = ["--target", "target.example"]

    # V1 — --list-vantages: discovery only, no probes, works without --target.
    with tempfile.TemporaryDirectory(prefix="kas-netdoc-van-") as tmp:
        lab = Path(tmp)
        plan = {"sysfs": {"eth0": "up", "wan2": "up", "mihomo-tun0": "up",
                          "lo": "unknown", "docker0": "up"},
                "ip": {"addr": {"eth0": ["2: eth0 inet 198.51.100.2/24 scope global eth0"],
                                "wan2": ["3: wan2 inet 203.0.113.2/24 scope global wan2"],
                                "mihomo-tun0": ["5: mihomo-tun0 inet 198.18.0.1/16 scope global mihomo-tun0"]}}}
        fakebin = make_lab(lab, plan)
        sysfs = make_vantage_sysfs(lab, plan)
        env = base_env(lab, fakebin)
        env["KAS_DOCTOR_SYSFS_NET"] = str(sysfs)
        r = run_tool(shell, ["--list-vantages"], env)
        out = r.stdout + r.stderr
        assert r.returncode == 0, (r.returncode, out[-800:])
        assert "if:eth0" in out and "if:wan2" in out, out[-800:]
        assert "mihomo-tun0" not in out and "docker0" not in out, out[-800:]
        assert not (lab / "curl_calls.json").exists(), "list-vantages must not probe"
        print("PASS", " ".join(shell), "v1 list-vantages discovery probeless")

    # V2 — distinct egress: the bound path proves a different route.
    with tempfile.TemporaryDirectory(prefix="kas-netdoc-van-") as tmp:
        lab = Path(tmp)
        plan = {"sysfs": {"eth0": "up", "wan2": "up"},
                "ip": {"addr": {"eth0": ["2: eth0 inet 198.51.100.2/24 scope global eth0"],
                                "wan2": ["3: wan2 inet 203.0.113.2/24 scope global wan2"]},
                       "route_get": "203.0.113.0/24 dev wan2 scope link src 203.0.113.2"},
                "egress_direct": "198.51.100.1",
                "egress_by_interface": {"203.0.113.2": "203.0.113.9"}}
        jf = lab / "report.json"
        fakebin = make_lab(lab, plan)
        sysfs = make_vantage_sysfs(lab, plan)
        env = base_env(lab, fakebin)
        env["KAS_DOCTOR_SYSFS_NET"] = str(sysfs)
        args = target_args + ["--vantage", "if:wan2", "--json", str(jf)]
        r = run_tool(shell, args, env)
        out = r.stdout + r.stderr
        assert r.returncode == 0, (r.returncode, out[-1200:])
        data = json.loads(jf.read_text())
        assert len(data.get("vantages", [])) == 1, data.get("vantages")
        v = data["vantages"][0]
        assert v["dev"] == "wan2" and v["route_proof"] == "egress-distinct", v
        assert v["egress"] == "203.0.113.9", v
        ids = [c["id"] for c in data["checks"]]
        for needed in ("vantage.if.wan2.discovery", "vantage.if.wan2.route.get",
                       "dns.vantage.if.wan2", "tcp.vantage.if.wan2",
                       "tls.vantage.if.wan2", "http.vantage.if.wan2",
                       "egress.vantage.if.wan2"):
            assert needed in ids, (needed, ids)
        assert data["budget"]["requests_limit"] == 20, data["budget"]
        # the default chain evidence stays untouched by the vantage slice
        assert data["egress"]["direct"] == "198.51.100.1", data["egress"]
        assert any(c["id"] == "dns.router" and c["status"] == "PASS"
                   for c in data["checks"])
        # the bound probes carry --interface in the curl call log
        calls = json.loads((lab / "curl_calls.json").read_text())
        assert any("--interface" in c and "203.0.113.2" in c for c in calls), calls[:4]
        print("PASS", " ".join(shell), "v2 bound vantage egress-distinct (json ok)")

    # V3 — same egress as default: the ambiguity is reported, never a PASS.
    with tempfile.TemporaryDirectory(prefix="kas-netdoc-van-") as tmp:
        lab = Path(tmp)
        plan = {"sysfs": {"eth0": "up", "wan2": "up"},
                "ip": {"addr": {"eth0": ["2: eth0 inet 198.51.100.2/24 scope global eth0"],
                                "wan2": ["3: wan2 inet 203.0.113.2/24 scope global wan2"]},
                       "route_get": "default dev wan2 src 203.0.113.2"},
                "egress_direct": "198.51.100.1",
                "egress_by_interface": {"203.0.113.2": "198.51.100.1"}}
        jf = lab / "report.json"
        fakebin = make_lab(lab, plan)
        env = base_env(lab, fakebin)
        env["KAS_DOCTOR_SYSFS_NET"] = str(make_vantage_sysfs(lab, plan))
        r = run_tool(shell, target_args + ["--vantage", "if:wan2", "--json", str(jf)], env)
        data = json.loads(jf.read_text())
        assert data["vantages"][0]["route_proof"] == "egress-same-as-default", data["vantages"]
        print("PASS", " ".join(shell), "v3 same-egress reported as ambiguous")

    # V4 — missing interface: FAIL discovery, run still completes honestly.
    with tempfile.TemporaryDirectory(prefix="kas-netdoc-van-") as tmp:
        lab = Path(tmp)
        plan = {"sysfs": {"eth0": "up"},
                "ip": {"addr": {"eth0": ["2: eth0 inet 198.51.100.2/24 scope global eth0"]}}}
        jf = lab / "report.json"
        fakebin = make_lab(lab, plan)
        env = base_env(lab, fakebin)
        env["KAS_DOCTOR_SYSFS_NET"] = str(make_vantage_sysfs(lab, plan))
        r = run_tool(shell, target_args + ["--vantage", "if:eth9", "--json", str(jf)], env)
        assert r.returncode == 0, (r.returncode, (r.stdout + r.stderr)[-800:])
        data = json.loads(jf.read_text())
        ids = [c["id"] for c in data["checks"]]
        assert "vantage.if.eth9.discovery" in ids, ids
        rec = next(c for c in data["checks"] if c["id"] == "vantage.if.eth9.discovery")
        assert rec["status"] == "FAIL", rec
        assert data["vantages"][0]["route_proof"] == "unproven", data["vantages"]
        print("PASS", " ".join(shell), "v4 missing interface fails the vantage record only")

    # V5 — bind error: the egress observation is UNKNOWN, route proof unproven.
    with tempfile.TemporaryDirectory(prefix="kas-netdoc-van-") as tmp:
        lab = Path(tmp)
        plan = {"sysfs": {"eth0": "up", "wan2": "up"},
                "ip": {"addr": {"eth0": ["2: eth0 inet 198.51.100.2/24 scope global eth0"],
                                "wan2": ["3: wan2 inet 203.0.113.2/24 scope global wan2"]},
                       "route_get": "203.0.113.0/24 dev wan2 scope link src 203.0.113.2"},
                "egress_direct": "198.51.100.1",
                "egress_by_interface": {"203.0.113.2": "bind_error"}}
        jf = lab / "report.json"
        fakebin = make_lab(lab, plan)
        env = base_env(lab, fakebin)
        env["KAS_DOCTOR_SYSFS_NET"] = str(make_vantage_sysfs(lab, plan))
        r = run_tool(shell, target_args + ["--vantage", "if:wan2", "--json", str(jf)], env)
        data = json.loads(jf.read_text())
        ids = [c["id"] for c in data["checks"]]
        rec = next(c for c in data["checks"] if c["id"] == "egress.vantage.if.wan2")
        assert rec["status"] == "UNKNOWN", rec
        assert data["vantages"][0]["route_proof"] == "unproven", data["vantages"]
        print("PASS", " ".join(shell), "v5 bind error keeps route proof unproven")

    # V6 — ALL mode: service devices excluded, budget scaled per vantage.
    with tempfile.TemporaryDirectory(prefix="kas-netdoc-van-") as tmp:
        lab = Path(tmp)
        plan = {"sysfs": {"eth0": "up", "wan2": "up", "mihomo-tun0": "up",
                          "lo": "unknown", "docker0": "up", "veth9": "up"},
                "ip": {"addr": {"eth0": ["2: eth0 inet 198.51.100.2/24 scope global eth0"],
                                "wan2": ["3: wan2 inet 203.0.113.2/24 scope global wan2"],
                                "mihomo-tun0": ["5: mihomo-tun0 inet 198.18.0.1/16 scope global mihomo-tun0"]},
                       "route_get": "default dev wan2 src 203.0.113.2"},
                "egress_direct": "198.51.100.1",
                "egress_by_interface": {"203.0.113.2": "203.0.113.9"}}
        jf = lab / "report.json"
        fakebin = make_lab(lab, plan)
        env = base_env(lab, fakebin)
        env["KAS_DOCTOR_SYSFS_NET"] = str(make_vantage_sysfs(lab, plan))
        r = run_tool(shell, target_args + ["--vantage", "all", "--json", str(jf)], env)
        data = json.loads(jf.read_text())
        devs = [v["dev"] for v in data.get("vantages", [])]
        assert devs == ["eth0", "wan2"], devs
        assert data["budget"]["requests_limit"] == 28, data["budget"]
        print("PASS", " ".join(shell), "v6 all mode excludes service devices, scales budget")

    # V7 — static guard: the tool reads routes, never writes them.
    # Code lines only: the honest-limit comments legitimately mention the
    # out-of-scope mechanisms by name.
    code = [l for l in TOOL.read_text().splitlines()
            if not l.lstrip().startswith("#")]
    for banned in ("ip rule", "ip route add", "ip route del", "ip route replace",
                   "ip route flush", "ip route change", "iptables ", "nft ",
                   "ip -6 rule"):
        hits = [l for l in code if banned in l]
        assert not hits, ("route mutation found", banned, hits[:1])
    assert "ip route get" in TOOL.read_text(), "route.get evidence is expected (read-only)"
    print("PASS", " ".join(shell), "v7 static no-route-mutation guard")


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

    target_args = ["--target", "target.example"]
    ip_args = ["--target", "192.0.2.10", "--port", "80"]

    cases = [
        ("https_all_good", {}, 0,
         {"expect_in": ("tls.handshake: certificate verification OK", "http.response: HTTP 200",
                        "VERDICT: target chain confirmed", "mihomo.socks-probe"),
          "cli_args": target_args, "want_curl_calls": 8}),
        ("http_target_skips_tls", {"target": "http200"}, 0,
         {"expect_in": ("TLS stage NOT TESTED by design", "http.response: HTTP 200",
                        "VERDICT: target chain confirmed", "plain HTTP target"),
          "cli_args": ["--target", "192.0.2.10"]}),        # review fix: an IP literal has no name resolution - curl-path DNS
        # side evidence must NOT be recorded even when the target is reached
        ("ip_target_no_curlpath_dns", {"target": "pass"}, 0,
         {"expect_not_in": ("dns.curl-path",),
          "cli_args": ["--target", "192.0.2.10"]}),
        ("dns_nxdomain", {"dns": "nxdomain", "target": "exit6"}, 1,
         {"expect_in": ("NXDOMAIN", "VERDICT: confirmed failure", "'dns.router'",
                        "Hypotheses", "--dns-server"),
          "cli_args": target_args}),
        ("dns_servfail", {"dns": "servfail", "target": "exit6"}, 1,
         {"expect_in": ("SERVFAIL", "'dns.router'"), "cli_args": target_args}),
        ("dns_refused", {"dns": "refused", "target": "exit6"}, 1,
         {"expect_in": ("REFUSED", "'dns.router'"), "cli_args": target_args}),
        ("dns_timeout", {"dns": "timeout", "target": "exit6"}, 1,
         {"expect_in": ("timeout", "'dns.router'"), "cli_args": target_args}),
        ("dns_busybox_tempfail", {"dns": "tempfail", "target": "exit6"}, 1,
         {"expect_in": ("no DNS answer", "'dns.router'"), "cli_args": target_args}),
        ("tcp_refused", {"tcp": "refused", "target": "exit7"}, 1,
         {"expect_in": ("connection refused or host/network unreachable", "'tcp.connect'",
                        "NOT TESTED", "hotspot"),
          "cli_args": target_args}),
        ("tcp_reset_ok", {"tcp": "reset"}, 0,
         {"expect_in": ("peer closed the probe connection", "tcp.connect:"),
          "cli_args": target_args}),
        ("tls_handshake_35", {"target": "exit35"}, 1,
         {"expect_in": ("TLS handshake failed (curl 35)", "NOT TESTED",
                        "IPv4+X25519", "VERDICT: confirmed failure", "'tls.handshake'",
                        "Hypotheses"),
          "cli_args": target_args}),
        ("tls_cert_60", {"target": "exit60"}, 1,
         {"expect_in": ("certificate verification failed", "ca-bundle", "date/time"),
          "cli_args": target_args}),
        ("tls_reset_56", {"target": "exit56"}, 3,
         {"expect_in": ("connection reset during the TLS exchange", "curl 56",
                        "VERDICT: inconclusive"),
          "cli_args": target_args}),
        ("tls_timeout_28", {"target": "exit28"}, 3,
         {"expect_in": ("timed out", "VERDICT: inconclusive"), "cli_args": target_args}),
        ("oversize_63_transport_ok", {"target": "exit63"}, 0,
         {"expect_in": ("http.response: HTTP 200", "diagnostic size limit",
                        "VERDICT: target chain confirmed"),
          "cli_args": target_args}),
        ("http_500_transport_ok", {"target": "http500"}, 0,
         {"expect_in": ("http.response: HTTP 500", "server-side error",
                        "VERDICT: target chain confirmed"),
          "cli_args": target_args}),
        ("http_403_declined", {"target": "http403"}, 0,
         {"expect_in": ("HTTP 403", "the server declined the request"),
          "cli_args": target_args}),
        ("captive_portal_redirect", {"target": "portal"}, 0,
         {"expect_in": ("http://192.168.88.1/[path withheld]", "captive portal"),
          "expect_not_in": ("login.html",),
          "cli_args": target_args}),
        ("egress_differs", {}, 0,
         {"expect_in": ("egress.direct: direct traffic currently exits from 203.0.113.10",
                        "egress.via-mihomo: traffic through the local Mihomo path currently exits from 198.51.100.9",
                        "fact: the paths exit from different addresses"),
          "cli_args": target_args}),
        ("egress_same", {"egress_socks": "203.0.113.10"}, 0,
         {"expect_in": ("fact: both paths exit from the same address",),
          "cli_args": target_args}),
        ("egress_unreachable", {"egress": "fail"}, 0,
         {"expect_in": ("egress.direct: observation inconclusive",),
          "cli_args": target_args}),
        ("egress_disabled", {}, 0,
         {"expect_in": ("egress.direct: disabled by --no-egress",),
          "cli_args": target_args + ["--no-egress"], "want_curl_calls": 6}),
        ("socks_not_listening", {"socks_listening": False}, 0,
         {"expect_in": ("mihomo.socks-port: TCP 7890 is NOT listening",
                        "confirmed not listening; probe skipped", "target chain confirmed"),
          "cli_args": target_args}),
        ("controller_401", {"controller_version": 401}, 0,
         {"expect_in": ("secret is missing or rejected", "VERDICT: target chain confirmed"),
          "cli_args": target_args}),
        ("controller_down", {"controller_down": True}, 0,
         {"expect_in": ("mihomo.controller: request failed", "target chain confirmed"),
          "cli_args": target_args}),
        ("selection_hidden", {}, 0,
         {"expect_in": ("has a selected leaf (name withheld",),
          "expect_not_in": ("PROXY-NODE-1",),
          "cli_args": target_args}),
        ("magitrickle_stopped", {"magitrickle_running": False}, 0,
         {"expect_in": ("magitrickle.process: magitrickled process is not running",
                        "target chain confirmed"),
          "cli_args": target_args}),
        ("proxyn_bridge_evidence", {"ndmc": "bridge"}, 0,
         {"expect_in": ("ProxyN upstream to 127.0.0.1:7890",
                        "raw running-config lines are withheld"),
          "cli_args": target_args}),
        ("proxyn_no_bridge", {"ndmc": "none"}, 0,
         {"expect_in": ("no ProxyN evidence",), "cli_args": target_args}),
        ("ip_target", {}, 0,
         {"expect_in": ("dns.router: target is an IP address literal", "http.response: HTTP 200",
                        "client.vantage"),
          "cli_args": ip_args}),
        ("dns_server_disagreement", {"dns": "pass", "dns_custom": "refused"}, 0,
         {"expect_in": ("dns.custom: via 192.0.2.53: REFUSED",
                        "the two resolvers disagree", "target chain confirmed"),
          "cli_args": target_args + ["--dns-server", "192.0.2.53"]}),
        ("dns_server_rescues", {"dns": "timeout", "dns_custom": "pass"}, 0,
         {"expect_in": ("192.0.2.53 resolves the name while the system resolver failed",
                        "despite the system resolver failure",
                        "VERDICT: target chain confirmed"),
          "cli_args": target_args + ["--dns-server", "192.0.2.53"]}),
        ("brief_mode", {}, 0,
         {"expect_in": ("[PASS] dns.router",), "cli_args": target_args + ["--brief"]}),
        ("usage_no_target", {}, 2, {"expect_in": ("--target is required",), "cli_args": []}),
        ("usage_bad_port", {}, 2,
         {"expect_in": ("--port expects",), "cli_args": ["--target", "h", "--port", "99999"]}),
        ("usage_unknown_opt", {}, 2,
         {"expect_in": ("Unknown option",), "cli_args": ["--target", "h", "--wat"]}),
        ("usage_bad_dns", {}, 2,
         {"expect_in": ("Unsupported --dns-server",),
          "cli_args": ["--target", "h", "--dns-server", "bad host"]}),

        # ---- review fixes: RED cases ----
        ("dns_answer_excludes_server", {}, 0,
         {"expect_in": ("resolved -> 93.184.216.34",),
          "expect_not_in": ("resolved -> 192.0.2.53",),
          "cli_args": target_args}),
        ("tcp_telnet_fail_https_ok", {"tcp": "refused", "target": "pass"}, 0,
         {"expect_in": ("proven by the TLS/HTTPS stage", "telnet probe disagreed",
                        "VERDICT: target chain confirmed"),
          "cli_args": target_args}),
        # issue #158: curl built without telnet skips the TCP-only probe
        # without spending a request; TLS still proves TCP reachability
        ("curl_without_telnet_skips_probe", {"curl_no_telnet": True}, 0,
         {"expect_in": ("telnet protocol NOT available",
                        "the TCP-only probe was skipped without spending a request",
                        "proven by the TLS/HTTPS stage", "VERDICT: target chain confirmed"),
          "cli_args": target_args, "want_curl_calls": 7}),
        ("dns_fail_https_ok_resolvers_disagree", {"dns": "nxdomain", "target": "pass"}, 0,
         {"expect_in": ("NXDOMAIN", "despite the system resolver failure",
                        "VERDICT: target chain confirmed"),
          "cli_args": target_args}),
        ("egress_fail_keeps_exit_code", {"egress": "fail"}, 0,
         {"expect_in": ("curl exit 28",),
          "cli_args": target_args}),
        ("redirect_not_followed", {"target": "redirect"}, 0,
         {"expect_in": ("does not follow redirects", "redirect target: http://192.0.2.99/"),
          "expect_not_in": ("after redirect handling",),
          "cli_args": target_args}),
        ("captive_portal_via_redirect_target", {"target": "portal"}, 0,
         {"expect_in": ("http://192.168.88.1/[path withheld]", "captive portal"),
          "cli_args": target_args}),
        ("proxies_response_capped", {}, 0,
         {"expect_in": ("mihomo.controller.selection",), "cli_args": target_args}),
        ("url_secrets_sanitized", {}, 0,
         {"expect_in": ("Host:    example.com",),
          "expect_not_in": ("secret", "token=abc"),
          "cli_args": ["--target", "https://user:secret@example.com/path?token=abc"]}),
        ("ndmc_lines_withheld", {"ndmc": "bridge"}, 0,
         {"expect_in": ("ProxyN", "127.0.0.1:7890"),
          "expect_not_in": ("PROVIDER-TOPSECRET",),
          "cli_args": target_args}),


        # ---- round 3: review blockers ----
        # the probed URL must keep the user's path
        ("target_path_preserved", {}, 0,
         {"expect_in": ("Host:    example.com",),
          "cli_args": ["--target", "https://example.com/missing"]}),
        # an explicit port inside the target URL is honored
        ("target_url_port_honored", {}, 0,
         {"expect_in": ("Port:    8443",),
          "cli_args": ["--target", "https://example.com:8443/path"]}),
        # explicit --port overrides the domain-target default
        ("target_cli_port_honored", {}, 0,
         {"expect_in": ("Port:    8443",),
          "cli_args": ["--target", "example.com", "--port", "8443"]}),
        # explicit --port overrides the port inside the URL (documented rule)
        ("target_cli_port_overrides_url", {}, 0,
         {"expect_in": ("Port:    9090",),
          "cli_args": ["--target", "http://example.com:8080/", "--port", "9090"]}),
        # IPv6 literals are an explicit usage error, never a silent other target
        # query-only URL (no slash after the host) keeps its query
        ("query_only_url_keeps_query", {}, 0,
         {"expect_in": ("Host:    example.com",),
          "cli_args": ["--target", "https://example.com?token=abc"]}),
        # a secret in the URL PATH is redacted in every shareable sink
        ("path_secret_redacted", {}, 0,
         {"expect_in": ("Host:    example.com", "[path withheld]"),
          "expect_not_in": ("TOPSECRET", "/api/TOPSECRET"),
          "cli_args": ["--target", "https://example.com/api/TOPSECRET?token=x"]}),
        # redirect Location with a secret in the path is redacted too
        ("redirect_path_secret_redacted", {"target": "redirect_path_secret"}, 0,
         {"expect_in": ("192.0.2.99", "[path withheld]"),
          "expect_not_in": ("TOPSECRET", "/dl/TOPSECRET"),
          "cli_args": target_args}),
        # usage errors never echo the raw user input
        ("usage_error_hides_secret", {}, 2,
         {"expect_in": ("Unsupported characters in target",),
          "expect_not_in": ("TOPSECRET",),
          "cli_args": ["--target", "https://exa mple.com/?token=TOPSECRET"]}),
        # bracketed IPv6 literals are rejected as an explicit usage error
        # (character allowlist), never silently resolved to another target
        ("ipv6_literal_usage_error", {}, 2,
         {"expect_in": ("Unsupported characters in target",),
          "cli_args": ["--target", "https://[2001:db8::1]/"]}),
    ]

    for shell in shells:
        for title, plan, want_exit, opts in cases:
            exercise(shell, title, plan, want_exit, **opts)

        # curl missing entirely -> inconclusive chain
        with tempfile.TemporaryDirectory(prefix="kas-netdoc-nocurl-") as tmp:
            lab = Path(tmp)
            fakebin = lab / "bin"
            fakebin.mkdir(parents=True)
            for name, body in MOCKS[1:]:
                p = fakebin / name
                p.write_text(body)
                p.chmod(0o755)
            (lab / "plan.json").write_text(json.dumps({}))
            env = base_env(lab, fakebin)
            env["PATH"] = str(fakebin)  # strict isolation: no host curl
            r = run_tool(shell, target_args, env)
            out = r.stdout + r.stderr
            assert r.returncode == 3, ("curl_missing", r.returncode, out[-800:])
            assert "UNSUPPORTED" in out, ("curl_missing", out[-800:])
            assert "VERDICT: inconclusive" in out, ("curl_missing", out[-800:])
            print("PASS", " ".join(shell), "curl_missing_inconclusive")

        # secret hygiene: the controller secret never appears in any output
        with tempfile.TemporaryDirectory(prefix="kas-netdoc-sec-") as tmp:
            lab = Path(tmp)
            jf = lab / "r.json"
            rf = lab / "r.txt"
            fakebin = make_lab(lab, {})
            env = base_env(lab, fakebin)
            env["MIHOMO_API_SECRET"] = "TOPSECRET-WORD"
            r = run_tool(shell, target_args + ["--json", str(jf), "--report", str(rf)], env)
            blob = r.stdout + r.stderr + jf.read_text() + rf.read_text()
            assert "TOPSECRET-WORD" not in blob, ("secret_leak", blob[:2000])
            assert r.returncode == 0, ("secret_run", r.returncode)
            print("PASS", " ".join(shell), "secret_never_printed")

        # proxy env: direct probes must carry --noproxy; socks probes must not
        with tempfile.TemporaryDirectory(prefix="kas-netdoc-proxy-") as tmp:
            lab = Path(tmp)
            fakebin = make_lab(lab, {})
            env = base_env(lab, fakebin)
            env["HTTPS_PROXY"] = "http://192.0.2.1:9"
            env["ALL_PROXY"] = "socks5://192.0.2.1:9"
            env["HTTP_PROXY"] = "http://192.0.2.1:9"
            r = run_tool(shell, target_args, env)
            calls = json.loads((lab / "curl_calls.json").read_text())
            real = [c for c in calls if "--version" not in c]
            assert real, "no curl calls logged"
            for c in real:
                if "--socks5-hostname" in c:
                    assert "--noproxy" not in c, ("noproxy on socks call", c)
                else:
                    assert "--noproxy" in c and "*" in c, ("missing --noproxy on direct call", c)
            print("PASS", " ".join(shell), "proxy_env_direct_noproxy")

        # controller /proxies response must be size-capped
        with tempfile.TemporaryDirectory(prefix="kas-netdoc-cap-") as tmp:
            lab = Path(tmp)
            fakebin = make_lab(lab, {})
            env = base_env(lab, fakebin)
            run_tool(shell, target_args, env)
            calls = json.loads((lab / "curl_calls.json").read_text())
            prox = [c for c in calls if any("/proxies" in a for a in c)]
            assert prox, "no /proxies call logged"
            assert any("--max-filesize" in a for a in prox[0]), ("proxies not capped", prox[0])
            print("PASS", " ".join(shell), "proxies_call_size_capped")

        # curl must hit the EXACT user-named URL: path, URL port, CLI port
        with tempfile.TemporaryDirectory(prefix="kas-netdoc-url-") as tmp:
            lab = Path(tmp)
            fakebin = make_lab(lab, {})
            env = base_env(lab, fakebin)
            for cli, want_url in (
                (["--target", "https://example.com/missing"], "https://example.com/missing"),
                (["--target", "https://example.com:8443/path"], "https://example.com:8443/path"),
                (["--target", "example.com", "--port", "8443"], "https://example.com:8443/"),
                (["--target", "http://example.com:8080/", "--port", "9090"], "http://example.com:9090/"),
                (["--target", "https://example.com?token=abc"], "https://example.com/?token=abc"),
            ):
                (lab / "curl_calls.json").unlink(missing_ok=True)
                r = run_tool(shell, cli, env)
                calls = json.loads((lab / "curl_calls.json").read_text())
                targets = [a for c in calls for a in c if "://" in a and not c[0].startswith("-") or "://" in a]
                targets = [a for c in calls for a in c if "://" in a and "://" in a]
                hit = [a for a in (x for c in calls for x in c) if "://" in a and a == want_url]
                telnet_or_http = [a for c in calls for a in c if a == want_url]
                assert telnet_or_http, ("exact target URL not probed", cli, want_url,
                                        [x for c in calls for x in c if "://" in a])
            print("PASS", " ".join(shell), "curl_hits_exact_target_url")

        # 302 with a secret Location: no marker in stdout, --report or --json
        with tempfile.TemporaryDirectory(prefix="kas-netdoc-sec302-") as tmp:
            lab = Path(tmp)
            jf, rf = lab / "r.json", lab / "r.txt"
            fakebin = make_lab(lab, {"target": "redirect_secret"})
            env = base_env(lab, fakebin)
            r = run_tool(shell, target_args + ["--json", str(jf), "--report", str(rf)], env)
            blob = r.stdout + r.stderr + jf.read_text() + rf.read_text()
            for marker in ("TOPSECRET", "token=", "user:secret", "user:"):
                assert marker not in blob, ("redirect secret leaked", marker, blob[:1500])
            assert "302" in blob, ("status lost", blob[:800])
            assert "example.com" in blob, ("safe host lost", blob[:800])
            data = json.loads(jf.read_text())
            ids = [c["id"] for c in data["checks"]]
            assert len(ids) == len(set(ids)), "duplicate ids"
            print("PASS", " ".join(shell), "redirect_secret_never_leaked")

        # hanging nslookup without any timeout wrapper: quick NOT TESTED, no hang
        with tempfile.TemporaryDirectory(prefix="kas-netdoc-dnsnt-") as tmp:
            lab = Path(tmp)
            fakebin = lab / "bin"
            fakebin.mkdir(parents=True)
            hang = "#!/usr/bin/env python3" + chr(10) + "import time" + chr(10) + "time.sleep(120)" + chr(10)
            pn = fakebin / "nslookup"
            pn.write_text(hang)
            pn.chmod(0o755)
            (lab / "plan.json").write_text(json.dumps({}))
            env = base_env(lab, fakebin)
            env["PATH"] = str(fakebin)  # no timeout utility in this PATH
            try:
                r = run_tool(shell, target_args, env)
                out = r.stdout + r.stderr
                assert "NOT TESTED" in out, ("expected NOT TESTED", out[-800:])
                assert "no timeout wrapper" in out, ("expected explicit guard note", out[-800:])
                assert "no timeout wrapper available; the DNS probe was not run" in out, out[-800:]
                print("PASS", " ".join(shell), "dns_without_timeout_guarded")
            except subprocess.TimeoutExpired:
                raise AssertionError("dns probe hung without a timeout wrapper")

        # issue #158: no timeout wrapper + healthy HTTPS 200 must still state
        # exactly what was confirmed (and what was not), with curl-path DNS
        # side evidence recorded; verdict stays honestly inconclusive (exit 3)
        with tempfile.TemporaryDirectory(prefix="kas-netdoc-noto-") as tmp:
            lab = Path(tmp)
            fakebin = make_lab(lab, {})
            # Field image (issue #158): no timeout binary anywhere, while the
            # doctor's own helpers still work. Filtering PATH directories is
            # not portable (timeout shares a directory with tr/awk on Git
            # Bash and ubuntu), so the lab PATH is made self-contained:
            # copies of every external helper the tool needs, NO timeout.
            for helper in ("sed", "head", "grep", "cut", "tr", "awk", "cat",
                           "tail", "date"):
                src = shutil.which(helper)
                if not src:
                    continue
                # forwarding shims: PATH is fakebin-only, each shim execs the
                # real binary by absolute path; works on Git Bash and CI alike
                shim = fakebin / helper
                shim.write_text(
                    "#!/bin/sh\nexec '%s' \"$@\"\n" % str(src).replace("\\", "/")
                )
                shim.chmod(0o755)
            # the mocked tools are python scripts: expose python3 via a tiny
            # exec wrapper so the real interpreter (and its DLLs) stay in place
            real_py = shutil.which("python3") or shutil.which("python")
            if real_py:
                pyw = fakebin / "python3"
                pyw.write_text(
                    "#!/bin/sh\nexec \"%s\" \"$@\"\n" % str(real_py).replace("\\", "/")
                )
                pyw.chmod(0o755)
            env = base_env(lab, fakebin)
            env["PATH"] = str(fakebin)  # no timeout utility in this PATH
            r = run_tool(shell, target_args, env)
            out = r.stdout + r.stderr
            assert r.returncode == 3, ("expected exit 3", r.returncode, out[-600:])
            assert "no timeout wrapper" in out, out[-800:]
            assert "Confirmed stages: tcp.connect=PASS, tls.handshake=PASS, http.response=PASS" in out, out[-900:]
            assert "Missing evidence: dns.router=NOT TESTED" in out, out[-900:]
            jf = lab / "r.json"
            r2 = run_tool(shell, target_args + ["--json", str(jf)], env)
            data = json.loads(jf.read_text())
            byid = {c["id"]: c for c in data["checks"]}
            assert byid["dns.curl-path"]["status"] == "PASS", byid.get("dns.curl-path")
            assert "not an independent DNS stage" in byid["dns.curl-path"]["detail"], byid["dns.curl-path"]
            print("PASS", " ".join(shell), "no_timeout_https_confirmed_inventory")

        # DNS probe time limit via a timeout wrapper (when available)
        if shutil.which("timeout"):
            with tempfile.TemporaryDirectory(prefix="kas-netdoc-dnst-") as tmp:
                lab = Path(tmp)
                fakebin = make_lab(lab, {"dns": "hang"})
                env = base_env(lab, fakebin)
                r = run_tool(shell, target_args, env)
                out = r.stdout + r.stderr
                assert "no DNS answer within" in out, ("dns hang not limited", out[-600:])
                print("PASS", " ".join(shell), "dns_probe_time_limited")
        else:
            print("SKIP", " ".join(shell), "dns_probe_time_limited (no timeout binary)")

        test_vantage_group(shell)

        # JSON contract on the happy path and on a failure path
        data, ids, text = json_case(shell, "json_happy", {}, target_args)
        for needed in ("dns.router", "tcp.connect", "tls.handshake", "http.response",
                       "egress.direct", "egress.via-mihomo", "mihomo.controller",
                       "mihomo.controller.selection", "mihomo.socks-probe",
                       "mihomo.socks-port", "magitrickle.process", "keenetic.proxyn",
                       "udp.transport", "client.vantage", "tools.curl"):
            assert needed in ids, ("json_ids_missing", needed, ids)
        assert data["verdict"]["summary"] == "ok" and data["exit_code"] == 0
        assert data["budget"]["requests_used"] > 0
        fdata, fids, ftext = json_case(shell, "json_fail35", {"target": "exit35"},
                                       target_args)
        assert fdata["verdict"]["summary"] == "confirmed_failure" and fdata["exit_code"] == 1
        assert fdata["verdict"]["first_failed_stage"] == "tls.handshake"
        assert any("curl 35" in h for h in fdata["verdict"]["hypotheses"]), fdata["verdict"]
        assert len(ftext) < 100000

    print("ALL OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
