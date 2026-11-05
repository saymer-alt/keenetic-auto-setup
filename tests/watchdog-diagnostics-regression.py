#!/usr/bin/env python3
"""Watchdog 2.0 incident diagnostics regression (issue #328).

Extracts the production incident-diagnostics block and runs the real
mihomo-watchdog.sh pipeline with scripted curl sequences under sh, dash and
BusyBox ash. Proves, without any router, network or Mihomo installation:

- L1: every confirmed failure cycle logs a compact [FAIL] evidence line
      from already collected probe data, before the restart decision acts;
- L2: event diagnostics run only after DIAG_FAIL_THRESHOLD confirmed
      cycles inside the window, honor their own cooldown, request budget
      and dedup, and never influence the restart decision;
- per-class accounting: wan/proxy_tunnel/port counters are independent;
      WAN_UNREACHABLE never touches tunnel history;
- recovery: a successful check resets consecutive failures but keeps the
      repeat window until it expires; a reboot (missing state) starts fresh;
- post-restart: one bounded tunnel recheck records recovered / still
      failing / unknown separately from [RESTART-VERIFIED];
- the restart policy itself is unchanged (existing restart decisions fire
      exactly as before) and logs stay free of URLs, stderr and secrets.

Invoke: python3 tests/watchdog-diagnostics-regression.py [--shell ...]
"""

import argparse
import os
import shlex
import subprocess

from mihomo_init_fixture import pin_fixture_init
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WATCHDOG = os.path.join(REPO, "mihomo-watchdog.sh")
INCIDENT_BEGIN = "# BEGIN WATCHDOG INCIDENT DIAGNOSTICS v1"
INCIDENT_END = "# END WATCHDOG INCIDENT DIAGNOSTICS v1"
PROCESS_END = "# END MIHOMO PROCESS STATE v1"

CLASSES = ["wan_failure", "proxy_tunnel_failure", "port_failure"]


def source(name):
    with open(name, "r", encoding="utf-8", newline="") as f:
        return f.read().replace("\r\n", "\n")


def incident_block():
    text = source(WATCHDOG)
    begin = text.index(INCIDENT_BEGIN)
    end = text.index(INCIDENT_END)
    return text[begin:end]


class Fixture:
    def __init__(self):
        self._tmp = tempfile.TemporaryDirectory()
        lab = self._tmp.name
        # Shell fixtures must receive a forward-slash path: backslashes would
        # be eaten as escape characters inside the generated sh scripts.
        self.lab = lab.replace("\\", "/")
        os.makedirs(self.lab + "/opt/etc/init.d")
        os.makedirs(self.lab + "/opt/var/log")
        os.makedirs(self.lab + "/tmp")
        init = self.lab + "/opt/etc/init.d/S99mihomo"
        with open(init, "w", encoding="utf-8", newline="\n") as f:
            f.write("#!/bin/sh\necho \"$1\" >> \"%s/actions\"\n" % self.lab)
        os.chmod(init, 0o755)
        open(self.lab + "/opt/etc/init.d/rc.func", "w").close()
        for name in ("actions", "curllog"):
            open(self.lab + "/" + name, "w").close()
        with open(self.lab + "/curln", "w") as f:
            f.write("0\n")

    def redirect(self, text):
        # Redirect every absolute production path into the disposable lab.
        # Plain concatenation keeps forward slashes on every host OS.
        text = pin_fixture_init(text, self.lab + "/opt/etc/init.d/S99mihomo")
        text = text.replace("/tmp/", self.lab + "/tmp/")
        text = text.replace("/opt/var/log", self.lab + "/opt/var/log")
        text = text.replace("/opt/etc/init.d", self.lab + "/opt/etc/init.d")
        text = text.replace("/proc/uptime", self.lab + "/uptime")
        return text

    def write_uptime(self, value="12345.67 0"):
        with open(os.path.join(self.lab, "uptime"), "w", encoding="utf-8", newline="\n") as f:
            f.write(value + "\n")

    def write_seq(self, seq):
        # Each new sequence starts a fresh probe count: the stub curl reads
        # its next exit code from this file and multi-run cases would
        # otherwise continue past the end of the previous sequence.
        with open(self.lab + "/seq", "w", encoding="utf-8", newline="\n") as f:
            for rc in seq:
                f.write(str(rc) + "\n")
        with open(self.lab + "/curln", "w") as f:
            f.write("0\n")
        open(self.lab + "/curllog", "w").close()

    def write_state(self, lines):
        path = os.path.join(self.lab, "tmp", "mihomo_watchdog.incidents")
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            for line in lines:
                f.write(line + "\n")

    def clean_run_state(self):
        for name in ("mihomo-lifecycle.lock.d", "mihomo_watchdog.lock.d",
                     "mihomo_watchdog.incidents", "mihomo_watchdog.restart",
                     "mihomo_watchdog.healthy"):
            path = os.path.join(self.lab, "tmp", name)
            if os.path.isdir(path):
                import shutil
                shutil.rmtree(path)
            elif os.path.exists(path):
                os.remove(path)
        for name in ("actions", "curllog"):
            open(os.path.join(self.lab, name), "w").close()
        with open(os.path.join(self.lab, "curln"), "w") as f:
            f.write("0\n")
        log = os.path.join(self.lab, "opt", "var", "log", "mihomo_watchdog.log")
        if os.path.exists(log):
            os.remove(log)

    def read(self, name):
        path = os.path.join(self.lab, name)
        if not os.path.exists(path):
            return ""
        with open(path, "r", encoding="utf-8") as f:
            return f.read()

    def log(self):
        return self.read(os.path.join("opt", "var", "log", "mihomo_watchdog.log"))

    def state_lines(self):
        text = self.read(os.path.join("tmp", "mihomo_watchdog.incidents"))
        return [line for line in text.splitlines() if line.strip()]

    def state_field(self, klass, index):
        for line in self.state_lines():
            parts = line.split()
            if parts and parts[0] == klass:
                return parts[index] if len(parts) > index else None
        return None

    def curl_calls(self):
        text = self.read("curllog").strip()
        return len(text.splitlines()) if text else 0

    def actions(self):
        text = self.read("actions").strip()
        return text.splitlines() if text else []

    def close(self):
        self._tmp.cleanup()


