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
from unittest.mock import patch
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

    def push_gh_user(self, login: str = "saymer-alt") -> None:
        self.push(json.dumps({"login": login}))

    def push_auth_ok(self) -> None:
        self.push("github.com\n  Logged in to github.com account saymer-alt")

    def push_git_sha(self, sha: str = SHA) -> None:
        self.push(sha + "\n")


def make_store(tmp: Path) -> ko.TaskStore:
    return ko.TaskStore(tmp / "state")


def do_fetch(runner: FakeRunner, store: ko.TaskStore, issue: int = 430) -> dict:
    runner.push_auth_ok()
    runner.push_gh_user()
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
        self.assertEqual(len(res["run_id"]), 32)
        self.assertTrue(all(c in "0123456789abcdef" for c in res["run_id"]))
        contract = json.loads(self.store.contract_file.read_text(encoding="utf-8"))
        for field in ("task_id", "issue", "issue_updated_at", "repo", "base_sha", "intent",
                      "DoD", "required_gates", "stop_conditions", "status"):
            self.assertIn(field, contract)
        handoff = self.store.handoff_file.read_text(encoding="utf-8")
        self.assertIn("gh issue view 430 --repo saymer-alt/keenetic-auto-setup", handoff)
        self.assertIn(f"Run ID: {res['run_id']}", handoff)

    def test_fetch_closed_issue_stops(self) -> None:
        self.runner.push_auth_ok()
        self.runner.push_gh_user()
        self.runner.push_gh_issue({**ISSUE_JSON, "state": "CLOSED"})
        with self.assertRaises(ko.Stop) as cm:
            do_fetch(self.runner, self.store)
        self.assertEqual(cm.exception.code, "ISSUE_CLOSED")

    def test_fetch_no_auth_stops(self) -> None:
        self.runner.push("gh: not logged in", returncode=1)
        with self.assertRaises(ko.Stop) as cm:
            do_fetch(self.runner, self.store)
        self.assertEqual(cm.exception.code, "NO_AUTH")

    def test_fetch_bad_account_stops(self) -> None:
        self.runner.push_auth_ok()
        self.runner.push_gh_user("someone-else")
        with self.assertRaises(ko.Stop) as cm:
            do_fetch(self.runner, self.store)
        self.assertEqual(cm.exception.code, "BAD_ACCOUNT")

    def test_fetch_malformed_issue_stops(self) -> None:
        cases = [
            ("number", {**ISSUE_JSON, "number": "430"}),
            ("title", {**ISSUE_JSON, "title": "   "}),
            ("body", {**ISSUE_JSON, "body": 42}),
            ("url", {**ISSUE_JSON, "url": "https://github.com/other/repo/issues/430"}),
            ("url_prefix", {**ISSUE_JSON, "url": ISSUE_JSON["url"] + "-spoofed"}),
            ("updatedAt", {**ISSUE_JSON, "updatedAt": None}),
        ]
        for name, payload in cases:
            with self.subTest(field=name):
                self.runner.queue.clear()
                self.runner.push_auth_ok()
                self.runner.push_gh_user()
                self.runner.push_gh_issue(payload)
                with self.assertRaises(ko.Stop) as cm:
                    do_fetch(self.runner, self.store)
                self.assertEqual(cm.exception.code, "MALFORMED_ISSUE")

    def test_fetch_network_error_stops(self) -> None:
        self.runner.push_auth_ok()
        self.runner.push_gh_user()
        self.runner.push("", returncode=1, stderr="dial tcp: connection refused")
        with self.assertRaises(ko.Stop) as cm:
            do_fetch(self.runner, self.store)
        self.assertEqual(cm.exception.code, "NETWORK")

    def test_fetch_oversize_body_truncates(self) -> None:
        big = {**ISSUE_JSON, "body": "x" * (ko.MAX_ISSUE_BODY + 100)}
        self.runner.push_auth_ok()
        self.runner.push_gh_user()
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
        self.runner.push_gh_user()
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

    def test_dry_run_never_yolo_and_never_claims_running(self) -> None:
        do_fetch(self.runner, self.store)
        self.runner.push_git_sha()  # guard_stale_sha at dispatch
        args = ko.parser_namespace(self.task)
        res = ko.cmd_dispatch(args, ko.GhRunner(self.runner), self.store, POC_DIR)
        cmd_line = res["output"]
        self.assertIn("--mode plan", cmd_line)
        self.assertIn("ELECTRON_RUN_AS_NODE=1", cmd_line)
        self.assertNotIn("yolo", cmd_line.lower())
        # dry-run executes nothing, so the task must not claim RUNNING
        self.assertEqual(self.store.load()["state"], "READY")

    def test_duplicate_dispatch_stops(self) -> None:
        # dry-run never claims the task; the guard closes a REAL (mock) run
        do_fetch(self.runner, self.store)
        self.runner.push_git_sha()
        self.runner.push_gh_issue()  # live Issue freshness check before real dispatch
        args = ko.parser_namespace({**self.task, "executor": "mock"})
        ko.cmd_dispatch(args, ko.GhRunner(self.runner), self.store, POC_DIR)
        with self.assertRaises(ko.Stop) as cm:
            ko.cmd_dispatch(args, ko.GhRunner(self.runner), self.store, POC_DIR)
        self.assertEqual(cm.exception.code, "DUPLICATE")

    def test_dispatch_stale_sha_stops(self) -> None:
        do_fetch(self.runner, self.store)
        self.runner.push_git_sha("f" * 40)  # checkout moved since fetch
        args = ko.parser_namespace(self.task)
        with self.assertRaises(ko.Stop) as cm:
            ko.cmd_dispatch(args, ko.GhRunner(self.runner), self.store, POC_DIR)
        self.assertEqual(cm.exception.code, "STALE_SHA")
        self.assertEqual(self.store.load()["state"], "READY")

    def test_mock_executor_reaches_review_ready(self) -> None:
        do_fetch(self.runner, self.store)
        self.runner.push_git_sha()
        self.runner.push_gh_issue()  # live Issue freshness check before real dispatch  # guard_stale_sha at dispatch
        self.task["executor"] = "mock"
        args = ko.parser_namespace(self.task)
        res = ko.cmd_dispatch(args, ko.GhRunner(self.runner), self.store, POC_DIR)
        self.assertEqual(res["state"], "REVIEW_READY")
        self.assertEqual(res["exit_code"], 0)
        journal = self.store.journal.read_text(encoding="utf-8").splitlines()
        states = [json.loads(line)["to"] for line in journal]
        self.assertEqual(states[:4], ["READY", "CLAIMED", "RUNNING", "REVIEW_READY"])

    def test_zcode_cli_missing_binary_stops(self) -> None:
        do_fetch(self.runner, self.store)
        self.runner.push_git_sha()
        self.runner.push_gh_issue()  # live Issue freshness check before real dispatch  # guard_stale_sha at dispatch
        self.task["executor"] = "zcode-cli"
        self.task["zcode_cli"] = str(self.tmp / "no-such-zcode.cjs")
        args = ko.parser_namespace(self.task)
        with self.assertRaises(ko.Stop) as cm:
            ko.cmd_dispatch(args, ko.GhRunner(self.runner), self.store, POC_DIR)
        self.assertEqual(cm.exception.code, "EXECUTOR_MISSING")


    def test_dispatch_closed_after_fetch_stops(self) -> None:
        do_fetch(self.runner, self.store)
        self.runner.push_git_sha()
        self.runner.push_gh_issue({**ISSUE_JSON, "state": "CLOSED",
                                   "updatedAt": "2026-11-07T19:00:00Z"})
        args = ko.parser_namespace({**self.task, "executor": "mock"})
        with self.assertRaises(ko.Stop) as cm:
            ko.cmd_dispatch(args, ko.GhRunner(self.runner), self.store, POC_DIR)
        self.assertEqual(cm.exception.code, "ISSUE_CLOSED")
        self.assertEqual(self.store.load()["state"], "READY")

    def test_dispatch_issue_edited_after_fetch_stops(self) -> None:
        do_fetch(self.runner, self.store)
        self.runner.push_git_sha()
        self.runner.push_gh_issue({**ISSUE_JSON, "body": "Owner changed scope",
                                   "updatedAt": "2026-11-07T19:00:00Z"})
        args = ko.parser_namespace({**self.task, "executor": "mock"})
        with self.assertRaises(ko.Stop) as cm:
            ko.cmd_dispatch(args, ko.GhRunner(self.runner), self.store, POC_DIR)
        self.assertEqual(cm.exception.code, "ISSUE_CHANGED")
        self.assertEqual(self.store.load()["state"], "READY")

    def test_zcode_cli_changed_issue_never_launches_process(self) -> None:
        do_fetch(self.runner, self.store)
        self.runner.push_git_sha()
        self.runner.push_gh_issue({**ISSUE_JSON,
                                   "updatedAt": "2026-11-07T20:00:00Z"})
        cli, electron = self.setUp_executor_paths()
        observed = []

        def refuse_launch(cmd, **kwargs):
            observed.append(cmd)
            raise AssertionError("ZCode must not launch on an edited Issue")

        orig = ko.EXEC_RUNNER
        ko.EXEC_RUNNER = refuse_launch
        try:
            args = ko.parser_namespace({**self.task, "executor": "zcode-cli",
                                        "zcode_cli": str(cli), "zcode_electron": str(electron)})
            with self.assertRaises(ko.Stop) as cm:
                ko.cmd_dispatch(args, ko.GhRunner(self.runner), self.store, POC_DIR)
        finally:
            ko.EXEC_RUNNER = orig
        self.assertEqual(cm.exception.code, "ISSUE_CHANGED")
        self.assertFalse(observed, "zcode executor must never be called")
        self.assertEqual(self.store.load()["state"], "READY")

    def test_dispatch_network_error_before_executor_stops(self) -> None:
        do_fetch(self.runner, self.store)
        self.runner.push_git_sha()
        self.runner.push("", returncode=1, stderr="dial tcp: connection refused")
        args = ko.parser_namespace({**self.task, "executor": "mock"})
        with self.assertRaises(ko.Stop) as cm:
            ko.cmd_dispatch(args, ko.GhRunner(self.runner), self.store, POC_DIR)
        self.assertEqual(cm.exception.code, "NETWORK")
        self.assertEqual(self.store.load()["state"], "READY")

    def test_dispatch_wrong_number_from_gh_stops(self) -> None:
        do_fetch(self.runner, self.store)
        self.runner.push_git_sha()
        self.runner.push_gh_issue({**ISSUE_JSON, "number": 431,
                                   "url": "https://github.com/saymer-alt/keenetic-auto-setup/issues/431"})
        args = ko.parser_namespace({**self.task, "executor": "mock"})
        with self.assertRaises(ko.Stop) as cm:
            ko.cmd_dispatch(args, ko.GhRunner(self.runner), self.store, POC_DIR)
        self.assertEqual(cm.exception.code, "MALFORMED_ISSUE")
        self.assertEqual(self.store.load()["state"], "READY")

    def test_dispatch_missing_issue_timestamp_stops(self) -> None:
        do_fetch(self.runner, self.store)
        task = self.store.load()
        task.pop("issue_updated_at")
        self.store.save(task)
        self.runner.push_git_sha()
        args = ko.parser_namespace({**self.task, "executor": "mock"})
        with self.assertRaises(ko.Stop) as cm:
            ko.cmd_dispatch(args, ko.GhRunner(self.runner), self.store, POC_DIR)
        self.assertEqual(cm.exception.code, "STATE_INCOMPLETE")
        self.assertEqual(self.store.load()["state"], "READY")

    def test_guard_only_plan_mode_allowed(self) -> None:
        self.assertEqual(ko.PLAN_MODE, "plan")
        self.assertIn("yolo", ko.FORBIDDEN_MODES)

    def setUp_executor_paths(self) -> tuple[Path, Path]:
        cli = self.tmp / "zcode.cjs"
        electron = self.tmp / "ZCode.exe"
        cli.write_text("// stub", encoding="utf-8")
        electron.write_text("stub", encoding="utf-8")
        return cli, electron

    def test_executor_failure_marks_blocked_no_false_pass(self) -> None:
        do_fetch(self.runner, self.store)
        self.runner.push_git_sha()
        self.runner.push_gh_issue()  # live Issue freshness check before real dispatch
        cli, electron = self.setUp_executor_paths()
        seen: dict[str, object] = {}

        def fake_exec(cmd, **kwargs):
            seen["cmd"] = cmd
            seen["env"] = kwargs.get("env") or {}
            return subprocess.CompletedProcess([], 3, "partial stdout", "model exploded")

        orig = ko.EXEC_RUNNER
        ko.EXEC_RUNNER = fake_exec
        try:
            args = ko.parser_namespace({**self.task, "executor": "zcode-cli",
                                        "zcode_cli": str(cli), "zcode_electron": str(electron)})
            with self.assertRaises(ko.Stop) as cm:
                ko.cmd_dispatch(args, ko.GhRunner(self.runner), self.store, POC_DIR)
        finally:
            ko.EXEC_RUNNER = orig
        self.assertEqual(cm.exception.code, "EXECUTOR_FAILED")
        self.assertIn("3", cm.exception.detail)
        # non-zero exit must never be reported as success
        self.assertEqual(self.store.load()["state"], "BLOCKED")
        self.assertEqual(seen["env"].get("ELECTRON_RUN_AS_NODE"), "1")
        cmd = seen["cmd"]
        self.assertIn("--mode", cmd)
        self.assertEqual(cmd[cmd.index("--mode") + 1], "plan")
        self.assertIn("--json", cmd)

    def test_executor_timeout_marks_blocked(self) -> None:
        do_fetch(self.runner, self.store)
        self.runner.push_git_sha()
        self.runner.push_gh_issue()  # live Issue freshness check before real dispatch
        cli, electron = self.setUp_executor_paths()

        def fake_exec(cmd, **kwargs):
            raise subprocess.TimeoutExpired(cmd, 900)

        orig = ko.EXEC_RUNNER
        ko.EXEC_RUNNER = fake_exec
        try:
            args = ko.parser_namespace({**self.task, "executor": "zcode-cli",
                                        "zcode_cli": str(cli), "zcode_electron": str(electron)})
            with self.assertRaises(ko.Stop) as cm:
                ko.cmd_dispatch(args, ko.GhRunner(self.runner), self.store, POC_DIR)
        finally:
            ko.EXEC_RUNNER = orig
        self.assertEqual(cm.exception.code, "EXECUTOR_TIMEOUT")
        self.assertEqual(self.store.load()["state"], "BLOCKED")


class CheckpointTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="kas-orch-test-"))
        self.store = make_store(self.tmp)
        self.runner = FakeRunner()
        do_fetch(self.runner, self.store)
        self.task = {
            "cmd": "dispatch", "repo": ko.DEFAULT_REPO, "executor": "dry-run",
            "repo_path": str(POC_DIR), "state_dir": str(self.store.dir),
            "json": False, "zcode_cli": None, "zcode_electron": None,
        }

    def test_checkpoint_local_fields(self) -> None:
        self.runner.push_git_sha()  # guard_stale_sha at checkpoint
        args = ko.parser_namespace({
            "cmd": "checkpoint", "repo": ko.DEFAULT_REPO,
            "status": "NOT_TESTED", "evidence": ["https://example.test/ev1"],
            "blocker": "no verified executor path yet", "next_decision": "owner GO for dispatch",
            "head_sha": "", "post": False, "confirm": False,
            "state_dir": str(self.store.dir), "json": False,
        })
        res = ko.cmd_checkpoint(args, ko.GhRunner(self.runner), self.store, POC_DIR)
        self.assertFalse(res["posted"])
        md = self.store.checkpoint_file.read_text(encoding="utf-8")
        rendered = {"base_sha": "base SHA", "head_sha": "head SHA",
                    "next_owner_decision": "next owner decision"}
        for field in ko.CHECKPOINT_FIELDS:
            self.assertIn(rendered.get(field, field), md)
        self.assertIn("NOT_TESTED", md)
        self.assertIn("https://example.test/ev1", md)

    def test_checkpoint_post_refused_without_optin(self) -> None:
        self.runner.push_git_sha()  # guard_stale_sha at checkpoint
        self.calls_before_checkpoint = len(self.runner.calls)
        args = ko.parser_namespace({
            "cmd": "checkpoint", "repo": ko.DEFAULT_REPO,
            "status": "NOT_TESTED", "evidence": [], "blocker": "",
            "next_decision": "", "head_sha": "", "post": True, "confirm": False,
            "state_dir": str(self.store.dir), "json": False,
        })
        with self.assertRaises(ko.Stop) as cm:
            ko.cmd_checkpoint(args, ko.GhRunner(self.runner), self.store, POC_DIR)
        self.assertEqual(cm.exception.code, "WRITE_NOT_ALLOWED")
        # no GitHub call was attempted during cmd_checkpoint itself
        new_calls = self.runner.calls[self.calls_before_checkpoint:]
        self.assertTrue(all(c[0] != "gh" for c in new_calls))

    def test_checkpoint_pass_unearned_from_ready_stops(self) -> None:
        # A bare manual PASS with no executor run must be refused (GO-A2 fix).
        self.runner.push_git_sha()  # guard_stale_sha at checkpoint
        args = ko.parser_namespace({
            "cmd": "checkpoint", "repo": ko.DEFAULT_REPO,
            "status": "PASS", "evidence": [], "blocker": "",
            "next_decision": "review", "head_sha": "", "post": False,
            "confirm": False, "state_dir": str(self.store.dir), "json": False,
        })
        with self.assertRaises(ko.Stop) as cm:
            ko.cmd_checkpoint(args, ko.GhRunner(self.runner), self.store, POC_DIR)
        self.assertEqual(cm.exception.code, "PASS_UNEARNED")
        self.assertEqual(self.store.load()["state"], "READY")
        self.assertFalse(self.store.checkpoint_file.exists())

    def test_checkpoint_pass_after_mock_run_stops(self) -> None:
        # Mock success reaches REVIEW_READY but never earns PASS.
        self.runner.push_git_sha()
        self.runner.push_gh_issue()  # live Issue guard from merged #446
        ko.cmd_dispatch(ko.parser_namespace({
            **self.task, "executor": "mock"}), ko.GhRunner(self.runner), self.store, POC_DIR)
        self.assertEqual(self.store.load()["state"], "REVIEW_READY")
        self.runner.push_git_sha()
        args = ko.parser_namespace({
            "cmd": "checkpoint", "repo": ko.DEFAULT_REPO,
            "status": "PASS", "evidence": [], "blocker": "",
            "next_decision": "review", "head_sha": "", "post": False,
            "confirm": False, "state_dir": str(self.store.dir), "json": False,
        })
        with self.assertRaises(ko.Stop) as cm:
            ko.cmd_checkpoint(args, ko.GhRunner(self.runner), self.store, POC_DIR)
        self.assertEqual(cm.exception.code, "PASS_UNEARNED")
        self.assertEqual(self.store.load()["state"], "REVIEW_READY")

    def test_checkpoint_old_success_same_sha_after_reset_cannot_earn_pass(self) -> None:
        # reset intentionally retains the journal; task_id repeats at same SHA.
        old = self.store.load()
        self.store.transition(old, "REVIEW_READY", "executor:zcode-cli:ok")
        previous_id = old["task_id"]
        previous_run_id = old["run_id"]
        self.store.reset()
        do_fetch(self.runner, self.store)
        self.assertEqual(self.store.load()["task_id"], previous_id)
        self.assertNotEqual(self.store.load()["run_id"], previous_run_id)
        self.runner.push_git_sha()
        self.runner.push_gh_issue()  # #446 freshness guard on new mock dispatch
        ko.cmd_dispatch(ko.parser_namespace({
            **self.task, "executor": "mock"}), ko.GhRunner(self.runner), self.store, POC_DIR)
        self.assertEqual(self.store.load()["state"], "REVIEW_READY")
        self.runner.push_git_sha()
        args = ko.parser_namespace({
            "cmd": "checkpoint", "repo": ko.DEFAULT_REPO,
            "status": "PASS", "evidence": [], "blocker": "",
            "next_decision": "review", "head_sha": "", "post": False,
            "confirm": False, "state_dir": str(self.store.dir), "json": False,
        })
        with self.assertRaises(ko.Stop) as cm:
            ko.cmd_checkpoint(args, ko.GhRunner(self.runner), self.store, POC_DIR)
        self.assertEqual(cm.exception.code, "PASS_UNEARNED")
        self.assertEqual(self.store.load()["state"], "REVIEW_READY")
        self.assertFalse(self.store.checkpoint_file.exists())

    def test_checkpoint_rejects_success_from_other_run_id(self) -> None:
        # Matching task_id and current REVIEW_READY do not authorize a different run.
        task = self.store.load()
        original_run_id = task["run_id"]
        self.store.transition(task, "REVIEW_READY", "executor:zcode-cli:ok")
        task["run_id"] = "f" * 32
        self.store.save(task)
        with self.assertRaises(ko.Stop) as cm:
            ko.guard_earned_pass(self.store, task)
        self.assertEqual(cm.exception.code, "PASS_UNEARNED")
        self.assertNotEqual(original_run_id, task["run_id"])

    def test_checkpoint_rejects_missing_run_id_even_with_old_journal(self) -> None:
        task = self.store.load()
        self.store.transition(task, "REVIEW_READY", "executor:zcode-cli:ok")
        task.pop("run_id")
        self.store.save(task)
        with self.assertRaises(ko.Stop) as cm:
            ko.guard_earned_pass(self.store, task)
        self.assertEqual(cm.exception.code, "PASS_UNEARNED")

    def test_checkpoint_post_optin_cannot_bypass_unearned_pass(self) -> None:
        # Even when write knobs are provided, proof must run before posting.
        self.runner.push_git_sha()
        args = ko.parser_namespace({
            "cmd": "checkpoint", "repo": ko.DEFAULT_REPO,
            "status": "PASS", "evidence": [], "blocker": "",
            "next_decision": "review", "head_sha": "", "post": True,
            "confirm": True, "state_dir": str(self.store.dir), "json": False,
        })
        with patch.dict(ko.os.environ, {"KAS_ORCH_ALLOW_WRITE": "1"}):
            with patch.object(ko, "post_checkpoint",
                              side_effect=AssertionError("no write on unearned PASS")) as writer:
                with self.assertRaises(ko.Stop) as cm:
                    ko.cmd_checkpoint(args, ko.GhRunner(self.runner), self.store, POC_DIR)
                writer.assert_not_called()
        self.assertEqual(cm.exception.code, "PASS_UNEARNED")
        self.assertEqual(self.store.load()["state"], "READY")
        self.assertFalse(self.store.checkpoint_file.exists())

    def test_checkpoint_post_live_gate_closed_even_with_all_optins(self) -> None:
        # Issue #454: the guarded publisher machinery exists, but the live
        # write gate is closed by default (LIVE_POST_ENABLED=False). Triple
        # opt-in alone must not touch the network and must STOP.
        self.runner.push_git_sha()
        args = ko.parser_namespace({
            "cmd": "checkpoint", "repo": ko.DEFAULT_REPO,
            "status": "NOT_TESTED", "evidence": [], "blocker": "",
            "next_decision": "review", "head_sha": "", "post": True,
            "confirm": True, "state_dir": str(self.store.dir), "json": False,
        })
        with patch.dict(ko.os.environ, {"KAS_ORCH_ALLOW_WRITE": "1"}):
            with self.assertRaises(ko.Stop) as cm:
                ko.cmd_checkpoint(args, ko.GhRunner(self.runner), self.store, POC_DIR)
        self.assertEqual(cm.exception.code, "LIVE_POST_NOT_ALLOWED")
        self.assertFalse(ko.LIVE_POST_ENABLED)
        self.assertEqual(self.store.load()["state"], "READY")
        self.assertFalse(self.store.checkpoint_file.exists())
        # No gh call was attempted: only the initial git rev-parse ran.
        self.assertTrue(all(c[0] == "git" for c in self.runner.calls[4:]))
    def test_checkpoint_pass_earned_after_real_executor_ok(self) -> None:
        # A recorded successful zcode-cli run earns PASS (guard stays silent).
        self.runner.push_git_sha()
        self.runner.push_gh_issue()  # live Issue guard from merged #446
        cli, electron = self.tmp / "zcode.cjs", self.tmp / "ZCode.exe"
        cli.write_text("// stub", encoding="utf-8")
        electron.write_text("stub", encoding="utf-8")
        orig = ko.EXEC_RUNNER
        ko.EXEC_RUNNER = lambda cmd, **kw: subprocess.CompletedProcess([], 0, "ok", "")
        try:
            res = ko.cmd_dispatch(ko.parser_namespace({
                **self.task, "executor": "zcode-cli",
                "zcode_cli": str(cli), "zcode_electron": str(electron)}),
                ko.GhRunner(self.runner), self.store, POC_DIR)
        finally:
            ko.EXEC_RUNNER = orig
        self.assertEqual(res["state"], "REVIEW_READY")
        self.runner.push_git_sha()
        args = ko.parser_namespace({
            "cmd": "checkpoint", "repo": ko.DEFAULT_REPO,
            "status": "PASS", "evidence": ["executor output"], "blocker": "",
            "next_decision": "review", "head_sha": "", "post": False,
            "confirm": False, "state_dir": str(self.store.dir), "json": False,
        })
        res = ko.cmd_checkpoint(args, ko.GhRunner(self.runner), self.store, POC_DIR)
        self.assertEqual(res["status"], "PASS")
        self.assertEqual(self.store.load()["state"], "OWNER_DECISION")

    def test_checkpoint_sets_owner_decision_on_fail(self) -> None:
        self.runner.push_git_sha()  # guard_stale_sha at checkpoint
        args = ko.parser_namespace({
            "cmd": "checkpoint", "repo": ko.DEFAULT_REPO,
            "status": "FAIL", "evidence": [], "blocker": "no run yet",
            "next_decision": "review", "head_sha": "", "post": False,
            "confirm": False, "state_dir": str(self.store.dir), "json": False,
        })
        ko.cmd_checkpoint(args, ko.GhRunner(self.runner), self.store, POC_DIR)
        self.assertEqual(self.store.load()["state"], "OWNER_DECISION")

    def test_checkpoint_stale_sha_stops(self) -> None:
        self.runner.push_git_sha("a" * 40)  # checkout moved since fetch
        args = ko.parser_namespace({
            "cmd": "checkpoint", "repo": ko.DEFAULT_REPO,
            "status": "NOT_TESTED", "evidence": [], "blocker": "",
            "next_decision": "", "head_sha": "", "post": False,
            "confirm": False, "state_dir": str(self.store.dir), "json": False,
        })
        with self.assertRaises(ko.Stop) as cm:
            ko.cmd_checkpoint(args, ko.GhRunner(self.runner), self.store, POC_DIR)
        self.assertEqual(cm.exception.code, "STALE_SHA")
        self.assertEqual(self.store.load()["state"], "READY")


class LockTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="kas-orch-test-"))

    def test_lock_mutual_exclusion_and_release(self) -> None:
        lock_path = self.tmp / ".lock"
        with ko.InterprocessLock(lock_path):
            second = ko.InterprocessLock(lock_path)
            with self.assertRaises(ko.Stop) as cm:
                second.acquire()
            self.assertEqual(cm.exception.code, "LOCKED")
        # after release, acquisition works again
        ko.InterprocessLock(lock_path).acquire()

    def test_stale_sha_helper_raises_on_mismatch(self) -> None:
        runner = FakeRunner()
        runner.push_git_sha("b" * 40)
        with self.assertRaises(ko.Stop) as cm:
            ko.guard_stale_sha(ko.GhRunner(runner), POC_DIR, "c" * 40)
        self.assertEqual(cm.exception.code, "STALE_SHA")


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


class MockWriter:
    """Test stand-in for GhCommentWriter; records posts, never touches gh."""

    def __init__(self) -> None:
        self.posted: list[tuple[str, int, str]] = []

    def post(self, repo: str, number: int, body: str) -> dict:
        self.posted.append((repo, number, body))
        return {"post_status": "posted",
                "url": ("https://github.com/saymer-alt/keenetic-auto-setup/"
                        "issues/430#issuecomment-9999")}


