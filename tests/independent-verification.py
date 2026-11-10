#!/usr/bin/env python3
"""Offline KAS regression ledger. Does NOT prove live router correctness."""
import argparse
import copy
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = "kas-independent-verification/v1"
CASES = (
    ("mt-runtime", "tests/magitrickle-runtime-regression.py"),
    ("rollback-fault", "tests/rollback-regression.py"),
    ("watchdog-diagnostics", "tests/watchdog-diagnostics-regression.py"),
)
SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")
DIGEST_PATTERN = re.compile(r"^[0-9a-f]{64}$")
SOURCE_CI = "CI_LINUX_MOCK"
SOURCE_LOCAL = "LOCAL_MOCK"


def checkout_sha():
    return subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
    ).strip()


def verify(record, sha, source):
    """Return fail-closed findings: NOT_TESTED/SKIPPED never become PASS."""
    failures = []
    if not SHA_PATTERN.fullmatch(sha):
        failures.append("expected checkout SHA must have 40 hex characters")
    if not isinstance(record, dict) or record.get("schema") != SCHEMA:
        return ["schema missing or unexpected"]
    if record.get("checkout_sha") != sha:
        failures.append("checkout SHA mismatch")
    if record.get("source") != source:
        failures.append("source mismatch")
    rows = record.get("cases")
    if not isinstance(rows, list) or len(rows) != len(CASES):
        return failures + ["missing, extra or invalid case list"]
    for row, (case_id, path) in zip(rows, CASES):
        if not isinstance(row, dict):
            failures.append("malformed case")
            continue
        if row.get("id") != case_id or row.get("script") != path:
            failures.append("case identity/order mismatch")
        if row.get("source") != source:
            failures.append(f"{case_id}: untrusted evidence source")
        if row.get("status") != "PASS":
            failures.append(f"{case_id}: not executed successfully")
        if type(row.get("exit_code")) is not int or row["exit_code"] != 0:
            failures.append(f"{case_id}: missing/nonzero exit status")
        if type(row.get("elapsed_ms")) is not int or row["elapsed_ms"] < 0:
            failures.append(f"{case_id}: elapsed time missing")
        if not isinstance(row.get("output_sha256"), str) or not DIGEST_PATTERN.fullmatch(row["output_sha256"]):
            failures.append(f"{case_id}: output digest missing")
    return failures


def run_one(case_id, script, source):
    start = time.monotonic()
    path = ROOT / script
    if not path.is_file() or path.is_symlink():
        return dict(id=case_id, script=script, source=source, status="NOT_TESTED",
                    exit_code=None, elapsed_ms=0, output_sha256=None, reason="script unavailable")
    try:
        result = subprocess.run(
            [sys.executable, str(path)], cwd=ROOT, capture_output=True,
            timeout=240, check=False
        )
        blob = result.stdout + b"\n--stderr--\n" + result.stderr
        return dict(
            id=case_id, script=script, source=source,
            status="PASS" if result.returncode == 0 else "FAIL",
            exit_code=result.returncode,
            elapsed_ms=int((time.monotonic() - start) * 1000),
            output_sha256=hashlib.sha256(blob).hexdigest(),
            reason="completed" if result.returncode == 0 else "nonzero process exit"
        )
    except subprocess.TimeoutExpired:
        return dict(id=case_id, script=script, source=source, status="FAIL",
                    exit_code=None, elapsed_ms=int((time.monotonic() - start) * 1000),
                    output_sha256=None, reason="timeout (240 seconds)")
    except OSError as exc:
        return dict(id=case_id, script=script, source=source, status="NOT_TESTED",
                    exit_code=None, elapsed_ms=int((time.monotonic() - start) * 1000),
                    output_sha256=None, reason=f"execution unavailable: {type(exc).__name__}")


def fake_pass_report(sha, source):
    return {
        "schema": SCHEMA, "checkout_sha": sha, "source": source,
        "cases": [
            dict(id=case_id, script=script, source=source, status="PASS",
                 exit_code=0, elapsed_ms=1, output_sha256="0" * 64)
            for case_id, script in CASES
        ]
    }


def selftest():
    """Mutated evidence examples, NOT production code mutation testing."""
    sha = "a" * 40
    valid = fake_pass_report(sha, SOURCE_LOCAL)
    assert not verify(valid, sha, SOURCE_LOCAL)
    mutations = []
    v = copy.deepcopy(valid); v["cases"][0]["status"] = "NOT_TESTED"; mutations.append(v)
    v = copy.deepcopy(valid); v["cases"][0]["status"] = "SKIPPED"; mutations.append(v)
    v = copy.deepcopy(valid); v["cases"][1]["exit_code"] = None; mutations.append(v)
    v = copy.deepcopy(valid); v["cases"].pop(); mutations.append(v)
    v = copy.deepcopy(valid); v["cases"][0]["id"] = "fake-test"; mutations.append(v)
    v = copy.deepcopy(valid); v["cases"][0]["source"] = "PHYSICAL_ROUTER"; mutations.append(v)
    v = copy.deepcopy(valid); v["checkout_sha"] = "b" * 40; mutations.append(v)
    v = copy.deepcopy(valid); v["cases"][0]["output_sha256"] = None; mutations.append(v)
    v = copy.deepcopy(valid); v["cases"][0]["exit_code"] = True; mutations.append(v)
    for n, item in enumerate(mutations, 1):
        if not verify(item, sha, SOURCE_LOCAL):
            raise AssertionError(f"negative evidence mutation {n} escaped")
    print(f"PASS: evidence policy refuses {len(mutations)} negative mutations")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["selftest", "run"])
    parser.add_argument("--report", type=Path, help="write secret-free JSON evidence")
    args = parser.parse_args()
    if args.mode == "selftest":
        selftest()
        return 0
    sha = checkout_sha()
    is_ci = os.environ.get("GITHUB_ACTIONS", "").lower() == "true"
    source = SOURCE_CI if is_ci else SOURCE_LOCAL
    report = {
        "schema": SCHEMA,
        "checkout_sha": sha,
        "pr_head_sha": os.environ.get("KAS_PR_HEAD_SHA", ""),
        "github_sha": os.environ.get("GITHUB_SHA", ""),
        "run_id": os.environ.get("GITHUB_RUN_ID", ""),
        "observed_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "source": source,
        "evidence_scope": "mock regression in CI Linux" if is_ci else "local mock regression",
        "field_status": "NOT_TESTED",
        "emulator_status": "NOT_TESTED",
        "cases": [],
    }
    for case_id, script in CASES:
        row = run_one(case_id, script, source)
        report["cases"].append(row)
        print(f'{row["status"]}: {case_id} ({row["reason"]})', flush=True)
    issues = verify(report, sha, source)
    if is_ci and (not os.environ.get("GITHUB_SHA") or os.environ["GITHUB_SHA"] != sha):
        issues.append("GitHub checked-out SHA does not match GITHUB_SHA")
    if checkout_sha() != sha:
        issues.append("checkout changed during verification")
    report["overall"] = "PASS" if not issues else "BLOCKED"
    report["gate_findings"] = issues
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    for issue in issues:
        print(f"BLOCKED: {issue}", file=sys.stderr)
    print(f'INDEPENDENT VERIFICATION: {report["overall"]} (source={source}, checkout={sha})')
    return 0 if not issues else 1


if __name__ == "__main__":
    sys.exit(main())
