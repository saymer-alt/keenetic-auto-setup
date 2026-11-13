#!/usr/bin/env python3
"""Offline digest-gate oracle for the native E2E Entware lock pins.

Why this exists
---------------
The native E2E guest bootstrap fetches every artifact through
``lab/build_entware.py::fetch()`` from the public router-emulator, pinned at
an ``emulator_ref``. When upstream re-published the aarch64-k3.10 set on
2026-11-06/09, the pinned digests became unfetchable and each E2E died with
``ValueError: download digest mismatch`` — the first pinned artifact, the
installer archive, already mismatched (expected ``aa2e5850…``, observed
``50f0ead4…``). The re-pin itself ships separately (as a separate reviewed update);
this oracle is the independent diagnostic:

  - it pins the FAIL-CLOSED semantics of the digest gate as an executable
    contract, using synthetic payloads and an isolated scratch — no network,
    no QEMU, no real artifacts;
  - it demonstrates the negative case the CI hit: an old (stale) lock record
    REJECTS fresh official bytes with exactly ``ValueError("download digest
    mismatch")`` and persists nothing;
  - it distinguishes transport failures (404/503) from actually-changed bytes;
  - it pins the mirror-index composition crash on a null field (the
    ``build()`` join concatenates ``k + ": " + v``, so absent keys must stay
    absent — regression for an override that emitted ``"Depends": null``).

Evidence schema (one record per scenario)::

    {"artifact", "exact_sha", "expected", "observed", "stage",
     "reason", "status"}   (+ optional provenance extras)

Statuses: ``REJECTED`` (gate refused, fail-closed as required),
``ACCEPTED`` (pinned bytes passed), ``ERROR_TRANSPORT`` (transport error
surfaced without any digest confusion). Non-secret data only.

Modes
-----
Default (no arguments): fully offline, faithful model of the pinned
``fetch()`` + ``build()`` index composition.

``--lab-source DIR``: additionally cross-check the model against the REAL
pinned implementation by importing ``<DIR>/build_entware.py`` and running the
same scenarios through its actual ``fetch()`` with the transport monkeypatched
(offline; sleeps neutralised). Point ``DIR`` at a read-only router-emulator
checkout at the pinned ``emulator_ref``. This mode runs only on the CLI, never
inside the default unit tests.

Run: ``python tests/ci-native-lock-diagnostics/oracle_digest_gate.py``
(writes ``evidence.json`` into an isolated scratch and prints the verdict).
"""
import argparse
import hashlib
import importlib.util
import json
import sys
import tempfile
import time
import urllib.error
from pathlib import Path

OFFICIAL_PREFIX = "https://bin.entware.net/aarch64-k3.10/"
FIXTURE = Path(__file__).with_name("fixtures") / "lab_lock_records_20261110.json"
REQUIRED_FIELDS = ("artifact", "exact_sha", "expected", "observed", "stage", "reason", "status")
SECRET_MARKERS = ("password", "passwd=", "token", "secret", "192.168.", "ssh-rsa",
                  "ssh-ed25519", "BEGIN OPENSSH", "dropbear_")

EVIDENCE_FIELDS = "exact-SHA, expected, observed, stage, reason, status"


class TransportHTTPError(Exception):
    """Stand-in for urllib.error.HTTPError inside the model."""

    def __init__(self, code):
        super().__init__(f"HTTP {code}")
        self.code = code


class GateDidNotRaise(Exception):
    """Recorded when a gate returns instead of raising — fail-open, verdict FAIL."""

    def __str__(self):
        return "gate did not raise — fail-open"


class FakeTransport:
    """Scripted transport: each call consumes the next behaviour."""

    def __init__(self, script):
        self.script = list(script)
        self.calls = []

    def __call__(self, url):
        self.calls.append(url)
        if not self.script:
            raise AssertionError("transport script exhausted — unexpected extra call")
        behaviour = self.script.pop(0)
        if isinstance(behaviour, TransportHTTPError):
            raise behaviour
        if isinstance(behaviour, int):  # bare HTTP status
            raise TransportHTTPError(behaviour)
        return behaviour


