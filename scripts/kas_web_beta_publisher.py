#!/usr/bin/env python3
"""Release-only KAS WEB beta.N publisher. NEVER installs or changes GitHub Pages.

Runs exclusively from an owner-dispatched GitHub Actions workflow. The verified
candidate artifacts are the only source of IPK bytes. No build, alias release,
channel switch, automatic rollback, or mutable release-asset replacement.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import urllib.request

ARCHES = ("aarch64-3.10", "armv7-3.2", "mipsel-3.4", "mips-3.4")
EXPECTED_REPO = "saymer-alt/keenetic-auto-setup"
PAGES_BASE = "https://saymer-alt.github.io/keenetic-auto-setup"
# Published beta.4 uses the dotted opkg version 0.1.0.beta.4-1.
# A tilde beta.5 would sort OLDER than published beta.4.
VERSION_RE = re.compile(r"0\.1\.0\.beta\.([1-9][0-9]*)-1\Z")
TAG_RE = re.compile(r"v0\.1\.0-beta\.([1-9][0-9]*)\Z")
PREFIX_RE = re.compile(r"kas-web-beta([1-9][0-9]*)\Z")
SHA_RE = re.compile(r"[a-f0-9]{40}\Z")
RUN_RE = re.compile(r"[1-9][0-9]*\Z")
ROOT = Path(__file__).resolve().parents[1]


class Refusal(RuntimeError):
    """Fail closed: the operation needs an operator investigation."""


def require(value, message):
    if not value:
        raise Refusal(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def run_checked(command, **kwargs):
    result = subprocess.run(command, capture_output=True, **kwargs)
    if result.returncode:
        raise Refusal("%s failed (%d): %s" %
                      (command[0], result.returncode,
                       result.stderr.decode("utf-8", "replace")[-700:]))
    return result.stdout


class Github:
    def __init__(self, repo=EXPECTED_REPO):
        require(repo == EXPECTED_REPO, "refusing to publish outside the canonical repository")
        self.repo = repo

    def api(self, path, missing_ok=False):
        completed = subprocess.run(["gh", "api", path], capture_output=True)
        if completed.returncode:
            stderr = completed.stderr.decode("utf-8", "replace")
            if missing_ok and re.search(r"HTTP 404\b", stderr):
                return None
            raise Refusal("GitHub API error at %s: %s" % (path, stderr[-700:]))
        return json.loads(completed.stdout)

    def list_tags(self):
        result = run_checked(["gh", "api", "--paginate", "--jq", ".[].tag_name",
                              "repos/%s/releases?per_page=100" % self.repo])
        return set(result.decode().splitlines())

    def release(self, tag):
        by_tag = self.api("repos/%s/releases/tags/%s" % (self.repo, tag), missing_ok=True)
        if by_tag is not None:
            return by_tag
        # Some GitHub API paths cannot see a newly created draft immediately.
        expr = '.[] | select(.tag_name == "%s") | .id' % tag
        out = run_checked(["gh", "api", "--paginate", "--jq", expr,
                           "repos/%s/releases?per_page=100" % self.repo])
        ids = [line.strip() for line in out.decode().splitlines() if line.strip()]
        require(len(ids) <= 1, "ambiguous draft release lookup")
        return self.api("repos/%s/releases/%s" % (self.repo, ids[0])) if ids else None

    def download_artifact(self, run_id, name, directory):
        run_checked(["gh", "run", "download", run_id, "--repo", self.repo,
                     "--name", name, "--dir", str(directory)])

    def create_draft(self, tag, sha, notes):
        run_checked(["gh", "release", "create", tag, "--repo", self.repo,
                     "--target", sha, "--draft", "--prerelease", "--latest=false",
                     "--title", "KAS Web %s" % tag[1:], "--notes-file", str(notes)])

    def upload(self, tag, path):
        # No --clobber: replacing even one release asset would defeat resume safety.
        run_checked(["gh", "release", "upload", tag, "--repo", self.repo, str(path)])

    def publish(self, tag):
        run_checked(["gh", "release", "edit", tag, "--repo", self.repo, "--draft=false"])

    def download_release_asset(self, tag, name, directory):
        run_checked(["gh", "release", "download", tag, "--repo", self.repo,
                     "--pattern", name, "--dir", str(directory)])


class Pages:
    def fetch(self, suffix):
        url = PAGES_BASE + "/updates/" + suffix
        request = urllib.request.Request(url, headers={"User-Agent": "KAS-web-release-verifier"})
        try:
            with urllib.request.urlopen(request, timeout=20) as reply:
                require(reply.status == 200, "Pages HTTP status is not 200")
                body = reply.read(1024 * 1024 + 1)
        except Exception as exc:
            raise Refusal("Pages read failed for %s: %s" % (suffix, exc)) from exc
        require(0 < len(body) <= 1024 * 1024, "Pages response missing or too large")
        return body


class Publisher:
    def __init__(self, args, github, pages, root=ROOT, compare=None):
        self.args, self.github, self.pages, self.root = args, github, pages, Path(root)
        self.compare = compare
        self.snapshots = {}
        self.latest = None

    def validate_inputs(self):
        a = self.args
        current = VERSION_RE.fullmatch(a.version)
        previous = VERSION_RE.fullmatch(a.previous_version)
        tag = TAG_RE.fullmatch(a.tag)
        prev_tag = TAG_RE.fullmatch(a.previous_tag)
        prefix = PREFIX_RE.fullmatch(a.artifact_prefix)
        require(all((current, previous, tag, prev_tag, prefix)), "invalid beta version/tag/prefix")
        require(int(current[1]) == int(tag[1]) == int(prefix[1]),
                "version, release tag and artifact prefix disagree")
        require(int(previous[1]) == int(prev_tag[1]) < int(current[1]),
                "previous tag/version must be earlier and agree")
        require(SHA_RE.fullmatch(a.source_sha) and a.source_sha != "0" * 40,
                "source_sha must be a real full lowercase commit SHA")
        require(RUN_RE.fullmatch(a.verified_run), "verified_run must be a positive numeric ID")
        if self.compare is None:
            opkg = os.environ.get("KAS_PUBLISH_OPKG", "")
            require(opkg and Path(opkg).is_file(), "verified Entware opkg is required")
            def real_compare(left, right):
                with tempfile.TemporaryDirectory() as td:
                    conf = Path(td) / "opkg.conf"
                    conf.write_text("dest root /opt\n")
                    opt = Path(td) / "root/opt/tmp"
                    opt.mkdir(parents=True)
                    cmd = [opkg, "-f", str(conf), "--offline-root", str(opt.parents[1]),
                           "--tmp-dir", str(opt), "compare-versions", left, ">>", right]
                    return subprocess.run(cmd, capture_output=True).returncode == 0
            self.compare = real_compare
        require(self.compare(a.version, a.previous_version),
                "real Entware ordering failed: current must be newer")
        # Dotted 0.1.0.beta.N prereleases are newer than 0.1.0-1.
        # A future stable WEB series must be greater (e.g. 0.1.1-1).
        require(self.compare("0.1.1-1", a.version),
                "real Entware ordering failed: future stable 0.1.1-1 must remain newer")
        require(not self.compare(a.previous_version, a.version),
                "reverse-order Entware check failed")

    def verify_source(self):
        a, gh = self.args, self.github
        commit = gh.api("repos/%s/commits/%s" % (EXPECTED_REPO, a.source_sha))
        require(commit.get("sha") == a.source_sha, "source_sha does not identify an exact commit")
        record = gh.api("repos/%s/actions/runs/%s" % (EXPECTED_REPO, a.verified_run))
        require(record.get("head_sha") == a.source_sha and
                record.get("status") == "completed" and record.get("conclusion") == "success",
                "candidate run is not completed/success at the pinned source SHA")
        require(record.get("event") == "workflow_dispatch" and
                record.get("head_branch") == "main" and
                str(record.get("path", "")).split("@", 1)[0] == ".github/workflows/kas-web-candidate-build.yml",
                "candidate run must be an explicitly dispatched kas-web-candidate-build run on main")
        # An infra/docs-only merge with explicitly relabelled old IPKs must not
        # masquerade as a new WEB source release. Require real WEB changes since
        # the previous published beta, not just publisher/workflow/doc updates.
        comparison = gh.api("repos/%s/compare/%s...%s" %
                            (EXPECTED_REPO, a.previous_tag, a.source_sha))
        require(comparison.get("status") == "ahead" and
                any(item.get("filename", "").startswith("web/control-center/") and
                    not item["filename"].endswith(".md")
                    for item in comparison.get("files", [])),
                "source_sha has no WEB executable/packaging changes since the previous beta")
        previous = gh.release(a.previous_tag)
        require(previous and previous.get("tag_name") == a.previous_tag and
                previous.get("prerelease") is True and previous.get("draft") is False,
                "previous tag must be an existing published WEB prerelease")
        prior_ref = gh.api("repos/%s/git/ref/tags/%s" % (EXPECTED_REPO, a.previous_tag))
        require(prior_ref.get("object", {}).get("type") in ("commit", "tag"),
                "previous release tag is missing")
        target = gh.api("repos/%s/git/ref/tags/%s" % (EXPECTED_REPO, a.tag),
                        missing_ok=True)
        if target is not None:
            require(target.get("object", {}).get("type") == "commit" and
                    target["object"]["sha"] == a.source_sha,
                    "existing candidate tag points to a different source")
        self.assert_no_legacy()
        self.latest = gh.api("repos/%s/releases/latest" % EXPECTED_REPO)
        require(self.latest.get("tag_name") and self.latest.get("id"),
                "cannot record repository Latest")
        for name in ("channels.json", "experimental/panel-update.json"):
            self.snapshots[name] = self.pages.fetch(name)
        registry = json.loads(self.snapshots["channels.json"])
        index = json.loads(self.snapshots["experimental/panel-update.json"])
        active = registry.get("channels", {}).get("experimental", {})
        require(registry.get("schema") == 1 and active.get("published") is True and
                index.get("schema") == 1 and index.get("channel") == "experimental" and
                active.get("tag") == index.get("tag") and
                index.get("tag") in (a.previous_tag, a.tag),
                "live Pages registry/index disagrees with the expected version ladder")

    def assert_no_legacy(self):
        names = self.github.list_tags()
        require(not any(t.startswith("kas-web-channel-") for t in names),
                "unexpected legacy channel Release exists")
        require("kas-web-ipk-" + self.args.source_sha[:7] not in names,
                "unexpected IPK alias Release exists")

    def verify_snapshots(self):
        require(self.github.api("repos/%s/releases/latest" % EXPECTED_REPO).get("id")
                == self.latest["id"], "repository Latest was changed")
        for name, before in self.snapshots.items():
            require(self.pages.fetch(name) == before, "Pages changed during Release-only publication: " + name)
        self.assert_no_legacy()

    def artifacts(self, temp):
        a = self.args
        names = {}
        manifests = {}
        dest = temp / "ipk"
        dest.mkdir()
        for arch in ARCHES:
            directory = temp / ("candidate-" + arch)
            directory.mkdir()
            self.github.download_artifact(a.verified_run,
                                          "%s-%s-%s" % (a.artifact_prefix, arch, a.source_sha),
                                          directory)
            ipk_name = "kas-control-center_%s_%s.ipk" % (a.version, arch)
            expected = {ipk_name, "SHA256SUMS", "manifest-canonical.json", "manifest-alias.json"}
            require({p.name for p in directory.iterdir()} == expected and
                    all(p.is_file() and not p.is_symlink() for p in directory.iterdir()),
                    "candidate contains missing, extra or unsafe files for " + arch)
            raw = (directory / ipk_name).read_bytes()
            require(0 < len(raw) <= 16 * 1024 * 1024, "invalid IPK size")
            expected_sums = "%s  ./%s\n" % (digest(raw), ipk_name)
            require((directory / "SHA256SUMS").read_text() == expected_sums,
                    "build-time SHA256SUMS mismatch for " + arch)
            ci = json.loads((directory / "manifest-canonical.json").read_text())
            require(ci.get("schema") == 1 and ci.get("channel") == "experimental" and
                    ci.get("tag") == a.tag and len(ci.get("packages", [])) == 1,
                    "candidate manifest metadata mismatch")
            manifest = dict(ci["packages"][0])
            require(manifest.get("version") == a.version and
                    manifest.get("source_sha") == a.source_sha and
                    manifest.get("architecture") == arch and
                    manifest.get("name") == ipk_name and
                    manifest.get("sha256") == digest(raw) and
                    manifest.get("size") == len(raw), "candidate package identity mismatch")
            # The build also emits an alias parsing fixture, never a public alias Release.
            alias = json.loads((directory / "manifest-alias.json").read_text())
            require(alias.get("tag") == "kas-web-ipk-" + a.source_sha[:7] and
                    alias.get("packages") == ci["packages"],
                    "candidate alias fixture diverges from the actual IPK")
            normalized = ipk_name.replace("~", ".")
            (dest / normalized).write_bytes(raw)
            manifest["name"] = normalized
            manifests[arch] = manifest
            names[normalized] = raw
        script = self.root / "web/control-center/packaging/update-manifest.py"
        output = run_checked([sys.executable, str(script), "--channel", "experimental",
                              "--tag", a.tag] + [str(dest / n) for n in names])
        aggregate = json.loads(output)
        require(aggregate.get("schema") == 1 and aggregate.get("tag") == a.tag and
                {p["architecture"]: p for p in aggregate["packages"]} == manifests,
                "reconstructed release index disagrees with all four CI manifests")
        (temp / "panel-update.json").write_bytes(output)
        sums = "".join("%s  %s\n" % (digest(names[n]), n) for n in names).encode()
        (dest / "SHA256SUMS").write_bytes(sums)
        names["SHA256SUMS"] = sums
        notes = ["KAS WEB %s (experimental prerelease)" % a.tag, "",
                 "Source SHA: `%s`" % a.source_sha,
                 "Verified candidate run: %s" % a.verified_run,
                 "Internal IPK version: `%s`" % a.version,
                 "Previous release: %s" % a.previous_tag, "",
                 "Four verified architectures (SHA256 of actual IPK bytes):", "",
                 "| Architecture | Asset | SHA256 |",
                 "| --- | --- | --- |"]
        for item in aggregate["packages"]:
            notes.append("| %s | `%s` | `%s` |" %
                         (item["architecture"], item["name"], item["sha256"]))
        notes += ["", "This Release does NOT switch the Pages update index.",
                  "A separate owner-approved GO PAGES is required.", ""]
        (temp / "RELEASE_NOTES.md").write_text("\n".join(notes))
        return {name: (dest / name) for name in names}

    def inspect(self, release, files, canonical=False):
        a = self.args
        require(release and release.get("tag_name") == a.tag and
                release.get("target_commitish") == a.source_sha and
                release.get("prerelease") is True,
                "existing release is not the pinned beta prerelease")
        assets = release.get("assets", [])
        require(isinstance(assets, list) and len({x.get("name") for x in assets}) == len(assets),
                "duplicate release asset names")
        remote = {x["name"]: x for x in assets}
        require(set(remote) <= set(files), "release contains an unapproved extra asset")
        for name, data in remote.items():
            raw = files[name].read_bytes()
            require(data.get("state") == "uploaded" and
                    data.get("size") == len(raw) and
                    data.get("digest") == "sha256:" + digest(raw),
                    "release asset digest or size mismatch for " + name)
            url = str(data.get("browser_download_url", ""))
            suffix = "/%s/%s" % (a.tag, name)
            require(url.endswith(suffix) if canonical else url.endswith("/" + name),
                    "release asset download path mismatch for " + name)
        return remote

    def release(self, files, temp):
        a, gh = self.args, self.github
        existing = gh.release(a.tag)
        if existing is not None:
            self.inspect(existing, files, canonical=not existing.get("draft"))
            require(existing.get("draft") is True or
                    len(existing.get("assets", [])) == len(files),
                    "published release is incomplete; manual investigation required")
            print("Found existing Release; verifying/resuming without recreation")
        else:
            self.verify_snapshots()  # no publication if the Pages or Latest snapshot drifted
            gh.create_draft(a.tag, a.source_sha, temp / "RELEASE_NOTES.md")
            existing = None
            for _ in range(4):
                existing = gh.release(a.tag)
                if existing is not None:
                    break
                time.sleep(3)
            require(existing is not None, "created draft is not visible; safe to retry later")
        self.inspect(existing, files, canonical=not existing.get("draft"))
        if existing.get("draft"):
            have = {x["name"] for x in existing.get("assets", [])}
            for name, path in files.items():
                if name not in have:
                    gh.upload(a.tag, path)
                    # A partial failure leaves a draft; never clobber an existing asset.
            candidate = gh.release(a.tag)
            self.inspect(candidate, files, canonical=False)
            require(len(candidate["assets"]) == len(files),
                    "draft is incomplete; refusing to publish")
            self.verify_snapshots()
            gh.publish(a.tag)
        require(gh.api("repos/%s/git/ref/tags/%s" % (EXPECTED_REPO, a.tag))
                .get("object", {}).get("sha") == a.source_sha,
                "published tag does not point to the verified source")
        published = gh.release(a.tag)
        require(published is not None and published.get("draft") is False,
                "Release is not public")
        self.inspect(published, files, canonical=True)
        require(len(published["assets"]) == len(files), "published Release asset set incomplete")
        # Independently download every public asset to detect a swapped/altered byte.
        verify = temp / "downloaded"
        verify.mkdir()
        for name, path in files.items():
            gh.download_release_asset(a.tag, name, verify)
            target = verify / name
            require(target.is_file() and not target.is_symlink() and
                    target.read_bytes() == path.read_bytes(),
                    "downloaded published asset differs from verified CI bytes: " + name)
        self.verify_snapshots()
        print("PASS: release-only publication/resume, five assets, Latest and Pages unchanged")

    def execute(self):
        self.validate_inputs()
        self.verify_source()
        with tempfile.TemporaryDirectory(prefix="kas-web-publish-") as directory:
            temp = Path(directory)
            files = self.artifacts(temp)
            self.release(files, temp)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ("version", "previous-version", "tag", "previous-tag",
                "verified-run", "source-sha", "artifact-prefix"):
        parser.add_argument("--" + arg, required=True)
    args = parser.parse_args(argv)
    require(os.environ.get("GITHUB_ACTIONS") == "true" and
            os.environ.get("GH_REPO") == EXPECTED_REPO and
            os.environ.get("GH_TOKEN"), "publisher is restricted to authenticated GitHub Actions")
    Publisher(args, Github(), Pages()).execute()


if __name__ == "__main__":
    try:
        main()
    except (Refusal, ValueError, KeyError, OSError) as exc:
        print("REFUSED: %s" % exc, file=sys.stderr)
        sys.exit(1)
