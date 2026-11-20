#!/usr/bin/env python3
"""Offline regression of setup.sh's actual wget fallback under sh/BusyBox ash.

The wget stub is a real executable on PATH (the timeout applet wraps
binaries, not shell functions — the previous shell-function stub silently
bypassed the wall-clock wrapper). It rejects calls missing the bounded
network inactivity timeout, simulates timed-out/partial/trickling transfers,
and verifies no stale destination survives a failure.

The wall-clock scenarios use SETUP_SMALL_TRANSFER_MAX_TIME=2 so the whole
suite stays offline, bounded and fast (~seconds); the production default
(20, matching the curl --max-time for the same payloads) is asserted on the
stub's argv in the non-trickle cases. No network calls, router operations
or real elapsed-time claims beyond the small bounded trickle budget.
"""
import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "setup.sh").read_text()
start = source.index("retry_wget_to_file() {")
end = source.index("\n}\n", start) + len("\n}")
REAL_FUNCTION = source[start:end]

WGET_STUB = r"""#!/usr/bin/python3
import os, sys, time
from pathlib import Path
args = sys.argv[1:]
lab = Path(os.environ["LAB"])
mode = os.environ.get("WGET_MODE", "fail-until-success")
with (lab / "args").open("a") as f:
    f.write(" ".join(args) + "\n")
count = lab / "count"
n = int(count.read_text()) if count.exists() else 0
count.write_text(str(n + 1))
dest = Path(args[args.index("-qO") + 1])
existed = dest.exists()
with (lab / "seen").open("a") as f:
    f.write("existed=%d\n" % existed)
if mode == "trickle":
    dest.write_text("trickle")
    for _ in range(300):          # real sleep: bytes keep arriving, so the
        time.sleep(1)             # per-read -T never fires; only a wall-clock
    sys.exit(28)                  # cap (timeout applet) can end the attempt
if mode == "slow-ok":
    time.sleep(1)                 # slower than nothing, well under any -T
    dest.write_text("#!/bin/sh\necho complete\n")
    sys.exit(0)
if mode == "fail-until-success" and n + 1 >= int(os.environ.get("SUCCESS_ON", "1")):
    dest.write_text("#!/bin/sh\necho complete\n")
    sys.exit(0)
dest.write_text("#!/bin/sh\necho partial\n")
sys.exit(28)
"""

GUARD = r"""
# Production defines the budget near the top of setup.sh; the extracted
# function under test needs the same default here.
SETUP_SMALL_TRANSFER_MAX_TIME="${SETUP_SMALL_TRANSFER_MAX_TIME:-20}"
command -v wget >/dev/null 2>&1 || { echo NO_WGET_STUB >&2; exit 97; }
if [ "$WANT_NO_TIMEOUT" = 1 ]; then
    if command -v timeout >/dev/null 2>&1; then
        echo TIMEOUT_LEAKED_INTO_PATH >&2
        exit 96
    fi
else
    command -v timeout >/dev/null 2>&1 || { echo NO_TIMEOUT_APPLET >&2; exit 95; }
fi
"""

TAIL = r"""
if retry_wget_to_file https://example.invalid/helper.sh "$LAB/download"; then
    echo RESULT=OK
else
    echo RESULT=FAILED
fi
"""


def run_case(label, shell, env_extra, want, checks):
    with tempfile.TemporaryDirectory(prefix="kas-internal-wget-") as temp:
        lab = Path(temp)
        (lab / "bin").mkdir()
        stub = lab / "bin" / "wget"
        stub.write_text(WGET_STUB, newline="\n")
        stub.chmod(0o755)
        no_timeout = env_extra.get("WANT_NO_TIMEOUT") == "1"
        if no_timeout:
            # PATH with only the lab bin: no timeout applet reachable, the
            # stub's absolute python3 shebang keeps it executable anyway.
            for name in ("rm",):
                link = lab / "bin" / name
                resolved = shutil.which(name)
                assert resolved, name
                link.symlink_to(resolved)
        env = dict(os.environ, LAB=str(lab), **env_extra)
        if no_timeout:
            env["PATH"] = str(lab / "bin")
        else:
            env["PATH"] = str(lab / "bin") + os.pathsep + os.environ["PATH"]
        script = "\n".join([GUARD, REAL_FUNCTION, TAIL])
        began = time.monotonic()
        proc = subprocess.run(
            shell + ["-c", script, "kas-wget-test"],
            capture_output=True, text=True, timeout=60,
            env=env, cwd=ROOT,
        )
        elapsed = time.monotonic() - began
        calls = (lab / "args").read_text().splitlines() if (lab / "args").exists() else []
        destination = lab / "download"
        assert proc.returncode == 0, (label, shell, proc.stdout, proc.stderr)
        assert ("RESULT=OK" in proc.stdout) == want, (label, proc.stdout, proc.stderr)
        for text in checks.get("stderr_absent", []):
            assert text not in proc.stderr, (label, proc.stderr)
        checks.get("assert", lambda ctx: None)({
            "calls": calls, "elapsed": elapsed, "lab": lab,
            "destination": destination, "stdout": proc.stdout,
        })
        print("PASS", "/".join(shell), label,
              "(%.1fs)" % elapsed if checks.get("timed") else "", flush=True)


