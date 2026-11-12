#!/usr/bin/env python3
"""Offline negative regressions for scripts/verify-entware-opkg.sh (#488).

The pinned Entware artifact verifier must stay fail-closed: a digest
mismatch, an empty payload or a non-ELF (for example HTML) payload never
produces a verified artifact, never leaves a partial download behind and
never chmods or executes unverified bytes. The canonical pinned digest must
not drift silently: re-pinning is a documented owner provenance decision
(Issue #488, BLOCKED_UPSTREAM_PROVENANCE), not a quiet edit.

All cases are deterministic and offline: --source/--url/--sha256 overrides
and a stub curl on PATH replace the real network.
"""
from pathlib import Path
import hashlib
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "verify-entware-opkg.sh"
# Re-pin 2026-11-09: documented owner trust decision (Issue #488, Option A,
# owner GO comment 6747639647), not a cryptographic attestation.
CANONICAL_PIN = "49f3d1e047483dc068fcc8985d64dcd28d0041044434de2cb3ccd616f2fc0b10"
CANONICAL_URL = "https://bin.entware.net/x64-k3.2/installer/opkg"

ELF_PAYLOAD = b"\x7fELF" + b"\x02\x01\x01\x00" + b"KAS trusted fixture payload\n"
OTHER_ELF = b"\x7fELF" + b"\x02\x01\x01\x00" + b"different trusted-region bytes\n"
HTML_PAYLOAD = b"<html><body>404 Not Found</body></html>\n"

failures = []


def check(name, condition, detail=""):
    if condition:
        print(f"[OK] {name}")
    else:
        failures.append(f"{name}: {detail}")
        print(f"[FAIL] {name}: {detail}")


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def run_helper(args):
    return subprocess.run(
        ["sh", str(HELPER)] + args, capture_output=True, text=True, timeout=60
    )


def write_source(directory, payload):
    fixture = Path(directory) / "fixture.bin"
    fixture.write_bytes(payload)
    os.chmod(fixture, 0o644)
    return fixture


def digest_arg(payload):
    return ["--sha256", sha256(payload)]


STUB_CURL = r"""#!/bin/sh
# Deterministic curl stub: -sI prints fixed server metadata, download mode
# copies the planned payload to the -o target. TRANSPORT_FAIL=1 makes the
# download mode exit 7 (connection refused) without writing any bytes.
for a in "$@"; do
    case $a in
        -sI|-I) mode=metadata ;;
    esac
done
if [ "${mode:-}" = metadata ]; then
    printf 'HTTP/1.1 200 OK\r\n'
    printf 'Content-Length: %s\r\n' "$(wc -c < "$PAYLOAD_FILE")"
    printf 'ETag: "stub-etag-1"\r\n'
    printf 'Last-Modified: Thu, 01 Jan 2026 00:00:00 GMT\r\n'
    exit 0
fi
prev=
for a in "$@"; do
    [ "$prev" = "-o" ] && { [ "${TRANSPORT_FAIL:-}" = 1 ] && exit 7; cat "$PAYLOAD_FILE" > "$a"; exit 0; }
    prev=$a
done
exit 18
"""


def run_helper_with_stub(args, payload, transport_fail=False):
    """Run the helper in network mode with curl replaced by a stub."""
    with tempfile.TemporaryDirectory(prefix="verify-opkg-stub-") as stub_dir:
        stub = Path(stub_dir) / "curl"
        stub.write_text(STUB_CURL)
        stub.chmod(0o755)
        payload_file = Path(stub_dir) / "planned-payload.bin"
        payload_file.write_bytes(payload)
        env = dict(os.environ)
        env["PATH"] = stub_dir + os.pathsep + env.get("PATH", "")
        env["PAYLOAD_FILE"] = str(payload_file)
        if transport_fail:
            env["TRANSPORT_FAIL"] = "1"
        return subprocess.run(
            ["sh", str(HELPER)] + args,
            capture_output=True,
            text=True,
            timeout=60,
            env=env,
        )


