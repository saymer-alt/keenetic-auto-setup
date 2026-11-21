#!/usr/bin/env python3
"""Verify exact upstream saymer-alt/entware-go Mihomo IPKs; never installs anything.

Pinned reviewed-version allowlist: the manifest must match one reviewed
snapshot byte-for-byte in identity (tag, version, asset names, sizes,
digests, packaged init script name). Any other manifest is refused — a
moving `latest` tag cannot introduce unreviewed artifacts.

Reviewed snapshots:
  1.19.34-2  S99mihomo (pre ee4b689 packaging)
  1.19.34-3  S28mihomo (ee4b689 network-service ordering; data-level
             identity enforced below, not just control fields)
"""
import argparse
import hashlib
import io
import json
import sys
import tarfile
import urllib.request
from pathlib import Path

SCHEMA = "kas-mihomo-official-mirror/v1"
DOWNLOAD_PREFIX = "https://github.com/saymer-alt/entware-go/releases/download/latest/"
EXPECTED_BY_VERSION = {
    "1.19.34-2": {
        "packages": [
            {"name": "mihomo_1.19.34-2_aarch64-3.10.ipk", "architecture": "aarch64-3.10",
             "package": "mihomo", "version": "1.19.34-2", "depends": "ca-bundle",
             "size": 13317150,
             "sha256": "ed5385fec56c31cd411780c41c0bd99ca204c068723f4095b568b781718bdcf8"},
            {"name": "mihomo_1.19.34-2_armv7-3.2.ipk", "architecture": "armv7-3.2",
             "package": "mihomo", "version": "1.19.34-2", "depends": "ca-bundle",
             "size": 12884030,
             "sha256": "355ef60f591d49368507b0533640e3fef407959c45da79b30753cc7a39b42abc"},
            {"name": "mihomo_1.19.34-2_mips-3.4.ipk", "architecture": "mips-3.4",
             "package": "mihomo", "version": "1.19.34-2", "depends": "ca-bundle",
             "size": 12672559,
             "sha256": "5aa6a264ba159a99dd4ef60cb7bedead587ad845a457c6c461b5a34542520d18"},
            {"name": "mihomo_1.19.34-2_mipsel-3.4.ipk", "architecture": "mipsel-3.4",
             "package": "mihomo", "version": "1.19.34-2", "depends": "ca-bundle",
             "size": 12892791,
             "sha256": "290c0802e60b12e38eb43f58656de3d8f0de317532a0bb67d2dda30b80fdadf6"},
            {"name": "mihomo_nohf_1.19.34-2_armv7-3.2.ipk", "architecture": "armv7-3.2",
             "package": "mihomo_nohf", "version": "1.19.34-2", "depends": "ca-bundle",
             "size": 12878682,
             "sha256": "a4836021eaa428611b6ef64915eebe354ac222866dc95478385fb96cf2a87f5c"},
        ],
        "init": "S99mihomo",
    },
    "1.19.34-3": {
        "packages": [
            {"name": "mihomo_1.19.34-3_aarch64-3.10.ipk", "architecture": "aarch64-3.10",
             "package": "mihomo", "version": "1.19.34-3", "depends": "ca-bundle",
             "size": 13315678,
             "sha256": "8b4f4b5b4bad42253b3aa886606f82e019412346bec2ac0b796455bcbb973f07"},
            {"name": "mihomo_1.19.34-3_armv7-3.2.ipk", "architecture": "armv7-3.2",
             "package": "mihomo", "version": "1.19.34-3", "depends": "ca-bundle",
             "size": 12883878,
             "sha256": "f93b1937b0f31d95264965941e13e8bce8bb8eabeba787e4bbb70e6c547ec2d9"},
            {"name": "mihomo_1.19.34-3_mips-3.4.ipk", "architecture": "mips-3.4",
             "package": "mihomo", "version": "1.19.34-3", "depends": "ca-bundle",
             "size": 12671314,
             "sha256": "3b06d5414b8b1181dba0b2c94ee201061e61c515dac3135808aeede15599048b"},
            {"name": "mihomo_1.19.34-3_mipsel-3.4.ipk", "architecture": "mipsel-3.4",
             "package": "mihomo", "version": "1.19.34-3", "depends": "ca-bundle",
             "size": 12892993,
             "sha256": "3176e3f402f7f7f10aca3659fb57f0cd53c4d9d2b34d3e270a620c0dfdfc948f"},
            {"name": "mihomo_nohf_1.19.34-3_armv7-3.2.ipk", "architecture": "armv7-3.2",
             "package": "mihomo_nohf", "version": "1.19.34-3", "depends": "ca-bundle",
             "size": 12879049,
             "sha256": "7ae722584f219a2aa008e384be171be9fe04153ef01f8afda83741a9d8d66283"},
        ],
        "init": "S28mihomo",
    },
}


