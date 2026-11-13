#!/usr/bin/env python3
"""Synthetic negative regression for fail-closed QA evidence. Offline stdlib."""
import importlib.util
import copy
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from evidence_gate import EXPECTED_MUTANTS, validate_checkout_evidence, validate_mutation_evidence

sha = "a" * 40


def good_report():
    return {
        "schema": "kas-qa-mutation/v1", "checkout_sha": sha, "overall": "PASS",
        "mutants": [
            {"id": key, "target_case": target, "status": "PASS", "killed": True,
             "baseline": {"exit_code": 0, "case_seen": True,
                          "pass_seen": True, "fail_seen": False},
             "mutant": {"exit_code": 1, "case_seen": True,
                        "pass_seen": False, "fail_seen": True}}
            for key, target in EXPECTED_MUTANTS.items()
        ],
    }


class EvidenceGateTests(unittest.TestCase):
    def assert_blocked(self, report):
        self.assertTrue(validate_mutation_evidence(report, sha))

    def test_happy_path(self):
        self.assertEqual(validate_mutation_evidence(good_report(), sha), [])
        self.assertEqual(validate_checkout_evidence(sha, "0"), [])

    def test_missing_or_corrupt_evidence(self):
        self.assert_blocked({})
        self.assert_blocked(None)
        self.assert_blocked([])

    def test_absent_or_duplicate_mutants(self):
        r = good_report()
        r["mutants"].pop()
        self.assert_blocked(r)
        r = good_report()
        r["mutants"][-1] = dict(r["mutants"][0])
        self.assert_blocked(r)

    def test_timeout_is_never_kill(self):
        r = good_report()
        r["mutants"][0]["mutant"]["exit_code"] = None
        r["mutants"][0]["mutant"]["fail_seen"] = False
        self.assert_blocked(r)

    def test_syntax_error_and_unrelated_exit_are_not_kills(self):
        r = good_report()
        r["mutants"][0]["mutant"]["exit_code"] = 2
        self.assert_blocked(r)
        r = good_report()
        r["mutants"][0]["mutant"]["fail_seen"] = False
        self.assert_blocked(r)

    def test_baseline_must_pass_named_case(self):
        r = good_report()
        r["mutants"][0]["baseline"]["pass_seen"] = False
        self.assert_blocked(r)

    def test_mutation_classifier_rejects_non_target_failures(self):
        spec = importlib.util.spec_from_file_location(
            "qa_mutation", HERE / "mutation-kas.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        good = {"exit_code": 1, "case_seen": True,
                "pass_seen": False, "fail_seen": True}
        self.assertTrue(mod.is_targeted_kill(good))
        for changed in (
            {"exit_code": 2},  # syntax error, not oracle kill
            {"exit_code": None},  # timeout, not oracle kill
            {"fail_seen": False},  # unrelated failure
            {"case_seen": False},  # wrong case
            {"pass_seen": True},  # contradictory PASS
        ):
            candidate = dict(good, **changed)
            self.assertFalse(mod.is_targeted_kill(candidate))

    def test_unhashable_ids_rejected_without_exception(self):
        r = good_report()
        r["mutants"][0]["id"] = ["not", "hashable"]
        self.assert_blocked(r)

    def test_sha_and_dirty_fail_closed(self):
        self.assertTrue(validate_checkout_evidence("UNKNOWN", "0"))
        self.assertTrue(validate_checkout_evidence("123", "0"))
        self.assertTrue(validate_checkout_evidence(sha, "UNKNOWN"))
        self.assertTrue(validate_checkout_evidence(sha, "1"))

    def test_schema_and_checkout_binding(self):
        r = good_report()
        r["schema"] = "other"
        self.assert_blocked(r)
        r = good_report()
        r["checkout_sha"] = "b" * 40
        self.assert_blocked(r)

    def test_fake_pass_summary_without_kill_proof(self):
        r = good_report()
        r["mutants"][0]["mutant"] = {"exit_code": 1}
        self.assert_blocked(r)
        r = good_report()
        r["mutants"][0]["killed"] = False
        self.assert_blocked(r)


if __name__ == "__main__":
    unittest.main()
