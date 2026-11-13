#!/usr/bin/env python3
"""Unit tests for the offline digest-gate oracle.

Runs the oracle against an isolated scratch (tempfile) and pins its evidence
contract:

  - the stale upstream installer record REJECTS fresh synthetic bytes with
    exactly `ValueError("download digest mismatch")` and persists nothing
    (the fail-closed negative the native E2E hit on 2026-11-10);
  - a matching digest is accepted and cached; an off-origin URL is refused
    before any transport access; a tampered cache entry is refused;
  - transport failures (404) stay transport errors, never digest matches;
    502/503/504 retries stay bounded before the digest gate decides;
  - a null mirror-index field crashes loudly (fail-closed) while absent
    fields compose cleanly;
  - every evidence record carries the exact evidence fields
    (`artifact, exact_sha, expected, observed, stage, reason, status`),
    the verdict is `ORACLE PASS`, and no secret marker appears.

Fully offline: synthetic payloads, scripted transport, no network, no QEMU.
The optional real-lab crosscheck (`oracle_digest_gate.py --lab-source`) is a
CLI-only mode and is skipped here unless KAS_LAB_SOURCE points at a pinned
router-emulator checkout.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ORACLE = HERE / "oracle_digest_gate.py"
FIXTURE = HERE / "fixtures" / "lab_lock_records_20261110.json"
sys.path.insert(0, str(HERE))

import oracle_digest_gate  # noqa: E402

REQUIRED_FIELDS = set(oracle_digest_gate.REQUIRED_FIELDS)
EVIDENCE_FIELDS_TEXT = "exact-SHA, expected, observed, stage, reason, status"


def flatten(evidence):
    for scenario in evidence["scenarios"]:
        records = scenario["evidence"]
        yield from (records if isinstance(records, list) else [records])


class DigestGateOracleTests(unittest.TestCase):
    """The oracle's evidence and fail-closed contract, offline."""

    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory(prefix="kas-lock-oracle-test-")
        cls.scratch = Path(cls._tmp.name)
        cls.evidence, cls.oracle_scratch = oracle_digest_gate.run_scenarios(
            cls.scratch, FIXTURE)

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def test_verdict_is_pass_and_secret_scan_clean(self):
        self.assertEqual(self.evidence["verdict"], "ORACLE PASS")
        self.assertEqual(self.evidence["secret_scan"], "clean")
        self.assertFalse(self.evidence["network_used"])
        self.assertIn(EVIDENCE_FIELDS_TEXT, self.evidence["evidence_fields"])

    def test_every_record_carries_the_exact_evidence_fields(self):
        for record in flatten(self.evidence):
            self.assertTrue(REQUIRED_FIELDS <= set(record),
                            f"missing evidence fields: {record}")
            self.assertTrue(str(record["exact_sha"]), "exact_sha must be present")
            self.assertIn(record["status"],
                          ("REJECTED", "ACCEPTED", "ERROR_TRANSPORT"),
                          f"unexpected status: {record['status']}")

    def test_s1_old_lock_rejects_new_bytes_and_persists_nothing(self):
        fixture = json.loads(FIXTURE.read_text(encoding="utf8"))
        stale_pin = fixture["upstream_installer_record"]["sha256"]
        record = next(r for r in flatten(self.evidence)
                      if r["stage"] == "fetch" and r["expected"] == stale_pin)
        self.assertEqual(record["status"], "REJECTED")
        self.assertEqual(record["reason"], "download digest mismatch")
        self.assertNotEqual(record["observed"], stale_pin)
        self.assertEqual(record["transport_calls"], 1)
        destination = self.oracle_scratch / "s1_old_lock_rejects_new_bytes" / "cache" / \
            fixture["upstream_installer_record"]["artifact"]
        self.assertFalse(destination.exists(),
                         "the digest gate must reject BEFORE writing the artifact")

    def test_s2_accept_path_persists_verified_bytes(self):
        record = next(r for r in flatten(self.evidence) if r["status"] == "ACCEPTED"
                      and r["stage"] == "fetch")
        self.assertEqual(record["expected"], record["observed"])
        self.assertTrue(record["persisted"])

    def test_s3_off_origin_refused_without_transport(self):
        record = next(r for r in flatten(self.evidence)
                      if r["reason"] == "unexpected bootstrap origin")
        self.assertEqual(record["status"], "REJECTED")
        self.assertEqual(record["transport_calls"], 0)
        self.assertEqual(record["observed"], "n/a (no bytes fetched)")

    def test_s4_tampered_cache_refused_without_transport(self):
        record = next(r for r in flatten(self.evidence)
                      if r["reason"] == "cached asset digest mismatch")
        self.assertEqual(record["status"], "REJECTED")
        self.assertEqual(record["transport_calls"], 0)

    def test_s5_transport_and_digest_failures_are_distinguishable(self):
        by_status = {}
        for record in flatten(self.evidence):
            by_status.setdefault(record["status"], []).append(record)
        rejected = [r for r in by_status.get("REJECTED", [])
                    if r["reason"] == "download digest mismatch" and "attempts" in r]
        transport = by_status.get("ERROR_TRANSPORT", [])
        self.assertEqual(len(rejected), 1, "a 503-flavoured mismatch must be REJECTED")
        self.assertGreater(rejected[0]["attempts"], 1, "502/503/504 must retry (bounded)")
        self.assertEqual(len(transport), 1, "a 404 must surface as ERROR_TRANSPORT")
        self.assertEqual(transport[0]["attempts"], 1, "404 must not be retried")

    def test_s6_null_index_field_fails_closed_absent_composes(self):
        records = next(s["evidence"] for s in self.evidence["scenarios"]
                       if s["name"] == "s6_mirror_index_null_field")
        self.assertEqual(records[0]["status"], "REJECTED")
        self.assertIn("TypeError", records[0]["reason"])
        self.assertEqual(records[1]["status"], "ACCEPTED")

    def test_cli_writes_evidence_and_exits_zero(self):
        with tempfile.TemporaryDirectory(prefix="kas-lock-oracle-cli-") as td:
            out = Path(td) / "evidence.json"
            proc = subprocess.run(
                [sys.executable, "-I", str(ORACLE),
                 "--scratch", str(Path(td) / "scratch"), "--evidence-out", str(out)],
                capture_output=True, text=True, timeout=120)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            self.assertIn("ORACLE PASS", proc.stdout)
            evidence = json.loads(out.read_text(encoding="utf8"))
            self.assertEqual(evidence["verdict"], "ORACLE PASS")

    def test_fixture_records_the_exact_diverging_record(self):
        fixture = json.loads(FIXTURE.read_text(encoding="utf8"))
        provenance = fixture["provenance"]
        self.assertIn("router-emulator", provenance["extracted_from"])
        self.assertEqual(provenance["emulator_ref"],
                         "9e59e0bff1319acbd191867dac1f5ace2df0655f")
        self.assertEqual(len(fixture["upstream_installer_record"]["sha256"]), 64)
        self.assertNotEqual(fixture["upstream_installer_record"]["sha256"],
                            fixture["live_state_at_extraction"]["sha256"],
                            "the fixture must keep the diverging pair, not collapse it")
        self.assertEqual(fixture["live_state_at_extraction"]["size_bytes"], 2941995)

    @unittest.skipUnless(os.environ.get("KAS_LAB_SOURCE"),
                         "real-lab crosscheck is opt-in: set KAS_LAB_SOURCE to a pinned "
                         "router-emulator checkout (emulator_ref 9e59e0b…)")
    def test_real_lab_crosscheck_agrees_with_the_model(self):
        with tempfile.TemporaryDirectory(prefix="kas-lock-oracle-real-") as td:
            out = Path(td) / "evidence.json"
            proc = subprocess.run(
                [sys.executable, "-I", str(ORACLE),
                 "--scratch", str(Path(td) / "scratch"), "--evidence-out", str(out),
                 "--lab-source", os.environ["KAS_LAB_SOURCE"]],
                capture_output=True, text=True, timeout=120)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            evidence = json.loads(out.read_text(encoding="utf8"))
            self.assertEqual(evidence["real_lab_crosscheck"]["verdict"],
                             "REAL-LAB CROSSCHECK PASS")
            for result in evidence["real_lab_crosscheck"]["results"]:
                self.assertTrue(result["agrees_with_model"], result)


if __name__ == "__main__":
    unittest.main()
