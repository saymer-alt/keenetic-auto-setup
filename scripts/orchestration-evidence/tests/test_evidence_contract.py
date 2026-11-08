"""Offline-only mock tests. No GitHub, KAS, emulator, API or token calls."""
import importlib.util
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("evidence_contract", ROOT / "evidence_contract.py")
mod = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)
HEAD = "a" * 40
EMU = "b" * 40


def run(kind, run_id, result="success"):
    return {"repository": {"full_name": mod.REPO}, "id": run_id,
            "path": mod.WORKFLOWS[kind], "event": "pull_request",
            "head_sha": HEAD, "status": "completed", "conclusion": result,
            "html_url": f"https://github.com/{mod.REPO}/actions/runs/{run_id}"}


def gates(outcome="PASS"):
    status = "PASS" if outcome == "PASS" else outcome
    return {"schema": 1, "references": {"kas_commit": HEAD, "emulator_commit": EMU},
            "outcome": outcome,
            "gates": {"BOOT_READY": {"status": "PASS", "reason": "boot_stages_observed"}},
            "checks": {"KAS_FOREIGN_RESOURCES": {
                "status": status, "reason": "native_command_verified"}}}


class EvidenceContractTests(unittest.TestCase):
    def setUp(self):
        self.s = run("shell", 111)
        self.n = run("native", 222)
        self.g = gates()

    def check(self, expected, reason=None):
        res = mod.assess(HEAD, self.s, self.n, self.g)
        self.assertEqual(res.outcome, expected)
        if reason:
            self.assertEqual(res.reason, reason)
        self.assertFalse(res.provenance_verified)
        self.assertEqual(res.source, "C1_OFFLINE_MOCK_UNVERIFIED")
        self.assertEqual(set(res.as_dict()),
                         {"outcome", "reason", "source", "provenance_verified"})

    def test_consistent_mock_cannot_be_real_verified(self):
        self.check("POTENTIAL_PASS", "ALL_MOCK_GATES_CONSISTENT")

    def test_native_fail_overrides_shell_green_458(self):
        self.n["conclusion"] = "failure"
        self.check("GATE_FAILED", "NATIVE_WORKFLOW_NOT_SUCCESS")

    def test_aggregate_blocked_overrides_native_green_470(self):
        self.g = gates("BLOCKED")
        self.check("GATE_BLOCKED", "NATIVE_AGGREGATE_BLOCKED")

    def test_aggregate_fail_overrides_native_green(self):
        self.g = gates("FAIL")
        self.check("GATE_FAILED", "NATIVE_AGGREGATE_FAIL")

    def test_shell_fail_alone_stops(self):
        self.s["conclusion"] = "failure"
        self.check("GATE_FAILED", "SHELL_WORKFLOW_NOT_SUCCESS")

    def test_missing_artifact_stops(self):
        self.g = None
        self.check("INCOMPLETE", "NATIVE_ARTIFACT_MISSING")

    def test_wrong_head_from_shell_stops(self):
        self.s["head_sha"] = EMU
        self.check("INCOMPLETE", "SHELL_RUN_PROVENANCE_UNPROVEN")

    def test_wrong_head_from_native_stops(self):
        self.n["head_sha"] = EMU
        self.check("INCOMPLETE", "NATIVE_RUN_PROVENANCE_UNPROVEN")

    def test_cross_run_identity_stops(self):
        self.n["id"] = 111
        self.n["html_url"] = self.s["html_url"]
        self.check("INCOMPLETE", "NON_DISTINCT_WORKFLOW_RUNS")

    def test_wrong_repo_in_snapshot_stops(self):
        self.n["repository"] = {"full_name": "someone/other"}
        self.check("INCOMPLETE", "NATIVE_RUN_PROVENANCE_UNPROVEN")

    def test_bad_run_url_stops(self):
        self.s["html_url"] += "?redirect=evil"
        self.check("INCOMPLETE", "SHELL_RUN_PROVENANCE_UNPROVEN")

    def test_wrong_workflow_type_stops(self):
        self.n["path"] = mod.WORKFLOWS["shell"]
        self.check("INCOMPLETE", "NATIVE_RUN_PROVENANCE_UNPROVEN")

    def test_wrong_event_stops(self):
        self.s["event"] = "workflow_dispatch"
        self.check("INCOMPLETE", "SHELL_RUN_PROVENANCE_UNPROVEN")

    def test_unfinished_workflow_stops(self):
        self.s["status"] = "in_progress"
        self.check("INCOMPLETE", "SHELL_RUN_PROVENANCE_UNPROVEN")

    def test_wrong_artifact_commit_stops(self):
        self.g["references"]["kas_commit"] = EMU
        self.check("INCOMPLETE", "NATIVE_ARTIFACT_REFERENCE_MISMATCH")

    def test_invalid_emulator_sha_stops(self):
        self.g["references"]["emulator_commit"] = "unknown"
        self.check("INCOMPLETE", "NATIVE_ARTIFACT_REFERENCE_MISMATCH")

    def test_missing_foreign_gate_stops(self):
        self.g["checks"] = {"KAS_UPDATE": {"status": "PASS", "reason": "ok"}}
        self.check("INCOMPLETE", "FOREIGN_RESOURCE_GATE_MISSING")

    def test_false_aggregate_pass_contradiction_stops(self):
        self.g["checks"]["KAS_FOREIGN_RESOURCES"]["status"] = "FAIL"
        self.check("INCOMPLETE", "NATIVE_AGGREGATE_CONTRADICTS_GATE_DETAILS")

    def test_false_aggregate_blocked_contradiction_stops(self):
        self.g = gates("BLOCKED")
        self.g["checks"]["KAS_FOREIGN_RESOURCES"]["status"] = "FAIL"
        self.check("INCOMPLETE", "NATIVE_AGGREGATE_CONTRADICTS_GATE_DETAILS")

    def test_no_failure_in_aggregate_fail_stops(self):
        self.g["outcome"] = "FAIL"
        self.check("INCOMPLETE", "NATIVE_AGGREGATE_CONTRADICTS_GATE_DETAILS")

    def test_invalid_status_object_stops(self):
        self.g["gates"]["BOOT_READY"] = {"status": "PASS"}
        self.check("INCOMPLETE", "NATIVE_GATE_DETAILS_MALFORMED")

    def test_bool_instead_of_run_id_stops(self):
        self.s["id"] = True
        self.check("INCOMPLETE", "SHELL_RUN_PROVENANCE_UNPROVEN")

    def test_malformed_head_stops(self):
        res = mod.assess("a"*39, self.s, self.n, self.g)
        self.assertEqual((res.outcome, res.reason),
                         ("INCOMPLETE", "HEAD_SHA_INVALID"))

    def test_invalid_schema_stops(self):
        self.g["schema"] = True
        self.check("INCOMPLETE", "NATIVE_ARTIFACT_SCHEMA_UNSUPPORTED")


if __name__ == "__main__":
    unittest.main()