def noop_sleep(_seconds):
    return None


def gate_fetch(url, digest, destination, transport, sleep=noop_sleep):
    """Faithful model of the pinned lab fetch() digest gate.

    Transcribed from lab/build_entware.py at emulator_ref
    9e59e0bff1319acbd191867dac1f5ace2df0655f (blob 4536e134…): origin check
    first, bounded retries for 502/503/504 only, digest check BEFORE the
    destination is written, and a re-verification of any pre-existing cache
    entry (symlinked or byte-changed cache is rejected too).
    """
    destination = Path(destination)
    if not url.startswith(OFFICIAL_PREFIX):
        raise ValueError("unexpected bootstrap origin")
    if not destination.exists():
        data = None
        for attempt in (1, 2, 3, 4, 5):
            try:
                data = transport(url)
                break
            except TransportHTTPError as error:
                if attempt == 5 or error.code not in (502, 503, 504):
                    raise
                sleep(min(15, 3 * attempt))
        if hashlib.sha256(data).hexdigest() != digest:
            raise ValueError("download digest mismatch")
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(data)
    if destination.is_symlink() or hashlib.sha256(destination.read_bytes()).hexdigest() != digest:
        raise ValueError("cached asset digest mismatch")
    return destination


def compose_index_block(package):
    """Faithful model of build()/add_packages() mirror index composition.

    The lab joins every remaining field as ``k + ": " + v`` — a null value
    must crash loudly (TypeError), so override locks keep absent keys absent.
    """
    return "\n".join(k + ": " + v for k, v in package.items() if k not in ("feed", "url"))


def _record(artifact, expected, observed, stage, reason, status, **extra):
    record = {"artifact": artifact, "exact_sha": expected, "expected": expected,
              "observed": observed, "stage": stage, "reason": reason, "status": status}
    record.update(extra)
    return record


def _digest(data):
    return hashlib.sha256(data).hexdigest()


