#!/usr/bin/env python3
"""Interactive progress/attempt visibility for installer downloads.

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
ASSET_DOWNLOAD_MAX_TIME=1800
ASSET_DOWNLOAD_LOW_SPEED_LIMIT=1024
ASSET_DOWNLOAD_LOW_SPEED_TIME=120
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

    _speed_key=""
    _seen_limit=""
    _seen_window=""
    _seen_budget=""
    for _a in "$@"; do
        if [ -n "$_speed_key" ]; then
            case "$_speed_key" in
                limit) _seen_limit="$_a" ;;
                window) _seen_window="$_a" ;;
                budget) _seen_budget="$_a" ;;
            esac
            _speed_key=""
            continue
        fi
        case "$_a" in
            --speed-limit) _speed_key=limit ;;
            --speed-time) _speed_key=window ;;
            --max-time) _speed_key=budget ;;
        esac
    done
    [ "$_seen_limit" = "$ASSET_DOWNLOAD_LOW_SPEED_LIMIT" ] &&
    [ "$_seen_window" = "$ASSET_DOWNLOAD_LOW_SPEED_TIME" ] &&
    [ "$_seen_budget" = "$ASSET_DOWNLOAD_MAX_TIME" ] ||
        { printf 'BAD_SPEED_GUARD\n' >> "$LAB/events"; return 93; }
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
# The mock wget must be a REAL executable on PATH, not only a shell function:
# the wall-clock wrapper (timeout applet) can only run binaries, so direct
# calls and wrapped calls must observe identical behavior through one stub.
# LAB and MODE travel through the environment for the same reason.
export LAB
export MODE
export ASSET_DOWNLOAD_LOW_SPEED_TIME
mkdir -p "$LAB/bin"
cat > "$LAB/bin/wget" <<'WSTUB'
#!/bin/sh
_dest=""
_next=0
_quiet=0
for _a in "$@"; do
    if [ "$_next" -eq 1 ]; then _dest="$_a"; _next=0; continue; fi
    case "$_a" in
      -O|-qO) _next=1; [ "$_a" = -qO ] && _quiet=1 ;;
    esac
done
[ -n "$_dest" ] || exit 91
_read_timeout=""
_read_next=0
for _a in "$@"; do
    if [ "$_read_next" -eq 1 ]; then _read_timeout="$_a"; _read_next=0; continue; fi
    [ "$_a" = "-T" ] && _read_next=1
done
[ "$_read_timeout" = "$ASSET_DOWNLOAD_LOW_SPEED_TIME" ] || exit 93
_count=0
[ ! -f "$LAB/wget-count" ] || _count=$(cat "$LAB/wget-count")
_count=$((_count + 1))
printf '%s' "$_count" > "$LAB/wget-count"
printf 'wget:%s:%s\n' "$_count" "$_quiet" >> "$LAB/events"
if [ "$MODE" = wget-retry ] && [ "$_count" -eq 2 ]; then
    [ ! -e "$_dest" ] || { printf 'STALE' >> "$LAB/events"; exit 92; }
    printf '%s' project-ipk > "$_dest"
    exit 0
fi
if [ "$MODE" = trickle ]; then
    printf 'trickle' > "$_dest"
    _i=0
    while [ "$_i" -lt 300 ]; do
        # Real sleep: bytes keep arriving, so the wget -T read timeout never
        # fires and only the wall-clock budget (timeout applet) can end the
        # attempt; the stub dies on TERM exactly like real wget.
        sleep 1
        _i=$((_i + 1))
    done
    exit 28
fi
printf 'partial-data' > "$_dest"
exit 28
WSTUB
chmod +x "$LAB/bin/wget"
PATH="$LAB/bin:$PATH"
export PATH
wget() { "$LAB/bin/wget" "$@"; }
'''


def check(shell, mode, tty, max_time=None):
    with tempfile.TemporaryDirectory(prefix="kas-progress-") as tmp:
        lab = Path(tmp)
        script = HARNESS + "\n" + FUNCTIONS + '\n'
        if max_time is not None:
            script += "ASSET_DOWNLOAD_MAX_TIME=%d\n" % max_time
        script += '''
if download_url_file "$URL" "$LAB/mihomo.ipk"; then
    printf 'RESULT=OK\\n'
else
    printf 'RESULT=FAIL\\n'
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
            if mode == "trickle":
                # Every attempt must die at the wall-clock budget, not by the
                # read timeout the trickle never triggers; three bounded
                # attempts, then cleanup, then FAIL.
                budget = max_time if max_time is not None else 180
                assert "wall-clock budget %d seconds" % budget in stderr, stderr
                assert events == ["curl:1:1", "curl:2:1", "curl:3:1", "curl:4:1",
                                  "wget:1:0", "wget:2:0", "wget:3:0"], events
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
        check(shell, "trickle", interactive, max_time=2)
    print("PASS", shell, "interactive progress and numbered attempts; non-TTY quiet; cleanup and fallback;"
          " trickling wget bounded by the wall-clock budget")
