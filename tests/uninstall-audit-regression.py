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

def scenario(shell, mode, malformed=False, ledger_mode='missing'):
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
        ledger = fixture / 'opt/etc/keenetic-auto-setup/ownership.v1'
        ledger.parent.mkdir(parents=True, exist_ok=True)
        if ledger_mode == 'valid':
            ledger.write_text('KAS_OWNERSHIP_V1\nowned|proxy|Proxy1\nowned|policy|bypass_wa\nenabled|dns|intercept\nowned|package|mihomo\nowned|package|magitrickle\nowned|repository|magitrickle.conf\nowned|hook|020-bypass_wa.sh\nowned|watchdog|binary\nowned|watchdog|wrapper\n')
        elif ledger_mode == 'valid_foreign':
            ledger.write_text('KAS_OWNERSHIP_V1\nowned|package|magitrickle\nowned|package|mihomo\n')
        elif ledger_mode == 'corrupt':
            ledger.write_text('KAS_OWNERSHIP_V1\nowned|proxy|Proxy1\nDISABLE SAFETY\n')
        elif ledger_mode == 'link':
            ledger.symlink_to(config)
        elif ledger_mode != 'missing':
            raise AssertionError(ledger_mode)
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
            if ledger_mode in ('valid','valid_foreign'):
                assert "creation journal verified" in p.stderr
            else:
                assert "no valid ownership journal" in p.stderr
            assert not calls, calls
            return
        assert p.returncode == 0, (p.returncode, p.stderr)
        assert "No changes made" in p.stdout
        if ledger_mode in ('valid','valid_foreign'):
            assert '[LEDGER] ownership.v1' in p.stdout
            if ledger_mode == 'valid':
                assert '[RECORDED] owned|proxy|Proxy1' in p.stdout
            else:
                assert '[RECORDED] owned|proxy|Proxy1' not in p.stdout
            assert '[RECORDED] owned|package|magitrickle' in p.stdout
        else:
            assert '[UNKNOWN] ledger' in p.stdout
            assert '[RECORDED]' not in p.stdout
        if mode == '--plan' and ledger_mode in ('valid','valid_foreign'):
            assert '=== KAS UNINSTALL PLAN (READ ONLY) ===' in p.stdout
            if ledger_mode == 'valid':
                assert '[REVIEW] Proxy1' in p.stdout, p.stdout
            else:
                assert '[BLOCKED] Proxy1' in p.stdout, p.stdout
            if ledger_mode == 'valid':
                assert '[REVIEW] opkg/mihomo' in p.stdout, p.stdout
                assert '[REVIEW] policy/bypass_wa' in p.stdout, p.stdout
                assert '[REVIEW] dns-proxy intercept' in p.stdout, p.stdout
            else:
                assert '[BLOCKED] opkg/mihomo' in p.stdout, p.stdout
                assert '[PRESERVE] policy/bypass_wa' in p.stdout, p.stdout
                assert '[PRESERVE] dns-proxy intercept' in p.stdout, p.stdout
            assert '[REVIEW] opkg/magitrickle' in p.stdout
            assert '[PRESERVE] other/unowned ProxyN, policies and Entware' in p.stdout
            assert '[BACKUP_REQUIRED] /opt/etc/mihomo/config.yaml' in p.stdout
            assert '[BACKUP_REQUIRED] /opt/var/lib/magitrickle/config.yaml' in p.stdout
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
    for ledger_mode in ('missing','valid','corrupt','link'):
        scenario(shell, '--check', ledger_mode=ledger_mode)
        print('[PASS]', ' '.join(shell), '--check', ledger_mode)
    for ledger_mode in ('valid','valid_foreign'):
        scenario(shell, '--plan', ledger_mode=ledger_mode)
        print('[PASS]', ' '.join(shell), '--plan', ledger_mode)
    scenario(shell, '--check', malformed=True)
    for mode in ('--remove','--purge'):
        for ledger_mode in ('missing','valid','corrupt','link'):
            scenario(shell, mode, ledger_mode=ledger_mode)
            print('[PASS] blocked', ' '.join(shell), mode, ledger_mode)
script = (ROOT / "uninstall.sh").read_text()
assert "rm -rf" not in script and "opkg remove" not in script
assert "ndmc -c \"interface" not in script
assert "iptables -D" not in script and "iptables -F" not in script
print("[PASS] no mutating commands or attempted cleanup")
