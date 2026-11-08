#!/usr/bin/env python3
"""Offline untrusted evidence assessment; NO GitHub reads or attestation.

Issue #473 Stage A. Caller supplies MOCK workflow and native artifact data.
Even a perfectly consistent snapshot is NEVER independently verified.
Do not set coordinator Observation.*_verified from this module.
"""
from __future__ import annotations
from dataclasses import dataclass
import re
from typing import Any

REPO = "saymer-alt/keenetic-auto-setup"
WORKFLOWS = {
    "shell": ".github/workflows/ci.yml",
    "native": ".github/workflows/ported-native-e2e.yml",
}
SHA = re.compile(r"[a-f0-9]{40}\Z")
RUN_URL = re.compile(r"https://github[.]com/saymer-alt/keenetic-auto-setup/actions/runs/([1-9][0-9]*)\Z")
PUBLIC_STATES = frozenset(("PASS", "FAIL", "BLOCKED", "NOT_TESTED"))


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


def assess(head_sha: str, shell: Any, native: Any,
           native_gates: Any) -> Assessment:
    """Assess consistency of untrusted snapshots, NOT their origin.

    No I/O, network, credentials, side effects, or trust flags.
    Returned reason codes are fixed public labels and never echo inputs.
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
    ref = native_gates.get("references")
    if (not isinstance(ref, dict) or ref.get("kas_commit") != head_sha or
            not isinstance(ref.get("emulator_commit"), str) or
            SHA.fullmatch(ref["emulator_commit"]) is None):
        return result("INCOMPLETE", "NATIVE_ARTIFACT_REFERENCE_MISMATCH")
    outcome = native_gates.get("outcome")
    if outcome not in ("PASS", "FAIL", "BLOCKED"):
        return result("INCOMPLETE", "NATIVE_ARTIFACT_OUTCOME_INVALID")
    gates = native_gates.get("gates")
    checks = native_gates.get("checks")
    if not isinstance(gates, dict) or not gates or not isinstance(checks, dict) or not checks:
        return result("INCOMPLETE", "NATIVE_GATE_DETAILS_MISSING")
    if "KAS_FOREIGN_RESOURCES" not in checks:
        return result("INCOMPLETE", "FOREIGN_RESOURCE_GATE_MISSING")
    statuses = []
    for group in (gates, checks):
        for entry in group.values():
            if (not isinstance(entry, dict) or entry.get("status") not in PUBLIC_STATES or
                    not isinstance(entry.get("reason"), str) or not entry["reason"]):
                return result("INCOMPLETE", "NATIVE_GATE_DETAILS_MALFORMED")
            statuses.append(entry["status"])
    if outcome == "PASS" and any(x != "PASS" for x in statuses):
        return result("INCOMPLETE", "NATIVE_AGGREGATE_CONTRADICTS_GATE_DETAILS")
    if outcome == "BLOCKED" and "FAIL" in statuses:
        return result("INCOMPLETE", "NATIVE_AGGREGATE_CONTRADICTS_GATE_DETAILS")
    if outcome == "FAIL" and "FAIL" not in statuses:
        return result("INCOMPLETE", "NATIVE_AGGREGATE_CONTRADICTS_GATE_DETAILS")
    if outcome == "BLOCKED" and not any(x in ("BLOCKED", "NOT_TESTED") for x in statuses):
        return result("INCOMPLETE", "NATIVE_AGGREGATE_CONTRADICTS_GATE_DETAILS")
    if outcome == "FAIL":
        return result("GATE_FAILED", "NATIVE_AGGREGATE_FAIL")
    if outcome == "BLOCKED":
        return result("GATE_BLOCKED", "NATIVE_AGGREGATE_BLOCKED")
    return result("POTENTIAL_PASS", "ALL_MOCK_GATES_CONSISTENT")
