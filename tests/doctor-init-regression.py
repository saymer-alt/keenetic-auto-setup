#!/usr/bin/env python3
"""Exercise Doctor's actual read-only service section in an isolated prefix."""
from pathlib import Path
import shutil
import subprocess
import tempfile

from mihomo_init_fixture import INIT


ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "mihomo-doctor.sh").read_text()
start = source.index('hdr "5. Service"')
end = source.index('hdr "6. Ports"', start)
# The resolver is inside this service section; extracting it a second time
# would execute duplicate declarations and weaken the fidelity of the fixture.
section = source[start:end]
assert "# BEGIN MIHOMO INIT RESOLUTION v1" in section
assert "# END MIHOMO INIT RESOLUTION v1" in section


def run_case(shell, first, second, expected, *, runtime=True, procs=1):
    with tempfile.TemporaryDirectory() as tmp:
        opt = Path(tmp)
        init = opt / "etc/init.d"
        init.mkdir(parents=True)
        if runtime:
            (init / "rc.func").write_text("echo UNEXPECTED-EXECUTION\n")
        foreign = opt / "foreign"
        foreign.write_text("#!/bin/sh\necho UNEXPECTED-EXECUTION\n")
        foreign.chmod(0o755)
        (init / "S99mihomo-backup").write_bytes(foreign.read_bytes())
        for name, kind in (("S28mihomo", first), ("S99mihomo", second)):
            path = init / name
            if kind == "absent":
                continue
            if kind in ("dangling", "link"):
                path.symlink_to(foreign if kind == "link" else opt / "absent")
                continue
            path.write_text(INIT if kind in ("package", "disabled") else foreign.read_text())
            path.chmod(0o644 if kind == "disabled" else 0o755)
        before = [(p.name, p.lstat().st_mode, p.readlink() if p.is_symlink() else p.read_bytes())
                  for p in sorted(init.iterdir())]
        prelude = '''
hdr() { :; }
ok() { printf 'OK %s\\n' "$*"; }
warn() { printf 'WARN %s\\n' "$*"; }
fail() { printf 'FAIL %s\\n' "$*"; }
info() { printf 'INFO %s\\n' "$*"; }
OPT_ROOT=$1
MIHOMO_PROCS=$2
'''
        result = subprocess.run(shell + ["-s", str(opt), str(procs)], input=prelude + section,
                                text=True, capture_output=True, check=True)
        after = [(p.name, p.lstat().st_mode, p.readlink() if p.is_symlink() else p.read_bytes())
                 for p in sorted(init.iterdir())]
        assert before == after
        assert "UNEXPECTED-EXECUTION" not in result.stdout
        assert all(part in result.stdout for part in expected), result.stdout
        assert "managed by" not in result.stdout, result.stdout


for shell in (["dash"], ["busybox", "ash"]):
    assert shutil.which(shell[0]), shell
    for first, second, expected in (
        ("package", "absent", ("OK Verified Mihomo init", "/S28mihomo")),
        ("absent", "package", ("OK Verified Mihomo init", "/S99mihomo")),
        ("package", "package", ("WARN", "UNVERIFIED", "ambiguous")),
        ("absent", "absent", ("INFO", "absent", "WARN")),
        ("package", "disabled", ("OK Verified Mihomo init", "/S28mihomo")),
        ("package", "link", ("WARN", "UNVERIFIED", "ambiguous")),
        ("package", "foreign", ("WARN", "UNVERIFIED", "ambiguous")),
        ("absent", "dangling", ("WARN", "UNVERIFIED", "notexec")),
        ("link", "absent", ("WARN", "UNVERIFIED", "unverified")),
        ("absent", "foreign", ("WARN", "UNVERIFIED", "unverified")),
    ):
        run_case(shell, first, second, expected)
    run_case(shell, "package", "absent", ("WARN", "UNVERIFIED", "runtime"), runtime=False)
    run_case(shell, "absent", "absent", ("FAIL",), procs=0)
    run_case(shell, "foreign", "absent", ("FAIL", "UNVERIFIED"), procs=0)
    run_case(shell, "package", "absent", ("WARN", "runtime UNKNOWN"), procs=-1)
    print(f"PASS Doctor service matrix {shell}")
