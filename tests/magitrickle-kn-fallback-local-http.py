#!/usr/bin/env python3
"""Local-HTTP behavioral tests for the MagiTrickle _kn fallback download path.

Runs the extracted install.sh fallback fragment against a REAL local HTTP
server with the REAL system curl: wrong HTTP status (404/500/503), truncated
IPK, corrupted bytes, HTML instead of an IPK, a slow server (real curl
--max-time abort) and — when the verified upstream bytes are provided locally
via KAS_MT_REAL_IPK_DIR — the full positive download+verify+install flow.

No network access: every pinned upstream URL is mapped onto 127.0.0.1.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import os
import re
import subprocess
import tempfile
import threading
import unittest

INSTALL = Path(__file__).resolve().parents[1] / "install.sh"
BEGIN = "# BEGIN MAGITRICKLE KN FALLBACK v1 (issue #505)"
END = "# END MAGITRICKLE KN FALLBACK v1"
SCRIPT = INSTALL.read_text(encoding="utf-8")
FUNCTIONS = SCRIPT.split(BEGIN, 1)[1].split(END, 1)[0]

EXPECTED_SHA = {
    "magitrickle_0.8.2-2_entware_mipsel-3.4_kn.ipk":
        "ad2732a4ab3d25abbf38a65ab8306d22138a959173234f6b2deb5326923fcd93",
    "magitrickle_0.8.2-1_entware_mipsel-3.4_kn.ipk":
        "5a10083cc063731536d8c7820c008348e99a16cf821534f51f1a415f50421c0e",
}


class MirrorHandler(BaseHTTPRequestHandler):
    # behavior[basename] = ("bytes", payload) | ("status", code) | ("slow", code)
    behavior = {}

    def do_GET(self):
        name = self.path.rsplit("/", 1)[-1]
        self.server.__dict__.setdefault("served", []).append(self.path)
        mode = self.behavior.get(name, ("status", 404))
        if mode[0] == "status":
            self.send_response(mode[1])
            self.end_headers()
        elif mode[0] == "slow":
            self.send_response(200)
            self.send_header("Content-Length", str(len(mode[2])))
            self.end_headers()
            self.wfile.write(mode[2][:1])
            self.server.__dict__.setdefault("slow_paths", set()).add(name)
            import time
            time.sleep(12)
        elif mode[0] == "bytes":
            payload = mode[1]
            self.send_response(200)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        else:  # html
            payload = b"<html><body>not an ipk</body></html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    def log_message(self, *args):
        pass


class LocalHttpFallback(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), MirrorHandler)
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def fallback_runner(self, behavior, real_ipk_dir=None):
        """Run the fallback fragment with real curl against the local server."""
        MirrorHandler.behavior = behavior
        self.server.__dict__["served"] = []
        self.server.__dict__.pop("slow_paths", None)
        env = os.environ.copy()
        env["TEST_PORT"] = str(self.port)
        fragment = r"""
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
        print-architecture) printf 'arch all 1\narch mipsel-3.4_kn 20\n' ;;
        status) printf 'Package: magitrickle\nStatus: install ok installed\nArchitecture: mipsel-3.4_kn\n' ;;
        install) printf '%s\n' "install:$2" >> "$TRACE"; FAKE_INSTALLED=1 ;;
        *) return 1 ;;
    esac
}
# Only the fixed invocation of mt_verified_kn_fallback is supported here;
# a shape change must fail loudly instead of silently bypassing the mapping.
curl() {
    if [ "$#" -ne 13 ] || [ "$1" != "-q" ] || [ "$2" != "-fSsL" ] || \
       [ "$3" != "--proto" ] || [ "$4" != "=https" ] || \
       [ "$5" != "--proto-redir" ] || [ "$6" != "=https" ] || \
       [ "$7" != "--connect-timeout" ] || [ "$9" != "--max-time" ] || \
       [ "${12}" != "-o" ]; then
        echo "unexpected curl invocation: $*" >> "$TRACE"
        return 64
    fi
    _url="${11}"; _out="${13}"
    case "$_url" in
        https://github.com/*) _url="http://127.0.0.1:${TEST_PORT}/gh${_url#https://github.com}" ;;
        https://gitlab.com/*) _url="http://127.0.0.1:${TEST_PORT}/gl${_url#https://gitlab.com}" ;;
        *) return 64 ;;
    esac
    command curl -fsS --connect-timeout 2 --max-time 6 "$_url" -o "$_out"
}
"""
        fragment += FUNCTIONS
        fragment += r"""
