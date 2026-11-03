#!/usr/bin/env python3
"""Offline publication contract: real IPK fixtures, mocked GitHub/Pages writes.

The actual publisher engine runs in-process with injected transport boundaries.
No GitHub Release, tag, Pages endpoint or router is contacted or modified.
"""
import argparse
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace

import yaml

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
from _publication_testkit import build_ipk

SCRIPT = ROOT / "scripts/kas_web_beta_publisher.py"
spec = importlib.util.spec_from_file_location("kas_web_beta_publisher", SCRIPT)
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)
SHA = "b" * 40
RUN = "424242"
VERSION = "0.1.0~beta.5-1"
PREVIOUS = "0.1.0~beta.4-1"
TAG = "v0.1.0-beta.5"
OLD_TAG = "v0.1.0-beta.4"
PREFIX = "kas-web-beta5"
ARCHES = publisher.ARCHES


def args(**overrides):
    data = dict(version=VERSION, previous_version=PREVIOUS, tag=TAG,
                previous_tag=OLD_TAG, source_sha=SHA, verified_run=RUN,
                artifact_prefix=PREFIX)
    data.update(overrides)
    return SimpleNamespace(**data)


def opkg_comparator(left, right):
    """Model version ordering only; real opkg binary runs in the workflow."""
    def version(s):
        if s == "0.1.0-1":
            return (2, 0)
        m = re.fullmatch(r"0\.1\.0~beta\.([0-9]+)-1", s)
        return (1, int(m[1])) if m else (0, 0)
    return version(left) > version(right)


def manifest_for(arch, tag, ipk):
    proc = subprocess.run([sys.executable, str(ROOT / "web/control-center/packaging/update-manifest.py"),
                           "--channel", "experimental", "--tag", tag, str(ipk)],
                          check=True, capture_output=True)
    return proc.stdout


def artifacts_at(root):
    out = {}
    for arch in ARCHES:
        folder = root / ("%s-%s-%s" % (PREFIX, arch, SHA))
        folder.mkdir(parents=True)
        filename = "kas-control-center_%s_%s.ipk" % (VERSION, arch)
        raw = build_ipk(arch, VERSION, SHA)
        (folder / filename).write_bytes(raw)
        (folder / "SHA256SUMS").write_text("%s  ./%s\n" % (hashlib.sha256(raw).hexdigest(), filename))
        (folder / "manifest-canonical.json").write_bytes(manifest_for(arch, TAG, folder / filename))
        (folder / "manifest-alias.json").write_bytes(
            manifest_for(arch, "kas-web-ipk-" + SHA[:7], folder / filename))
        out[folder.name] = folder
    return out


class FakePages:
    def __init__(self):
        self.data = {
            "channels.json": json.dumps({
                "schema": 1, "channels": {
                    "experimental": {"published": True, "tag": OLD_TAG},
                    "stable": {"published": False, "tag": ""}}}).encode(),
            "experimental/panel-update.json": json.dumps({
                "schema": 1, "channel": "experimental", "tag": OLD_TAG,
                "packages": [{"name": "old-package"}]}).encode(),
        }
        self.reads = 0
        self.change_on_read = None

    def fetch(self, suffix):
        self.reads += 1
        if self.reads == self.change_on_read:
            self.data["channels.json"] = b'{"schema":1,"channels":{"experimental":{"published":true,"tag":"another"}}}'
        return self.data[suffix]