class CheckpointPostTests(unittest.TestCase):
    """Issue #454 mock tests: guarded checkpoint publisher, fail-closed."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="kas-orch-post-"))
        self.store = make_store(self.tmp)
        self.runner = FakeRunner()
        do_fetch(self.runner, self.store)
        self.writer = MockWriter()
        self.task = {
            "cmd": "dispatch", "repo": ko.DEFAULT_REPO, "executor": "dry-run",
            "repo_path": str(POC_DIR), "state_dir": str(self.store.dir),
            "json": False, "zcode_cli": None, "zcode_electron": None,
        }

    # -- helpers -----------------------------------------------------------
    def post_args(self, status: str = "NOT_TESTED", evidence: list | None = None,
                  blocker: str = "live post not GOed yet",
                  next_decision: str = "owner GO-B") -> argparse.Namespace:
        return ko.parser_namespace({
            "cmd": "checkpoint", "repo": ko.DEFAULT_REPO,
            "status": status, "evidence": evidence if evidence is not None else
            ["https://example.test/ev"],
            "blocker": blocker, "next_decision": next_decision,
            "head_sha": "", "post": True, "confirm": True,
            "state_dir": str(self.store.dir), "json": False,
        })

    def queue_post_reads(self, comment_pages: list | None = None,
                         issue: dict | None = None) -> None:
        """Queue the reads of the guarded post path in order: sha (initial
        cmd_checkpoint guard), sha (guarded-path re-verify), auth, user,
        issue refetch, comment pages."""
        self.runner.push_git_sha()
        self.runner.push_git_sha()
        self.runner.push_auth_ok()
        self.runner.push_gh_user()
        self.runner.push_gh_issue(issue)
        for page in (comment_pages if comment_pages is not None else [[]]):
            self.runner.push(json.dumps(page))

    def run_post(self, args: argparse.Namespace, live: bool = True):
        gh_runner = ko.GhRunner(self.runner)
        env = {"KAS_ORCH_ALLOW_WRITE": "1"}
        if live:
            with patch.dict(ko.os.environ, env), \
                    patch.object(ko, "LIVE_POST_ENABLED", True):
                return ko.cmd_checkpoint(args, gh_runner, self.store, POC_DIR,
                                         writer=self.writer)
        with patch.dict(ko.os.environ, env):
            return ko.cmd_checkpoint(args, gh_runner, self.store, POC_DIR,
                                     writer=self.writer)

    # -- gate wiring -------------------------------------------------------
    def test_live_gate_closed_by_default_refuses_before_any_call(self) -> None:
        self.runner.push_git_sha()  # initial cmd_checkpoint SHA guard only
        args = self.post_args()
        with patch.dict(ko.os.environ, {"KAS_ORCH_ALLOW_WRITE": "1"}):
            with self.assertRaises(ko.Stop) as cm:
                ko.cmd_checkpoint(args, ko.GhRunner(self.runner), self.store,
                                  POC_DIR, writer=self.writer)
        self.assertEqual(cm.exception.code, "LIVE_POST_NOT_ALLOWED")
        self.assertFalse(ko.LIVE_POST_ENABLED)
        self.assertEqual(self.writer.posted, [])
        self.assertFalse(self.store.checkpoint_file.exists())
        self.assertEqual(self.store.load()["state"], "READY")

    def test_single_mocked_post_success(self) -> None:
        self.queue_post_reads()
        res = self.run_post(self.post_args())
        self.assertEqual(res["post_status"], "posted")
        self.assertTrue(res["posted"])
        self.assertIn("#issuecomment-9999", res["post_url"])
        self.assertEqual(len(self.writer.posted), 1)
        repo, number, body = self.writer.posted[0]
        self.assertEqual(repo, ko.DEFAULT_REPO)
        self.assertEqual(number, 430)
        task = self.store.load()
        marker = ko.checkpoint_marker(task, "NOT_TESTED")
        self.assertIn(marker, body)
        self.assertIn(task["task_id"], body)
        self.assertIn(task["run_id"], body)
        self.assertIn(task["base_sha"], body)
        self.assertIn("unvalidated", body)
        self.assertIn("Not a CI result", body)
        self.assertIn("NOT_TESTED", body)
        self.assertEqual(self.runner.queue, [])  # exact scripted calls only
        self.assertTrue(self.store.checkpoint_file.exists())
        self.assertEqual(self.store.load()["state"], "REVIEW_READY")

    def test_duplicate_marker_returns_already_posted_no_second_comment(self) -> None:
        task = self.store.load()
        marker = ko.checkpoint_marker(task, "NOT_TESTED")
        self.queue_post_reads(comment_pages=[[{"body": "earlier note\n" + marker}]])
        res = self.run_post(self.post_args())
        self.assertEqual(res["post_status"], "already_posted")
        self.assertFalse(res["posted"])
        self.assertEqual(self.writer.posted, [])  # no second comment
        self.assertTrue(self.store.checkpoint_file.exists())
        self.assertEqual(self.store.load()["state"], "REVIEW_READY")

    def test_marker_scan_pagination_finds_marker_on_later_page(self) -> None:
        task = self.store.load()
        marker = ko.checkpoint_marker(task, "NOT_TESTED")
        page1 = [{"body": f"filler comment {i}"} for i in range(100)]
        self.queue_post_reads(comment_pages=[page1, [{"body": marker}]])
        res = self.run_post(self.post_args())
        self.assertEqual(res["post_status"], "already_posted")
        self.assertEqual(self.writer.posted, [])

    def test_no_post_by_default_makes_no_gh_calls(self) -> None:
        self.runner.push_git_sha()
        args = self.post_args()
        args.post = False
        args.confirm = False
        res = ko.cmd_checkpoint(args, ko.GhRunner(self.runner), self.store, POC_DIR)
        self.assertEqual(res["post_status"], "not_requested")
        self.assertFalse(res["posted"])
        self.assertTrue(all(c[0] != "gh" for c in self.runner.calls[4:]))
        self.assertEqual(self.writer.posted, [])

    def test_missing_optin_variants_stop_without_gh_calls(self) -> None:
        cases = [("no_env", {}), ("no_confirm", {"KAS_ORCH_ALLOW_WRITE": "1"})]
        for name, env in cases:
            with self.subTest(case=name):
                self.runner.queue.clear()
                self.runner.push_git_sha()
                args = self.post_args()
                if name == "no_confirm":
                    args.confirm = False
                with patch.dict(ko.os.environ, env):
                    with self.assertRaises(ko.Stop) as cm:
                        ko.cmd_checkpoint(args, ko.GhRunner(self.runner),
                                          self.store, POC_DIR, writer=self.writer)
                self.assertEqual(cm.exception.code, "WRITE_NOT_ALLOWED")
                self.assertEqual(self.writer.posted, [])
                self.assertTrue(all(c[0] == "git" for c in self.runner.calls[4:]))

    # -- pre-write verification ---------------------------------------------
    def test_stale_sha_blocks_before_post_gate(self) -> None:
        self.runner.push_git_sha("a" * 40)  # checkout moved since fetch
        with self.assertRaises(ko.Stop) as cm:
            self.run_post(self.post_args())
        self.assertEqual(cm.exception.code, "STALE_SHA")
        self.assertEqual(self.writer.posted, [])

    def test_edited_issue_at_post_gate_stops_before_writer(self) -> None:
        self.queue_post_reads(issue={**ISSUE_JSON,
                                     "updatedAt": "2026-11-08T12:00:00Z"})
        with self.assertRaises(ko.Stop) as cm:
            self.run_post(self.post_args())
        self.assertEqual(cm.exception.code, "ISSUE_CHANGED")
        self.assertEqual(self.writer.posted, [])
        self.assertFalse(self.store.checkpoint_file.exists())

    def test_closed_issue_at_post_gate_stops_before_writer(self) -> None:
        self.queue_post_reads(issue={**ISSUE_JSON, "state": "CLOSED"})
        with self.assertRaises(ko.Stop) as cm:
            self.run_post(self.post_args())
        self.assertEqual(cm.exception.code, "ISSUE_CLOSED")
        self.assertEqual(self.writer.posted, [])

    def test_wrong_account_at_post_gate_stops(self) -> None:
        self.runner.push_git_sha()
        self.runner.push_git_sha()
        self.runner.push_auth_ok()
        self.runner.push_gh_user("someone-else")
        with self.assertRaises(ko.Stop) as cm:
            self.run_post(self.post_args())
        self.assertEqual(cm.exception.code, "BAD_ACCOUNT")
        self.assertEqual(self.writer.posted, [])

    def test_wrong_repo_allowlist_at_post_gate_stops(self) -> None:
        # gh account matches the task repo owner, but that repo is outside
        # the owner allowlist: guard_repo must fire before any write.
        task = self.store.load()
        task["repo"] = "evil-org/keenetic-auto-setup"
        self.store.save(task)
        self.runner.push_git_sha()
        self.runner.push_git_sha()
        self.runner.push_auth_ok()
        self.runner.push_gh_user("evil-org")
        with self.assertRaises(ko.Stop) as cm:
            self.run_post(self.post_args())
        self.assertEqual(cm.exception.code, "BAD_REPO")
        self.assertEqual(self.writer.posted, [])

    def test_malformed_comments_payload_stops(self) -> None:
        cases = [("not_a_list", {"unexpected": "payload"}),
                 ("body_none", [{"id": 1, "body": None}]),
                 ("body_number", [{"id": 1, "body": 7}])]
        for name, page in cases:
            with self.subTest(case=name):
                self.runner.queue.clear()
                self.queue_post_reads(comment_pages=[page])
                with self.assertRaises(ko.Stop) as cm:
                    self.run_post(self.post_args())
                self.assertEqual(cm.exception.code, "MARKERS_UNREADABLE")
                self.assertEqual(self.writer.posted, [])

    def test_comments_unreachable_stops_without_posting(self) -> None:
        self.runner.push_git_sha()
        self.runner.push_git_sha()
        self.runner.push_auth_ok()
        self.runner.push_gh_user()
        self.runner.push_gh_issue()
        self.runner.push("", returncode=1, stderr="dial tcp: connection refused")
        with self.assertRaises(ko.Stop) as cm:
            self.run_post(self.post_args())
        self.assertEqual(cm.exception.code, "NETWORK")
        self.assertEqual(self.writer.posted, [])
        self.assertFalse(self.store.checkpoint_file.exists())

    def test_missing_run_id_stops(self) -> None:
        task = self.store.load()
        task.pop("run_id")
        self.store.save(task)
        self.runner.push_git_sha()
        with self.assertRaises(ko.Stop) as cm:
            self.run_post(self.post_args())
        self.assertEqual(cm.exception.code, "STATE_INCOMPLETE")
        self.assertEqual(self.writer.posted, [])

    def test_stale_run_id_stops(self) -> None:
        task = self.store.load()
        task["run_id"] = "f" * 32  # well-formed but not the journaled run
        self.store.save(task)
        self.runner.push_git_sha()
        with self.assertRaises(ko.Stop) as cm:
            self.run_post(self.post_args())
        self.assertEqual(cm.exception.code, "RUN_ID_STALE")
        self.assertEqual(self.writer.posted, [])

    # -- payload hygiene -----------------------------------------------------
    def test_oversized_fields_stop(self) -> None:
        self.runner.push_git_sha()
        with self.assertRaises(ko.Stop) as cm:
            self.run_post(self.post_args(blocker="x" * 501))
        self.assertEqual(cm.exception.code, "PAYLOAD_INVALID")
        self.assertEqual(self.writer.posted, [])
        self.runner.queue.clear()
        self.runner.push_git_sha()
        with self.assertRaises(ko.Stop) as cm:
            self.run_post(self.post_args(evidence=["https://a", "https://b",
                                                   "https://c", "https://d"]))
        self.assertEqual(cm.exception.code, "PAYLOAD_INVALID")
        with self.assertRaises(ko.Stop) as cm:
            ko.scan_post_payload("x" * (ko.MAX_POST_BODY + 1))
        self.assertEqual(cm.exception.code, "PAYLOAD_TOO_LARGE")

    def test_secret_bearing_payload_stops(self) -> None:
        cases = [
            ("github_token", "https://x.test/t?k=ghp_" + "A" * 36),
            ("aws_key", "AKIA" + "B" * 16),
            ("bearer", "Bearer " + "c" * 20),
            ("private_key", "-----BEGIN RSA PRIVATE KEY-----"),
            ("assignment", "token: " + "d" * 12),
        ]
        for name, secret in cases:
            with self.subTest(case=name):
                self.runner.queue.clear()
                self.runner.push_git_sha()
                with self.assertRaises(ko.Stop) as cm:
                    self.run_post(self.post_args(evidence=[secret]))
                self.assertEqual(cm.exception.code, "SECRETS_DETECTED")
                self.assertEqual(self.writer.posted, [])

    def test_pass_like_tokens_fail_closed(self) -> None:
        cases = [("evidence", ["run shows CI PASS"]),
                 ("evidence_field", ["run shows FIELD PASS"]),
                 ("blocker", "status was PASS"),
                 ("next", "wait for CI PASS")]
        for name, value in cases:
            with self.subTest(case=name):
                self.runner.queue.clear()
                self.runner.push_git_sha()
                if name.startswith("evidence"):
                    args = self.post_args(evidence=value)
                elif name == "blocker":
                    args = self.post_args(blocker=value)
                else:
                    args = self.post_args(next_decision=value)
                with self.assertRaises(ko.Stop) as cm:
                    self.run_post(args)
                self.assertEqual(cm.exception.code, "POST_FORBIDDEN_TOKEN")
                self.assertEqual(self.writer.posted, [])

    def test_fail_status_local_only_post_forbidden(self) -> None:
        self.runner.push_git_sha()
        with self.assertRaises(ko.Stop) as cm:
            self.run_post(self.post_args(status="FAIL"))
        self.assertEqual(cm.exception.code, "POST_STATUS_FORBIDDEN")
        self.assertEqual(self.writer.posted, [])

    def test_earned_pass_stays_local_unpostable(self) -> None:
        # Even a fully earned PASS (real executor ok event in journal) must
        # never be published by this P1-A writer (#454: no PASS from locals).
        self.runner.push_git_sha()
        self.runner.push_gh_issue()
        cli, electron = self.tmp / "zcode.cjs", self.tmp / "ZCode.exe"
        cli.write_text("// stub", encoding="utf-8")
        electron.write_text("stub", encoding="utf-8")
        orig = ko.EXEC_RUNNER
        ko.EXEC_RUNNER = lambda cmd, **kw: subprocess.CompletedProcess([], 0, "ok", "")
        try:
            res = ko.cmd_dispatch(ko.parser_namespace({
                **self.task, "executor": "zcode-cli",
                "zcode_cli": str(cli), "zcode_electron": str(electron)}),
                ko.GhRunner(self.runner), self.store, POC_DIR)
        finally:
            ko.EXEC_RUNNER = orig
        self.assertEqual(res["state"], "REVIEW_READY")
        self.runner.push_git_sha()
        with self.assertRaises(ko.Stop) as cm:
            self.run_post(self.post_args(status="PASS"))
        self.assertEqual(cm.exception.code, "POST_STATUS_FORBIDDEN")
        self.assertEqual(self.writer.posted, [])
        self.assertFalse(self.store.checkpoint_file.exists())

    # -- writer behaviour ------------------------------------------------------
    def test_post_timeout_is_uncertain_and_never_retried(self) -> None:
        calls: list[list[str]] = []

        def fake_run(cmd, **kwargs):
            calls.append(cmd)
            raise subprocess.TimeoutExpired(cmd, ko.POST_TIMEOUT_S)

        self.queue_post_reads()
        writer = ko.GhCommentWriter(run=fake_run)
        with patch.dict(ko.os.environ, {"KAS_ORCH_ALLOW_WRITE": "1"}), \
                patch.object(ko, "LIVE_POST_ENABLED", True):
            with self.assertRaises(ko.Stop) as cm:
                ko.cmd_checkpoint(self.post_args(), ko.GhRunner(self.runner),
                                  self.store, POC_DIR, writer=writer)
        self.assertEqual(cm.exception.code, "POST_UNCERTAIN")
        self.assertEqual(len(calls), 1, "no auto-retry after an uncertain post")
        self.assertFalse(self.store.checkpoint_file.exists())
        self.assertEqual(self.store.load()["state"], "READY")

    def test_post_network_failure_is_uncertain(self) -> None:
        self.queue_post_reads()
        writer = ko.GhCommentWriter(
            run=lambda cmd, **kw: subprocess.CompletedProcess(
                [], 1, "", "dial tcp: lookup failed"))
        with patch.dict(ko.os.environ, {"KAS_ORCH_ALLOW_WRITE": "1"}), \
                patch.object(ko, "LIVE_POST_ENABLED", True):
            with self.assertRaises(ko.Stop) as cm:
                ko.cmd_checkpoint(self.post_args(), ko.GhRunner(self.runner),
                                  self.store, POC_DIR, writer=writer)
        self.assertEqual(cm.exception.code, "POST_UNCERTAIN")
        self.assertFalse(self.store.checkpoint_file.exists())

    def test_post_gh_failure_is_post_failed(self) -> None:
        self.queue_post_reads()
        writer = ko.GhCommentWriter(
            run=lambda cmd, **kw: subprocess.CompletedProcess(
                [], 1, "", "gh: permission denied"))
        with patch.dict(ko.os.environ, {"KAS_ORCH_ALLOW_WRITE": "1"}), \
                patch.object(ko, "LIVE_POST_ENABLED", True):
            with self.assertRaises(ko.Stop) as cm:
                ko.cmd_checkpoint(self.post_args(), ko.GhRunner(self.runner),
                                  self.store, POC_DIR, writer=writer)
        self.assertEqual(cm.exception.code, "POST_FAILED")
        self.assertFalse(self.store.checkpoint_file.exists())

    def test_real_writer_posts_via_stdin_not_argv(self) -> None:
        self.runner.push("https://github.com/saymer-alt/keenetic-auto-setup/"
                         "issues/430#issuecomment-123456")
        writer = ko.GhCommentWriter(run=self.runner)
        with patch.object(ko, "LIVE_POST_ENABLED", True):
            res = writer.post(ko.DEFAULT_REPO, 430, "payload body")
        self.assertEqual(res["post_status"], "posted")
        self.assertIn("#issuecomment-123456", res["url"])
        cmd = self.runner.calls[-1]  # the writer's gh call, not do_fetch's
        self.assertEqual(cmd[:2], ["gh", "issue"])
        self.assertIn("--body-file", cmd)
        self.assertEqual(cmd[-1], "-", "body must travel via stdin")
        self.assertNotIn("payload body", " ".join(cmd))

    def test_real_writer_refuses_when_gate_closed(self) -> None:
        writer = ko.GhCommentWriter(
            run=lambda cmd, **kw: (_ for _ in ()).throw(
                AssertionError("gh must not run while the live gate is closed")))
        with self.assertRaises(ko.Stop) as cm:
            writer.post(ko.DEFAULT_REPO, 430, "body")
        self.assertEqual(cm.exception.code, "LIVE_POST_NOT_ALLOWED")


if __name__ == "__main__":
    unittest.main()
