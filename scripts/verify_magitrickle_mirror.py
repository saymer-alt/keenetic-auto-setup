#!/usr/bin/env python3
"""Verify exact upstream MagiTrickle IPKs before mirroring; never executes package hooks."""
import argparse
import hashlib
import io
import json
import re
import sys
import tarfile
import time
import urllib.request
from pathlib import Path


def member(archive, name):
    matches = [item for item in archive.getmembers()
               if item.name.removeprefix("./") == name and item.isfile()]
    if len(matches) != 1:
        raise ValueError(f"missing or duplicate archive member: {name}")
    return archive.extractfile(matches[0]).read()


def verify_ipk(data, architecture, version):
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as outer:
        if member(outer, "debian-binary").strip() != b"2.0":
            raise ValueError("unexpected IPK format")
        control_blob = member(outer, "control.tar.gz")
        member(outer, "data.tar.gz")  # present; do not extract/install/execute
    with tarfile.open(fileobj=io.BytesIO(control_blob), mode="r:gz") as control_tar:
        controls = member(control_tar, "control").decode("utf-8")
        postinst = member(control_tar, "postinst").decode("utf-8")
        script_names = {x.name.removeprefix("./") for x in control_tar.getmembers()}
        if "postinst-pkg" in script_names or "prerm-pkg" in script_names:
            raise ValueError("unexpected split maintainer script - inspect upstream")
    fields = dict(line.split(": ", 1) for line in controls.splitlines() if ": " in line)
    expected = {"Package": "magitrickle", "Version": version, "Architecture": architecture}
    for key, value in expected.items():
        if fields.get(key) != value:
            raise ValueError(f"IPK {key}: got {fields.get(key)!r}, expected {value!r}")
    if not postinst.startswith("#!/bin/sh\n") or "/opt/etc/init.d/S99magitrickle restart" not in postinst:
        raise ValueError("unexpected postinst: must manually review upstream IPK")
    if "/opt/lib/functions.sh" in postinst:
        raise ValueError("postinst relies on a nonstandard Entware helper")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--offline", action="store_true",
                        help="recheck previously staged files, without network access")
    args = parser.parse_args()
    lock = json.loads(args.manifest.read_text(encoding="utf-8"))
    if (lock.get("schema") != "kas-magitrickle-official-mirror/v1"
            or lock.get("upstream_repository") != "MagiTrickle/MagiTrickle"
            or lock.get("upstream_release_tag") != "0.8.2-rev2"
            or lock.get("package_version") != "0.8.2-2"
            or lock.get("source_commit") != "9337c101ca2245886f9dfff1d2660f6abae3013a"
            or len(lock.get("packages", [])) != 3):
        raise ValueError("invalid/unreviewed upstream manifest")
    args.output.mkdir(parents=True, exist_ok=True)
    seen = set()
    for item in lock["packages"]:
        arch, name = item["architecture"], item["name"]
        if arch not in {"aarch64-3.10_kn", "mips-3.4_kn", "mipsel-3.4_kn"} or name != f"magitrickle_0.8.2-2_entware_{arch}.ipk":
            raise ValueError("invalid filename or architecture")
        if name in seen:
            raise ValueError("duplicate package")
        seen.add(name)
        dest = args.output / name
        if args.offline:
            data = dest.read_bytes()
        else:
            url = ("https://github.com/MagiTrickle/MagiTrickle/releases/download/"
                   f"0.8.2-rev2/{name}")
            for attempt in range(1, 4):
                try:
                    print(f"Downloading {name}: attempt {attempt}/3", flush=True)
                    req = urllib.request.Request(url, headers={"User-Agent": "KAS-verified-MT-IPK-mirror/1"})
                    with urllib.request.urlopen(req, timeout=35) as response:
                        data = response.read(item["size"] + 1)
                    break
                except Exception as exc:
                    print(f"Download error: {type(exc).__name__}", file=sys.stderr, flush=True)
                    if attempt == 3:
                        raise
                    time.sleep(attempt)
        if len(data) != item["size"]:
            raise ValueError(f"{name}: size mismatch")
        sha = hashlib.sha256(data).hexdigest()
        if sha != item["sha256"]:
            raise ValueError(f"{name}: SHA256 mismatch")
        verify_ipk(data, arch, lock["package_version"])
        if not args.offline:
            temp = dest.with_name(dest.name + ".part")
            temp.write_bytes(data)
            temp.replace(dest)
        print(f"PASS {name} {sha}", flush=True)
    print("PASS all three Keenetic _kn MagiTrickle IPK assets (offline package inspection)")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, tarfile.TarError, KeyError) as exc:
        sys.exit(f"FAIL: {exc}")
