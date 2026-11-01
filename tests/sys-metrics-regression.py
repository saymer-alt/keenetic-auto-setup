#!/usr/bin/env python3
"""Offline regression for kas-sys-metrics.sh (issue #309): real tool,
fixture sysfs/procfs only.

KAS_SYSFS_ROOT / KAS_PROC_ROOT injection roots point the collector at
per-test fixture trees; no real sensor, no KeeneticOS, no hardware is
involved. Shell dialects: dash-compatible /bin/sh and BusyBox ash when
available. Asserts honest UNKNOWN handling, no fabricated readings,
load-average-vs-CPU wording, and a valid router-metrics/v1 JSON with no
threshold verdicts.
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


def make_proc(lab, mem=True, swap=True, load="1.25 0.95 0.75 1/231 4211",
              uptime="187343.24 184517.55"):
    proc = lab / "proc"
    proc.mkdir(parents=True, exist_ok=True)
    if mem:
        lines = [
            "MemTotal:        262144 kB",
            "MemFree:           91234 kB",
            "MemAvailable:     118000 kB",
            "Buffers:            2048 kB",
            "Cached:            31456 kB",
        ]
        if swap:
            lines += ["SwapTotal:        524288 kB", "SwapFree:         511000 kB"]
        (proc / "meminfo").write_text("\n".join(lines) + "\n")
    if load is not None:
        (proc / "loadavg").write_text(load + "\n")
    if uptime is not None:
        (proc / "uptime").write_text(uptime + "\n")
    return proc


def add_zone(sysroot, name, ztype, temp, readable=True):
    z = sysroot / "class" / "thermal" / name
    z.mkdir(parents=True, exist_ok=True)
    (z / "type").write_text(ztype + "\n")
    if readable:
        (z / "temp").write_text(str(temp) + "\n")
    return z


def add_hwmon(sysroot, name, hwname, inputs):
    hw = sysroot / "class" / "hwmon" / name
    hw.mkdir(parents=True, exist_ok=True)
    (hw / "name").write_text(hwname + "\n")
    for fname, val in inputs.items():
        (hw / fname).write_text(str(val) + "\n")
    return hw


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


def lab_with(proc_kw=None, build_sys=None):
    tmp = tempfile.TemporaryDirectory(prefix="kas-sysmet-")
    lab = Path(tmp.name)
    make_proc(lab, **(proc_kw or {}))
    if build_sys:
        build_sys(lab)
    else:
        (lab / "sys" / "class").mkdir(parents=True, exist_ok=True)
    return tmp, lab


def exercise(shell, title, want_exit, expect_in=(), expect_not_in=(),
             proc_kw=None, build_sys=None, cli_args=(), json_out=False):
    tmp, lab = lab_with(proc_kw, build_sys)
    try:
        env = base_env(lab)
        args = list(cli_args)
        if json_out:
            args += ["--json", str(lab / "out.json")]
        r = run_tool(shell, args, env)
        out = r.stdout + r.stderr
        if r.returncode != want_exit:
            raise AssertionError((title, r.returncode, want_exit, out[-1200:]))
        for needle in expect_in:
            assert needle in out, (title, needle, out[-1200:])
        for needle in expect_not_in:
            assert needle not in out, (title, needle, out[-1200:])
        data = None
        if json_out:
            data = json.loads((lab / "out.json").read_text())
            assert data["schema"] == "router-metrics/v1", title
            assert data["temperature"]["status"] in ("PASS", "UNKNOWN"), title
            assert data["load"]["status"] in ("PASS", "UNKNOWN"), title
            assert data["load"]["note"], title
        print("PASS", " ".join(shell), title)
        return data
    finally:
        tmp.cleanup()


def main():
    shells = []
    if shutil.which("sh"):
        shells.append([shutil.which("sh")])
    if shutil.which("busybox"):
        shells.append([shutil.which("busybox"), "ash"])
    if not shells:
        print("FAIL no POSIX shell found")
        return 1

    def good_sys(lab):
        s = lab / "sys"
        add_zone(s, "thermal_zone0", "soc_thermal", 45000)

    def hwmon_sys(lab):
        s = lab / "sys"
        add_hwmon(s, "hwmon0", "cpu_thermal", {"temp1_input": 52000})

    def wide_thermal_sys(lab):
        s = lab / "sys"
        # a board/enclosure zone whose type contains "thermal" but NOT cpu/soc:
        # this must NOT be reported as the CPU/SoC temperature
        add_zone(s, "thermal_zone0", "board_thermal", 55000)

    def ambiguous_sys(lab):
        s = lab / "sys"
        add_zone(s, "thermal_zone0", "acpitz", 61000)
        add_zone(s, "thermal_zone1", "battery", 31000)

    def multi_sys(lab):
        s = lab / "sys"
        add_zone(s, "thermal_zone0", "acpitz", 61000)
        add_zone(s, "thermal_zone1", "cpu_thermal", 47500)
        add_zone(s, "thermal_zone2", "gpu", 39000)

    def bad_val_sys(lab):
        s = lab / "sys"
        add_zone(s, "thermal_zone0", "cpu_thermal", 999999)

    def neg_val_sys(lab):
        s = lab / "sys"
        add_zone(s, "thermal_zone0", "cpu_thermal", -45000)

    def text_val_sys(lab):
        s = lab / "sys"
        add_zone(s, "thermal_zone0", "cpu_thermal", "abc", readable=True)

    def unreadable_sys(lab):
        s = lab / "sys"
        add_zone(s, "thermal_zone0", "cpu_thermal", None, readable=False)

    def nothing_sys(lab):
        (lab / "sys" / "class").mkdir(parents=True, exist_ok=True)

    cases = [
        ("cpu_zone_pass", 0,
         {"expect_in": ("temperature.cpu-soc: 45.0 C", "soc_thermal",
                        "load.avg: 1m=1.25 5m=0.95 15m=0.75",
                        "uptime:", "memory: total 262144 kB",
                        "swap: total 524288 kB", "metrics observed: 4 of 4"),
          "expect_not_in": ("FAIL", "overheating detected"),
          "build_sys": good_sys, "json_out": True}),
        ("hwmon_source_pass", 0,
         {"expect_in": ("temperature.cpu-soc: 52.0 C", "hwmon0", "sysfs:hwmon"),
          "build_sys": hwmon_sys}),
        ("wide_thermal_not_cpu", 0,
         {"expect_in": ("no identifiable CPU/SoC temperature sensor", "UNKNOWN",
                        "type=board_thermal"),
          "expect_not_in": ("55.0 C", "temperature.cpu-soc: 55"),
          "build_sys": wide_thermal_sys}),
        ("ambiguous_zones_no_cpu_unknown", 0,
         {"expect_in": ("no identifiable CPU/SoC temperature sensor", "UNKNOWN",
                        "type=acpitz", "type=battery"),
          "expect_not_in": ("61.0 C",),
          "build_sys": ambiguous_sys}),
        ("multi_zones_first_cpu", 0,
         {"expect_in": ("47500", "cpu_thermal", "zone thermal_zone0"),
          "expect_not_in": ("61.0 C",),
          "build_sys": multi_sys}),
        ("implausible_value_unknown", 0,
         {"expect_in": ("outside the plausible range", "UNKNOWN",
                        "not clamped"),
          "expect_not_in": ("999.9", "1000.0"),
          "build_sys": bad_val_sys}),
        ("negative_value_unknown", 0,
         {"expect_in": ("UNKNOWN",), "expect_not_in": ("-45.0",),
          "build_sys": neg_val_sys}),
        ("text_value_unknown", 0,
         {"expect_in": ("no identifiable CPU/SoC temperature sensor", "UNKNOWN"),
          "build_sys": text_val_sys}),
        ("unreadable_file_unknown", 0,
         {"expect_in": ("no identifiable CPU/SoC temperature sensor",),
          "build_sys": unreadable_sys}),
        ("no_sensor_but_proc_ok", 0,
         {"expect_in": ("no identifiable CPU/SoC temperature sensor",
                        "load.avg: 1m=1.25", "uptime:", "metrics observed: 3 of 4"),
          "build_sys": nothing_sys}),
        ("all_unknown_exit1", 1,
         {"expect_in": ("no core metric could be observed", "UNKNOWN"),
          "build_sys": nothing_sys,
          "proc_kw": {"mem": False, "load": None, "uptime": None}}),
        ("loadavg_missing", 0,
         {"expect_in": ("load.avg: /proc/loadavg unreadable", "UNKNOWN",
                        "uptime:"),
          "proc_kw": {"load": None}}),
        ("loadavg_garbage", 0,
         {"expect_in": ("load.avg: /proc/loadavg unreadable",),
          "proc_kw": {"load": "not a load line at all"}}),
        ("uptime_missing", 0,
         {"expect_in": ("uptime: /proc/uptime unreadable", "load.avg:"),
          "proc_kw": {"uptime": None}}),
        ("no_swap_is_na", 0,
         {"expect_in": ("swap: no swap totals readable", "N/A"),
          "expect_not_in": ("FAIL",),
          "proc_kw": {"swap": False}}),
        ("json_contract", 0,
         {"expect_in": ("router-metrics/v1",), "build_sys": good_sys,
          "json_out": True}),
        ("usage_error", 2, {"expect_in": ("Unknown option",),
                            "cli_args": ("--wat",)}),
    ]

    for shell in shells:
        for title, want_exit, opts in cases:
            exercise(shell, title, want_exit, **opts)

        # JSON field-level assertions on the good fixture
        tmp, lab = lab_with({}, good_sys)
        try:
            env = base_env(lab)
            jf = lab / "m.json"
            r = run_tool(shells[0], ["--json", str(jf)], env)
            assert r.returncode == 0, ("json_fields", r.stdout)
            d = json.loads(jf.read_text())
            assert d["tool"] == "kas-sys-metrics.sh"
            assert d["temperature"]["celsius"] == "45.0"
            assert d["temperature"]["source"] == "sysfs:thermal"
            assert d["load"]["one_min"] == "1.25"
            assert d["uptime"]["seconds"] == "187343.24"
            assert d["memory"]["mem_total_kb"] == "262144"
            assert d["memory"]["mem_available_kb"] == "118000"
            assert d["swap"]["total_kb"] == "524288"
            assert d["exit_code"] == 0
            blob = jf.read_text().lower()
            assert "warn" not in blob and "fail" not in blob
            print("PASS", " ".join(shells[0]), "json_fields")
        finally:
            tmp.cleanup()

    print("ALL OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
