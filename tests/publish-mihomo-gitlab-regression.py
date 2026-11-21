#!/usr/bin/env python3
"""Synthetic negative/positive regression for scripts/publish-mihomo-gitlab.sh.

Runs the real publish tool against a loopback GitLab Generic Package Registry
simulator. Never touches gitlab.com and never issues a real PUT. Covers the
fail-closed publication contract from mirrors/mihomo/GITLAB-PUBLISH.md:

  - progress only when ALL files (5 IPKs + SHA256SUMS) are confirmed 404;
  - partial publication (any 200) -> ABORT, zero PUTs;
  - unknown state (5xx/403/transport error/bad PAT) -> STOP, zero PUTs;
  - non-public project -> STOP, zero PUTs;
  - mid-upload failure -> STOP; a re-run must abort on the already-published
    files instead of overwriting anything;
  - bundle integrity gate (tampered SHA256SUMS -> refuse before any HTTP);
  - independent trust gate: the bundle must match the reviewed lock manifest
    (tampered IPKs behind a regenerated SHA256SUMS -> refuse before any HTTP;
    the verifier override is refused outside loopback hosts);
  - the documented launch form from GITLAB-PUBLISH.md: the exported Step 1
    snippet runs end-to-end against the simulator, the same snippet WITHOUT
    export refuses at preflight (why `export` is mandatory), and the Step 2a
    verification commands resolve from a really created verify-mihomo
    directory via the absolute REPO_ROOT;
  - PAT hygiene: never on a command line (--user absent), 0600 temp curl
    config removed on exit (no leftovers in TMPDIR), PAT never in output;
  - mandatory anonymous post-verification (200 + byte equality).

Hosts that cannot emulate POSIX file modes (MSYS: stat always reports 644)
honestly SKIP the mode-dependent scenarios; they run in WSL/CI where 0600
is real (the operator environment this tool targets).

Run: python3 tests/publish-mihomo-gitlab-regression.py
"""
import hashlib
import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "publish-mihomo-gitlab.sh"
IPK_NAMES = [
    "mihomo_1.19.34-3_aarch64-3.10.ipk",
    "mihomo_1.19.34-3_armv7-3.2.ipk",
    "mihomo_1.19.34-3_mips-3.4.ipk",
    "mihomo_1.19.34-3_mipsel-3.4.ipk",
    "mihomo_nohf_1.19.34-3_armv7-3.2.ipk",
]
ALL_FILES = IPK_NAMES + ["SHA256SUMS"]
PAT = "glpat-mocktoken123456"

MODE_OK = None  # can this host create/observe a 0600 file? probed in main()
SKIP = []


def new_state():
    return {
        "proj_status": 200, "proj_visibility": "public",
        "probe": {},            # file name -> '200' | '500' | '403' | 'fail'
        "put_fail_on": 0,       # fail the Nth PUT with 500 (0 = never)
        "put_attempts": 0,
        "published_bytes": {},  # file name -> uploaded bytes
        "anon_override": {},    # file name -> bytes or 'HTTP_500'
        "requests": [],
    }


