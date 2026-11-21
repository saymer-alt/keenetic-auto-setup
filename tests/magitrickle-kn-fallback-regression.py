#!/usr/bin/env python3
"""No-network behavioral regressions for KAS MagiTrickle _kn fallback.

Covers the fallback chain (official feed outage -> pinned GitHub 0.8.2-2 ->
pinned GitLab 0.8.2-1 -> honest failure) and the MagiTrickle-feed-scoped
tolerance of the global opkg update. Every scenario runs an extracted
install.sh fragment under /bin/sh with mocks; nothing is installed and no
network is used.
"""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

INSTALL = Path(__file__).resolve().parents[1] / "install.sh"
BEGIN = "# BEGIN MAGITRICKLE KN FALLBACK v1 (issue #505)"
END = "# END MAGITRICKLE KN FALLBACK v1"
BEGIN_PROBE = "# BEGIN MAGITRICKLE FEED PROBE v1"
END_PROBE = "# END MAGITRICKLE FEED PROBE v1"
SCRIPT = INSTALL.read_text(encoding="utf-8")
assert SCRIPT.count(BEGIN) == SCRIPT.count(END) == 1
assert SCRIPT.count(BEGIN_PROBE) == SCRIPT.count(END_PROBE) == 1
FUNCTIONS = SCRIPT.split(BEGIN, 1)[1].split(END, 1)[0]
PROBE = SCRIPT.split(BEGIN_PROBE, 1)[1].split(END_PROBE, 1)[0]


def run_fragment(code, extra_env=None):
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)
    with tempfile.TemporaryDirectory() as d:
        env["TEST_TMP"] = d
        full = code
        run = subprocess.run(["sh", "-s"], input=full, text=True,
                             env=env, capture_output=True, timeout=20)
        trace = Path(d) / "trace"
        out = run.stdout + ("\nSTDERR: " + run.stderr if run.returncode else "")
        return run.returncode, out, (trace.read_text() if trace.exists() else "")