def non_trickle_checks(ctx):
    calls, lab = ctx["calls"], ctx["lab"]
    assert len(calls) == WANT_COUNT, (label(), calls)
    assert all("-T 20 " in c + " " for c in calls), calls
    assert all("-qO " in c for c in calls), calls
    seen = (lab / "seen").read_text().splitlines()
    assert all(line == "existed=0" for line in seen), seen  # cleanup between attempts
    if WANT_SUCCESS:
        assert ctx["destination"].read_text() == "#!/bin/sh\necho complete\n"
    else:
        assert not ctx["destination"].exists(), "partial file survived"


def trickle_checks(ctx):
    calls, lab, elapsed = ctx["calls"], ctx["lab"], ctx["elapsed"]
    assert len(calls) == 3, calls
    assert all("-T 2 " in c + " " for c in calls), calls
    # The stub would run for 300s per attempt on its own; three bounded
    # attempts finishing this fast prove the wall-clock cap engaged.
    assert elapsed < 20, ("trickle attempts were not wall-clock bounded", elapsed)
    assert not ctx["destination"].exists(), "trickled partial survived"
    seen = (lab / "seen").read_text().splitlines()
    assert len(seen) == 3 and all(line == "existed=0" for line in seen), seen


CASES = [
    ("first_success", {"SUCCESS_ON": "1"}, True,
     {"count": 1, "success": True, "checks": non_trickle_checks}),
    ("timeout_then_success", {"SUCCESS_ON": "2"}, True,
     {"count": 2, "success": True, "checks": non_trickle_checks}),
    ("three_timeout_failures", {"SUCCESS_ON": "99"}, False,
     {"count": 3, "success": False, "checks": non_trickle_checks}),
]

_label = ""


def label():
    return _label


WANT_COUNT = 0
WANT_SUCCESS = False


def main():
    global _label, WANT_COUNT, WANT_SUCCESS
    shells = [["/bin/sh"]]
    busybox = shutil.which("busybox")
    if busybox:
        shells.append([busybox, "ash"])
    for shell in shells:
        for _label, env_extra, success, spec in CASES:
            WANT_COUNT, WANT_SUCCESS = spec["count"], spec["success"]
            run_case(_label, shell, env_extra, success, {"assert": spec["checks"]})
        # Wall-clock cap: every attempt trickles forever under -T; only the
        # timeout applet can end it. Budget 2s keeps the case fast.
        _label = "trickle_bounded_by_wall_clock"
        WANT_COUNT, WANT_SUCCESS = 3, False
        run_case(_label, shell, {"WGET_MODE": "trickle",
                                 "SETUP_SMALL_TRANSFER_MAX_TIME": "2"},
                 False, {"assert": trickle_checks, "timed": True})
        # Without a timeout applet the per-read bound stays the only limit,
        # the attempt still completes, and the guard proves the PATH really
        # had no timeout (issue #89: behaviour unchanged, no false caps).
        _label = "no_timeout_applet_per_read_preserved"
        WANT_COUNT, WANT_SUCCESS = 1, True
        run_case(_label, shell, {"WGET_MODE": "slow-ok",
                                 "WANT_NO_TIMEOUT": "1", "EXTRA_PATH": ""},
                 True, {"assert": non_trickle_checks})
    print("PASS setup.sh real wget function bounded read/wall-clock timeout and cleanup")


if __name__ == "__main__":
    main()
