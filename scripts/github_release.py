#!/usr/bin/env python3
"""GitHub Actions release gates. Does not build or sign applications."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def api(path):
    return json.loads(subprocess.check_output(["gh", "api", path], text=True))


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def version():
    tag = os.environ["RELEASE_TAG"]
    require(re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag), "Invalid stable version tag")
    match = re.search(r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+[0-9]+\s*$", Path("pubspec.yaml").read_text(), re.M)
    require(match and match.group(1) == tag[1:], "Tag differs from pubspec.yaml")
    return tag[1:]


def preflight():
    version()
    repo, sha = os.environ["GH_REPO"], os.environ["GITHUB_SHA"]
    checks = api(f"repos/{repo}/commits/{sha}/check-runs?per_page=100")["check_runs"]
    require(any(c["name"] == "validate" and c["conclusion"] == "success" for c in checks), "Validate ProxyYou must succeed on this exact commit first")


def verify_draft():
    v = version()
    require(os.environ.get("ARTIFACTS_VERIFIED") == "true", "Confirm artifact validation and disclosure of signing status before publication")
    repo, tag = os.environ["GH_REPO"], os.environ["RELEASE_TAG"]
    releases = api(f"repos/{repo}/releases?per_page=100")
    matching = [r for r in releases if r["tag_name"] == tag]
    require(len(matching) == 1, "Expected one release for the requested version")
    release = matching[0]
    require(release["draft"] and not release["prerelease"], "Expected a stable draft release")
    commit = api(f"repos/{repo}/commits/{release['target_commitish']}")
    require(commit["sha"] == os.environ["GITHUB_SHA"], "Draft release must target this validated commit")
    refs = api(f"repos/{repo}/git/matching-refs/tags/{tag}")
    if any(r["ref"] == f"refs/tags/{tag}" for r in refs):
        require(api(f"repos/{repo}/commits/{tag}")["sha"] == os.environ["GITHUB_SHA"], "Existing release tag differs from the validated commit")
    include_macos = os.environ.get("INCLUDE_MACOS", "true")
    require(include_macos in {"true", "false"}, "INCLUDE_MACOS must be true or false")
    windows_only = os.environ.get("WINDOWS_ONLY", "false")
    require(windows_only in {"true", "false"}, "WINDOWS_ONLY must be true or false")
    expected = {f"ProxyYou-Windows-x64-{v}-Setup.exe"}
    names = {a["name"] for a in release["assets"]}
    if windows_only == "true":
        require(not any(name.startswith(("ProxyYou-Android-", "ProxyYou-macOS-")) for name in names),
                "Windows-only release must not contain Android or macOS packages")
    else:
        expected.add(f"ProxyYou-Android-{v}.apk")
        if include_macos == "true":
            expected.add(f"ProxyYou-macOS-AppleSilicon-{v}.zip")
            require(not any(name.startswith("ProxyYou-macOS-Intel-") for name in names),
                    "macOS Intel packages are no longer published")
        else:
            require(not any(name.startswith("ProxyYou-macOS-") for name in names),
                    "macOS publication is paused: remove macOS assets from this draft")
    require(expected | {"SHA256SUMS.txt"} <= names, "Missing platform packages or SHA256SUMS.txt")
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["gh", "release", "download", tag, "--dir", tmp, "--pattern", "SHA256SUMS.txt"], check=True)
        sums = {}
        for line in (Path(tmp) / "SHA256SUMS.txt").read_text().splitlines():
            m = re.fullmatch(r"([a-fA-F0-9]{64}) [ *]([^/\\]+)", line)
            require(m is not None, "Invalid checksum entry or unsafe filename")
            require(m[2] not in sums, "Duplicate checksum entry")
            sums[m[2]] = m[1].lower()
        require(expected <= sums.keys(), "Missing package checksums")
        for name in sorted(expected):
            subprocess.run(["gh", "release", "download", tag, "--dir", tmp, "--pattern", name], check=True)
            digest = hashlib.sha256()
            with (Path(tmp) / name).open("rb") as f:
                for block in iter(lambda: f.read(1024 * 1024), b""):
                    digest.update(block)
            require(digest.hexdigest() == sums[name], f"Checksum mismatch: {name}")
    print("Release assets and hashes verified; signing status is a maintainer attestation.")


if __name__ == "__main__":
    {"preflight": preflight, "verify-draft": verify_draft}[sys.argv[1]]()