class MockGitLab(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _send(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _fail_transport(self):
        self.close_connection = True
        raise Exception("simulated transport failure")

    def do_GET(self):
        st = self.server.kas_state
        st["requests"].append(("GET", self.path))
        if self.path.startswith("/api/v4/projects/") and "/packages/" not in self.path:
            body = json.dumps({"id": 1234, "visibility": st["proj_visibility"]}).encode()
            self._send(st["proj_status"], body)
            return
        if "/packages/generic/" in self.path:
            name = self.path.rsplit("/", 1)[-1]
            if self.headers.get("Authorization"):
                # Authorized pre-publish probe: 200 only for actually
                # uploaded files, overrides simulate server-side state.
                if name in st["published_bytes"]:
                    self._send(200, st["published_bytes"][name])
                    return
                probe = st["probe"].get(name, "404")
                if probe == "fail":
                    self._fail_transport()
                    return
                self._send({"404": 404, "200": 200, "500": 500, "403": 403}[probe], b"")
                return
            # Anonymous fetch (as a router sees the mirror).
            if name in st["anon_override"]:
                if st["anon_override"][name] == "HTTP_500":
                    self._send(500, b"")
                else:
                    self._send(200, st["anon_override"][name])
                return
            if name in st["published_bytes"]:
                self._send(200, st["published_bytes"][name])
                return
            self._send(404, b"")
            return
        self._send(404, b"")

    def do_PUT(self):
        st = self.server.kas_state
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        st["put_attempts"] += 1
        if st["put_fail_on"] and st["put_attempts"] >= st["put_fail_on"]:
            self._send(500, b"")
            return
        st["published_bytes"][self.path.rsplit("/", 1)[-1]] = body
        st["requests"].append(("PUT", self.path))
        self._send(201, b"")


def start_server(state):
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), MockGitLab)
    srv.kas_state = state
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def _p(path):
    """Forward-slash path accepted by both MSYS sh and POSIX sh."""
    return str(path).replace("\\", "/")


def make_bundle(d):
    files = {n: ("PKGMOCK:" + n).encode() for n in IPK_NAMES}
    for n, b in files.items():
        (d / n).write_bytes(b)
    # LF bytes on purpose: sha256sum -c must see plain "\n" endings (a CRLF
    # checkout would turn "name\r" into an unfindable file name).
    (d / "SHA256SUMS").write_bytes(
        "".join(hashlib.sha256(files[n]).hexdigest() + "  " + n + "\n"
                for n in IPK_NAMES).encode())


def make_pat_file(d, good=True):
    p = d / "pat.txt"
    if good:
        subprocess.run(["sh", "-c", 'umask 077; printf "%s" "$2" > "$1"; chmod 600 "$1"',
                        "sh", _p(p), PAT], check=True)
    else:
        subprocess.run(["sh", "-c", 'umask 022; printf "%s" "$2" > "$1"; chmod 644 "$1"',
                        "sh", _p(p), PAT], check=True)
    return p


