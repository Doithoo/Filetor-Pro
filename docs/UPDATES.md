# Personal release workflow

The application updates only from `Doithoo/Filetor`. The feed URL is:

```text
https://github.com/Doithoo/Filetor/releases/latest/download/appcast.xml
```

Sparkle 2.10.1 performs downloading, Ed25519 validation, installation and relaunch using native macOS components. The application uses a single shared updater for all windows. Its standard interface supplies progress, cancellation, release notes and error feedback. Automatic checks and downloads are separate user preferences. An existing `autoUpdate` preference migrates once, without overwriting subsequent choices or toolbar settings.

The signed feed specifies an increasing numeric build, Apple Silicon hardware and macOS 26 or later. The archive is verified before extraction. Release notes are embedded as plain text. No authentication token or signing private key is shipped in the app.

## Publish the next improvement

1. Implement and review the change. Increment `version` and `build` in `scripts/release-config.json`; keep `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `Filetor.xcodeproj/project.xcproj` aligned. The build must be greater than the previous release, even when the visible version changes.
2. Write `docs/releases/<version>.md`. Keep release descriptions suitable for the personal fork's public repository.
3. Run `python3 scripts/build-personal.py --test`. For updater changes, also run `python3 scripts/test-updater.py`.
4. Commit the intended source changes with an English Conventional Commit, then push the branch to `origin` (`Doithoo/Filetor`). Do not create an upstream pull request.
5. Run `python3 scripts/release-personal.py`. It requires a clean checkout, runs regression checks, builds, verifies the application signature, creates a ZIP preserving framework symlinks, signs both archive and appcast, and records the source commit plus checksums under `.build/releases/<version>/`.
6. Run `python3 scripts/release-personal.py --publish`. It verifies the prepared files, signing key, pushed source commit and increasing build; uploads to a draft release; checks the uploaded assets; then makes the release public and latest. Interrupted uploads leave a draft that can be retried. Published versions are immutable: use a new version for any correction.

Git commits alone do not create installable updates. Complete the release steps after each improvement that should reach the installed app. Publishing never needs access to the upstream repository and creates no pull request there.

## Signing and settings

The release key is stored in the macOS login Keychain under the Sparkle account `com.doithoo.Filetor.personal`. Only its public key is committed in `scripts/release-config.json` and `Filetor/Info.plist`. Release signing runs on this Mac. To transfer publishing to another machine, use Sparkle's documented Keychain export/import procedure privately; never commit private keys or place them in an app bundle.

The installed bundle identifier stays `com.doithoo.Filetor.personal` and the canonical installation stays `/Applications/Filetor.app`. Its preferences survive replacement, including the toolbar configuration imported from the original application. The first upgrade from `0.2.0-personal.1` requires one manual replacement because that version contains no installer; subsequent personal releases use the application updater.

This is an Apple Silicon personal distribution. The application is ad hoc code signed, not Developer ID signed or notarized. Signed Sparkle updates have been tested with that identity on the local Mac. Initial installation on another Mac may require macOS approval. Release signing keys and Apple code signing identities serve different purposes.

## Verification

`Tests/Regression.swift` covers preference migration without toolbar resets, a shared updater across windows, and restart protection for active file operations. `scripts/test-updater.py` builds disposable applications with unique bundle identifiers and a loopback feed. It verifies an actual upgrade and relaunch with preserved preferences, rejects tampered archives and feeds, and exercises no-update and HTTP failure responses. It never replaces the installed Filetor or writes its preference domain.

The release preparation command uses `scripts/build-personal.py`, which embeds the full verified Sparkle framework. The Xcode project also declares the pinned package; the Command Line Tools release path is the validated build on this machine.