class FallbackRegression(unittest.TestCase):
    def runner(self, arch="mipsel-3.4_kn", github="fail", gitlab="ok",
               sha="correct", installed=False, github_rc=None, size="correct"):
        with tempfile.TemporaryDirectory() as d:
            code = r"""
set -eu
TMP_DIR="$TEST_TMP"
FAKE_INSTALLED="${TEST_INSTALLED:-0}"
FAKE_SOURCE=""
TRACE="$TEST_TMP/trace"
log() { :; }
warn() { :; }
pkg_is_installed() { [ "$FAKE_INSTALLED" = 1 ]; }
opkg() {
    case "$1" in
        print-architecture)
            printf 'arch all 1\narch mipsel-3.4 10\narch %s 20\n' "$TEST_ARCH" ;;
        status)
            printf 'Package: magitrickle\nStatus: install ok installed\nArchitecture: %s\n' "$TEST_ARCH" ;;
        install)
            printf '%s\n' "install:$2" >> "$TRACE"
            FAKE_INSTALLED=1 ;;
        *) return 1 ;;
    esac
}
curl() {
    _url=""; _output=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            https://*) _url="$1" ;;
            -o) shift; _output="$1" ;;
        esac
        shift
    done
    case "$_url" in
        *github.com*)
            printf 'github\n' >> "$TRACE"
            if [ -n "${TEST_GITHUB_RC:-}" ]; then return "$TEST_GITHUB_RC"; fi
            [ "$TEST_GITHUB" = ok ] || return 1
            FAKE_SOURCE=github ;;
        *gitlab.com*)
            printf 'gitlab\n' >> "$TRACE"
            [ "$TEST_GITLAB" = ok ] || return 1
            FAKE_SOURCE=gitlab ;;
        *) return 1 ;;
    esac
    printf 'dummy' > "$_output"
}
wget() { return 127; }
wc() {
    case "$TEST_SIZE_MODE" in
        wrong) echo 0 ;;
        *) case "$FAKE_SOURCE:$TEST_ARCH" in
               github:aarch64-3.10_kn) echo 2548308 ;;
               github:mips-3.4_kn) echo 2379639 ;;
               github:mipsel-3.4_kn) echo 2418194 ;;
               gitlab:aarch64-3.10_kn) echo 2547127 ;;
               gitlab:mips-3.4_kn) echo 2380080 ;;
               gitlab:mipsel-3.4_kn) echo 2418259 ;;
               *) echo 0 ;;
           esac ;;
    esac
}
sha256sum() {
    if [ "$TEST_SHA" = wrong ]; then echo '0000000000000000000000000000000000000000000000000000000000000000  file'
    else
        case "$FAKE_SOURCE:$TEST_ARCH" in
            github:aarch64-3.10_kn) echo 'd3423385f542b012fb583f1135ce9c10ff90b4570a03af4bc2e272fa18d783ef  file' ;;
            github:mips-3.4_kn) echo '4fe3a712196e7498e336589c65240c0f109f63b3be4bc50473344c043a68b10b  file' ;;
            github:mipsel-3.4_kn) echo 'ad2732a4ab3d25abbf38a65ab8306d22138a959173234f6b2deb5326923fcd93  file' ;;
            gitlab:aarch64-3.10_kn) echo '9ae3df3c33f8c836aa1adc34f79c5de4fd620dee5da96cef26015b0cec186c9b  file' ;;
            gitlab:mips-3.4_kn) echo '21eb0d8e2a97fbe571998cdcc963c771c314d1bb4ea3e044e4951711162de9ea  file' ;;
            gitlab:mipsel-3.4_kn) echo '5a10083cc063731536d8c7820c008348e99a16cf821534f51f1a415f50421c0e  file' ;;
        esac
    fi
}
"""
            code += FUNCTIONS
            code += r"""
if mt_select_kn_arch; then
    echo "selected:$MT_KN_ARCH"
else
    echo "not-selected"
    exit 3
fi
if mt_verified_kn_fallback; then echo 'fallback-success'; else echo 'fallback-fail'; fi
"""
            env = dict(TEST_TMP=d, TEST_ARCH=arch, TEST_GITHUB=github,
                       TEST_GITLAB=gitlab, TEST_SHA=sha,
                       TEST_SIZE_MODE=size, TEST_INSTALLED=str(int(installed)))
            if github_rc is not None:
                env["TEST_GITHUB_RC"] = str(github_rc)
            run = subprocess.run(["sh", "-s"], input=code, text=True,
                                 env={**os.environ, **env}, capture_output=True, timeout=12)
            trace = (Path(d) / "trace")
            return run.returncode, run.stdout + ("\nSTDERR: " + run.stderr if run.returncode else ""), (trace.read_text() if trace.exists() else "")

    # --- fallback chain ---------------------------------------------------

    def test_official_feed_gone_github_works(self):
        rc, out, trace = self.runner(github="ok")
        self.assertEqual(rc, 0, out)
        self.assertIn("fallback-success", out)
        self.assertIn("github", trace)
        self.assertNotIn("gitlab", trace)
        self.assertEqual(trace.count("install:"), 1)

    def test_github_down_gitlab_works(self):
        rc, out, trace = self.runner(github="fail", gitlab="ok")
        self.assertEqual(rc, 0, out)
        self.assertIn("github\ngitlab\n", trace)
        # Versioned GitLab URL is selected, never a generic Entware artifact.
        self.assertEqual(trace.count("install:"), 1)

    def test_all_sources_down_honest_failure(self):
        rc, out, trace = self.runner(github="fail", gitlab="fail")
        self.assertEqual(rc, 0)
        self.assertIn("fallback-fail", out)
        self.assertNotIn("install:", trace)

    def test_fail_on_unknown_architecture(self):
        rc, out, trace = self.runner(arch="armv7-3.2")
        self.assertEqual(rc, 3)
        self.assertEqual(trace, "")

    def test_fail_on_checksum_mismatch(self):
        rc, out, trace = self.runner(github="ok", gitlab="ok", sha="wrong")
        self.assertEqual(rc, 0)
        self.assertIn("fallback-fail", out)
        self.assertNotIn("install:", trace)

    def test_fail_on_truncated_ipk_size_mismatch(self):
        rc, out, trace = self.runner(github="ok", gitlab="ok", size="wrong")
        self.assertEqual(rc, 0)
        self.assertIn("fallback-fail", out)
        self.assertNotIn("install:", trace)

    def test_tls_error_falls_through_to_gitlab(self):
        # curl exit 60 = TLS peer certificate problem; must be treated like any
        # transport failure (never retried with -k, never bypassed).
        rc, out, trace = self.runner(github="ok", gitlab="ok", github_rc=60)
        self.assertEqual(rc, 0, out)
        self.assertIn("github\ngitlab\n", trace)
        self.assertIn("fallback-success", out)
        self.assertEqual(trace.count("install:"), 1)

    def test_http_status_errors_fall_through(self):
        for rc_code in (22, 8):  # curl -f: 22 = HTTP >= 400 (404/500/503), 8 = bad reply
            rc, out, trace = self.runner(github="ok", gitlab="ok", github_rc=rc_code)
            self.assertEqual(rc, 0, out)
            self.assertIn("github\ngitlab\n", trace)
            self.assertIn("fallback-success", out)

    def test_no_timeout_applet_dependency(self):
        # The fallback must rely on curl/wget built-in timeouts only: no
        # external `timeout` applet invocation (a standalone `timeout` word
        # that is not part of --connect-timeout/--max-time flags).
        import re as _re
        for fragment in (FUNCTIONS, PROBE):
            self.assertIsNone(_re.search(r"(?<![-\w])timeout(?=[\s|;])", fragment))

    def test_already_installed_mt_is_never_touched(self):
        rc, out, trace = self.runner(github="ok", gitlab="ok", installed=True)
        self.assertEqual(rc, 0)
        self.assertIn("fallback-fail", out)
        self.assertNotIn("github", trace)
        self.assertNotIn("install:", trace)

    def test_no_downgrade_or_forced_flags(self):
        self.assertNotIn("--force", FUNCTIONS)
        self.assertNotIn("--autoremove", FUNCTIONS)
        self.assertIn("Never replace or downgrade an existing MagiTrickle",
                      FUNCTIONS)
        self.assertIn("pkg_is_installed magitrickle && return 1", FUNCTIONS)

    def test_rerun_after_outage_installs_exactly_once(self):
        # First run: every source unreachable (network outage). Second run
        # (same harness state): GitHub is back; the fallback installs exactly
        # once and never keeps a half-installed state across runs.
        rc1, out1, trace1 = self.runner(github="fail", gitlab="fail")
        self.assertEqual(rc1, 0)
        self.assertIn("fallback-fail", out1)
        self.assertNotIn("install:", trace1)
        rc2, out2, trace2 = self.runner(github="ok")
        self.assertEqual(rc2, 0)
        self.assertIn("fallback-success", out2)
        self.assertEqual(trace2.count("install:"), 1)

    def test_source_only_three_kn_architectures(self):
        for arch in ("aarch64-3.10_kn", "mips-3.4_kn", "mipsel-3.4_kn"):
            rc, out, trace = self.runner(arch=arch, github="ok")
            self.assertEqual(rc, 0, out)
            self.assertIn("selected:" + arch, out)
            self.assertIn("fallback-success", out)
        self.assertIn("0.8.2-1_entware_$MT_KN_ARCH.ipk", FUNCTIONS)
        self.assertIn("0.8.2-2_entware_$MT_KN_ARCH.ipk", FUNCTIONS)


