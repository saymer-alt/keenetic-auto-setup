#!/usr/bin/env python3
"""Offline installer Mihomo GitHub Release Asset API fallback regression (#478).

Tests the real POSIX helper from install.sh under sh and BusyBox ash with mocked
curl. Never contacts GitHub, runs opkg, or changes a router.
"""
import hashlib
import json
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "install.sh").read_text(encoding="utf-8")
def extract(name):
    start = SOURCE.index(name + "() {")
    end = SOURCE.index("\n}\n", start) + len("\n}")
    return SOURCE[start:end]


HELPER = "\n".join(extract(name) for name in (
    "installer_asset_feedback",
    "installer_asset_api_curl",
    "download_mihomo_release_asset_api",
))
SELECTED = (
    "https://github.com/saymer-alt/entware-go/releases/download/latest/"
    "mihomo_1.19.33-2_aarch64-3.10.ipk"
)
DATA = "project-mihomo-ipk-payload"
SHA = hashlib.sha256(DATA.encode()).hexdigest()


def metadata(*, asset_id=321, size=None, digest="auto", url=SELECTED, duplicate=False, tag="latest"):
    asset = {
        "id": asset_id,
        "state": "uploaded",
        "name": SELECTED.rsplit("/", 1)[-1],
        "browser_download_url": url,
        "size": len(DATA) if size is None else size,
        "digest": "sha256:" + SHA if digest == "auto" else digest,
    }
    return {"tag_name": tag, "assets": [asset, dict(asset)] if duplicate else [asset]}


HARNESS = r"""
LAB="$1"
MODE="$2"
REPO_OWNER=saymer-alt
REPO_NAME=entware-go
ASSET_DOWNLOAD_MAX_TIME=180
curl() {
    _seen_api=0
    _seen_accept=0
    _seen_out=0
    _dest=""
    for _arg in "$@"; do
        if [ "$_seen_out" -eq 1 ]; then
            _dest="$_arg"
            _seen_out=0
            continue
        fi
        case "$_arg" in
            -o) _seen_out=1 ;;
            https://api.github.com/repos/saymer-alt/entware-go/releases/assets/321) _seen_api=1 ;;
            "Accept: application/octet-stream") _seen_accept=1 ;;
        esac
    done
    [ "$_seen_api" -eq 1 ] && [ "$_seen_accept" -eq 1 ] && [ -n "$_dest" ] || return 91
    _count=0
    [ ! -e "$LAB/calls" ] || _count=$(cat "$LAB/calls")
    _count=$((_count + 1))
    printf '%s' "$_count" > "$LAB/calls"
    if [ "$MODE" = "partial" ] && [ "$_count" -eq 1 ]; then
        printf 'PARTIAL' > "$_dest"
        return 28
    fi
    if [ "$MODE" = "partial" ] && [ -e "$_dest" ]; then
        printf 'stale candidate present' > "$LAB/stale"
        return 92
    fi
    if [ "$MODE" = "network" ]; then
        printf 'PARTIAL' > "$_dest"
        return 28
    fi
    if [ "$MODE" = "json" ]; then
        printf '{"asset":321}' > "$_dest"
        return 0
    fi
    if [ "$MODE" = "corrupt" ]; then
        printf '%s' "$BAD_DATA" > "$_dest"
        return 0
    fi
    printf '%s' "$GOOD_DATA" > "$_dest"
    return 0
}
"""


def exercise(shell, mode, source, success, count, name):
    with tempfile.TemporaryDirectory(prefix="kas-asset-api-") as temp:
        lab = Path(temp)
        script = "\n".join([
            HARNESS,
            "GOOD_DATA=" + shlex.quote(DATA),
            "BAD_DATA=" + shlex.quote("X" * len(DATA)),
            "ASSETS_JSON=" + shlex.quote(json.dumps(source)),
            "SELECTED=" + shlex.quote(SELECTED),
            HELPER,
            'if download_mihomo_release_asset_api "$SELECTED" "$LAB/mihomo.ipk"; then',
            '  printf "RESULT=OK\n"',
            'else',
            '  printf "RESULT=FAIL\n"',
            'fi',
        ])
        p = subprocess.run(shell + ["-c", script, "asset-test", temp, mode],
                           capture_output=True, text=True, timeout=10)
        calls = int((lab / "calls").read_text()) if (lab / "calls").exists() else 0
        result = "RESULT=OK" if success else "RESULT=FAIL"
        assert p.returncode == 0 and result in p.stdout, (name, shell, p.returncode, p.stdout, p.stderr)
        assert calls == count, (name, shell, calls, count)
        assert not (lab / "stale").exists(), (name, shell, "partial was not removed")
        candidate = lab / "mihomo.ipk"
        if success:
            assert candidate.read_text() == DATA, (name, shell, "incorrect candidate")
        else:
            assert not candidate.exists(), (name, shell, "failed candidate retained")


