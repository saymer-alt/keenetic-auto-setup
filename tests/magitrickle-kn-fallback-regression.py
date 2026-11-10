#!/usr/bin/env python3
"""No-network behavioral regressions for KAS MagiTrickle _kn fallback."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

INSTALL = Path(__file__).resolve().parents[1] / "install.sh"
BEGIN = "# BEGIN MAGITRICKLE KN FALLBACK v1"
END = "# END MAGITRICKLE KN FALLBACK v1"
SCRIPT = INSTALL.read_text(encoding="utf-8")
assert SCRIPT.count(BEGIN) == SCRIPT.count(END) == 1
FUNCTIONS = SCRIPT.split(BEGIN, 1)[1].split(END, 1)[0]


class FallbackRegression(unittest.TestCase):
    def runner(self, arch="mipsel-3.4_kn", github="fail", gitlab="ok",
               sha="correct", installed=False):
        with tempfile.TemporaryDirectory() as d:
            code = r"""
set -eu
TMP_DIR="$TEST_TMP"
FAKE_INSTALLED=0
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
wc() {
    case "$FAKE_SOURCE:$TEST_ARCH" in
        github:aarch64-3.10_kn) echo 2548308 ;;
        github:mips-3.4_kn) echo 2379639 ;;
        github:mipsel-3.4_kn) echo 2418194 ;;
        gitlab:aarch64-3.10_kn) echo 2547127 ;;
        gitlab:mips-3.4_kn) echo 2380080 ;;
        gitlab:mipsel-3.4_kn) echo 2418259 ;;
        *) echo 0 ;;
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
            env = os.environ.copy()
            env.update(TEST_TMP=d, TEST_ARCH=arch, TEST_GITHUB=github,
                       TEST_GITLAB=gitlab, TEST_SHA=sha)
            run = subprocess.run(["sh", "-s"], input=code, text=True,
                                 env=env, capture_output=True, timeout=12)
            trace = (Path(d) / "trace")
            return run.returncode, run.stdout + ("\nSTDERR: " + run.stderr if run.returncode else ""), (trace.read_text() if trace.exists() else "")

    def test_github_first_and_one_install(self):
        rc, out, trace = self.runner(github="ok")
        self.assertEqual(rc, 0, out)
        self.assertIn("fallback-success", out)
        self.assertIn("github", trace)
        self.assertNotIn("gitlab", trace)
        self.assertEqual(trace.count("install:"), 1)

    def test_gitlab_after_github_network_failure(self):
        rc, out, trace = self.runner(github="fail", gitlab="ok")
        self.assertEqual(rc, 0, out)
        self.assertIn("github\ngitlab\n", trace)
        # Versioned GitLab URL is selected, never a generic Entware artifact.
        self.assertEqual(trace.count("install:"), 1)

    def test_fail_on_unknown_architecture(self):
        rc, out, trace = self.runner(arch="armv7-3.2")
        self.assertEqual(rc, 3)
        self.assertEqual(trace, "")

    def test_fail_on_both_network_sources(self):
        rc, out, trace = self.runner(github="fail", gitlab="fail")
        self.assertEqual(rc, 0)
        self.assertIn("fallback-fail", out)
        self.assertNotIn("install:", trace)

    def test_fail_on_checksum_mismatch(self):
        rc, out, trace = self.runner(github="ok", gitlab="ok", sha="wrong")
        self.assertEqual(rc, 0)
        self.assertIn("fallback-fail", out)
        self.assertNotIn("install:", trace)

    def test_source_only_three_kn_architectures(self):
        for arch in ("aarch64-3.10_kn", "mips-3.4_kn", "mipsel-3.4_kn"):
            rc, out, trace = self.runner(arch=arch, github="ok")
            self.assertEqual(rc, 0, out)
            self.assertIn("selected:" + arch, out)
            self.assertIn("fallback-success", out)
        self.assertIn("pkg_is_installed magitrickle && return 1", FUNCTIONS)
        self.assertNotIn("--force-downgrade", FUNCTIONS)
        self.assertNotIn("--force-architecture", FUNCTIONS)
        self.assertIn("0.8.2-1_entware_$MT_KN_ARCH.ipk", FUNCTIONS)
        self.assertIn("0.8.2-2_entware_$MT_KN_ARCH.ipk", FUNCTIONS)


if __name__ == "__main__":
    unittest.main()