class FeedProbeRegression(unittest.TestCase):
    def probe_runner(self, conf, update, feed, installed=0):
        # The probe fragment and this fixture must agree on one /opt path.
        # Only a POSIX host (WSL/Linux/CI) shares /opt between Python and the
        # shell: on Windows Python resolves /opt to the current drive while
        # MSYS sh maps it into the Git installation, so the fragment would
        # never see the fixture and every scenario would fail for the wrong
        # reason (and the fixture would pollute the host). Skip honestly.
        if os.name != "posix":
            self.skipTest("needs a POSIX host where /opt is shared with sh")
        # Sandbox /opt/etc/opkg the same way other KAS regressions do; skip
        # cleanly when the test environment cannot create /opt.
        try:
            opt = Path("/opt/etc/opkg")
            opt.mkdir(parents=True, exist_ok=True)
            conf_path = opt / "magitrickle.conf"
            if conf is None:
                conf_path.unlink(missing_ok=True)
            else:
                conf_path.write_text(conf, encoding="utf-8")
        except OSError:
            self.skipTest("cannot create /opt/etc/opkg sandbox")
        code = r"""
set -u
TRACE="$TEST_TMP/trace"
log() { :; }
warn() { printf 'WARN\n' >> "$TRACE"; }
err() { printf 'ERR\n' >> "$TRACE"; exit 1; }
retry() { "$@"; }
opkg() {
    case "$1" in
        update) [ "$TEST_UPDATE" = ok ] || return 1 ;;
        list-installed) [ "$TEST_INSTALLED" = 1 ] && printf 'magitrickle 0.8.2-1\n' || : ;;
        *) : ;;
    esac
}
curl() { [ "$TEST_FEED" = reachable ] && return 0 || return 7; }
wget() { return 7; }
"""
        code += PROBE
        code += '\nprintf "PROBE-CONTINUED\\n" >> "$TRACE"\n'
        return run_fragment(code, dict(TEST_UPDATE=update,
                                       TEST_FEED=feed, TEST_INSTALLED=str(installed)))

    def test_update_fails_mt_feed_down_not_installed_continues(self):
        conf = "src/gz magitrickle_mipsel-3.4_kn http://bin.magitrickle.dev/packages/entware/mipsel-3.4_kn\n"
        rc, out, trace = self.probe_runner(conf, update="fail", feed="down")
        self.assertEqual(rc, 0)
        self.assertIn("WARN", trace)
        self.assertIn("PROBE-CONTINUED", trace)
        self.assertNotIn("ERR", trace)

    def test_update_fails_feed_reachable_fails_closed(self):
        conf = "src/gz magitrickle_mipsel-3.4_kn http://bin.magitrickle.dev/packages/entware/mipsel-3.4_kn\n"
        rc, out, trace = self.probe_runner(conf, update="fail", feed="reachable")
        self.assertEqual(rc, 1)
        self.assertIn("ERR", trace)
        self.assertNotIn("PROBE-CONTINUED", trace)

    def test_update_fails_mt_installed_fails_closed(self):
        conf = "src/gz magitrickle_mipsel-3.4_kn http://bin.magitrickle.dev/packages/entware/mipsel-3.4_kn\n"
        rc, out, trace = self.probe_runner(conf, update="fail", feed="down", installed=1)
        self.assertEqual(rc, 1)
        self.assertIn("ERR", trace)
        self.assertNotIn("PROBE-CONTINUED", trace)

    def test_no_conf_fails_closed(self):
        rc, out, trace = self.probe_runner(None, update="fail", feed="down")
        self.assertEqual(rc, 1)
        self.assertIn("ERR", trace)

    def test_update_ok_continues(self):
        conf = "src/gz magitrickle_mipsel-3.4_kn http://bin.magitrickle.dev/packages/entware/mipsel-3.4_kn\n"
        rc, out, trace = self.probe_runner(conf, update="ok", feed="down")
        self.assertEqual(rc, 0)
        self.assertIn("PROBE-CONTINUED", trace)
        self.assertNotIn("WARN", trace)
        self.assertNotIn("ERR", trace)


if __name__ == "__main__":
    unittest.main()
