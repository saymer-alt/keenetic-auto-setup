#!/usr/bin/env python3
"""Offline contract tests for the read-only Core Sync Guard."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


CHECKER = Path(__file__).resolve().parents[1] / "scripts" / "core-sync-check.py"


def git(repo, *args):
    p = subprocess.run(["git", "-C", str(repo), *args],
                       check=True, text=True, capture_output=True)
    return p.stdout.strip()


class CoreSyncGuardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name) / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q")
        git(self.repo, "config", "user.email", "core-sync-test@example.invalid")
        git(self.repo, "config", "user.name", "Core Sync Tests")
        (self.repo / "a.sh").write_text("#!/bin/sh\necho a\n")
        (self.repo / "b.sh").write_text("#!/bin/sh\necho b\n")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-qm", "stable")
        self.stable_ref = git(self.repo, "rev-parse", "HEAD")
        self.b_stable = git(self.repo, "rev-parse", "HEAD:b.sh")
        (self.repo / "b.sh").write_text("#!/bin/sh\necho changed\n")
        (self.repo / "c.sh").write_text("#!/bin/sh\necho main only\n")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-qm", "main")
        self.b_main = git(self.repo, "rev-parse", "HEAD:b.sh")
        self.c_main = git(self.repo, "rev-parse", "HEAD:c.sh")
        self.config = Path(self.tmp.name) / "config.json"
        self.report = Path(self.tmp.name) / "report.json"

    def run_guard(self, acknowledged):
        self.config.write_text(json.dumps({
            "schema": "core-sync/v1", "acknowledged": acknowledged,
        }), encoding="utf-8")
        result = subprocess.run([
            sys.executable, str(CHECKER), "--repo", str(self.repo),
            "--main-ref", "HEAD", "--stable-ref", self.stable_ref,
            "--config", str(self.config), "--json-out", str(self.report),
        ], text=True, capture_output=True)
        data = json.loads(self.report.read_text()) if self.report.exists() else {}
        return result, {e["path"]: e for e in data.get("entries", [])}

    def test_pinned_drift_and_new_unreviewed_file(self):
        ack = {
            "b.sh": {"main": self.b_main, "stable": self.b_stable,
                     "reason": "reviewed branch-specific difference"},
            "c.sh": {"main": self.c_main, "stable": None,
                     "reason": "accepted main-only standalone tool"},
        }
        result, rows = self.run_guard(ack)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rows["a.sh"]["status"], "SYNC")
        self.assertEqual(rows["b.sh"]["status"], "ACKNOWLEDGED")
        self.assertEqual(rows["c.sh"]["status"], "ACKNOWLEDGED")
        self.assertNotIn("::warning", result.stdout)

        (self.repo / "b.sh").write_text("#!/bin/sh\necho another change\n")
        (self.repo / "new-tool.sh").write_text("#!/bin/sh\nexit 0\n")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-qm", "unreviewed modifications")
        result, rows = self.run_guard(ack)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rows["b.sh"]["status"], "REVIEW")
        self.assertEqual(rows["new-tool.sh"]["status"], "REVIEW")
        self.assertIn("::warning file=b.sh", result.stdout)
        self.assertEqual(rows["c.sh"]["status"], "ACKNOWLEDGED")

    def test_missing_main_and_invalid_ref(self):
        git(self.repo, "rm", "a.sh")
        git(self.repo, "commit", "-qm", "remove core script")
        result, rows = self.run_guard({})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rows["a.sh"]["status"], "REVIEW")
        self.assertEqual(rows["a.sh"]["reason"], "Present only in stable")
        missing = subprocess.run([
            sys.executable, str(CHECKER), "--repo", str(self.repo),
            "--main-ref", "no-such-branch", "--stable-ref", self.stable_ref,
            "--config", str(self.config),
        ], text=True, capture_output=True)
        self.assertEqual(missing.returncode, 2)

    def test_invalid_pinned_sha_rejected(self):
        result, _ = self.run_guard({
            "b.sh": {"main": "fake", "stable": self.b_stable,
                     "reason": "invalid pin"}
        })
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
