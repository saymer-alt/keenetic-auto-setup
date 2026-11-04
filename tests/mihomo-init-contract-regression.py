#!/usr/bin/env python3
"""Issue #355: Mihomo init-script resolution contract regression.

Upstream Entware renamed the packaged Mihomo init script S99mihomo ->
S28mihomo (Entware/entware-go commit ee4b689, script body unchanged) while
the saymer-alt/entware-go fork and older feeds still ship S99mihomo, so
both names are field realities. Before this contract every KAS tool chose
its own literal: config-import.sh and the installer hardcoded S99mihomo
(an S28-only installation failed before the import), and update-mihomo.sh
picked `find /opt/etc/init.d -name '*mihomo*' | head -1` — an arbitrary
script when a feed upgrade leaves both names behind.

Pinned contracts (the marked MIHOMO INIT RESOLUTION v1 block, identical in
every consumer):
  1. the block is byte-identical in every consumer (single contract, no
     drift) and every consumer calls it;
  2. only the two known names are candidates — no glob is used;
  3. exactly one executable candidate with verified package bytes resolves
     (S28-only and S99-only both work);
  4. two usable candidates fail CLOSED with state "ambiguous": KAS never
     picks one, because two Mihomo launches at boot would break the
     one-Mihomo invariant;
  5. a directory or a non-executable/dangling entry is unusable
     (notfile:/notexec: state with the offending path). Executable aliases
     count toward boot ambiguity and cannot be the trusted candidate;
  6. one usable candidate plus a leftover in another state still
     resolves the usable script (executable evidence wins);
  7. no known name exists -> state "absent", callers report the classic
     not-found error;
  8. end-to-end (root, disposable /opt): config-import.sh performs a
     recovery import against an S28-only fixture (previously it errored
     with "S99mihomo not found") and fails closed with the actionable
     "ambiguous" diagnostic when both names exist — config.yaml and the
     backup stay byte-identical in that case.

The unit section runs the extracted block under every available shell
with stubbed diagnostics. The E2E section runs only as root on a machine
without a real /opt/etc/init.d/S{28,99}mihomo or /opt/etc/mihomo
(config-import.sh file mode; no router is contacted, no init script is
renamed, chmoded or deleted).
"""
import os
import re
import shutil
import subprocess

from mihomo_init_fixture import INIT, write_package_init
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

CONSUMERS = ["config-import.sh", "update-mihomo.sh", "install.sh"]

BLOCK_RE = re.compile(
    r'^# BEGIN MIHOMO INIT RESOLUTION v1 \(issue #355\)\n(.*?)^# END MIHOMO INIT RESOLUTION v1\n',
    re.S | re.M)

failures = []


def check(name, ok, detail=""):
    if ok:
        print("[OK] %s" % name)
    else:
        print("[FAIL] %s%s" % (name, (": " + detail) if detail else ""))
        failures.append(name)


def extract_block(path):
    src = open(os.path.join(ROOT, path), encoding="utf-8").read()
    match = BLOCK_RE.search(src)
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


# (name, prepare(init_dir), expect_rc, expect_state)
MATRIX = [
    ("S99-only usable", lambda d: _mk(d, "S99mihomo", 0o755), 0, "S99mihomo"),
    ("S28-only usable", lambda d: _mk(d, "S28mihomo", 0o755), 0, "S28mihomo"),
    ("both usable -> ambiguous fail closed",
     lambda d: (_mk(d, "S28mihomo", 0o755), _mk(d, "S99mihomo", 0o755)),
     2, "ambiguous"),
    ("S99 non-executable -> notexec",
     lambda d: _mk(d, "S99mihomo", 0o644), 2, "notexec:/opt/etc/init.d/S99mihomo"),
    ("S99 symlink to executable file -> unverified",
     lambda d: _mk_symlink(d, "S99mihomo"), 2, "unverified:/opt/etc/init.d/S99mihomo"),
    ("S99 dangling symlink -> notexec",
     lambda d: _mk_dangling(d, "S99mihomo"), 2, "notexec:/opt/etc/init.d/S99mihomo"),
    ("S99 directory -> notfile",
     lambda d: _mk_dir(d, "S99mihomo"), 2, "notfile:/opt/etc/init.d/S99mihomo"),
    ("absent", lambda d: None, 1, "absent"),
    ("S28 usable + S99 leftover notexec -> S28 wins",
     lambda d: (_mk(d, "S28mihomo", 0o755), _mk(d, "S99mihomo", 0o644)),
     0, "S28mihomo"),
    ("S99 usable + S28 leftover dangling link -> S99 wins",
     lambda d: (_mk(d, "S99mihomo", 0o755), _mk_dangling(d, "S28mihomo")),
     0, "S99mihomo"),
    ("S28 usable + S99 leftover dangling link -> S28 wins",
     lambda d: (_mk(d, "S28mihomo", 0o755), _mk_dangling(d, "S99mihomo")),
     0, "S28mihomo"),
    ("S28 usable + S99 link to a foreign executable -> ambiguous fail closed",
     lambda d: (_mk(d, "S28mihomo", 0o755), _mk_foreign_link(d, "S99mihomo")),
     2, "ambiguous"),
]