class FakeGithub:
    def __init__(self, store):
        self.store = store
        self.prior = {"tag_name": OLD_TAG, "prerelease": True, "draft": False,
                      "target_commitish": "a" * 40, "assets": []}
        self.release_obj = None
        self.remote_bytes = {}
        self.latest = {"tag_name": "v1.8.5", "id": 999}
        self.record = {"head_sha": SHA, "status": "completed", "conclusion": "success",
                       "event": "workflow_dispatch", "head_branch": "main",
                       "path": ".github/workflows/web-beta3-build.yml@main"}
        self.operations = []
        self.fail_upload_at = None
        self.hijack_latest_after_publish = False
        self.hijack_pages_after_publish = None
        self.tamper_download = None
        self.alias = False

    def api(self, path, missing_ok=False):
        if "/commits/" in path:
            return {"sha": path.rsplit("/", 1)[-1]}
        if "/actions/runs/" in path:
            return self.record
        if "/releases/latest" in path:
            return self.latest
        if "/git/ref/tags/" in path:
            tag = path.rsplit("/", 1)[-1]
            if tag == OLD_TAG:
                return {"object": {"sha": "a" * 40, "type": "commit"}}
            if self.release_obj and tag == TAG:
                return {"object": {"sha": self.release_obj["target_commitish"], "type": "commit"}}
            return None
        raise AssertionError("unexpected API query: " + path)

    def list_tags(self):
        tags = {"v1.8.5", OLD_TAG}
        if self.release_obj is not None:
            tags.add(TAG)
        if self.alias:
            tags.add("kas-web-ipk-" + SHA[:7])
        return tags

    def release(self, tag):
        return copy.deepcopy(self.prior if tag == OLD_TAG else self.release_obj if tag == TAG else None)

    def download_artifact(self, run_id, name, directory):
        assert run_id == RUN
        assert name in self.store, "requested unverified artifact name"
        shutil.copytree(self.store[name], directory, dirs_exist_ok=True)

    def create_draft(self, tag, sha, notes):
        assert tag == TAG and sha == SHA
        assert "Verified candidate run: " + RUN in notes.read_text()
        assert "Four verified architectures" in notes.read_text()
        assert self.release_obj is None
        self.operations.append("create-draft")
        self.release_obj = {"tag_name": tag, "target_commitish": sha, "prerelease": True,
                            "draft": True, "assets": []}

    def upload(self, tag, path):
        assert self.release_obj["draft"] and tag == TAG
        self.operations.append("upload:" + path.name)
        n = sum(action.startswith("upload:") for action in self.operations)
        if self.fail_upload_at == n:
            raise publisher.Refusal("injected upload failure")
        name = path.name
        assert name not in self.remote_bytes, "clobber detected"
        raw = path.read_bytes()
        self.remote_bytes[name] = raw
        self.release_obj["assets"].append({
            "name": name, "size": len(raw), "state": "uploaded",
            "digest": "sha256:" + hashlib.sha256(raw).hexdigest(),
            "browser_download_url": "https://github.com/%s/releases/download/untagged-123/%s"
                                    % (publisher.EXPECTED_REPO, name)})

    def publish(self, tag):
        assert tag == TAG and self.release_obj["draft"]
        self.operations.append("publish")
        self.release_obj["draft"] = False
        for asset in self.release_obj["assets"]:
            asset["browser_download_url"] = (
                "https://github.com/%s/releases/download/%s/%s"
                % (publisher.EXPECTED_REPO, TAG, asset["name"]))
        if self.hijack_latest_after_publish:
            self.latest = {"tag_name": TAG, "id": 1000}
        if self.hijack_pages_after_publish is not None:
            self.hijack_pages_after_publish.data["experimental/panel-update.json"] = b"tampered"

    def download_release_asset(self, tag, name, directory):
        assert tag == TAG and not self.release_obj["draft"]
        raw = self.remote_bytes[name]
        if name == self.tamper_download:
            raw += b"evil"
        (directory / name).write_bytes(raw)


def scenario(label, mutate=None, expect_ok=True, postcheck=None):
    with tempfile.TemporaryDirectory(prefix="kas-web-release-offline-") as td:
        fixtures = Path(td) / "fixtures"
        fixtures.mkdir()
        store = artifacts_at(fixtures)
        gh = FakeGithub(store)
        pages = FakePages()
        a = args()
        if mutate:
            mutate(a, gh, pages, store)
        engine = publisher.Publisher(a, gh, pages, root=ROOT, compare=opkg_comparator)
        error = None
        try:
            engine.execute()
        except (publisher.Refusal, ValueError, KeyError, AssertionError, OSError) as exc:
            error = exc
        if bool(error is None) != expect_ok:
            raise AssertionError("%s: expected success=%s, got %s" % (label, expect_ok, error))
        if postcheck:
            postcheck(gh, pages, store)
        print("PASS", label)


