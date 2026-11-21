#!/usr/bin/env python3
"""Real-HTTP regression: bootstrap.sh against loopback GitHub/GitLab simulators.

Runs the actual bootstrap with the actual system curl against a real
127.0.0.1 HTTP server that emulates the GitHub raw/Contents endpoints and
the GitLab raw + repository-files attestation endpoints for the SAME ref.
No public network is touched: the loopback-only KAS_MOCK_* endpoint
overrides must be accepted for these simulators and refused for anything
else. Run: python3 tests/script-mirror-real-http-regression.py

Covers (issue #232): real transport integrity for the verified GitLab
mirror fallback — mid-body connection close at the 16KB/20KB DPI cut sizes,
a lying Content-Length (curl exit 0 with a partial body), metadata/raw
desynchronisation, attestation drift, and fail-closed behaviour.
"""
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
SENTINEL = "# KAS_EOF_V1\n"
PAD = "# " + "A" * 21500 + "\n"
GOOD = (
    "#!/bin/sh\n"
    "PROJECT_API_CONTENTS='https://api.github.com/repos/test/contents'\n"
    "download_project_script() { :; }\n"
    + PAD +
    "printf 'SETUP_RAN\\n'\n" + SENTINEL
).encode()
OTHER = (
    "#!/bin/sh\n"
    "PROJECT_API_CONTENTS='other'\n"
    + PAD +
    "printf 'WRONG_SCRIPT_RAN\\n'\n" + SENTINEL
).encode()

PROJECT = "saymer-alt%2Fkeenetic-auto-setup"
GL_RAW_PREFIX = "/-/raw/"
GL_META_PREFIX = "/projects/" + PROJECT + "/repository/files/"


def attest(data):
    return {
        "blob_id": hashlib.sha1(b"blob %d\x00" % len(data) + data).hexdigest(),
        "content_sha256": hashlib.sha256(data).hexdigest(),
        "size": len(data),
        "commit_id": "attested-commit",
    }


class Lab:
    """Shared, per-test mutable server state."""

    def __init__(self):
        self.gh_raw = None          # bytes or 'fail'
        self.gh_api = None
        self.gl_raw = None          # bytes, ('cut', n), ('lying', n) or 'fail'
        self.gl_meta = None         # dict overrides or 'fail' or 'html'
        self.requests = []

    def log(self, what):
        self.requests.append(what)


def make_handler(lab):
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):
            pass

        def _body(self, data):
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _not_found(self):
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_GET(self):
            path = self.path.split("?")[0]
            if "/repository/files/" in path:
                lab.log("gl_meta")
                script = path[len(GL_META_PREFIX):]
                if lab.gl_meta == "fail":
                    self._not_found()
                    return
                if lab.gl_meta == "html":
                    self._body(b"<html>rate limited</html>")
                    return
                script = path[len(GL_META_PREFIX):]
                payload = dict(lab.gl_meta or {})
                base = lab.gl_raw if isinstance(lab.gl_raw, bytes) else GOOD
                obj = attest(base)
                obj.update(payload)
                self._body(json.dumps(obj, separators=(",", ":")).encode())
                return
            if path == "/redirect-target":
                lab.log("redirect_target")
                self._body(GOOD)
                return
            if path.startswith(GL_RAW_PREFIX):
                lab.log("gl_raw")
                if isinstance(lab.gl_raw, tuple) and lab.gl_raw[0] == "redirect":
                    self.send_response(302)
                    self.send_header("Location", lab.gl_raw[1])
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if lab.gl_raw == "fail":
                    self._not_found()
                    return
                if isinstance(lab.gl_raw, tuple) and lab.gl_raw[0] == "cut":
                    # Real mid-body close at a DPI-cut size: curl must not
                    # report success on this transfer.
                    n = lab.gl_raw[1]
                    self.send_response(200)
                    self.send_header("Content-Type", "text/plain")
                    self.send_header("Content-Length", str(len(GOOD)))
                    self.end_headers()
                    self.wfile.write(GOOD[:n])
                    self.wfile.flush()
                    self.close_connection = True
                    return
                if isinstance(lab.gl_raw, tuple) and lab.gl_raw[0] == "lying":
                    # Attest a small clean Content-Length, deliver a short
                    # body and close cleanly: curl exits 0 with a partial
                    # body that can never carry the sentinel.
                    n = lab.gl_raw[1]
                    self.send_response(200)
                    self.send_header("Content-Type", "text/plain")
                    self.send_header("Content-Length", str(n))
                    self.end_headers()
                    self.wfile.write(GOOD[:n])
                    self.wfile.flush()
                    self.close_connection = True
                    return
                if isinstance(lab.gl_raw, bytes):
                    self._body(lab.gl_raw)
                    return
                self._not_found()
                return
            if path.startswith("/repos/saymer-alt/keenetic-auto-setup/contents/"):
                lab.log("gh_api")
                if lab.gh_api == "fail" or not isinstance(lab.gh_api, bytes):
                    self._not_found()
                else:
                    self._body(lab.gh_api)
                return
            if path.startswith("/test-ref/") or path.startswith("/stable/"):
                lab.log("gh_raw")
                if lab.gh_raw == "fail" or not isinstance(lab.gh_raw, bytes):
                    self._not_found()
                else:
                    self._body(lab.gh_raw)
                return
            self._not_found()

    return Handler