def make_verify_stub(d, ok=True):
    """Loopback-only verifier substitute (the publish tool refuses this
    override outside loopback hosts). It proves the gate plumbing was invoked
    with the reviewed-manifest arguments; the real verifier logic is exercised
    elsewhere against real reviewed bytes."""
    p = d / "verify-stub.sh"
    body = (
        "#!/bin/sh\n"
        "# Loopback-only verifier substitute used by the synthetic tests.\n"
        'for a in --manifest --output --offline; do\n'
        '    case " $* " in *" $a "*) ;; *) echo "stub: missing $a"; exit 1 ;; esac\n'
        'done\n'
        'echo "stub verify ok"\n'
        'exit %d\n' % (0 if ok else 1)
    )
    with open(p, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(body)
    return p


def run_doc_shell(code, extra_env=None, cwd=None):
    """Run a documented shell snippet LITERALLY via `sh -c` (the exact
    execution model an owner pasting the docs gets), from the repository root
    unless cwd is given, with a fresh private TMPDIR."""
    tmp = Path(tempfile.mkdtemp(prefix="kas-doc-shell."))
    e = os.environ.copy()
    e["TMPDIR"] = _p(tmp)
    e["LC_ALL"] = "C"
    for k, v in (extra_env or {}).items():
        e[k] = _p(v) if isinstance(v, Path) else v
    p = subprocess.run(["sh", "-c", code], env=e, capture_output=True,
                       text=True, timeout=120, cwd=str(cwd or ROOT))
    leftovers = sorted(x.name for x in tmp.iterdir())
    return p.returncode, p.stdout + p.stderr, leftovers


def run_script(env, pat_file):
    tmp = Path(tempfile.mkdtemp(prefix="kas-pub-test-tmp."))
    e = os.environ.copy()
    e.update({
        "PROJECT_ID": "1234",
        # Required on purpose: an empty value would make the script fall back
        # to the real gitlab.com. A missing key must fail loudly here instead.
        "GITLAB_HOST": env["GITLAB_HOST"],
        "BUNDLE_DIR": _p(env["BUNDLE_DIR"]),
        "KAS_GITLAB_PAT_FILE": _p(pat_file),
        "TMPDIR": _p(tmp),
        "LC_ALL": "C",
    })
    for k, v in env.items():
        if k.startswith("KAS_"):
            e[k] = _p(v) if isinstance(v, Path) else v
    p = subprocess.run(["sh", _p(SCRIPT)], env=e, capture_output=True,
                       text=True, timeout=120)
    leftovers = sorted(x.name for x in tmp.iterdir())
    return p.returncode, p.stdout + p.stderr, leftovers


fails = []


def check(name, ok, detail=""):
    print(("[OK] " if ok else "[FAIL] ") + name + ((" : " + detail) if detail else ""))
    if not ok:
        fails.append(name)


def skip(name):
    print("[SKIP] %s (host cannot emulate POSIX 0600; runs in WSL/CI)" % name)
    SKIP.append(name)


def scenario(state, env=None):
    srv = start_server(state)
    work = Path(tempfile.mkdtemp(prefix="kas-pub-test-bundle."))
    make_bundle(work)
    pat = make_pat_file(work)
    # Full flows satisfy the independent trust gate through the loopback-only
    # verifier substitute (real reviewed bytes are exercised in WSL).
    e = {"BUNDLE_DIR": work,
         "KAS_VERIFY_MIRROR_SCRIPT": make_verify_stub(work)}
    e.update(env or {})
    e["GITLAB_HOST"] = "http://127.0.0.1:%d" % srv.server_address[1]
    rc, out, leftovers = run_script(e, pat)
    srv.shutdown()
    return rc, out, leftovers, state


def mode_dependent_suite():
    """Everything that needs a real 0600 PAT file (full publish flow)."""

    # 1. Happy path: all 404 -> publish all 6, anonymous verify passes.
    rc, out, leftovers, st = scenario(new_state())
    check("happy path exit 0", rc == 0, out[-200:])
    check("happy path uploaded all 6 files", st["put_attempts"] == 6)
    check("happy path bytes match bundle for every file",
          all(st["published_bytes"].get(n) == ("PKGMOCK:" + n).encode()
              for n in IPK_NAMES) and
          "SHA256SUMS" in st["published_bytes"])
    check("happy path anonymous verification ran", "ANON-OK SHA256SUMS" in out)
    check("PAT never printed to stdout/stderr", PAT not in out)
    check("temp dir cleaned up on exit", leftovers == [], str(leftovers))

    # 2. Partial publication: one file already 200 -> ABORT, zero PUTs.
    st2 = new_state()
    st2["probe"][IPK_NAMES[2]] = "200"
    rc, out, _, st2 = scenario(st2)
    check("partial publication aborts (exit 2)", rc == 2, out[-200:])
    check("partial publication issues zero PUTs", st2["put_attempts"] == 0)
    check("abort message forbids overwrite and deletion",
          "NEVER overwrite" in out and "delete files" in out)

    # 3-5. Unknown probe state: 500 / 403 / transport error -> STOP, zero PUTs.
    for tag, probe in (("500", "500"), ("403", "403"), ("transport-fail", "fail")):
        s = new_state()
        s["probe"][IPK_NAMES[0]] = probe
        rc, out, _, s = scenario(s)
        check("probe %s -> STOP (exit 1), zero PUTs" % tag,
              rc == 1 and s["put_attempts"] == 0, out[-200:])

    # 6-7. Project gate: rejected PAT and non-public project -> STOP, zero PUTs.
    s = new_state()
    s["proj_status"] = 401
    rc, out, _, s = scenario(s)
    check("project 401 (bad PAT) -> STOP, zero PUTs", rc == 1 and s["put_attempts"] == 0)
    s = new_state()
    s["proj_visibility"] = "private"
    rc, out, _, s = scenario(s)
    check("private project -> STOP, zero PUTs", rc == 1 and s["put_attempts"] == 0)

    # 8. Mid-upload failure then re-run: no blind overwrite.
    s = new_state()
    s["put_fail_on"] = 3
    rc, out, _, s = scenario(s)
    check("mid-upload failure -> STOP (exit 1)", rc == 1 and s["put_attempts"] == 3)
    check("stop message forbids blind retry and deletion",
          "do not retry blindly" in out and "do not delete files" in out)
    rerun = new_state()
    rerun["published_bytes"] = dict(s["published_bytes"])
    rc, out, _, rerun = scenario(rerun)
    check("re-run after partial publish -> ABORT (exit 2), zero PUTs",
          rc == 2 and rerun["put_attempts"] == 0, out[-200:])

    # 13. Anonymous verification mismatch -> STOP even after successful PUTs.
    s = new_state()
    s["anon_override"][IPK_NAMES[4]] = b"WRONG-BYTES"
    rc, out, _, s = scenario(s)
    check("anonymous byte mismatch -> STOP (exit 1)", rc == 1, out[-200:])

    # 14. Anonymous verification 500 -> STOP.
    s = new_state()
    s["anon_override"]["SHA256SUMS"] = "HTTP_500"
    rc, out, _, s = scenario(s)
    check("anonymous verification 500 -> STOP (exit 1)", rc == 1, out[-200:])

    # 18. The documented Step 1 launch (GITLAB-PUBLISH.md) reproduced
    # literally: export + `sh scripts/publish-mihomo-gitlab.sh` from the
    # repository root, against the loopback simulator.
    st = new_state()
    srv = start_server(st)
    work = Path(tempfile.mkdtemp(prefix="kas-doc-export."))
    make_bundle(work)
    pat = make_pat_file(work)
    code_x = (
        'export GITLAB_HOST="%s"\n'
        'export PROJECT_ID="1234"\n'
        'export BUNDLE_DIR="%s"\n'
        'export KAS_GITLAB_PAT_FILE="%s"\n'
        'sh scripts/publish-mihomo-gitlab.sh\n'
    ) % ("http://127.0.0.1:%d" % srv.server_address[1], _p(work), _p(pat))
    rc, out, leftovers = run_doc_shell(
        code_x, extra_env={"KAS_VERIFY_MIRROR_SCRIPT": make_verify_stub(work)})
    srv.shutdown()
    check("documented Step 1 export form -> exit 0, full publish flow",
          rc == 0 and st["put_attempts"] == 6, out[-200:])
    check("documented Step 1 export form verifies anonymously",
          "PUBLISHED AND ANONYMOUSLY VERIFIED" in out)
    check("documented Step 1 export form leaks no PAT", PAT not in out)
    check("documented Step 1 export form cleans temp",
          leftovers == [], str(leftovers))


def universal_suite():
    """Static checks + refusal paths that do not need a valid 0600 PAT."""

    # 0. Static credential-hygiene checks on the tool itself.
    text = SCRIPT.read_text(encoding="utf-8")
    check("no --user on any curl command line", "--user" not in text)
    check("no DELETE fallback (never repair by deleting)",
          "--request DELETE" not in text and "-X DELETE" not in text)
    check("PAT file mode 0600 enforced", '"600"' in text or "0600" in text)
    check("temp curl config removed via trap", "trap 'rm -rf" in text)
    check("lock-manifest gate wired (KAS_LOCK_MANIFEST default)",
          "KAS_LOCK_MANIFEST" in text)
    check("independent reviewed-snapshot verifier referenced",
          "verify_mihomo_mirror.py" in text)
    check("verifier override is loopback-gated",
          "allowed only for loopback test hosts" in text)

    def refusal(tag, env, pat_file, expect=None, host=None):
        st = new_state()
        srv = start_server(st)
        e = {"BUNDLE_DIR": env["BUNDLE_DIR"],
             "GITLAB_HOST": host or "http://127.0.0.1:%d" % srv.server_address[1]}
        e.update(env.get("overrides", {}))
        rc, out, _ = run_script(e, pat_file)
        srv.shutdown()
        ok = rc == 3 and st["put_attempts"] == 0 and not st["requests"]
        msg = ""
        if ok and expect is not None:
            ok = expect in out
            msg = repr(out[-200:])
        check("preflight refusal (%s) exit 3, zero HTTP" % tag, ok, msg)

    stub = None  # scenarios that must pass the lock gate use a fresh stub

    # 9. Missing PAT file (lock gate satisfied by a stub first).
    work = Path(tempfile.mkdtemp(prefix="kas-pub-test-preflight."))
    make_bundle(work)
    refusal("missing PAT file path",
            {"BUNDLE_DIR": work,
             "overrides": {"KAS_VERIFY_MIRROR_SCRIPT": make_verify_stub(work)}},
            work / "does-not-exist.txt", expect="PAT file missing")

    # 10. World-readable PAT file.
    work = Path(tempfile.mkdtemp(prefix="kas-pub-test-preflight."))
    make_bundle(work)
    refusal("world-readable PAT file",
            {"BUNDLE_DIR": work,
             "overrides": {"KAS_VERIFY_MIRROR_SCRIPT": make_verify_stub(work)}},
            make_pat_file(work, good=False), expect="mode 0600")

    # 11. Plain http non-loopback host (refused before the PAT is even read).
    work = Path(tempfile.mkdtemp(prefix="kas-pub-test-preflight."))
    make_bundle(work)
    refusal("plain http non-loopback host",
            {"BUNDLE_DIR": work,
             "overrides": {"GITLAB_HOST": "http://example.com"}},
            make_pat_file(work))

    # 12. Tampered bundle checksums: the SHA256SUMS gate refuses (the lock
    # gate is satisfied by a stub, so this scenario isolates the sums gate).
    work = Path(tempfile.mkdtemp(prefix="kas-pub-test-preflight."))
    make_bundle(work)
    (work / "SHA256SUMS").write_bytes(
        ("deadbeef  " + IPK_NAMES[0] + "\n").encode())
    refusal("tampered bundle checksums",
            {"BUNDLE_DIR": work,
             "overrides": {"KAS_VERIFY_MIRROR_SCRIPT": make_verify_stub(work)}},
            work / "does-not-exist.txt", expect="SHA256SUMS verification failed")

    # 12b. Independent trust gate (issue: bundle AND SHA256SUMS tampered
    # together). The sums are regenerated so the bundle is self-consistent;
    # the REAL reviewed-snapshot verifier must still refuse the publication.
    work = Path(tempfile.mkdtemp(prefix="kas-pub-test-preflight."))
    make_bundle(work)
    (work / IPK_NAMES[1]).write_bytes(b"TAMPERED-BYTES")
    (work / "SHA256SUMS").write_bytes(
        "".join(hashlib.sha256((work / n).read_bytes()).hexdigest() + "  " + n + "\n"
                for n in IPK_NAMES).encode())
    refusal("tampered IPK behind regenerated SHA256SUMS (lock gate)",
            {"BUNDLE_DIR": work}, work / "does-not-exist.txt",
            expect="reviewed lock manifest")

    # 15. Verifier override outside a loopback host is refused (test hook
    # must never be usable against real GitLab).
    work = Path(tempfile.mkdtemp(prefix="kas-pub-test-preflight."))
    make_bundle(work)
    refusal("verifier override outside loopback",
            {"BUNDLE_DIR": work,
             "overrides": {"KAS_VERIFY_MIRROR_SCRIPT": make_verify_stub(work)}},
            work / "does-not-exist.txt",
            host="https://gitlab.example.invalid",
            expect="allowed only for loopback test hosts")

    # 16. Documented Step 1 launch WITHOUT export (the old defective doc
    # form): the plain assignments never reach the child process, the script
    # must refuse at preflight with zero HTTP anywhere.
    work = Path(tempfile.mkdtemp(prefix="kas-doc-noexport."))
    make_bundle(work)
    st = new_state()
    srv = start_server(st)
    code_nx = (
        'PROJECT_ID="1234"\n'
        'BUNDLE_DIR="%s"\n'
        'KAS_GITLAB_PAT_FILE="%s"\n'
        'sh scripts/publish-mihomo-gitlab.sh\n'
    ) % (_p(work), _p(work / "unused-pat.txt"))
    rc, out, _ = run_doc_shell(code_nx)
    srv.shutdown()
    check("documented launch without export -> preflight refusal, zero HTTP",
          rc == 3 and "PROJECT_ID" in out and not st["requests"], out[-160:])

    # 17. Documented Step 2a executed from a REALLY created verify-mihomo
    # directory: the curl loop + sha256sum -c pass against the simulator and
    # the verification command resolves scripts/ and mirrors/ through the
    # absolute REPO_ROOT (the old snippet used relative paths after cd).
    work = Path(tempfile.mkdtemp(prefix="kas-doc-step2a-src."))
    make_bundle(work)
    st = new_state()
    st["published_bytes"] = {n: (work / n).read_bytes() for n in ALL_FILES}
    srv = start_server(st)
    parent = Path(tempfile.mkdtemp(prefix="kas-doc-step2a."))
    code_2a = (
        'set -e\n'
        'GITLAB_HOST="%s"\n'
        'PROJECT_ID="1234"\n'
        'REPO_ROOT="%s"\n'
        'mkdir -p verify-mihomo && cd verify-mihomo\n'
        'for f in %s; do\n'
        '  code=$(curl -sS -L -o "$f" -w \'%%{http_code}\' '
        '"$GITLAB_HOST/api/v4/projects/$PROJECT_ID/packages/generic/'
        'kas-mihomo-mirror/1.19.34-3/$f")\n'
        '  [ "$code" = "200" ] || { echo "FAIL $f: HTTP $code"; exit 1; }\n'
        'done\n'
        'sha256sum -c SHA256SUMS\n'
    ) % ("http://127.0.0.1:%d" % srv.server_address[1], _p(ROOT),
         " ".join(ALL_FILES))
    rc, out, _ = run_doc_shell(code_2a, cwd=parent)
    srv.shutdown()
    check("doc step 2a: six files downloaded, sums verified from verify-mihomo",
          rc == 0 and (parent / "verify-mihomo" / "SHA256SUMS").is_file(),
          out[-200:])
    ver = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "verify_mihomo_mirror.py"),
         "--manifest", str(ROOT / "mirrors" / "mihomo" / "1.19.34-3.lock.json"),
         "--output", str(parent / "verify-mihomo"), "--offline"],
        capture_output=True, text=True, timeout=120,
        cwd=str(parent / "verify-mihomo"))
    blob = ver.stdout + ver.stderr
    # Mock bytes are not the reviewed snapshot, so the verifier must fail on
    # CONTENT (size mismatch) — a path failure (No such file) would mean the
    # documented REPO_ROOT form is broken.
    check("doc step 2a: absolute REPO_ROOT paths resolve inside verify-mihomo",
          ver.returncode != 0 and "size mismatch" in blob
          and "No such file" not in blob and "can't open" not in blob,
          blob[-200:])


def main():
    global MODE_OK
    probe_dir = Path(tempfile.mkdtemp(prefix="kas-pub-mode-probe."))
    probe = probe_dir / "probe"
    subprocess.run(["sh", "-c", 'umask 077; printf x > "$1"; chmod 600 "$1"',
                    "sh", _p(probe)], check=True)
    seen = subprocess.run(["stat", "-c", "%a", _p(probe)],
                          capture_output=True, text=True).stdout.strip()
    MODE_OK = (seen == "600")
    if not MODE_OK:
        print("[NOTE] this host reports '%s' for a 0600-chmodded file (MSYS "
              "mode emulation); mode-dependent scenarios are delegated to "
              "WSL/CI and reported as SKIP" % (seen or "<unset>"))

    universal_suite()
    if MODE_OK:
        mode_dependent_suite()
    else:
        for name in ("happy path (6 checks)", "partial publication abort",
                     "probe 500/403/transport-fail", "project 401/private",
                     "mid-upload failure + re-run", "anonymous mismatch/500",
                     "documented Step 1 export form"):
            skip(name)

    print("ALL PASS" if not fails else "SOME FAIL")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
