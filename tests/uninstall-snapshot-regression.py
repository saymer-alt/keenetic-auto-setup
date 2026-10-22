#!/usr/bin/env python3
"""No-destructive-write backup contract, dash and BusyBox ash fixtures."""
from pathlib import Path
import os
import shutil
import stat
import subprocess
import tempfile

BASE = Path(__file__).resolve().parents[1]
SHELLS = [["sh"]]
if shutil.which("busybox"):
    SHELLS.append(["busybox", "ash"])

def setup(td):
    root = td / "root"
    files = {
        "opt/etc/keenetic-auto-setup/ownership.v1": (
            "KAS_OWNERSHIP_V1\nowned|proxy|Proxy0\nowned|policy|bypass_wa\n"
            "enabled|dns|intercept\nowned|package|mihomo\n"
            "owned|package|magitrickle\nowned|repository|magitrickle.conf\n"
            "owned|hook|020-bypass_wa.sh\nowned|watchdog|binary\n"
            "owned|watchdog|wrapper\n"),
        "opt/etc/mihomo/config.yaml": "secret: TEST_SECRET_MUST_NOT_PRINT\nmixed-port: 7890\n",
        "opt/var/lib/magitrickle/config.yaml": "server: internal\n",
        "opt/etc/crontab": "*/5 * * * * root /opt/bin/run-parts /opt/etc/cron.5mins\n",
        "opt/etc/ndm/netfilter.d/020-bypass_wa.sh": "#!/bin/sh\n",
        "opt/bin/mihomo_watchdog.sh": "#!/bin/sh\n",
        "opt/etc/cron.5mins/mihomo_watchdog": "#!/bin/sh\n",
        "opt/etc/opkg/magitrickle.conf": "src/gz magitrickle https://example.invalid\n",
        "opt/etc/init.d/S99mihomo": "#!/bin/sh\n",
        "opt/etc/init.d/S99magitrickle": "#!/bin/sh\n",
    }
    for rel, body in files.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body)
    toolbin = td / "bin"
    toolbin.mkdir()
    for name, script in {
        "ndmc": '#!/bin/sh\ncase "$2" in\n"show running-config") printf "interface Proxy0\\n proxy upstream 127.0.0.1 7890\\n" ;;\n"show ip policy") printf "bypass_wa\\n" ;;\n*) exit 40 ;;\nesac\n',
        "iptables": '#!/bin/sh\n[ "$*" = "-t mangle -S" ] || exit 40\necho "-N _CUST_BYPASS_WA_"\n',
        "opkg": '#!/bin/sh\n[ "$1" = list-installed ] || exit 40\nprintf "mihomo - 1\\nmagitrickle - 1\\n"\n',
    }.items():
        p = toolbin / name
        p.write_text(script)
        p.chmod(0o755)
    env = os.environ | {
        "KAS_SNAPSHOT_ROOT": str(root),
        "PATH": str(toolbin) + os.pathsep + os.environ.get("PATH", ""),
    }
    return root, files, env

def run(shell, env, mode):
    p = subprocess.run(shell + [str(BASE / "uninstall-snapshot.sh"), mode],
                       env=env, capture_output=True, text=True, timeout=12)
    assert "TEST_SECRET_MUST_NOT_PRINT" not in p.stdout + p.stderr
    return p

for shell in SHELLS:
    with tempfile.TemporaryDirectory(prefix="kas-uninstall-snapshot-") as temp:
        td = Path(temp)
        root, files, env = setup(td)
        result = run(shell, env, "--check")
        assert result.returncode == 0, result
        assert not (root / "opt/kas-uninstall-backups").exists()
        result = run(shell, env, "--create")
        assert result.returncode == 0, (result.stdout, result.stderr)
        snaps = list((root / "opt/kas-uninstall-backups").iterdir())
        assert len(snaps) == 1, snaps
        snap = snaps[0]
        assert (snap / "READY").read_text() == "READY\n"
        assert (snap / "manifest.v1").read_text().startswith("KAS_UNINSTALL_SNAPSHOT_V1\n")
        for rel, content in files.items():
            copied = snap / "files" / rel
            assert copied.read_text() == content, (rel, copied)
            assert stat.S_IMODE(copied.stat().st_mode) == 0o600, rel
            assert (root / rel).read_text() == content, ("source mutated", rel)
        for rel in ["READY", "manifest.v1", "running-config", "ip-policy", "iptables-mangle", "opkg-packages"]:
            assert stat.S_IMODE((snap / rel).stat().st_mode) == 0o600, rel
        assert stat.S_IMODE(snap.stat().st_mode) == 0o700
        print("[PASS]", shell, "verified secret-preserving snapshot + no original mutation")

    for kind in ("corrupt", "duplicate", "missing_yaml", "linked_yaml", "maintenance"):
        with tempfile.TemporaryDirectory(prefix="kas-uninstall-blocked-") as temp:
            td = Path(temp)
            root, files, env = setup(td)
            ledger = root / "opt/etc/keenetic-auto-setup/ownership.v1"
            yaml = root / "opt/etc/mihomo/config.yaml"
            if kind == "corrupt":
                ledger.write_text(ledger.read_text() + "BOGUS\n")
            elif kind == "duplicate":
                ledger.write_text(ledger.read_text() + "owned|proxy|Proxy0\n")
            elif kind == "missing_yaml":
                yaml.unlink()
            elif kind == "linked_yaml":
                yaml.unlink()
                yaml.symlink_to(root / "opt/etc/crontab")
            elif kind == "maintenance":
                marker = root / "tmp/mihomo.maintenance"
                marker.parent.mkdir(parents=True)
                marker.write_text("owner\n")
            p = run(shell, env, "--create")
            assert p.returncode == 3 and "[BLOCKED]" in p.stderr, (kind, p.stdout, p.stderr)
            assert not (root / "opt/kas-uninstall-backups").exists()
            print("[PASS]", shell, "blocked", kind)
print("[PASS] no destructive actions tested or required")