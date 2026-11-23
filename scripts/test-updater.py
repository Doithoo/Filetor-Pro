#!/usr/bin/env python3
"""Exercise Sparkle's real download/verify/install/relaunch path in disposable apps."""
import argparse
import code_signing
import functools
import http.server
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import threading
import time
import uuid

from build_support import ROOT, CONFIG, sparkle

spec = importlib.util.spec_from_file_location("release_filetor", ROOT / "scripts/release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--keep-fixtures", action="store_true",
                        help="Keep temporary fixture files after a successful run for inspection")
    args = parser.parse_args()
    dependency = sparkle()
    root = Path(tempfile.mkdtemp(prefix="updater-fixtures-", dir=ROOT / ".build"))
    try:
        run_tests(root, dependency)
    except BaseException:
        print("Updater fixtures retained for diagnosis:", root, flush=True)
        raise
    if args.keep_fixtures:
        print("Updater fixtures retained:", root, flush=True)
    else:
        shutil.rmtree(root)
        print("Temporary updater fixtures removed.", flush=True)


def run_tests(root, dependency):
    report = ROOT / ".build/reports/updater.json"
    report.parent.mkdir(parents=True, exist_ok=True)
    # A failed run must not leave a previous successful summary looking current.
    report.unlink(missing_ok=True)
    sdk = "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
    executable = root / "UpdateProbe"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor", "-sdk", sdk,
                    "-parse-as-library", "-F", str(dependency), "-framework", "Sparkle", "-Xlinker", "-rpath", "-Xlinker",
                    "@executable_path/../Frameworks", str(ROOT / "Filetor/AutomaticUpdateSettings.swift"),
                    str(ROOT / "Tests/UpdateProbe.swift"), "-o", str(executable)], check=True)
    class QuietHandler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *_):
            pass
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(QuietHandler, directory=str(root)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base_url = f"http://127.0.0.1:{server.server_port}"
    sign = str(dependency / "bin/sign_update")
    account = CONFIG["signing_account"]
    results = []
    try:
        for mode in ["valid", "signature_migration", "renamed", "automatic", "tampered_archive", "tampered_feed", "no_update", "unreachable"]:
            case = root / mode
            case.mkdir()
            bundle_id = "com.doithoo.Filetor.UpdateProbe." + uuid.uuid4().hex
            log = case / "probe.log"
            feed = case / "appcast.xml"
            renamed = mode == "renamed"
            app = case / "installed" / ("Filetor.app" if renamed else "Filetor Update Probe.app")
            candidate = case / "candidate" / ("Filetor Pro.app" if renamed else "Filetor Update Probe.app")
            for bundle, build in [(app, "1"), (candidate, "2")]:
                executable_name = ("FiletorPersonal" if build == "1" else "FiletorPro") if renamed else "UpdateProbe"
                product_name = ("Filetor Personal" if build == "1" else "Filetor Pro") if renamed else "Filetor Update Probe"
                version = ("0.2.0-personal.2" if build == "1" else "0.3.0") if renamed else build
                macos = bundle / "Contents/MacOS"
                macos.mkdir(parents=True)
                shutil.copy2(executable, macos / executable_name)
                frameworks = bundle / "Contents/Frameworks"
                frameworks.mkdir()
                subprocess.run(["ditto", str(dependency / "Sparkle.framework"), str(frameworks / "Sparkle.framework")], check=True)
                info = {"CFBundleIdentifier": bundle_id, "CFBundleExecutable": executable_name, "CFBundleName": product_name,
                        "CFBundleDisplayName": product_name,
                        "CFBundlePackageType": "APPL", "CFBundleVersion": build, "CFBundleShortVersionString": version,
                        "LSMinimumSystemVersion": "26.0", "LSUIElement": True, "ProbeLog": str(log), "ProbeMode": mode,
                        "SUFeedURL": base_url + f"/{mode}/appcast.xml", "SUPublicEDKey": CONFIG["public_ed_key"],
                        "SUEnableAutomaticChecks": False, "SUAutomaticallyUpdate": False,
                        "SUVerifyUpdateBeforeExtraction": True, "SURequireSignedFeed": True,
                        "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True}}
                with (bundle / "Contents/Info.plist").open("wb") as f:
                    plistlib.dump(info, f)
                if mode == "signature_migration" and build == "1":
                    subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], check=True, capture_output=True)
                else:
                    code_signing.sign(bundle, bundle_id)
            archive = case / "update.zip"
            subprocess.run(["ditto", "-c", "-k", "--keepParent", "--norsrc", "--noextattr", str(candidate), str(archive)], check=True)
            signature = subprocess.check_output([sign, "--account", account, "-p", str(archive)], text=True).strip()
            release.make_feed(archive, signature, "Native updater integration fixture", feed, version="0.3.0" if renamed else "2", build=1 if mode == "no_update" else 2,
                              download_url=base_url + f"/{mode}/update.zip")
            subprocess.run([sign, "--account", account, str(feed)], check=True, capture_output=True)
            if mode == "tampered_archive":
                data = bytearray(archive.read_bytes()); data[len(data) // 2] ^= 0x01; archive.write_bytes(data)
            elif mode == "tampered_feed":
                feed.write_text(feed.read_text().replace("Native updater integration fixture", "Modified untrusted release notes"))
            elif mode == "unreachable":
                feed.unlink()
            process = subprocess.Popen([str(app / "Contents/MacOS" / ("FiletorPersonal" if renamed else "UpdateProbe"))], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            deadline = time.monotonic() + 75
            reopened = False
            try:
                while time.monotonic() < deadline:
                    text = log.read_text() if log.exists() else ""
                    if mode == "automatic" and "INSTALL_ON_QUIT" in text and process.poll() is not None and not reopened:
                        # Silent installation intentionally does not relaunch. Simulate the next launch.
                        info_path = app / "Contents/Info.plist"
                        if info_path.exists() and plistlib.loads(info_path.read_bytes())["CFBundleVersion"] == "2":
                            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
                            process = subprocess.Popen([str(app / "Contents/MacOS/UpdateProbe")], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                            reopened = True
                    if any(marker in text for marker in ["INSTALLED_PREFERENCES_PRESERVED", "PREFERENCES_LOST", "UPDATE_ERROR:", "START_ERROR:", "NO_UPDATE", "SETTINGS_ERROR:"]):
                        break
                    time.sleep(0.2)
                else:
                    raise RuntimeError(f"{mode} timed out: {text}")
                if mode in ["valid", "signature_migration", "renamed", "automatic"]:
                    if mode == "automatic":
                        assert "COMBINED_SETTINGS_VERIFIED" in text, text
                        assert "INSTALL_ON_QUIT" in text, text
                        assert "FOUND:" not in text and "CHECKING" not in text, text
                    assert "INSTALLED_PREFERENCES_PRESERVED" in text, text
                    installed = list((case / "installed").glob("*.app"))
                    assert len(installed) == 1, installed
                    code_signing.verify(installed[0], bundle_id)
                    info = plistlib.loads((installed[0] / "Contents/Info.plist").read_bytes())
                    assert info["CFBundleVersion"] == "2"
                    assert info["CFBundleIdentifier"] == bundle_id
                    if renamed:
                        assert info["CFBundleDisplayName"] == "Filetor Pro"
                        assert info["CFBundleShortVersionString"] == "0.3.0"
                        assert info["CFBundleExecutable"] == "FiletorPro"
                        assert "LAUNCHED: FiletorPro" in text, text
                        assert not (installed[0] / "Contents/MacOS/FiletorPersonal").exists()
                elif mode == "no_update":
                    assert "NO_UPDATE" in text, text
                else:
                    assert "UPDATE_ERROR:" in text, text
                    assert plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleVersion"] == "1"
                print("PASS:", mode, flush=True)
                results.append({"case": mode, "passed": True, "log": log.read_text()})
            finally:
                if process.poll() is None:
                    try: process.wait(timeout=3)
                    except subprocess.TimeoutExpired: process.terminate(); process.wait(timeout=5)
                subprocess.run(["defaults", "delete", bundle_id], capture_output=True)
                shutil.rmtree(Path.home() / "Library/Caches" / bundle_id, ignore_errors=True)
                register = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
                for installed in (case / "installed").glob("*.app"):
                    subprocess.run([register, "-u", str(installed)], capture_output=True)
                shutil.rmtree(case / "installed", ignore_errors=True)
                shutil.rmtree(candidate, ignore_errors=True)
        report.write_text(json.dumps(results, indent=2) + "\n")
        print("Updater integration results:", report, flush=True)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
