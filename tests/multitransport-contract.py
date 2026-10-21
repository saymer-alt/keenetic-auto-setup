#!/usr/bin/env python3
"""MT-002: offline validator for MultiTransport provider contract v0.

Reproducible local checks (PR #175 schemas + fixtures) — no network, no
/proc, no processes, no signals, no real WDTT binaries. Synthetic data only.

Usage:
    python tests/multitransport-contract.py [--mt-dir DIR] [--now ISO8601]

--now sets the deterministic "time of check" used ONLY by the freshness
(STALE) rules; the default is a fixed constant so results are reproducible.
A stale JSON can still be schema-valid: schema validity and semantic
freshness are reported separately.

Dependency (not auto-installed):  pip install "jsonschema>=4.21,<5"

Exit codes: 0 = all checks passed, 1 = at least one FAIL, 2 = missing
dependency or broken invocation.
"""

import argparse
import datetime
import json
import sys
from pathlib import Path

try:
    from jsonschema import Draft202012Validator
except ImportError:  # pragma: no cover
    print("FAIL missing dependency: pip install \"jsonschema>=4.21,<5\" (Draft 2020-12 support required)")
    sys.exit(2)

DEFAULT_NOW = "2026-10-21T12:00:00Z"  # deterministic; fixtures are set around it
SCHEMAS = ["provider-v0", "status-v0", "acceptance-v0"]
# valid-fixture name -> schema key
VALID_MAP = {
    "wdtt-manifest": "provider-v0",
    "openflux-manifest": "provider-v0",
    "wdtt-status": "status-v0",
    "status-udp-unsupported": "status-v0",
    "status-udp-not-tested": "status-v0",
    "status-tcp-fail": "status-v0",
    "status-stale": "status-v0",
    "wdtt-acceptance": "acceptance-v0",
}
CAP_FOR_TEST_TYPE = {"TCP_E2E": "socks_tcp", "UDP_E2E": "socks_udp"}
READY_EGRESS = {"TCP_E2E_READY", "UDP_E2E_READY"}

results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok), detail))
    print(("PASS " if ok else "FAIL ") + name + (f" — {detail}" if detail and not ok else ""))


def load(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def parse_ts(value):
    return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))


def is_stale(status, now):
    return parse_ts(status["observed_at"]) + datetime.timedelta(
        seconds=status["freshness_ttl_sec"]
    ) < now


