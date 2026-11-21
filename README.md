# Filetor Pro

A lightweight, native file manager for macOS, maintained by **Doithoo**. Built with SwiftUI and AppKit, with independent windows, tabs, a dual-pane workspace and inline folder expansion.

Filetor Pro is developed independently by Doithoo, building on [Filetor by David Praznik](https://github.com/davidpraznik/Filetor). It preserves the original project's native approach, commit history, MIT license and author attribution while maintaining its own roadmap and releases.

## Everyday browsing

- **Inline folder expansion** in list view: open the disclosure triangle, use the Right/Left arrow keys, or expand selected folders from the View menu. Browse nested folders without leaving the current list.
- **Independent windows** with `⌘N`. Each window has its own folders, tabs, selections and undo history.
- **Tabs in each pane**: one always-visible New Tab button, plus create, reorder, close and reopen actions; restore folders, views, sorting and expansion state across launches.
- **A customizable toolbar** with your choice of tools, order and labels.
- Single or dual panes, list/icon/column views, breadcrumbs, favorites, mounted disks and network locations.
- Finder tags, saved searches, subfolder search, Quick Look and an optional information panel.
- **Local search** with `⌘F`: combine name, kind, extension, modification date and size, in the current folder or its subfolders.
- **Go To toolbar button**: browse folders, sidebar favorites and recent locations in a native popover. Click a folder name to open it or its arrow to browse deeper; each breadcrumb also has a subfolder dropdown. Path entry, `⇧⌘G` and Tab completion remain available.
- Categorized settings with independent list row height and grid icon size, safe extension hiding, and optional native file thumbnails (off by default).

Press **Space** on a file or folder to open native macOS Quick Look in any view. The toolbar, context menu and information panel's **Quick Look** button use the same system preview, including enabled extensions such as Looq. Space or Escape closes it; list selection changes update the preview. The information panel itself shows metadata and a thumbnail. Preview formats and rendering depend on the extensions selected by macOS, just as in Finder.

## File tools

Copy, move, rename, duplicate, Trash, batch rename, compress and extract archives. Transfers include progress, cancellation and conflict handling. File operations use a shared queue across windows, staged copying and recovery paths for failed replacements.

Image conversion and optimization, metadata removal, duplicate finding, folder comparison, synchronization and project-folder templates are also available. `⌘K` opens the action palette; `⌥⌘K` shows keyboard shortcuts.

The app keeps its native interface and small footprint: no Electron runtime, embedded browser or always-running update service.

## Install and update

Current release: **Filetor Pro 0.5.1**. Requires **Apple Silicon and macOS 26 or later** for the published build.

Download `Filetor-Pro-<version>-arm64.zip` from [this repository's Releases](https://github.com/Doithoo/Filetor-Pro/releases/latest), unzip it, and move **Filetor Pro.app** to Applications.

Existing `0.2.0-personal.2` users can choose **Check for Updates…** in the app. Filetor Pro preserves the existing preferences identity, including toolbar layout, labels, sidebar and workspaces. The installed filename may stay unchanged during an in-app update; the product shown in menus and settings becomes Filetor Pro.

Settings has one **Automatically check for and install updates** switch. When enabled, updates download in the background and install when you quit. The manual check can install and restart immediately. Updates are downloaded, verified, installed and relaunched by Sparkle; relaunch waits for active file operations. Only Filetor Pro releases from **Doithoo/Filetor-Pro** are offered. Committing code alone does not publish an update: each release must be built, signed and published.

The app currently uses ad hoc code signing, without Developer ID signing or notarization. A first installation may need approval under **System Settings → Privacy & Security → Open Anyway**. Full Disk Access is optional and may need to be granted again after an update. The update archive and feed are separately protected by Ed25519 signatures.

## Development

```sh
python3 scripts/build.py --test
python3 scripts/test-updater.py
python3 scripts/build.py
open ".build/pro/Filetor Pro.app"
```

See the [development and verification guide](docs/DEVELOPMENT.md) for prerequisites and current limitations, and the [release workflow](docs/UPDATES.md) for publishing signed updates. The source includes the application icon; a clean build does not require an existing installation.

The [repository layout and cleanup guide](docs/DEVELOPMENT.md#项目目录与清理) explains which files belong in source control and where generated files and local backups should live.

Versions use `MAJOR.MINOR.PATCH`, starting with `0.3.0` under the Filetor Pro name. Each release also increments its numeric build. The independent repository is **Doithoo/Filetor-Pro**. Version `0.3.3` uses its new update address; older versions reach it through GitHub's redirect from `Doithoo/Filetor`. The internal bundle identifier and update signing key remain stable so existing installations retain settings and can keep updating.

## Privacy, attribution and feedback

File operations run locally. Update checks and downloads contact GitHub; the updater does not upload file contents or send Sparkle system profiles. Network file access and external applications run only as requested by the user.

Please report Filetor Pro issues in [this repository's issue tracker](https://github.com/Doithoo/Filetor-Pro/issues).

Original Filetor and its icon: **David Praznik**. Filetor Pro modifications: **Doithoo**. Source is provided under the [MIT license](LICENSE). Sparkle and optional libwebp retain their respective bundled licenses.
