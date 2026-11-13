#!/usr/bin/env python3
"""MUT-KAS — targeted production mutation testing on verbatim lab copies.

For every mutant: (1) prove the independent oracle PASSES on the pristine
source, (2) apply ONE precise textual mutation to a lab copy, (3) prove the
same oracle FAILS on the mutant (mutation killed). The git worktree and the
checkout are never modified; everything runs inside a mktemp lab.

Anchors are hard-checked for uniqueness: an ambiguous or drifted anchor is
BLOCKED, never silently skipped. A surviving mutant is reported as FAIL
(the oracle needs improvement; the assertion is never weakened to pass).

This is evidence for exactly these five scenarios, NOT full mutation
coverage. FIELD/EMULATOR remain NOT_TESTED.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

# tests/qa-independent/mutation-kas.py -> repo root is two levels up.
ROOT = Path(__file__).resolve().parents[2]
QA = ROOT / "tests" / "qa-independent"

# Digest constant used by every production resolver copy; the lab pins it to
# the fixture digest, and MUT-WD-3 disables the comparison on that pinned copy.
PROD_DIGEST = "06ba8f6abe78a3b109d2037c902d826085d5a4814cf4b4aca0d135b22a7b86d9"

MUTANTS = [
    {
        "id": "MUT-WD-1/wan-down-gate-removed",
        "source": "mihomo-watchdog.sh",
        "oracle": "bb-watchdog-wan.sh",
        "only": "BB-WD-1/watchdog-wan-down-no-restart",
        "description": "watchdog no longer exits after a confirmed WAN failure; the run falls through to service checks",
        "find": '    run_diag_wan\n    exit 0\nfi',
        "replace": '    run_diag_wan\n    : # MUTANT: WAN failure no longer stops the run\nfi',
    },
    {
        "id": "MUT-WD-2/restart-cooldown-removed",
        "source": "mihomo-watchdog.sh",
        "oracle": "fi-watchdog-restarts.sh",
        "only": "FI-WD-1/restart-rate-limit-no-loop",
        "description": "restart rate limiting disabled (MIN_RESTART_INTERVAL 300 -> 0); repeated cron runs restart every time",
        "find": "MIN_RESTART_INTERVAL=300",
        "replace": "MIN_RESTART_INTERVAL=0",
    },
    {
        "id": "MUT-WD-3/init-digest-guard-disabled",
        "source": "mihomo-watchdog.sh",
        "oracle": "fi-watchdog-restarts.sh",
        "only": "FI-WD-3/unverified-init-digest-skip",
        "description": "init digest verification disabled: any init script is accepted for a restart",
        "find": 'MIHOMO_INIT_STATE="unverified:$_mir_found"\n            return 2',
        "replace": ': # MUTANT: unverified-init branch disabled\n            return 0',
    },
    {
        "id": "MUT-MT-1/stopped-reported-as-unknown",
        "source": "install.sh",
        "oracle": "bb-mt-opkg-gate.sh",
        "only": "BB-MT-1/mt-stopped-at-opkg-success",
        "description": "installer gate stops distinguishing proven-stopped from unknown; STOPPED/ASYNC warnings vanish",
        "find": '[ "$_mt_state" -eq 1 ]',
        "replace": '[ "$_mt_state" -eq 99 ]',
    },
    {
        "id": "MUT-TUN-1/rollback-restore-skipped",
        "source": "migrate-mihomo-tun.sh",
        "oracle": "fi-tun-rollback.sh",
        "only": "FI-TUN-2/sigterm-after-atomic-commit",
        "description": "rollback no longer restores the user YAML after an interrupted commit; recovery is faked as done",
        "find": 'mv -f "$ROLLBACK_STAGE" "$CONFIG" || return 1',
        "replace": ': # MUTANT: rollback restore skipped\n    return 0',
    },
]


def run_case(oracle, only, mutant_path, lab):
    env = dict(os.environ)
    env["KAS_QA_ONLY"] = only
    env["KAS_QA_SHELLS"] = env.get("KAS_QA_MUT_SHELLS", "dash,busybox")
    if mutant_path is not None:
        env["KAS_QA_MUTANT"] = str(mutant_path)
    else:
        env.pop("KAS_QA_MUTANT", None)
    start = time.monotonic()
    proc = subprocess.run(
        ["/bin/sh", str(QA / oracle)],
        cwd=str(ROOT), env=env, capture_output=True, text=True, timeout=600,
    )
    # A nonzero exit is *not* proof that the named oracle caught a mutant.
    # Require the exact CASE and FAIL assertion markers emitted by qa_case/qa_fail.
    stdout_lines = [line.strip() for line in proc.stdout.splitlines()]
    return {
        "exit_code": proc.returncode,
        "elapsed_s": round(time.monotonic() - start, 2),
        "case_seen": f"CASE {only}" in stdout_lines,
        "pass_seen": f"PASS {only}" in stdout_lines,
        "fail_seen": any(line.startswith(f"FAIL {only}:") for line in stdout_lines),
        "tail": (proc.stdout + ("\n--stderr--\n" + proc.stderr if proc.stderr else "")).strip().splitlines()[-12:],
    }


def is_targeted_kill(mut):
    """Only a deliberate failure of the named assertion counts as killed."""
    return (
        mut.get("exit_code") == 1
        and mut.get("case_seen") is True
        and mut.get("fail_seen") is True
        and mut.get("pass_seen") is False
    )


def main():
    report = {
        "schema": "kas-qa-mutation/v1",
        # The worktree's .git pointer may be Windows-only, so the launcher
        # passes the exact SHA via KAS_QA_COMMIT_SHA; git is only a fallback.
        "checkout_sha": os.environ.get("KAS_QA_COMMIT_SHA")
        or subprocess.run(["git", "rev-parse", "HEAD"], cwd=str(ROOT),
                          text=True, capture_output=True).stdout.strip()
        or "UNKNOWN",
        "scope": "five targeted production mutants on verbatim lab copies",
        "attestation_note": (
            "Executed by the same author that wrote the oracles; not a "
            "cryptographic attestation. A killed mutant proves this specific "
            "oracle detects this specific production change; surviving or "
            "blocked mutants are reported honestly."),
        "field_status": "NOT_TESTED",
        "emulator_status": "NOT_TESTED",
        "mutants": [],
        "overall": "PASS",
        "gate_findings": [],
    }
    failures = []
    with tempfile.TemporaryDirectory(prefix="kas-mutation-") as work:
        for m in MUTANTS:
            row = {"id": m["id"], "description": m["description"],
                   "source": m["source"], "oracle": m["oracle"],
                   "target_case": m["only"], "status": "PASS"}
            try:
                pristine_text = (ROOT / m["source"]).read_text(encoding="utf-8")
            except OSError as exc:
                row["status"] = "BLOCKED"; row["reason"] = f"source unreadable: {exc}"
                report["mutants"].append(row); failures.append(m["id"])
                print(f"BLOCKED: {m['id']} ({row['reason']})", flush=True)
                continue

            # Baseline: pristine verbatim copy through the same oracle.
            pristine = Path(work) / f"{m['id'].split('/')[0]}.pristine"
            pristine.write_text(pristine_text, encoding="utf-8", newline="\n")
            try:
                base = run_case(m["oracle"], m["only"], pristine, work)
            except subprocess.TimeoutExpired:
                row["status"] = "BLOCKED"; row["reason"] = "baseline oracle timed out"
                report["mutants"].append(row); failures.append(m["id"])
                print(f"BLOCKED: {m['id']} ({row['reason']})", flush=True)
                continue
            row["baseline"] = base
            if not (base["exit_code"] == 0 and base["case_seen"]
                    and base["pass_seen"] and not base["fail_seen"]):
                row["status"] = "BLOCKED"
                row["reason"] = "oracle did not PASS on the pristine source"
                row["baseline_tail"] = base["tail"]
                report["mutants"].append(row); failures.append(m["id"])
                print(f"BLOCKED: {m['id']} ({row['reason']})", flush=True)
                continue

            # Mutant: one precise textual change, uniqueness hard-checked.
            n = pristine_text.count(m["find"])
            if n != 1:
                row["status"] = "BLOCKED"
                row["reason"] = f"mutation anchor not unique (found {n})"
                report["mutants"].append(row); failures.append(m["id"])
                print(f"BLOCKED: {m['id']} ({row['reason']})", flush=True)
                continue
            mutated = Path(work) / f"{m['id'].split('/')[0]}.mutant"
            mutated.write_text(pristine_text.replace(m["find"], m["replace"], 1),
                               encoding="utf-8", newline="\n")
            try:
                mut = run_case(m["oracle"], m["only"], mutated, work)
            except subprocess.TimeoutExpired:
                row["status"] = "BLOCKED"
                row["reason"] = "mutant oracle timed out: target assertion not observed"
                row["killed"] = False
                report["mutants"].append(row); failures.append(m["id"])
                print(f"BLOCKED: {m['id']} ({row['reason']})", flush=True)
                continue
            row["mutant"] = mut
            row["killed"] = is_targeted_kill(mut)
            if not row["killed"]:
                row["status"] = "FAIL"
                row["reason"] = (
                    "mutant did not trigger the named qa_fail assertion "
                    "(survived, syntax error or unrelated infrastructure failure)")
                failures.append(m["id"])
            report["mutants"].append(row)
            print(f"{row['status']}: {m['id']} killed={row.get('killed')}", flush=True)

    if not re.fullmatch(r"[0-9a-f]{40}", report["checkout_sha"]):
        report["overall"] = "BLOCKED"
        report["gate_findings"].append(
            "checkout SHA unavailable: evidence cannot be bound to an exact commit")
        failures = failures or ["checkout-sha-unavailable"]
    if failures:
        report["overall"] = report["overall"] if report["overall"] == "BLOCKED" else "FAIL"
        report["gate_findings"] = [f"mutation not killed or blocked: {i}" for i in failures]
    out_path = os.environ.get("KAS_QA_MUT_REPORT", "")
    if out_path:
        out = Path(out_path)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n",
                       encoding="utf-8")
    print(f"MUTATION OVERALL: {report['overall']}")
    if report["overall"] == "PASS":
        return 0
    # 2 lets run-all.sh distinguish BLOCKED (missing preconditions) from FAIL.
    return 2 if report["overall"] == "BLOCKED" else 1


if __name__ == "__main__":
    sys.exit(main())
