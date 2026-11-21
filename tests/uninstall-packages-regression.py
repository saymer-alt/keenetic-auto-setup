#!/usr/bin/env python3
"""Small contract test for the deliberately partial Entware-only uninstaller."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

SCRIPT = Path(__file__).resolve().parents[1] / "uninstall-packages.sh"
SHELLS = [["sh"]] + ([["busybox", "ash"]] if shutil.which("busybox") else [])

for shell in SHELLS:
    subprocess.run(shell + ["-n", str(SCRIPT)], check=True)
    for scenario, expected_calls, expected_rc in [
        ("both", ["list-installed", "remove mihomo", "remove magitrickle"], 0),
        ("one", ["list-installed", "remove mihomo"], 0),
        ("none", ["list-installed"], 0),
        ("inventory_failed", ["list-installed"], 1),
        ("remove_failed", ["list-installed", "remove mihomo", "remove magitrickle"], 1),
    ]:
        with tempfile.TemporaryDirectory(prefix="kas-minimal-remove-") as temp:
            root = Path(temp)
            fake = root / "opkg"
            log = root / "calls"
            yaml = root / "config.yaml"
            yaml.write_text("user: keep\n")
            fake.write_text("""#!/bin/sh
printf '%s\\n' "$*" >> "$OPKG_TEST_LOG"
if [ "$1" = list-installed ]; then
    [ "$TEST_CASE" = inventory_failed ] && exit 9
    [ "$TEST_CASE" = none ] && exit 0
    echo "mihomo - 1.19.33-2"
    [ "$TEST_CASE" = one ] || echo "magitrickle - 0.8.2-1"
    exit 0
fi
[ "$1" = remove ] || exit 8
[ "$TEST_CASE" = remove_failed ] && [ "$2" = mihomo ] && exit 7
exit 0
""")
            fake.chmod(0o700)
            env = os.environ.copy()
            env.update(PATH=temp + os.pathsep + env["PATH"], OPKG_TEST_LOG=str(log),
                       TEST_CASE=scenario)
            result = subprocess.run(shell + [str(SCRIPT)], capture_output=True,
                                    text=True, env=env, timeout=10)
            assert result.returncode == expected_rc, (shell, scenario, result)
            assert log.read_text().splitlines() == expected_calls, (shell, scenario)
            assert yaml.read_text() == "user: keep\n", (shell, scenario)
            assert (("[OK]" in result.stdout or "[PARTIAL]" in result.stdout + result.stderr) if expected_rc == 0 else "[ERROR]" in result.stderr), (shell, scenario)
            print("[PASS]", shell, scenario)
print("[PASS] package-only uninstaller does not call ndmc, iptables or file delete")

# --cleanup contract for the MagiTrickle architecture fragment: the KAS-owned
# kas-mt-arch.conf (journaled as owned|repository|kas-mt-arch.conf) must be
# removed strictly AFTER the package removals succeed — the cleanup block
# runs only when no removal failed. Without the journal record, on a failed
# removal, or through a symlink the fragment is preserved.
CLEANUP_SCENARIOS = {
    "cleanup_ok": (0, False),
    "cleanup_no_record": (0, True),
    "cleanup_remove_failed": (1, True),
    "cleanup_symlink": (0, True),
}
CLEANUP_CALLS = ["list-installed", "remove mihomo", "remove magitrickle"]
CLEANUP_FAKE_OPKG = """#!/bin/sh
printf '%s\\n' "$*" >> "$OPKG_TEST_LOG"
if [ "$1" = list-installed ]; then
    echo "mihomo - 1.19.33-2"
    echo "magitrickle - 0.8.2-1"
    exit 0
fi
[ "$1" = remove ] || exit 8
[ "$TEST_CASE" = cleanup_remove_failed ] && [ "$2" = magitrickle ] && exit 7
exit 0
"""

for shell in SHELLS:
    for scenario, (expected_rc, fragment_kept) in CLEANUP_SCENARIOS.items():
        # The script only accepts marked disposable roots under /tmp.
        with tempfile.TemporaryDirectory(prefix="kas-uninstall-test-", dir="/tmp") as temp:
            root = Path(temp)
            (root / ".kas-uninstall-test").write_text("KAS_UNINSTALL_TEST_V1")
            ledger_dir = root / "opt/etc/keenetic-auto-setup"
            ledger_dir.mkdir(parents=True)
            ledger = ledger_dir / "ownership.v1"
            record = "owned|repository|kas-mt-arch.conf\n" \
                if scenario != "cleanup_no_record" else ""
            ledger.write_text("KAS_OWNERSHIP_V1\nowned|package|magitrickle\n" + record)
            fragment = root / "opt/etc/opkg/kas-mt-arch.conf"
            fragment.parent.mkdir(parents=True)
            if scenario == "cleanup_symlink":
                foreign = root / "opt/etc/opkg/foreign.conf"
                foreign.write_text("arch foreign 500\n")
                fragment.symlink_to(foreign)
            else:
                fragment.write_text("arch mipsel-3.4_kn 51\n")
            fake = root / "opkg"
            fake.write_text(CLEANUP_FAKE_OPKG)
            fake.chmod(0o700)
            log = root / "calls"
            env = os.environ.copy()
            env.update(PATH=str(root) + os.pathsep + env["PATH"],
                       KAS_UNINSTALL_TEST_ROOT=str(root), OPKG_TEST_LOG=str(log),
                       TEST_CASE=scenario)
            result = subprocess.run(
                shell + [str(SCRIPT), "--cleanup"], capture_output=True,
                text=True, env=env, timeout=10)
            assert result.returncode == expected_rc, (shell, scenario, result)
            assert log.read_text().splitlines() == CLEANUP_CALLS, (shell, scenario, log.read_text())
            if fragment_kept:
                assert fragment.exists() or fragment.is_symlink(), (shell, scenario)
            else:
                assert not fragment.exists() and not fragment.is_symlink(), (shell, scenario)
            if scenario == "cleanup_symlink":
                assert "[WARN] Symlink preserved" in result.stderr, (shell, scenario, result.stderr)
            if expected_rc != 0:
                assert "[PARTIAL]" in result.stderr, (shell, scenario, result.stderr)
            print("[PASS]", shell, scenario)
print("[PASS] kas-mt-arch.conf cleanup runs only after successful package removal")
script_text = SCRIPT.read_text()
assert "'repository:kas-mt-arch.conf:etc/opkg/kas-mt-arch.conf'" in script_text
audit_text = SCRIPT.with_name("uninstall.sh").read_text()
assert "/^owned[|]repository[|]kas-mt-arch.conf$/ { next }" in audit_text
assert "report REVIEW 'opkg/kas-mt-arch.conf'" in audit_text
print("[PASS] kas-mt-arch.conf uninstall contracts wired")
