#!/usr/bin/env python3
"""Offline untrusted evidence assessment; NO GitHub reads or attestation.

Issue #473 Stage A. Caller supplies MOCK workflow and native artifact data.
Even a perfectly consistent snapshot is NEVER independently verified.
Do not set coordinator Observation.*_verified from this module.

Manifest v1 (see README): the native ``gates.json`` shape below is pinned to
the real producer ``lab.gates.Evidence`` at
``saymer-alt/router-emulator@9e59e0bff1319acbd191867dac1f5ace2df0655f`` — the
exact reusable-workflow ref hardcoded in ``.github/workflows/ported-native-e2e.yml``
— and was cross-checked against the real artifact of hosted native run
42556157563 (artifact id 13647269022) built at KAS HEAD
274b66c1511b9224995a884372fdaf4a6bae123f. Any producer/manifest drift fails
closed with INCOMPLETE until this manifest is consciously re-versioned.
"""
from __future__ import annotations
from dataclasses import dataclass
import re
from types import MappingProxyType
from typing import Any

REPO = "saymer-alt/keenetic-auto-setup"
WORKFLOWS = {
    "shell": ".github/workflows/ci.yml",
    "native": ".github/workflows/ported-native-e2e.yml",
}
SHA = re.compile(r"[a-f0-9]{40}\Z")
SHA256 = re.compile(r"[a-f0-9]{64}\Z")
RUN_URL = re.compile(r"https://github[.]com/saymer-alt/keenetic-auto-setup/actions/runs/([1-9][0-9]*)\Z")
PUBLIC_STATES = frozenset(("PASS", "FAIL", "BLOCKED", "NOT_TESTED"))

# ---------------------------------------------------------------------------
# Manifest v1 — stage "kas" (baseline), the only stage the native workflow can
# run on pull_request events (workflow_dispatch-only stages: entware,
# preflight, uninstall-packages, kas-update, knvr; profile legacy-bridge).
# Source: lab/gates.py GATES/CHECKS/CAPABILITIES/REASONS/write() at the pin.
# ---------------------------------------------------------------------------
MANIFEST_VERSION = 1
MANIFEST_STAGE = "kas"
MANIFEST_PRODUCER = "saymer-alt/router-emulator@9e59e0bff1319acbd191867dac1f5ace2df0655f"

PLATFORM = "WR3000P_PORTED_5_1_8_QEMU"
HARDWARE_ACCEPTANCE = "NOT_TESTED"

GATE_NAMES = frozenset((
    "BOOT_READY", "AUTH_READY", "ENTWARE_READY", "KAS_PREFLIGHT",
    "KAS_INSTALL", "KAS_DOCTOR", "KAS_REBOOT", "KAS_ROLLBACK", "KAS_UNINSTALL",
    "KAS_UNINSTALL_PACKAGES", "KAS_UPDATE_E2E"))
# In stage "kas" these two gates are set BLOCKED/prerequisite_blocked by the
# producer controller before the lifecycle starts and never overridden, so a
# PR artifact can never carry outcome=PASS (producer outcome rule: PASS only
# when every gate and check is PASS).
PREREQ_BLOCKED_GATES = frozenset(("KAS_UNINSTALL_PACKAGES", "KAS_UPDATE_E2E"))
EXERCISED_GATES = GATE_NAMES - PREREQ_BLOCKED_GATES
PREREQ_BLOCKED_ENTRY = MappingProxyType(
    {"status": "BLOCKED", "reason": "prerequisite_blocked"})

