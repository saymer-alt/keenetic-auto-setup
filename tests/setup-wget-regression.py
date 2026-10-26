#!/usr/bin/env python3
"""Offline regression of setup.sh's actual wget fallback under sh/BusyBox ash.

Mock wget rejects calls missing the bounded network inactivity timeout,
simulates timed-out/partial transfers, and verifies no stale destination.
No network calls, router operations or real elapsed-time claims.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "setup.sh").read_text()
start = source.index("retry_wget_to_file() {")
end = source.index("\n}\n", start) + len("\n}")
REAL_FUNCTION = source[start:end]

HARNESS = r"""
set -eu
LAB=$1
SUCCESS_ON=$2
sleep() { :; }
wget() {
    printf '%s\n' "$*" >> "$LAB/args"
    if [ "$#" -ne 5 ] || [ "$1" != -qO ] || [ "$3" != -T ] || \
       [ "$4" != 20 ] || [ "$5" != https://example.invalid/helper.sh ]; then
        echo BAD_WGET_ARGS >&2
        return 88
    fi
    count=0
    [ ! -f "$LAB/count" ] || count=$(cat "$LAB/count")
    count=$((count + 1))
    printf '%s\n' "$count" > "$LAB/count"
    if [ "$SUCCESS_ON" -eq "$count" ]; then
        printf '#!/bin/sh\necho complete\n' > "$2"
        return 0
    fi
    printf '#!/bin/sh\necho partial\n' > "$2"
    return 28
}
"""
TAIL = r"""
if retry_wget_to_file https://example.invalid/helper.sh "$LAB/download"; then
    echo RESULT=OK
else
    echo RESULT=FAILED
fi
"""


def run_case(shell, label, succeed_on, want_count, want_success):
    with tempfile.TemporaryDirectory(prefix="kas-internal-wget-") as temp:
        lab = Path(temp)
        script = HARNESS + "\n" + REAL_FUNCTION + "\n" + TAIL
        proc = subprocess.run(
            shell + ["-c", script, "kas-wget-test", temp, str(succeed_on)],
            capture_output=True, text=True, timeout=8,
            env=os.environ.copy(), cwd=ROOT,
        )
        calls = (lab / "args").read_text().splitlines()
        destination = lab / "download"
        assert proc.returncode == 0, (shell, label, proc.stdout, proc.stderr)
        assert "BAD_WGET_ARGS" not in proc.stderr, (shell, label, proc.stderr)
        assert len(calls) == want_count, (shell, label, calls)
        assert all(" -T 20 " in " " + c + " " for c in calls), calls
        assert ("RESULT=OK" in proc.stdout) == want_success, proc.stdout
        if want_success:
            assert destination.read_text() == "#!/bin/sh\necho complete\n"
        else:
            assert not destination.exists(), (shell, label, "partial file survived")
        print("PASS", "/".join(shell), label)


def main():
    shells = [["/bin/sh"]]
    busybox = shutil.which("busybox")
    if busybox:
        shells.append([busybox, "ash"])
    for shell in shells:
        run_case(shell, "three_timeout_failures", 0, 3, False)
        run_case(shell, "timeout_then_success", 2, 2, True)
        run_case(shell, "first_success", 1, 1, True)
    print("PASS setup.sh real wget function bounded read timeout/cleanup")


if __name__ == "__main__":
    main()
