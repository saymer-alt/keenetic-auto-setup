#!/usr/bin/env python3
"""Independent QA evidence verifier: a missing proof is never PASS.

Only synthetic local evidence. This module does not access network, devices or
GitHub. Neither env-supplied SHA nor this report is a cryptographic attestation.
"""
import re

EXPECTED_MUTANTS = {
    "MUT-WD-1/wan-down-gate-removed": "BB-WD-1/watchdog-wan-down-no-restart",
    "MUT-WD-2/restart-cooldown-removed": "FI-WD-1/restart-rate-limit-no-loop",
    "MUT-WD-3/init-digest-guard-disabled": "FI-WD-3/unverified-init-digest-skip",
    "MUT-MT-1/stopped-reported-as-unknown": "BB-MT-1/mt-stopped-at-opkg-success",
    "MUT-TUN-1/rollback-restore-skipped": "FI-TUN-2/sigterm-after-atomic-commit",
}


def validate_checkout_evidence(checkout_sha, dirty):
    findings = []
    if not isinstance(checkout_sha, str) or re.fullmatch(r"[0-9a-f]{40}", checkout_sha) is None:
        findings.append("checkout SHA missing/invalid: cannot bind evidence to a commit")
    if str(dirty) != "0":
        findings.append("worktree dirty or unknown: exact checked-out contents unproven")
    return findings


def validate_mutation_evidence(report, checkout_sha):
    """Accept five exact targeted kills, rejecting missing or forged-looking summaries."""
    findings = []
    if not isinstance(report, dict) or not report:
        return ["mutation evidence absent or invalid JSON (fail-closed)"]
    if report.get("schema") != "kas-qa-mutation/v1":
        findings.append("mutation evidence schema mismatch")
    if report.get("checkout_sha") != checkout_sha:
        findings.append("mutation evidence checkout SHA does not match launcher SHA")
    if report.get("overall") != "PASS":
        findings.append("mutation overall not PASS")
    entries = report.get("mutants")
    if not isinstance(entries, list) or len(entries) != len(EXPECTED_MUTANTS):
        return findings + ["mutation evidence missing or extra mutant rows"]
    ids = [x.get("id") if isinstance(x, dict) and isinstance(x.get("id"), str) else None
           for x in entries]
    if len(set(ids)) != len(EXPECTED_MUTANTS) or set(ids) != set(EXPECTED_MUTANTS):
        return findings + ["mutation evidence mutant IDs are missing/duplicate/unknown"]
    for row in entries:
        case_id = row["id"]
        if row.get("target_case") != EXPECTED_MUTANTS[case_id]:
            findings.append(f"{case_id}: target case mismatch")
        if row.get("status") != "PASS" or row.get("killed") is not True:
            findings.append(f"{case_id}: no PASS targeted kill")
        pristine = row.get("baseline")
        mutant = row.get("mutant")
        if not isinstance(pristine, dict) or not (
            pristine.get("exit_code") == 0 and pristine.get("case_seen") is True
            and pristine.get("pass_seen") is True and pristine.get("fail_seen") is False
        ):
            findings.append(f"{case_id}: pristine oracle did not prove target PASS")
        if not isinstance(mutant, dict) or not (
            mutant.get("exit_code") == 1 and mutant.get("case_seen") is True
            and mutant.get("fail_seen") is True and mutant.get("pass_seen") is False
        ):
            findings.append(f"{case_id}: mutated oracle did not prove target FAIL")
    return findings
