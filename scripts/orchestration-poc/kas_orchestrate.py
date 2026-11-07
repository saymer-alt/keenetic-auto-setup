#!/usr/bin/env python3
"""KAS Agent Orchestration POC (issue #430) — read-only GitHub task transport.

Fetches exactly one GitHub Issue by number, validates source/repo/permissions/
SHA, emits a compact task-contract handoff, and produces a structured
checkpoint. Execution is DRY-RUN by default: no LLM agent is started without
an explicit ``--executor`` choice, and any write to GitHub requires a double
opt-in (``--post`` + ``--confirm`` + ``KAS_ORCH_ALLOW_WRITE=1``).

Design constraints (issue #430, AGENTS.md):
- reuse-first: `gh` CLI is the only GitHub backend; no new servers, daemons,
  webhooks, Actions or API tokens. Auth comes from the existing `gh` keyring.
- one active task; the executor reads the Issue itself via `gh issue view N`,
  so task text is never copy-pasted by the owner.
- fail closed: every unsupported or ambiguous condition is a STOP, not a guess.

Exit codes: 0 = done, 2 = STOP (safe refusal, reason printed), 1 = internal error.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Callable

DEFAULT_REPO = "saymer-alt/keenetic-auto-setup"
MAX_ISSUE_BODY = 50_000  # bytes; bounded reading per token-efficiency doc
TRUNCATION_MARKER = "\n\n[KAS-ORCH: body truncated at %d bytes; read the rest via gh issue view]"
PLAN_MODE = "plan"  # the only headless mode this tool may ever request
FORBIDDEN_MODES = ("yolo", "build", "edit")  # never pass these to an executor
EXECUTOR_TIMEOUT_S = 15 * 60

# Structured checkpoint fields required by issue #430 (Stage 1).
CHECKPOINT_FIELDS = (
    "task_id",
    "issue",
    "repo",
    "base_sha",
    "head_sha",
    "status",
    "evidence",
    "blocker",
    "next_owner_decision",
)

STATUSES = ("PASS", "FAIL", "BLOCKED", "NOT_TESTED")

TASK_STATES = ("READY", "CLAIMED", "RUNNING", "REVIEW_READY", "BLOCKED", "OWNER_DECISION")


class Stop(Exception):
    """Safe refusal: the tool refuses the step and reports why."""

    def __init__(self, code: str, detail: str) -> None:
        super().__init__(f"STOP_{code}: {detail}")
        self.code = code
        self.detail = detail


class GhRunner:
    """Thin subprocess wrapper around gh/git; injectable in tests."""

    def __init__(
        self,
        run: Callable[..., subprocess.CompletedProcess[str]] | None = None,
    ) -> None:
        self._run = run or subprocess.run

    def gh_json(self, *args: str) -> dict[str, Any]:
        proc = self._run(["gh", *args], capture_output=True, text=True, timeout=60,
                         encoding="utf-8", errors="replace")
        if proc.returncode != 0:
            raise Stop("NETWORK" if _looks_like_network(proc.stderr) else "GH_COMMAND",
                       f"gh {' '.join(args)} failed: {_first_line(proc.stderr)}")
        try:
            return json.loads(proc.stdout)
        except json.JSONDecodeError as exc:
            raise Stop("GH_COMMAND", f"gh returned non-JSON output: {exc}") from exc

    def gh_ok(self, *args: str) -> bool:
        proc = self._run(["gh", *args], capture_output=True, text=True, timeout=30,
                         encoding="utf-8", errors="replace")
        return proc.returncode == 0

    def git(self, *args: str) -> str:
        proc = self._run(["git", *args], capture_output=True, text=True, timeout=30,
                         encoding="utf-8", errors="replace")
        if proc.returncode != 0:
            raise Stop("GIT", f"git {' '.join(args)} failed: {_first_line(proc.stderr)}")
        return proc.stdout.strip()


def _first_line(text: str) -> str:
    for line in (text or "").splitlines():
        if line.strip():
            return line.strip()[:200]
    return "(no stderr)"


def _looks_like_network(stderr: str) -> bool:
    low = (stderr or "").lower()
    return any(w in low for w in ("network", "timed out", "connection", "could not resolve",
                                  "unreachable", "tls", "dial tcp", "temporary failure"))


# ---------------------------------------------------------------- validation

def check_auth(runner: GhRunner) -> None:
    if not runner.gh_ok("auth", "status"):
        raise Stop("NO_AUTH", "gh is not authenticated; run `gh auth login` first")


def fetch_issue(runner: GhRunner, repo: str, number: int) -> dict[str, Any]:
    data = runner.gh_json(
        "issue", "view", str(number), "--repo", repo,
        "--json", "number,title,state,body,url,updatedAt,labels,author",
    )
    if data.get("state") != "OPEN":
        raise Stop("ISSUE_CLOSED", f"issue #{number} state is {data.get('state')!r}, only OPEN accepted")
    return data


def guard_repo(repo: str) -> None:
    # Allowlist guard: this POC is bound to the KAS repository by default.
    # Overriding --repo is allowed only to a same-owner repository, so the tool
    # cannot be pointed at an arbitrary third-party target without editing code.
    owner = repo.split("/")[0] if "/" in repo else ""
    if owner != DEFAULT_REPO.split("/")[0]:
        raise Stop("BAD_REPO", f"repo {repo!r} is outside the owner allowlist ({DEFAULT_REPO.split('/')[0]}/*)")


def truncate_body(body: str) -> tuple[str, bool]:
    raw = body or ""
    if len(raw.encode("utf-8")) <= MAX_ISSUE_BODY:
        return raw, False
    cut = raw.encode("utf-8")[:MAX_ISSUE_BODY].decode("utf-8", errors="ignore")
    return cut + TRUNCATION_MARKER % MAX_ISSUE_BODY, True


def current_sha(runner: GhRunner, repo_path: Path) -> str:
    return runner.git("-C", str(repo_path), "rev-parse", "HEAD")


# ---------------------------------------------------------------- state store

def parser_namespace(values: dict[str, Any]) -> argparse.Namespace:
    """Build an argparse.Namespace from a dict (used by tests and helpers)."""
    return argparse.Namespace(**values)


class TaskStore:
    """Local cache of the one active task; GitHub remains source of truth."""

    def __init__(self, state_dir: Path) -> None:
        self.dir = state_dir
        self.dir.mkdir(parents=True, exist_ok=True)
        self.task_file = self.dir / "current_task.json"
        self.journal = self.dir / "events.jsonl"
        self.contract_file = self.dir / "contract.json"
        self.handoff_file = self.dir / "handoff.md"
        self.checkpoint_file = self.dir / "checkpoint.md"

    def load(self) -> dict[str, Any] | None:
        if not self.task_file.exists():
            return None
        try:
            return json.loads(self.task_file.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            raise Stop("STATE_CORRUPT", f"{self.task_file} is not valid JSON; run `reset`")

    def save(self, task: dict[str, Any]) -> None:
        self.task_file.write_text(json.dumps(task, indent=2, ensure_ascii=False), encoding="utf-8")

    def transition(self, task: dict[str, Any], new_state: str, event: str) -> None:
        old = task.get("state")
        task["state"] = new_state
        self.save(task)
        with self.journal.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "event": event,
                                 "from": old, "to": new_state,
                                 "task_id": task.get("task_id")}, ensure_ascii=False) + "\n")

    def reset(self) -> None:
        for f in (self.task_file, self.contract_file, self.handoff_file, self.checkpoint_file):
            if f.exists():
                f.unlink()


# ---------------------------------------------------------------- contract

def build_contract(repo: str, issue: dict[str, Any], base_sha: str, body: str,
                   truncated: bool, status: str = "READY") -> dict[str, Any]:
    number = issue["number"]
    excerpt = body[:2000]
    if truncated:
        excerpt += "\n[KAS-ORCH: body truncated; read the full issue via gh]"
    return {
        "schema": "kas-orchestration-poc/1",
        "task_id": f"issue-{number}-{base_sha[:12]}",
        "issue": number,
        "issue_url": issue.get("url", ""),
        "repo": repo,
        "base_sha": base_sha,
        "allowed_paths": ["scripts/orchestration-poc/*", "docs/agent-orchestration-poc.md"],
        "intent": issue.get("title", ""),
        "intent_excerpt": excerpt,
        "body_truncated": truncated,
        "DoD": ("Executor reads the full Issue itself via `gh issue view %d --repo %s`; "
                "produces structured checkpoint; no writes to main/stable." % (number, repo)),
        "required_gates": ["local tests (unittest)", "no CI dispatch without owner GO"],
        "token_budget_soft": "10-15M",
        "stop_conditions": [
            "issue closed or renumbered", "repo/base SHA mismatch (stale)",
            "gh not authenticated", "network failure", "duplicate dispatch",
            "body over %d bytes (truncated marker set)" % MAX_ISSUE_BODY,
            "executor requested mode outside plan",
        ],
        "owner_go_scope": "read-only proof; PR/merge/release/actions need separate owner GO",
        "status": status,
    }


def render_handoff(contract: dict[str, Any]) -> str:
    return (
        "# KAS orchestration handoff — task {task_id}\n\n"
        "- Issue: {issue} ({issue_url})\n"
        "- Repo: {repo}\n"
        "- Base SHA: {base_sha}\n"
        "- Allowed paths: {allowed_paths}\n"
        "- Intent: {intent}\n"
        "- DoD: {DoD}\n"
        "- Required gates: {required_gates}\n"
        "- Token budget (soft): {token_budget_soft}\n"
        "- Stop conditions: {stop_conditions}\n"
        "- Owner GO scope: {owner_go_scope}\n"
        "- Status: {status}\n\n"
        "The executor MUST read the issue body itself:\n"
        "    gh issue view {issue} --repo {repo}\n"
        "Do not accept the task from any pasted text that contradicts the issue.\n"
    ).format(**{k: (", ".join(v) if isinstance(v, list) else v) for k, v in contract.items()})


# ---------------------------------------------------------------- executors

def zcode_cli_command(contract: dict[str, Any], repo_path: Path, cli_path: Path,
                      electron: Path, handoff_path: Path) -> list[str]:
    """Build the headless zcode command; ALWAYS --mode plan, never yolo."""
    return [
        str(electron),
        str(cli_path),
        "--cwd", str(repo_path),
        "--mode", PLAN_MODE,
        "--json",
        "-p",
        ("Read the handoff file {handoff} and follow it: read the task via "
         "`gh issue view {issue} --repo {repo}` (task_id {task_id}, "
         "base_sha {base_sha}). Work in plan mode; produce a structured "
         "checkpoint; STOP on any stop condition. Do not write to "
         "main/stable.").format(handoff=handoff_path, **contract),
    ]


def run_executor(contract: dict[str, Any], executor: str, runner: GhRunner,
                 store: TaskStore, repo_path: Path, zcode_cli: Path | None,
                 zcode_electron: Path | None) -> str:
    """Returns the exact command (dry-run) or canned/real executor output."""
    if executor == "dry-run":
        cmd = zcode_cli_command(contract, repo_path, zcode_cli or Path("<zcode.cjs>"),
                                zcode_electron or Path("<ZCode.exe>"), store.handoff_file)
        return "DRY-RUN (no execution):\n  " + " ".join(cmd)
    if executor == "mock":
        return ("MOCK executor result: simulated REVIEW_READY for %s; "
                "no model was called." % contract["task_id"])
    if executor == "zcode-cli":
        if not zcode_cli or not zcode_cli.exists():
            raise Stop("EXECUTOR_MISSING", f"zcode.cjs not found at {zcode_cli}")
        if not zcode_electron or not zcode_electron.exists():
            raise Stop("EXECUTOR_MISSING", f"ZCode electron binary not found at {zcode_electron}")
        cmd = zcode_cli_command(contract, repo_path, zcode_cli, zcode_electron, store.handoff_file)
        if cmd[cmd.index("--mode") + 1] != PLAN_MODE:
            raise Stop("UNSAFE_MODE", "executor command requested a mode outside plan")
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                                  errors="replace", timeout=EXECUTOR_TIMEOUT_S,
                                  cwd=str(repo_path))
        except subprocess.TimeoutExpired:
            raise Stop("EXECUTOR_TIMEOUT", f"executor exceeded {EXECUTOR_TIMEOUT_S}s; killed")
        return (proc.stdout + ("\n[stderr] " + proc.stderr if proc.stderr.strip() else "")).strip()
    raise Stop("BAD_EXECUTOR", f"unknown executor {executor!r}")


# ---------------------------------------------------------------- checkpoint

def build_checkpoint(task: dict[str, Any], status: str, head_sha: str,
                     evidence: list[str], blocker: str, next_decision: str) -> str:
    missing = [f for f in ("task_id", "issue", "repo", "base_sha") if not task.get(f)]
    if missing:
        raise Stop("STATE_INCOMPLETE", f"active task lacks fields: {', '.join(missing)}")
    lines = [
        "## KAS orchestration checkpoint (%s)" % time.strftime("%Y-%m-%d %H:%M"),
        "",
        "| field | value |",
        "|---|---|",
        "| task_id | %s |" % task["task_id"],
        "| issue | #%s (%s) |" % (task["issue"], task.get("issue_url", "")),
        "| repo | %s |" % task["repo"],
        "| base SHA | %s |" % task["base_sha"],
        "| head SHA | %s |" % (head_sha or task["base_sha"]),
        "| status | %s |" % status,
        "| evidence | %s |" % ("; ".join(evidence) if evidence else "none"),
        "| blocker | %s |" % (blocker or "none"),
        "| next owner decision | %s |" % next_decision,
        "",
    ]
    return "\n".join(lines)


def post_checkpoint(runner: GhRunner, repo: str, number: int, body: str) -> None:
    # Mechanism stub: real posting is intentionally NOT exercised in this POC.
    # No gh call is made here; a future version wires `gh issue comment` only
    # after a separate owner GO for GitHub writes.
    raise Stop("WRITE_NOT_ALLOWED",
               "checkpoint posting is disabled in this POC; deliver the file manually "
               "(mechanism present, exercised only after owner GO)")


# ---------------------------------------------------------------- CLI

def main(argv: list[str] | None = None) -> int:
    # Windows consoles may be cp1251; keep stdout/stderr UTF-8-safe (no ANSI).
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, OSError):
            pass
    parser = argparse.ArgumentParser(prog="kas_orchestrate", description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=DEFAULT_REPO)
    parser.add_argument("--repo-path", default=".", help="local checkout used for SHA checks")
    parser.add_argument("--state-dir", default=None, help="defaults to <repo-path>/.kas-orch-state")
    parser.add_argument("--json", action="store_true", help="machine-readable result output")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_fetch = sub.add_parser("fetch", help="fetch and validate one issue, create task state")
    p_fetch.add_argument("--issue", type=int, required=True)

    p_status = sub.add_parser("status", help="show current task state")

    p_dispatch = sub.add_parser("dispatch", help="hand the contract to an executor")
    p_dispatch.add_argument("--executor", choices=("dry-run", "mock", "zcode-cli"), default="dry-run")
    p_dispatch.add_argument("--zcode-cli", default=None, help="path to zcode.cjs")
    p_dispatch.add_argument("--zcode-electron", default=None, help="path to ZCode electron binary")

    p_ckpt = sub.add_parser("checkpoint", help="generate a structured checkpoint (local by default)")
    p_ckpt.add_argument("--status", choices=STATUSES, required=True)
    p_ckpt.add_argument("--evidence", action="append", default=[])
    p_ckpt.add_argument("--blocker", default="")
    p_ckpt.add_argument("--next", dest="next_decision", default="await owner GO")
    p_ckpt.add_argument("--head-sha", default="")
    p_ckpt.add_argument("--post", action="store_true", help="attempt to post to GitHub (requires opt-in)")
    p_ckpt.add_argument("--confirm", action="store_true")

    p_reset = sub.add_parser("reset", help="clear local task state")
    p_reset.add_argument("--confirm", action="store_true")

    args = parser.parse_args(argv)
    runner = GhRunner()
    repo_path = Path(args.repo_path).resolve()
    state_dir = Path(args.state_dir) if args.state_dir else repo_path / ".kas-orch-state"
    store = TaskStore(state_dir)

    result: dict[str, Any] = {"cmd": args.cmd, "repo": args.repo}
    try:
        guard_repo(args.repo)
        if args.cmd == "fetch":
            result.update(cmd_fetch(args, runner, store, repo_path))
        elif args.cmd == "status":
            task = store.load()
            if not task:
                raise Stop("NO_ACTIVE_TASK", "no task in state dir; run `fetch --issue N` first")
            result.update({"task_id": task["task_id"], "state": task["state"],
                           "base_sha": task["base_sha"]})
        elif args.cmd == "dispatch":
            result.update(cmd_dispatch(args, runner, store, repo_path))
        elif args.cmd == "checkpoint":
            result.update(cmd_checkpoint(args, runner, store))
        elif args.cmd == "reset":
            if not args.confirm:
                raise Stop("CONFIRM_REQUIRED", "reset deletes local state; pass --confirm")
            store.reset()
            result["message"] = "state cleared"
    except Stop as stop:
        result.update({"result": "STOP", "stop_code": stop.code, "detail": stop.detail})
        print(json.dumps(result, ensure_ascii=False) if args.json else str(stop))
        return 2
    result["result"] = "OK"
    print(json.dumps(result, ensure_ascii=False) if args.json else
          "\n".join(f"{k}: {v}" for k, v in result.items() if k != "cmd"))
    return 0


def cmd_fetch(args: argparse.Namespace, runner: GhRunner, store: TaskStore,
              repo_path: Path) -> dict[str, Any]:
    active = store.load()
    if active and active.get("state") not in ("OWNER_DECISION",):
        raise Stop("ACTIVE_TASK",
                   f"task {active.get('task_id')} is still {active.get('state')}; "
                   "one active task allowed; resolve it or run `reset --confirm`")
    if active:
        store.reset()
    check_auth(runner)
    issue = fetch_issue(runner, args.repo, args.issue)
    body, truncated = truncate_body(issue.get("body") or "")
    base_sha = current_sha(runner, repo_path)
    contract = build_contract(args.repo, issue, base_sha, body, truncated)
    store.save(contract)
    store.transition(contract, "READY", "fetched")
    store.contract_file.write_text(json.dumps(contract, indent=2, ensure_ascii=False), encoding="utf-8")
    store.handoff_file.write_text(render_handoff(contract), encoding="utf-8")
    return {"task_id": contract["task_id"], "state": "READY", "base_sha": base_sha,
            "body_truncated": truncated,
            "handoff": str(store.handoff_file), "contract": str(store.contract_file)}


def cmd_dispatch(args: argparse.Namespace, runner: GhRunner, store: TaskStore,
                 repo_path: Path) -> dict[str, Any]:
    task = store.load()
    if not task:
        raise Stop("NO_ACTIVE_TASK", "no task in state dir; run `fetch --issue N` first")
    if task["state"] == "RUNNING":
        raise Stop("DUPLICATE", f"task {task['task_id']} is already RUNNING; no parallel dispatch")
    if task["state"] in ("REVIEW_READY", "BLOCKED", "OWNER_DECISION"):
        raise Stop("DUPLICATE", f"task {task['task_id']} is {task['state']}; dispatch closed")
    store.transition(task, "CLAIMED", f"dispatch:{args.executor}")
    store.transition(task, "RUNNING", f"executor:{args.executor}")
    out = run_executor(task, args.executor, runner, store, repo_path,
                       Path(args.zcode_cli) if args.zcode_cli else None,
                       Path(args.zcode_electron) if args.zcode_electron else None)
    if args.executor == "mock":
        store.transition(task, "REVIEW_READY", "mock_result")
    return {"task_id": task["task_id"], "state": task["state"], "executor": args.executor,
            "output": out[:4000]}


def cmd_checkpoint(args: argparse.Namespace, runner: GhRunner, store: TaskStore) -> dict[str, Any]:
    task = store.load()
    if not task:
        raise Stop("NO_ACTIVE_TASK", "no task in state dir; run `fetch --issue N` first")
    if args.post:
        if os.environ.get("KAS_ORCH_ALLOW_WRITE") != "1" or not args.confirm:
            raise Stop("WRITE_NOT_ALLOWED",
                       "posting requires KAS_ORCH_ALLOW_WRITE=1 AND --confirm AND owner GO")
        post_checkpoint(runner, task["repo"], task["issue"], "")
    md = build_checkpoint(task, args.status, args.head_sha, args.evidence,
                          args.blocker, args.next_decision)
    store.checkpoint_file.write_text(md, encoding="utf-8")
    store.transition(task, "OWNER_DECISION" if args.status in ("PASS", "FAIL")
                     else ("BLOCKED" if args.status == "BLOCKED" else "REVIEW_READY"),
                     f"checkpoint:{args.status}")
    return {"task_id": task["task_id"], "status": args.status,
            "checkpoint": str(store.checkpoint_file), "posted": False,
            "fields": list(CHECKPOINT_FIELDS)}


if __name__ == "__main__":
    sys.exit(main())