def full_script(fx, extra_stubs=""):
    """Production watchdog with redirected paths and process/curl stubs."""
    text = source(WATCHDOG)
    marker = PROCESS_END
    idx = text.index(marker) + len(marker)
    stubs = (
        "\nmp_state() { return 0; }\n"
        "mp_known() { return 0; }\n"
        "mp_running() { return 0; }\n"
        "curl() {\n"
        "    _n=$(cat \"$CURLN\" 2>/dev/null || echo 0)\n"
        "    _n=$((_n + 1))\n"
        "    echo \"$_n\" > \"$CURLN\"\n"
        "    _rc=$(sed -n \"${_n}p\" \"$CURLSEQ\" 2>/dev/null)\n"
        "    echo \"$_n=$_rc\" >> \"$CURLLOG\"\n"
        "    return \"${_rc:-1}\"\n"
        "}\n"
        "sleep() { :; }\n"
        + extra_stubs
    )
    text = text.replace("can_restart() {", "wd_restart_identity() { echo stopped; }\ncan_restart() {", 1)
    return fx.redirect(text[:idx] + stubs + text[idx:])


def unit_script(fx, body):
    """Extracted incident block with minimal stubs and a test body."""
    env = (
        "LAB=\"%s\"\n"
        "INCIDENT_STATE=\"%s\"\n"
        "DIAG_WINDOW_SECS=1800\n"
        "DIAG_FAIL_THRESHOLD=2\n"
        "DIAG_MIN_INTERVAL=900\n"
        "DIAG_MAX_REQUESTS=4\n"
        "DIAG_SOCKS_TARGET_ALT=\"https://www.cloudflare.com\"\n"
        "MIHOMO_CONTROLLER_URL=\"\"\n"
        "PROXY=\"127.0.0.1:7890\"\n"
        "WAN_PRIMARY_TARGETS=\"http://cp.cloudflare.com\"\n"
        "log() { echo \"$(date '+%%Y-%%m-%%d %%H:%%M:%%S') $1\" >> \"$LAB/unit.log\"; }\n"
        "ml_marker_busy() { return 1; }\n"
        "mp_state() { return \"${MP_STATE_RC:-0}\"; }\n"
    ) % (fx.lab, os.path.join(fx.lab, "tmp", "mihomo_watchdog.incidents"))
    return "#!/bin/sh\n" + env + incident_block() + "\n" + body + "\n"


