"""Offline-only mock tests. No GitHub, KAS, emulator, API or token calls.

The positive fixture mirrors the real producer contract (manifest v1,
router-emulator@9e59e0b): 11 gates, the 8 stage-"kas" checks, 18 capabilities,
9 pinned references. The legacy two-entry snapshot must never reach
POTENTIAL_PASS again (review of #475, comment 6731519071).
"""
import importlib.util
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("evidence_contract", ROOT / "evidence_contract.py")
mod = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)
HEAD = "a" * 40
EMU = "b" * 40
QEMU_BINARY = "c" * 64
QEMU_PATCHES = "2" * 64

GATE_REASONS = {
    "BOOT_READY": "boot_stages_observed",
    "AUTH_READY": "authenticated_version_and_reboot",
    "ENTWARE_READY": "ext4_opkg_abi_and_reboot",
    "KAS_PREFLIGHT": "runtime_prerequisites_passed",
    "KAS_INSTALL": "native_installer_passed",
    "KAS_DOCTOR": "native_doctor_passed",
    "KAS_REBOOT": "services_restored_after_reboot",
    "KAS_ROLLBACK": "native_rollback_passed",
    "KAS_UNINSTALL": "native_uninstall_passed",
}


def references():
    return {"emulator_commit": mod.EMULATOR_COMMIT,
            "kas_commit": HEAD,
            "qemu_source_commit": mod.QEMU_SOURCE_COMMIT,
            "qemu_binary_sha256": QEMU_BINARY,
            "qemu_patches_sha256": QEMU_PATCHES,
            "firmware_sha256": mod.FIRMWARE_SHA256,
            "keenboot_sha256": mod.KEENBOOT_SHA256,
            "entware_lock_sha256": mod.ENTWARE_LOCK_SHA256,
            "kas_assets_lock_sha256": mod.KAS_ASSETS_LOCK_SHA256}


def full_artifact(outcome="BLOCKED"):
    gates = {name: {"status": "PASS", "reason": GATE_REASONS[name]}
             for name in sorted(mod.EXERCISED_GATES)}
    for name in sorted(mod.PREREQ_BLOCKED_GATES):
        gates[name] = {"status": "BLOCKED", "reason": "prerequisite_blocked"}
    checks = {name: {"status": "PASS", "reason": "native_command_verified"}
              for name in sorted(mod.REQUIRED_CHECKS)}
    capabilities = {name: {"status": "SUPPORTED", "reason": "native_command_verified"}
                    for name in sorted(mod.CAPABILITY_NAMES)}
    return {"schema": 1, "platform": mod.PLATFORM, "outcome": outcome,
            "hardware_acceptance": "NOT_TESTED", "gates": gates,
            "capabilities": capabilities, "checks": checks,
            "references": references(),
            "measurements": {"doctor_ok": 35, "doctor_warn": 0, "doctor_fail": 0}}


def run(kind, run_id, result="success"):
    return {"repository": {"full_name": mod.REPO}, "id": run_id,
            "path": mod.WORKFLOWS[kind], "event": "pull_request",
            "head_sha": HEAD, "status": "completed", "conclusion": result,
            "html_url": f"https://github.com/{mod.REPO}/actions/runs/{run_id}"}


REASON_ALPHABET = re.compile(r"[A-Z0-9_:,]+\Z")


