#!/bin/sh
# run-all.sh — independent offline KAS quality-assurance launcher.
#
# Runs every suite of tests/qa-independent/ offline inside ONE invocation and
# aggregates a fail-closed machine-readable report. No network, no router, no
# Docker; labs live in mktemp scratch and are always cleaned.
#
# Usage: sh run-all.sh [--out-dir DIR]
# Exit code: 0 all suites PASS; 1 any FAIL/BLOCKED (missing proof is never
# success). FIELD and EMULATOR are NOT_TESTED by design at this SHA.

set -u

QA_SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
REPO_ROOT=$(CDPATH= cd -- "$QA_SELF_DIR/../.." && pwd -P)

OUT_DIR=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --out-dir) OUT_DIR=$2; shift 2 ;;
        *) echo "usage: $0 [--out-dir DIR]" >&2; exit 2 ;;
    esac
done

# Worktree .git pointers can be Windows-only; the launcher passes the
# exact values via KAS_QA_COMMIT_SHA / KAS_QA_DIRTY when git is unavailable.
CHECKOUT_SHA=${KAS_QA_COMMIT_SHA:-$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "UNKNOWN")}
if [ "${KAS_QA_DIRTY+x}" = x ]; then
    DIRTY=$KAS_QA_DIRTY
elif _git_status=$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null); then
    DIRTY=$(printf '%s\n' "$_git_status" | sed '/^$/d' | wc -l | tr -d ' ')
else
    DIRTY=UNKNOWN
fi

echo "KAS QA-INDEPENDENT RUN"
echo "  checkout: $CHECKOUT_SHA"
echo "  dirty entries in worktree: $DIRTY"
echo "  date (UTC): $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo

RESULTS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kas-qa-runall.XXXXXX")
trap 'rm -rf "$RESULTS_DIR"' EXIT INT TERM

run_suite() {
    # run_suite <id> <shell-cmd...>
    _id=$1
    shift
    echo "=== SUITE $_id"
    _log="$RESULTS_DIR/$_id.log"
    _start=$(date +%s)
    if "$@" > "$_log" 2>&1; then
        _status=PASS
    else
        _rc=$?
        # 2 = BLOCKED (the suites use exit 2 for missing preconditions)
        [ "$_rc" -eq 2 ] && _status=BLOCKED || _status=FAIL
    fi
    _end=$(date +%s)
    echo "$_status" > "$RESULTS_DIR/$_id.status"
    echo "$((_end - _start))" > "$RESULTS_DIR/$_id.secs"
    grep -E '^(CASE|PASS|FAIL|BLOCKED|ALL-PASS|  \.\.)' "$_log" | head -60
    echo "=== SUITE $_id -> $_status ($((_end - _start))s)"
    echo
}

run_suite bb-mt-opkg-gate        /bin/sh "$QA_SELF_DIR/bb-mt-opkg-gate.sh"
run_suite bb-watchdog-wan        /bin/sh "$QA_SELF_DIR/bb-watchdog-wan.sh"
run_suite fi-watchdog-restarts   /bin/sh "$QA_SELF_DIR/fi-watchdog-restarts.sh"
run_suite fi-tun-rollback        /bin/sh "$QA_SELF_DIR/fi-tun-rollback.sh"
# The mutation suite writes its detailed JSON where the aggregator reads it.
KAS_QA_MUT_REPORT="$RESULTS_DIR/mutation-kas.json"
export KAS_QA_MUT_REPORT
run_suite mutation-kas         python3 "$QA_SELF_DIR/mutation-kas.py"
unset KAS_QA_MUT_REPORT

python3 - "$REPO_ROOT" "$RESULTS_DIR" "$CHECKOUT_SHA" "$DIRTY" "$OUT_DIR" <<'PYAGG'
import datetime
import json
import platform
import subprocess
import sys
from pathlib import Path

repo, results, checkout_sha, dirty, out_dir = sys.argv[1:6]
results = Path(results)
sys.path.insert(0, str(Path(repo) / "tests" / "qa-independent"))
from evidence_gate import validate_checkout_evidence, validate_mutation_evidence

