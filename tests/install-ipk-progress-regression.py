#!/usr/bin/env python3
"""#478: interactive progress/attempt visibility for installer downloads.

Runs the exact shell functions extracted from install.sh with mocked transports,
including a pseudo-TTY. Does not contact networks or change any router files.
"""
import os
from pathlib import Path
import pty
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "install.sh").read_text(encoding="utf-8")


def func(name):
    start = SOURCE.index(name + "() {")
    stop = SOURCE.index("\n}\n", start) + len("\n}")
    return SOURCE[start:stop]


FUNCTIONS = "\n".join(func(n) for n in (
    "retry_silent", "installer_asset_feedback", "installer_asset_retry_curl",
    "installer_asset_retry_wget", "download_url_file",
))

HARNESS = r'''
LAB="$1"
MODE="$2"
ASSET_DOWNLOAD_MAX_TIME=180
URL="https://github.com/saymer-alt/entware-go/releases/download/latest/mihomo_1.19.33-2_aarch64-3.10.ipk"
warn() { printf '[WARN] %s\n' "$1"; }
sleep() { :; }
curl() {
    _dest=""
    _next=0
    _progress=0
    _compat=0
    for _a in "$@"; do
        if [ "$_next" -eq 1 ]; then _dest="$_a"; _next=0; continue; fi
        case "$_a" in
          -o) _next=1 ;;
          --progress-bar) _progress=1 ;;
          --curves) _compat=1 ;;
        esac
    done
    [ -n "$_dest" ] || return 91
    _count=0
    [ ! -f "$LAB/curl-count" ] || _count=$(cat "$LAB/curl-count")
    _count=$((_count + 1))
    printf '%s' "$_count" > "$LAB/curl-count"
    printf 'curl:%s:%s\n' "$_count" "$_progress" >> "$LAB/events"
    if [ "$_progress" -eq 1 ]; then printf '25%% progress\n' >&2; fi
    # One interrupted transfer, then success in the first retry. Other modes
    # intentionally exhaust curl attempts and fall through to wget.
    if [ "$MODE" = curl-retry ] && [ "$_count" -eq 2 ]; then
        [ ! -e "$_dest" ] || { printf 'STALE' >> "$LAB/events"; return 92; }
        printf '%s' project-ipk > "$_dest"
        return 0
    fi
    printf 'partial-data' > "$_dest"
    return 28
}
wget() {
    _dest=""
    _next=0
    _quiet=0
    for _a in "$@"; do
        if [ "$_next" -eq 1 ]; then _dest="$_a"; _next=0; continue; fi
        case "$_a" in
          -O|-qO) _next=1; [ "$_a" = -qO ] && _quiet=1 ;;
        esac
    done
    [ -n "$_dest" ] || return 91
    _count=0
    [ ! -f "$LAB/wget-count" ] || _count=$(cat "$LAB/wget-count")
    _count=$((_count + 1))
    printf '%s' "$_count" > "$LAB/wget-count"
    printf 'wget:%s:%s\n' "$_count" "$_quiet" >> "$LAB/events"
    if [ "$MODE" = wget-retry ] && [ "$_count" -eq 2 ]; then
        [ ! -e "$_dest" ] || { printf 'STALE' >> "$LAB/events"; return 92; }
        printf '%s' project-ipk > "$_dest"
        return 0
    fi
    printf 'partial-data' > "$_dest"
    return 28
}
'''


def check(shell, mode, tty):
    with tempfile.TemporaryDirectory(prefix="kas-progress-") as tmp:
        lab = Path(tmp)
        script = HARNESS + "\n" + FUNCTIONS + '\n'
        script += '''
if download_url_file "$URL" "$LAB/mihomo.ipk"; then
    printf 'RESULT=OK\n'
else
    printf 'RESULT=FAIL\n'
fi
'''
        kwargs = dict(input=script, text=True, stdout=subprocess.PIPE, timeout=15)
        if tty:
            master, slave = pty.openpty()
            try:
                kwargs["stderr"] = slave
                p = subprocess.run(shell + ["-s", tmp, mode], **kwargs)
            finally:
                os.close(slave)
            err = bytearray()
            while True:
                try:
                    part = os.read(master, 4096)
                except OSError:
                    break
                if not part:
                    break
                err.extend(part)
            os.close(master)
            stderr = err.decode("utf-8", "replace")
        else:
            p = subprocess.run(shell + ["-s", tmp, mode],
                               input=script, text=True, capture_output=True, timeout=15)
            stderr = p.stderr

        good = mode in ("curl-retry", "wget-retry")
        assert p.returncode == 0, (shell, mode, p.stderr if not tty else stderr)
        assert ("RESULT=OK" in p.stdout) == good, (shell, mode, p.stdout, stderr)
        assert not (lab / "events").read_text().endswith("STALE"), (shell, mode)
        events = (lab / "events").read_text().splitlines()
        assert not any("STALE" in x for x in events), (shell, mode, events)
        dest = lab / "mihomo.ipk"
        if good:
            assert dest.read_text() == "project-ipk"
        else:
            assert not dest.exists(), (shell, mode, "partial retained")
        if tty:
            if mode == "curl-retry":
                assert "curl attempt 1/3" in stderr and "curl attempt 2/3" in stderr
                assert "25% progress" in stderr and events[:2] == ["curl:1:1", "curl:2:1"]
            if mode == "wget-retry":
                assert "wget attempt 1/3" in stderr and "wget attempt 2/3" in stderr
                assert "curl attempt 3/3" in stderr
                assert events[-2:] == ["wget:1:0", "wget:2:0"]
        else:
            assert "attempt 1/3" not in stderr
            if mode == "curl-retry":
                assert events[:2] == ["curl:1:0", "curl:2:0"]
            if mode == "wget-retry":
                assert events[-2:] == ["wget:1:1", "wget:2:1"]


for shell in (["sh"], ["busybox", "ash"]):
    for interactive in (False, True):
        for mode in ("curl-retry", "wget-retry", "all-fail"):
            check(shell, mode, interactive)
    print("PASS", shell, "interactive progress and numbered attempts; non-TTY quiet; cleanup and fallback")
