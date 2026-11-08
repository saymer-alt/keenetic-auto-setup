#!/usr/bin/env python3
"""Mock-first, fail-closed GitHub checkpoint publisher contract (Issue #454).

Not connected to the production kas_orchestrate.py --post CLI. Live posting
remains DISABLED until a separate owner GO-B and a reviewed transport adapter.
No network, LLM, or new dependencies; transport is injected for offline tests.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any, Protocol
from urllib.parse import urlsplit

REPO = "saymer-alt/keenetic-auto-setup"
SHA_RE = re.compile(r"^[a-f0-9]{40}$")
RUN_RE = re.compile(r"^[a-f0-9]{32}$")
MARKER_PREFIX = "kas-orch:checkpoint:v1"
SUSPICIOUS = re.compile(
    r"(?i)(?:\b(?:api[_-]?key|password|passwd|secret|authorization|bearer)\b"
    r"|(?:access|refresh)[_-]?token\b|-----BEGIN|https?://[^\s/]+:[^\s/@]+@"
    r"|\b(?:CI|FIELD)\s+PASS\b)"
)


class PublisherStop(Exception):
    """A safe, non-retryable refusal."""
    def __init__(self, code: str, detail: str) -> None:
        self.code = code
        super().__init__(f"STOP_{code}: {detail}")


@dataclass(frozen=True)
class PublishPlan:
    repo: str
    issue: int
    issue_url: str
    issue_updated_at: str
    issue_title: str
    task_id: str
    run_id: str
    base_sha: str
    status: str
    marker: str
    body: str


class Transport(Protocol):
    """list_comments MUST return every page, or explicitly complete=False."""
    def account(self) -> str: ...
    def issue(self, repo: str, number: int) -> dict[str, Any]: ...
    def checkout_head(self) -> str: ...
    def list_comments(self, repo: str, number: int) -> dict[str, Any]: ...
    def post_comment(self, repo: str, number: int, body: str) -> None: ...


def _safe_text(value: str, field: str) -> str:
    if not isinstance(value, str) or len(value.encode("utf-8")) > 240:
        raise PublisherStop("UNSAFE_FIELD", f"{field} is missing or exceeds 240 bytes")
    if any(ord(c) < 32 or ord(c) == 127 or c in "<>|@[]{}" for c in value):
        raise PublisherStop("UNSAFE_FIELD", f"{field} contains markup, mention or controls")
    if SUSPICIOUS.search(value):
        raise PublisherStop("SECRET_OR_CLAIM", f"{field} contains secrets/unverified claims")
    return value.strip() or "not supplied"


def _evidence_url(value: str) -> str:
    if not isinstance(value, str) or len(value) > 320:
        raise PublisherStop("UNSAFE_EVIDENCE", "evidence URL absent/oversized")
    try:
        parts = urlsplit(value)
        valid = (parts.scheme == "https" and parts.hostname == "github.com"
                 and parts.port is None and parts.username is None and parts.password is None
                 and not parts.query and not parts.fragment)
    except ValueError as exc:
        raise PublisherStop("UNSAFE_EVIDENCE", "invalid URL") from exc
    prefix = f"/{REPO}/"
    if not valid or not parts.path.startswith(prefix):
        raise PublisherStop("UNSAFE_EVIDENCE", "evidence must be canonical same-repo GitHub URL")
    suffix = parts.path[len(prefix):]
    if not re.fullmatch(r"(?:issues|pull)/[1-9][0-9]*|actions/runs/[1-9][0-9]*|commit/[a-f0-9]{40}", suffix):
        raise PublisherStop("UNSAFE_EVIDENCE", "evidence type is not allowlisted")
    return value


def prepare(task: dict[str, Any], *, status: str, evidence: list[str] | None = None,
            blocker: str = "", next_owner_decision: str = "", head_sha: str = "") -> PublishPlan:
    """Build bounded, visibly UNVERIFIED payload. PASS/CI/FIELD PASS are forbidden."""
    if not isinstance(task, dict):
        raise PublisherStop("BAD_STATE", "missing task")
    repo, number = task.get("repo"), task.get("issue")
    base, run, task_id = task.get("base_sha"), task.get("run_id"), task.get("task_id")
    updated, title = task.get("issue_updated_at"), task.get("intent")
    if repo != REPO or not isinstance(number, int) or isinstance(number, bool) or number <= 0:
        raise PublisherStop("BAD_REPO", "wrong repo or issue")
    if not isinstance(base, str) or not SHA_RE.fullmatch(base):
        raise PublisherStop("BAD_SHA", "full lowercase Git SHA required")
    if not isinstance(run, str) or not RUN_RE.fullmatch(run):
        raise PublisherStop("BAD_RUN", "unique valid run ID required")
    if task_id != f"issue-{number}-{base[:12]}":
        raise PublisherStop("BAD_TASK", "task ID inconsistent with issue/SHA")
    issue_url = f"https://github.com/{repo}/issues/{number}"
    if task.get("issue_url") != issue_url or not isinstance(updated, str) or not updated:
        raise PublisherStop("BAD_ISSUE", "issue identity/timestamp incomplete")
    if not isinstance(title, str) or not title.strip():
        raise PublisherStop("BAD_ISSUE", "issue title missing")
    if status not in ("BLOCKED", "NOT_TESTED"):
        raise PublisherStop("STATUS_DENIED", "P1-A permits BLOCKED/NOT_TESTED only")
    if head_sha and head_sha != base:
        raise PublisherStop("UNVERIFIED_HEAD", "changed head requires independent commit verification")
    ev = [] if evidence is None else evidence
    if not isinstance(ev, list) or len(ev) > 3:
        raise PublisherStop("UNSAFE_EVIDENCE", "at most three evidence URLs")
    urls = [_evidence_url(e) for e in ev]
    reason = _safe_text(blocker, "blocker")
    decision = _safe_text(next_owner_decision, "next_owner_decision")
    marker = f"<!-- {MARKER_PREFIX} task={task_id} run={run} status={status} -->"
    # Original Issue text, executor stdout, full CI logs, credentials are excluded.
    body = "\n".join((
        marker,
        "**KAS checkpoint: UNVERIFIED (mock-first publisher)**",
        "",
        f"- Issue: {issue_url}",
        f"- Task/run: {task_id} / {run}",
        f"- Base/head SHA (local checkout only): {base}",
        f"- Status: {status}; not an independently verified CI/FIELD result",
        f"- Evidence URLs (unverified): {', '.join(urls) if urls else 'none'}",
        f"- Blocker (untrusted field): {reason}",
        f"- Next owner decision (untrusted field): {decision}",
        "- No authorization for merge/release/deploy/hardware is implied.",
    ))
    if len(body.encode("utf-8")) > 2600:
        raise PublisherStop("OVERSIZE", "payload too large")
    return PublishPlan(repo, number, issue_url, updated, title, task_id,
                       run, base, status, marker, body)


def _check_issue(transport: Transport, plan: PublishPlan) -> None:
    issue = transport.issue(plan.repo, plan.issue)
    if not isinstance(issue, dict) or (issue.get("number") != plan.issue
            or issue.get("url") != plan.issue_url or issue.get("state") != "OPEN"):
        raise PublisherStop("ISSUE_CHANGED", "issue changed, closed or replaced")
    if issue.get("updatedAt") != plan.issue_updated_at or issue.get("title") != plan.issue_title:
        raise PublisherStop("ISSUE_CHANGED", "issue edited since original fetch")


def _read_comments(transport: Transport, plan: PublishPlan) -> list[str]:
    result = transport.list_comments(plan.repo, plan.issue)
    if not isinstance(result, dict) or result.get("complete") is not True:
        raise PublisherStop("COMMENTS_INCOMPLETE", "must read every comments page")
    items = result.get("items")
    if not isinstance(items, list) or len(items) > 1000:
        raise PublisherStop("COMMENTS_INCOMPLETE", "missing/oversized comment list")
    bodies = []
    for item in items:
        if not isinstance(item, dict) or not isinstance(item.get("body"), str):
            raise PublisherStop("COMMENTS_MALFORMED", "comment without text body")
        bodies.append(item["body"])
    return bodies


def _existing(plan: PublishPlan, bodies: list[str]) -> bool:
    prefix = f"<!-- {MARKER_PREFIX} task={plan.task_id} run={plan.run_id}"
    matches = [body for body in bodies if body.startswith(prefix)]
    if len(matches) > 1:
        raise PublisherStop("DUPLICATE_CONFLICT", "multiple comments for same run")
    if matches:
        if matches[0] != plan.body:
            raise PublisherStop("DUPLICATE_CONFLICT", "same run already has different payload")
        return True
    return False


def publish_mock(transport: Transport, plan: PublishPlan, *,
                 allow_mock_write: bool = False) -> dict[str, Any]:
    """Exercise a fake transport. Not reachable from existing --post CLI.

    Live implementation must obtain owner GO-B and implement gh double opt-in.
    """
    if not allow_mock_write:
        raise PublisherStop("WRITE_DISABLED", "live GitHub writes not authorized")
    if transport.account() != REPO.split("/")[0]:
        raise PublisherStop("BAD_ACCOUNT", "writer must be repository owner")
    # A previously confirmed comment can advance Issue.updatedAt. Deduplicate
    # before freshness checks, but NEVER write unless those checks pass.
    initial = _read_comments(transport, plan)
    if _existing(plan, initial):
        return {"post_status": "already_posted", "posted": False}
    _check_issue(transport, plan)
    if transport.checkout_head() != plan.base_sha:
        raise PublisherStop("STALE_SHA", "checkout changed immediately before posting")
    again = _read_comments(transport, plan)
    if again != initial:
        raise PublisherStop("CONCURRENT_CHANGE", "comments changed before posting")
    # The Issue may change while comments are being paginated; check a second
    # time immediately before attempting the non-atomic write.
    _check_issue(transport, plan)
    try:
        transport.post_comment(plan.repo, plan.issue, plan.body)
    except Exception as exc:
        raise PublisherStop("POST_UNCERTAIN", "write outcome unknown; no automatic retry") from exc
    try:
        verified = _read_comments(transport, plan)
    except Exception as exc:
        raise PublisherStop("POST_UNCERTAIN", "cannot verify posted comment; no auto retry") from exc
    if not _existing(plan, verified):
        raise PublisherStop("POST_UNCERTAIN", "comment not visible after posting; no auto retry")
    return {"post_status": "posted_confirmed_mock", "posted": True}
