#!/usr/bin/env python3
"""Offline, non-mutating uninstall inventory regression (dash/BusyBox ash)."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SHELLS = [["sh"]]
if shutil.which("busybox"):
    SHELLS.append(["busybox", "ash"])

def fingerprint(root):
    snap = {}
    for path in root.rglob("*"):
        key = str(path.relative_to(root))
        if path.is_symlink():
            snap[key] = ("link", os.readlink(path))
        elif path.is_file():
            snap[key] = ("file", hashlib.sha256(path.read_bytes()).hexdigest())
        else:
            snap[key] = ("dir",)
    return snap

def scenario(shell, mode, malformed=False):
    with tempfile.TemporaryDirectory(prefix="kas-uninstall-preflight-") as temp:
        home = Path(temp)
        fixture = home / "root"
        config = fixture / "opt/etc/mihomo/config.yaml"
        config.parent.mkdir(parents=True)
        config.write_text("secret: DO_NOT_LEAK_ME\nmixed-port: 7890\n")
        link = fixture / "opt/bin/mihomo_watchdog.sh"
        link.parent.mkdir(parents=True)
        link.symlink_to(config)
        cron = fixture / "opt/etc/crontab"
        cron.parent.mkdir(parents=True, exist_ok=True)
        cron.write_text("0 1 * * * root echo foreign\n")
        toolbin = home / "bin"
        toolbin.mkdir()
        logfile = home / "calls"
        tools = {
            "opkg": '#!/bin/sh\necho "opkg $*" >> "$LOGFILE"\n[ "$1" = list-installed ] || exit 50\necho "mihomo - 1"; echo "magitrickle - 1"\n',
            "ndmc": '#!/bin/sh\necho "ndmc $*" >> "$LOGFILE"\n[ "$1" = -c ] || exit 50\n[ "$MALFORMED" = 0 ] || exit 45\ncase "$2" in\n"show running-config") printf "interface Proxy1\\n proxy upstream 127.0.0.1 7890\\ndns-proxy intercept enable\\n";;\n"show ip policy") echo "bypass_wa";;\n*) exit 50;;\nesac\n',
            "iptables": '#!/bin/sh\necho "iptables $*" >> "$LOGFILE"\n[ "$*" = "-t mangle -S _CUST_BYPASS_WA_" ] || exit 50\n',
        }
        for name, body in tools.items():
            f = toolbin / name
            f.write_text(body)
            f.chmod(0o755)
        before = fingerprint(fixture)
        env = dict(os.environ, PATH=str(toolbin) + os.pathsep + os.environ.get("PATH", ""),
                   KAS_AUDIT_ROOT=str(fixture), LOGFILE=str(logfile), MALFORMED=str(int(malformed)))
        p = subprocess.run(shell + [str(ROOT / "uninstall.sh"), mode], env=env,
                           text=True, capture_output=True, timeout=15)
        assert fingerprint(fixture) == before, (shell, mode, "files mutated")
        calls = logfile.read_text().splitlines() if logfile.exists() else []
        if mode in ("--remove", "--purge"):
            assert p.returncode == 3 and "[BLOCKED]" in p.stderr, p
            assert not calls, calls
            return
        assert p.returncode == 0, (p.returncode, p.stderr)
        assert "No changes made" in p.stdout
        assert "DO_NOT_LEAK_ME" not in p.stdout
        assert "[SHARED_OR_FOREIGN] /opt/etc/mihomo/config.yaml" in p.stdout
        assert "[UNKNOWN] /opt/bin/mihomo_watchdog.sh" in p.stdout
        if malformed:
            assert "[UNKNOWN] ProxyN" in p.stdout
            assert "[UNKNOWN] policy/bypass_wa" in p.stdout
        else:
            assert "[UNKNOWN] ProxyN" in p.stdout
            assert "[SHARED_OR_FOREIGN] dns-proxy intercept" in p.stdout
        assert calls == ["opkg list-installed", "ndmc -c show running-config",
                         "ndmc -c show ip policy",
                         "iptables -t mangle -S _CUST_BYPASS_WA_"], calls

for shell in SHELLS:
    for mode, malformed in [("--check", False), ("--check", True),
                            ("--remove", False), ("--purge", False)]:
        scenario(shell, mode, malformed)
        print("[PASS]", " ".join(shell), mode, "unreadable" if malformed else "normal")
script = (ROOT / "uninstall.sh").read_text()
assert "rm -rf" not in script and "opkg remove" not in script
assert "ndmc -c \"interface" not in script
assert "iptables -D" not in script and "iptables -F" not in script
print("[PASS] no mutating commands or attempted cleanup")