CHECK_NAMES = frozenset((
    "KAS_LEGACY_RULES", "KAS_IDEMPOTENCE", "KAS_INSTALL_INTERRUPTION",
    "KAS_UPDATE", "KAS_FOREIGN_RESOURCES", "KAS_UNINSTALL_SNAPSHOT",
    "KAS_TRANSACTION_GATE", "KAS_WAN_RESTART_GUARD", "KAS_UNINSTALL_GUARD",
    "KAS_UNINSTALL_PACKAGES_REPEAT", "KAS_UNINSTALL_PACKAGES_REBOOT",
    "KAS_UPDATE_RELEASE_UPGRADE", "KAS_UPDATE_NOOP", "KAS_UPDATE_IDEMPOTENT",
    "KAS_UPDATE_NETFAIL_REFUSAL", "KAS_UPDATE_MODIFIED_REFUSAL",
    "KAS_UPDATE_FOREIGN_CRON_REVIEW", "KAS_UPDATE_COMMIT_FAILURE",
    "KAS_UPDATE_BUSY_REFUSAL", "KAS_UPDATE_INERTNESS", "KAS_UPDATE_EXITCODES"))
# Checks the producer always writes during a full stage-"kas" baseline run
# (clean lifecycle + separate foreign-resource profile).
REQUIRED_CHECKS = frozenset((
    "KAS_WAN_RESTART_GUARD", "KAS_IDEMPOTENCE", "KAS_INSTALL_INTERRUPTION",
    "KAS_UPDATE", "KAS_UNINSTALL_SNAPSHOT", "KAS_TRANSACTION_GATE",
    "KAS_UNINSTALL_GUARD", "KAS_FOREIGN_RESOURCES"))

CAPABILITY_NAMES = frozenset((
    "ndmc", "native_rci", "dns_filter", "opkg_kmod_netfilter", "dns_tls_or_https",
    "proxy_client", "netfilter_mark", "netfilter_connmark", "tun",
    "routing", "ext4_opt", "ram", "zram", "external_swap", "clock",
    "dns", "local_http", "package_mirror"))
CAPABILITY_STATUSES = frozenset(("SUPPORTED", "UNSUPPORTED", "BLOCKED", "NOT_TESTED"))

REFERENCE_NAMES = frozenset((
    "emulator_commit", "kas_commit", "qemu_source_commit", "qemu_binary_sha256",
    "qemu_patches_sha256", "firmware_sha256", "keenboot_sha256",
    "entware_lock_sha256", "kas_assets_lock_sha256"))
# Run-invariant values hardcoded in (or purely derived from) the pinned
# producer. Only qemu_binary_sha256 is environment-derived and is only
# shape-checked.
EMULATOR_COMMIT = "9e59e0bff1319acbd191867dac1f5ace2df0655f"
QEMU_SOURCE_COMMIT = "f8b2f64e2336a28bf0d50b6ef8a7d8c013e9bcf3"
FIRMWARE_SHA256 = "710e4a37b1aa9f3a65a5122edd0650f5c5ad3e6eca5df53b11ac28aab2664eb7"
KEENBOOT_SHA256 = "8b8615b345d912187853fea6bef6b1868760fd52ed92ba7c3a380ad5533cbf08"
ENTWARE_LOCK_SHA256 = "1c51a73bdcc44c1c5b8ef72e520ccbbd31524cef9682e5450f43b78c384cd951"
KAS_ASSETS_LOCK_SHA256 = "c71536609f45eeac01774f93f00260acbb4ab5a3d21928aecfd1f0a34ab243c2"
PINNED_REFERENCES = {
    "emulator_commit": EMULATOR_COMMIT,
    "qemu_source_commit": QEMU_SOURCE_COMMIT,
    "firmware_sha256": FIRMWARE_SHA256,
    "keenboot_sha256": KEENBOOT_SHA256,
    "entware_lock_sha256": ENTWARE_LOCK_SHA256,
    "kas_assets_lock_sha256": KAS_ASSETS_LOCK_SHA256,
}
COMMIT_REFERENCES = frozenset(("emulator_commit", "qemu_source_commit", "kas_commit"))
UNPINNED_SHA256_REFERENCES = frozenset(("qemu_binary_sha256",))

MEASUREMENT_NAMES = frozenset(("doctor_ok", "doctor_warn", "doctor_fail"))
MEASUREMENT_MAX = 10000

