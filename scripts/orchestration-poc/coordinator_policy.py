#!/usr/bin/env python3
"""Offline-only decision policy prototype for coordinator Issue #456 (C0).

This is a pure function over a caller-supplied observation. It does not fetch
GitHub, attest CI, run an executor, post a comment, spend tokens, or merge.
The caller must independently verify Issue/PR/CI identities and provenance.
NEVER treat this output as permission to perform an actual side effect.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

REPO = "saymer-alt/keenetic-auto-setup"
SHA = re.compile(r"^[0-9a-f]{40}$")
RUN_ID = re.compile(r"^[0-9a-f]{32}$")
TASK_STATES = frozenset(("READY", "CLAIMED", "RUNNING", "REVIEW_READY",
                         "BLOCKED", "OWNER_DECISION"))
CI_STATES = frozenset(("NOT_CHECKED", "PENDING", "SUCCESS", "FAILURE", "ERROR"))
REVIEW_STATES = frozenset(("NOT_CHECKED", "APPROVED",
                           "CHANGES_REQUESTED", "BLOCKED"))
# GitHub Actions workflow status != actual acceptance-gate outcome.
# An E2E workflow can be SUCCESS even when its uploaded gates.json is BLOCKED.
NATIVE_GATE_OUTCOMES = frozenset(("NOT_CHECKED", "PASS", "BLOCKED", "FAIL", "NOT_TESTED"))
MAX_REWORKS = 2


@dataclass(frozen=True)
class Observation:
    """Untrusted input; booleans are assertions, NOT automatically verified facts.

    Fail-closed defaults prevent a constructed Observation() from dispatching.
    Only a future approved connector may set verified flags after read-back.
    """

    repo: str = REPO
    issue: int = 456
    task_id: str = ""
    run_id: str = ""
    base_sha: str = ""
    head_sha: str = ""
    checkout_sha: str = ""
    state: str = "READY"

    kill_switch: bool = True
    issue_open: bool = False
    issue_fresh: bool = False
    scope_allowed: bool = False
    other_active_tasks: int = 0

    transport_ready: bool = False
    executor_ready: bool = False
    executor_authorized: bool = False
    quota_verified: bool = False
    model_calls_remaining: int = 0

    elapsed_seconds: int = 0
    timeout_seconds: int = 3600

    ci_status: str = "NOT_CHECKED"
    ci_head_sha: str = ""
    ci_run_url: str = ""
    ci_verified: bool = False

    # A second independently verified Actions run plus aggregate gates.json.
    # Every value here remains a CLAIM until a future read-only verifier
    # reads GitHub workflow metadata and the exact run's gates artifact.
    native_e2e_status: str = "NOT_CHECKED"
    native_e2e_head_sha: str = ""
    native_e2e_run_url: str = ""
    native_e2e_verified: bool = False
    native_gates_outcome: str = "NOT_CHECKED"
    native_gates_verified: bool = False

    ci_failure_fixable: bool = False
    failure_signature: str = ""
    previous_failure_signature: str = ""
    reworks_done: int = 0

    review_status: str = "NOT_CHECKED"
    review_verified: bool = False


@dataclass(frozen=True)
class Decision:
    """An inert recommendation, not a command or evidence of successful work."""

    action: str
    reason: str
    proposed_state: str
    owner_decision_required: bool = False
    source: str = "C0_OFFLINE_UNVERIFIED"

    def as_dict(self) -> dict[str, object]:
        return {
            "schema": "kas-coordinator-policy-c0/1",
            "action": self.action,
            "reason": self.reason,
            "proposed_state": self.proposed_state,
            "owner_decision_required": self.owner_decision_required,
            "source": self.source,
        }


def _decision(action: str, reason: str, state: str,
              owner: bool = False) -> Decision:
    return Decision(action, reason, state, owner)


def _valid_input(s: Observation) -> bool:
    if not isinstance(s, Observation):
        return False
    if s.repo != REPO or type(s.issue) is not int or s.issue < 1:
        return False
    if (not isinstance(s.base_sha, str) or not SHA.fullmatch(s.base_sha)
            or not isinstance(s.head_sha, str) or not SHA.fullmatch(s.head_sha)
            or not isinstance(s.checkout_sha, str) or
            not SHA.fullmatch(s.checkout_sha)):
        return False
    if (not isinstance(s.run_id, str) or not RUN_ID.fullmatch(s.run_id)
            or s.task_id != f"issue-{s.issue}-{s.base_sha[:12]}"):
        return False
    if s.state not in TASK_STATES or s.ci_status not in CI_STATES:
        return False
    if (s.native_e2e_status not in CI_STATES
            or s.native_gates_outcome not in NATIVE_GATE_OUTCOMES):
        return False
    if s.review_status not in REVIEW_STATES:
        return False
    for flag in (
        s.kill_switch, s.issue_open, s.issue_fresh, s.scope_allowed,
        s.transport_ready, s.executor_ready, s.executor_authorized,
        s.quota_verified, s.ci_verified, s.ci_failure_fixable,
        s.native_e2e_verified, s.native_gates_verified, s.review_verified,
    ):
        if type(flag) is not bool:
            return False
    for integer in (
        s.other_active_tasks, s.model_calls_remaining, s.elapsed_seconds,
        s.timeout_seconds, s.reworks_done,
    ):
        if type(integer) is not int or integer < 0:
            return False
    if s.timeout_seconds == 0 or s.reworks_done > MAX_REWORKS:
        return False
    if not isinstance(s.failure_signature, str) or len(s.failure_signature) > 80:
        return False
    if (not isinstance(s.previous_failure_signature, str)
            or len(s.previous_failure_signature) > 80):
        return False
    if s.failure_signature and not re.fullmatch(r"[A-Za-z0-9_.:-]{1,80}", s.failure_signature):
        return False
    if s.previous_failure_signature and not re.fullmatch(
            r"[A-Za-z0-9_.:-]{1,80}", s.previous_failure_signature):
        return False
    if not isinstance(s.ci_head_sha, str) or (s.ci_head_sha and
            not SHA.fullmatch(s.ci_head_sha)):
        return False
    if not isinstance(s.ci_run_url, str):
        return False
    # This validates an evidence URL's *shape*, never its authenticity.
    if s.ci_run_url and not re.fullmatch(
            r"https://github[.]com/saymer-alt/keenetic-auto-setup/actions/runs/[1-9][0-9]*",
            s.ci_run_url):
        return False
    if (not isinstance(s.native_e2e_head_sha, str) or
            (s.native_e2e_head_sha and not SHA.fullmatch(s.native_e2e_head_sha))):
        return False
    if not isinstance(s.native_e2e_run_url, str):
        return False
    if s.native_e2e_run_url and not re.fullmatch(
            r"https://github[.]com/saymer-alt/keenetic-auto-setup/actions/runs/[1-9][0-9]*",
            s.native_e2e_run_url):
        return False
    if s.native_e2e_run_url and s.native_e2e_run_url == s.ci_run_url:
        # KAS Shell contracts and Native E2E are distinct required workflows.
        return False
    return True


def decide(s: Observation) -> Decision:
    """Compute one conservative NEXT STEP only; perform ZERO actions."""
    if not _valid_input(s):
        return _decision("STOP", "BAD_OBSERVATION", "BLOCKED")
    if s.kill_switch:
        return _decision("STOP", "KILL_SWITCH", "BLOCKED")
    if not s.issue_open:
        return _decision("STOP", "ISSUE_NOT_OPEN", "BLOCKED")
    if not s.issue_fresh:
        return _decision("STOP", "ISSUE_CHANGED", "BLOCKED")
    if not s.scope_allowed:
        return _decision("STOP", "SCOPE_NOT_AUTHORIZED", "BLOCKED")
    if s.other_active_tasks:
        return _decision("STOP", "SINGLE_TASK_LIMIT", "BLOCKED")

    if s.state == "BLOCKED":
        return _decision("OWNER_REVIEW", "EXISTING_BLOCKER", "BLOCKED", True)
    if s.state == "OWNER_DECISION":
        return _decision("OWNER_REVIEW", "AWAIT_EXPLICIT_OWNER_GO", "OWNER_DECISION", True)

    if s.state == "READY":
        if s.checkout_sha != s.base_sha:
            return _decision("STOP", "STALE_BASE_SHA", "BLOCKED")
        if not s.transport_ready:
            return _decision("STOP", "TRANSPORT_NOT_PROVEN", "BLOCKED")
        if not s.executor_ready:
            return _decision("STOP", "EXECUTOR_NOT_PROVEN", "BLOCKED")
        if not s.executor_authorized:
            return _decision("OWNER_REVIEW", "EXECUTOR_GO_REQUIRED", "READY", True)
        if not s.quota_verified:
            return _decision("STOP", "COST_NOT_VERIFIED", "BLOCKED")
        if s.model_calls_remaining < 1:
            return _decision("STOP", "BUDGET_EXHAUSTED", "BLOCKED")
        return _decision("PLAN_DISPATCH", "ONE_APPROVED_EXECUTOR_ONLY", "CLAIMED")

    if s.state in ("CLAIMED", "RUNNING"):
        if s.elapsed_seconds >= s.timeout_seconds:
            return _decision("STOP", "EXECUTOR_TIMEOUT_UNCERTAIN", "BLOCKED")
        return _decision("WAIT", "EXECUTOR_IN_PROGRESS", s.state)

    if s.state == "REVIEW_READY":
        # Assertions from LLM output alone are not independently verified CI.
        if s.ci_status == "NOT_CHECKED" or s.ci_status == "PENDING":
            return _decision("WAIT", "CI_NOT_READY", "REVIEW_READY")
        if not s.ci_verified or not s.ci_head_sha or not s.ci_run_url:
            return _decision("STOP", "CI_PROVENANCE_MISSING", "BLOCKED")
        if s.ci_head_sha != s.head_sha:
            return _decision("STOP", "CI_HEAD_SHA_MISMATCH", "BLOCKED")
        if s.ci_status == "ERROR":
            return _decision("STOP", "CI_ERROR_UNCERTAIN", "BLOCKED")
        if s.ci_status == "FAILURE":
            if not s.ci_failure_fixable:
                return _decision("OWNER_REVIEW", "CI_FAILURE_NOT_CLASSIFIED_FIXABLE",
                                 "BLOCKED", True)
            if not s.failure_signature:
                return _decision("STOP", "CI_FAILURE_SIGNATURE_MISSING", "BLOCKED")
            if s.reworks_done >= MAX_REWORKS:
                return _decision("OWNER_REVIEW", "REWORK_LIMIT", "BLOCKED", True)
            if (s.reworks_done >= 1 and s.previous_failure_signature
                    == s.failure_signature):
                return _decision("OWNER_REVIEW", "REPEATED_CI_FAILURE", "BLOCKED", True)
            if not s.quota_verified or s.model_calls_remaining < 1:
                return _decision("OWNER_REVIEW", "REWORK_BUDGET_NOT_AVAILABLE",
                                 "BLOCKED", True)
            if not s.executor_ready or not s.executor_authorized:
                return _decision("OWNER_REVIEW", "EXECUTOR_NOT_AUTHORIZED_FOR_REWORK",
                                 "BLOCKED", True)
            return _decision("PLAN_REWORK", "FIXABLE_CI_FAILURE_WITH_BOUNDED_RETRY",
                             "CLAIMED")
        # Shell CI SUCCESS alone is insufficient: require the separately
        # proven Native E2E run and its gate artifact for the SAME PR head.
        if s.native_e2e_status in ("NOT_CHECKED", "PENDING"):
            return _decision("WAIT", "NATIVE_E2E_NOT_READY", "REVIEW_READY")
        if (not s.native_e2e_verified or not s.native_e2e_head_sha
                or not s.native_e2e_run_url):
            return _decision("STOP", "NATIVE_E2E_PROVENANCE_MISSING", "BLOCKED")
        if s.native_e2e_head_sha != s.head_sha:
            return _decision("STOP", "NATIVE_E2E_HEAD_SHA_MISMATCH", "BLOCKED")
        if s.native_e2e_status == "ERROR":
            return _decision("STOP", "NATIVE_E2E_ERROR_UNCERTAIN", "BLOCKED")
        if s.native_e2e_status == "FAILURE":
            return _decision("OWNER_REVIEW", "NATIVE_E2E_FAILED", "BLOCKED", True)
        # The workflow may be green while its gates.json outcome is BLOCKED;
        # report this honestly, never convert it to an unqualified PASS.
        if not s.native_gates_verified:
            return _decision("STOP", "NATIVE_GATES_PROVENANCE_MISSING", "BLOCKED")
        if s.native_gates_outcome == "FAIL":
            return _decision("OWNER_REVIEW", "NATIVE_GATES_FAILED", "BLOCKED", True)
        if s.native_gates_outcome == "BLOCKED":
            return _decision("OWNER_REVIEW", "NATIVE_GATES_BLOCKED", "BLOCKED", True)
        if s.native_gates_outcome != "PASS":
            return _decision("STOP", "NATIVE_GATES_NOT_PROVEN", "BLOCKED")
        # Proven CI+E2E/gates success still is not FIELD PASS or merge authority.
        if not s.review_verified or s.review_status == "NOT_CHECKED":
            return _decision("WAIT", "REVIEW_NOT_VERIFIED", "REVIEW_READY")
        if s.review_status in ("BLOCKED", "CHANGES_REQUESTED"):
            return _decision("OWNER_REVIEW", "REVIEW_BLOCKER", "BLOCKED", True)
        return _decision("OWNER_REVIEW", "REVIEW_READY_OWNER_MERGE_GO_REQUIRED",
                         "OWNER_DECISION", True)

    # Only listed states are allowed; this fallback must never propose work.
    return _decision("STOP", "UNREACHABLE_STATE", "BLOCKED")
