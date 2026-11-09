#!/usr/bin/env python3
"""Offline storage regression for kas-sys-metrics.sh (issue #476 stage A):
real tool, injected /opt + mount-table + df fixtures only.

KAS_OPT_ROOT / KAS_MOUNTS_SRC / KAS_DF_BIN point the collector's storage
section at per-test fixtures; no real /opt, no KeeneticOS, no hardware.
Asserts the Doctor-mirrored classification (internal UBIFS, external
EXT4, RAM-backed tmpfs), honest UNKNOWN/N-A handling for absent,
ambiguous, malformed and out-of-range data, the /opt-vs-/tmp distinction,
and that the storage observation never changes the exit code. Shell
dialects: dash-compatible /bin/sh and BusyBox ash when available.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "kas-sys-metrics.sh"

DF_HEADER = "Filesystem 1024-blocks Used Available Capacity Mounted on"


def make_proc(lab):
    proc = lab / "proc"
    proc.mkdir(parents=True, exist_ok=True)
    (proc / "loadavg").write_text("1.25 0.95 0.75 1/231 4211\n")
    (proc / "uptime").write_text("187343.24 184517.55\n")
    (proc / "meminfo").write_text(
        "MemTotal:        262144 kB\nMemAvailable:     118000 kB\n")
    (lab / "sys" / "class").mkdir(parents=True, exist_ok=True)
    return proc


def write_df(lab, body):
    df = lab / "df-fixture.sh"
    df.write_text("#!/bin/sh\n" + body)
    df.chmod(0o700)
    return df


def canned_df(lab, line):
    return write_df(lab, "cat <<KASDFEOF\n%s\n%s\nKASDFEOF\n" % (DF_HEADER, line))


def base_env(lab):
    env = dict(os.environ)
    env.update({
        "NO_COLOR": "1",
        "TERM": "dumb",
        "KAS_SYSFS_ROOT": str(lab / "sys"),
        "KAS_PROC_ROOT": str(lab / "proc"),
    })
    return env


def run_tool(shell, cli_args, env):
    return subprocess.run(
        [*shell, str(TOOL), *cli_args],
        text=True, capture_output=True, timeout=60, env=env, cwd=str(ROOT),
        check=False, encoding="utf-8", errors="replace",
    )


def storage_case(shell, title, mounts, df_setup, opt_name="opt",
                 opt_exists=False, opt_root=None, want_status=None, want_class=None,
                 want_fstype=None, want_mp=None, want_free=None, want_total=None,
                 want_source=None, want_exit=None, extra_expect=()):
    """Run one storage scenario; returns the parsed JSON (or None).

    mounts may be a string or a callable(lab) -> string (for fixtures that
    must reference the lab path itself). opt_root defaults to the literal
    "/opt" (production shape); pass a lab path for cases that need one.
    """
    tmp = tempfile.TemporaryDirectory(prefix="kas-stor-")
    lab = Path(tmp.name)
    try:
        make_proc(lab)
        if opt_root is None:
            opt_root = str(lab / opt_name)
            if opt_exists:
                (lab / opt_name).mkdir(parents=True, exist_ok=True)
        mounts_src = str(lab / "mounts-absent")
        if mounts is not None:
            body = mounts(lab) if callable(mounts) else mounts
            (lab / "mounts").write_text(body)
            mounts_src = str(lab / "mounts")
        df_path = df_setup(lab)
        env = base_env(lab)
        env["KAS_OPT_ROOT"] = opt_root
        env["KAS_MOUNTS_SRC"] = mounts_src
        env["KAS_DF_BIN"] = df_path
        out = lab / "out.json"
        r = run_tool(shell, ["--json", str(out)], env)
        if want_exit is not None and r.returncode != want_exit:
            raise AssertionError((title, "exit", r.returncode, want_exit, r.stdout[-800:]))
        text = r.stdout + r.stderr
        for needle in extra_expect:
            assert needle in text, (title, needle, text[-800:])
        data = json.loads(out.read_text())
        st = data["storage"]
        assert data["schema"] == "router-metrics/v1", title
        assert data["tool_version"] == "0.2.0", title
        if want_status is not None:
            assert st["status"] == want_status, (title, st, want_status)
        if want_class is not None:
            assert st["mount_class"] == want_class, (title, st, want_class)
        if want_fstype is not None:
            assert st["fstype"] == want_fstype, (title, st, want_fstype)
        if want_mp is not None:
            assert st["mount_point"] == want_mp, (title, st, want_mp)
        if want_free is not None:
            assert st["free_kb"] == want_free, (title, st, want_free)
        if want_total is not None:
            assert st["total_kb"] == want_total, (title, st, want_total)
        if want_source is not None:
            assert st["source"] == want_source, (title, st, want_source)
        if st["status"] == "PASS":
            assert st["free_kb"].isdigit() and st["total_kb"].isdigit(), (title, st)
            assert int(st["free_kb"]) <= int(st["total_kb"]) > 0, (title, st)
        else:
            assert st["free_kb"] == "" and st["total_kb"] == "", (title, st)
        blob = out.read_text().lower()
        assert "warn" not in blob and "fail" not in blob, title
        print("PASS", " ".join(shell), title)
        return st
    finally:
        tmp.cleanup()


def main():
    # syntax gate first: the tool must parse under the strict POSIX shell
    for shell in ([shutil.which("sh")] if shutil.which("sh") else []):
        r = subprocess.run([shell, "-n", str(TOOL)], capture_output=True, text=True)
        assert r.returncode == 0, ("sh -n", r.stderr)
    print("PASS sh -n syntax check")

    shells = []
    if shutil.which("sh"):
        shells.append([shutil.which("sh")])
    if shutil.which("busybox"):
        shells.append([shutil.which("busybox"), "ash"])
    if not shells:
        print("FAIL no POSIX shell found")
        return 1

    for shell in shells:
        storage_case(
            shell, "internal_ubifs_root_mount_kn3811",
            "ubi0:rootfs / ubifs rw 0 0\ntmpfs /opt/tmp tmpfs rw 0 0\n",
            lambda lab: canned_df(lab, "ubi0:rootfs 100352 51200 49152 51% /"),
            want_status="PASS", want_class="internal", want_fstype="ubifs",
            want_free="49152", want_total="100352", want_source="df+proc_mounts",
            want_exit=0, extra_expect=("storage /opt: 49152 kB free of 100352 kB",))

        storage_case(
            shell, "external_ext4_bind_opt_with_escaped_parent",
            "/dev/sda1 /tmp/mnt/Store\\040One ext4 rw 0 0\n"
            "/tmp/mnt/Store\\040One/entware /opt ext4 rw 0 0\n",
            lambda lab: canned_df(lab, "ubivol 100352 51200 49152 51% /opt"),
            opt_root="/opt",
            want_status="PASS", want_class="external", want_fstype="ext4",
            want_free="49152", want_total="100352", want_source="df+proc_mounts")

        storage_case(
            shell, "tmpfs_opt_is_ram_not_flash",
            "tmpfs /opt tmpfs rw 0 0\n",
            lambda lab: canned_df(lab, "none 1024 0 1024 0% /opt"),
            opt_root="/opt",
            want_status="PASS", want_class="ram", want_fstype="tmpfs",
            want_free="1024", want_total="1024")

        storage_case(
            shell, "no_opt_na",
            "/dev/sda1 /tmp/mnt/Disk ext4 rw 0 0\n",
            lambda lab: write_df(lab, "exit 1\n"),
            opt_name="opt-absent",
            want_status="N/A", want_class="unknown", want_fstype="unknown",
            want_source="none",
            extra_expect=("no /opt mount or directory observed",))

        storage_case(
            shell, "dir_without_cover_and_broken_df_unknown",
            "/dev/sda1 /tmp/mnt/Disk ext4 rw 0 0\n",
            lambda lab: write_df(lab, "exit 1\n"),
            opt_name="opt", opt_exists=True,
            want_status="UNKNOWN", want_source="none")

        storage_case(
            shell, "garbled_df_unknown_class_retained",
            "ubi0:rootfs / ubifs rw 0 0\n",
            lambda lab: canned_df(lab, "garbage nonsense line"),
            opt_root="/opt",
            want_status="UNKNOWN", want_class="internal", want_fstype="ubifs",
            want_source="proc_mounts")

        storage_case(
            shell, "nonnumeric_df_unknown",
            "ubi0:rootfs / ubifs rw 0 0\n",
            lambda lab: canned_df(lab, "ubivol twelve 51200 49152 51% /"),
            opt_root="/opt",
            want_status="UNKNOWN")

        storage_case(
            shell, "free_over_total_unknown",
            "ubi0:rootfs / ubifs rw 0 0\n",
            lambda lab: canned_df(lab, "ubi0:rootfs 100 51200 49152 51% /"),
            opt_root="/opt",
            want_status="UNKNOWN", want_free="", want_total="")

        storage_case(
            shell, "oversized_total_unknown",
            "ubi0:rootfs / ubifs rw 0 0\n",
            lambda lab: canned_df(lab, "ubi0:rootfs 10000000000 0 10000000000 0% /"),
            opt_root="/opt",
            want_status="UNKNOWN")

        storage_case(
            shell, "zero_total_unknown",
            "ubi0:rootfs / ubifs rw 0 0\n",
            lambda lab: canned_df(lab, "ubi0:rootfs 0 0 0 0% /"),
            opt_root="/opt",
            want_status="UNKNOWN")

        storage_case(
            shell, "zero_free_honest_pass",
            "ubi0:rootfs / ubifs rw 0 0\n",
            lambda lab: canned_df(lab, "ubi0:rootfs 100352 100352 0 100% /"),
            opt_root="/opt",
            want_status="PASS", want_free="0", want_total="100352")

        storage_case(
            shell, "missing_df_binary_unknown",
            "ubi0:rootfs / ubifs rw 0 0\n",
            lambda lab: lab / "df-binary-not-present",
            opt_root="/opt",
            want_status="UNKNOWN", want_source="proc_mounts")

        storage_case(
            shell, "df_kP_fallback_to_k",
            "ubi0:rootfs / ubifs rw 0 0\n",
            lambda lab: write_df(
                lab, '[ "$1" = "-kP" ] && exit 1\ncat <<KASDFEOF\n%s\nubi0:rootfs 100352 51200 49152 51%% /\nKASDFEOF\n' % DF_HEADER),
            opt_root="/opt",
            want_status="PASS", want_free="49152", want_total="100352")

        storage_case(
            shell, "ambiguous_deepest_unknown_class",
            "ubiA /opt ubifs rw 0 0\nubiB /opt ext4 rw 0 0\n",
            lambda lab: canned_df(lab, "ubiX 100352 51200 49152 51% /opt"),
            opt_root="/opt",
            want_status="PASS", want_class="unknown", want_fstype="unknown",
            want_free="49152", want_total="100352", want_source="df")

        storage_case(
            shell, "mounts_unreadable_df_only",
            None,
            lambda lab: canned_df(lab, "ubivol 100352 51200 49152 51% /opt"),
            opt_root="/opt",
            want_status="PASS", want_class="unknown", want_fstype="unknown",
            want_source="df")

        storage_case(
            shell, "mounts_unreadable_df_broken_unknown",
            None,
            lambda lab: write_df(lab, "exit 1\n"),
            opt_root="/opt",
            want_status="UNKNOWN", want_source="none")

        storage_case(
            shell, "escaped_mount_point_decoded",
            "ubivol /x/my\\040dir ubifs rw 0 0\n",
            lambda lab: canned_df(lab, "ubivol 100352 51200 49152 51% /x"),
            opt_root="/x/my\\040dir",
            want_status="PASS", want_class="internal", want_mp="/x/my dir",)

        # /opt must never be confused with the (much larger) /tmp tmpfs or
        # with any other filesystem: the deepest mount carrying /opt wins.
        def opt_vs_tmp_df(lab):
            return write_df(
                lab,
                'case "$2" in */optdir|*/optdir/) cat <<KASDFEOF\n%s\n'
                "/dev/sda1 20480 1024 19456 5%% /optdir\nKASDFEOF\n;;\n*) cat <<KASDFEOF\n%s\n"
                "tmpfs 8388608 100 8388508 1%% /tmp\nKASDFEOF\n;;esac\n" % (DF_HEADER, DF_HEADER))
        st = storage_case(
            shell, "opt_distinct_from_tmp_tmpfs",
            lambda lab: "tmpfs /tmp tmpfs rw 0 0\n/dev/sda1 %s ext4 rw 0 0\n" % (lab / "optdir"),
            opt_vs_tmp_df,
            opt_name="optdir",
            want_status="PASS", want_class="external", want_fstype="ext4",
            want_free="19456", want_total="20480")
        assert st["total_kb"] == "20480", st

        # storage is additive: a PASS storage reading never rescues the
        # exit code of an all-UNKNOWN core report (0/1 semantics preserved).
        tmp = tempfile.TemporaryDirectory(prefix="kas-stor-")
        lab = Path(tmp.name)
        try:
            (lab / "sys" / "class").mkdir(parents=True, exist_ok=True)
            proc = lab / "proc"
            proc.mkdir(parents=True, exist_ok=True)
            (proc / "meminfo").write_text("MemTotal: 0 kB\n")
            (lab / "mounts").write_text("ubi0:rootfs / ubifs rw 0 0\n")
            df_path = canned_df(lab, "ubi0:rootfs 100352 51200 49152 51% /")
            env = base_env(lab)
            env["KAS_MOUNTS_SRC"] = str(lab / "mounts")
            env["KAS_DF_BIN"] = str(df_path)
            out = lab / "out.json"
            r = run_tool(shell, ["--json", str(out)], env)
            assert r.returncode == 1, ("exit_code_untouched", r.returncode, r.stdout[-800:])
            data = json.loads(out.read_text())
            assert data["storage"]["status"] == "PASS", data["storage"]
            assert data["exit_code"] == 1, data
            print("PASS", " ".join(shell), "exit_code_untouched_by_storage")
        finally:
            tmp.cleanup()

    print("ALL OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