def integration(shell, mode, want):
    """Execute the actual initial-install branch with stubbed I/O and opkg."""
    a = SOURCE.index("    # GitHub Releases are the primary package source;")
    b = SOURCE.index("    MIHOMO_BIN=$(resolve_installed_mihomo", a)
    real_install_path = SOURCE[a:b]
    stub = r"""
LAB="$1"; MODE="$2"; TMP_DIR="$LAB"
DOWNLOAD_URL="https://github.com/saymer-alt/entware-go/releases/download/latest/mihomo_1.19.33-2_aarch64-3.10.ipk"
IPK_SUFFIX=aarch64-3.10
REPO_OWNER=saymer-alt
REPO_NAME=entware-go
log() { :; }
warn() { :; }
err() { printf 'ERROR\n'; exit 89; }
download_url_file() {
  [ "$MODE" = direct ] || return 1
  printf '%s' project-ipk > "$2"
}
download_mihomo_release_asset_api() {
  printf 'called\n' >> "$LAB/api"
  [ "$MODE" = api ] || return 1
  printf '%s' project-ipk > "$2"
}
opkg() {
  [ "$1" = install ] || return 90
  printf '%s\n' "$2" >> "$LAB/opkg"
}
"""
    with tempfile.TemporaryDirectory(prefix="kas-ipk-order-") as temp:
        script = stub + "\n" + real_install_path
        p = subprocess.run(shell + ["-c", script, "install-mock", temp, mode],
                           capture_output=True, text=True, timeout=10)
        installed = (Path(temp) / "opkg").read_text().splitlines()
        got = ["feed" if x == "mihomo" else "project" for x in installed]
        assert p.returncode == 0 and got == want, (mode, shell, got, p.stdout, p.stderr)
        if mode == "direct":
            assert not (Path(temp) / "api").exists(), "API invoked after a successful direct download"
        elif mode in ("api", "feed"):
            assert (Path(temp) / "api").read_text().splitlines() == ["called"]


for shell in (["sh"], ["busybox", "ash"]):
    scenarios = [
        ("normal", "good", metadata(), True, 1),
        ("IPv4 retry cleans partial", "partial", metadata(), True, 2),
        ("both transports fail/cleanup", "network", metadata(), False, 2),
        ("JSON HTTP 200 rejected", "json", metadata(), False, 1),
        ("same size, wrong digest", "corrupt", metadata(), False, 1),
        ("wrong expected length", "good", metadata(size=len(DATA) + 1), False, 1),
        ("missing ID", "good", metadata(asset_id=None), False, 0),
        ("negative ID", "good", metadata(asset_id=-1), False, 0),
        ("duplicate match", "good", metadata(duplicate=True), False, 0),
        ("wrong browser URL", "good", metadata(url=SELECTED.replace("github.com", "evil.invalid")), False, 0),
        ("wrong release tag", "good", metadata(tag="foreign"), False, 0),
        ("malformed digest", "good", metadata(digest="sha256:not-hex"), False, 0),
        ("null digest still size-checked", "good", metadata(digest=None), True, 1),
    ]
    for name, mode, source, ok, count in scenarios:
        exercise(shell, mode, source, ok, count, name)
    for mode, want in (("direct", ["project"]), ("api", ["project"]), ("feed", ["feed"])):
        integration(shell, mode, want)
    print("PASS", shell, "asset API exact ID, bounded fallback, bytes/hash, cleanup, initial-install order")
