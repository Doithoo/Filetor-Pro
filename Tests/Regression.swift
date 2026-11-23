import Foundation
import AppKit
import SwiftUI
import Sparkle
import Quartz

@main
struct Regression {
    static let delegate = RegressionAppDelegate()
    static let fm = FileManager.default
    static var checks = 0
    static var recoveryItems: [URL] = []

    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw FileOperationSafety.failure("FAIL: " + message) }
        checks += 1
        print("PASS: " + message)
    }

    static func folder(_ root: URL, _ name: String) throws -> URL {
        let url = root.appending(path: name)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }

    static func file(_ root: URL, _ name: String, _ contents: String = "fixture") throws -> URL {
        let url = root.appending(path: name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    static func contents(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "<missing>" }

    static func until(_ description: String, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw FileOperationSafety.failure("Timed out: " + description)
    }

    static func engine(_ move: Bool = false, _ choice: ConflictChoice = .replace, control: TransferControl = TransferControl()) -> TransferEngine {
        TransferEngine(move: move, control: control, preset: choice) { _ in ConflictAnswer(choice: .stop, applyToAll: false) }
    }

    static func renameTests(_ root: URL) throws {
        let dir = try folder(root, "rename")
        let a = try file(dir, "A.txt", "A"), b = try file(dir, "B.txt", "B")
        let moves = [(from: a, to: b), (from: b, to: a)]
        try RenameTransaction.run(moves)
        try check(contents(a) == "B" && contents(b) == "A", "rename swaps without overwriting")
        for failAt in [2, 4] {
            var calls = 0
            do {
                try RenameTransaction.run(moves) { from, to in
                    calls += 1
                    if calls == failAt { throw FileOperationSafety.failure("injected move failure") }
                    try fm.moveItem(at: from, to: to)
                }
                throw FileOperationSafety.failure("Injected failure did not fire")
            } catch {
                try check(contents(a) == "B" && contents(b) == "A", "rename phase \(failAt == 2 ? 1 : 2) failure restores all original names and contents")
                try check((try fm.contentsOfDirectory(atPath: dir.path)).count == 2, "rename rollback removes staging names")
            }
        }
        let lower = dir.appending(path: "a.txt")
        try RenameTransaction.run([(a, lower)])
        try check((try fm.contentsOfDirectory(atPath: dir.path)).contains("a.txt"), "case-only rename")
        let parent = try folder(root, "parent"), child = try file(parent, "child")
        do {
            try RenameTransaction.run([(parent, root.appending(path: "renamed")), (child, parent.appending(path: "renamed-child"))])
            throw FileOperationSafety.failure("Expected parent-child rejection")
        } catch {
            try check(FileOperationSafety.exists(child), "parent/child rename rejected before mutation")
        }
        try check(!FileOperationSafety.validName("../escape") && !FileOperationSafety.validName("..") && !FileOperationSafety.validName("a\0b"), "invalid names rejected")
    }

    static func transferTests(_ root: URL) async throws {
        let source = try folder(root, "source"), nested = try folder(source, "nested")
        let original = try file(source, "data.txt", "original")
        let alias = root.appending(path: "alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: source)
        for destination in [source, nested, alias] {
            let e = engine()
            let failures = await e.run(items: [(source, destination)])
            try check(!failures.isEmpty && e.records.isEmpty, "self/descendant/alias copy is rejected: \(destination.lastPathComponent)")
        }
        try check(!FileOperationSafety.contains(source, root.appending(path: "source-other")), "containment respects path component boundaries")
        try check(FileOperationSafety.topLevel([source, nested, original, source]) == [source], "tree selection removes duplicates and selected descendants")
        let dest = try folder(root, "destination")
        let e = engine()
        let failures = await e.run(items: [(source, dest), (original, dest)])
        try check(failures.isEmpty && e.records.count == 1, "parent/child selection copies once")
        try check(contents(dest.appending(path: "source/data.txt")) == "original", "directory copy retains file contents")
        let cancelled = TransferControl(); cancelled.cancelled = true
        let stopped = engine(control: cancelled)
        _ = await stopped.run(items: [(source, dest)])
        try check(stopped.records.isEmpty, "cancelled copy produces no result")
        let replacement = try file(dest, "data.txt", "old destination")
        let replacing = engine(true)
        let replaceFailures = await replacing.run(items: [(original, dest)])
        recoveryItems += replacing.records.compactMap(\.trashed)
        try check(replaceFailures.isEmpty && !FileOperationSafety.exists(original) && contents(replacement) == "original", "move replacement commits before source removal")
        try check(replacing.records.first?.trashed.map(contents) == "old destination", "replacement preserves prior destination")
        let history = TransferHistory(replacing.records)
        try check(history.undo() == nil && contents(original) == "original" && contents(replacement) == "old destination", "undo replacement restores source and old destination")
        try check(history.redo() == nil && contents(replacement) == "original" && !FileOperationSafety.exists(original), "redo replacement restores exact transferred item")
        try check(history.undo() == nil && contents(original) == "original", "second undo succeeds")

        let retrySource = try folder(root, "retry-source"), retryDest = try folder(root, "retry-dest")
        let x = try file(retrySource, "x", "X"), y = try file(retrySource, "y", "Y")
        let moving = engine(true)
        _ = await moving.run(items: [(x, retryDest), (y, retryDest)])
        let retryHistory = TransferHistory(moving.records)
        _ = try file(retrySource, "x", "unrelated")
        try check(retryHistory.undo() != nil && contents(y) == "Y" && contents(x) == "unrelated", "partial undo preserves unrelated colliding file")
        try fm.removeItem(at: x)
        try check(retryHistory.undo() == nil && contents(x) == "X" && contents(y) == "Y", "retry undo skips already completed items")
        _ = try file(retryDest, "y", "do not replace")
        try check(retryHistory.redo() != nil && contents(retryDest.appending(path: "y")) == "do not replace", "redo never silently replaces a newly created file")
        try fm.removeItem(at: retryDest.appending(path: "y"))
        try check(retryHistory.redo() == nil && contents(retryDest.appending(path: "x")) == "X", "retry redo skips completed items")
        let retired = try folder(root, "retired-source")
        _ = try file(retired, "first")
        _ = try file(retired, "second")
        let remainder = try SourceRetirement.run(retired) { staged in
            try fm.removeItem(at: staged.appending(path: "first"))
            throw FileOperationSafety.failure("injected partial source cleanup failure")
        }
        try check(!FileOperationSafety.exists(retired) && remainder.map { FileOperationSafety.exists($0.appending(path: "second")) } == true, "partial source cleanup cannot masquerade as a complete original")
    }

    static func archiveTests(_ root: URL) throws {
        let a = try folder(root, "archive a"), b = try folder(root, "archive b"), out = try folder(root, "archives")
        let one = try file(a, "same.txt", "first"), two = try file(b, "same.txt", "second")
        let dash = try file(a, "-odd.txt", "third")
        try check(FileTools.compress([one, two, dash], in: out) == nil, "compress nested selections with spaces, duplicate basenames and leading dash")
        let extracted = try folder(root, "extracted")
        try check(FileTools.run("/usr/bin/ditto", ["-x", "-k", out.appending(path: "Archive.zip").path, extracted.path]) == nil, "archive can be extracted")
        try check(contents(extracted.appending(path: "archive a/same.txt")) == "first" && contents(extracted.appending(path: "archive b/same.txt")) == "second", "archive includes exact selected paths")
        try check(FolderAnalysis.hash(one) != nil && FolderAnalysis.hash(a) == nil && FolderAnalysis.hash(a.appending(path: "missing")) == nil, "hash errors are not mistaken for EOF")
    }

    static func paneTests(_ root: URL) async throws {
        let dir = try folder(root, "tree"), a = try folder(dir, "A"), b = try folder(a, "B"), empty = try folder(dir, "Empty")
        let leaf = try file(b, "leaf.txt")
        let pane = PaneModel(url: dir)
        pane.setVisible(true)
        defer { pane.stop() }
        try await until("initial listing") { !pane.loading }
        try check(pane.sortedItems.count == 2, "initial tree shows only root children")
        pane.expand(a)
        try await until("expand A") { !pane.loadingFolders.contains(a) }
        pane.expand(b)
        try await until("expand B") { !pane.loadingFolders.contains(b) }
        try check(pane.sortedItems.contains { $0.url == leaf } && pane.level(of: leaf) == 2, "nested folder expansion and indentation")
        pane.expand(empty)
        try await until("empty folder") { !pane.loadingFolders.contains(empty) }
        try check(pane.expanded.contains(empty), "empty folder remains visibly expanded")
        pane.selection = [leaf]
        pane.reloadKeepingSelection()
        try await until("refresh tree") { !pane.loading }
        try check(pane.selection.contains(leaf) && pane.expanded.contains(b), "refresh preserves deep selection and expansion")
        let snapshot = PaneSnapshot(pane)
        let restored = snapshot.makePane()
        restored.setVisible(true)
        try await until("restored tree") { !restored.loading }
        try check(restored.sortedItems.contains { $0.url == leaf }, "session restores expanded descendants")
        restored.stop()
        pane.collapse(a)
        try check(!pane.sortedItems.contains { $0.url == leaf } && !pane.selection.contains(leaf), "collapse removes hidden descendants from selection")
        pane.expand(a)
        pane.navigate(to: root)
        pane.navigate(to: dir)
        try await until("rapid navigation") { !pane.loading && pane.loadingFolders.isEmpty }
        try check(pane.currentURL == dir && pane.items.allSatisfy { $0.url.deletingLastPathComponent() == dir }, "stale expansion results cannot overwrite a new location")
        pane.expand(a)
        try await until("re-expand") { !pane.loadingFolders.contains(a) }
        let added = try file(a, "new-child.txt")
        try await until("recursive event refresh") { pane.sortedItems.contains { $0.url == added } }
        try check(pane.sortedItems.contains { $0.url == added }, "deep filesystem changes refresh expanded folders")
        pane.setVisible(false)
        try check(!pane.isVisible && pane.loadingFolders.isEmpty, "inactive tab stops background work")
        let app1 = AppModel(), app2 = AppModel()
        app1.groups[0].current.navigate(to: dir)
        app2.groups[0].current.navigate(to: a)
        app1.newTab()
        try check(app1.groups[0].tabs.count == 2 && app2.groups[0].tabs.count == 1 && app2.active.currentURL == a, "windows have independent tabs and locations")
        app1.active.expanded = [b]
        app1.closeTab()
        app1.activeGroup.reopen()
        try check(app1.active.expanded.contains(b), "reopen closed tab restores expansion")
        app1.stop(); app2.stop()
    }

    static func managerTests(_ root: URL) async throws {
        let source = try folder(root, "manager-src"), dest = try folder(root, "manager-dst")
        let original = try file(source, "conflict", "source")
        _ = try file(dest, "conflict", "target")
        let manager = TransferManager()
        manager.start(items: [(original, dest)], move: false)
        try await until("conflict sheet") { manager.pending != nil }
        let second = TransferManager()
        second.start(items: [(original, dest)], move: false)
        try await Task.sleep(for: .milliseconds(60))
        try check(second.pending == nil, "file jobs serialize across windows")
        second.cancel(second.jobs[0])
        try await until("queued cancellation") { second.jobs.isEmpty }
        manager.cancel(manager.jobs[0])
        try await until("conflict cancellation") { !manager.hasActive }
        try check(manager.pending == nil && contents(original) == "source" && contents(dest.appending(path: "conflict")) == "target", "cancel resumes conflict continuation without touching either file")
    }

    static func nativeUITests(_ root: URL) async throws {
        let dir = try folder(root, "Native List"), parent = try folder(dir, "Projects"), child = try folder(parent, "Design")
        _ = try file(child, "Notes.txt", "Native folder expansion")
        _ = try folder(dir, "Empty Folder")
        let pane = PaneModel(url: dir)
        let app = AppModel()
        app.groups[0].tabs = [pane]
        app.activeIndex = 0
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 940, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Filetor Pro — Folder Expansion Test"
        let host = NSHostingView(rootView: PaneContainer(app: app, index: 0))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close(); app.stop() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        try await until("native table") { !pane.loading && descendants(host).contains { ($0 as? NSTableView)?.numberOfRows == 2 } }
        guard let table = descendants(host).compactMap({ $0 as? NSTableView }).first,
              let row = pane.sortedItems.firstIndex(where: { $0.url == parent }),
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true),
              let button = descendants(cell).compactMap({ $0 as? NSButton }).first else {
            throw FileOperationSafety.failure("Missing native disclosure button")
        }
        button.performClick(nil)
        try await until("disclosure click") { table.numberOfRows == 3 }
        try check(pane.expanded.contains(parent), "native disclosure button expands folder")
        let childRow = pane.sortedItems.firstIndex(where: { $0.url == child })!
        table.selectRowIndexes(IndexSet(integer: childRow), byExtendingSelection: false)
        let right = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124)!
        table.keyDown(with: right)
        try await until("keyboard expansion") { table.numberOfRows == 4 }
        try check(pane.expanded.contains(child), "native Right Arrow expands selected folder")
        host.layoutSubtreeIfNeeded()
        let snapshotView: NSView = host
        if let bitmap = snapshotView.bitmapImageRepForCachingDisplay(in: snapshotView.bounds) {
            snapshotView.cacheDisplay(in: snapshotView.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                let output = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appending(path: "folder-expansion.png")
                try data.write(to: output)
                print("Native UI snapshot: \(output.path)")
            }
        }
        let left = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 123)!
        table.keyDown(with: left)
        try await until("keyboard collapse") { table.numberOfRows == 3 }
        try check(!pane.expanded.contains(child), "native Left Arrow collapses selected folder")

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(table)
        try await Task.sleep(for: .milliseconds(100))
        let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil, characters: " ",
                                    charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        table.keyDown(with: space)
        let preview = SystemQuickLook.shared
        let panel = QLPreviewPanel.shared()!
        try await until("folder Quick Look") { panel.isVisible && panel.currentController as AnyObject? === preview }
        try check(panel.currentPreviewItem?.previewItemURL == child, "Space sends folders to the system preview panel")
        try check(preview.previewPanel(panel, handle: space), "Space closes the system preview")
        try await until("preview closes") { !panel.isVisible }

        let archive = dir.appending(path: "Example.zip")
        try check(FileTools.run("/usr/bin/ditto", ["-c", "-k", parent.path, archive.path]) == nil, "create native preview archive fixture")
        try await until("archive appears") { pane.sortedItems.contains { $0.url == archive } && table.numberOfRows == pane.sortedItems.count }
        let archiveRow = pane.sortedItems.firstIndex { $0.url == archive }!
        table.selectRowIndexes(IndexSet(integer: archiveRow), byExtendingSelection: false)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(table)
        table.keyDown(with: space)
        try await until("archive Quick Look") { panel.isVisible && panel.currentPreviewItem?.previewItemURL == archive }
        try check(panel.currentController as AnyObject? === preview, "Space sends archives to the same system preview panel")

        let parentRow = pane.sortedItems.firstIndex { $0.url == parent }!
        table.selectRowIndexes(IndexSet(integer: parentRow), byExtendingSelection: false)
        try check(panel.currentPreviewItem?.previewItemURL == parent, "system preview follows list selection")
        let selectedBeforePreview = pane.selection
        app.quickLook([dir])
        try check(panel.currentPreviewItem?.previewItemURL == dir && pane.selection == selectedBeforePreview,
                  "explicit folder preview does not change file selection")

        app.quickLook([archive, parent])
        try check(preview.urls == pane.sortedItems.map(\.url).filter { $0 == archive || $0 == parent }
                  && preview.numberOfPreviewItems(in: panel) == 2, "toolbar and context previews preserve display order and multiple items")
        let leaf = child.appending(path: "Notes.txt")
        app.quickLook([leaf])
        try check(panel.currentPreviewItem?.previewItemURL == leaf, "column descendant files use native preview even outside the visible root list")

        let other = AppModel()
        let otherWindow = NSWindow(contentRect: NSRect(x: 180, y: 180, width: 600, height: 300),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        defer { other.stop(); otherWindow.close() }
        otherWindow.makeKeyAndOrderFront(nil)
        other.quickLook([archive])
        try check(panel.currentController as AnyObject? === preview && panel.currentPreviewItem?.previewItemURL == archive
                  && window.nextResponder !== preview, "another window can take preview ownership without leaving a responder attached")
        app.refreshQuickLook()
        preview.close(owner: app)
        try check(panel.currentPreviewItem?.previewItemURL == archive && panel.isVisible,
                  "inactive windows cannot replace or close another window's preview")
        other.active.selection = []
        other.refreshQuickLook()
        try await until("empty selection closes preview") { !panel.isVisible }
        try check(preview.urls.isEmpty && otherWindow.nextResponder !== preview,
                  "clearing selection closes preview and restores the responder chain")
        other.quickLook([parent])
        other.stop()
        try await until("closing workspace closes preview") { !panel.isVisible }
        try check(preview.urls.isEmpty, "closing the owning workspace releases its preview")
    }

    static func updateTests(_ root: URL) async throws {
        let domain = "FiletorUpdatePreferences-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(false, forKey: "autoUpdate")
        defaults.set(Data("toolbar fixture".utf8), forKey: "toolbar.entries.v1")
        AutomaticUpdateSettings.migratePreferences(defaults)
        try check(!defaults.bool(forKey: "SUEnableAutomaticChecks") && !defaults.bool(forKey: "SUAutomaticallyUpdate"), "combined updates preserve a disabled legacy preference")
        defaults.set(true, forKey: "SUEnableAutomaticChecks")
        defaults.set(true, forKey: "SUAutomaticallyUpdate")
        AutomaticUpdateSettings.migratePreferences(defaults)
        try check(defaults.bool(forKey: "SUEnableAutomaticChecks") && defaults.bool(forKey: "SUAutomaticallyUpdate"), "combined migration does not override a later user choice")
        try check(defaults.data(forKey: "toolbar.entries.v1") == Data("toolbar fixture".utf8), "updater preference migration preserves toolbar configuration")
        for (checks, downloads) in [(false, false), (false, true), (true, false), (true, true)] {
            defaults.removePersistentDomain(forName: domain)
            defaults.set(checks, forKey: "SUEnableAutomaticChecks")
            defaults.set(downloads, forKey: "SUAutomaticallyUpdate")
            AutomaticUpdateSettings.migratePreferences(defaults)
            try check(defaults.bool(forKey: "SUEnableAutomaticChecks") == checks && defaults.bool(forKey: "SUAutomaticallyUpdate") == checks,
                      "combined migration preserves check choice for \(checks)/\(downloads)")
        }
        defaults.removePersistentDomain(forName: domain)
        AutomaticUpdateSettings.migratePreferences(defaults)
        try check(defaults.bool(forKey: "SUEnableAutomaticChecks") && defaults.bool(forKey: "SUAutomaticallyUpdate"), "new installations enable the complete automatic update cycle")
        defaults.set(false, forKey: "SUEnableAutomaticChecks")
        defaults.set(false, forKey: "SUAutomaticallyUpdate")
        AutomaticUpdateSettings.migratePreferences(defaults)
        try check(!defaults.bool(forKey: "SUEnableAutomaticChecks") && !defaults.bool(forKey: "SUAutomaticallyUpdate"), "automatic update opt-out survives subsequent launches")
        let app1 = AppModel(), app2 = AppModel()
        defer { app1.stop(); app2.stop() }
        try check(app1.updater === app2.updater, "all windows share one updater")
        let job = TransferJob(title: "Update restart guard")
        app2.transfers.jobs.append(job)
        try check(AppModel.hasActiveFileOperations, "update restart guard sees operations in another window")
        job.isFinished = true
        app2.transfers.jobs.removeAll()
        try check(!AppModel.hasActiveFileOperations, "completed operations release the update restart guard")
        let archiveRoot = try folder(root, "update-archive")
        let document = try file(archiveRoot, "document.txt")
        app1.active.navigate(to: archiveRoot)
        app1.compress([document])
        try check(AppModel.hasActiveFileOperations, "background compression blocks restart before its task begins")
        try await until("background archive finishes") { !AppModel.hasActiveFileOperations }
        try check(app1.backgroundWrites == 0, "background write tracking clears after compression")
        try check(UpdateChecker.shared.feedURLString(for: SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil).updater) == "https://github.com/Doithoo/Filetor-Pro/releases/latest/download/appcast.xml" && UpdateChecker.repo == "Doithoo/Filetor-Pro", "updater uses the canonical Filetor Pro repository feed")

        let host = NSHostingView(rootView: SettingsSheet(app: app1).background(Color(nsColor: .windowBackgroundColor)))
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                let output = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appending(path: "settings-updates.png")
                try data.write(to: output)
                print("Settings snapshot: \(output.path)")
            }
        }
    }

    @MainActor static func main() {
        setbuf(stdout, nil)
        if CommandLine.arguments.contains("--navigation-scene") {
            NSApplication.shared.setActivationPolicy(.regular)
            NavigationRegressionScene.main()
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }

    @MainActor static func runTests() async {
        // A prior failed run exits before its defer; start from the test app's
        // own clean preferences so restored test windows cannot leak across runs.
        UserDefaults.standard.removePersistentDomain(forName: "FiletorRegression")
        let root = fm.temporaryDirectory.appending(path: "FiletorRegression-\(UUID().uuidString)")
        defer {
            try? fm.removeItem(at: root)
            recoveryItems.forEach { try? fm.removeItem(at: $0) }
            UserDefaults.standard.removePersistentDomain(forName: "FiletorRegression")
        }
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: false)
            if CommandLine.arguments.contains("--navigation-workspace-only") {
                try await navigationWorkspaceUITests(root)
            } else if CommandLine.arguments.contains("--trash-only") {
                try await trashDeletionTests(root)
            } else if CommandLine.arguments.contains("--sidebar-toolbar-only") {
                try await sidebarToolbarTests(root)
            } else if CommandLine.arguments.contains("--navigation-only") {
                try await navigationTests(root)
            } else {
                try renameTests(root)
                try await transferTests(root)
                try archiveTests(root)
                try await paneTests(root)
                try await managerTests(root)
                try await nativeUITests(root)
                try await updateTests(root)
                try await browsingTests(root)
                try await navigationTests(root)
                try await sidebarToolbarTests(root)
                try await trashDeletionTests(root)
            }
            print("\nAll \(checks) regression checks passed.")
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

final class RegressionAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        Task {
            await Regression.runTests()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
