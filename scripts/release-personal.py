#!/usr/bin/env python3
"""Prepare and publish signed releases to the personal fork only."""
import argparse
from datetime import datetime, timezone
from email.utils import format_datetime
import hashlib
import json
from pathlib import Path
import platform
import plistlib
import subprocess
import sys
import urllib.request
import xml.etree.ElementTree as ET

from personal_build import BUNDLE_ID, CONFIG, ROOT, sparkle

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)


def run(*args, **kwargs):
    return subprocess.run(list(args), cwd=ROOT, check=True, **kwargs)


def capture(*args):
    return subprocess.check_output(list(args), cwd=ROOT, text=True).strip()


def make_feed(archive, signature, notes, destination, *, version=None, build=None, download_url=None):
    version = version or CONFIG["version"]
    tag = "v" + version
    feed = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(feed, "channel")
    ET.SubElement(channel, "title").text = "Filetor Personal"
    ET.SubElement(channel, "link").text = f"https://github.com/{CONFIG['repository']}/releases"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"Filetor Personal {version}"
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = str(build or CONFIG["build"])
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = CONFIG["minimum_system_version"]
    ET.SubElement(item, f"{{{SPARKLE_NS}}}hardwareRequirements").text = "arm64"
    ET.SubElement(item, "description", {f"{{{SPARKLE_NS}}}format": "plain-text"}).text = notes
    url = download_url or f"https://github.com/{CONFIG['repository']}/releases/download/{tag}/{archive.name}"
    ET.SubElement(item, "enclosure", {"url": url, "type": "application/octet-stream",
                                     "length": str(archive.stat().st_size), f"{{{SPARKLE_NS}}}edSignature": signature})
    ET.indent(feed)
    ET.ElementTree(feed).write(destination, encoding="utf-8", xml_declaration=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--publish", action="store_true", help="Publish the prepared release to Doithoo/Filetor")
    parser.add_argument("--notes", type=Path, default=ROOT / "docs/releases" / (CONFIG["version"] + ".md"))
    args = parser.parse_args()
    if CONFIG["repository"] != "Doithoo/Filetor":
        raise RuntimeError("This release script is restricted to the personal fork")
    if platform.machine() != "arm64":
        raise RuntimeError("This personal release channel currently targets Apple Silicon")
    if capture("git", "status", "--porcelain"):
        raise RuntimeError("Commit the intended changes before preparing or publishing a release")
    revision = capture("git", "rev-parse", "HEAD")
    output = ROOT / ".build/releases" / CONFIG["version"]
    tag = "v" + CONFIG["version"]
    archive = output / f"Filetor-Personal-{CONFIG['version']}-arm64.zip"
    feed = output / "appcast.xml"
    manifest = output / "release.json"
    notes = args.notes.read_text()
    dependency = sparkle()
    sign = str(dependency / "bin/sign_update")
    account = CONFIG["signing_account"]
    public_key = capture(str(dependency / "bin/generate_keys"), "--account", account, "-p")
    if public_key != CONFIG["public_ed_key"]:
        raise RuntimeError("The local signing key does not match this release channel")
    if not args.publish:
        run(sys.executable, "scripts/build-personal.py", "--test")
        run(sys.executable, "scripts/build-personal.py")
        app = ROOT / ".build/personal/Filetor Personal.app"
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        assert info["CFBundleIdentifier"] == BUNDLE_ID
        assert info["CFBundleShortVersionString"] == CONFIG["version"]
        assert info["CFBundleVersion"] == str(CONFIG["build"])
        output.mkdir(parents=True, exist_ok=True)
        archive.unlink(missing_ok=True)
        # ditto preserves framework symlinks and signatures, without copying extended attributes.
        run("ditto", "-c", "-k", "--keepParent", "--norsrc", "--noextattr", str(app), str(archive))
        signature = capture(sign, "--account", account, "-p", str(archive))
        run(sign, "--account", account, "--verify", str(archive), signature)
        make_feed(archive, signature, notes, feed)
        run(sign, "--account", account, str(feed))
        run(sign, "--account", account, "--verify", str(feed))
        (output / "release-notes.md").write_text(notes)
        hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in [archive, feed, output / "release-notes.md"]}
        (output / "SHA256SUMS").write_text("".join(f"{digest}  {name}\n" for name, digest in hashes.items()))
        manifest.write_text(json.dumps({"commit": revision, "version": CONFIG["version"], "build": CONFIG["build"],
                                        "archive_signature": signature, "files": hashes}, indent=2) + "\n")
        print(f"Prepared and verified {output}. Publish with: python3 scripts/release-personal.py --publish")
        return
    prepared = json.loads(manifest.read_text())
    if prepared["commit"] != revision or prepared["version"] != CONFIG["version"]:
        raise RuntimeError("Prepared release does not match HEAD; prepare it again")
    for name, expected in prepared["files"].items():
        if hashlib.sha256((output / name).read_bytes()).hexdigest() != expected:
            raise RuntimeError(f"Prepared release asset changed: {name}")
    run(sign, "--account", account, "--verify", str(archive), prepared["archive_signature"])
    run(sign, "--account", account, "--verify", str(feed))
    repo = CONFIG["repository"]
    # HEAD must already be pushed, so the release always points to reviewable source.
    remote = capture("gh", "api", f"repos/{repo}/commits/{revision}", "--jq", ".sha")
    if remote != revision:
        raise RuntimeError("Push the release commit to the personal fork first")
    releases = json.loads(capture("gh", "api", f"repos/{repo}/releases?per_page=100"))
    for release in releases:
        if not release["draft"] and release["tag_name"] == tag:
            raise RuntimeError("This release is already published; increment version and build for a new release")
    # Prevent downgrade of the stable feed; the existing feed is public and small.
    published = [release for release in releases if not release["draft"] and not release["prerelease"]]
    if published:
        with urllib.request.urlopen(f"https://github.com/{repo}/releases/latest/download/appcast.xml", timeout=30) as response:
            existing = ET.fromstring(response.read())
        builds = [int(element.text) for element in existing.iter(f"{{{SPARKLE_NS}}}version")]
        if not builds or CONFIG["build"] <= max(builds):
            raise RuntimeError("The release build must be greater than every published build")
    if not any(release["tag_name"] == tag for release in releases):
        run("gh", "release", "create", tag, "--repo", repo, "--target", revision, "--draft", "--title",
            f"Filetor Personal {CONFIG['version']}", "--notes-file", str(output / "release-notes.md"))
    run("gh", "release", "upload", tag, "--repo", repo, "--clobber", str(archive), str(feed), str(output / "SHA256SUMS"))
    uploaded = json.loads(capture("gh", "api", f"repos/{repo}/releases/tags/{tag}"))
    assets = {a["name"]: a for a in uploaded["assets"]}
    for path in [archive, feed, output / "SHA256SUMS"]:
        asset = assets.get(path.name)
        if not asset or asset["size"] != path.stat().st_size:
            raise RuntimeError("Uploaded assets are incomplete; release remains a draft")
        digest = asset.get("digest")
        if digest and digest != "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest():
            raise RuntimeError("Uploaded asset checksum mismatch; release remains a draft")
    run("gh", "release", "edit", tag, "--repo", repo, "--draft=false", "--latest", "--notes-file", str(output / "release-notes.md"))
    print(f"Published https://github.com/{repo}/releases/tag/{tag}")


if __name__ == "__main__":
    main()