def run(fx, script, args, shell, expect_rc=0, env_extra=None):
    env = dict(os.environ)
    env["CURLSEQ"] = os.path.join(fx.lab, "seq")
    env["CURLN"] = os.path.join(fx.lab, "curln")
    env["CURLLOG"] = os.path.join(fx.lab, "curllog")
    env["LAB"] = fx.lab
    if env_extra:
        env.update(env_extra)
    script_path = os.path.join(fx.lab, "case.sh")
    with open(script_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(script)
    proc = subprocess.run(
        shell + [script_path],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=60,
    )
    out = proc.stdout.decode("utf-8", "replace")
    err = proc.stderr.decode("utf-8", "replace")
    assert proc.returncode == expect_rc, (
        "rc=%s expected %s\nstdout:%s\nstderr:%s" % (proc.returncode, expect_rc, out, err))
    return out, err


def now():
    import time
    return int(time.time())


def assert_state(fx, klass, **fields):
    index_map = {
        "confirmed": 1, "consecutive": 2, "window_count": 3, "window_start": 4,
        "first": 5, "last": 6, "transient": 7, "diag_last": 8, "diag_occ": 9,
    }
    for name, value in fields.items():
        got = fx.state_field(klass, index_map[name])
        assert got == str(value), (
            "%s.%s expected %s got %s (state: %r)" % (klass, name, value, got, fx.state_lines()))


def assert_no_secrets_in_diag(fx):
    for line in fx.log().splitlines():
        # strip the timestamp prefix
        if len(line) > 20 and "[DIAG" in line:
            body = line[20:]
            assert "://" not in body, "URL leaked into diagnostics: %r" % line
            assert "socks5h" not in body, "proxy scheme leaked: %r" % line
            assert "stderr" not in body, "raw stderr marker leaked: %r" % line


def test_l1_first_tunnel_cycle(fx, shell):
    fx.clean_run_state()
    fx.write_uptime()
    fx.write_seq([0, 0, 1, 1, 1])
    run(fx, full_script(fx), [], shell)
    assert "can_restart" not in fx.log()
    assert "[FAIL] proxy_tunnel confirmed | cycles=1" in fx.log()
    assert "curl_rc=1" in fx.log()
    assert "[DIAG-TRIGGER]" not in fx.log(), "L2 must not run below threshold"
    assert "[DIAG-SUMMARY]" not in fx.log()
    assert fx.actions() == ["restart"], "restart policy changed?"
    assert_state(fx, "proxy_tunnel_failure", confirmed=1, consecutive=1, window_count=1)
    # post-restart recheck ran (fifth probe) and recorded still failing
    assert "post-restart tunnel recheck: still failing" in fx.log()
    assert fx.curl_calls() == 5
    assert_no_secrets_in_diag(fx)


def test_l2_triggers_on_second_cycle(fx, shell):
    fx.clean_run_state()
    fx.write_uptime()
    fx.write_seq([0, 0, 1, 1, 1])
    ts = now()
    fx.write_state([
        "wan_failure 0 0 0 0 0 0 0 0 0 -",
        "proxy_tunnel_failure 1 1 1 %d %d %d 0 0 0 -" % (ts - 600, ts - 600, ts - 600),
        "port_failure 0 0 0 0 0 0 0 0 0 -",
    ])
    run(fx, full_script(fx), [], shell)
    assert "[DIAG-TRIGGER] proxy_tunnel" in fx.log()
    assert "[DIAG-SUMMARY] tunnel=FAIL" in fx.log()
    assert "cause=upstream_or_route_unknown" in fx.log()
    assert "Full Network Doctor" in fx.log()
    assert fx.actions() == ["restart"], "diag must not change the restart decision"
    assert_state(fx, "proxy_tunnel_failure", window_count=2, diag_occ=1)
    assert fx.state_field("proxy_tunnel_failure", 10) != "-", "summary hash recorded"
    assert_no_secrets_in_diag(fx)


def test_l2_cooldown_skips(fx, shell):
    fx.clean_run_state()
    fx.write_uptime()
    fx.write_seq([0, 0, 1, 1, 1])
    ts = now()
    fx.write_state([
        "wan_failure 0 0 0 0 0 0 0 0 0 -",
        "proxy_tunnel_failure 1 1 1 %d %d %d 0 %d 1 12345" % (ts - 600, ts - 600, ts - 600, ts - 60),
        "port_failure 0 0 0 0 0 0 0 0 0 -",
    ])
    run(fx, full_script(fx), [], shell)
    assert "[DIAG-SKIP] proxy_tunnel_failure | diagnostic cooldown" in fx.log()
    assert "[DIAG-TRIGGER]" not in fx.log()
    assert "[DIAG-SUMMARY]" not in fx.log()
    assert_state(fx, "proxy_tunnel_failure", diag_last=ts - 60, diag_occ=1)
    assert fx.actions() == ["restart"]


def test_l2_silent_below_threshold(fx, shell):
    fx.clean_run_state()
    fx.write_uptime()
    fx.write_seq([0, 0, 1, 1, 1])
    ts = now()
    fx.write_state([
        "wan_failure 0 0 0 0 0 0 0 0 0 -",
        "proxy_tunnel_failure 1 1 1 %d %d %d 0 0 0 -" % (ts - 1700, ts - 1700, ts - 1700),
        "port_failure 0 0 0 0 0 0 0 0 0 -",
    ])
    run(fx, full_script(fx), [], shell)
    # window_count becomes 2 here, so diag fires; use a fresh window instead
    fx2 = Fixture()
    try:
        fx2.write_uptime()
        fx2.write_seq([0, 0, 1, 1, 1])
        fx2.write_state([
            "wan_failure 0 0 0 0 0 0 0 0 0 -",
            "proxy_tunnel_failure 0 0 0 0 0 0 0 0 0 -",
            "port_failure 0 0 0 0 0 0 0 0 0 -",
        ])
        run(fx2, full_script(fx2), [], shell)
        assert "[DIAG-TRIGGER]" not in fx2.log(), "first cycle must stay at L1"
    finally:
        fx2.close()


def test_transient_and_recovery(fx, shell):
    fx.clean_run_state()
    fx.write_uptime()
    fx.write_seq([0, 0, 1, 0, 0])
    run(fx, full_script(fx), [], shell)
    assert "[INFO] Proxy tunnel first probe failed; retry succeeded - no restart" in fx.log()
    assert "transient_cycles=1" in fx.log()
    assert fx.actions() == [], "transient must not restart"
    assert_state(fx, "proxy_tunnel_failure", confirmed=0, consecutive=0, transient=1)

    # healthy run resets consecutive but keeps the repeat window
    fx.write_seq([0, 0, 0, 0, 0])
    ts = now()
    fx.write_state([
        "wan_failure 0 0 0 0 0 0 0 0 0 -",
        "proxy_tunnel_failure 3 3 2 %d %d %d 1 0 0 -" % (ts - 600, ts - 700, ts - 600),
        "port_failure 0 0 0 0 0 0 0 0 0 -",
    ])
    run(fx, full_script(fx), [], shell)
    assert_state(fx, "proxy_tunnel_failure", consecutive=0, window_count=2, confirmed=3)
    assert "[OK] All good" in fx.log()


def test_wan_failure_class_isolation(fx, shell):
    fx.clean_run_state()
    fx.write_uptime()
    fx.write_seq([1, 1, 1, 1, 1, 1, 1])
    ts = now()
    fx.write_state([
        "wan_failure 0 0 0 0 0 0 0 0 0 -",
        "proxy_tunnel_failure 5 5 5 %d %d %d 0 0 0 -" % (ts - 600, ts - 600, ts - 600),
        "port_failure 0 0 0 0 0 0 0 0 0 -",
    ])
    run(fx, full_script(fx), [], shell, expect_rc=0)
    assert "[WARN] WAN unreachable (primary + whitelist targets failed)" in fx.log()
    assert "[FAIL] wan confirmed | cycles=1" in fx.log()
    assert fx.actions() == [], "WAN outage never restarts Mihomo"
    assert_state(fx, "wan_failure", window_count=1)
    assert_state(fx, "proxy_tunnel_failure", window_count=5, confirmed=5,
                 consecutive=5), "WAN failure must not touch tunnel history"
    assert_no_secrets_in_diag(fx)


def test_port_failure_with_post_recheck(fx, shell):
    fx.clean_run_state()
    fx.write_uptime()
    fx.write_seq([0, 1, 0])
    run(fx, full_script(fx), [], shell)
    assert "[FAIL] port confirmed | cycles=1" in fx.log()
    assert fx.actions() == ["restart"]
    assert "post-restart tunnel recheck: SOCKS recovered" in fx.log()
    assert fx.curl_calls() == 3, "recheck adds exactly one bounded probe"
    assert_state(fx, "port_failure", window_count=1)
    assert_no_secrets_in_diag(fx)


def test_window_expiry_resets_count(fx, shell):
    fx.clean_run_state()
    fx.write_uptime()
    fx.write_seq([0, 0, 1, 1, 1])
    ts = now()
    fx.write_state([
        "wan_failure 0 0 0 0 0 0 0 0 0 -",
        "proxy_tunnel_failure 7 7 4 %d %d %d 0 0 0 -" % (ts - 2000, ts - 2400, ts - 2000),
        "port_failure 0 0 0 0 0 0 0 0 0 -",
    ])
    run(fx, full_script(fx), [], shell)
    assert_state(fx, "proxy_tunnel_failure", window_count=1)
    assert "[DIAG-TRIGGER]" not in fx.log(), "expired window starts a new count at L1"
    assert fx.actions() == ["restart"]


def test_wan_diag_direct_only(fx, shell):
    fx.clean_run_state()
    fx.write_uptime()
    fx.write_seq([1, 1, 1, 1, 1, 1, 1, 6])
    ts = now()
    fx.write_state([
        "wan_failure 1 1 2 %d %d %d 0 0 0 -" % (ts - 600, ts - 700, ts - 600),
        "proxy_tunnel_failure 0 0 0 0 0 0 0 0 0 -",
        "port_failure 0 0 0 0 0 0 0 0 0 -",
    ])
    run(fx, full_script(fx), [], shell)
    assert "[DIAG-TRIGGER] wan_failure" in fx.log()
    assert "cause=dns_resolution_suspected" in fx.log()
    assert "socks_probes=skipped_by_design" in fx.log()
    assert fx.actions() == []
    # 7 WAN probes + 1 diag probe = 8; no SOCKS probe spent
    assert fx.curl_calls() == 8
    assert_no_secrets_in_diag(fx)


def test_port_diag_local_only(fx, shell):
    fx.clean_run_state()
    fx.write_uptime()
    fx.write_seq([0, 1, 1])
    ts = now()
    fx.write_state([
        "wan_failure 0 0 0 0 0 0 0 0 0 -",
        "proxy_tunnel_failure 0 0 0 0 0 0 0 0 0 -",
        "port_failure 1 1 1 %d %d %d 0 0 0 -" % (ts - 600, ts - 600, ts - 600),
    ])
    run(fx, full_script(fx), [], shell)
    assert "[DIAG-TRIGGER] port_failure" in fx.log()
    assert "scope=local_only" in fx.log()
    assert fx.actions() == ["restart"]
    # 1 WAN + 1 port + 1 post-recheck; no external diag probes
    assert fx.curl_calls() == 3
    assert "cause=listener_not_accepting" in fx.log()


def test_unit_semantics(fx, shell):
    body = r"""
# fresh confirm -> window starts at 1
incident_confirm proxy_tunnel_failure 28 5000
[ "$(eval "echo \$INC_proxy_tunnel_failure_window_count")" = "1" ] || exit 20
[ "$(eval "echo \$INC_proxy_tunnel_failure_consecutive")" = "1" ] || exit 21
# second confirm inside window
incident_confirm proxy_tunnel_failure 28 5100
[ "$(eval "echo \$INC_proxy_tunnel_failure_window_count")" = "2" ] || exit 22
# transient only bumps transient
incident_transient proxy_tunnel_failure
[ "$(eval "echo \$INC_proxy_tunnel_failure_transient")" = "1" ] || exit 23
[ "$(eval "echo \$INC_proxy_tunnel_failure_confirmed")" = "2" ] || exit 24
# recover resets consecutive, keeps window
incident_recover proxy_tunnel_failure
[ "$(eval "echo \$INC_proxy_tunnel_failure_consecutive")" = "0" ] || exit 25
[ "$(eval "echo \$INC_proxy_tunnel_failure_window_count")" = "2" ] || exit 26
# unknown class is ignored
incident_confirm bogus_class 1 1 || true
incident_load
[ "$(eval "echo \${INC_bogus_class_confirmed:-0}")" = "0" ] || exit 27
# reload round-trips the saved file
incident_load
[ "$(eval "echo \$INC_proxy_tunnel_failure_window_count")" = "2" ] || exit 28
# malformed lines are skipped, other classes survive
printf 'garbage line\nproxy_tunnel_failure 9 9 9 1 1 1 9 9 9 abc\n' > "$INCIDENT_STATE"
incident_load
[ "$(eval "echo \$INC_proxy_tunnel_failure_hash")" = "abc" ] || exit 29
exit 0
"""
    fx.clean_run_state()
    run(fx, unit_script(fx, body), [], shell)
    log = fx.read("unit.log")
    assert "[FAIL]" not in log


def test_now_ms_padded_fraction(fx, shell):
    # POSIX sh/dash/ash arithmetic reads a leading 0 as octal: an uptime
    # fraction like .09 pads to "090" and used to abort the whole watchdog
    # run with "Illegal number: 090" (~9% of real runs, purely by clock).
    fx.write_uptime("12345.09 0")
    body = r"""
now_ms || exit 30
[ "$now_ms_result" = "12345090" ] || exit 31
exit 0
"""
    fx.clean_run_state()
    run(fx, fx.redirect(unit_script(fx, body)), [], shell)
    for value, expect in (("12345.9 0", "12345900"), ("12345.00 0", "12345000"),
                          ("7 0", "7000"), ("0.09 0", "90")):
        fx.write_uptime(value)
        body = "now_ms || exit 30\n[ \"$now_ms_result\" = \"%s\" ] || exit 31\nexit 0\n" % expect
        fx.clean_run_state()
        run(fx, fx.redirect(unit_script(fx, body)), [], shell)


def test_state_file_shape(fx, shell):
    fx.clean_run_state()
    fx.write_uptime()
    fx.write_seq([0, 0, 1, 1, 1])
    run(fx, full_script(fx), [], shell)
    lines = fx.state_lines()
    assert len(lines) == 3, "one line per class"
    for line in lines:
        parts = line.split()
        assert len(parts) == 11, "fixed 11-field record: %r" % line
        assert parts[0] in CLASSES
        for field in parts[1:10]:
            assert field.isdigit(), "numeric field expected: %r" % line
    assert_no_secrets_in_diag(fx)


def test_full_smoke_wan_outage(fx, shell):
    fx.clean_run_state()
    fx.write_uptime()
    fx.write_seq([1] * 12)
    run(fx, full_script(fx), [], shell, expect_rc=0)
    assert fx.actions() == [], "total WAN outage must not restart"
    assert "[WARN] WAN unreachable" in fx.log()
    assert "[RESTART]" not in fx.log()


CASES = [
    test_l1_first_tunnel_cycle,
    test_l2_triggers_on_second_cycle,
    test_l2_cooldown_skips,
    test_l2_silent_below_threshold,
    test_transient_and_recovery,
    test_wan_failure_class_isolation,
    test_port_failure_with_post_recheck,
    test_window_expiry_resets_count,
    test_wan_diag_direct_only,
    test_port_diag_local_only,
    test_unit_semantics,
    test_now_ms_padded_fraction,
    test_state_file_shape,
    test_full_smoke_wan_outage,
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--shell", action="append", help="sh, dash or 'busybox ash'; repeatable")
    args = parser.parse_args()
    for value in args.shell or ["sh", "dash", "busybox ash"]:
        shell = shlex.split(value)
        try:
            subprocess.run(shell + ["-c", ":"], check=True)
        except (OSError, subprocess.CalledProcessError):
            print("[SKIP] %s not available on this host" % value)
            continue
        print("=== %s ===" % value, flush=True)
        for case in CASES:
            fx = Fixture()
            try:
                case(fx, shell)
            finally:
                fx.close()
            print("[OK] %s" % case.__name__, flush=True)
    print("[OK] Watchdog incident diagnostics regressions passed")


if __name__ == "__main__":
    main()