def main():
    check(
        "canonical pin constant unchanged",
        CANONICAL_PIN in HELPER.read_text() and CANONICAL_URL in HELPER.read_text(),
        f"{HELPER} must still carry the pinned digest and URL; re-pinning needs a documented owner provenance decision (#488)",
    )
    check(
        "verifier never chmods or executes payload",
        "chmod +x" not in HELPER.read_text() and "| sh" not in HELPER.read_text(),
        "helper must not mark or run the payload; callers chmod only verified artifacts",
    )

    with tempfile.TemporaryDirectory(prefix="verify-opkg-") as directory:
        fixture = write_source(directory, ELF_PAYLOAD)
        proc = run_helper(
            ["--source", str(fixture), "--sha256", sha256(ELF_PAYLOAD)]
        )
        check(
            "correct known trusted bytes pass",
            proc.returncode == 0 and "VERIFY: OK" in proc.stdout,
            f"rc={proc.returncode} stdout={proc.stdout!r} stderr={proc.stderr!r}",
        )
        check(
            "verified payload stays non-executable",
            (fixture.stat().st_mode & 0o111) == 0,
            "fixture mode must remain 0o644 after verification",
        )

    fixture = write_source(tempfile.mkdtemp(prefix="verify-opkg-"), OTHER_ELF)
    try:
        proc = run_helper(["--source", str(fixture), "--sha256", sha256(ELF_PAYLOAD)])
        combined = proc.stdout + proc.stderr
        check(
            "mismatched digest fails with rc == 1 (not a usage error)",
            proc.returncode == 1,
            f"rc={proc.returncode}",
        )
        check(
            "mismatch report shows expected, observed and size",
            sha256(ELF_PAYLOAD) in combined
            and sha256(OTHER_ELF) in combined
            and str(len(OTHER_ELF)) in combined,
            f"missing diagnostics in {combined!r}",
        )
        check(
            "mismatch report names the blocked-provenance policy",
            "BLOCKED_UPSTREAM_PROVENANCE" in combined,
            "fail report must point at the owner provenance gate",
        )
        check(
            "mismatch does not mutate the supplied payload",
            fixture.read_bytes() == OTHER_ELF,
            "source fixture must stay untouched on failure",
        )
    finally:
        fixture.unlink(missing_ok=True)

    # Strengthened per independent review: the empty and non-ELF early-returns
    # used to leave OBSERVED unset, so report_mismatch died under set -u
    # ("OBSERVED: parameter not set", exit 2 from the usage class) before any
    # diagnostics. These paths must now behave exactly like a digest
    # mismatch: rc == 1, the full expected/observed/bytes report carrying the
    # observed SHA256 and the blocked-provenance policy, and no leftover
    # files anywhere.
    for name, payload, needle in (
        ("html payload", HTML_PAYLOAD, "not a verified ELF"),
        ("empty payload", b"", "payload is empty"),
    ):
        fixture = write_source(tempfile.mkdtemp(prefix="verify-opkg-"), payload)
        try:
            proc = run_helper(["--source", str(fixture), "--sha256", sha256(payload)])
            combined = proc.stdout + proc.stderr
            check(
                f"malformed {name} fails with rc == 1 (not a usage error)",
                proc.returncode == 1,
                f"rc={proc.returncode} stderr={proc.stderr!r}",
            )
            check(
                f"malformed {name} names the defect",
                needle in combined,
                f"missing {needle!r} in {combined!r}",
            )
            check(
                f"malformed {name} reports observed SHA256 and full diagnostics",
                "expected:" in combined
                and "observed:" in combined
                and sha256(payload) in combined
                and f"bytes:    {len(payload)}" in combined
                and "BLOCKED_UPSTREAM_PROVENANCE" in combined,
                f"missing full mismatch report in {combined!r}",
            )
            check(
                f"malformed {name} leaves no leftover files",
                sorted(p.name for p in fixture.parent.iterdir()) == [fixture.name],
                "a rejected payload must not materialize any artifact",
            )
        finally:
            fixture.unlink(missing_ok=True)

    # The same early-return paths in network mode (the mode CI actually
    # uses): a stubbed download serving malformed bytes must fail closed
    # with the full report, server metadata in the audit trail and no
    # .part or committed artifact.
    for name, payload, needle in (
        ("html payload", HTML_PAYLOAD, "not a verified ELF"),
        ("empty payload", b"", "payload is empty"),
    ):
        with tempfile.TemporaryDirectory(prefix="verify-opkg-net-") as directory:
            dest = Path(directory) / "entware-opkg"
            proc = run_helper_with_stub(
                ["--url", "https://lab.invalid/x64-k3.2/installer/opkg"]
                + digest_arg(ELF_PAYLOAD)
                + ["--output", str(dest)],
                payload,
            )
            combined = proc.stdout + proc.stderr
            check(
                f"network mode malformed {name} fails with rc == 1",
                proc.returncode == 1 and not dest.exists(),
                f"rc={proc.returncode} dest exists={dest.exists()}",
            )
            check(
                f"network mode malformed {name} reports observed SHA256",
                needle in combined
                and "observed:" in combined
                and sha256(payload) in combined
                and "BLOCKED_UPSTREAM_PROVENANCE" in combined
                and "stub-etag-1" in combined,
                f"missing full mismatch report in {combined!r}",
            )
            check(
                f"network mode malformed {name} cleans up partial download",
                not dest.with_name(dest.name + ".part").exists(),
                "failed verification must remove the .part file",
            )

    with tempfile.TemporaryDirectory(prefix="verify-opkg-net-") as directory:
        dest = Path(directory) / "entware-opkg"
        proc = run_helper_with_stub(
            ["--url", "https://lab.invalid/x64-k3.2/installer/opkg"]
            + digest_arg(ELF_PAYLOAD)
            + ["--output", str(dest)],
            ELF_PAYLOAD,
        )
        check(
            "network mode with trusted bytes passes and commits artifact",
            proc.returncode == 0 and dest.is_file() and dest.read_bytes() == ELF_PAYLOAD,
            f"rc={proc.returncode} stdout={proc.stdout!r} stderr={proc.stderr!r}",
        )
        check(
            "no partial download left after success",
            not dest.with_name(dest.name + ".part").exists(),
            "atomic commit must remove the .part file",
        )
        check(
            "success audit trail includes server metadata",
            "ETag" in proc.stdout and "Last-Modified" in proc.stdout,
            f"stdout={proc.stdout!r}",
        )

    with tempfile.TemporaryDirectory(prefix="verify-opkg-net-") as directory:
        dest = Path(directory) / "entware-opkg"
        proc = run_helper_with_stub(
            ["--url", "https://lab.invalid/x64-k3.2/installer/opkg"]
            + digest_arg(ELF_PAYLOAD)
            + ["--output", str(dest)],
            OTHER_ELF,
        )
        combined = proc.stdout + proc.stderr
        check(
            "network mode digest mismatch fails closed",
            proc.returncode != 0 and not dest.exists(),
            f"rc={proc.returncode} dest exists={dest.exists()}",
        )
        check(
            "network mismatch reports observed bytes and server metadata",
            sha256(OTHER_ELF) in combined and "ETag" in combined and "stub-etag-1" in combined,
            f"missing diagnostics in {combined!r}",
        )
        check(
            "network mismatch cleans up partial download",
            not dest.with_name(dest.name + ".part").exists(),
            "failed verification must remove the .part file",
        )

    # A download transport failure must
    # fail closed exactly like a digest mismatch — no artifact, no .part
    # leftover, an explicit infra-failure diagnosis instead of a silent pass.
    with tempfile.TemporaryDirectory(prefix="verify-opkg-net-") as directory:
        dest = Path(directory) / "entware-opkg"
        proc = run_helper_with_stub(
            ["--url", "https://lab.invalid/x64-k3.2/installer/opkg"]
            + digest_arg(ELF_PAYLOAD)
            + ["--output", str(dest)],
            ELF_PAYLOAD,
            transport_fail=True,
        )
        combined = proc.stdout + proc.stderr
        check(
            "network transport error fails closed",
            proc.returncode != 0 and not dest.exists(),
            f"rc={proc.returncode} dest exists={dest.exists()}",
        )
        check(
            "transport error names the download failure",
            "download transport error" in combined,
            f"missing transport diagnostics in {combined!r}",
        )
        check(
            "transport error cleans up partial download",
            not dest.with_name(dest.name + ".part").exists(),
            "failed transport must remove the .part file",
        )

    if failures:
        print(f"\n{len(failures)} FAILED:")
        for item in failures:
            print(f"  - {item}")
        raise SystemExit(1)
    print("\nAll verify-entware-opkg regressions passed")


if __name__ == "__main__":
    main()
