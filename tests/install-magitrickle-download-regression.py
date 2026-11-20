#!/usr/bin/env python3
"""Offline regressions for the small-transfer download helper (small-transfer tracking).

FIELD KN-1010: an intermittent resolver (curl 6) failed every silent attempt
of the MagiTrickle add_repo.sh download and the installer aborted without
naming the cause. The helper must: retry a bounded number of times, rescue
with exactly one documented IPv4/X25519 attempt and a bounded wget fallback,
clean partials between attempts, and classify the final failure
(DNS/TLS/HTTP/timeout/truncated/empty) instead of exiting silently. TLS is
never downgraded and no resolver/mirror changes are permitted.

All cases are deterministic and offline: curl/wget/sleep are stubs, plans
drive per-call exit codes and payloads, and the real helper is extracted
from install.sh and run under sh and BusyBox ash.
"""
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "install.sh").read_text(encoding="utf-8")


def extract(name):
    start = SOURCE.index(name + "() {")
    end = SOURCE.index("\n}\n", start) + len("\n}\n")
    return SOURCE[start:end]


HELPER = "\n".join(extract(name) for name in (
    "small_transfer_reason",
    "small_transfer_attempt_feedback",
    "download_small_file_bounded",
))
PAYLOAD = "#!/bin/sh\necho kas-mt-helper\n"
URL = "https://bin.magitrickle.dev/packages/add_repo.sh"

HARNESS = r"""
LAB="$1"
MODE="$2"
SMALL_TRANSFER_MAX_TIME=20
sleep() { :; }
warn() { printf 'WARN:%s\n' "$1"; }
curl() {
    _curl_policy="$*"
    _dest=
    _prev=
    for _a in "$@"; do
        [ "$_prev" = "-o" ] && _dest="$_a"
        _prev=$_a
    done
    [ -n "$_dest" ] || return 90
    [ ! -e "$_dest" ] || touch "$LAB/stale-destination"
    _n=$(($(cat "$LAB/curlcount" 2>/dev/null || echo 0) + 1))
    printf '%s' "$_n" > "$LAB/curlcount"
    _entry=$(sed -n "${_n}p" "$LAB/curlplan")
    [ -n "$_entry" ] || return 91
    _rc=${_entry%%:*}
    _data=${_entry#*:}
    if [ "$_rc" = redirect ]; then
        case "$_curl_policy" in
            *'--proto-redir =https '*) return 1 ;;
        esac
        _rc=0
    fi
    if [ -n "$_data" ]; then
        printf '%b' "$_data" > "$_dest"
    fi
    return "$_rc"
}
wget() {
    case "$*" in *--version) return 0 ;; esac
    _wget_policy="$*"
    _dest=
    _prev=
    for _a in "$@"; do
        [ "$_prev" = "-qO" ] && _dest="$_a"
        _prev=$_a
    done
    [ -n "$_dest" ] || return 90
    [ ! -e "$_dest" ] || touch "$LAB/stale-destination"
    _n=$(($(cat "$LAB/wgetcount" 2>/dev/null || echo 0) + 1))
    printf '%s' "$_n" > "$LAB/wgetcount"
    _entry=$(sed -n "${_n}p" "$LAB/wgetplan")
    [ -n "$_entry" ] || return 91
    _rc=${_entry%%:*}
    _data=${_entry#*:}
    if [ "$_rc" = redirect ]; then
        case "$_wget_policy" in
            *'--max-redirect=0 '*) return 8 ;;
        esac
        _rc=0
    fi
    if [ -n "$_data" ]; then
        printf '%b' "$_data" > "$_dest"
    fi
    return "$_rc"
}
"""


def write_plan(lab, name, entries):
    # Payloads travel through printf %b escapes so multi-line script payloads
    # stay on one plan line per call.
    encoded = [entry.replace("\n", "\\n") for entry in entries]
    (lab / name).write_text("\n".join(encoded) + "\n", encoding="utf-8")


def run_scenario(name, curl_plan, wget_plan, shell, stale=False):
    """Runs one scenario; returns (proc, dest_content_or_None). Plans: list of
    'rc:payload' entries per call."""
    with tempfile.TemporaryDirectory(prefix="kas-mt-dl-") as temp:
        lab = Path(temp)
        write_plan(lab, "curlplan", curl_plan)
        write_plan(lab, "wgetplan", wget_plan)
        dest = lab / "add_repo.sh"
        if stale:
            dest.write_text("stale-previous-attempt", encoding="utf-8")
        script = "\n".join([
            HARNESS,
            "URL=" + shlex.quote(URL),
            HELPER,
            f'if download_small_file_bounded "$URL" "{dest}"; then',
            '  printf "RESULT=OK\\n"',
            "else",
            '  printf "RESULT=FAIL\\n"',
            "fi",
            '[ ! -e "$LAB/stale-destination" ] || printf "STALE_DESTINATION\\n"',
            'printf "CURLCALLS=%s\\n" "$(cat "$LAB/curlcount" 2>/dev/null || echo 0)"',
            'printf "WGETCALLS=%s\\n" "$(cat "$LAB/wgetcount" 2>/dev/null || echo 0)"',
        ])
        proc = subprocess.run(
            shell + ["-c", script, "mt-dl-test", str(lab), name],
            capture_output=True, text=True, timeout=30,
        )
        content = dest.read_text(encoding="utf-8") if dest.exists() else None
        return proc, content


failures = []