# Fixed public evidence labels the producer accepts (lab/gates.py REASONS,
# including the .update() block); a gates.json can never carry anything else.
EVIDENCE_REASONS = frozenset((
    "unattempted", "prerequisite_blocked", "boot_stages_observed",
    "authenticated_version_and_reboot", "authentication_rejected",
    "serial_timeout", "runner_failure", "ext4_opkg_abi_and_reboot",
    "entware_install_failed", "required_component_absent",
    "runtime_prerequisites_passed", "native_installer_passed",
    "native_doctor_passed", "services_restored_after_reboot",
    "native_rollback_passed", "native_uninstall_passed",
    "native_uninstall_failed", "native_command_verified", "execution_failed",
    "component_absent", "runtime_capability_unavailable",
    "native_installer_failed", "native_doctor_failed", "doctor_warning",
    "verified_tls_source_failed", "native_remove_not_implemented",
    "snapshot_gate_blocked", "native_reboot_failed", "native_rollback_failed",
    "native_update_failed", "idempotence_failed", "rollback_not_exercised",
    "uninstall_not_delivered", "uninstall_candidate_unreviewed",
    "uninstall_packages_passed", "uninstall_packages_failed",
    "watchdog_lock_blocked", "native_services_duplicate",
    "native_services_not_ready", "native_ownership_invalid",
    "native_proxy_invalid", "native_policy_invalid", "native_dns_invalid",
    "native_rules_not_ready", "native_file_digest_invalid",
    "foreign_proxy_changed", "foreign_cron_changed", "foreign_setup_failed",
    "native_socks_not_ready", "native_command_failed",
    "native_command_timed_out", "mihomo_config_changed",
    "magi_config_changed", "watchdog_changed", "hook_changed",
    "crontab_changed", "ledger_changed", "proxy_changed", "policy_changed",
    "netfilter_changed", "legacy_bridge_setup_failed",
    "legacy_bridge_changed", "legacy_bridge_reactivated",
    "kas_update_stage_passed", "kas_update_stage_failed",
    "kas_update_release_upgrade_passed", "kas_update_noop_passed",
    "kas_update_idempotent_passed", "kas_update_netfail_refused",
    "kas_update_modified_refused", "kas_update_foreign_cron_reviewed",
    "kas_update_commit_failure_verified", "kas_update_busy_refused",
    "kas_update_inertness_passed", "kas_update_exitcodes_passed",
    "kas_update_tls_delivery_failed", "kas_update_fixture_unavailable",
    "kas_update_precondition_missing"))

ENTRY_KEYS = frozenset(("status", "reason"))
OUTCOME_VALUES = frozenset(("PASS", "FAIL", "BLOCKED"))


@dataclass(frozen=True)
class Assessment:
    outcome: str
    reason: str
    source: str = "C1_OFFLINE_MOCK_UNVERIFIED"
    provenance_verified: bool = False

    def as_dict(self) -> dict[str, str | bool]:
        return {"outcome": self.outcome, "reason": self.reason,
                "source": self.source, "provenance_verified": self.provenance_verified}


def result(outcome: str, reason: str) -> Assessment:
    return Assessment(outcome, reason)


def _missing_reason(prefix: str, names: frozenset[str], provided: dict) -> str:
    # Only manifest constants can appear here: the difference is computed
    # against the manifest name set, never echoing untrusted keys.
    return prefix + ":" + ",".join(sorted(names - set(provided)))


def _run_shape(run: Any, kind: str, head: str) -> bool:
    if not isinstance(run, dict):
        return False
    repo = run.get("repository")
    if not isinstance(repo, dict) or repo.get("full_name") != REPO:
        return False
    run_id = run.get("id")
    if type(run_id) is not int or run_id <= 0:
        return False
    if run.get("path") != WORKFLOWS[kind] or run.get("event") != "pull_request":
        return False
    if run.get("head_sha") != head:
        return False
    if run.get("status") != "completed" or run.get("conclusion") not in (
            "success", "failure", "cancelled", "timed_out", "action_required"):
        return False
    link = run.get("html_url")
    if not isinstance(link, str):
        return False
    m = RUN_URL.fullmatch(link)
    return m is not None and int(m.group(1)) == run_id