def _mk(init_dir, name, mode):
    path = os.path.join(init_dir, name)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(INIT)
    os.chmod(path, mode)
    return path


SYMLINK_TARGETS = []


def _mk_symlink(init_dir, name):
    target = os.path.join(init_dir, name)
    holder = tempfile.mkdtemp(prefix="kas-mir-outside-")
    outside = os.path.join(holder, "outside.sh")
    with open(outside, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("#!/bin/sh\nexit 0\n")
    os.chmod(outside, 0o755)
    os.symlink(outside, target)
    SYMLINK_TARGETS.append(holder)
    return target


def _mk_dangling(init_dir, name):
    target = os.path.join(init_dir, name)
    os.symlink(os.path.join(init_dir, ".no-such-target"), target)
    return target


def _mk_foreign_link(init_dir, name):
    """A leftover *mihomo-named* link pointing at an unrelated executable:
    boot would run it, so after dereferencing both names are usable and
    ownership is ambiguous (fail closed, operator decides)."""
    target = os.path.join(init_dir, name)
    holder = tempfile.mkdtemp(prefix="kas-mir-foreign-")
    foreign = os.path.join(holder, "foreign-service.sh")
    with open(foreign, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("#!/bin/sh\nexit 0\n")
    os.chmod(foreign, 0o755)
    os.symlink(foreign, target)
    SYMLINK_TARGETS.append(holder)
    return target


def _mk_dir(init_dir, name):
    path = os.path.join(init_dir, name)
    os.makedirs(path)
    return path


def run_resolver_block(shell_argv, block, init_dir):
    """Call the resolver against a fixture init dir and report its contract.

    The production paths are absolute /opt/etc/init.d, so the fixture must
    BE that directory; the caller guarantees it is disposable.
    """
    with tempfile.TemporaryDirectory(prefix="kas-mir-run-") as workdir:
        wrapper = os.path.join(workdir, "block.sh")
        with open(wrapper, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(
                "#!/bin/sh\n"
                + block +
                'RC=0\n'
                'resolve_mihomo_init || RC=$?\n'
                'printf "RC=%s RESOLVED=%s STATE=%s\\n" "$RC" '
                '"$MIHOMO_INIT_RESOLVED" "$MIHOMO_INIT_STATE"\n')
        os.chmod(wrapper, 0o755)
        result = subprocess.run(shell_argv + [wrapper], capture_output=True,
                                text=True, timeout=15, encoding="utf-8",
                                errors="replace")
        if result.returncode != 0:
            raise AssertionError("block run failed rc=%r: %s"
                                 % (result.returncode, result.stderr))
        match = re.search(r"RC=(\d+) RESOLVED=(\S*) STATE=(\S*)",
                          result.stdout)
        if not match:
            raise AssertionError("no result line: %r" % result.stdout[-200:])
        return int(match.group(1)), match.group(2), match.group(3)


def fixture_guard():
    """E2E/unit fixtures need /opt free of a real Mihomo installation."""
    problems = []
    for name in ("S28mihomo", "S99mihomo", "rc.func"):
        path = "/opt/etc/init.d/" + name
        if os.path.lexists(path):
            problems.append("%s already exists (real install?)" % path)
    if os.path.exists("/opt/etc/mihomo/config.yaml"):
        problems.append("/opt/etc/mihomo/config.yaml already exists (real install?)")
    for binary in ("/opt/sbin/mihomo", "/opt/bin/mihomo"):
        if os.path.lexists(binary):
            problems.append("%s already exists (real install?)" % binary)
    return (not problems), "; ".join(problems)


def test_unit_contract():
    blocks = {}
    for consumer in CONSUMERS:
        block = extract_block(consumer)
        check("block present in %s" % consumer, block is not None)
        blocks[consumer] = block
    unique = {b for b in blocks.values() if b is not None}
    check("block is byte-identical in every consumer", len(unique) == 1,
          "%d distinct blocks" % len(unique))
    block = blocks[CONSUMERS[0]]
    if block is None:
        return

    # The contract must never glob for arbitrary *mihomo* scripts and
    # never write to the init directory (code lines only: the comment
    # header legitimately mentions names and arrows).
    check("no glob in the resolver block", "for _mir_path in" in block
          and "find /opt/etc/init.d" not in block)
    code_lines = [line for line in block.splitlines()
                  if not line.lstrip().startswith("#")]
    for verb in ("ln ", "mv ", "rm -f", "chmod", "touch", ">"):
        check("resolver never mutates (%s absent)" % verb.strip(),
              not any(verb in line for line in code_lines),
              repr([line for line in code_lines if verb in line][:1]))

    try:
        os.makedirs("/opt/etc/init.d", exist_ok=True)
        open("/opt/etc/init.d/rc.func", "w").close()
        for shell in shells():
            for name, prepare, want_rc, want_state in MATRIX:
                # Clean both candidate names between cases.
                for cand in ("S28mihomo", "S99mihomo"):
                    path = "/opt/etc/init.d/" + cand
                    if os.path.islink(path) or os.path.isfile(path):
                        os.remove(path)
                    elif os.path.isdir(path):
                        shutil.rmtree(path)
                prepare("/opt/etc/init.d")
                try:
                    rc, resolved, state = run_resolver_block(shell, block,
                                                             "/opt/etc/init.d")
                except AssertionError as error:
                    check("%s (%s)" % (name, " ".join(shell)), False, str(error))
                    continue
                want_resolved = "" if rc != 0 else "/opt/etc/init.d/" + want_state
                want_state_out = "" if want_rc == 0 else want_state
                ok = (rc == want_rc
                      and resolved == want_resolved
                      and state == want_state_out)
                check("%s (%s)" % (name, " ".join(shell)), ok,
                      "rc=%r resolved=%r state=%r" % (rc, resolved, state))
    finally:
        for cand in ("S28mihomo", "S99mihomo"):
            path = "/opt/etc/init.d/" + cand
            if os.path.islink(path) or os.path.isfile(path):
                os.remove(path)
            elif os.path.isdir(path):
                shutil.rmtree(path)
        if os.path.exists("/opt/etc/init.d/rc.func"):
            os.unlink("/opt/etc/init.d/rc.func")
        for holder in SYMLINK_TARGETS:
            shutil.rmtree(holder, ignore_errors=True)
        del SYMLINK_TARGETS[:]


def run_import(candidate_path):
    env = dict(os.environ)
    env["NO_COLOR"] = "1"
    env["TERM"] = "dumb"
    proc = subprocess.run(
        ["/bin/sh", os.path.join(ROOT, "config-import.sh"), candidate_path],
        capture_output=True, timeout=60, env=env)
    return proc.returncode, proc.stdout + proc.stderr


def test_e2e_import_s28():
    """config-import.sh with an S28-only fixture: recovery import proceeds
    (previously it hard-failed with 'S99mihomo not found'), and with both
    names present it fails closed without touching config or backup."""
    candidate = None
    try:
        os.makedirs("/opt/etc/init.d", exist_ok=True)
        os.makedirs("/opt/etc/mihomo", exist_ok=True)
        os.makedirs("/opt/sbin", exist_ok=True)
        with open("/opt/sbin/mihomo", "w", encoding="utf-8", newline="\n") as fh:
            fh.write("#!/bin/sh\nexit 0\n")
        os.chmod("/opt/sbin/mihomo", 0o755)
        write_package_init("/opt/etc/init.d/S28mihomo", "exit 0\n")

        config_path = "/opt/etc/mihomo/config.yaml"
        backup_path = "/opt/etc/mihomo/config.yaml.bak"
        good_bak = b"mixed-port: 7890\nmode: rule\nsecret: real-old\n"
        with open(backup_path, "wb") as fh:
            fh.write(good_bak)

        candidate = os.path.join(
            tempfile.gettempdir(), "kas-mir-candidate-%d.yaml" % os.getpid())
        with open(candidate, "wb") as fh:
            fh.write(b"mixed-port: 7890\nmode: rule\nsecret: null\ns28: yes\n")

        # S28-only: the import proceeds (the pre-contract behavior failed
        # with "Mihomo init script not found: /opt/etc/init.d/S99mihomo").
        rc, out = run_import(candidate)
        after = open(config_path, "rb").read() if os.path.exists(config_path) else b""
        check("E2E S28-only import proceeds", rc == 0 and b"s28: yes" in after
              and open(backup_path, "rb").read() == good_bak,
              "rc=%r tail=%r" % (rc, out[-160:]))

        # Both names: ambiguous, fail closed, nothing changed. The leftover
        # S99 makes the pre-import resolution fail BEFORE any mutation.
        write_package_init("/opt/etc/init.d/S99mihomo", "exit 0\n")
        with open(config_path, "wb") as fh:
            fh.write(b"")  # empty current config (recovery context)
        rc, out = run_import(candidate)
        after = open(config_path, "rb").read() if os.path.exists(config_path) else b""
        check("E2E both present fails closed untouched",
              rc != 0 and after == b"" and b"ambiguous" in out
              and open(backup_path, "rb").read() == good_bak
              and b"s28: yes" not in after,
              "rc=%r tail=%r" % (rc, out[-160:]))
    finally:
        for cand in ("S28mihomo", "S99mihomo"):
            path = "/opt/etc/init.d/" + cand
            if os.path.lexists(path):
                os.remove(path)
        for path in ("/opt/etc/init.d/rc.func",
                     "/opt/etc/mihomo/config.yaml",
                     "/opt/etc/mihomo/config.yaml.bak",
                     "/opt/sbin/mihomo"):
            try:
                if os.path.lexists(path):
                    os.remove(path)
            except OSError:
                pass
        if candidate and os.path.exists(candidate):
            os.remove(candidate)
        for path in ("/opt/etc/mihomo", "/opt/etc/init.d", "/opt/etc",
                     "/opt/sbin", "/opt"):
            try:
                os.rmdir(path)
            except OSError:
                pass


def main():
    for consumer in CONSUMERS:
        path = os.path.join(ROOT, consumer)
        if not os.path.exists(path):
            print("[FAIL] %s not found under %s" % (consumer, ROOT))
            return 1
    # Static caller contract: no consumer keeps a literal-only S99 entry
    # point and the updater must not glob anymore.
    updater = open(os.path.join(ROOT, "update-mihomo.sh"),
                   encoding="utf-8").read()
    check("updater no longer globs '*mihomo*' init scripts",
          "find /opt/etc/init.d -name '*mihomo*'" not in updater)
    importer = open(os.path.join(ROOT, "config-import.sh"),
                    encoding="utf-8").read()
    check("importer no longer hardcodes the S99 literal as INIT_SCRIPT",
          'INIT_SCRIPT="/opt/etc/init.d/S99mihomo"' not in importer)
    installer = open(os.path.join(ROOT, "install.sh"), encoding="utf-8").read()
    check("installer uses the resolver for the service action block",
          installer.count("resolve_mihomo_init") >= 2)

    ok, why = fixture_guard()
    if not ok:
        print("[SKIP] init-contract fixture tests (%s)" % why)
    else:
        test_unit_contract()
        test_e2e_import_s28()
    if failures:
        print("[FAIL] mihomo init contract regression: %d failure(s)"
              % len(failures))
        return 1
    print("[OK] mihomo init contract regression passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
