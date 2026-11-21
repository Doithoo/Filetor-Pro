#!/usr/bin/env python3
"""Build Filetor Personal with a checksum-pinned Sparkle updater."""
import os
import platform
import sys
from pathlib import Path
import plistlib
import shutil
import subprocess
from personal_build import CONFIG, FEED_URL, sparkle

root = Path(__file__).resolve().parents[1]
out = root / ".build" / "personal"
out.mkdir(parents=True, exist_ok=True)
app = out / "Filetor Personal.app"
macos = app / "Contents" / "MacOS"
resources = app / "Contents" / "Resources"
macos.mkdir(parents=True, exist_ok=True)
resources.mkdir(parents=True, exist_ok=True)
sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
# The installed 27.x CLT SDK declares SwiftUI macros but omits their compiler
# plugin. Use the installed stable SDK, or an explicit SDKROOT, for local builds.
stable_sdk = Path("/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk")
sdk = os.environ.get("SDKROOT", str(stable_sdk) if stable_sdk.exists() else sdk)
testing = "--test" in sys.argv
sparkle_dir = sparkle()
command = ["xcrun", "swiftc", "-Onone" if testing else "-O", "-whole-module-optimization", "-swift-version", "5", "-default-isolation", "MainActor",
           "-target", f"{platform.machine()}-apple-macosx26.0", "-sdk", sdk, "-module-name", "FiletorPersonal",
           "-module-cache-path", str(out / "ModuleCache"), "-o", str(out / "FiletorRegression" if testing else macos / "FiletorPersonal")]
command += ["-F", str(sparkle_dir), "-framework", "Sparkle", "-Xlinker", "-rpath", "-Xlinker",
            str(sparkle_dir) if testing else "@executable_path/../Frameworks"]
# Preserve WebP support when Homebrew's existing static libraries are available.
webp = Path("/opt/homebrew/opt/webp")
if (webp / "lib/libwebp.a").exists():
    module = out / "Modules/libwebp"
    module.mkdir(parents=True, exist_ok=True)
    (module / "module.modulemap").write_text('module libwebp { header "' + str(webp / "include/webp/encode.h") + '" export * }\n')
    command += ["-I", str(out / "Modules"), "-Xcc", "-I" + str(webp / "include"), str(webp / "lib/libwebp.a"), str(webp / "lib/libsharpyuv.a")]
command += [str(p) for p in sorted((root / "Filetor").glob("*.swift")) if not (testing and p.name == "MyApp.swift")]
if testing:
    command += [str(root / "Tests/Regression.swift")]
    subprocess.run(command, check=True)
    subprocess.run([str(out / "FiletorRegression")], check=True, timeout=180)
    sys.exit(0)
subprocess.run(command, check=True)
info = {
    "CFBundleExecutable": "FiletorPersonal", "CFBundleIdentifier": "com.doithoo.Filetor.personal",
    "CFBundleName": "Filetor Personal", "CFBundleDisplayName": "Filetor Personal",
    "CFBundlePackageType": "APPL", "CFBundleShortVersionString": CONFIG["version"],
    "CFBundleVersion": str(CONFIG["build"]), "LSMinimumSystemVersion": CONFIG["minimum_system_version"],
    "NSHighResolutionCapable": True, "FiletorPersonalBuild": True,
    "SUFeedURL": FEED_URL, "SUPublicEDKey": CONFIG["public_ed_key"],
    "SUEnableAutomaticChecks": True, "SUAutomaticallyUpdate": False,
    "SUScheduledCheckInterval": 3600, "SUSendProfileInfo": False,
    "SUVerifyUpdateBeforeExtraction": True, "SURequireSignedFeed": True,
    "NSHumanReadableCopyright": "Copyright © 2026 David Praznik. Personal modifications.",
}
original_resources = Path("/Applications/Filetor.app/Contents/Resources")
for name in ["Assets.car", "Filetorapp.icns"]:
    if (original_resources / name).exists():
        shutil.copy2(original_resources / name, resources / name)
        info["CFBundleIconName"] = "Filetorapp"
        info["CFBundleIconFile"] = "Filetorapp"
(resources / "LICENSE.txt").write_text((root / "LICENSE").read_text())
if (webp / "COPYING").exists():
    shutil.copy2(webp / "COPYING", resources / "libwebp-LICENSE.txt")
with (app / "Contents/Info.plist").open("wb") as f:
    plistlib.dump(info, f)
frameworks = app / "Contents/Frameworks"
frameworks.mkdir(exist_ok=True)
framework = frameworks / "Sparkle.framework"
if framework.exists():
    shutil.rmtree(framework)
subprocess.run(["ditto", str(sparkle_dir / "Sparkle.framework"), str(framework)], check=True)
subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
print(app)
