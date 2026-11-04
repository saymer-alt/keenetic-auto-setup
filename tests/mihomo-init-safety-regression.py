#!/usr/bin/env python3
"""Exercise every shipped resolver and the watchdog outcome contract."""

from pathlib import Path
import re
import shlex
import shutil
import subprocess

from mihomo_init_fixture import INIT
import tempfile


ROOT = Path(__file__).resolve().parent.parent
CONSUMERS = ("install.sh", "update-mihomo.sh", "config-import.sh", "mihomo-watchdog.sh")


def function(text, name):
    match = re.search(rf"^{name}\(\) \{{.*?^\}}", text, re.M | re.S)
    return match[0] if match else ""


def run(shell, body, expected):
    result = subprocess.run(shell, input=body, text=True, capture_output=True, timeout=20)
    assert result.returncode == 0 and expected in result.stdout, (shell, expected, result)
    return result.stdout


def test_resolver(shell, consumer, lab):
    source = (ROOT / consumer).read_text()
    start = source.index("# BEGIN MIHOMO INIT RESOLUTION")
    end = source.index("# END MIHOMO INIT RESOLUTION", start)
    block = source[start:end].replace("/opt/etc/init.d", str(lab))
    candidate = lab / "S28mihomo"
    foreign = lab / "foreign"
    foreign.write_text("#!/bin/sh\necho foreign-executed\n")
    foreign.chmod(0o755)
    (lab / "rc.func").touch()
    body = '\nrc=0; resolve_mihomo_init || rc=$?; printf "%s:%s\\n" "$rc" "$MIHOMO_INIT_RESOLVED"\n'
    candidate.symlink_to(foreign)
    run(shell, block + body, "2:\n")
    candidate.unlink()
    candidate.write_text("#!/missing-interpreter\nexit 0\n")
    candidate.chmod(0o755)
    run(shell, block + body, "2:\n")
    candidate.write_text(INIT)
    run(shell, block + body, f"0:{candidate}\n")
    run(shell, block + body + f"rm {shlex.quote(str(candidate))}\n" + body, "1:\n")
    print(f"PASS {consumer} {shell}: foreign link, missing interpreter, stale result")


def test_watchdog(shell, lab):
    source = (ROOT / "mihomo-watchdog.sh").read_text()
    code = function(source, "can_restart")
    pre = f'''
RESTART_STATE={shlex.quote(str(lab / "cooldown"))}
MIN_RESTART_INTERVAL=300
reset_healthy_heartbeat() {{ :; }}
ml_lifecycle_acquire() {{ :; }}
ml_lifecycle_release() {{ :; }}
mp_known() {{ :; }}
mp_running() {{ :; }}
sleep() {{ :; }}
log() {{ printf '%s\\n' "$*"; }}
resolve_mihomo_init() {{
    MIHOMO_INIT_STATE=absent
    MIHOMO_INIT_RESOLVED=restart_command
    [ "$CASE" != skipped ]
}}
restart_command() {{
    [ "$CASE" != failed ] || return 7
    : > "$RESTART_STATE.called"
}}
wd_restart_identity() {{
    case "$CASE" in
        unknown) return 2 ;;
        verified|overlap) [ ! -f "$RESTART_STATE.called" ] || {{ echo "25 200"; return; }} ;;
    esac
    echo "12 100"
}}
wd_old_identity_gone() {{ [ "$CASE" != overlap ]; }}
'''
    for case, verdict in (("skipped", "SKIPPED"), ("failed", "FAILED"),
                          ("old", "UNKNOWN"), ("overlap", "UNKNOWN"), ("unknown", "SKIPPED"),
                          ("verified", "VERIFIED")):
        for name in ("cooldown", "cooldown.called"):
            (lab / name).unlink(missing_ok=True)
        output = run(shell, pre + code + f"\nCASE={case}; can_restart fixture || :\n",
                     f"[RESTART-{verdict}]")
        assert "[RESTART-OK]" not in output, output
        assert (lab / "cooldown").exists() == (case in ("failed", "old", "overlap", "verified")), case
    print(f"PASS watchdog {shell}: skipped, failed, unchanged, unknown, verified")


if __name__ == "__main__":
    shells = [["/bin/sh"]]
    if shutil.which("busybox"):
        shells.append(["busybox", "ash"])
    for shell in shells:
        for consumer in CONSUMERS:
            with tempfile.TemporaryDirectory() as tmp:
                test_resolver(shell, consumer, Path(tmp))
        with tempfile.TemporaryDirectory() as tmp:
            test_watchdog(shell, Path(tmp))
