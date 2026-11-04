#!/usr/bin/env python3
"""Issue #356: static package provenance, NEVER execute/install an Entware IPK.

All network targets are fixed official Entware endpoints. The downloaded package
bytes are validated against HTTPS Packages index metadata when possible.
This is *not* a pinned hash in source and is not evidence of a working opkg upgrade.
"""
import argparse
import hashlib
import io
import json
from pathlib import PurePosixPath
import re
import sys
import tarfile
import urllib.request
from urllib.parse import urlsplit

TARGETS = (
    ("stable-1.37", "https://bin.entware.net/aarch64-k3.10/archive/busybox_1.37.0-6_aarch64-3.10.ipk", "https://bin.entware.net/aarch64-k3.10/Packages", "1.37.0-6"),
    ("test-1.38", "https://test.entware.net/aarch64-k3.10/busybox_1.38.0-3_aarch64-3.10.ipk", "https://test.entware.net/aarch64-k3.10/Packages", "1.38.0-3"),
)
MAX_INDEX = 6_000_000
MAX_IPK = 1_500_000


def sha(b):
    return hashlib.sha256(b).hexdigest()


def limited_fetch(url, limit):
    # Automatic urllib redirects are checked on final destination and may not
    # be used to silently switch to another download origin.
    req = urllib.request.Request(url, headers={"User-Agent": "KAS-356-static-evidence/1"})
    with urllib.request.urlopen(req, timeout=25) as resp:
        final = resp.geturl()
        if urlsplit(final).scheme != "https" or urlsplit(final).hostname != urlsplit(url).hostname:
            raise ValueError("unexpected download redirect/origin")
        data = resp.read(limit + 1)
        if len(data) > limit:
            raise ValueError("response exceeded bounded download budget")
        return data


def parse_index(payload, filename, version):
    records = payload.decode("utf-8", "replace").split("\n\n")
    for stanza in records:
        fields = {}
        for line in stanza.splitlines():
            if line and line[0].isspace():
                continue
            if ": " in line:
                key, value = line.split(": ", 1)
                fields[key.lower()] = value.strip()
        if (fields.get("package") == "busybox" and
                fields.get("version") == version and
                fields.get("filename", "").split("/")[-1] == filename):
            idxsha = fields.get("sha256sum") or fields.get("sha256")
            return fields, idxsha
    return None, None


def ar_members(blob):
    if not blob.startswith(b"!<arch>\n"):
        raise ValueError("not an ar/IPK archive")
    pos = 8
    result = {}
    while pos < len(blob):
        if pos + 60 > len(blob) or blob[pos + 58:pos + 60] != b"`\n":
            raise ValueError("invalid ar header")
        header = blob[pos:pos + 60]
        name = header[:16].decode("ascii", "strict").strip().rstrip("/")
        size = int(header[48:58].decode("ascii").strip())
        start = pos + 60
        end = start + size
        if size < 0 or end > len(blob) or name in result:
            raise ValueError("invalid ar entry")
        result[name] = blob[start:end]
        pos = end + (size % 2)
    return result


def container_members(blob):
    if blob.startswith(b"!<arch>\n"):
        return ar_members(blob), "ar"
    # Some IPK formats are tar-like; read only archive members, not files.
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:*") as tar:
        result = {}
        for member in tar.getmembers():
            if not member.isfile():
                continue
            name = member.name.removeprefix("./")
            if "/" in name or name in result:
                raise ValueError("unexpected outer tar path")
            result[name] = tar.extractfile(member).read()
        return result, "tar"


def inspect_ipk(blob, expected_version):
    members, kind = container_members(blob)
    ctrl = next((v for k, v in members.items() if re.fullmatch(r"control\.tar(?:\.gz|\.xz|\.bz2|\.zst)?", k)), None)
    data = next((v for k, v in members.items() if re.fullmatch(r"data\.tar(?:\.gz|\.xz|\.bz2|\.zst)?", k)), None)
    if ctrl is None or data is None:
        raise ValueError("missing control or data archive")
    found = {}
    with tarfile.open(fileobj=io.BytesIO(ctrl), mode="r:*") as tar:
        for member in tar.getmembers():
            if not member.isfile():
                continue
            path = PurePosixPath(member.name.removeprefix("./"))
            if path.is_absolute() or ".." in path.parts:
                raise ValueError("control archive path traversal")
            if str(path) in ("control", "preinst", "postinst", "prerm", "postrm"):
                found[str(path)] = tar.extractfile(member).read(100_000)
    meta = {}
    for line in found.get("control", b"").decode("utf-8", "replace").splitlines():
        if ": " in line and not line.startswith(" "):
            k, v = line.split(": ", 1)
            meta[k.lower()] = v.strip()
    if meta.get("package") != "busybox" or meta.get("version") != expected_version:
        raise ValueError("package identity/version mismatch")
    if meta.get("architecture") not in ("aarch64-3.10", "aarch64"):
        raise ValueError("package architecture mismatch")
    manifest = []
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as tar:
        for member in tar.getmembers():
            path = PurePosixPath(member.name.removeprefix("./"))
            if path.is_absolute() or ".." in path.parts:
                raise ValueError("data archive path traversal")
            if "busybox_applets.lst.dist" in str(path) and member.isfile():
                manifest = tar.extractfile(member).read(60_000).decode("utf-8", "replace").splitlines()
    scripts = {k: {"sha256": sha(v), "shebang": v.splitlines()[0].decode("utf-8", "replace")[:100] if v else ""}
               for k, v in found.items() if k != "control"}
    return {"container": kind, "control_sha256": sha(found.get("control", b"")),
            "scripts": scripts, "manifest_count": len(manifest),
            "manifest_sha256": sha("\n".join(manifest).encode()) if manifest else None}


