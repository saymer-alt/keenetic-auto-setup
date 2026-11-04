"""Fixtures for the package-init resolver and isolated lifecycle suites."""

import hashlib
from pathlib import Path

INIT = """#!/bin/sh

ENABLED=yes
PROCS=mihomo
ARGS="-d /opt/etc/$PROCS"
PREARGS=""
DESC=$PROCS
PATH=/opt/sbin:/opt/bin:/opt/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

. /opt/etc/init.d/rc.func
"""


def write_package_init(path, rc_func):
    path = Path(path)
    path.write_bytes(INIT.encode())
    path.chmod(0o755)
    path.with_name("rc.func").write_text(rc_func, encoding="utf-8", newline="\n")


def pin_fixture_init(source, path):
    """Trust the exact synthetic script only in the generated lab script."""
    expected = hashlib.sha256(INIT.encode()).hexdigest()
    fixture = hashlib.sha256(Path(path).read_bytes()).hexdigest()
    return source.replace(expected, fixture)
