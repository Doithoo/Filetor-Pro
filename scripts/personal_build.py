"""Shared release configuration and a checksum-pinned native dependency."""
import hashlib
import json
import subprocess
import tempfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONFIG = json.loads((ROOT / "scripts/release-config.json").read_text())
BUNDLE_ID = "com.doithoo.Filetor.personal"
FEED_URL = f"https://github.com/{CONFIG['repository']}/releases/latest/download/appcast.xml"


def sparkle():
    version = CONFIG["sparkle_version"]
    directory = ROOT / ".build/dependencies" / f"Sparkle-{version}"
    directory.mkdir(parents=True, exist_ok=True)
    archive = directory / f"Sparkle-{version}.tar.xz"
    if not archive.exists():
        url = f"https://github.com/sparkle-project/Sparkle/releases/download/{version}/{archive.name}"
        with tempfile.NamedTemporaryFile(dir=directory, delete=False) as pending:
            pending_path = Path(pending.name)
        try:
            urllib.request.urlretrieve(url, pending_path)
            if hashlib.sha256(pending_path.read_bytes()).hexdigest() != CONFIG["sparkle_sha256"]:
                raise RuntimeError("Sparkle download failed SHA-256 verification")
            pending_path.replace(archive)
        finally:
            pending_path.unlink(missing_ok=True)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != CONFIG["sparkle_sha256"]:
        raise RuntimeError("Cached Sparkle archive failed SHA-256 verification")
    # Re-extract the verified distribution to avoid trusting a modified cached binary.
    subprocess.run(["tar", "-xJf", str(archive), "-C", str(directory)], check=True)
    return directory
