#!/usr/bin/env python3
"""One bounded production mutation: MT stopped-state must not become RUNNING.

Copies only install.sh and its existing regression test into a temporary lab.
Neither production files nor router/network configurations are modified.
A killed mutation is evidence for exactly this scenario, not full coverage.
"""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
START = "# BEGIN MAGITRICKLE RUNTIME STATE v1"
END = "# END MAGITRICKLE RUNTIME STATE v1"
BEFORE = '[ "$rc" -eq 1 ] && return 1'
AFTER = '[ "$rc" -eq 1 ] && return 0'


def execute(test_path, timeout=180):
    env = dict(os.environ, PYTHONOPTIMIZE="0")
    return subprocess.run([sys.executable, str(test_path)],
                          cwd=test_path.parent.parent, env=env,
                          capture_output=True, text=True, timeout=timeout)


def main():
    source = (ROOT / "install.sh").read_text(encoding="utf-8")
    test = ROOT / "tests" / "magitrickle-runtime-regression.py"
    if source.count(START) != 1 or source.count(END) != 1 or not test.is_file():
        raise RuntimeError("BLOCKED: required source or regression missing")
    first = source.index(START)
    last = source.index(END, first)
    block = source[first:last]
    if block.count(BEFORE) != 1:
        raise RuntimeError("BLOCKED: unique production mutation anchor changed")

    with tempfile.TemporaryDirectory(prefix="kas-mutation-mt-") as work:
        lab = Path(work)
        (lab / "tests").mkdir()
        staged_install = lab / "install.sh"
        staged_test = lab / "tests" / test.name
        shutil.copy2(test, staged_test)
        staged_install.write_text(source, encoding="utf-8")

        original = execute(staged_test)
        if original.returncode != 0:
            print("BLOCKED: baseline regression did not PASS in isolated lab", file=sys.stderr)
            return 1

        mutated = source[:first] + block.replace(BEFORE, AFTER, 1) + source[last:]
        staged_install.write_text(mutated, encoding="utf-8")
        result = execute(staged_test)
        if result.returncode == 0:
            print("FAIL: regression missed stopped=>running production mutation", file=sys.stderr)
            return 1
        if "AssertionError" not in result.stderr or "pidof" not in result.stderr:
            print("BLOCKED: mutation run failed for unrelated/unknown reason", file=sys.stderr)
            return 1
        print("PASS: MT production mutation killed (pidof rc=1 cannot imply RUNNING)")
        print("EVIDENCE: LOCAL/CI_LINUX_MOCK, isolated copy only; FIELD NOT_TESTED")
        return 0


if __name__ == "__main__":
    sys.exit(main())