def expect_full(gh, pages, _):
    assert gh.release_obj is not None and gh.release_obj["draft"] is False
    assert len(gh.release_obj["assets"]) == 5
    assert gh.operations.count("create-draft") == 1
    assert gh.operations.count("publish") == 1
    assert gh.latest["tag_name"] == "v1.8.5"
    assert json.loads(pages.data["experimental/panel-update.json"])["tag"] == OLD_TAG
    assert not any("alias" in x for x in gh.operations)


def invalid(label, field, value):
    def edit(a, *_):
        setattr(a, field, value)
    scenario(label, edit, False, lambda gh, *_: no_release(gh))


def no_release(gh):
    assert gh.release_obj is None


def test_workflow():
    workflow = yaml.safe_load((ROOT / ".github/workflows/publish-web-beta-release.yml").read_text())
    trigger = workflow.get("on", workflow.get(True))
    assert set(trigger) == {"workflow_dispatch"}, "must remain dispatch-only"
    required = trigger["workflow_dispatch"]["inputs"]
    assert set(required) == {"version", "previous_version", "tag", "previous_tag",
                             "verified_run", "source_sha", "artifact_prefix"}
    assert all(x["required"] is True for x in required.values())
    assert workflow["permissions"] == {"contents": "read"}
    job = workflow["jobs"]["publish"]
    assert job["permissions"] == {"actions": "read", "contents": "write"}
    assert "refs/heads/main" in job["if"] and "saymer-alt/keenetic-auto-setup" in job["if"]
    assert job["steps"][-1]["env"]["SOURCE_SHA"] == "$" + "{{ inputs.source_sha }}"
    assert not any("release edit --latest" in str(s) or "deploy-pages" in str(s)
                   for s in job["steps"])
    for step in job["steps"]:
        if "run" in step:
            p = subprocess.run(["bash", "-n"], input=step["run"].encode(), capture_output=True)
            assert p.returncode == 0, p.stderr.decode()
    assert "cancel-in-progress" in workflow["concurrency"]
    print("PASS workflow contract (dispatch-only, main guard, permissions, shell syntax)")


def test_resume():
    with tempfile.TemporaryDirectory(prefix="kas-web-resume-") as td:
        fixtures = Path(td) / "fixtures"
        fixtures.mkdir()
        gh = FakeGithub(artifacts_at(fixtures))
        pages = FakePages()
        def engine():
            return publisher.Publisher(args(), gh, pages, root=ROOT, compare=opkg_comparator)
        gh.fail_upload_at = 2
        try:
            engine().execute()
            raise AssertionError("partial upload unexpectedly succeeded")
        except publisher.Refusal:
            pass
        assert gh.release_obj["draft"] and len(gh.release_obj["assets"]) == 1
        gh.fail_upload_at = None
        engine().execute()
        assert not gh.release_obj["draft"] and len(gh.release_obj["assets"]) == 5
        assert gh.operations.count("create-draft") == 1
        assert gh.operations.count("publish") == 1
        # Once published, retries must be verified but cause NO mutation.
        original = list(gh.operations)
        engine().execute()
        assert gh.operations == original
        print("PASS draft partial failure → safe resume → published idempotency")