class EvidenceContractTests(unittest.TestCase):
    def setUp(self):
        self.s = run("shell", 111)
        self.n = run("native", 222)
        self.g = full_artifact()

    def check(self, expected, reason=None):
        res = mod.assess(HEAD, self.s, self.n, self.g)
        self.assertEqual(res.outcome, expected)
        if reason:
            self.assertEqual(res.reason, reason)
        self.assertFalse(res.provenance_verified)
        self.assertEqual(res.source, "C1_OFFLINE_MOCK_UNVERIFIED")
        self.assertEqual(set(res.as_dict()),
                         {"outcome", "reason", "source", "provenance_verified"})
        self.assertRegex(res.reason, REASON_ALPHABET)
        return res

    # -- manifest integrity ------------------------------------------------
    def test_manifest_shape_is_producer_pinned(self):
        self.assertEqual(len(mod.GATE_NAMES), 11)
        self.assertEqual(len(mod.REQUIRED_CHECKS), 8)
        self.assertEqual(len(mod.CAPABILITY_NAMES), 18)
        self.assertEqual(len(mod.REFERENCE_NAMES), 9)
        self.assertTrue(mod.REQUIRED_CHECKS <= mod.CHECK_NAMES)
        self.assertTrue(mod.PREREQ_BLOCKED_GATES <= mod.GATE_NAMES)
        self.assertEqual(mod.EXERCISED_GATES,
                         mod.GATE_NAMES - mod.PREREQ_BLOCKED_GATES)
        self.assertEqual(mod.ENTRY_KEYS, {"status", "reason"})

    # -- positive classification ------------------------------------------
    def test_complete_consistent_mock_cannot_be_real_verified(self):
        self.check("POTENTIAL_PASS", "ALL_REQUIRED_GATES_CONSISTENT")

    # -- workflow-level provenance (regressions #458, #470) ----------------
    def test_native_fail_overrides_shell_green_458(self):
        self.n["conclusion"] = "failure"
        self.check("GATE_FAILED", "NATIVE_WORKFLOW_NOT_SUCCESS")

    def test_aggregate_blocked_overrides_native_green_470(self):
        self.g["gates"]["KAS_UNINSTALL"] = {
            "status": "BLOCKED", "reason": "native_remove_not_implemented"}
        self.g["checks"]["KAS_UNINSTALL_SNAPSHOT"] = {
            "status": "BLOCKED", "reason": "native_remove_not_implemented"}
        self.g["checks"]["KAS_TRANSACTION_GATE"] = {
            "status": "BLOCKED", "reason": "native_remove_not_implemented"}
        self.check("GATE_BLOCKED", "NATIVE_AGGREGATE_BLOCKED")

    def test_aggregate_fail_overrides_native_green(self):
        self.g["outcome"] = "FAIL"
        self.g["gates"]["KAS_INSTALL"] = {
            "status": "FAIL", "reason": "native_installer_failed"}
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

    def test_bool_instead_of_run_id_stops(self):
        self.s["id"] = True
        self.check("INCOMPLETE", "SHELL_RUN_PROVENANCE_UNPROVEN")

    def test_malformed_head_stops(self):
        res = mod.assess("a" * 39, self.s, self.n, self.g)
        self.assertEqual((res.outcome, res.reason),
                         ("INCOMPLETE", "HEAD_SHA_INVALID"))

    # -- artifact top-level contract ---------------------------------------
    def test_invalid_schema_stops(self):
        self.g["schema"] = True
        self.check("INCOMPLETE", "NATIVE_ARTIFACT_SCHEMA_UNSUPPORTED")

    def test_unknown_schema_version_stops(self):
        self.g["schema"] = 2
        self.check("INCOMPLETE", "NATIVE_ARTIFACT_SCHEMA_UNSUPPORTED")

    def test_platform_mismatch_stops(self):
        self.g["platform"] = "WR3000P_PORTED_9_9_9_QEMU"
        self.check("INCOMPLETE", "NATIVE_ARTIFACT_PLATFORM_MISMATCH")

    def test_hardware_acceptance_tampered_stops(self):
        self.g["hardware_acceptance"] = "PASS"
        self.check("INCOMPLETE", "NATIVE_ARTIFACT_HARDWARE_ACCEPTANCE_MISMATCH")

    def test_unknown_outcome_value_stops(self):
        self.g["outcome"] = "GREEN"
        self.check("INCOMPLETE", "NATIVE_ARTIFACT_OUTCOME_INVALID")

    def test_not_tested_outcome_value_stops(self):
        self.g["outcome"] = "NOT_TESTED"
        self.check("INCOMPLETE", "NATIVE_ARTIFACT_OUTCOME_INVALID")

    # -- references: pins, shapes, head binding ----------------------------
    def test_wrong_artifact_commit_stops(self):
        self.g["references"]["kas_commit"] = EMU
        self.check("INCOMPLETE", "NATIVE_ARTIFACT_REFERENCE_MISMATCH")

    def test_unpinned_emulator_commit_stops(self):
        self.g["references"]["emulator_commit"] = EMU
        self.check("INCOMPLETE", "NATIVE_ARTIFACT_REFERENCE_MISMATCH")

    def test_unpinned_qemu_source_commit_stops(self):
        self.g["references"]["qemu_source_commit"] = EMU
        self.check("INCOMPLETE", "NATIVE_ARTIFACT_REFERENCE_MISMATCH")

    def test_tampered_firmware_hash_stops(self):
        self.g["references"]["firmware_sha256"] = "f" * 64
        self.check("INCOMPLETE", "NATIVE_ARTIFACT_REFERENCE_MISMATCH")

    def test_missing_reference_key_stops(self):
        del self.g["references"]["entware_lock_sha256"]
        self.check("INCOMPLETE", "NATIVE_ARTIFACT_REFERENCE_MISMATCH")

    def test_extra_reference_key_stops(self):
        self.g["references"]["evil_extra"] = "x" * 64
        self.check("INCOMPLETE", "NATIVE_ARTIFACT_REFERENCE_MISMATCH")

    def test_short_qemu_binary_hash_stops(self):
        self.g["references"]["qemu_binary_sha256"] = "c" * 63
        self.check("INCOMPLETE", "NATIVE_ARTIFACT_REFERENCE_MISMATCH")

    def test_references_not_dict_stops(self):
        self.g["references"] = []
        self.check("INCOMPLETE", "NATIVE_ARTIFACT_REFERENCE_MISMATCH")

    # -- gate manifest completeness ----------------------------------------
    def test_missing_install_gate_is_not_potential_pass(self):
        del self.g["gates"]["KAS_INSTALL"]
        self.check("INCOMPLETE", "REQUIRED_GATE_MISSING:KAS_INSTALL")

    def test_missing_auth_gate_is_not_potential_pass(self):
        del self.g["gates"]["AUTH_READY"]
        self.check("INCOMPLETE", "REQUIRED_GATE_MISSING:AUTH_READY")

    def test_missing_gates_listed_deterministically(self):
        del self.g["gates"]["AUTH_READY"]
        del self.g["gates"]["KAS_INSTALL"]
        del self.g["gates"]["KAS_DOCTOR"]
        self.check("INCOMPLETE",
                   "REQUIRED_GATE_MISSING:AUTH_READY,KAS_DOCTOR,KAS_INSTALL")

    def test_legacy_two_entry_fixture_is_not_potential_pass(self):
        legacy = {"schema": 1, "platform": mod.PLATFORM, "outcome": "PASS",
                  "hardware_acceptance": "NOT_TESTED",
                  "gates": {"BOOT_READY": {"status": "PASS",
                                           "reason": "boot_stages_observed"}},
                  "capabilities": {},
                  "checks": {"KAS_FOREIGN_RESOURCES": {
                      "status": "PASS", "reason": "native_command_verified"}},
                  "references": references(), "measurements": {}}
        res = mod.assess(HEAD, self.s, self.n, legacy)
        self.assertEqual(res.outcome, "INCOMPLETE")
        self.assertTrue(res.reason.startswith("REQUIRED_GATE_MISSING:"))
        self.assertIn("AUTH_READY", res.reason)
        self.assertFalse(res.provenance_verified)

    def test_unexpected_gate_key_stops(self):
        self.g["gates"]["EXTRA_GATE"] = {
            "status": "PASS", "reason": "native_command_verified"}
        self.check("INCOMPLETE", "NATIVE_UNEXPECTED_GATE_KEY")

    def test_unexpected_gate_key_not_echoed(self):
        self.g["gates"]["HOSTILE_KEY_9"] = {
            "status": "PASS", "reason": "native_command_verified"}
        res = self.check("INCOMPLETE", "NATIVE_UNEXPECTED_GATE_KEY")
        self.assertNotIn("HOSTILE", res.reason)

    def test_gates_not_dict_stops(self):
        self.g["gates"] = []
        self.check("INCOMPLETE", "NATIVE_GATE_DETAILS_MISSING")

    # -- check manifest completeness ---------------------------------------
    def test_missing_foreign_resource_check_stops(self):
        del self.g["checks"]["KAS_FOREIGN_RESOURCES"]
        self.check("INCOMPLETE", "REQUIRED_CHECK_MISSING:KAS_FOREIGN_RESOURCES")

    def test_missing_wan_guard_check_stops(self):
        del self.g["checks"]["KAS_WAN_RESTART_GUARD"]
        self.check("INCOMPLETE", "REQUIRED_CHECK_MISSING:KAS_WAN_RESTART_GUARD")

    def test_missing_checks_listed_deterministically(self):
        del self.g["checks"]["KAS_UPDATE"]
        del self.g["checks"]["KAS_IDEMPOTENCE"]
        self.check("INCOMPLETE",
                   "REQUIRED_CHECK_MISSING:KAS_IDEMPOTENCE,KAS_UPDATE")

    def test_other_stage_check_is_outside_manifest(self):
        self.g["checks"]["KAS_UNINSTALL_PACKAGES_REPEAT"] = {
            "status": "PASS", "reason": "uninstall_packages_passed"}
        self.check("INCOMPLETE", "NATIVE_CHECK_OUTSIDE_STAGE_MANIFEST")

    def test_unexpected_check_key_stops(self):
        self.g["checks"]["MADE_UP_CHECK"] = {
            "status": "PASS", "reason": "native_command_verified"}
        self.check("INCOMPLETE", "NATIVE_UNEXPECTED_CHECK_KEY")

    def test_checks_not_dict_stops(self):
        self.g["checks"] = "PASS"
        self.check("INCOMPLETE", "NATIVE_GATE_DETAILS_MISSING")

    # -- per-entry shape and vocabulary ------------------------------------
    def test_entry_without_reason_stops(self):
        self.g["gates"]["BOOT_READY"] = {"status": "PASS"}
        self.check("INCOMPLETE", "NATIVE_GATE_DETAILS_MALFORMED")

    def test_entry_with_extra_key_stops(self):
        self.g["checks"]["KAS_UPDATE"] = {
            "status": "PASS", "reason": "native_command_verified", "note": "x"}
        self.check("INCOMPLETE", "NATIVE_GATE_DETAILS_MALFORMED")

    def test_forged_reason_label_stops(self):
        self.g["checks"]["KAS_UPDATE"] = {
            "status": "PASS", "reason": "trust_me_everything_passed"}
        self.check("INCOMPLETE", "NATIVE_GATE_DETAILS_MALFORMED")

    def test_entry_status_casing_stops(self):
        self.g["gates"]["KAS_REBOOT"] = {
            "status": "pass", "reason": "services_restored_after_reboot"}
        self.check("INCOMPLETE", "NATIVE_GATE_DETAILS_MALFORMED")

    def test_capability_status_vocabulary_stops(self):
        self.g["capabilities"]["tun"] = {
            "status": "PASS", "reason": "native_command_verified"}
        self.check("INCOMPLETE", "NATIVE_GATE_DETAILS_MALFORMED")

    def test_capability_set_missing_key_stops(self):
        del self.g["capabilities"]["zram"]
        self.check("INCOMPLETE", "NATIVE_ARTIFACT_CAPABILITIES_MALFORMED")

    def test_capability_set_extra_key_stops(self):
        self.g["capabilities"]["nvme"] = {
            "status": "SUPPORTED", "reason": "native_command_verified"}
        self.check("INCOMPLETE", "NATIVE_ARTIFACT_CAPABILITIES_MALFORMED")

    # -- measurements -------------------------------------------------------
    def test_bool_measurement_stops(self):
        self.g["measurements"]["doctor_ok"] = True
        self.check("INCOMPLETE", "NATIVE_ARTIFACT_MEASUREMENTS_MALFORMED")

    def test_out_of_range_measurement_stops(self):
        self.g["measurements"]["doctor_fail"] = 10001
        self.check("INCOMPLETE", "NATIVE_ARTIFACT_MEASUREMENTS_MALFORMED")

    def test_unknown_measurement_stops(self):
        self.g["measurements"]["runtime_seconds"] = 12
        self.check("INCOMPLETE", "NATIVE_ARTIFACT_MEASUREMENTS_MALFORMED")

    def test_missing_measurements_section_stops(self):
        del self.g["measurements"]
        self.check("INCOMPLETE", "NATIVE_ARTIFACT_MEASUREMENTS_MALFORMED")

    # -- stage producibility (manifest core) --------------------------------
    def test_prereq_gate_pass_is_not_producible(self):
        self.g["gates"]["KAS_UNINSTALL_PACKAGES"] = {
            "status": "PASS", "reason": "uninstall_packages_passed"}
        self.check("INCOMPLETE", "NATIVE_GATE_NOT_PRODUCIBLE_FOR_STAGE")

    def test_prereq_gate_not_tested_is_not_producible(self):
        self.g["gates"]["KAS_UPDATE_E2E"] = {
            "status": "NOT_TESTED", "reason": "unattempted"}
        self.check("INCOMPLETE", "NATIVE_GATE_NOT_PRODUCIBLE_FOR_STAGE")

    def test_prereq_gate_wrong_reason_is_not_producible(self):
        self.g["gates"]["KAS_UPDATE_E2E"] = {
            "status": "BLOCKED", "reason": "unattempted"}
        self.check("INCOMPLETE", "NATIVE_GATE_NOT_PRODUCIBLE_FOR_STAGE")

    def test_full_pass_outcome_is_not_producible_for_pr_stage(self):
        for name in mod.PREREQ_BLOCKED_GATES:
            self.g["gates"][name] = {
                "status": "PASS", "reason": GATE_REASONS.get(
                    name, "native_command_verified")}
        self.g["outcome"] = "PASS"
        self.check("INCOMPLETE", "NATIVE_OUTCOME_NOT_PRODUCIBLE_FOR_STAGE")

    # -- aggregate consistency ---------------------------------------------
    def test_pass_outcome_with_fail_status_stops_unproducible(self):
        # outcome=PASS is checked before aggregate details: for stage "kas" it
        # is unproducible regardless of the per-gate statuses beneath it.
        self.g["outcome"] = "PASS"
        self.g["checks"]["KAS_UPDATE"] = {
            "status": "FAIL", "reason": "native_update_failed"}
        self.check("INCOMPLETE", "NATIVE_OUTCOME_NOT_PRODUCIBLE_FOR_STAGE")

    def test_fail_status_with_blocked_outcome_contradicts(self):
        self.g["checks"]["KAS_UPDATE"] = {
            "status": "FAIL", "reason": "native_update_failed"}
        self.check("INCOMPLETE", "NATIVE_AGGREGATE_CONTRADICTS_GATE_DETAILS")

    def test_no_failure_in_aggregate_fail_stops(self):
        self.g["outcome"] = "FAIL"
        self.check("INCOMPLETE", "NATIVE_AGGREGATE_CONTRADICTS_GATE_DETAILS")

    def test_blocked_outcome_with_all_pass_gates_is_not_producible(self):
        # All 11 gates PASS (including the prerequisite pair) is the forged
        # "everything green" shape; the stage rule catches it before any
        # aggregate reasoning, because a PR run can never set them PASS.
        for name in mod.PREREQ_BLOCKED_GATES:
            self.g["gates"][name] = {
                "status": "PASS", "reason": "native_command_verified"}
        self.check("INCOMPLETE", "NATIVE_GATE_NOT_PRODUCIBLE_FOR_STAGE")

    # -- terminal classes ---------------------------------------------------
    def test_doctor_warning_keeps_result_blocked(self):
        self.g["gates"]["KAS_DOCTOR"] = {
            "status": "BLOCKED", "reason": "doctor_warning"}
        self.check("GATE_BLOCKED", "NATIVE_AGGREGATE_BLOCKED")

    def test_blocked_required_check_keeps_result_blocked(self):
        self.g["checks"]["KAS_UNINSTALL_SNAPSHOT"] = {
            "status": "BLOCKED", "reason": "native_remove_not_implemented"}
        self.check("GATE_BLOCKED", "NATIVE_AGGREGATE_BLOCKED")

    def test_every_terminal_result_stays_unverified(self):
        scenarios = [
            (full_artifact(), "POTENTIAL_PASS"),
            (None, "INCOMPLETE"),
            (full_artifact("FAIL"), None),
        ]
        for artifact, _ in scenarios:
            if artifact is not None and artifact["outcome"] == "FAIL":
                artifact["gates"]["KAS_INSTALL"] = {
                    "status": "FAIL", "reason": "native_installer_failed"}
            res = mod.assess(HEAD, self.s, self.n, artifact)
            self.assertFalse(res.provenance_verified)
            self.assertEqual(res.source, "C1_OFFLINE_MOCK_UNVERIFIED")

    def test_reasons_never_echo_untrusted_payload(self):
        self.g["gates"]["DROP_TABLE_USERS"] = {
            "status": "PASS", "reason": "native_command_verified"}
        self.n["html_url"] = "https://github.com/evil/payload"
        self.g["checks"]["KAS_UPDATE"] = {
            "status": "PASS", "reason": "injected;'--"}
        res = mod.assess(HEAD, self.s, self.n, self.g)
        self.assertNotIn("DROP_TABLE", res.reason)
        self.assertNotIn("evil", res.reason)
        self.assertNotIn("injected", res.reason)
        self.assertRegex(res.reason, REASON_ALPHABET)


if __name__ == "__main__":
    unittest.main()
