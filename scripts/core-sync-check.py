#!/usr/bin/env python3
"""Read-only Core drift detector. Does not merge branches or change the repo.

The initial scope is all root-level *.sh files from the union of both trees.
Pinned acknowledgements are exact (main blob SHA, stable blob SHA) pairs:
a new edit automatically becomes REVIEW, never a permanent ignored path.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

SHA_RE = re.compile(r"^[0-9a-f]{40}$")
ROOT_SCRIPT_RE = re.compile(r"^[^/]+\.sh$")


def tree_blobs(repo: Path, ref: str) -> dict:
    proc = subprocess.run(
        ["git", "-C", str(repo), "ls-tree", "-r", "-z", ref],
        capture_output=True, check=True,
    )
    blobs = {}
    for record in proc.stdout.split(b"\0"):
        if not record:
            continue
        meta, path = record.split(b"\t", 1)
        mode, kind, sha = meta.split(b" ")
        if kind == b"blob":
            blobs[path.decode("utf-8")] = sha.decode("ascii")
    return blobs


def load_acknowledgements(filename: Path) -> dict:
    data = json.loads(filename.read_text(encoding="utf-8"))
    if data.get("schema") != "core-sync/v1":
        raise ValueError("unsupported Core Sync Guard schema")
    items = data.get("acknowledged", {})
    if not isinstance(items, dict):
        raise ValueError("acknowledged must be an object")
    for path, info in items.items():
        if not ROOT_SCRIPT_RE.fullmatch(path) or not isinstance(info, dict):
            raise ValueError("invalid acknowledgement path")
        if not isinstance(info.get("reason"), str) or not info["reason"].strip():
            raise ValueError("acknowledgement requires a reason: " + path)
        for ref in ("main", "stable"):
            val = info.get(ref)
            if val is not None and (not isinstance(val, str) or not SHA_RE.fullmatch(val)):
                raise ValueError("invalid pinned blob SHA for " + path)
    return items


def scan(main_blobs: dict, stable_blobs: dict, acknowledged: dict) -> list:
    paths = sorted(p for p in main_blobs.keys() | stable_blobs.keys()
                   if ROOT_SCRIPT_RE.fullmatch(p))
    report = []
    for path in paths:
        main_sha = main_blobs.get(path)
        stable_sha = stable_blobs.get(path)
        ack = acknowledged.get(path)
        if main_sha == stable_sha:
            status, reason = "SYNC", "Identical blobs"
        elif (ack is not None
              and ack.get("main") == main_sha
              and ack.get("stable") == stable_sha):
            status, reason = "ACKNOWLEDGED", ack["reason"]
        else:
            status = "REVIEW"
            if main_sha is None:
                reason = "Present only in stable"
            elif stable_sha is None:
                reason = "Present only in main"
            elif ack is not None:
                reason = "Changed from the acknowledged blob pair"
            else:
                reason = "Unreviewed main/stable difference"
        report.append({
            "path": path, "status": status, "reason": reason,
            "main_blob": main_sha, "stable_blob": stable_sha,
        })
    return report


def fmt_sha(value):
    return value[:12] if value else "ABSENT"


def markdown(rows, main_ref, stable_ref):
    counts = {state: sum(row["status"] == state for row in rows)
              for state in ("SYNC", "ACKNOWLEDGED", "REVIEW")}
    output = [
        "## Core Sync Guard (informational)",
        "",
        "Comparing root-level shell scripts by Git blob SHA.",
        "No merges, writes, branch protection or release gates are performed.",
        "",
        "- main candidate: " + main_ref,
        "- production baseline: " + stable_ref,
        "- SYNC: {SYNC}; ACKNOWLEDGED: {ACKNOWLEDGED}; REVIEW: {REVIEW}".format(**counts),
        "",
        "| Script | Status | main blob | stable blob | Note |",
        "|---|---|---|---|---|",
    ]
    for row in rows:
        output.append("| {path} | {status} | {main} | {stable} | {reason} |".format(
            path=row["path"], status=row["status"],
            main=fmt_sha(row["main_blob"]), stable=fmt_sha(row["stable_blob"]),
            reason=row["reason"].replace("|", "/").replace("\n", " "),
        ))
    output += ["", "REVIEW is an advisory finding, not permission to backport.",
               "Stable and main need not be identical. Manual triage is required.", ""]
    return "\n".join(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path("."))
    parser.add_argument("--main-ref", default="refs/remotes/origin/main")
    parser.add_argument("--stable-ref", default="refs/remotes/origin/stable")
    parser.add_argument("--config", type=Path,
                        default=Path("config/core-sync-baseline.json"))
    parser.add_argument("--json-out", type=Path)
    args = parser.parse_args()
    try:
        ack = load_acknowledgements(args.config)
        rows = scan(tree_blobs(args.repo, args.main_ref),
                    tree_blobs(args.repo, args.stable_ref), ack)
        if not rows:
            raise ValueError("No root shell scripts found; check Git refs")
    except (OSError, subprocess.CalledProcessError, ValueError, json.JSONDecodeError) as exc:
        print("Core Sync Guard infrastructure ERROR: " + str(exc), file=sys.stderr)
        return 2

    report = markdown(rows, args.main_ref, args.stable_ref)
    print(report)
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(
            json.dumps({"schema": "core-sync-report/v1",
                        "main_ref": args.main_ref, "stable_ref": args.stable_ref,
                        "entries": rows}, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
    summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_file:
        with open(summary_file, "a", encoding="utf-8") as summary:
            summary.write(report + "\n")
    for row in rows:
        if row["status"] == "REVIEW":
            print("::warning file={path},title=Core Sync Guard::"
                  "Unreviewed {path} drift; main={main}; stable={stable}".format(
                      path=row["path"], main=fmt_sha(row["main_blob"]),
                      stable=fmt_sha(row["stable_blob"])))
    return 0  # Drift is informational; only broken checker/infrastructure is fatal.


if __name__ == "__main__":
    sys.exit(main())