def test_tamper():
    with tempfile.TemporaryDirectory(prefix="kas-web-tamper-") as td:
        folder = Path(td) / "artifacts"
        folder.mkdir()
        gh = FakeGithub(artifacts_at(folder))
        pages = FakePages()
        def engine():
            return publisher.Publisher(args(), gh, pages, root=ROOT, compare=opkg_comparator)
        engine().execute()
        name = next(iter(gh.remote_bytes))
        old = gh.release_obj["assets"][0]["digest"]
        gh.release_obj["assets"][0]["digest"] = "sha256:" + "0" * 64
        try:
            engine().execute()
            raise AssertionError("tampered published asset accepted")
        except publisher.Refusal:
            pass
        assert gh.release_obj["assets"][0]["digest"] != old
        # A metadata-preserving byte substitution must also be detected
        # by the public download verification.
        gh.release_obj["assets"][0]["digest"] = old
        gh.tamper_download = name
        try:
            engine().execute()
            raise AssertionError("tampered public download accepted")
        except publisher.Refusal:
            pass
        print("PASS published asset metadata + downloaded byte tamper rejection")


def main():
    test_workflow()
    scenario("happy Release-only, full byte verification", postcheck=expect_full)
    for label, field, value in (
        ("refuse version typo", "version", "v0.1.0-beta.5"),
        ("refuse equal version", "previous_version", VERSION),
        ("refuse reversed version", "previous_version", "0.1.0~beta.6-1"),
        ("refuse tag mismatch", "tag", "v0.1.0-beta.6"),
        ("refuse previous tag mismatch", "previous_tag", "v0.1.0-beta.3"),
        ("refuse mismatched artifact prefix", "artifact_prefix", "kas-web-beta4"),
        ("refuse zero source SHA", "source_sha", "0" * 40),
        ("refuse short SHA", "source_sha", "abcdef"),
        ("refuse invalid run ID", "verified_run", "0"),
    ):
        invalid(label, field, value)

    def bad_run(a, gh, *_):
        gh.record["conclusion"] = "failure"
    scenario("failed candidate run", bad_run, False, lambda gh, *_: no_release(gh))
    def push_run(a, gh, *_):
        gh.record["event"] = "push"
    scenario("push-run cannot replace pinned dispatch", push_run, False,
             lambda gh, *_: no_release(gh))
    def old_source(a, gh, *_):
        gh.record["head_sha"] = "a" * 40
    scenario("run source SHA mismatch", old_source, False, lambda gh, *_: no_release(gh))
    def missing_previous(a, gh, *_):
        gh.prior["draft"] = True
    scenario("previous Release still draft", missing_previous, False,
             lambda gh, *_: no_release(gh))
    def alias(a, gh, *_):
        gh.alias = True
    scenario("forbid alias release", alias, False, lambda gh, *_: no_release(gh))

    def corrupt_ipk(a, gh, pages, store):
        path = store["%s-%s-%s" % (PREFIX, ARCHES[0], SHA)]
        target = next(path.glob("*.ipk"))
        target.write_bytes(target.read_bytes() + b"corrupted")
    scenario("corrupt IPK rejected before draft", corrupt_ipk, False,
             lambda gh, *_: no_release(gh))

    def stale_manifest(a, gh, pages, store):
        path = store["%s-%s-%s" % (PREFIX, ARCHES[0], SHA)]
        m = path / "manifest-canonical.json"
        parsed = json.loads(m.read_text())
        parsed["packages"][0]["source_sha"] = "d" * 40
        m.write_text(json.dumps(parsed))
    scenario("stale manifest rejected", stale_manifest, False,
             lambda gh, *_: no_release(gh))

    def pages_change(a, gh, pages, store):
        pages.change_on_read = 3
    scenario("changed live Pages before draft refused", pages_change, False,
             lambda gh, *_: no_release(gh))

    def hijack_latest(a, gh, pages, store):
        gh.hijack_latest_after_publish = True
    scenario("Latest hijack detected, never overwritten", hijack_latest, False)

    def tamper_pages(a, gh, pages, store):
        gh.hijack_pages_after_publish = pages
    scenario("post-publication Pages mutation detected", tamper_pages, False)

    test_resume()
    test_tamper()
    print("PASS all web beta publisher offline scenarios")


if __name__ == "__main__":
    main()
