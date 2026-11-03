#!/usr/bin/env python3
"""Issue #320 stage A regression: update-mihomo.sh must WARN when the opkg
database still lists a mihomo package whose version differs from the binary
the updater just installed. A later plain `opkg upgrade` compares the stale
database against the feed and may replace the newer project-managed ELF with
an older feed one (reproduced offline with the pinned official Entware opkg;
see tests/test_opkg_downgrade_repro.py).

The check under test is diagnostics-only: it never sets an opkg flag/hold
and never writes the database. The block is extracted from the production
script between explicit markers (same approach as the PTY reader
extraction) and executed under every available shell with stubbed output
helpers.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SCRIPT = os.path.join(ROOT, "update-mihomo.sh")


def extract_block():
    src = open(SCRIPT, encoding="utf-8").read()
    match = re.search(
        r'^# BEGIN OPKG STALENESS CHECK v1\n(.*?)^# END OPKG STALENESS CHECK v1\n',
        src, re.S | re.M)
    return match.group(1) if match else None


def shells():
    out = []
    for path in ("/bin/sh", "/bin/dash", "/bin/busybox"):
        if os.path.exists(path):
            if path == "/bin/busybox":
                out.append(["/bin/busybox", "sh"])
            else:
                out.append([path])
    if not out:
        sh = shutil.which("sh")
        if sh:
            out.append([sh])
    return out


def run_block(shell_argv, opkg_meta, installed_ver="1.19.33"):
    block = extract_block()
    if block is None:
        raise AssertionError(
            "OPKG staleness check block (# BEGIN/END OPKG STALENESS CHECK v1) "
            "not found in update-mihomo.sh")
    with tempfile.TemporaryDirectory(prefix="kas-opkg-stale-") as workdir:
        wrapper = os.path.join(workdir, "block.sh")
        with open(wrapper, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(
                "#!/bin/sh\n"
                'WARNED=""\n'
                'LOGGED=""\n'
                'warn() { WARNED="$WARNED$1\\n"; }\n'
                'log() { LOGGED="$LOGGED$1\\n"; }\n'
                'BINARY_STATE="/opt/etc/keenetic-auto-setup-mihomo.state"\n'
                'INSTALLED_VER="%s"\n'
                'OPKG_META="%s"\n'
                % (installed_ver, opkg_meta)
                + block
                + 'printf "WARNED:%s\\n" "$WARNED"\n'
                  'printf "LOGGED:%s\\n" "$LOGGED"\n')
        os.chmod(wrapper, 0o755)
        result = subprocess.run(shell_argv + [wrapper], text=True,
                                capture_output=True, timeout=15,
                                encoding="utf-8", errors="replace")
        if result.returncode != 0:
            raise AssertionError("block failed rc=%r: %s"
                                 % (result.returncode, result.stderr))
        return result.stdout


def main():
    failures = 0

    def check(name, ok, detail=""):
        nonlocal failures
        if ok:
            print("PASS", name)
        else:
            print("FAIL", name, detail)
            failures += 1

    # The whole script must stay syntactically valid in every shell.
    for shell in shells():
        result = subprocess.run(shell + ["-n", SCRIPT], capture_output=True,
                                text=True)
        check("sh -n %s" % " ".join(shell), result.returncode == 0,
              result.stderr[:200])

    try:
        cases = run_block(shells()[0], "1.19.23-1")
    except AssertionError as error:
        print("FAIL", error)
        return 1

    # Stale database (the field downgrade setup): warning fires with both
    # versions and the issue pointer.
    check("stale DB warns", "opkg database lists mihomo as '1.19.23-1'" in cases
          and "1.19.33" in cases and "issue #320" in cases, repr(cases[-400:]))
    # Release-suffixed match and exact match: informational log only.
    for meta in ("1.19.33-1", "1.19.33"):
        out = run_block(shells()[0], meta)
        check("matching DB %s does not warn" % meta,
              "WARNED:\n" in out and "matches the installed binary" in out,
              repr(out[-200:]))
    # No opkg-managed mihomo package: fully silent.
    out = run_block(shells()[0], "")
    check("absent DB metadata is silent",
          "WARNED:\n" in out and "LOGGED:\n" in out, repr(out[-200:]))

    # The block must stay read-only diagnostics: never touch opkg state.
    # opkg may only be *mentioned* inside quoted message text, never invoked.
    block = extract_block() or ""
    for line in block.splitlines():
        if "opkg" not in line:
            continue
        code_part = line.split('"')[0].split("'")[0]
        check("line invokes no opkg command: %s" % line.strip()[:60],
              not re.search(r"\bopkg\b", code_part), repr(line[:120]))

    # Same behavior under every available shell.
    for shell in shells()[1:]:
        out = run_block(shell, "1.19.23-1")
        check("stale DB warns (%s)" % " ".join(shell),
              "opkg database lists mihomo as '1.19.23-1'" in out
              and "issue #320" in out, repr(out[-200:]))

    if failures:
        print("FAIL update-mihomo opkg-staleness regression: %d failure(s)"
              % failures)
        return 1
    print("ALL OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