def probe():
    report = {"schema": "entware-busybox-ipk-evidence/v1", "scope": "static-package-inspection-only", "packages": []}
    errors = 0
    for label, url, index_url, ver in TARGETS:
        entry = {"label": label, "url": url, "index": index_url, "expected_version": ver}
        try:
            raw = limited_fetch(url, MAX_IPK)
            entry["file_sha256"] = sha(raw)
            entry["size"] = len(raw)
            entry["archive"] = inspect_ipk(raw, ver)
            index = limited_fetch(index_url, MAX_INDEX)
            entry["index_sha256"] = sha(index)
            fields, digest = parse_index(index, url.rsplit("/", 1)[-1], ver)
            entry["indexed_version"] = fields.get("version") if fields else None
            entry["index_match"] = ("SHA256-VERIFIED" if digest and digest.lower() == entry["file_sha256"] else
                                    "SHA256-MISMATCH" if digest else "INDEX-UNAVAILABLE")
            if entry["index_match"] != "SHA256-VERIFIED":
                errors += 1
        except Exception as exc:
            entry["error"] = str(exc)
            entry["index_match"] = "NOT-VERIFIED"
            errors += 1
        report["packages"].append(entry)
    print(json.dumps(report, sort_keys=True, ensure_ascii=False, indent=2))
    if errors:
        print("[BLOCKED] Missing verified source bytes. No install executed.", file=sys.stderr)
        return 2
    print("[PASS] Both package files matched current HTTPS index digests; this is not an immutable pin or opkg upgrade.")
    return 0


def selftest():
    import tarfile
    def tar_bytes(files):
        dest = io.BytesIO()
        with tarfile.open(fileobj=dest, mode="w:gz") as tf:
            for name, value in files.items():
                t = tarfile.TarInfo(name)
                t.size = len(value)
                tf.addfile(t, io.BytesIO(value))
        return dest.getvalue()
    control = b"Package: busybox\nVersion: 1.38.0-3\nArchitecture: aarch64-3.10\n"
    compressed_ctrl = tar_bytes({"./control": control, "./postinst": b"#!/opt/bin/busybox sh\necho hi\n"})
    compressed_data = tar_bytes({"./opt/share/busybox_applets.lst.dist": b"bin/sh\nbin/chmod\n"})
    pieces = {"debian-binary": b"2.0\n", "control.tar.gz": compressed_ctrl, "data.tar.gz": compressed_data}
    blob = b"!<arch>\n"
    for name, payload in pieces.items():
        header = f"{name + '/':<16}{0:<12}{0:<6}{0:<6}{100644:<8}{len(payload):<10}`\n".encode("ascii")
        assert len(header) == 60
        blob += header + payload + (b"\n" if len(payload) % 2 else b"")
    r = inspect_ipk(blob, "1.38.0-3")
    assert r["container"] == "ar" and r["manifest_count"] == 2 and "postinst" in r["scripts"]
    assert parse_index(b"Package: busybox\nVersion: 1.38.0-3\nFilename: busybox_1.38.0-3_aarch64-3.10.ipk\nSHA256sum: " + sha(blob).encode() + b"\n", "busybox_1.38.0-3_aarch64-3.10.ipk", "1.38.0-3")[1] == sha(blob)
    try:
        inspect_ipk(blob, "1.37.0-6")
    except ValueError:
        pass
    else:
        raise AssertionError("version mismatch not rejected")
    print("[PASS] Synthetic IPK archive inspection, checksum metadata and identity rejection; no network/opkg or host /opt access")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--selftest", action="store_true")
    mode.add_argument("--probe", action="store_true")
    args = parser.parse_args()
    sys.exit(selftest() if args.selftest else probe())