def run_scenarios(scratch, fixture_path=FIXTURE):
    """Run every scenario; return (evidence dict, scratch Path). Isolated, offline."""
    scratch = Path(scratch)
    fixture = json.loads(Path(fixture_path).read_text(encoding="utf8"))
    stale_record = fixture["upstream_installer_record"]
    scenarios = []

    def expect(scenario, payload):
        destination = scratch / scenario / "cache" / stale_record["artifact"]
        try:
            payload()
        except Exception as error:  # the gate MUST raise; classified by the scenario
            return error, destination
        return GateDidNotRaise(), destination

    # S1 — the negative case CI hit: old lock record rejects fresh bytes.
    payload = b"kas-oracle synthetic installer bytes (not the real artifact)\n"
    transport = FakeTransport([payload])
    scenario = "s1_old_lock_rejects_new_bytes"
    s1_destination = scratch / scenario / "cache" / stale_record["artifact"]
    error, destination = expect(scenario,
                                lambda: gate_fetch(stale_record["url"], stale_record["sha256"],
                                                   s1_destination, transport))
    scenarios.append({
        "name": scenario,
        "contract": "a stale pinned digest must reject fresh official bytes with "
                    "`ValueError('download digest mismatch')` and persist nothing",
        "evidence": _record(stale_record["artifact"], stale_record["sha256"],
                            _digest(payload), "fetch", str(error),
                            "REJECTED" if "download digest mismatch" in str(error)
                            and not destination.exists() else "ORACLE_FAIL",
                            transport_calls=len(transport.calls)),
    })

    # S2 — accept path: a digest matching the payload passes and persists.
    payload_ok = b"kas-oracle synthetic payload whose digest is the pin\n"
    pin = _digest(payload_ok)
    scenario = "s2_repin_accepts_pinned_bytes"
    destination = scratch / scenario / "cache" / "synthetic.tar.gz"
    accepted = None
    error2 = None
    try:
        accepted = gate_fetch(OFFICIAL_PREFIX + "synthetic.tar.gz", pin, destination, FakeTransport([payload_ok]))
    except Exception as err:  # noqa: BLE001
        error2 = err
    scenarios.append({
        "name": scenario,
        "contract": "bytes whose digest equals the pin are accepted and cached",
        "evidence": _record("synthetic.tar.gz", pin, _digest(payload_ok), "fetch",
                            "digest match (accept path demonstrated offline)",
                            "ACCEPTED" if accepted is not None and destination.exists()
                            and destination.read_bytes() == payload_ok else "ORACLE_FAIL",
                            persisted=bool(destination.exists())),
    })

    # S3 — non-official origin is rejected before any download.
    scenario = "s3_non_official_origin_rejected"
    evil_url = "https://example.invalid/aarch64-k3.10/synthetic.tar.gz"
    transport = FakeTransport([payload_ok])  # must never be consumed
    destination = scratch / scenario / "cache" / "synthetic.tar.gz"
    error3 = None
    try:
        gate_fetch(evil_url, pin, destination, transport)
    except Exception as err:  # noqa: BLE001
        error3 = err
    scenarios.append({
        "name": scenario,
        "contract": "an off-origin URL is refused without any network access",
        "evidence": _record("synthetic.tar.gz", pin, "n/a (no bytes fetched)", "fetch",
                            str(error3),
                            "REJECTED" if "unexpected bootstrap origin" in str(error3)
                            and not transport.calls and not destination.exists() else "ORACLE_FAIL",
                            transport_calls=len(transport.calls)),
    })

    # S4 — a tampered pre-existing cache entry is rejected without network.
    scenario = "s4_tampered_cache_rejected"
    destination = scratch / scenario / "cache" / "synthetic.tar.gz"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(b"tampered cache bytes\n")
    transport = FakeTransport([payload_ok])
    error4 = None
    try:
        gate_fetch(OFFICIAL_PREFIX + "synthetic.tar.gz", pin, destination, transport)
    except Exception as err:  # noqa: BLE001
        error4 = err
    scenarios.append({
        "name": scenario,
        "contract": "a cached file whose bytes no longer match the pin is refused",
        "evidence": _record("synthetic.tar.gz", pin, _digest(b"tampered cache bytes\n"),
                            "fetch", str(error4),
                            "REJECTED" if "cached asset digest mismatch" in str(error4)
                            and not transport.calls else "ORACLE_FAIL",
                            transport_calls=len(transport.calls)),
    })

    # S5 — transport failures stay transport failures; retries stay bounded.
    scenario = "s5_transport_vs_digest"
    destination = scratch / scenario / "cache503" / "synthetic.tar.gz"
    transport = FakeTransport([503, 503, payload])  # two retries, then mismatched bytes
    error5a = None
    try:
        gate_fetch(OFFICIAL_PREFIX + "synthetic.tar.gz", pin, destination, transport)
    except Exception as err:  # noqa: BLE001
        error5a = err
    record_503 = _record("synthetic.tar.gz", pin, _digest(payload), "fetch", str(error5a),
                         "REJECTED" if "download digest mismatch" in str(error5a) else "ORACLE_FAIL",
                         attempts=len(transport.calls))
    transport404 = FakeTransport([404])
    error5b = None
    try:
        gate_fetch(OFFICIAL_PREFIX + "synthetic.tar.gz", pin,
                   scratch / scenario / "cache404" / "synthetic.tar.gz", transport404)
    except TransportHTTPError as err:
        error5b = err
    record_404 = _record("synthetic.tar.gz", pin, "n/a (HTTP 404)", "fetch",
                         f"TransportHTTPError: {error5b}",
                         "ERROR_TRANSPORT" if getattr(error5b, "code", None) == 404 else "ORACLE_FAIL",
                         attempts=len(transport404.calls))
    scenarios.append({
        "name": scenario,
        "contract": "502/503/504 retry bounded, then the digest gate still decides; "
                    "a 404 surfaces as a transport error, never as a digest match",
        "evidence": [record_503, record_404],
    })

    # S6 — mirror index composition: null must crash, absent must compose.
    scenario = "s6_mirror_index_null_field"
    null_package = {"Package": "synthetic", "Version": "1.0", "Size": "1",
                    "SHA256sum": pin, "Depends": None}
    null_error = None
    try:
        compose_index_block(null_package)
    except TypeError as err:
        null_error = err
    absent_package = {"Package": "synthetic", "Version": "1.0", "Size": "1", "SHA256sum": pin}
    block = compose_index_block(absent_package)
    composed_ok = "Depends" not in block and "SHA256sum: " + pin in block
    scenarios.append({
        "name": scenario,
        "contract": "build() concatenates field values — a null field must crash "
                    "loudly (fail-closed), an absent field must compose cleanly",
        "evidence": [
            _record("Packages.gz block", "str fields only", "None value in record",
                    "mirror_index_composition",
                    f"{type(null_error).__name__}: {null_error}",
                    "REJECTED" if null_error is not None else "ORACLE_FAIL"),
            _record("Packages.gz block", "absent keys stay absent",
                    block.replace("\n", " | "), "mirror_index_composition",
                    "composed", "ACCEPTED" if composed_ok else "ORACLE_FAIL"),
        ],
    })

    flat = []
    for scenario in scenarios:
        evidence = scenario["evidence"]
        flat.extend(evidence if isinstance(evidence, list) else [evidence])
    verdict = "ORACLE PASS" if all(r["status"] != "ORACLE_FAIL" for r in flat) else "ORACLE FAIL"
    evidence = {
        "oracle": "native-e2e-lock-digest-oracle",
        "schema": 1,
        "evidence_fields": EVIDENCE_FIELDS,
        "checked_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "fixture": Path(fixture_path).name,
        "fixture_sha256": _digest(Path(fixture_path).read_bytes()),
        "network_used": False,
        "payloads": "synthetic (no real artifacts downloaded)",
        "scenarios": scenarios,
        "verdict": verdict,
    }
    dump = json.dumps(evidence, indent=2)
    evidence["secret_scan"] = ("clean" if not any(m.lower() in dump.lower()
                                                  for m in SECRET_MARKERS) else "MARKER FOUND")
    if evidence["secret_scan"] != "clean":
        raise AssertionError("evidence contains a secret marker — refusing to write it")
    return evidence, scratch


