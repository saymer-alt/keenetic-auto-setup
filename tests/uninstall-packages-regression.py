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
