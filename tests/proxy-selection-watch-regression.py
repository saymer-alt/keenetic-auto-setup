#!/usr/bin/env python3
"""Bounded Mihomo Controller sampling: offline mocked curl/jq/sleep regression."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
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
if response == "http401":
    print("\n401", end="")
    sys.exit(0)
if response == "http403":
    print("\n403", end="")
    sys.exit(0)
if response == "malformed":
    print('{"not_proxies":true}\n200', end="")
    sys.exit(0)
if isinstance(response, str):
    # Raw body fixture: served verbatim with HTTP 200. Used for negative
    # payloads (null / [] / string / truncated JSON / wrong shape).
    print(response + "\n200", end="")
    sys.exit(0)
print(json.dumps({"proxies": response}) + "\n200", end="")
'''

JQ_MOCK = r'''#!/usr/bin/env python3
import json
import sys
argv = sys.argv[1:]
query = argv[-1]
try:
    obj = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(2)
if ".proxies" in query and "select(type" in query:
    # Emulates jq: .proxies | select(type == "object") — nothing is printed
    # for a missing or non-object .proxies (corrupted snapshot), exactly
    # like the real jq filter in fetch_state().
    proxies = obj.get("proxies") if isinstance(obj, dict) else None
    if isinstance(proxies, dict):
        print(json.dumps(proxies))
    sys.exit(0)
if not isinstance(obj, dict):
    sys.exit(2)
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
            started = time.monotonic()
            run = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=15)
            elapsed = time.monotonic() - started
            calls = (t / "curl.log").read_text().splitlines() if (t / "curl.log").exists() else []
            sleeps = (t / "sleep.log").read_text().splitlines() if (t / "sleep.log").exists() else []
            for item in calls:
                argv = json.loads(item)
                self.assertTrue(argv[-1].endswith("/proxies"), argv)
                self.assertFalse(any(a in argv for a in ("-X", "--request", "-d", "--data")), argv)
            return run, calls, sleeps, elapsed

    def assert_polls_and_waits(self, calls, sleeps, samples, elapsed, watch=1):
        """Polls and wait intervals must match the requested budget exactly.

        How the wait interval is instrumented depends on how the shell
        resolves `sleep`, and both resolutions are deterministic:

        - dash, and BusyBox builds without standalone applet preference,
          exec the PATH shim: the shim log must hold exactly samples - 1
          entries (the last sample exits before sleeping);
        - BusyBox ash can resolve `sleep` to its own applet and never reach
          the PATH shim (observed with busybox 1.36.1 on ubuntu-24.04 CI:
          empty shim log while real ~1 s applet sleeps ran). The shim log
          is then empty by design, and the wall clock must prove that the
          watcher really waited (samples - 1) * watch seconds between the
          polls.

        A watcher that skips waiting fails the wall-clock check, so neither
        shell can silently weaken the timing contract. The 300 s sampling
        budget itself is enforced at argument validation and covered by
        test_reject_bad_arguments_before_http, with no sleeping involved.
        No test here sleeps longer than samples - 1 real seconds.
        """
        self.assertEqual(len(calls), samples)
        if len(sleeps) == samples - 1:
            return
        self.assertEqual(len(sleeps), 0, sleeps)
        self.assertGreaterEqual(
            elapsed, (samples - 1) * watch - 0.1,
            "watcher skipped %d wait intervals of %ds (elapsed %.2fs, shim log %r)"
            % (samples - 1, watch, elapsed, sleeps))

    def test_stable_and_exact_budget(self):
        r, calls, sleeps, elapsed = self.run_watcher([selection()] * 3, ["--watch", "1", "--samples", "3"])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("polls=3 observed=3 incomplete=0 leaf-changes=0", r.stdout)
        self.assertIn("SELECTION RESULT: OBSERVED", r.stdout)
        self.assertIn("not proof of actual IP egress", r.stdout)
        self.assert_polls_and_waits(calls, sleeps, 3, elapsed)

    def test_direct_is_observed_not_assumed_safe(self):
        r, calls, sleeps, elapsed = self.run_watcher(
            [selection("A"), selection("DIRECT"), selection("B")],
            ["--watch=1", "--samples=3"], secret="SYNTHETIC_SECRET_12345"
        )
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("leaf-changes=2 direct-observed=1", r.stdout)
        self.assertNotIn("SYNTHETIC_SECRET_12345", r.stdout + r.stderr)
        self.assert_polls_and_waits(calls, sleeps, 3, elapsed)

    def test_missing_controller_inconclusive(self):
        r, calls, sleeps, elapsed = self.run_watcher(
            [selection("A"), "unreachable", selection("A")],
            ["--watch", "1", "--samples", "3"]
        )
        self.assertEqual(r.returncode, 6, r.stdout + r.stderr)
        self.assertIn("observed=2 incomplete=1", r.stdout)
        self.assertIn("INCONCLUSIVE", r.stdout)
        self.assert_polls_and_waits(calls, sleeps, 3, elapsed)

    def test_malformed_controller_inconclusive(self):
        r, calls, sleeps, elapsed = self.run_watcher(
            ["malformed", selection()], ["--watch", "1", "--samples", "2"])
        self.assertEqual(r.returncode, 6, r.stdout + r.stderr)
        self.assertIn("observed=1 incomplete=1", r.stdout)
        self.assert_polls_and_waits(calls, sleeps, 2, elapsed)

    def test_loadbalance_cannot_reveal_per_connection_leaf(self):
        r, calls, sleeps, elapsed = self.run_watcher(
            [balanced(), balanced()], ["--watch", "1", "--samples", "2"])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("load-balanced=2", r.stdout)
        self.assertIn("CURRENT SERVER: [load-balanced]", r.stdout)
        self.assert_polls_and_waits(calls, sleeps, 2, elapsed)

    def test_one_shot_backward_compatible(self):
        r, calls, sleeps, elapsed = self.run_watcher([selection()], [])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("CURRENT SERVER: A", r.stdout)
        self.assertNotIn("SELECTION SUMMARY", r.stdout)
        self.assertEqual((len(calls), len(sleeps)), (1, 0))
        one, calls, sleeps, elapsed = self.run_watcher([selection()], ["--watch", "1", "--samples", "1"])
        self.assertEqual(one.returncode, 0, one.stderr)
        self.assertEqual((len(calls), len(sleeps)), (1, 0))

    def test_reject_bad_arguments_before_http(self):
        for args in (["--samples", "3"], ["--watch", "1", "--samples", "0"],
                     ["--watch", "1", "--samples", "31"], ["--watch", "1", "--samples="],
                     ["--watch", "1", "--samples", "invalid"],
                     ["--watch", "30", "--samples", "30"],
                     ["--watch", "0", "--samples", "3"]):
            with self.subTest(args=args):
                r, calls, sleeps, elapsed = self.run_watcher([selection()], args)
                self.assertEqual(r.returncode, 1, (args, r.stdout, r.stderr))
                self.assertEqual(len(calls), 0)

    def test_leading_zeroes_are_decimal(self):
        r, calls, sleeps, elapsed = self.run_watcher(
            [selection()] * 2, ["--watch", "01", "--samples", "002"])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("polls=2", r.stdout)
        self.assert_polls_and_waits(calls, sleeps, 2, elapsed)

    # ---------------- negative fixtures ----------------

    def test_corrupted_proxies_types_inconclusive(self):
        # A syntactically valid HTTP 200 body whose .proxies is not an
        # object (null / [] / string) is a corrupted snapshot, not an
        # empty group: bounded mode must report INCONCLUSIVE/6 and never
        # the "group not found" misclassification (exit 4).
        for raw in ('{"proxies":null}', '{"proxies":[]}', '{"proxies":"unexpected"}'):
            with self.subTest(raw=raw):
                r, calls, sleeps, elapsed = self.run_watcher(
                    [raw], ["--watch", "1", "--samples", "1"])
                self.assertEqual(r.returncode, 6, r.stdout + r.stderr)
                self.assertIn("polls=1 observed=0 incomplete=1", r.stdout)
                self.assertIn("INCONCLUSIVE", r.stdout)
                self.assertNotIn("start group not found", r.stdout + r.stderr)
                self.assertEqual(len(calls), 1)

    def test_http200_invalid_payload_inconclusive(self):
        # HTTP 200 but the payload is not a usable /proxies snapshot:
        # truncated JSON, a JSON array root, a JSON string root, or an
        # object without .proxies. All are corrupted snapshots -> 6.
        for raw in ('{"proxies":', '[1,2,3]', '"just a string"', '{"not_proxies":true}'):
            with self.subTest(raw=raw):
                r, calls, sleeps, elapsed = self.run_watcher(
                    [raw], ["--watch", "1", "--samples", "1"])
                self.assertEqual(r.returncode, 6, r.stdout + r.stderr)
                self.assertIn("incomplete=1", r.stdout)
                self.assertIn("INCONCLUSIVE", r.stdout)
                self.assertEqual(len(calls), 1)

    def test_one_shot_corrupted_proxies_is_malformed_not_missing(self):
        # One-shot keeps its documented error semantics: a corrupted
        # snapshot is reported as a malformed/unusable response (exit 5),
        # not as "start group not found" (exit 4).
        for raw in ('{"proxies":null}', '{"proxies":[]}', '{"proxies":"unexpected"}',
                    '{"proxies":', '[1,2,3]'):
            with self.subTest(raw=raw):
                r, calls, sleeps, elapsed = self.run_watcher([raw], [])
                self.assertEqual(r.returncode, 5, r.stdout + r.stderr)
                self.assertIn("malformed", r.stderr)
                self.assertNotIn("start group not found", r.stderr)
                self.assertEqual(len(calls), 1)

    def test_partial_series_inconclusive_without_recovery(self):
        # Controller dropout in the middle of a series that never recovers:
        # every unavailable poll counts, the series must stay INCONCLUSIVE.
        r, calls, sleeps, elapsed = self.run_watcher(
            [selection("A"), "unreachable", "unreachable"],
            ["--watch", "1", "--samples", "3"])
        self.assertEqual(r.returncode, 6, r.stdout + r.stderr)
        self.assertIn("polls=3 observed=1 incomplete=2", r.stdout)
        self.assertIn("INCONCLUSIVE", r.stdout)
        self.assert_polls_and_waits(calls, sleeps, 3, elapsed)

    def test_bounded_auth_401_403_stops_watch(self):
        # Authorization failure stays fatal (exit 3) in bounded mode: the
        # watch stops at the first poll, remaining samples are not
        # attempted, and the secret is never echoed.
        for code in ("http401", "http403"):
            with self.subTest(code=code):
                r, calls, sleeps, elapsed = self.run_watcher(
                    [code, selection(), selection()],
                    ["--watch", "1", "--samples", "3"], secret="SYNTHETIC_SECRET_12345")
                self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
                self.assertIn("secret", r.stderr)
                self.assertNotIn("SYNTHETIC_SECRET_12345", r.stdout + r.stderr)
                self.assertEqual(len(calls), 1)
                sent = [json.loads(item) for item in calls]
                headers = [a for argv in sent for a in argv if a.startswith("Authorization: Bearer ")]
                self.assertEqual(headers, ["Authorization: Bearer SYNTHETIC_SECRET_12345"])

    def test_one_shot_auth_401_403(self):
        for code in ("http401", "http403"):
            with self.subTest(code=code):
                r, calls, sleeps, elapsed = self.run_watcher(
                    [code], [], secret="SYNTHETIC_SECRET_12345")
                self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
                self.assertIn("secret", r.stderr)
                self.assertNotIn("SYNTHETIC_SECRET_12345", r.stdout + r.stderr)
                self.assertEqual(len(calls), 1)

    def test_bounded_unknown_group_and_empty_snapshot_exit_4(self):
        # A genuinely absent start group — including the empty-but-valid
        # {"proxies":{}} snapshot — keeps the documented exit 4; it is a
        # valid observation, not a corrupted snapshot.
        for responses, args in (([selection()], ["--watch", "1", "--samples", "2",
                                                   "-g", "NoSuchGroup"]),
                                (['{"proxies":{}}'], ["--watch", "1", "--samples", "1"])):
            with self.subTest(args=args):
                r, calls, sleeps, elapsed = self.run_watcher(responses, args)
                self.assertEqual(r.returncode, 4, r.stdout + r.stderr)
                self.assertIn("start group not found", r.stderr)
                self.assertNotIn("INCONCLUSIVE", r.stdout)
                self.assertEqual(len(calls), 1)

if __name__ == "__main__":
    for shell in ("/bin/sh", "busybox"):
        if shell == "busybox" and not shutil.which("busybox"):
            continue
        SHELL = shell
        print("=== shell:", shell, "===", flush=True)
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(SelectionTests)
        if not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful():
            sys.exit(1)
