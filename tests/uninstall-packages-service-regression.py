#!/usr/bin/env python3
"""Offline behavioural checks for ordinary service stop -> OPKG remove."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading

SCRIPT = Path(__file__).resolve().parents[1] / "uninstall-packages.sh"
SHELLS = [["sh"]] + ([["busybox", "ash"]] if shutil.which("busybox") else [])


def make(root: Path, scenario: str) -> dict:
    (root / ".kas-uninstall-test").write_text("KAS_UNINSTALL_TEST_V1\n")
    for sub in ("tmp", "bin", "opt/bin", "opt/etc/init.d", "opt/etc/cron.5mins",
                "opt/etc/ndm/netfilter.d", "opt/etc/keenetic-auto-setup",
                "opt/etc/opkg", "opt/etc/mihomo", "opt/var/lib/magitrickle"):
        (root / sub).mkdir(parents=True, exist_ok=True)
    (root / "opt/etc/mihomo/config.yaml").write_text("user: mihomo\n")
    (root / "opt/var/lib/magitrickle/config.yaml").write_text("user: magitrickle\n")
    (root / "opt/etc/crontab").write_text(
        "*/5 * * * * root /bin/sh /opt/etc/cron.5mins/mihomo_watchdog\n"
        "0 0 * * * root echo keep\n")
    wrapper = root / "opt/etc/cron.5mins/mihomo_watchdog"
    wrapper.write_text('#!/bin/sh\nexec /opt/bin/mihomo_watchdog.sh "$@"\n')
    (root / "opt/bin/mihomo_watchdog.sh").write_text(
        "#!/bin/sh\n# MIHOMO WATCHDOG SCRIPT\n")
    (root / "opt/etc/opkg/magitrickle.conf").write_text("src/gz magitrickle example\n")
    (root / "opt/etc/ndm/netfilter.d/020-bypass_wa.sh").write_text(
        '#!/bin/sh\nchain="_CUST_BYPASS_WA_"\n')
    (root / "opt/etc/keenetic-auto-setup/ownership.v1").write_text(
        "KAS_OWNERSHIP_V1\nowned|repository|magitrickle.conf\n"
        "owned|hook|020-bypass_wa.sh\n")
    (root / "router-network-state").write_text("foreign policy and routes\n")
    for pkg, daemon in (("mihomo", "mihomo"), ("magitrickle", "magitrickled")):
        (root / f"tmp/{daemon}.running").write_text("1")
        if scenario != "none":
            (root / f"tmp/{pkg}.installed").write_text("1")
        init = root / f"opt/etc/init.d/S99{pkg}"
        init.write_text(
            '#!/bin/sh\nENABLED=yes\n'
            f'echo "{pkg}:$1" >> "$TEST_ROOT/actions"\n'
            f'[ "$1" = stop ] || exit 0\n'
            f'grep -qx ENABLED=yes "$TEST_ROOT/opt/etc/init.d/S99{pkg}" || exit 7\n'
            f'[ "$TEST_STUCK" = "{pkg}" ] || rm -f "$TEST_ROOT/tmp/{daemon}.running"\n')
        init.chmod(0o755)
    (root / "bin/pidof").write_text(
        '#!/bin/sh\n[ -f "$TEST_ROOT/tmp/$1.running" ]\n')
    (root / "bin/opkg").write_text(
        '#!/bin/sh\n'
        'case "$1" in\n'
        'list-installed)\n'
        '  for p in mihomo magitrickle; do\n'
        '    [ ! -f "$TEST_ROOT/tmp/$p.installed" ] || echo "$p - 1.0";\n'
        '  done; exit 0 ;;\n'
        'remove) echo "remove:$2" >> "$TEST_ROOT/actions"\n'
        '  [ "$TEST_CASE" != opkg_error ] || [ "$2" != mihomo ] || exit 4\n'
        '  rm -f "$TEST_ROOT/tmp/$2.installed"\n'
        '  case "$2" in\n'
        '    mihomo) rm -f "$TEST_ROOT/opt/etc/mihomo/config.yaml";;\n'
        '    magitrickle) rm -f "$TEST_ROOT/opt/var/lib/magitrickle/config.yaml";;\n'
        '  esac; exit 0 ;;\n'
        'esac\nexit 2\n')
    for name in ("opkg", "pidof"):
        (root / f"bin/{name}").chmod(0o755)
    env = os.environ.copy()
    env.update(
        KAS_UNINSTALL_TEST_ROOT=str(root), TEST_ROOT=str(root),
        TEST_CASE=scenario, TEST_STUCK="mihomo" if scenario == "stuck" else "",
        PATH=str(root / "bin") + os.pathsep + os.environ["PATH"])
    return env


for shell in SHELLS:
    for scenario, args, rc in (
        ("normal", [], 0),
        ("normal", ["--cleanup"], 0),
        ("normal", ["--purge-config"], 0),
        ("stuck", [], 1),
        ("opkg_error", [], 1),
        ("none", [], 0),
        ("watchdog_busy", [], 1),
        ("watchdog_settles", [], 0),
        ("foreign_cron", [], 1),
    ):
        with tempfile.TemporaryDirectory(prefix="kas-uninstall-test-") as temp:
            root = Path(temp)
            env = make(root, scenario)
            if scenario in ("watchdog_busy", "watchdog_settles"):
                lock = root / "tmp/mihomo_watchdog.lock.d"
                lock.mkdir()
                if scenario == "watchdog_settles":
                    done = threading.Event()
                    def finish_watchdog():
                        lock.rmdir()
                        done.set()
                    threading.Timer(0.2, finish_watchdog).start()
            if scenario == "foreign_cron":
                with (root / "opt/etc/crontab").open("a") as stream:
                    stream.write("*/5 * * * * root /bin/sh /foreign/mihomo_watchdog\n")
            result = subprocess.run(shell + [str(SCRIPT), *args], env=env,
                                    capture_output=True, text=True, timeout=20)
            assert result.returncode == rc, (shell, scenario, result)
            actions = (root / "actions").read_text().splitlines() if (
                root / "actions").exists() else []
            if scenario in ("normal", "stuck", "opkg_error", "watchdog_settles"):
                assert "mihomo:stop" in actions
                assert "magitrickle:stop" in actions
                expected_disabled = scenario != "stuck"
                assert ("ENABLED=no" in (
                    root / "opt/etc/init.d/S99mihomo").read_text()) == expected_disabled
            if scenario in ("watchdog_busy", "foreign_cron"):
                assert not actions, (shell, scenario, actions)
            if scenario == "watchdog_settles":
                assert done.wait(3), "watchdog lock did not settle"
            assert "0 0 * * * root echo keep" in (
                root / "opt/etc/crontab").read_text()
            if scenario != "foreign_cron":
                assert "mihomo_watchdog" not in (
                    root / "opt/etc/crontab").read_text()
            assert (
                root / "opt/etc/cron.5mins/mihomo_watchdog").exists() == (
                    scenario == "foreign_cron")
            assert (root / "router-network-state").read_text() == (
                "foreign policy and routes\n")
            assert ("remove:mihomo" in actions) == (
                scenario not in ("stuck", "none", "watchdog_busy", "foreign_cron"))
            assert ("remove:magitrickle" in actions) == (
                scenario not in ("none", "watchdog_busy", "foreign_cron"))
            if scenario == "normal" and args != ["--purge-config"]:
                assert (root / "opt/etc/mihomo/config.yaml").read_text() == (
                    "user: mihomo\n")
            if args == ["--purge-config"]:
                assert not (root / "opt/etc/mihomo/config.yaml").exists()
            if args == ["--cleanup"]:
                assert not (root / "opt/etc/opkg/magitrickle.conf").exists()
                assert not (root / "opt/etc/ndm/netfilter.d/020-bypass_wa.sh").exists()
            else:
                assert (root / "opt/etc/opkg/magitrickle.conf").exists()
            if scenario == "stuck":
                assert (root / "tmp/mihomo.installed").exists()
                # A first stop failed. Second run must retry *working* init stop.
                env["TEST_STUCK"] = ""
                env["TEST_CASE"] = "normal"
                retry = subprocess.run(shell + [str(SCRIPT)], env=env,
                                       capture_output=True, text=True, timeout=20)
                assert retry.returncode == 0, (shell, retry)
                assert not (root / "tmp/mihomo.installed").exists()
                assert not (root / "tmp/magitrickle.installed").exists()
                assert (root / "opt/etc/mihomo/config.yaml").read_text() == "user: mihomo\n"
                actions = (root / "actions").read_text().splitlines()
                assert actions.count("mihomo:stop") == 2, actions
                # A third run must be idempotent: do not stop/remove packages again.
                again = subprocess.run(shell + [str(SCRIPT)], env=env,
                                       capture_output=True, text=True, timeout=20)
                assert again.returncode == 0, (shell, again)
                assert actions == (root / "actions").read_text().splitlines()
            print("[PASS]", " ".join(shell), scenario, args)
print("[PASS] native init stop, watchdog, OPKG, YAML, optional cleanup and foreign state")