SUITES = [
    ("bb-mt-opkg-gate", "black-box", "tests/qa-independent/bb-mt-opkg-gate.sh"),
    ("bb-watchdog-wan", "black-box", "tests/qa-independent/bb-watchdog-wan.sh"),
    ("fi-watchdog-restarts", "fault-injection", "tests/qa-independent/fi-watchdog-restarts.sh"),
    ("fi-tun-rollback", "black-box+fault-injection", "tests/qa-independent/fi-tun-rollback.sh"),
    ("mutation-kas", "mutation", "tests/qa-independent/mutation-kas.py"),
]

def shells():
    found = {}
    for name, probe in (("dash", ["/usr/bin/dash", "--version"]),
                        ("busybox", ["/usr/bin/busybox", "true"]),
                        ("bash", ["/usr/bin/bash", "--version"])):
        try:
            subprocess.run(probe, capture_output=True, timeout=10)
            found[name] = True
        except OSError:
            found[name] = False
    return found

mutation_report = {}
mdet = results / "mutation-kas.json"
if mdet.exists():
    try:
        mutation_report = json.loads(mdet.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        mutation_report = {}

cases = []
for suite_id, kind, script in SUITES:
    status_file = results / f"{suite_id}.status"
    status = status_file.read_text().strip() if status_file.exists() else "NOT_TESTED"
    secs = results / f"{suite_id}.secs"
    cases.append({
        "id": suite_id,
        "kind": kind,
        "script": script,
        "source": "LOCAL_MOCK",
        "status": status,
        "exit_code": {"PASS": 0, "BLOCKED": 2}.get(status),
        "elapsed_s": int(secs.read_text().strip()) if secs.exists() else None,
    })

findings = [f"suite {c['id']}: {c['status']}" for c in cases if c["status"] != "PASS"]
findings.extend(validate_checkout_evidence(checkout_sha, dirty))
findings.extend(validate_mutation_evidence(mutation_report, checkout_sha))
overall = "PASS" if not findings else ("BLOCKED" if all(c["status"] in ("BLOCKED", "NOT_TESTED") for c in cases)
                                           and all(c["status"] != "PASS" for c in cases) else "FAIL")

report = {
    "schema": "kas-qa-independent/v1",
    "checkout_sha": checkout_sha,
    "worktree_dirty_entries": int(dirty) if dirty.isdigit() else -1,
    "observed_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "environment": {
        "platform": platform.platform(),
        "kernel": platform.release(),
        "shells": shells(),
        "network": "none (offline lab, PATH shims only)",
        "router": "none",
    },
    "source": "LOCAL_MOCK",
    "ci_linux_mock": "RUNNING" if __import__("os").environ.get("GITHUB_ACTIONS") == "true" else "NOT_RUN",
    "emulator_status": "NOT_TESTED",
    "field_status": "NOT_TESTED",
    "scope_note": (
        "Offline mock checks of installer, Watchdog, TUN rollback and "
        "mutation oracles; no real router or firmware is tested. "
        "Results are not a cryptographic attestation."),
    "cases": cases,
    "mutation_overall": mutation_report.get("overall", "UNKNOWN"),
    "mutation_details": mutation_report,
    "overall": overall,
    "gate_findings": findings,
}

print(json.dumps({k: report[k] for k in
                  ("schema", "checkout_sha", "overall", "mutation_overall")}, indent=2))
for c in cases:
    print(f"  {c['status']}: {c['id']} ({c['kind']}, {c['elapsed_s']}s)")

if str(out_dir):
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    (out / "REPORT.json").write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    lines = [
        "# KAS — independent offline QA report",
        "",
        f"- checkout: `{checkout_sha}` (worktree dirty entries: {dirty})",
        f"- observed: {report['observed_utc']}",
        f"- source: LOCAL_MOCK (WSL2 Linux, offline); CI_LINUX_MOCK={report['ci_linux_mock']}, EMULATOR=NOT_TESTED, FIELD=NOT_TESTED",
        "",
        "| suite | kind | status | elapsed s |",
        "| --- | --- | --- | --- |",
    ]
    for c in cases:
        lines.append(f"| {c['id']} | {c['kind']} | {c['status']} | {c['elapsed_s']} |")
    lines += ["", f"- mutation overall: {report['mutation_overall']}",
              f"- run overall: **{overall}**",
              "", report["scope_note"], ""]
    (out / "REPORT.md").write_text("\n".join(lines), encoding="utf-8")
    print(f"report written to {out}/REPORT.json and REPORT.md")

sys.exit(0 if overall == "PASS" else 1)
PYAGG
