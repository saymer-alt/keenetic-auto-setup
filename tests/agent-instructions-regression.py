#!/usr/bin/env python3
"""Focused structural checks for agent instructions; NOT a semantic proof or runtime test."""
from pathlib import Path
import re
import sys

ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
HARD_LIMIT = 12 * 1024
SOFT_TARGET = 8 * 1024
ACTIVE_DOCS = [
    "AGENTS.md",
    "docs/AGENT-DETAILED-REFERENCE.md",
    "docs/agent-guidance/01-architecture-and-platforms.md",
    "docs/agent-guidance/02-development-and-safety.md",
    "docs/agent-guidance/03-agent-workflow-and-git.md",
    "docs/agent-guidance/04-testing-and-portability.md",
    "docs/agent-guidance/06-owner-policy-and-licensing.md",
]
ARCHIVES = [
    "docs/archaeology/kas-agent-historical-context-2026.md",
    "docs/archaeology/kas-platform-field-inventory-2026.md",
]
LINK = re.compile(r"\]\(([^)]+)\)")
OLD_SECTION = re.compile(r"(?:\bsee\s+|\breread\s+|\()§{1,2}\d+", re.IGNORECASE)
errors = []


def require(ok, message):
    if not ok:
        errors.append(message)


def read(path):
    file = ROOT / path
    if not file.is_file():
        errors.append(f"missing file: {path}")
        return ""
    return file.read_text(encoding="utf-8")


docs = {name: read(name) for name in ACTIVE_DOCS + ARCHIVES}
startup = docs["AGENTS.md"]
safety = docs["docs/agent-guidance/02-development-and-safety.md"]
workflow = docs["docs/agent-guidance/03-agent-workflow-and-git.md"]
policy = read("docs/CONSTITUTION.md")

nbytes = len(startup.encode("utf-8"))
require(nbytes <= HARD_LIMIT, f"AGENTS.md startup exceeds {HARD_LIMIT} bytes: {nbytes}")
if SOFT_TARGET < nbytes <= HARD_LIMIT:
    print(f"[WARN] AGENTS.md is {nbytes} bytes, above {SOFT_TARGET}-byte target; review need, do not delete safety rules")

# Known-policy sentinels are NOT a proof of logical equivalence: require human review.
for term in (
    "KAS-SAFETY-001",
    "KAS-AGENT-001",
    "docs/CONSTITUTION.md",
    "docs/AGENT-TASK-CONTRACT.md",
    "main",
    "stable",
    "owner GO",
    "rollback",
    "FIELD PASS",
    "quiet per attempt",
):
    require(term in startup, f"required startup policy anchor absent: {term}")
require("KAS-SAFETY-001" in policy and "KAS-AGENT-001" in policy,
        "KAS constitution invariants missing")
require("Before drafting or executing any KAS agent task" in startup,
        "startup must require consulting task policy for every agent task")
require("Before drafting **or executing**" in workflow,
        "detailed agent workflow lost mandatory task-contract entrypoint")

# Do not autoload historical router inventory and previous incidents.
require(not re.search(r"\b(?:KN|NC)-\d{4}\b", startup),
        "historical router inventory must not be loaded in root AGENTS")
require("docs/archaeology/" not in startup,
        "root AGENTS should link via topical index, not history files")
require("## 10. Historical context (why it is this way)" in docs[ARCHIVES[0]],
        "historical incident section missing")
require("## 11. Known pitfalls" in docs[ARCHIVES[0]],
        "historical pitfall section missing")
require("## 3. Target platforms" in docs[ARCHIVES[1]],
        "old platform evidence not preserved")

# Active hazards recovered from historical notes must be easy to find.
for term in (
    "## Current operational pitfalls",
    "set -e",
    "/proc/<pid>/exe",
    "type=iptables",
    "table=mangle",
    "cron",
):
    require(term in safety, f"active runtime guardrail absent: {term}")
require("topic branch" in workflow, "workflow must describe isolated development branches")
require("make sure you are on main" not in workflow,
        "workflow incorrectly requires editing directly on main")
require(("Develop on " + chr(96) + "main" + chr(96)) not in workflow,
        "workflow still instructs agents to develop directly on main")

# Monolith section numbers can no longer be used as cross-document navigation.
for path in ACTIVE_DOCS:
    require(not OLD_SECTION.search(docs[path]), f"stale cross-file section reference in {path}")

# Verify Markdown local file destinations (anchor semantics still need review).
for path, body in docs.items():
    parent = (ROOT / path).parent
    for match in LINK.finditer(body):
        raw = match.group(1).strip()
        if not raw or raw.startswith(("https://", "http://", "mailto:", "#")):
            continue
        local = raw.split("#", 1)[0]
        if not local:
            continue
        target = (parent / local).resolve()
        try:
            target.relative_to(ROOT)
        except ValueError:
            errors.append(f"{path}: local link escapes repository: {raw}")
            continue
        require(target.is_file(), f"{path}: missing link target: {raw}")

if errors:
    for issue in errors:
        print(f"[FAIL] {issue}", file=sys.stderr)
    sys.exit(1)
print(f"[OK] agent instruction structural contracts: root={nbytes} bytes, "
      f"{len(ACTIVE_DOCS)} active files, {len(ARCHIVES)} archives")
