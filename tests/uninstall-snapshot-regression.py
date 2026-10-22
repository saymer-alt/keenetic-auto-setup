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
    # The real KeeneticOS always has /tmp; offline fixtures need to model it.
    (root / "tmp").mkdir(exist_ok=True)
    toolbin = td / "bin"
    toolbin.mkdir()
    for name, script in {
        "ndmc": """#!/bin/sh
case "$2" in
"show running-config") cat <<'KAS_RCI'
interface Bridge0
    description Home
!
interface Proxy0
    description "mihomo t2s0"
    security-level public
    ip global 350
    proxy protocol socks5
    proxy upstream 127.0.0.1 7890
    proxy socks5-udp
    up
!
ip policy bypass_wa
    description bypass_wa
    permit global Proxy0
    no permit global GigabitEthernet1
!
dns-proxy
    intercept enable
!
KAS_RCI
;;
"show ip policy") echo bypass_wa ;;
*) exit 40 ;;
esac
""",
        "iptables": '#!/bin/sh\n[ "$*" = "-t mangle -S" ] || exit 40\necho "-N _CUST_BYPASS_WA_"\necho "-A PREROUTING -m mark --mark 0x0 -j _CUST_BYPASS_WA_"\necho "-A _CUST_BYPASS_WA_ -p udp -m multiport --dports 1400,3478,3482 -j MARK --set-xmark 0xffffaaa/0xffffffff"\necho "-A _CUST_BYPASS_WA_ -p udp -m multiport --dports 1400,3478,3482 -j CONNMARK --save-mark"\necho "-A _CUST_BYPASS_WA_ -p udp -m multiport --dports 1400,3478,3482 -j RETURN"\n',
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
        verifier = str(BASE / "uninstall-snapshot-verify.sh")
        def verify():
            p = subprocess.run(shell + [verifier, snap.name], env=env,
                               capture_output=True, text=True, timeout=12)
            assert "TEST_SECRET_MUST_NOT_PRINT" not in p.stdout + p.stderr
            return p
        p = verify()
        assert p.returncode == 0 and "[PASS] Snapshot verified" in p.stdout, (p.stdout, p.stderr)
        # Before any destructive implementation, check that the 9-claim
        # profile permits a strict read-only transaction plan.
        gate = subprocess.run(
            shell + [str(BASE / "uninstall-transaction-gate.sh"), "--check", snap.name],
            env=env, capture_output=True, text=True, timeout=12)
        assert gate.returncode == 0 and "[PASS] Nine-claim" in gate.stdout, (gate.stdout, gate.stderr)
        assert "TEST_SECRET_MUST_NOT_PRINT" not in gate.stdout + gate.stderr

        # Prepare-stage regression: validation uses the canonical KAS lock and
        # a second state capture, and may write ONLY to this backup snapshot.
        env["KAS_TXN_FIXTURE_ROOT"] = str(root)
        prep_script = str(BASE / "uninstall-transaction.sh")
        prepared = subprocess.run(
            shell + [prep_script, "--prepare", snap.name], env=env,
            capture_output=True, text=True, timeout=12)
        assert prepared.returncode == 0 and "[PASS] KAS uninstall transaction prepared" in prepared.stdout, (
            prepared.stdout, prepared.stderr)
        assert (snap / "transaction/prepare.v1").read_text().startswith(
            "KAS_UNINSTALL_PREPARE_V1\n")
        assert not (root / "tmp/mihomo-lifecycle.lock.d").exists()
        assert not (root / "tmp/mihomo.maintenance").exists()
        for rel, content in files.items():
            assert (root / rel).read_text() == content, ("PREPARE changed source", rel)
        blocked = subprocess.run(
            shell + [prep_script, "--remove", snap.name], env=env,
            capture_output=True, text=True, timeout=12)
        assert blocked.returncode == 3 and "[BLOCKED]" in blocked.stderr
        print("[PASS]", shell, "canonical lock, second verification and non-destructive transaction preparation")

        # Any source change requires a new snapshot; we may not rely on READY alone.
        yaml = root / "opt/etc/mihomo/config.yaml"
        original = yaml.read_text()
        yaml.write_text(original + "# modified after snapshot\n")
        p = verify()
        assert p.returncode == 3 and "source" in p.stderr, p
        yaml.write_text(original)

        evidence = snap / "iptables-mangle"
        backup = evidence.read_text()
        evidence.write_text(backup + "# tampered\n")
        p = verify()
        assert p.returncode == 3 and "mangle" in p.stderr, p
        evidence.write_text(backup)

        manifest = snap / "manifest.v1"
        backup = manifest.read_text()
        manifest.write_text(backup + "copied|/etc/foreign\n")
        p = verify()
        assert p.returncode == 3 and "manifest" in p.stderr, p
        manifest.write_text(backup)

        copied = snap / "files/opt/etc/mihomo/config.yaml"
        copied.chmod(0o644)
        p = verify()
        assert p.returncode == 3 and "permissions" in p.stderr, p
        copied.chmod(0o600)

        link_target = snap / "files/opt/etc/mihomo/config.yaml"
        link_target.unlink()
        link_target.symlink_to(root / "opt/etc/mihomo/config.yaml")
        p = verify()
        assert p.returncode == 3 and "snapshot file" in p.stderr, p

        print("[PASS]", shell, "snapshot integrity, freshness and symlink guards")

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
                marker.parent.mkdir(parents=True, exist_ok=True)
                marker.write_text("owner\n")
            p = run(shell, env, "--create")
            assert p.returncode == 3 and "[BLOCKED]" in p.stderr, (kind, p.stdout, p.stderr)
            assert not (root / "opt/kas-uninstall-backups").exists()
            print("[PASS]", shell, "blocked", kind)

# A new, internally self-consistent snapshot does NOT authorize removal when
# the profile includes foreign consumers or a customized shared policy.
for shell in SHELLS:
    for kind in ("foreign_proxy", "shared_policy"):
        with tempfile.TemporaryDirectory(prefix="kas-uninstall-gate-") as temp:
            td = Path(temp)
            root, files, env = setup(td)
            ndmc = td / "bin/ndmc"
            body = ndmc.read_text()
            if kind == "foreign_proxy":
                body = body.replace(
                    "dns-proxy\n    intercept enable",
                    'interface Proxy1\n    description "foreign"\n'
                    '    proxy upstream 127.0.0.1 7890\n!\ndns-proxy\n    intercept enable')
            else:
                body = body.replace("    permit global Proxy0\n",
                                    "    permit global Proxy0\n    permit global GigabitEthernet1\n")
            ndmc.write_text(body)
            p = run(shell, env, "--create")
            assert p.returncode == 0, (kind, p.stdout, p.stderr)
            snap = next((root / "opt/kas-uninstall-backups").iterdir())
            p = subprocess.run(
                shell + [str(BASE / "uninstall-transaction-gate.sh"), "--check", snap.name],
                env=env, capture_output=True, text=True, timeout=12)
            assert p.returncode == 3 and "[BLOCKED]" in p.stderr, (kind, p.stdout, p.stderr)
            print("[PASS]", shell, "strict transaction gate rejects", kind)
# Keenetic may serialize a policy's WAN deny using an interface alias, even
# though the underlying interface ID is GigabitEthernet1 (KN-1010: ISP).
# The gate must accept ONLY a unique, live alias within that interface block.
for shell in SHELLS:
    for kind, allowed in (
        ("isp_alias", True),
        ("wan_id", True),
        ("missing_alias", False),
        ("wrong_interface_alias", False),
        ("duplicate_alias", False),
        ("extra_permit", False),
        ("duplicate_permit", False),
        ("duplicate_deny", False),
        ("missing_deny", False),
        ("unknown_directive", False),
    ):
        with tempfile.TemporaryDirectory(prefix="kas-uninstall-isp-alias-") as temp:
            td = Path(temp)
            root, files, env = setup(td)
            ndmc = td / "bin/ndmc"
            body = ndmc.read_text()
            if kind != "wan_id":
                inserted = "interface GigabitEthernet1\n    rename ISP\n!\n"
                if kind == "missing_alias":
                    inserted = "interface GigabitEthernet1\n!\n"
                elif kind == "wrong_interface_alias":
                    inserted = "interface Bridge2\n    rename ISP\n!\n"
                elif kind == "duplicate_alias":
                    inserted = "interface GigabitEthernet1\n    rename ISP\n    rename ISP\n!\n"
                body = body.replace("interface Proxy0\n", inserted + "interface Proxy0\n", 1)
                body = body.replace(
                    "    no permit global GigabitEthernet1\n",
                    "    no permit global ISP\n", 1
                )
            if kind == "extra_permit":
                body = body.replace(
                    "    permit global Proxy0\n",
                    "    permit global Proxy0\n    permit global ISP\n", 1)
            elif kind == "duplicate_permit":
                body = body.replace(
                    "    permit global Proxy0\n",
                    "    permit global Proxy0\n    permit global Proxy0\n", 1)
            elif kind == "duplicate_deny":
                body = body.replace(
                    "    no permit global ISP\n",
                    "    no permit global ISP\n    no permit global GigabitEthernet1\n", 1)
            elif kind == "missing_deny":
                body = body.replace("    no permit global ISP\n", "", 1)
            elif kind == "unknown_directive":
                body = body.replace(
                    "    permit global Proxy0\n",
                    "    permit global Proxy0\n    description altered\n", 1)
            ndmc.write_text(body)
            p = run(shell, env, "--create")
            assert p.returncode == 0, (kind, p.stdout, p.stderr)
            snap = next((root / "opt/kas-uninstall-backups").iterdir())
            p = subprocess.run(
                shell + [str(BASE / "uninstall-transaction-gate.sh"), "--check", snap.name],
                env=env, capture_output=True, text=True, timeout=12)
            assert "TEST_SECRET_MUST_NOT_PRINT" not in p.stdout + p.stderr
            if allowed:
                assert p.returncode == 0 and "[PASS] Nine-claim" in p.stdout, (
                    kind, p.stdout, p.stderr)
            else:
                assert p.returncode == 3 and "[BLOCKED]" in p.stderr, (
                    kind, p.stdout, p.stderr)
            print("[PASS]", shell, "WAN alias policy guard", kind)

# A well-formed and fresh snapshot with FOREIGN Netfilter chain contents
# is not enough to authorize transaction preparation.
for shell in SHELLS:
    with tempfile.TemporaryDirectory(prefix="kas-uninstall-foreign-mangle-") as temp:
        td = Path(temp)
        root, files, env = setup(td)
        bad = td / "bin/iptables"
        original = bad.read_text()
        bad.write_text(original + 'echo "-A _CUST_BYPASS_WA_ -p tcp -j DROP"\n')
        p = run(shell, env, "--create")
        assert p.returncode == 0, (p.stdout, p.stderr)
        snap = next((root / "opt/kas-uninstall-backups").iterdir())
        env["KAS_TXN_FIXTURE_ROOT"] = str(root)
        prepared = subprocess.run(
            shell + [str(BASE / "uninstall-transaction.sh"), "--prepare", snap.name],
            env=env, capture_output=True, text=True, timeout=12)
        assert prepared.returncode == 3 and "[BLOCKED]" in prepared.stderr, (
            prepared.stdout, prepared.stderr)
        assert not (snap / "transaction").exists(), "foreign-chain preparation mutated snapshot"
        print("[PASS]", shell, "foreign mangle chain prevents transaction preparation")

# Rehearse ONLY on a synthetic fixture: temporarily remove KAS-owned files
# and a direct cron route, then prove originals were restored byte for byte.
for shell in SHELLS:
    for fault in ("none", "wrapper", "binary", "hook", "cron"):
        with tempfile.TemporaryDirectory(prefix="kas-uninstall-rehearse-") as temp:
            td = Path(temp)
            root, files, env = setup(td)
            env["KAS_TXN_FIXTURE_ROOT"] = str(root)
            if fault in ("none", "cron"):
                direct = "*/5 * * * * root /bin/sh /opt/etc/cron.5mins/mihomo_watchdog\n"
                files["opt/etc/crontab"] = direct
                (root / "opt/etc/crontab").write_text(direct)
            if fault != "none":
                env["KAS_TXN_TEST_FAIL_AT"] = fault
            p = run(shell, env, "--create")
            assert p.returncode == 0, (fault, p.stdout, p.stderr)
            snap = next((root / "opt/kas-uninstall-backups").iterdir())
            rehearsed = subprocess.run(
                shell + [str(BASE / "uninstall-transaction.sh"), "--rehearse", snap.name],
                env=env, capture_output=True, text=True, timeout=12)
            if fault == "none":
                assert rehearsed.returncode == 0 and "[PASS] Simulated" in rehearsed.stdout, (
                    fault, rehearsed.stdout, rehearsed.stderr)
            else:
                assert rehearsed.returncode == 3 and "[BLOCKED]" in rehearsed.stderr, (
                    fault, rehearsed.stdout, rehearsed.stderr)
            assert "TEST_SECRET_MUST_NOT_PRINT" not in rehearsed.stdout + rehearsed.stderr
            for rel, original in files.items():
                assert (root / rel).read_text() == original, ("rollback failed", fault, rel)
            assert not (root / "tmp/mihomo-lifecycle.lock.d").exists()
            assert not (root / "tmp/mihomo.maintenance").exists()
            print("[PASS]", shell, "file removal recovery rehearsal", fault)

print("[PASS] actual production uninstall remains BLOCKED")
