#!/usr/bin/env python3
"""Check update identity continuity without touching macOS privacy grants."""
import json
import plistlib
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
from build_support import ROOT
import code_signing


def main():
    results = []
    def check(condition, description):
        if not condition:
            raise RuntimeError(description)
        print("PASS:", description, flush=True)
        results.append(description)

    with tempfile.TemporaryDirectory(prefix="filetor-signature-") as directory:
        root = Path(directory)
        bundles = []
        bundle_id = "com.doithoo.Filetor.SignatureProbe"
        for version in ["1", "2"]:
            app = root / version / "Signature Probe.app"
            macos = app / "Contents/MacOS"
            macos.mkdir(parents=True)
            shutil.copy("/usr/bin/true" if version == "1" else "/usr/bin/false", macos / "Probe")
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": bundle_id, "CFBundleExecutable": "Probe",
                "CFBundleVersion": version, "CFBundlePackageType": "APPL"}))
            code_signing.sign(app, bundle_id)
            bundles.append(app)
        details = [subprocess.run(["codesign", "-dvvv", str(app)], capture_output=True, text=True, check=True).stderr for app in bundles]
        hashes = [re.search(r"^CDHash=(.+)$", text, re.M).group(1) for text in details]
        check(hashes[0] != hashes[1], "different releases have different binary hashes")
        requirements = [code_signing.designated_requirement(app) for app in bundles]
        check(requirements[0] == requirements[1] == code_signing.requirement(bundle_id),
              "different releases retain the same certificate-bound designated requirement")
        subprocess.run(["codesign", "--verify", "-R", "=" + requirements[0], str(bundles[1])], check=True)
        check(True, "new release satisfies the previous release's code identity")
        subprocess.run(["codesign", "--force", "--sign", "-", str(bundles[1])], check=True, capture_output=True)
        try:
            code_signing.verify(bundles[1], bundle_id)
        except (subprocess.CalledProcessError, RuntimeError):
            check(True, "an ad hoc replacement is rejected even with the same bundle identifier")
        else:
            raise RuntimeError("Ad hoc replacement unexpectedly passed")
        (bundles[0] / "Contents/Info.plist").write_bytes(b"tampered")
        result = subprocess.run(["codesign", "--verify", "--strict", str(bundles[0])], capture_output=True)
        check(result.returncode != 0, "tampering invalidates the certificate-signed application")
    report = ROOT / ".build/reports/signing.json"
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps({"certificateSHA1": code_signing.identity(), "checks": results,
                                 "tccGrantPersistenceTested": False}, indent=2) + "\n")


if __name__ == "__main__":
    main()
