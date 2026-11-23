"""Preserve the release's code identity across builds; never silently use ad hoc signing."""
import re
import subprocess
from build_support import BUNDLE_ID, CONFIG


def identity():
    fingerprint = CONFIG.get("code_signing_certificate_sha1", "")
    if not re.fullmatch(r"[0-9A-Fa-f]{40}", fingerprint):
        raise RuntimeError("Configure a persistent code signing certificate before building a release")
    return fingerprint.upper()


def requirement(bundle_id=BUNDLE_ID):
    if not re.fullmatch(r"[A-Za-z0-9.-]+", bundle_id):
        raise ValueError("Invalid signing identifier")
    return f'identifier "{bundle_id}" and certificate root = H"{identity().lower()}"'


def designated_requirement(app):
    result = subprocess.run(["codesign", "-d", "-r-", str(app)], check=True, capture_output=True, text=True)
    for line in (result.stdout + result.stderr).splitlines():
        if line.startswith("designated => "):
            return line.removeprefix("designated => ")
    raise RuntimeError("The application has no designated requirement")


def verify(app, bundle_id=BUNDLE_ID):
    expected = requirement(bundle_id)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", "-R", "=" + expected, str(app)], check=True)
    if designated_requirement(app) != expected:
        raise RuntimeError("Code identity changed; do not publish or replace the installed app")
    return expected


def sign(app, bundle_id=BUNDLE_ID):
    # The private key lives in the login Keychain. A missing/locked identity is
    # an error, never a reason to fall back to `--sign -`.
    subprocess.run(["codesign", "--force", "--sign", identity(), "--timestamp=none",
                    "--identifier", bundle_id, str(app)], check=True)
    return verify(app, bundle_id)
