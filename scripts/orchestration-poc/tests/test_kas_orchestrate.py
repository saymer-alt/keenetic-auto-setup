#!/usr/bin/env python3
"""Tests for the KAS orchestration POC (issue #430).

Pure stdlib; the GitHub backend is a scripted fake — no network, no gh, no
LLM calls. Run from the repo root:

    python -m unittest discover -s scripts/orchestration-poc/tests -v
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

POC_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(POC_DIR))

import kas_orchestrate as ko  # noqa: E402

ISSUE_JSON = {
    "number": 430,
    "title": "Agent Orchestration (reuse-first)",
    "state": "OPEN",
    "body": "Owner must not be the copy-paste proxy between ChatGPT and ZCode.",
    "url": "https://github.com/saymer-alt/keenetic-auto-setup/issues/430",
    "updatedAt": "2026-11-07T18:16:17Z",
    "labels": [],
    "author": {"login": "saymer-alt"},
}

SHA = "db36be0d3bfc0408fd8a98793fd83f26450c9bc2"


class FakeRunner:
    """Scripted stand-in for subprocess.run; returns queued responses."""

    def __init__(self) -> None:
        self.calls: list[list[str]] = []
        self.queue: list[subprocess.CompletedProcess[str]] = []

    def push(self, stdout: str, returncode: int = 0, stderr: str = "") -> None:
        self.queue.append(subprocess.CompletedProcess([], returncode, stdout, stderr))

    def __call__(self, cmd, capture_output=True, text=True, timeout=None, cwd=None, **kwargs):
        self.calls.append(cmd)
        if not self.queue:  # fail closed on unexpected calls
            raise AssertionError(f"unexpected subprocess call: {cmd}")
        return self.queue.pop(0)

    # -- helpers -----------------------------------------------------------
    def push_gh_issue(self, issue: dict | None = None) -> None:
        body = json.dumps(issue if issue is not None else ISSUE_JSON)
        self.push(body)

    def push_auth_ok(self) -> None:
        self.push("github.com\n  Logged in to github.com account saymer-alt")

    def push_git_sha(self, sha: str = SHA) -> None:
        self.push(sha + "\n")


def make_store(tmp: Path) -> ko.TaskStore:
    return ko.TaskStore(tmp / "state")


def do_fetch(runner: FakeRunner, store: ko.TaskStore, issue: int = 430) -> dict:
    runner.push_auth_ok()
    runner.push_gh_issue()
    runner.push_git_sha()
    task = {
        "cmd": "fetch", "repo": ko.DEFAULT_REPO, "issue": issue,
        "repo_path": str(POC_DIR), "state_dir": str(store.dir), "json": False,
    }
    args = ko.parser_namespace(task)
    return ko.cmd_fetch(args, ko.GhRunner(runner), store, POC_DIR)


class FetchTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="kas-orch-test-"))
        self.store = make_store(self.tmp)
        self.runner = FakeRunner()

    def test_fetch_happy_path(self) -> None:
        res = do_fetch(self.runner, self.store)
        self.assertEqual(res["state"], "READY")
        self.assertTrue(res["task_id"].startswith("issue-430-db36be0"))
        contract = json.loads(self.store.contract_file.read_text(encoding="utf-8"))
        for field in ("task_id", "issue", "repo", "base_sha", "intent",
                      "DoD", "required_gates", "stop_conditions", "status"):
            self.assertIn(field, contract)
        handoff = self.store.handoff_file.read_text(encoding="utf-8")
        self.assertIn("gh issue view 430 --repo saymer-alt/keenetic-auto-setup", handoff)

    def test_fetch_closed_issue_stops(self) -> None:
        self.runner.push_auth_ok()
        self.runner.push_gh_issue({**ISSUE_JSON, "state": "CLOSED"})
        with self.assertRaises(ko.Stop) as cm:
            do_fetch(self.runner, self.store)
        self.assertEqual(cm.exception.code, "ISSUE_CLOSED")

    def test_fetch_no_auth_stops(self) -> None:
        self.runner.push("gh: not logged in", returncode=1)
        with self.assertRaises(ko.Stop) as cm:
            do_fetch(self.runner, self.store)
        self.assertEqual(cm.exception.code, "NO_AUTH")

    def test_fetch_network_error_stops(self) -> None:
        self.runner.push_auth_ok()
        self.runner.push("", returncode=1, stderr="dial tcp: connection refused")
        with self.assertRaises(ko.Stop) as cm:
            do_fetch(self.runner, self.store)
        self.assertEqual(cm.exception.code, "NETWORK")

    def test_fetch_oversize_body_truncates(self) -> None:
        big = {**ISSUE_JSON, "body": "x" * (ko.MAX_ISSUE_BODY + 100)}
        self.runner.push_auth_ok()
        self.runner.push_gh_issue(big)
        self.runner.push_git_sha()
        res = do_fetch(self.runner, self.store)
        self.assertTrue(res["body_truncated"])
        self.assertIn("KAS-ORCH: body truncated", json.loads(
            self.store.contract_file.read_text(encoding="utf-8"))["intent_excerpt"])

    def test_fetch_rejects_active_task(self) -> None:
        do_fetch(self.runner, self.store)
        self.runner.queue.clear()
        self.runner.push_auth_ok()
        self.runner.push_gh_issue()
        with self.assertRaises(ko.Stop) as cm:
            do_fetch(self.runner, self.store)
        self.assertEqual(cm.exception.code, "ACTIVE_TASK")

    def test_owner_allowlist(self) -> None:
        with self.assertRaises(ko.Stop) as cm:
            ko.guard_repo("evil-org/keenetic-auto-setup")
        self.assertEqual(cm.exception.code, "BAD_REPO")


class DispatchTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="kas-orch-test-"))
        self.store = make_store(self.tmp)
        self.runner = FakeRunner()
        self.task = {
            "cmd": "dispatch", "repo": ko.DEFAULT_REPO, "executor": "dry-run",
            "repo_path": str(POC_DIR), "state_dir": str(self.store.dir),
            "json": False, "zcode_cli": None, "zcode_electron": None,
        }

    def test_dry_run_never_yolo(self) -> None:
        self.runner.push_auth_ok()
        self.runner.push_gh_issue()
        self.runner.push_git_sha()
        do_fetch(self.runner, self.store)
        args = ko.parser_namespace(self.task)
        res = ko.cmd_dispatch(args, ko.GhRunner(self.runner), self.store, POC_DIR)
        cmd_line = res["output"]
        self.assertIn("--mode plan", cmd_line)
        self.assertNotIn("yolo", cmd_line.lower())
        self.assertEqual(self.store.load()["state"], "RUNNING")

    def test_duplicate_dispatch_stops(self) -> None:
        self.runner.push_auth_ok()
        self.runner.push_gh_issue()
        self.runner.push_git_sha()
        do_fetch(self.runner, self.store)
        args = ko.parser_namespace(self.task)
        ko.cmd_dispatch(args, ko.GhRunner(self.runner), self.store, POC_DIR)
        with self.assertRaises(ko.Stop) as cm:
            ko.cmd_dispatch(args, ko.GhRunner(self.runner), self.store, POC_DIR)
        self.assertEqual(cm.exception.code, "DUPLICATE")

    def test_mock_executor_reaches_review_ready(self) -> None:
        self.runner.push_auth_ok()
        self.runner.push_gh_issue()
        self.runner.push_git_sha()
        do_fetch(self.runner, self.store)
        self.task["executor"] = "mock"
        args = ko.parser_namespace(self.task)
        res = ko.cmd_dispatch(args, ko.GhRunner(self.runner), self.store, POC_DIR)
        self.assertEqual(res["state"], "REVIEW_READY")
        journal = self.store.journal.read_text(encoding="utf-8").splitlines()
        states = [json.loads(line)["to"] for line in journal]
        self.assertEqual(states[:4], ["READY", "CLAIMED", "RUNNING", "REVIEW_READY"])

    def test_zcode_cli_missing_binary_stops(self) -> None:
        self.runner.push_auth_ok()
        self.runner.push_gh_issue()
        self.runner.push_git_sha()
        do_fetch(self.runner, self.store)
        self.task["executor"] = "zcode-cli"
        self.task["zcode_cli"] = str(self.tmp / "no-such-zcode.cjs")
        args = ko.parser_namespace(self.task)
        with self.assertRaises(ko.Stop) as cm:
            ko.cmd_dispatch(args, ko.GhRunner(self.runner), self.store, POC_DIR)
        self.assertEqual(cm.exception.code, "EXECUTOR_MISSING")

    def test_guard_only_plan_mode_allowed(self) -> None:
        self.assertEqual(ko.PLAN_MODE, "plan")
        self.assertIn("yolo", ko.FORBIDDEN_MODES)


class CheckpointTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="kas-orch-test-"))
        self.store = make_store(self.tmp)
        self.runner = FakeRunner()
        do_fetch(self.runner, self.store)

    def test_checkpoint_local_fields(self) -> None:
        args = ko.parser_namespace({
            "cmd": "checkpoint", "repo": ko.DEFAULT_REPO,
            "status": "NOT_TESTED", "evidence": ["https://example.test/ev1"],
            "blocker": "no verified executor path yet", "next_decision": "owner GO for dispatch",
            "head_sha": "", "post": False, "confirm": False,
            "state_dir": str(self.store.dir), "json": False,
        })
        res = ko.cmd_checkpoint(args, ko.GhRunner(self.runner), self.store)
        self.assertFalse(res["posted"])
        md = self.store.checkpoint_file.read_text(encoding="utf-8")
        rendered = {"base_sha": "base SHA", "head_sha": "head SHA",
                    "next_owner_decision": "next owner decision"}
        for field in ko.CHECKPOINT_FIELDS:
            self.assertIn(rendered.get(field, field), md)
        self.assertIn("NOT_TESTED", md)
        self.assertIn("https://example.test/ev1", md)

    def test_checkpoint_post_refused_without_optin(self) -> None:
        self.calls_before_checkpoint = len(self.runner.calls)
        args = ko.parser_namespace({
            "cmd": "checkpoint", "repo": ko.DEFAULT_REPO,
            "status": "NOT_TESTED", "evidence": [], "blocker": "",
            "next_decision": "", "head_sha": "", "post": True, "confirm": False,
            "state_dir": str(self.store.dir), "json": False,
        })
        with self.assertRaises(ko.Stop) as cm:
            ko.cmd_checkpoint(args, ko.GhRunner(self.runner), self.store)
        self.assertEqual(cm.exception.code, "WRITE_NOT_ALLOWED")
        # no GitHub call was attempted during cmd_checkpoint itself
        self.assertEqual(len(self.runner.calls), self.calls_before_checkpoint)

    def test_checkpoint_sets_owner_decision_on_pass(self) -> None:
        args = ko.parser_namespace({
            "cmd": "checkpoint", "repo": ko.DEFAULT_REPO,
            "status": "PASS", "evidence": [], "blocker": "",
            "next_decision": "review", "head_sha": "", "post": False,
            "confirm": False, "state_dir": str(self.store.dir), "json": False,
        })
        ko.cmd_checkpoint(args, ko.GhRunner(self.runner), self.store)
        self.assertEqual(self.store.load()["state"], "OWNER_DECISION")


class StopContractTests(unittest.TestCase):
    def test_stale_sha_detection_helper(self) -> None:
        # current_sha must go through git and return the exact SHA.
        runner = FakeRunner()
        runner.push_git_sha("0" * 40)
        sha = ko.current_sha(ko.GhRunner(runner), POC_DIR)
        self.assertEqual(sha, "0" * 40)

    def test_statuses_and_states_are_the_contract_ones(self) -> None:
        self.assertEqual(ko.STATUSES, ("PASS", "FAIL", "BLOCKED", "NOT_TESTED"))
        self.assertEqual(set(ko.TASK_STATES),
                         {"READY", "CLAIMED", "RUNNING", "REVIEW_READY", "BLOCKED",
                          "OWNER_DECISION"})


if __name__ == "__main__":
    unittest.main()
