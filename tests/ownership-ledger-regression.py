#!/usr/bin/env python3
"""Exercise standalone ledger functions from install.sh, without running installer."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
installer = (ROOT / "install.sh").read_text()
begin = "# BEGIN KAS OWNERSHIP LEDGER V1\n"
end = "# END KAS OWNERSHIP LEDGER V1\n"
assert installer.count(begin) == 1 and installer.count(end) == 1
block = installer.split(begin, 1)[1].split(end, 1)[0]
assert "KAS_OWNER_DIR=/opt/etc/keenetic-auto-setup" in block

SHELLS = [["sh"]]
if shutil.which("busybox"):
    SHELLS.append(["busybox", "ash"])

def run(shell, root, body):
    program = (
        "log() { :; }\n"
        + block
        + '\nKAS_OWNER_DIR="$1"\nKAS_OWNER_FILE="$KAS_OWNER_DIR/ownership.v1"\n'
        + body
    )
    return subprocess.run(shell + ["-c", program, "ledger-test", str(root)],
                          capture_output=True, text=True, timeout=15)

for shell in SHELLS:
    with tempfile.TemporaryDirectory(prefix="kas-ledger-v1-") as d:
        base = Path(d)
        target = base / "safe"
        p = run(shell, target, """
kas_ledger_init || exit 1
kas_ledger_record owned proxy Proxy1 || exit 2
kas_ledger_record owned package magitrickle || exit 3
kas_ledger_record owned package magitrickle || exit 4
kas_ledger_valid || exit 5
""")
        assert p.returncode == 0, (shell, p.stdout, p.stderr)
        ledger = target / "ownership.v1"
        assert ledger.read_text().splitlines() == [
            "KAS_OWNERSHIP_V1", "owned|proxy|Proxy1",
            "owned|package|magitrickle",
        ]
        assert ledger.stat().st_mode & 0o777 == 0o600
        before = ledger.read_bytes()
        p = run(shell, target, """
kas_ledger_init || exit 1
kas_ledger_record owned proxy ProxyNotNumeric && exit 2
kas_ledger_record owned package magitrickle || exit 3
""")
        assert p.returncode == 0, (shell, p.stdout, p.stderr)
        assert ledger.read_bytes() == before
        ledger.write_text("KAS_OWNERSHIP_V1\nowned|package|magitrickle\ninvalid|foo|bar\n")
        before = ledger.read_bytes()
        p = run(shell, target, 'kas_ledger_init && exit 7; exit 0\n')
        assert p.returncode == 0, (shell, p.stdout, p.stderr)
        assert ledger.read_bytes() == before
        # A symlink at the ledger location must never be followed.
        ledger.unlink()
        victim = base / "victim"
        victim.write_text("leave alone\n")
        ledger.symlink_to(victim)
        p = run(shell, target, 'kas_ledger_init && exit 7; exit 0\n')
        assert p.returncode == 0
        assert victim.read_text() == "leave alone\n"
        print("[PASS]", " ".join(shell), "atomic ledger, dedup, malformed, symlink")

# The only ownership claims come from observed "fresh" install branches.
assert "kas_package_was_absent magitrickle" in installer
assert "kas_package_was_absent mihomo" in installer
assert "PROXY_CREATED_THIS_RUN=1\n        kas_ledger_record owned proxy Proxy0" in installer
assert "PROXY_CREATED_THIS_RUN=1\n    kas_ledger_record owned proxy" in installer
assert 'if [ "$_kas_bypass_hook_existed" -eq 0 ]' in installer
assert 'if [ "$_kas_mt_repo_existed" -eq 0 ]' in installer
assert "kas_ledger_record enabled dns intercept" in installer
assert "kas_ledger_record owned service S00ubifs" in installer
print("[PASS] installer calls ownership writes only after new creations")
