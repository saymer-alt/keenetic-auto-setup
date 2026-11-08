#!/usr/bin/env python3
"""Offline C0 policy contract tests — no subprocess/network/model calls."""
from __future__ import annotations

import sys
import unittest
from dataclasses import replace
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import coordinator_policy as cp  # noqa: E402


BASE = "a" * 40
HEAD = "b" * 40
RUN = "1" * 32
CI_URL = "https://github.com/saymer-alt/keenetic-auto-setup/actions/runs/42479954768"


def ready(**kw) -> cp.Observation:
    fields = {
        "repo": cp.REPO, "issue": 456,
        "task_id": "issue-456-" + BASE[:12],
        "run_id": RUN, "base_sha": BASE,
        "head_sha": HEAD, "checkout_sha": BASE,
        "state": "READY",
        "kill_switch": False,
        "issue_open": True,
        "issue_fresh": True,
        "scope_allowed": True,
        "transport_ready": True,
        "executor_ready": True,
        "executor_authorized": True,
        "quota_verified": True,
        "model_calls_remaining": 1,
    }
    fields.update(kw)
    return cp.Observation(**fields)


def verified_ci(**kw) -> cp.Observation:
    defaults = {
        "state": "REVIEW_READY",
        "ci_status": "SUCCESS",
        "ci_verified": True,
        "ci_head_sha": HEAD,
        "ci_run_url": CI_URL,
        "review_status": "APPROVED",
        "review_verified": True,
    }
    defaults.update(kw)
    return ready(**defaults)