def run_bootstrap(shell, env_extra):
    with tempfile.TemporaryDirectory(prefix="kas-mirror-http-") as tmp:
        env = os.environ.copy()
        env.update({
            "TMPDIR": tmp,
            "KAS_BOOTSTRAP_REF": "test-ref",
            "NO_COLOR": "1",
            "TERM": "dumb",
        })
        env.update(env_extra)
        return subprocess.run(
            shell + [str(ROOT / "bootstrap.sh")],
            text=True, capture_output=True, timeout=60,
            env=env, cwd=ROOT, check=False,
            stdin=subprocess.DEVNULL,
        ), Path(tmp)


def main():
    curl = shutil.which("curl")
    if not curl:
        print("SKIP: system curl not available")
        return
    shells = [["/bin/sh"]]
    bb = shutil.which("busybox")
    if bb:
        shells.append([bb, "ash"])

    lab = Lab()
    handler_cls = make_handler(lab)

    class BoundServer(http.server.ThreadingHTTPServer):
        def finish_request(self, request, client_address):
            handler_cls(request, client_address, self)

    server = BoundServer(("127.0.0.1", 0), None)
    port = server.server_address[1]
    base = f"http://127.0.0.1:{port}"
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()

    mock_env = {
        "KAS_MOCK_GH_RAW_BASE": base,
        "KAS_MOCK_GH_API_BASE": base + "/repos/saymer-alt/keenetic-auto-setup",
        "KAS_MOCK_GL_RAW_BASE": base,
        "KAS_MOCK_GL_API_BASE": base + "/api/v4",
    }

    def check(shell, title, setup, env_extra, want_exit, want_run,
              want_stderr=None, forbid=None):
        setup()
        lab.requests.clear()
        r, _ = run_bootstrap(shell, env_extra)
        if r.returncode != want_exit:
            raise AssertionError((title, r.returncode, r.stdout, r.stderr))
        assert ("SETUP_RAN" in r.stdout) == want_run, (title, r.stdout, r.stderr)
        assert "WRONG_SCRIPT_RAN" not in r.stdout, title
        if want_stderr and want_stderr not in r.stderr:
            raise AssertionError((title, want_stderr, r.stderr))
        if forbid:
            assert forbid not in lab.requests, (title, lab.requests)
        print("PASS", shell, title)

    try:
        for shell in shells:
            # Happy path: GitHub raw serves the real bytes.
            check(shell, "gh_raw_good",
                  lambda: setattr(lab, "gh_raw", GOOD) or setattr(lab, "gh_api", "fail")
                  or setattr(lab, "gl_raw", "fail") or setattr(lab, "gl_meta", "fail"),
                  mock_env, 0, True)
            # GitHub fully down: real transport, real binding, verified
            # GitLab mirror fallback succeeds.
            def gh_down_gl_good():
                lab.gh_raw = "fail"; lab.gh_api = "fail"
                lab.gl_raw = GOOD; lab.gl_meta = {}
            check(shell, "gh_down_gitlab_verified_good",
                  gh_down_gl_good, mock_env, 0, True)

            # Real mid-body close at the DPI cut sizes (curl never exits 0).
            def cut16():
                lab.gh_raw = "fail"; lab.gh_api = "fail"
                lab.gl_raw = ("cut", 16384); lab.gl_meta = {}
            check(shell, "gitlab_cut16k_midclose_rejected",
                  cut16, mock_env, 1, False)
            def cut20():
                lab.gh_raw = "fail"; lab.gh_api = "fail"
                lab.gl_raw = ("cut", 20480); lab.gl_meta = {}
            check(shell, "gitlab_cut20k_midclose_rejected",
                  cut20, mock_env, 1, False)
            # Lying Content-Length: curl exits 0 with a short body; the
            # missing sentinel must fail the run closed.
            def lying():
                lab.gh_raw = "fail"; lab.gh_api = "fail"
                lab.gl_raw = ("lying", 16384); lab.gl_meta = {}
            check(shell, "gitlab_lying_cl_exit0_partial_rejected",
                  lying, mock_env, 1, False)
            # Attestation/raw desynchronisation (mirror drift or ref race).
            def race():
                lab.gh_raw = "fail"; lab.gh_api = "fail"
                lab.gl_raw = OTHER; lab.gl_meta = {}
            check(shell, "gitlab_meta_raw_race_rejected",
                  race, mock_env, 1, False)
            # Tampered attestation fields (drift).
            def drift_sha():
                lab.gh_raw = "fail"; lab.gh_api = "fail"
                lab.gl_raw = GOOD; lab.gl_meta = {"content_sha256": "0" * 64}
            check(shell, "gitlab_attested_sha_drift_rejected",
                  drift_sha, mock_env, 1, False)
            def drift_blob():
                lab.gh_raw = "fail"; lab.gh_api = "fail"
                lab.gl_raw = GOOD; lab.gl_meta = {"blob_id": "0" * 40}
            check(shell, "gitlab_attested_blob_drift_rejected",
                  drift_blob, mock_env, 1, False)
            # Attestation endpoint down: fail closed, raw never consulted.
            def meta_down():
                lab.gh_raw = "fail"; lab.gh_api = "fail"
                lab.gl_raw = GOOD; lab.gl_meta = "fail"
            check(shell, "gitlab_meta_down_fail_closed",
                  meta_down, mock_env, 1, False,
                  forbid="gl_raw")
            # A mock GitLab endpoint may redirect to a different URL.
            # Even a same-loopback redirect carrying fully valid staged bytes
            # must NOT be followed in mock mode (never leave the URL gate).
            def redirect():
                lab.gh_raw = "fail"; lab.gh_api = "fail"
                lab.gl_raw = ("redirect", base + "/redirect-target")
                lab.gl_meta = {}
            check(shell, "mock_gitlab_redirect_rejected",
                  redirect, mock_env, 1, False,
                  forbid="redirect_target")
            # Loopback-only override gate: a non-loopback base is refused
            # before any request is made.
            check(shell, "mock_override_nonloopback_refused",
                  lambda: None,
                  {"KAS_MOCK_GL_RAW_BASE": "http://192.0.2.9:9999"},
                  2, False, want_stderr="must be unset or a loopback http URL")
    finally:
        server.shutdown()
        server.server_close()
    print("PASS all real-HTTP mirror cases over loopback curl")


if __name__ == "__main__":
    main()
