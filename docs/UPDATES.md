# Filetor Pro release workflow

The application updates only from `Doithoo/Filetor-Pro`. The feed URL is:

```text
https://github.com/Doithoo/Filetor-Pro/releases/latest/download/appcast.xml
```

Sparkle 2.10.1 performs downloading, Ed25519 validation, installation and relaunch using native macOS components. The application uses a single shared updater for all windows. Its standard interface supplies progress, cancellation, release notes and error feedback. A single switch controls automatic checking, downloading and installation on quit. The old check preference (including legacy `autoUpdate`) migrates once to both Sparkle settings, preserving opt-outs and toolbar settings. Changes made in Sparkle’s own update dialog are reflected in the combined switch. Manual checks remain available when automatic updates are off.

The signed feed specifies an increasing numeric build, Apple Silicon hardware and macOS 26 or later. The archive is verified before extraction. Release notes are embedded as plain text. No authentication token or signing private key is shipped in the app.

## Publish the next improvement

1. Implement and review the change. Use standard `MAJOR.MINOR.PATCH` versions (for example `0.3.1` or `0.4.0`). Increment `version` and `build` in `scripts/release-config.json`; keep `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `Filetor.xcodeproj/project.xcproj` aligned. The build must be greater than the previous release, even when the visible version changes.
2. Write `docs/releases/<version>.md`. Keep release descriptions suitable for the Filetor Pro repository's public repository.
3. Run `python3 scripts/build.py --test`. For updater changes, also run `python3 scripts/test-updater.py`.
4. Commit the intended source changes with an English Conventional Commit, then push the branch to `origin` (`Doithoo/Filetor-Pro`). Do not create an upstream pull request.
5. Run `python3 scripts/release.py`. It requires a clean checkout, runs regression checks, builds, verifies the application signature, creates a ZIP preserving framework symlinks, signs both archive and appcast, and records the source commit plus checksums under `.build/releases/<version>/`.
6. Run `python3 scripts/release.py --publish`. It verifies the prepared files, signing key, pushed source commit and increasing build; uploads to a draft release; checks the uploaded assets; then makes the release public and latest. Interrupted uploads leave a draft that can be retried. Published versions are immutable: use a new version for any correction.

Git commits alone do not create installable updates. Complete the release steps after each improvement that should reach the installed app. Publishing never needs access to the upstream repository and creates no pull request there.

## Signing and settings

The release key is stored in the macOS login Keychain under the Sparkle account `com.doithoo.Filetor.personal`. Only its public key is committed in `scripts/release-config.json` and `Filetor/Info.plist`. Release signing runs on this Mac. To transfer publishing to another machine, use Sparkle's documented Keychain export/import procedure privately; never commit private keys or place them in an app bundle.

The installed bundle identifier stays `com.doithoo.Filetor.personal`. New installations use `/Applications/Filetor Pro.app`; Sparkle may preserve a pre-existing installation filename while changing the visible product name and executable. Keep the bundle ID and signing account stable through branding changes. Repository renames must preserve the old URL redirect and verify updates from an existing installation before retiring the old address. Preferences survive replacement, including the toolbar configuration imported from the original application. The first upgrade from `0.2.0-personal.1` requires one manual replacement because that version contains no installer; subsequent releases use the application updater.

This is an Apple Silicon distribution. The application is ad hoc code signed, not Developer ID signed or notarized. Signed Sparkle updates have been tested with that identity on the local Mac. Initial installation on another Mac may require macOS approval. Release signing keys and Apple code signing identities serve different purposes.

## Verification

`Tests/Regression.swift` covers preference migration without toolbar resets, a shared updater across windows, and restart protection for active file operations. `scripts/test-updater.py` builds disposable applications with unique bundle identifiers and a loopback feed. It verifies actual upgrades and relaunches with preserved preferences, including Filetor Personal to Filetor Pro name and executable changes and silent background downloading followed by installation on quit, rejects tampered archives and feeds, and exercises no-update and HTTP failure responses. It never replaces the installed Filetor or writes its preference domain.

The release preparation command uses `scripts/build.py`, which embeds the full verified Sparkle framework. The Xcode project also declares the pinned package; the Command Line Tools release path is the validated build on this machine.

## Branding and continuity

Product name and executable are defined in `scripts/release-config.json`. The native interface uses `Filetor/ProductInfo.swift`; keep Xcode product settings aligned. Published releases are titled `Filetor Pro <version>` and contain `Filetor-Pro-<version>-arm64.zip`. Historical release tags and notes are retained unchanged. Use `scripts/build.py` and `scripts/release.py`; the obsolete personal-build wrappers have been removed.

Version `0.3.0` / build `3` follows `0.2.0-personal.2` / build `2`. Sparkle compares numeric builds, so the branding change does not interrupt upgrading.

Version `0.3.3` / build `6` adopts the independent repository's new name, `Doithoo/Filetor-Pro`. Versions through `0.3.2` contain the old `Doithoo/Filetor` update address and rely on GitHub's rename redirect to reach the same signed feed. Keep the old repository name unused: creating another repository at `Doithoo/Filetor` would break that redirect. Historical signed feeds and archives are retained byte-for-byte; their embedded old download URLs also use the redirect. Verify the old client's Sparkle update check as well as the new feed when changing this routing.
