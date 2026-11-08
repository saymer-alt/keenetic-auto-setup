#!/usr/bin/env python3
"""Bounded Mihomo Controller sampling: offline mocked curl/jq/sleep regression."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "mihomo-proxy-selection-watch.sh"
SHELL = "/bin/sh"

CURL_MOCK = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
argv = sys.argv[1:]
if not argv or not argv[-1].endswith("/proxies") or "-X" in argv or "--request" in argv:
    sys.exit(88)
with open(os.environ["PROBE_LOG"], "a", encoding="utf8") as f:
    f.write(json.dumps(argv) + "\n")
idx_file = Path(os.environ["PROBE_INDEX"])
idx = int(idx_file.read_text()) if idx_file.exists() else 0
idx_file.write_text(str(idx + 1))
seq = json.loads(Path(os.environ["PROBE_FIXTURES"]).read_text())
response = seq[min(idx, len(seq) - 1)]
if response == "unreachable":
    sys.exit(7)
if response == "malformed":
    print('{"not_proxies":true}\n200', end="")
    sys.exit(0)
print(json.dumps({"proxies": response}) + "\n200", end="")
'''

JQ_MOCK = r'''#!/usr/bin/env python3
import json
import sys
argv = sys.argv[1:]
query = argv[-1]
obj = json.load(sys.stdin)
if ".proxies // empty" in query:
    proxies = obj.get("proxies")
    if proxies is not None: print(json.dumps(proxies))
    sys.exit(0)
n = argv[argv.index("--arg") + 2]
if '"yes"' in query and "has($n)" in query:
    print("yes" if n in obj else "no")
elif "].type" in query:
    print(obj.get(n, {}).get("type", ""))
elif "].now" in query:
    print(obj.get(n, {}).get("now", ""))
else:
    sys.exit(91)
'''

SLEEP_MOCK = """#!/bin/sh
printf '.\\n' >> "$PROBE_SLEEP"
"""

def selection(name="A"):
    # A selected provider-backed leaf may be absent from top-level /proxies.
    return {"GLOBAL": {"type": "Selector", "now": "Auto"},
            "Auto": {"type": "Fallback", "now": name}}

def balanced():
    return {"GLOBAL": {"type": "Selector", "now": "Balance"},
            "Balance": {"type": "LoadBalance"}}

class SelectionTests(unittest.TestCase):
    def run_watcher(self, responses, args, secret=""):
        with tempfile.TemporaryDirectory(prefix="kas-selection-") as temp:
            t = Path(temp)
            for name, source in (("curl", CURL_MOCK), ("jq", JQ_MOCK), ("sleep", SLEEP_MOCK)):
                p = t / name
                p.write_text(source)
                p.chmod(0o755)
            (t / "fixtures.json").write_text(json.dumps(responses))
            env = dict(os.environ)
            env.update(PATH=str(t) + os.pathsep + os.environ.get("PATH", ""),
                       PROBE_LOG=str(t / "curl.log"), PROBE_INDEX=str(t / "index"),
                       PROBE_FIXTURES=str(t / "fixtures.json"), PROBE_SLEEP=str(t / "sleep.log"))
            if secret:
                env["MIHOMO_API_SECRET"] = secret
            cmd = [SHELL, str(SCRIPT), *args]
            if SHELL == "busybox":
                cmd.insert(1, "ash")
            run = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=15)
            calls = (t / "curl.log").read_text().splitlines() if (t / "curl.log").exists() else []
            sleeps = (t / "sleep.log").read_text().splitlines() if (t / "sleep.log").exists() else []
            for item in calls:
                argv = json.loads(item)
                self.assertTrue(argv[-1].endswith("/proxies"), argv)
                self.assertFalse(any(a in argv for a in ("-X", "--request", "-d", "--data")), argv)
            return run, calls, sleeps

    def test_stable_and_exact_budget(self):
        r, calls, sleeps = self.run_watcher([selection()] * 3, ["--watch", "1", "--samples", "3"])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("polls=3 observed=3 incomplete=0 leaf-changes=0", r.stdout)
        self.assertIn("SELECTION RESULT: OBSERVED", r.stdout)
        self.assertIn("not proof of actual IP egress", r.stdout)
        self.assertEqual((len(calls), len(sleeps)), (3, 2))

    def test_direct_is_observed_not_assumed_safe(self):
        r, calls, _ = self.run_watcher(
            [selection("A"), selection("DIRECT"), selection("B")],
            ["--watch=1", "--samples=3"], secret="SYNTHETIC_SECRET_12345"
        )
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("leaf-changes=2 direct-observed=1", r.stdout)
        self.assertNotIn("SYNTHETIC_SECRET_12345", r.stdout + r.stderr)
        self.assertEqual(len(calls), 3)

    def test_missing_controller_inconclusive(self):
        r, calls, sleeps = self.run_watcher(
            [selection("A"), "unreachable", selection("A")],
            ["--watch", "1", "--samples", "3"]
        )
        self.assertEqual(r.returncode, 6, r.stdout + r.stderr)
        self.assertIn("observed=2 incomplete=1", r.stdout)
        self.assertIn("INCONCLUSIVE", r.stdout)
        self.assertEqual((len(calls), len(sleeps)), (3, 2))

    def test_malformed_controller_inconclusive(self):
        r, _, _ = self.run_watcher(["malformed", selection()], ["--watch", "1", "--samples", "2"])
        self.assertEqual(r.returncode, 6, r.stdout + r.stderr)
        self.assertIn("observed=1 incomplete=1", r.stdout)

    def test_loadbalance_cannot_reveal_per_connection_leaf(self):
        r, _, _ = self.run_watcher([balanced(), balanced()], ["--watch", "1", "--samples", "2"])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("load-balanced=2", r.stdout)
        self.assertIn("CURRENT SERVER: [load-balanced]", r.stdout)

    def test_one_shot_backward_compatible(self):
        r, calls, sleeps = self.run_watcher([selection()], [])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("CURRENT SERVER: A", r.stdout)
        self.assertNotIn("SELECTION SUMMARY", r.stdout)
        self.assertEqual((len(calls), len(sleeps)), (1, 0))
        one, calls, sleeps = self.run_watcher([selection()], ["--watch", "1", "--samples", "1"])
        self.assertEqual(one.returncode, 0, one.stderr)
        self.assertEqual((len(calls), len(sleeps)), (1, 0))

    def test_reject_bad_arguments_before_http(self):
        for args in (["--samples", "3"], ["--watch", "1", "--samples", "0"],
                     ["--watch", "1", "--samples", "31"], ["--watch", "1", "--samples="],
                     ["--watch", "1", "--samples", "invalid"],
                     ["--watch", "30", "--samples", "30"],
                     ["--watch", "0", "--samples", "3"]):
            with self.subTest(args=args):
                r, calls, _ = self.run_watcher([selection()], args)
                self.assertEqual(r.returncode, 1, (args, r.stdout, r.stderr))
                self.assertEqual(len(calls), 0)

    def test_leading_zeroes_are_decimal(self):
        r, calls, _ = self.run_watcher([selection()] * 2, ["--watch", "01", "--samples", "002"])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("polls=2", r.stdout)
        self.assertEqual(len(calls), 2)

if __name__ == "__main__":
    for shell in ("/bin/sh", "busybox"):
        if shell == "busybox" and not shutil.which("busybox"):
            continue
        SHELL = shell
        print("=== shell:", shell, "===", flush=True)
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(SelectionTests)
        if not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful():
            sys.exit(1)