def crosscheck_real_lab(lab_source, scratch, fixture_path=FIXTURE):
    """Optional: run S1/S3/S4 against the REAL pinned fetch() (offline).

    Imports <lab_source>/build_entware.py, monkeypatches its transport with the
    synthetic fake (and neutralises its sleep), and asserts the real gate raises
    the same messages the model pinned. Run only from the CLI, never in tests.
    """
    lab_source = Path(lab_source)
    spec = importlib.util.spec_from_file_location("lab_build_entware_real",
                                                  lab_source / "build_entware.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    fixture = json.loads(Path(fixture_path).read_text(encoding="utf8"))
    stale_record = fixture["upstream_installer_record"]
    payload = b"kas-oracle synthetic installer bytes (not the real artifact)\n"
    pin = _digest(b"kas-oracle synthetic payload whose digest is the pin\n")
    payload_ok = b"kas-oracle synthetic payload whose digest is the pin\n"
    scratch = Path(scratch)
    results = []
    original_urlopen = urllib.request.urlopen
    original_sleep = module.time.sleep
    try:
        module.time.sleep = noop_sleep
        real_calls = []

        def fake_urlopen(url, timeout=None):
            real_calls.append(url)
            if not fake_urlopen.script:
                raise AssertionError("real-lab transport script exhausted")
            behaviour = fake_urlopen.script.pop(0)
            if isinstance(behaviour, int):
                raise urllib.error.HTTPError(url, behaviour, "synthetic", None, None)
            return FakeResponse(behaviour)

        fake_urlopen.script = []
        urllib.request.urlopen = fake_urlopen

        # S1-real: stale pin vs mismatched bytes
        fake_urlopen.script = [payload]
        destination = scratch / "real-s1" / "installer.tar.gz"
        error1 = None
        try:
            module.fetch(stale_record["url"], stale_record["sha256"], destination)
        except Exception as err:  # noqa: BLE001
            error1 = err
        results.append({
            "scenario": "s1_real_fetch_stale_pin",
            "error": str(error1),
            "artifact_persisted": destination.exists(),
            "agrees_with_model": "download digest mismatch" in str(error1)
                                 and not destination.exists(),
        })

        # S3-real: non-official origin
        error3 = None
        try:
            module.fetch("https://example.invalid/aarch64-k3.10/x.tar.gz", pin,
                         scratch / "real-s3" / "x.tar.gz")
        except Exception as err:  # noqa: BLE001
            error3 = err
        results.append({
            "scenario": "s3_real_fetch_off_origin",
            "error": str(error3),
            "network_touched": bool(real_calls) and real_calls[-1] != stale_record["url"],
            "agrees_with_model": "unexpected bootstrap origin" in str(error3),
        })

        # S4-real: tampered cache entry, no network
        destination = scratch / "real-s4" / "x.tar.gz"
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(b"tampered cache bytes\n")
        error4 = None
        calls_before = len(real_calls)
        try:
            module.fetch(OFFICIAL_PREFIX + "x.tar.gz", pin, destination)
        except Exception as err:  # noqa: BLE001
            error4 = err
        results.append({
            "scenario": "s4_real_fetch_tampered_cache",
            "error": str(error4),
            "agrees_with_model": "cached asset digest mismatch" in str(error4)
                                 and len(real_calls) == calls_before,
        })
    finally:
        urllib.request.urlopen = original_urlopen
        module.time.sleep = original_sleep
    verdict = ("REAL-LAB CROSSCHECK PASS" if all(r["agrees_with_model"] for r in results)
               else "REAL-LAB CROSSCHECK FAIL")
    return {"crosscheck": "real lab/build_entware.py fetch()", "lab_source": str(lab_source),
            "emulator_ref_expected": "9e59e0bff1319acbd191867dac1f5ace2df0655f",
            "results": results, "verdict": verdict}


class FakeResponse:
    """Minimal context-manager response for the monkeypatched urlopen."""

    def __init__(self, data):
        self._data = data

    def read(self):
        return self._data

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--scratch", help="scratch directory (default: isolated tempfile)")
    parser.add_argument("--fixture", default=str(FIXTURE), help="fixture JSON path")
    parser.add_argument("--evidence-out", help="write evidence.json here (default: scratch)")
    parser.add_argument("--lab-source", help="optional: router-emulator checkout with "
                                             "lab/build_entware.py for the real-fetch crosscheck")
    args = parser.parse_args(argv)
    with tempfile.TemporaryDirectory(prefix="kas-lock-oracle-") as td:
        scratch = Path(args.scratch) if args.scratch else Path(td)
        evidence, scratch = run_scenarios(scratch, args.fixture)
        if args.lab_source:
            evidence["real_lab_crosscheck"] = crosscheck_real_lab(args.lab_source, scratch, args.fixture)
            if "FAIL" in evidence["real_lab_crosscheck"]["verdict"]:
                evidence["verdict"] = "ORACLE FAIL"
        out = Path(args.evidence_out) if args.evidence_out else scratch / "evidence.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf8")
        print(f"evidence: {out}")
        print(f"verdict:  {evidence['verdict']}")
        if "real_lab_crosscheck" in evidence:
            print(f"crosscheck: {evidence['real_lab_crosscheck']['verdict']}")
        return 0 if evidence["verdict"] == "ORACLE PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