class C0PolicyTests(unittest.TestCase):
    def assert_decision(self, observation, action, reason):
        decision = cp.decide(observation)
        self.assertEqual((decision.action, decision.reason), (action, reason))
        self.assertEqual(decision.source, "C0_OFFLINE_UNVERIFIED")
        return decision

    def test_default_constructor_is_fail_closed(self):
        self.assert_decision(cp.Observation(), "STOP", "BAD_OBSERVATION")

    def test_kill_switch_blocks_even_ready_task(self):
        self.assert_decision(ready(kill_switch=True), "STOP", "KILL_SWITCH")

    def test_closed_issue_blocks(self):
        self.assert_decision(ready(issue_open=False), "STOP", "ISSUE_NOT_OPEN")

    def test_edited_issue_blocks(self):
        self.assert_decision(ready(issue_fresh=False), "STOP", "ISSUE_CHANGED")

    def test_scope_not_authorized_blocks(self):
        self.assert_decision(ready(scope_allowed=False), "STOP", "SCOPE_NOT_AUTHORIZED")

    def test_other_active_task_blocks(self):
        self.assert_decision(ready(other_active_tasks=1), "STOP", "SINGLE_TASK_LIMIT")

    def test_ready_old_checkout_fails(self):
        self.assert_decision(ready(checkout_sha=HEAD), "STOP", "STALE_BASE_SHA")

    def test_transport_not_proven_fails(self):
        self.assert_decision(ready(transport_ready=False), "STOP", "TRANSPORT_NOT_PROVEN")

    def test_executor_not_proven_fails(self):
        self.assert_decision(ready(executor_ready=False), "STOP", "EXECUTOR_NOT_PROVEN")

    def test_no_executor_go_requires_owner(self):
        result = self.assert_decision(ready(executor_authorized=False),
                                      "OWNER_REVIEW", "EXECUTOR_GO_REQUIRED")
        self.assertTrue(result.owner_decision_required)
        self.assertEqual(result.proposed_state, "READY")

    def test_unknown_quota_fails(self):
        self.assert_decision(ready(quota_verified=False), "STOP", "COST_NOT_VERIFIED")

    def test_exhausted_quota_fails(self):
        self.assert_decision(ready(model_calls_remaining=0), "STOP", "BUDGET_EXHAUSTED")

    def test_ready_plans_one_dispatch_without_running_it(self):
        result = self.assert_decision(ready(), "PLAN_DISPATCH", "ONE_APPROVED_EXECUTOR_ONLY")
        self.assertEqual(result.proposed_state, "CLAIMED")
        self.assertFalse(result.owner_decision_required)

    def test_running_waits_without_retrying(self):
        self.assert_decision(ready(state="RUNNING", elapsed_seconds=29),
                             "WAIT", "EXECUTOR_IN_PROGRESS")

    def test_claimed_waits_without_retrying(self):
        self.assert_decision(ready(state="CLAIMED"), "WAIT", "EXECUTOR_IN_PROGRESS")

    def test_executor_timeout_blocks_no_automatic_retry(self):
        self.assert_decision(ready(state="RUNNING", elapsed_seconds=3600),
                             "STOP", "EXECUTOR_TIMEOUT_UNCERTAIN")

    def test_blocked_task_requires_owner(self):
        result = self.assert_decision(ready(state="BLOCKED"), "OWNER_REVIEW",
                                      "EXISTING_BLOCKER")
        self.assertTrue(result.owner_decision_required)

    def test_owner_decision_state_has_no_automatic_merge(self):
        result = self.assert_decision(ready(state="OWNER_DECISION"), "OWNER_REVIEW",
                                      "AWAIT_EXPLICIT_OWNER_GO")
        self.assertEqual(result.proposed_state, "OWNER_DECISION")

    def test_unchecked_ci_waits(self):
        self.assert_decision(ready(state="REVIEW_READY"), "WAIT", "CI_NOT_READY")

    def test_pending_ci_waits(self):
        self.assert_decision(verified_ci(ci_status="PENDING"), "WAIT", "CI_NOT_READY")

    def test_unverified_ci_claim_stops_even_if_success(self):
        self.assert_decision(verified_ci(ci_verified=False), "STOP",
                             "CI_PROVENANCE_MISSING")

    def test_ci_missing_run_link_stops(self):
        self.assert_decision(verified_ci(ci_run_url=""), "STOP",
                             "CI_PROVENANCE_MISSING")

    def test_ci_sha_mismatch_stops(self):
        self.assert_decision(verified_ci(ci_head_sha=BASE), "STOP",
                             "CI_HEAD_SHA_MISMATCH")

    def test_ci_error_is_not_retriable(self):
        self.assert_decision(verified_ci(ci_status="ERROR"), "STOP",
                             "CI_ERROR_UNCERTAIN")

    def test_ci_success_pending_review_waits(self):
        self.assert_decision(verified_ci(review_verified=False), "WAIT",
                             "REVIEW_NOT_VERIFIED")

    def test_ci_success_verified_approved_requests_owner_go(self):
        decision = self.assert_decision(verified_ci(), "OWNER_REVIEW",
                                        "REVIEW_READY_OWNER_MERGE_GO_REQUIRED")
        self.assertEqual(decision.proposed_state, "OWNER_DECISION")
        self.assertTrue(decision.owner_decision_required)

    def test_review_changes_requested_refuses_auto_merge(self):
        self.assert_decision(verified_ci(review_status="CHANGES_REQUESTED"),
                             "OWNER_REVIEW", "REVIEW_BLOCKER")

    def test_fixable_ci_failure_plans_one_rework(self):
        x = verified_ci(ci_status="FAILURE", ci_failure_fixable=True,
                        failure_signature="unit-python-42")
        d = self.assert_decision(x, "PLAN_REWORK",
                                  "FIXABLE_CI_FAILURE_WITH_BOUNDED_RETRY")
        self.assertEqual(d.proposed_state, "CLAIMED")

    def test_unclassified_ci_failure_needs_owner(self):
        self.assert_decision(verified_ci(ci_status="FAILURE"),
                             "OWNER_REVIEW", "CI_FAILURE_NOT_CLASSIFIED_FIXABLE")

    def test_ci_failure_missing_signature_blocks(self):
        self.assert_decision(verified_ci(ci_status="FAILURE",
                                         ci_failure_fixable=True),
                             "STOP", "CI_FAILURE_SIGNATURE_MISSING")

    def test_same_failure_after_one_rework_blocks(self):
        self.assert_decision(verified_ci(ci_status="FAILURE", ci_failure_fixable=True,
                                         failure_signature="unit-42",
                                         previous_failure_signature="unit-42",
                                         reworks_done=1),
                             "OWNER_REVIEW", "REPEATED_CI_FAILURE")

    def test_different_failure_allows_second_rework(self):
        self.assert_decision(verified_ci(ci_status="FAILURE", ci_failure_fixable=True,
                                         failure_signature="unit-43",
                                         previous_failure_signature="unit-42",
                                         reworks_done=1),
                             "PLAN_REWORK", "FIXABLE_CI_FAILURE_WITH_BOUNDED_RETRY")

    def test_two_reworks_exhausted(self):
        self.assert_decision(verified_ci(ci_status="FAILURE", ci_failure_fixable=True,
                                         failure_signature="unit-43", reworks_done=2),
                             "OWNER_REVIEW", "REWORK_LIMIT")

    def test_rework_budget_unavailable_blocks(self):
        self.assert_decision(verified_ci(ci_status="FAILURE", ci_failure_fixable=True,
                                         failure_signature="unit-43",
                                         model_calls_remaining=0),
                             "OWNER_REVIEW", "REWORK_BUDGET_NOT_AVAILABLE")

    def test_rework_requires_authorized_executor(self):
        self.assert_decision(verified_ci(ci_status="FAILURE", ci_failure_fixable=True,
                                         failure_signature="unit-43",
                                         executor_authorized=False),
                             "OWNER_REVIEW", "EXECUTOR_NOT_AUTHORIZED_FOR_REWORK")

    def test_wrong_repo_or_task_identity_stops(self):
        for x in (ready(repo="other/repo"),
                  ready(task_id="issue-999-aaaaaaaaaaaa"),
                  ready(run_id="not-a-run"), ready(base_sha="abc")):
            with self.subTest(x=x):
                self.assert_decision(x, "STOP", "BAD_OBSERVATION")

    def test_bool_disguised_as_integer_stops(self):
        for x in (ready(issue=True), ready(other_active_tasks=False),
                  ready(model_calls_remaining=True), ready(reworks_done=False)):
            with self.subTest(x=x):
                self.assert_decision(x, "STOP", "BAD_OBSERVATION")

    def test_invalid_ci_link_or_malformed_sha_stops(self):
        for x in (verified_ci(ci_run_url="https://github.com/other/repo/actions/runs/12"),
                  verified_ci(ci_run_url=CI_URL + "?token=1"),
                  verified_ci(ci_head_sha="z"*40)):
            with self.subTest(x=x):
                self.assert_decision(x, "STOP", "BAD_OBSERVATION")

    def test_bad_failure_signature_refused(self):
        self.assert_decision(verified_ci(failure_signature="line\nnew"),
                             "STOP", "BAD_OBSERVATION")

    def test_invalid_states_stop(self):
        for x in (ready(state="MERGED"), ready(ci_status="PASS"),
                  ready(review_status="GREEN"), ready(reworks_done=3)):
            with self.subTest(x=x):
                self.assert_decision(x, "STOP", "BAD_OBSERVATION")

    def test_output_is_bounded_nonexecuting_contract(self):
        o = cp.decide(verified_ci()).as_dict()
        self.assertEqual(o["schema"], "kas-coordinator-policy-c0/1")
        self.assertEqual(o["source"], "C0_OFFLINE_UNVERIFIED")
        self.assertNotIn("command", o)
        self.assertNotIn("shell", o)
        self.assertNotIn("merge", o)


if __name__ == "__main__":
    unittest.main()
