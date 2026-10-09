#!/usr/bin/env python3
"""Owner Experience Gate: safe first-run errors for setup.sh.

The tested shell sees a PATH containing only 'rm' and, in one case, a fake
'opkg'. It can never reach a network downloader, installer or real router.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def invoke(path: Path) -> subprocess.CompletedProcess:
    env = {
        "PATH": str(path),
        "HOME": str(path),
        "TERM": "dumb",
        "NO_COLOR": "1",
        "LC_ALL": "C",
    }
    return subprocess.run(
        ["/bin/sh", str(ROOT / "setup.sh")],
        cwd=str(ROOT),
        env=env,
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )


def expect_failure(result: subprocess.CompletedProcess, needle: str) -> None:
    assert result.returncode != 0, "Expected fail-closed exit"
    assert "Keenetic Auto Setup" in result.stdout, "No visible product context"
    assert "[ERROR]" in result.stderr, "Error must be explicit even without ANSI colors"
    assert needle in result.stderr, (needle, result.stdout, result.stderr)
    assert "\x1b[" not in result.stdout + result.stderr, "NO_COLOR ignored"


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="kas-owner-experience-") as d:
        path = Path(d)
        rm = shutil.which("rm")
        assert rm, "rm not available on test runner"
        (path / "rm").symlink_to(rm)

        # Missing Entware: instructions must be meaningful, never download.
        expect_failure(invoke(path), "Install Entware first.")
        print("PASS: missing OPKG fails with an actionable prerequisite")

        # Fake OPKG is discoverable but must NEVER be executed: curl is absent.
        sentinel = path / "opkg-was-run"
        fake = path / "opkg"
        fake.write_text("#!/bin/sh\nprintf invoked > " + str(sentinel) + "\nexit 97\n")
        fake.chmod(0o700)
        expect_failure(invoke(path), "opkg update && opkg install curl")
        assert not sentinel.exists(), "Unexpected OPKG execution"
        print("PASS: missing curl fails with a copyable next step; no OPKG calls")

    print("OWNER EXPERIENCE GATE: setup first-run refusals PASS (no network/device)")


if __name__ == "__main__":
    main()