def cross_file_errors(manifest, status, acceptance):
    """Return list of human-readable violations for one provider bundle."""
    errs = []
    mcap = manifest.get("capabilities", {})
    if status:
        if status.get("provider_id") != manifest["provider_id"]:
            errs.append("status.provider_id != manifest.provider_id")
        if status.get("state") == "running" and not status.get("pid_verified"):
            errs.append("state=running without pid_verified=true")
        udp_build = mcap.get("socks_udp", {}).get("build")
        if status.get("udp_e2e") == "PASS" and udp_build != "PRESENT":
            errs.append("udp_e2e=PASS but socks_udp.build != PRESENT")
        if status.get("udp_e2e") == "UNSUPPORTED" and udp_build != "ABSENT":
            errs.append("udp_e2e=UNSUPPORTED requires socks_udp.build=ABSENT (not UNKNOWN/other)")
        if status.get("egress") in READY_EGRESS:
            axis = "tcp_e2e" if status["egress"] == "TCP_E2E_READY" else "udp_e2e"
            if status.get(axis) != "PASS":
                errs.append(f"egress={status['egress']} requires {axis}=PASS")
    if acceptance:
        if acceptance.get("provider_id") != manifest["provider_id"]:
            errs.append("acceptance.provider_id != manifest.provider_id")
        if acceptance.get("artifact_sha256") != manifest.get("artifact_provenance", {}).get("sha256"):
            errs.append("acceptance.artifact_sha256 != manifest artifact sha256")
        if acceptance.get("result") == "PASS":
            cap = CAP_FOR_TEST_TYPE.get(acceptance.get("test_type"))
            build = mcap.get(cap, {}).get("build") if cap else None
            if build != "PRESENT":
                errs.append(f"acceptance PASS for {acceptance.get('test_type')} but {cap}.build != PRESENT")
    return errs


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--mt-dir", default=None, help="path to docs/research/multitransport")
    ap.add_argument("--now", default=DEFAULT_NOW, help="deterministic time of check (ISO-8601)")
    args = ap.parse_args()

    root = Path(args.mt_dir) if args.mt_dir else Path(__file__).resolve().parent.parent / "docs/research/multitransport"
    fx = root / "fixtures"
    now = parse_ts(args.now)

    # 1. Schemas must be valid Draft 2020-12 documents.
    validators = {}
    for key in SCHEMAS:
        path = root / "schemas" / f"{key}.schema.json"
        schema = load(path)
        try:
            Draft202012Validator.check_schema(schema)
            validators[key] = Draft202012Validator(schema)
            check(f"schema/{key}", True)
        except Exception as exc:  # noqa: BLE001
            check(f"schema/{key}", False, str(exc)[:200])

    def valid(doc, key):
        return not list(validators[key].iter_errors(doc))

    # 2. VALID fixtures must pass their schema.
    for name, key in VALID_MAP.items():
        path = fx / "valid" / f"{name}.json"
        try:
            errs = list(validators[key].iter_errors(load(path)))
            check(f"valid/{name}", not errs, errs[0].message[:160] if errs else "")
        except Exception as exc:  # noqa: BLE001
            check(f"valid/{name}", False, f"unreadable: {exc}"[:160])

    # 3. INVALID fixtures must be rejected.
    for path in sorted((fx / "invalid").glob("*.json")):
        key = "status-v0" if path.stem.startswith("status-") else "provider-v0"
        doc = load(path)
        errs = list(validators[key].iter_errors(doc))
        check(f"invalid/{path.stem} rejected", bool(errs), "schema ACCEPTED an invalid fixture" if not errs else "")

    # 4. Cross-file bundle rules. Bundle dir = optional manifest.json
    # (falls back to the good bundle), optional status.json, optional
    # acceptance.json. "good-*" must be clean, "bad-*" must violate >=1 rule.
    bundles = fx / "bundles"
    good_manifest = load(bundles / "good-wdtt" / "manifest.json")
    for bdir in sorted(p for p in bundles.iterdir() if p.is_dir()):
        if not (bdir.name.startswith("good-") or bdir.name.startswith("bad-")):
            continue  # freshness bundles are judged by the freshness section
        manifest = load(bdir / "manifest.json") if (bdir / "manifest.json").exists() else good_manifest
        status = load(bdir / "status.json") if (bdir / "status.json").exists() else None
        acceptance = load(bdir / "acceptance.json") if (bdir / "acceptance.json").exists() else None
        errs = cross_file_errors(manifest, status, acceptance)
        must_fail = bdir.name.startswith("bad-")
        ok = bool(errs) if must_fail else not errs
        detail = errs[0] if errs else ""
        if must_fail and not errs:
            detail = "expected a cross-file violation, bundle is clean"
        check(f"bundle/{bdir.name}", ok, detail)

    # 5. Freshness (STALE): deterministic --now; a stale status must not
    # claim ready egress or live PASS verdicts. Schema validity and
    # freshness are separate: a stale document can still be schema-valid.
    stale_dir = fx / "bundles" / "freshness-bad-stale-claim"
    for path in sorted((fx / "valid").glob("status-*.json")) + sorted(stale_dir.glob("status.json")):
        doc = load(path)
        stale = is_stale(doc, now)
        claims = doc.get("egress") in READY_EGRESS or doc.get("tcp_e2e") == "PASS" or doc.get("udp_e2e") == "PASS"
        label = path.parent.name + "/" + path.stem
        if path.parent == stale_dir:
            check(f"freshness/{label} detects stale claim", stale and claims,
                  "planted stale+claim was not detected")
        else:
            check(f"freshness/{label} no unsupported claim", not (stale and claims),
                  "fixture is stale yet claims readiness" if stale else "")

    # 6. Port-conflict detection: one bind claimed by two providers is an
    # error configuration (v0 allows a single active transport; this only
    # verifies the detector, not multiplexing support).
    binds = {}
    manifests = sorted((fx / "valid").glob("*manifest*.json"))
    manifests += sorted((fx / "bundles" / "port-conflict").glob("*manifest*.json")) if (fx / "bundles" / "port-conflict").exists() else []
    planted = None
    for path in manifests:
        doc = load(path)
        binds.setdefault(doc["inbound_bind"], []).append(doc["provider_id"])
        if path.parent.name == "port-conflict":
            planted = doc["inbound_bind"]
    conflicts = {b: ids for b, ids in binds.items() if len(set(ids)) > 1}
    check("portconflict/detector finds planted conflict", planted is not None and planted in conflicts,
          f"conflicts={conflicts}")
    check("portconflict/good set clean", all(len(v) == 1 for b, v in binds.items() if b != planted),
          "unexpected conflict outside the planted one")

    # 7. Self-loop detection on the synthetic chaining profile (NOT a v0
    # schema field; profile exists only to test the detector).
    profile_path = fx / "profiles" / "chaining-self-loop.json"
    if profile_path.exists():
        profile = load(profile_path)
        all_binds = {p["inbound_bind"] for p in profile["providers"]}
        loops = [p["id"] for p in profile["providers"]
                 if p.get("upstream") in all_binds or p.get("upstream") == p.get("inbound_bind")]
        check("selfloop/detector finds planted loop", bool(loops), f"loops={loops}")
    else:
        check("selfloop/detector finds planted loop", False, "profile fixture missing")

    failed = [name for name, ok, _ in results if not ok]
    passed = len(results) - len(failed)
    print(f"\nTOTAL: {passed} passed, {len(failed)} failed (of {len(results)} checks)")
    if failed:
        print("FAILED: " + ", ".join(failed))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
