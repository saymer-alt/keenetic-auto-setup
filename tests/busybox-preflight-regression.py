#!/usr/bin/env python3
"""Issue #356: KAS Entware/BusyBox preflight regression (read-only).

The preflight (kas-entware-preflight.sh) must diagnose the Entware
runtime surface from the SYSTEM shell — its control flow never depends
on a /opt binary — and classify every state explicitly as PASS, WARN,
FAIL or UNKNOWN without repairing anything.

Fixture states (all under a disposable /opt, guarded against a real
install; the fake busybox is a shell script implementing --list,
readlink -f and --help):
  1. healthy runtime: busybox + sh + applet links + real wget file +
     readable opkg -> exit 0, no FAIL/UNKNOWN;
  2. interrupted upgrade (the field state): prerm deleted every
     busybox-owned link including /opt/bin/sh and /opt/bin/chmod,
     postinst never ran -> FAIL for sh and every missing provided
     applet, FAIL for the missing wget, exit 1;
  3. dangling applet link: the official postinst [ ! -e ] skips it, so
     the state must be reported as a FAIL with that exact explanation;
  4. broken busybox binary (not executable): FAIL busybox-binary, the
     applet presence cannot be established -> WARN (not FAIL) lines;
  5. busybox present but does not execute (ELF/ABI/loader): FAIL with
     the explicit manual-rescue wording;
  6. wget pointing at the busybox applet: WARN no-HTTPS capability
     (Entware #887 class), exit still 0;
  7. no opkg: UNKNOWN opkg-view and exit 2 when nothing failed.

The suite runs the script under every available shell (dash, BusyBox
ash) and asserts severities and exit codes, never file mutations.
"""
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SCRIPT = os.path.join(ROOT, "kas-entware-preflight.sh")

APPLETS = ["chmod", "ln", "rm", "cp", "mv", "ls", "cat", "grep", "sed",
           "awk", "wget"]

failures = []


def check(name, ok, detail=""):
    if ok:
        print("[OK] %s" % name)
    else:
        print("[FAIL] %s%s" % (name, (": " + detail) if detail else ""))
        failures.append(name)


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


FAKE_BUSYBOX = r"""#!/bin/sh
# Synthetic busybox: implements --list, readlink -f, --help; exits 0.
case "$1" in
    --list)
        for a in sh chmod ln rm cp mv ls cat grep sed awk wget readlink; do
            printf '%s\n' "$a"
        done
        exit ${FAKE_BB_LIST_RC:-0}
        ;;
    readlink)
        # readlink -f /opt/bin/wget | /opt/bin/busybox -> canonical target
        case "$3" in
            /opt/bin/wget) printf '/opt/bin/busybox\n' ;;
            *) printf '/opt/bin/busybox\n' ;;
        esac
        exit 0
        ;;
esac
exit ${FAKE_BB_RC:-0}
"""

FAKE_OPKG = """#!/bin/sh
[ "$1" = status ] || exit 0
[ "$2" = busybox ] || exit 0
printf 'Package: busybox\\nVersion: 1.38.0-3\\nStatus: install ok installed\\n'
"""

GUARD_PATHS = ["/opt/bin/busybox", "/opt/bin/sh", "/opt/bin/opkg",
               "/opt/etc/mihomo/config.yaml"]


def fixture_guard():
    problems = [p for p in GUARD_PATHS if os.path.lexists(p)]
    return (not problems), "; ".join(problems)