def member(tf, name):
    for item in tf.getmembers():
        if item.name.removeprefix("./") == name and item.isfile():
            return tf.extractfile(item).read()
    return None


def verify_ipk(data, item, expected_init):
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as outer:
        if member(outer, "debian-binary").strip() != b"2.0":
            raise ValueError(f"{item['name']}: unexpected IPK format")
        control_blob = member(outer, "control.tar.gz")
        data_blob = member(outer, "data.tar.gz")
    with tarfile.open(fileobj=io.BytesIO(control_blob), mode="r:gz") as ctrl:
        controls = member(ctrl, "control").decode("utf-8")
    fields = dict(line.split(": ", 1) for line in controls.splitlines() if ": " in line)
    for key in ("Package", "Version", "Architecture", "Depends"):
        expected_value = item["package" if key == "Package" else key.lower()]
        if key == "Depends" and fields.get(key) != expected_value:
            raise ValueError(f"{item['name']}: Depends drifted upstream "
                             f"({fields.get(key)!r}); a new reviewed manifest is required")
        if key != "Depends" and fields.get(key) != expected_value:
            raise ValueError(f"{item['name']}: {key}={fields.get(key)!r} expected "
                             f"{expected_value!r}")
    # Data-level init identity (issue #50): the packaged init script name is
    # part of the reviewed snapshot. Any other mihomo init name (including
    # the pre/post ee4b689 variant) is a drift that requires a new reviewed
    # manifest, never a silent mirror of a different service layout.
    with tarfile.open(fileobj=io.BytesIO(data_blob), mode="r:gz") as dt:
        data_names = {m.name.removeprefix("./") for m in dt.getmembers() if m.isfile()}
    inits = {n.rsplit("/", 1)[-1] for n in data_names
             if n.startswith("opt/etc/init.d/") and "mihomo" in n.rsplit("/", 1)[-1]}
    if inits != {expected_init}:
        raise ValueError(f"{item['name']}: packaged init script(s) {sorted(inits)} "
                         f"!= reviewed {expected_init!r}; a new reviewed manifest "
                         f"is required")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--offline", action="store_true",
                        help="recheck previously staged files, without network access")
    args = parser.parse_args()
    lock = json.loads(args.manifest.read_text(encoding="utf-8"))
    version = lock.get("package_version")
    if (lock.get("schema") != SCHEMA
            or lock.get("upstream_repository") != "saymer-alt/entware-go"
            or version not in EXPECTED_BY_VERSION):
        raise ValueError("invalid/unreviewed upstream manifest")
    reviewed = EXPECTED_BY_VERSION[version]
    expected = {p["name"]: p for p in reviewed["packages"]}
    actual = {p["name"]: p for p in lock.get("packages", [])}
    if set(expected) != set(actual):
        raise ValueError("manifest asset set does not match the reviewed snapshot")
    for name, item in expected.items():
        got = actual[name]
        for key in ("size", "sha256", "architecture"):
            if got.get(key) != item[key]:
                raise ValueError(f"{name}: {key} drifted from the reviewed snapshot")
    args.output.mkdir(parents=True, exist_ok=True)
    for name, item in expected.items():
        dest = args.output / name
        if args.offline:
            data = dest.read_bytes()
        else:
            req = urllib.request.Request(DOWNLOAD_PREFIX + name,
                                         headers={"User-Agent": "KAS-mihomo-mirror-prep/1"})
            with urllib.request.urlopen(req, timeout=60) as response:
                data = response.read(item["size"] + 1)
        if len(data) != item["size"]:
            raise ValueError(f"{name}: size mismatch")
        sha = hashlib.sha256(data).hexdigest()
        if sha != item["sha256"]:
            raise ValueError(f"{name}: SHA256 mismatch")
        verify_ipk(data, item, reviewed["init"])
        if not args.offline:
            temp = dest.with_name(dest.name + ".part")
            temp.write_bytes(data)
            temp.replace(dest)
        print(f"PASS {name} {sha}", flush=True)
    print("PASS all pinned Mihomo Entware IPK assets (offline package inspection)")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, tarfile.TarError, KeyError, json.JSONDecodeError) as exc:
        sys.exit(f"FAIL: {exc}")