if mt_select_kn_arch; then
    echo "selected:$MT_KN_ARCH"
else
    echo "not-selected"; exit 3
fi
if mt_verified_kn_fallback; then echo 'fallback-success'; else echo 'fallback-fail'; fi
"""
        with tempfile.TemporaryDirectory() as d:
            env["TEST_TMP"] = d
            run = subprocess.run(["sh", "-s"], input=fragment, text=True,
                                 env=env, capture_output=True, timeout=40)
            trace = Path(d) / "trace"
            out = run.stdout
            if run.returncode:
                out += "\nSTDERR: " + run.stderr
            return run.returncode, out, (trace.read_text() if trace.exists() else "")

    def upstream_behavior(self, name, mode, payload=None):
        """behavior entries for the mipsel-3.4_kn pinned basenames."""
        if name.startswith("0.8.2-2"):
            return {"magitrickle_0.8.2-2_entware_mipsel-3.4_kn.ipk": mode}
        return {"magitrickle_0.8.2-1_entware_mipsel-3.4_kn.ipk": mode}

    def test_404_then_gitlab_404_honest_failure(self):
        b = {}
        b.update(self.upstream_behavior("0.8.2-2", ("status", 404)))
        b.update(self.upstream_behavior("0.8.2-1", ("status", 404)))
        rc, out, trace = self.fallback_runner(b)
        self.assertEqual(rc, 0)
        self.assertIn("fallback-fail", out)
        self.assertNotIn("install:", trace)

    def test_500_and_503_honest_failure(self):
        for code in (500, 503):
            b = {}
            b.update(self.upstream_behavior("0.8.2-2", ("status", code)))
            b.update(self.upstream_behavior("0.8.2-1", ("status", code)))
            rc, out, trace = self.fallback_runner(b)
            self.assertEqual(rc, 0)
            self.assertIn("fallback-fail", out)
            self.assertNotIn("install:", trace)

    def test_truncated_ipk_refused(self):
        payload = b"truncated-data-" * 1024  # wrong size and bytes
        b = {}
        b.update(self.upstream_behavior("0.8.2-2", ("bytes", payload)))
        b.update(self.upstream_behavior("0.8.2-1", ("bytes", payload)))
        rc, out, trace = self.fallback_runner(b)
        self.assertEqual(rc, 0)
        self.assertIn("fallback-fail", out)
        self.assertNotIn("install:", trace)

    def test_html_instead_of_ipk_refused(self):
        b = {}
        b.update(self.upstream_behavior("0.8.2-2", ("html",)))
        b.update(self.upstream_behavior("0.8.2-1", ("html",)))
        rc, out, trace = self.fallback_runner(b)
        self.assertEqual(rc, 0)
        self.assertIn("fallback-fail", out)
        self.assertNotIn("install:", trace)

    def test_slow_server_real_curl_timeout(self):
        b = {}
        b.update(self.upstream_behavior("0.8.2-2", ("slow", 200, b"x" * 4096)))
        b.update(self.upstream_behavior("0.8.2-1", ("status", 404)))
        rc, out, trace = self.fallback_runner(b)
        self.assertEqual(rc, 0)
        self.assertIn("fallback-fail", out)
        self.assertNotIn("install:", trace)

    def test_positive_flow_with_real_verified_bytes(self):
        src = os.environ.get("KAS_MT_REAL_IPK_DIR")
        if not src or not Path(src).is_dir():
            self.skipTest("KAS_MT_REAL_IPK_DIR with verified upstream IPKs not provided")
        b = {}
        for name in EXPECTED_SHA:
            data = (Path(src) / name).read_bytes()
            import hashlib
            self.assertEqual(hashlib.sha256(data).hexdigest(), EXPECTED_SHA[name],
                             "provided bytes do not match pinned upstream digest")
            rev = name.split("_")[1].split("-entware")[0]
            b[name] = ("bytes", data)
        # Serve correct bytes for the mipsel-3.4_kn pinned files; the fallback
        # selects GitHub 0.8.2-2 first and must install it exactly once.
        rc, out, trace = self.fallback_runner(b)
        self.assertEqual(rc, 0)
        self.assertIn("fallback-success", out)
        self.assertEqual(trace.count("install:"), 1)
        served = "".join(self.server.__dict__["served"])
        self.assertIn("/gh/", served)          # GitHub 0.8.2-2 was fetched first
        self.assertNotIn("/gl/", served)       # no GitLab fetch after GitHub success


if __name__ == "__main__":
    unittest.main()