def _entry_valid(entry: Any, statuses: frozenset[str]) -> bool:
    return (isinstance(entry, dict) and set(entry) == ENTRY_KEYS and
            entry["status"] in statuses and
            isinstance(entry["reason"], str) and entry["reason"] in EVIDENCE_REASONS)


def _references_ok(ref: Any, head: str) -> bool:
    if not isinstance(ref, dict) or set(ref) != REFERENCE_NAMES:
        return False
    for name in COMMIT_REFERENCES:
        if not isinstance(ref[name], str) or SHA.fullmatch(ref[name]) is None:
            return False
    for name in UNPINNED_SHA256_REFERENCES:
        if not isinstance(ref[name], str) or SHA256.fullmatch(ref[name]) is None:
            return False
    if ref["kas_commit"] != head:
        return False
    for name, value in PINNED_REFERENCES.items():
        if ref[name] != value:
            return False
    return True


def _measurements_ok(measurements: Any) -> bool:
    if not isinstance(measurements, dict):
        return False
    if not set(measurements) <= MEASUREMENT_NAMES:
        return False
    for value in measurements.values():
        if type(value) is not int or not 0 <= value <= MEASUREMENT_MAX:
            return False
    return True


def assess(head_sha: str, shell: Any, native: Any,
           native_gates: Any) -> Assessment:
    """Assess consistency AND manifest completeness of untrusted snapshots.

    The native artifact must carry the full versioned stage-"kas" manifest:
    exact gate key set, every stage-required check, exact producer
    platform/reference pins, and an outcome the producer could actually emit
    for a pull_request run. No I/O, network, credentials, side effects, or
    trust flags. Returned reason codes are fixed public labels (optionally
    listing missing manifest constants) and never echo untrusted input.
    """
    if not isinstance(head_sha, str) or SHA.fullmatch(head_sha) is None:
        return result("INCOMPLETE", "HEAD_SHA_INVALID")
    if not _run_shape(shell, "shell", head_sha):
        return result("INCOMPLETE", "SHELL_RUN_PROVENANCE_UNPROVEN")
    if not _run_shape(native, "native", head_sha):
        return result("INCOMPLETE", "NATIVE_RUN_PROVENANCE_UNPROVEN")
    if shell["id"] == native["id"]:
        return result("INCOMPLETE", "NON_DISTINCT_WORKFLOW_RUNS")
    if shell["conclusion"] != "success":
        return result("GATE_FAILED", "SHELL_WORKFLOW_NOT_SUCCESS")
    if native["conclusion"] != "success":
        return result("GATE_FAILED", "NATIVE_WORKFLOW_NOT_SUCCESS")
    if not isinstance(native_gates, dict):
        return result("INCOMPLETE", "NATIVE_ARTIFACT_MISSING")
    if type(native_gates.get("schema")) is not int or native_gates["schema"] != 1:
        return result("INCOMPLETE", "NATIVE_ARTIFACT_SCHEMA_UNSUPPORTED")
    if native_gates.get("platform") != PLATFORM:
        return result("INCOMPLETE", "NATIVE_ARTIFACT_PLATFORM_MISMATCH")
    if native_gates.get("hardware_acceptance") != HARDWARE_ACCEPTANCE:
        return result("INCOMPLETE", "NATIVE_ARTIFACT_HARDWARE_ACCEPTANCE_MISMATCH")
    if not _references_ok(native_gates.get("references"), head_sha):
        return result("INCOMPLETE", "NATIVE_ARTIFACT_REFERENCE_MISMATCH")
    outcome = native_gates.get("outcome")
    if outcome not in OUTCOME_VALUES:
        return result("INCOMPLETE", "NATIVE_ARTIFACT_OUTCOME_INVALID")
    gates = native_gates.get("gates")
    checks = native_gates.get("checks")
    capabilities = native_gates.get("capabilities")
    if not isinstance(gates, dict) or not isinstance(checks, dict):
        return result("INCOMPLETE", "NATIVE_GATE_DETAILS_MISSING")
    # Exact key sets: unexpected keys fail closed without being echoed.
    if not set(gates) <= GATE_NAMES:
        return result("INCOMPLETE", "NATIVE_UNEXPECTED_GATE_KEY")
    if not set(checks) <= CHECK_NAMES:
        return result("INCOMPLETE", "NATIVE_UNEXPECTED_CHECK_KEY")
    if not set(checks) <= REQUIRED_CHECKS:
        return result("INCOMPLETE", "NATIVE_CHECK_OUTSIDE_STAGE_MANIFEST")
    if set(gates) != GATE_NAMES:
        return result("INCOMPLETE",
                      _missing_reason("REQUIRED_GATE_MISSING", GATE_NAMES, gates))
    if set(checks) != REQUIRED_CHECKS:
        return result("INCOMPLETE",
                      _missing_reason("REQUIRED_CHECK_MISSING", REQUIRED_CHECKS, checks))
    for group in (gates, checks):
        for entry in group.values():
            if not _entry_valid(entry, PUBLIC_STATES):
                return result("INCOMPLETE", "NATIVE_GATE_DETAILS_MALFORMED")
    if not isinstance(capabilities, dict) or set(capabilities) != CAPABILITY_NAMES:
        return result("INCOMPLETE", "NATIVE_ARTIFACT_CAPABILITIES_MALFORMED")
    for entry in capabilities.values():
        if not _entry_valid(entry, CAPABILITY_STATUSES):
            return result("INCOMPLETE", "NATIVE_GATE_DETAILS_MALFORMED")
    if not _measurements_ok(native_gates.get("measurements")):
        return result("INCOMPLETE", "NATIVE_ARTIFACT_MEASUREMENTS_MALFORMED")
    # outcome=PASS requires all 11 gates PASS, but the producer keeps
    # PREREQ_BLOCKED_GATES at BLOCKED/prerequisite_blocked for stage "kas",
    # so a pull_request artifact can never legitimately claim it.
    if outcome == "PASS":
        return result("INCOMPLETE", "NATIVE_OUTCOME_NOT_PRODUCIBLE_FOR_STAGE")
    # Stage producibility: the prerequisite-blocked pair is fixed by the
    # producer controller; any other shape is unproducible for pull_request.
    for name in PREREQ_BLOCKED_GATES:
        if gates[name] != PREREQ_BLOCKED_ENTRY:
            return result("INCOMPLETE", "NATIVE_GATE_NOT_PRODUCIBLE_FOR_STAGE")
    statuses = ([entry["status"] for entry in gates.values()] +
                [entry["status"] for entry in checks.values()])
    if "FAIL" in statuses and outcome != "FAIL":
        return result("INCOMPLETE", "NATIVE_AGGREGATE_CONTRADICTS_GATE_DETAILS")
    if outcome == "FAIL" and "FAIL" not in statuses:
        return result("INCOMPLETE", "NATIVE_AGGREGATE_CONTRADICTS_GATE_DETAILS")
    if outcome == "FAIL":
        return result("GATE_FAILED", "NATIVE_AGGREGATE_FAIL")
    fully_passed = (all(gates[name]["status"] == "PASS" for name in EXERCISED_GATES)
                    and all(checks[name]["status"] == "PASS"
                            for name in REQUIRED_CHECKS))
    if fully_passed:
        return result("POTENTIAL_PASS", "ALL_REQUIRED_GATES_CONSISTENT")
    return result("GATE_BLOCKED", "NATIVE_AGGREGATE_BLOCKED")
