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
CANONICAL_PIN = "08c8feb2ef3153f025ba687f8df02adf915e4252a3605cc6798f8d105162cb38"
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
# copies the planned payload to the -o target.
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
    [ "$prev" = "-o" ] && { cat "$PAYLOAD_FILE" > "$a"; exit 0; }
    prev=$a
done
exit 18
"""


def run_helper_with_stub(args, payload):
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
            "mismatched digest still fails",
            proc.returncode != 0,
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

    for name, payload, needle in (
        ("html payload", HTML_PAYLOAD, "not a verified ELF"),
        ("empty payload", b"", "payload is empty"),
    ):
        fixture = write_source(tempfile.mkdtemp(prefix="verify-opkg-"), payload)
        try:
            proc = run_helper(["--source", str(fixture), "--sha256", sha256(payload)])
            check(
                f"malformed {name} fails",
                proc.returncode != 0 and needle in proc.stdout + proc.stderr,
                f"rc={proc.returncode} stderr={proc.stderr!r}",
            )
        finally:
            fixture.unlink(missing_ok=True)

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

    if failures:
        print(f"\n{len(failures)} FAILED:")
        for item in failures:
            print(f"  - {item}")
        raise SystemExit(1)
    print("\nAll verify-entware-opkg regressions passed")


if __name__ == "__main__":
    main()