def check(name, condition, detail=""):
    if condition:
        print(f"[OK] {name}")
    else:
        failures.append(f"{name}: {detail}")
        print(f"[FAIL] {name}: {detail}")


def scenario(shell, name, curl_plan, wget_plan, ok, curl_calls, wget_calls,
             expect_reason=None, forbid_reasons=(), stale=False, want_payload=None):
    proc, content = run_scenario(name, curl_plan, wget_plan, shell, stale=stale)
    combined = proc.stdout + proc.stderr
    want = "RESULT=OK" if ok else "RESULT=FAIL"
    check(
        f"{shell[0]}:{name} result",
        proc.returncode == 0 and want in proc.stdout,
        f"rc={proc.returncode} stdout={proc.stdout!r} stderr={proc.stderr[:200]!r}",
    )
    check(
        f"{shell[0]}:{name} bounded calls",
        f"CURLCALLS={curl_calls}" in proc.stdout
        and f"WGETCALLS={wget_calls}" in proc.stdout,
        f"calls={proc.stdout!r}",
    )
    check(
        f"{shell[0]}:{name} clean stage before each transfer",
        "STALE_DESTINATION" not in proc.stdout,
        proc.stdout,
    )
    if expect_reason is not None:
        check(
            f"{shell[0]}:{name} classification",
            expect_reason in combined,
            f"missing {expect_reason!r} in {combined!r}",
        )
    for reason in forbid_reasons:
        check(
            f"{shell[0]}:{name} excludes {reason!r}",
            reason not in combined,
            f"unexpected {reason!r} in {combined!r}",
        )
    if want_payload is None:
        check(
            f"{shell[0]}:{name} no destination residue",
            content is None,
            f"failed download left destination: {content!r}",
        )
    else:
        check(
            f"{shell[0]}:{name} payload committed",
            content == want_payload,
            f"destination content mismatch: {content!r}",
        )
    return proc


def main():
    for shell in (["sh"], ["busybox", "ash"]):
        # Failure -> recovery: two DNS failures then success on attempt 3.
        proc = scenario(
            shell, "dns-recover", ["6:", "6:", f"0:{PAYLOAD}"], [], True, 3, 0,
            want_payload=PAYLOAD,
        )

        # One documented IPv4/X25519 attempt rescues after three DNS failures.
        scenario(
            shell, "ipv4-recovery", ["6:", "6:", "6:", f"0:{PAYLOAD}"], [],
            True, 4, 0, want_payload=PAYLOAD,
        )

        # Exhausted DNS failures: IPv4 attempt + bounded wget fallback, explicit
        # curl 6 classification, no destination residue.
        scenario(
            shell, "dns-exhausted", ["6:"] * 4, ["1:"] * 3, False, 4, 3,
            expect_reason="DNS resolution failed (curl 6",
            forbid_reasons=("TLS",),
        )

        # TLS/certificate failure is named and never suggests --insecure.
        scenario(
            shell, "tls-classified", ["60:"] * 4, ["1:"] * 3, False, 4, 3,
            expect_reason="TLS/certificate error (curl 60",
            forbid_reasons=("--insecure",),
        )
        # HTTP >= 400, timeout, truncation.
        scenario(
            shell, "http-classified", ["22:"] * 4, ["1:"] * 3, False, 4, 3,
            expect_reason="HTTP error >= 400 (curl 22",
        )
        scenario(
            shell, "timeout-classified", ["28:"] * 4, ["1:"] * 3, False, 4, 3,
            expect_reason="timed out (curl 28",
        )
        scenario(
            shell, "truncated-classified", ["18:partial-curl"] * 4, ["1:partial-wget"] * 3, False, 4, 3,
            expect_reason="transfer truncated (curl 18",
        )

        # Simulate an HTTPS response redirecting to an HTTP payload for every
        # curl attempt and every wget attempt.
        scenario(
            shell, "http-redirect-rejected", [f"redirect:{PAYLOAD}"] * 4,
            [f"redirect:{PAYLOAD}"] * 3, False, 4, 3,
        )

        # rc 0 with an empty body is a failure, not success.
        scenario(
            shell, "empty-payload-rejected", ["0:"] * 4, ["1:"] * 3, False, 4, 3,
            expect_reason="empty payload",
        )

        # wget fallback recovery when curl cannot serve the URL at all.
        scenario(
            shell, "wget-recovery", ["127:"] * 4, ["1:", "1:", f"0:{PAYLOAD}"],
            True, 4, 3, want_payload=PAYLOAD,
        )

        # Idempotent repeat: a stale destination from a previous run is
        # replaced by the fresh payload, not merged or left behind.
        proc = scenario(
            shell, "idempotent-repeat", ["6:", f"0:{PAYLOAD}"], [], True, 2, 0,
            want_payload=PAYLOAD, stale=True,
        )

        # Per-attempt feedback is TTY-only: captured (non-TTY) output keeps the
        # quiet-per-attempt contract for attempt lines; the final classification
        # is still visible via warn() on stdout.
        check(
            f"{shell[0]}:quiet per attempt in non-TTY logs",
            "curl attempt 1/3" not in proc.stdout and "curl attempt 1/3" not in proc.stderr,
            f"per-attempt feedback leaked in non-TTY run: {proc.stderr[:200]!r}",
        )

    if failures:
        print(f"\n{len(failures)} FAILED:")
        for item in failures:
            print(f"  - {item}")
        raise SystemExit(1)
    print("\nAll magitrickle download resilience regressions passed")


if __name__ == "__main__":
    main()