class Fixture:
    """Disposable /opt tree; only removes what it created."""

    def __init__(self):
        self.created = []
        os.makedirs("/opt/bin", exist_ok=True)
        os.makedirs("/opt/usr/bin", exist_ok=True)
        os.makedirs("/opt/sbin", exist_ok=True)
        self._existed_opt = os.path.isdir("/opt")

    def bin(self, name, body, mode=0o755):
        path = "/opt/bin/" + name
        with open(path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(body)
        os.chmod(path, mode)
        self.created.append(path)
        return path

    def link(self, name, target):
        path = "/opt/bin/" + name
        os.symlink(target, path)
        self.created.append(path)
        return path

    def install_healthy(self, wget_is_applet=False, with_opkg=True):
        self.bin("busybox", FAKE_BUSYBOX)
        self.link("sh", "/opt/bin/busybox")
        for applet in APPETS_EXCEPT_WGET:
            self.link(applet, "/opt/bin/busybox")
        if wget_is_applet:
            self.link("wget", "/opt/bin/busybox")
        else:
            self.bin("wget", "#!/bin/sh\nexit 0\n")
        if with_opkg:
            self.bin("opkg", FAKE_OPKG)

    def install_busybox_only(self):
        """The interrupted-upgrade state: prerm removed every link."""
        self.bin("busybox", FAKE_BUSYBOX)

    def cleanup(self):
        for path in reversed(self.created):
            if os.path.islink(path) or os.path.isfile(path):
                os.remove(path)
            elif os.path.isdir(path):
                shutil.rmtree(path)
        for path in ("/opt/usr/bin", "/opt/usr", "/opt/sbin", "/opt/bin",
                     "/opt/etc/mihomo", "/opt/etc", "/opt"):
            try:
                os.rmdir(path)
            except OSError:
                pass


APPETS_EXCEPT_WGET = [a for a in APPLETS if a != "wget"]


def run_preflight(shell_argv, env_extra=None):
    env = dict(os.environ)
    env["NO_COLOR"] = "1"
    if env_extra:
        env.update(env_extra)
    proc = subprocess.run(shell_argv + [SCRIPT], capture_output=True,
                          timeout=60, env=env)
    lines = (proc.stdout + proc.stderr).decode("utf-8", "replace")
    return proc.returncode, lines


def sev(lines, check_id):
    out = []
    for line in lines.splitlines():
        if check_id in line:
            out.append(line.split(":", 1)[0].strip())
    return out


def run_matrix(name, setup, asserts, env_extra=None):
    """Run one fixture state under every shell and apply asserts."""
    for shell in shells():
        fx = Fixture()
        try:
            setup(fx)
            rc, lines = run_preflight(shell, env_extra)
            asserts(name, shell, rc, lines)
        finally:
            fx.cleanup()


def main():
    if not os.path.exists(SCRIPT):
        print("[FAIL] kas-entware-preflight.sh not found under %s" % ROOT)
        return 1
    ok, why = fixture_guard()
    if not ok:
        print("[SKIP] busybox preflight regression (%s)" % why)
        return 0

    # 1. healthy runtime
    def healthy(fx):
        fx.install_healthy()

    def assert_healthy(name, shell, rc, lines):
        check("healthy exit 0 (%s)" % " ".join(shell), rc == 0,
              "rc=%r tail=%r" % (rc, lines[-200:]))
        check("healthy no FAIL/UNKNOWN (%s)" % " ".join(shell),
              "\nFAIL:" not in lines and "\nUNKNOWN:" not in lines, lines)
        check("healthy wget capability PASS (%s)" % " ".join(shell),
              sev(lines, "wget-capability") == ["PASS"], lines)
        check("healthy opkg PASS (%s)" % " ".join(shell),
              sev(lines, "opkg-view") == ["PASS"], lines)

    run_matrix("healthy", healthy, assert_healthy)

    # 2. interrupted upgrade: every busybox-owned link deleted
    def interrupted(fx):
        fx.install_busybox_only()

    def assert_interrupted(name, shell, rc, lines):
        check("interrupted exit 1 (%s)" % " ".join(shell), rc == 1,
              "rc=%r tail=%r" % (rc, lines[-200:]))
        check("interrupted sh FAIL (%s)" % " ".join(shell),
              sev(lines, "opt-sh") == ["FAIL"], lines)
        for applet in ("chmod", "ln", "wget"):
            check("interrupted %s FAIL (%s)" % (applet, " ".join(shell)),
                  sev(lines, "applet-%s" % applet) == ["FAIL"], lines)
        check("interrupted wget-capability FAIL (%s)" % " ".join(shell),
              sev(lines, "wget-capability") == ["FAIL"], lines)
        check("interrupted busybox PASS (%s)" % " ".join(shell),
              sev(lines, "busybox-binary") == ["PASS"], lines)

    run_matrix("interrupted", interrupted, assert_interrupted)

    # 3. dangling applet link (postinst [ ! -e ] cannot repair)
    def dangling(fx):
        fx.install_healthy()
        path = "/opt/bin/chmod"
        os.remove(path)
        os.symlink("/opt/bin/.gone-target", path)
        fx.created.append(path)

    def assert_dangling(name, shell, rc, lines):
        check("dangling exit 1 (%s)" % " ".join(shell), rc == 1,
              "rc=%r" % rc)
        check("dangling chmod FAIL with postinst explanation (%s)" % " ".join(shell),
              sev(lines, "applet-chmod") == ["FAIL"]
              and "[ ! -e ]" in lines and "will not repair" in lines, lines)

    run_matrix("dangling", dangling, assert_dangling)

    # 4. busybox binary not executable
    def notexec(fx):
        fx.bin("busybox", FAKE_BUSYBOX, mode=0o644)
        fx.link("sh", "/opt/bin/busybox")

    def assert_notexec(name, shell, rc, lines):
        check("notexec busybox FAIL (%s)" % " ".join(shell),
              rc == 1 and sev(lines, "busybox-binary") == ["FAIL"], lines)
        check("notexec applets WARN not FAIL (%s)" % " ".join(shell),
              sev(lines, "applet-chmod") == ["WARN"], lines)

    run_matrix("notexec", notexec, assert_notexec)

    # 5. busybox present but does not execute (ABI/loader)
    def execfail(fx):
        fx.bin("busybox", FAKE_BUSYBOX, mode=0o755)
        fx.link("sh", "/opt/bin/busybox")

    def assert_execfail(name, shell, rc, lines):
        check("execfail busybox FAIL with rescue wording (%s)" % " ".join(shell),
              rc == 1 and sev(lines, "busybox-binary") == ["FAIL"]
              and "manual rescue required" in lines, lines)

    run_matrix("execfail", execfail, assert_execfail,
               env_extra={"FAKE_BB_RC": "3"})

    # 6. wget -> busybox applet (no HTTPS)
    def wget_applet(fx):
        fx.install_healthy(wget_is_applet=True)

    def assert_wget_applet(name, shell, rc, lines):
        check("wget-applet WARN exit 0 (%s)" % " ".join(shell),
              rc == 0 and sev(lines, "wget-capability") == ["WARN"]
              and "#887" in lines, lines)

    run_matrix("wget-applet", wget_applet, assert_wget_applet)

    def failed_list(fx):
        fx.install_healthy()
        fx.bin("busybox", """#!/bin/sh
case "$1" in
    --help) exit 0 ;;
    --list) printf 'chmod\n'; exit 7 ;;
    -c) exit 0 ;;
esac
exit 1
""")

    def assert_failed_list(name, shell, rc, lines):
        check("failed BusyBox applet enumeration is UNKNOWN (%s)" % " ".join(shell),
              rc == 2 and sev(lines, "busybox-applets") == ["UNKNOWN"], lines)

    run_matrix("failed-list", failed_list, assert_failed_list)

    def failed_readlink(fx):
        fx.install_healthy(wget_is_applet=True)
        fx.bin("busybox", FAKE_BUSYBOX.replace("readlink)", "readlink) exit 7 ;; ignored)"))

    def assert_failed_readlink(name, shell, rc, lines):
        check("failed canonical lookup leaves wget capability UNKNOWN (%s)" % " ".join(shell),
              rc == 2 and sev(lines, "wget-capability") == ["UNKNOWN"], lines)

    run_matrix("failed-readlink", failed_readlink, assert_failed_readlink)

    # 7. no opkg -> UNKNOWN, exit 2 when nothing failed
    def noopkg(fx):
        fx.install_healthy(with_opkg=False)

    def assert_noopkg(name, shell, rc, lines):
        check("noopkg exit 2 (%s)" % " ".join(shell), rc == 2,
              "rc=%r" % rc)
        check("noopkg UNKNOWN opkg-view (%s)" % " ".join(shell),
              sev(lines, "opkg-view") == ["UNKNOWN"], lines)

    run_matrix("noopkg", noopkg, assert_noopkg)

    # The script itself must stay read-only and POSIX-safe: no ln, no
    # chmod, no opkg update/upgrade/install and no downloaders as command
    # words (emit message text legitimately mentions those words, so only
    # command heads are checked).
    import re
    src = open(SCRIPT, encoding="utf-8").read()
    code = [l for l in src.splitlines() if not l.lstrip().startswith("#")]
    banned_words = {"ln", "chmod", "wget", "curl", "opkg-update",
                    "opkg-upgrade", "opkg-install"}
    heads = set()
    for line in code:
        for part in re.split(r";|\|\||\||&&", line):
            part = part.strip()
            for kw in ("if ", "then ", "else ", "elif ", "for ", "while ",
                       "case ", "!", "do ", "}"):
                while part.startswith(kw):
                    part = part[len(kw):].lstrip()
            if part:
                heads.add(part.split()[0].strip('"'))
    for banned in ("ln", "chmod", "wget", "curl"):
        check("preflight never invokes %r" % banned, banned not in heads,
              repr(sorted(h for h in heads if banned in h)[:3]))
    for line in code:
        check("preflight never runs mutating opkg: %s" % line.strip()[:60],
              not re.search(r"opkg\s+(update|upgrade|install|flag)", line),
              line.strip()[:80])

    if failures:
        print("[FAIL] busybox preflight regression: %d failure(s)"
              % len(failures))
        return 1
    print("[OK] busybox preflight regression passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
