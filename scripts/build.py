#!/usr/bin/env python3
"""Build Filetor Pro with a checksum-pinned Sparkle updater."""
import os
import platform
import sys
from pathlib import Path
import plistlib
import shutil
import subprocess
import code_signing
from build_support import APP_PATH, BUILD_DIR, BUNDLE_ID, CONFIG, EXECUTABLE, FEED_URL, PRODUCT_NAME, sparkle

root = Path(__file__).resolve().parents[1]
out = BUILD_DIR
out.mkdir(parents=True, exist_ok=True)
subprocess.run([sys.executable, str(root / "scripts/check_localization.py")], check=True)
app = APP_PATH
macos = app / "Contents" / "MacOS"
resources = app / "Contents" / "Resources"
macos.mkdir(parents=True, exist_ok=True)
resources.mkdir(parents=True, exist_ok=True)
# Shared by the app and command-line regression runner.
for source in sorted((root / "Filetor").glob("*.lproj")):
    shutil.copytree(source, resources / source.name, dirs_exist_ok=True)
    shutil.copytree(source, out / "Resources" / source.name, dirs_exist_ok=True)
sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
# The installed 27.x CLT SDK declares SwiftUI macros but omits their compiler
# plugin. Use the installed stable SDK, or an explicit SDKROOT, for local builds.
stable_sdk = Path("/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk")
sdk = os.environ.get("SDKROOT", str(stable_sdk) if stable_sdk.exists() else sdk)
testing = "--test" in sys.argv
sparkle_dir = sparkle()
command = ["xcrun", "swiftc", "-Onone" if testing else "-O", "-whole-module-optimization", "-swift-version", "5", "-default-isolation", "MainActor",
           "-target", f"{platform.machine()}-apple-macosx26.0", "-sdk", sdk, "-module-name", EXECUTABLE,
           "-module-cache-path", str(out / "ModuleCache"), "-o", str(out / "FiletorRegression" if testing else macos / EXECUTABLE)]
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
    command += [str(p) for p in sorted((root / "Tests").glob("*Regression.swift"))]
    subprocess.run(command, check=True)
    test_args = [arg for arg in sys.argv[1:] if arg != "--test"]
    subprocess.run([str(out / "FiletorRegression"), "-AppleLanguages", "(en)"] + test_args, check=True, timeout=180)
    if not test_args:
        subprocess.run([str(out / "FiletorRegression"), "-AppleLanguages", "(en)", "--navigation-scene"], check=True, timeout=60)
        subprocess.run([str(out / "FiletorRegression"), "-AppleLanguages", "(zh-Hans)", "--localization-only"], check=True, timeout=60)
        subprocess.run([str(out / "FiletorRegression"), "-AppleLanguages", "(zh-Hans)", "--navigation-scene"], check=True, timeout=60)
    sys.exit(0)
subprocess.run(command, check=True)
info = {
    "CFBundleExecutable": EXECUTABLE, "CFBundleIdentifier": BUNDLE_ID,
    "CFBundleName": PRODUCT_NAME, "CFBundleDisplayName": PRODUCT_NAME,
    "CFBundlePackageType": "APPL", "CFBundleShortVersionString": CONFIG["version"],
    "CFBundleVersion": str(CONFIG["build"]), "LSMinimumSystemVersion": CONFIG["minimum_system_version"],
    "CFBundleDevelopmentRegion": "en", "CFBundleLocalizations": ["en", "zh-Hans"],
    "NSHighResolutionCapable": True, "LSApplicationCategoryType": "public.app-category.utilities",
    "SUFeedURL": FEED_URL, "SUPublicEDKey": CONFIG["public_ed_key"],
    "SUEnableAutomaticChecks": True, "SUAutomaticallyUpdate": True,
    "SUScheduledCheckInterval": 3600, "SUSendProfileInfo": False,
    "SUVerifyUpdateBeforeExtraction": True, "SURequireSignedFeed": True,
    "NSHumanReadableCopyright": "© 2026 David Praznik; Filetor Pro modifications © 2026 Doithoo.",
}
# The licensed icon is bundled with the source, so clean builds need no installed app.
shutil.copy2(root / "Resources/FiletorPro.icns", resources / "FiletorPro.icns")
info["CFBundleIconFile"] = "FiletorPro"
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
if os.environ.get("FILETOR_ADHOC_BUILD") == "1":
    # Explicit opt-in for contributors without this product's private key.
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
else:
    code_signing.sign(app)
print(app)
