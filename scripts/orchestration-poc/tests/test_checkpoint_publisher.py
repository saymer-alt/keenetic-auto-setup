#!/usr/bin/env python3
"""Mock-only tests for the P1-A checkpoint publication adapter (#454)."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import checkpoint_publisher as cp  # noqa: E402

SHA = "db36be0d3bfc0408fd8a98793fd83f26450c9bc2"
RUN = "1" * 32
NUMBER = 454
TITLE = "P1: no-token GitHub checkpoint publisher"
UPDATED = "2026-11-08T11:52:24Z"
ISSUE_URL = f"https://github.com/{cp.REPO}/issues/{NUMBER}"


def task() -> dict:
    return {
        "repo": cp.REPO, "issue": NUMBER, "issue_url": ISSUE_URL,
        "issue_updated_at": UPDATED, "intent": TITLE,
        "task_id": f"issue-{NUMBER}-{SHA[:12]}", "run_id": RUN,
        "base_sha": SHA,
    }


def plan(**kwargs) -> cp.PublishPlan:
    values = {
        "status": "BLOCKED",
        "blocker": "executor unavailable",
        "next_owner_decision": "review provider",
        "evidence": [f"https://github.com/{cp.REPO}/actions/runs/42462990571"],
    }
    values.update(kwargs)
    return cp.prepare(task(), **values)


class FakeTransport:
    def __init__(self) -> None:
        self.user = "saymer-alt"
        self.head = SHA
        self.issued = {
            "number": NUMBER, "url": ISSUE_URL, "state": "OPEN",
            "updatedAt": UPDATED, "title": TITLE,
        }
        self.comments: list[dict] = []
        self.complete = True
        self.calls = []
        self.fail_post = False
        self.drop_post = False
        self.fail_verify = False
        self.change_issue_at = 0
        self.change_comments_at = 0
        self.issue_reads = 0
        self.comment_reads = 0

    def account(self):
        self.calls.append("account")
        return self.user

    def issue(self, repo, number):
        self.calls.append("issue")
        self.issue_reads += 1
        result = dict(self.issued)
        if self.change_issue_at == self.issue_reads:
            result["updatedAt"] = "newer"
        return result

    def checkout_head(self):
        self.calls.append("head")
        return self.head

    def list_comments(self, repo, number):
        self.calls.append("comments")
        self.comment_reads += 1
        if self.fail_verify and self.comment_reads >= 3:
            return {"complete": False, "items": []}
        items = list(self.comments)
        if self.change_comments_at == self.comment_reads:
            items.append({"body": "another user posted"})
        return {"complete": self.complete, "items": items}

    def post_comment(self, repo, number, body):
        self.calls.append("post")
        if self.fail_post:
            raise OSError("timed out after attempting a write")
        if not self.drop_post:
            self.comments.append({"body": body})


class PublisherTests(unittest.TestCase):
    def setUp(self) -> None:
        self.backend = FakeTransport()
        self.plan = plan()

    def assert_stop(self, code: str, fn) -> None:
        with self.assertRaises(cp.PublisherStop) as caught:
            fn()
        self.assertEqual(caught.exception.code, code)
        self.assertNotIn("post", self.backend.calls)

    def test_happy_mock_post_with_independent_verification(self):
        out = cp.publish_mock(self.backend, self.plan, allow_mock_write=True)
        self.assertEqual(out["post_status"], "posted_confirmed_mock")
        self.assertEqual(self.backend.calls.count("post"), 1)
        self.assertEqual(self.backend.comments[0]["body"], self.plan.body)
        self.assertIn("UNVERIFIED", self.plan.body)

    def test_disabled_by_default(self):
        self.assert_stop("WRITE_DISABLED", lambda: cp.publish_mock(self.backend, self.plan))
        self.assertEqual(self.backend.calls, [])

    def test_duplicate_no_op(self):
        self.backend.comments.append({"body": self.plan.body})
        out = cp.publish_mock(self.backend, self.plan, allow_mock_write=True)
        self.assertEqual(out, {"post_status": "already_posted", "posted": False})

    def test_same_run_different_content_stops(self):
        self.backend.comments.append({"body": self.plan.marker + "\nother payload"})
        self.assert_stop("DUPLICATE_CONFLICT", lambda: cp.publish_mock(
            self.backend, self.plan, allow_mock_write=True))

    def test_multiple_same_run_comments_stops(self):
        self.backend.comments = [{"body": self.plan.body}, {"body": self.plan.body}]
        self.assert_stop("DUPLICATE_CONFLICT", lambda: cp.publish_mock(
            self.backend, self.plan, allow_mock_write=True))

    def test_wrong_account_stops(self):
        self.backend.user = "someone-else"
        self.assert_stop("BAD_ACCOUNT", lambda: cp.publish_mock(
            self.backend, self.plan, allow_mock_write=True))

    def test_stale_checkout_stops(self):
        self.backend.head = "f" * 40
        self.assert_stop("STALE_SHA", lambda: cp.publish_mock(
            self.backend, self.plan, allow_mock_write=True))

    def test_changed_issue_stops(self):
        self.backend.issued["updatedAt"] = "changed"
        self.assert_stop("ISSUE_CHANGED", lambda: cp.publish_mock(
            self.backend, self.plan, allow_mock_write=True))

    def test_closed_issue_stops(self):
        self.backend.issued["state"] = "CLOSED"
        self.assert_stop("ISSUE_CHANGED", lambda: cp.publish_mock(
            self.backend, self.plan, allow_mock_write=True))

    def test_issue_changes_just_before_write_stops(self):
        self.backend.change_issue_at = 2
        self.assert_stop("ISSUE_CHANGED", lambda: cp.publish_mock(
            self.backend, self.plan, allow_mock_write=True))

    def test_comments_incomplete_stops(self):
        self.backend.complete = False
        self.assert_stop("COMMENTS_INCOMPLETE", lambda: cp.publish_mock(
            self.backend, self.plan, allow_mock_write=True))

    def test_comment_list_changes_before_write_stops(self):
        self.backend.change_comments_at = 2
        self.assert_stop("CONCURRENT_CHANGE", lambda: cp.publish_mock(
            self.backend, self.plan, allow_mock_write=True))

    def test_uncertain_write_does_not_retry(self):
        self.backend.fail_post = True
        with self.assertRaises(cp.PublisherStop) as caught:
            cp.publish_mock(self.backend, self.plan, allow_mock_write=True)
        self.assertEqual(caught.exception.code, "POST_UNCERTAIN")
        self.assertEqual(self.backend.calls.count("post"), 1)

    def test_unconfirmed_write_does_not_claim_success(self):
        self.backend.drop_post = True
        with self.assertRaises(cp.PublisherStop) as caught:
            cp.publish_mock(self.backend, self.plan, allow_mock_write=True)
        self.assertEqual(caught.exception.code, "POST_UNCERTAIN")

    def test_verification_unavailable_does_not_claim_success(self):
        self.backend.fail_verify = True
        with self.assertRaises(cp.PublisherStop) as caught:
            cp.publish_mock(self.backend, self.plan, allow_mock_write=True)
        self.assertEqual(caught.exception.code, "POST_UNCERTAIN")

    def test_pass_claims_refused(self):
        for status in ("PASS", "CI PASS", "FIELD PASS", "FAIL", "REVIEW_READY"):
            with self.subTest(status=status):
                with self.assertRaises(cp.PublisherStop) as caught:
                    plan(status=status)
                self.assertEqual(caught.exception.code, "STATUS_DENIED")

    def test_missing_or_old_run_id_refused(self):
        for run in (None, "", "legacy", "x" * 32):
            with self.subTest(run=run):
                contract = task()
                contract["run_id"] = run
                with self.assertRaises(cp.PublisherStop) as caught:
                    cp.prepare(contract, status="BLOCKED")
                self.assertEqual(caught.exception.code, "BAD_RUN")

    def test_foreign_repo_refused(self):
        contract = task()
        contract["repo"] = "other-owner/repo"
        with self.assertRaises(cp.PublisherStop) as caught:
            cp.prepare(contract, status="BLOCKED")
        self.assertEqual(caught.exception.code, "BAD_REPO")

    def test_head_sha_unverified_refused(self):
        with self.assertRaises(cp.PublisherStop) as caught:
            plan(head_sha="f" * 40)
        self.assertEqual(caught.exception.code, "UNVERIFIED_HEAD")

    def test_secret_and_misleading_claims_refused(self):
        for text in ("Bearer sk-abcd", "api_key=abc", "CI PASS", "FIELD PASS",
                     "-----BEGIN PRIVATE KEY-----", "hello\nworld", "<script>"):
            with self.subTest(text=text):
                with self.assertRaises(cp.PublisherStop):
                    plan(blocker=text)

    def test_untrusted_evidence_rejected(self):
        for url in (
            "https://example.com/proof",
            "https://github.com/other/repo/issues/1",
            "https://github.com/saymer-alt/keenetic-auto-setup/issues/454?token=abcdef",
            "https://user:pass@github.com/saymer-alt/keenetic-auto-setup/issues/454",
            "file:///tmp/sensitive.txt",
            "https://github.com/saymer-alt/keenetic-auto-setup/../../secrets",
        ):
            with self.subTest(url=url):
                with self.assertRaises(cp.PublisherStop) as caught:
                    plan(evidence=[url])
                self.assertEqual(caught.exception.code, "UNSAFE_EVIDENCE")

    def test_payload_excludes_raw_issue_body(self):
        contract = task()
        contract["intent_excerpt"] = "PRIVATE ACCESS TOKEN ABC"
        contract["body"] = "top secret owner transcript"
        result = cp.prepare(contract, status="NOT_TESTED")
        self.assertNotIn("top secret owner transcript", result.body)
        self.assertNotIn("PRIVATE ACCESS TOKEN", result.body)

    def test_overlong_text_rejected(self):
        with self.assertRaises(cp.PublisherStop) as caught:
            plan(blocker="a" * 250)
        self.assertEqual(caught.exception.code, "UNSAFE_FIELD")


if __name__ == "__main__":
    unittest.main()
