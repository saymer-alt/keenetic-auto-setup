#!/usr/bin/env python3
"""#356: offline/disposable model of pinned Entware BusyBox maintainer scripts.

Derived from Entware/Entware@e19847436af08c926dce6b080eda391f3a220d5e
package/utils/busybox/Makefile, Git blob 3398fd4e7eec3787562498d25cb0be902e1a34cc.
The shell operations are adapted: /opt -> TemporaryDirectory/opt and
the BusyBox executable -> a restricted host-command shim. This does NOT
execute opkg, test actual package scripts/binaries, prove ABI compatibility
or provide router/field acceptance. No host /opt path is modified.
"""
from pathlib import Path
import subprocess
import tempfile

# Maintainer-script semantics, adapted from the pinned upstream templates.
# The same removal block runs in upstream prerm and postinst.
REMOVE_OWNED_LINKS = r'''bb_fc=$(/opt/bin/busybox readlink -f /opt/bin/busybox)
for file in /opt/bin/*; do
    if [ -L $file -a "$(/opt/bin/busybox readlink -f $file)" = $bb_fc ]; then
       /opt/bin/busybox rm -f $file
    fi
done
for file in /opt/sbin/*; do
    if [ -L $file -a "$(/opt/bin/busybox readlink -f $file)" = $bb_fc ]; then
       /opt/bin/busybox rm -f $file
    fi
done
'''
POSTINST = REMOVE_OWNED_LINKS + r'''cd /opt
for applet in $(/opt/bin/busybox cat share/busybox_applets.lst.dist)
do
    if [ ! -e $applet ]
    then
       /opt/bin/busybox ln -s /opt/bin/busybox $applet
    else
       echo "Warning: '/opt/$applet' is already exists, skipping."
    fi
done
'''


def check(ok, explanation):
    if not ok:
        raise AssertionError(explanation)
    print("[PASS]", explanation)


def run_script(root, source):
    # Only verified local templates are rendered, never network or user input.
    command = source.replace("/opt", str(root / "opt"))
    return subprocess.run(
        ["/bin/sh", "-c", command], cwd=root, text=True,
        capture_output=True, timeout=10,
    )


def setup(root, symlink_opt=False):
    opt = root / "opt"
    if symlink_opt:
        real = root / "storage" / "opt"
        real.mkdir(parents=True)
        opt.symlink_to(real, target_is_directory=True)
    for name in ("bin", "sbin", "share"):
        (opt / name).mkdir(parents=True, exist_ok=True)
    bb = opt / "bin" / "busybox"
    # This is a RESTRICTED SIMULATOR, not a real BusyBox or Entware ELF.
    # Refuse all mutations outside the generated fixture.
    root_prefix = str(root)
    bb.write_text('''#!/bin/sh
cmd=$1; shift
case "$cmd" in
    readlink) exec /usr/bin/readlink "$@" ;;
    cat) exec /bin/cat "$@" ;;
    rm)
        [ "$1" = -f ] || exit 80; shift
        case "$1" in "''' + root_prefix + '''"/*) exec /bin/rm -f -- "$1" ;; *) exit 81;; esac ;;
    ln)
        [ "$1" = -s ] || exit 82; shift
        target=$1; shift
        case "$target" in "''' + root_prefix + '''"/*) :;; *) exit 83;; esac
        case "$1" in "''' + root_prefix + '''"/*|bin/*|sbin/*) exec /bin/ln -s -- "$target" "$1" ;; *) exit 84;; esac ;;
    *) exit 85 ;;
esac
''', encoding="utf-8")
    bb.chmod(0o755)
    (opt / "share" / "busybox_applets.lst.dist").write_text(
        "bin/sh\nbin/chmod\nbin/grep\nbin/wget\nsbin/arping\n",
        encoding="utf-8",
    )
    return opt, bb


def scenario(symlink_opt=False, dangling=False):
    with tempfile.TemporaryDirectory(prefix="entware-busybox-offline-") as temp:
        root = Path(temp)
        opt, bb = setup(root, symlink_opt)
        for name in ("sh", "chmod"):
            (opt / "bin" / name).symlink_to(bb)
        (opt / "sbin" / "arping").symlink_to(bb)

        # Foreign executable placeholders, with stable bytes to fingerprint.
        wget = opt / "bin" / "wget"
        wget.write_bytes(b"FOREIGN-WGET-SSL-ELF-MARKER\x00\x01")
        grep = opt / "bin" / "grep"
        grep.write_bytes(b"FOREIGN-GNU-GREP-MARKER\x00\x02")
        baseline = (wget.read_bytes(), grep.read_bytes())

        if dangling:
            (opt / "bin" / "chmod").unlink()
            (opt / "bin" / "chmod").symlink_to(opt / "bin" / ".missing")

        pre = run_script(root, REMOVE_OWNED_LINKS)
        check(pre.returncode == 0, "prerm model exits successfully")
        check(not (opt / "bin" / "sh").exists(), "interruption: sh link absent")
        check(not (opt / "sbin" / "arping").exists(), "interruption: sbin applet absent")
        if dangling:
            check((opt / "bin" / "chmod").is_symlink(), "prerm preserves dangling link")
        else:
            check(not (opt / "bin" / "chmod").exists(), "interruption: chmod absent")
        check((wget.read_bytes(), grep.read_bytes()) == baseline,
              "prerm preserves separate wget-ssl and GNU grep")

        resumed = run_script(root, POSTINST)
        check((opt / "bin" / "sh").is_symlink(), "postinst restores manifest sh")
        check((opt / "sbin" / "arping").is_symlink(), "postinst restores sbin applet")
        check((wget.read_bytes(), grep.read_bytes()) == baseline,
              "postinst preserves foreign executable bytes")
        if dangling:
            check((opt / "bin" / "chmod").is_symlink()
                  and not (opt / "bin" / "chmod").exists(),
                  "dangling link remains broken despite [ ! -e ]")
            check("File exists" in resumed.stderr, "postinst reports existing link")
        else:
            check((opt / "bin" / "chmod").is_symlink()
                  and (opt / "bin" / "chmod").exists(),
                  "postinst restores missing chmod")
        check(resumed.returncode == 0,
              "postinst may finish exit 0 even if an earlier applet was not repaired")


def main():
    for symlink_opt, dangling in ((False, False), (False, True), (True, False)):
        print("[SCENARIO] opt_symlink=%s dangling=%s" % (symlink_opt, dangling))
        scenario(symlink_opt, dangling)
    print("RESULT PASS: script semantics; NOT TESTED: actual opkg, ABI and hardware")


if __name__ == "__main__":
    main()
