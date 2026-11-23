import AppKit
import SwiftUI

extension Regression {
    static func trashDeletionTests(_ base: URL) async throws {
        let root = try folder(base, "trash-deletion").resolvingSymlinksInPath()
        let trash = try folder(root, "Trash fixture")
        let nested = try folder(trash, "Nested")
        let child = try file(nested, "child")
        let hidden = try file(trash, ".hidden")
        let outside = try folder(root, "outside")
        let protected = try file(outside, "keep.txt", "keep")
        let link = trash.appending(path: "outside-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        let snapshot = try TrashDeletion.snapshot(root: trash)
        try check(Set(snapshot.items.map { $0.url.path }) == Set([nested, hidden, link].map(\.path)),
                  "empty Trash snapshot includes hidden items and folders independently of view filters")
        try check(FileOperationSafety.exists(child) && FileOperationSafety.exists(hidden),
                  "preparing a confirmation never deletes files")
        let late = try file(trash, "added-after-confirmation")
        for item in snapshot.items { try snapshot.remove(item) }
        try check(contents(protected) == "keep" && !FileOperationSafety.exists(link),
                  "deleting a Trash symbolic link preserves its external target")
        try check(FileOperationSafety.exists(trash) && FileOperationSafety.exists(late) && !FileOperationSafety.exists(child),
                  "empty Trash preserves its root and later additions while removing confirmed folders")
        let selected = try file(trash, "selected")
        let one = try TrashDeletion.snapshot(root: trash, selection: [selected])
        try one.remove(one.items[0])
        try check(FileOperationSafety.exists(late) && !FileOperationSafety.exists(selected),
                  "permanent selection deletion preserves unselected Trash items")
        let parent = try folder(trash, "parent"), leaf = try file(parent, "leaf")
        let tree = try TrashDeletion.snapshot(root: trash, selection: [parent, leaf])
        try check(tree.items.count == 1, "selected parent and child are removed only once")
        let replaced = try TrashDeletion.snapshot(root: trash, selection: [late])
        let moved = root.appending(path: "old-item")
        try fm.moveItem(at: late, to: moved)
        _ = try file(trash, late.lastPathComponent, "replacement")
        do {
            try replaced.remove(replaced.items[0])
            throw FileOperationSafety.failure("Replacement was deleted")
        } catch {
            try check(contents(late) == "replacement", "replacement at a confirmed path is not deleted")
        }
        for urls: Set<URL> in [[trash], [protected]] {
            let rejected = (try? TrashDeletion.snapshot(root: trash, selection: urls)) == nil
            try check(rejected && FileOperationSafety.exists(trash) && contents(protected) == "keep",
                      "Trash root and out-of-scope selections cannot be deleted")
        }
        let alias = root.appending(path: "redirected")
        try fm.createSymbolicLink(at: alias, withDestinationURL: trash)
        try check((try? TrashDeletion.snapshot(root: alias)) == nil && FileOperationSafety.exists(late),
                  "redirected Trash roots are rejected before deletion")
        let beforeReplace = try TrashDeletion.snapshot(root: trash)
        try fm.moveItem(at: trash, to: root.appending(path: "old-trash"))
        try fm.createDirectory(at: trash, withIntermediateDirectories: false)
        _ = try file(trash, late.lastPathComponent, "new-root")
        do {
            try beforeReplace.remove(beforeReplace.items.first { $0.url == late }!)
            throw FileOperationSafety.failure("Replaced root accepted")
        } catch {
            try check(contents(late) == "new-root", "a replaced Trash root stops deletion of the new directory contents")
        }
        let app = AppModel()
        defer { app.stop() }
        app.groups.forEach { $0.current.navigate(to: trash) }
        app.requestTrashDeletion(root: trash)
        try await until("non-Trash rejected") { !app.preparingTrashDeletion }
        try check(app.pendingTrashDeletion == nil && app.alert != nil && contents(late) == "new-root",
                  "production entry point refuses an ordinary directory")
        app.alert = nil
        let cancelSnapshot = try TrashDeletion.snapshot(root: trash)
        app.pendingTrashDeletion = cancelSnapshot
        let host = NSHostingView(rootView: Text("Trash confirmation test").frame(width: 650, height: 350).modifier(AppAlerts(app: app)))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 650, height: 350), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try await until("Trash confirmation appears") { window.attachedSheet != nil }
        let sheet = window.attachedSheet!
        if let view = sheet.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to:
                URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appending(path: "empty-trash-confirmation.png"))
        }
        try check(sheet.defaultButtonCell?.title == "Cancel", "Return defaults to Cancel in the native destructive confirmation")
        sheet.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: sheet.windowNumber, context: nil, characters: "\r",
                                        charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
        try await until("Trash confirmation cancelled") { app.pendingTrashDeletion == nil }
        try check(contents(late) == "new-root" && app.trashDeletionJob == nil,
                  "cancelling the native Trash confirmation leaves files untouched")
        let blocker = UUID()
        _ = await TransferScheduler.shared.acquire(blocker)
        app.pendingTrashDeletion = cancelSnapshot
        app.confirmTrashDeletion()
        try await Task.sleep(for: .milliseconds(80))
        try check(contents(late) == "new-root" && app.transfers.hasActive,
                  "Trash deletion waits for existing file operations and protects application restart")
        app.transfers.cancel(app.trashDeletionJob!)
        TransferScheduler.shared.release(blocker)
        try await until("queued Trash deletion cancelled") { app.trashDeletionJob == nil }
        try check(contents(late) == "new-root", "cancelling queued Trash deletion preserves every item")
        app.alert = nil
        let failed = try file(trash, "failure")
        let partial = try TrashDeletion.snapshot(root: trash)
        try fm.moveItem(at: failed, to: root.appending(path: "failure-original"))
        _ = try file(trash, "failure", "do-not-delete")
        app.pendingTrashDeletion = partial
        app.confirmTrashDeletion()
        try await until("partial Trash deletion finishes") { app.trashDeletionJob == nil }
        try check(!FileOperationSafety.exists(late) && contents(failed) == "do-not-delete"
                  && app.alert?.contains("failure") == true,
                  "partial deletion completes independent items and identifies skipped failures")
        app.alert = nil
        try await until("earlier confirmation closes") { window.attachedSheet == nil }
        app.pendingTrashDeletion = try TrashDeletion.snapshot(root: trash)
        try await until("final Trash confirmation appears") { window.attachedSheet != nil }
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        guard let sheetContent = window.attachedSheet?.contentView,
              let empty = buttons(sheetContent).first(where: { $0.title == "Empty Trash" }) else {
            throw FileOperationSafety.failure("Missing native Empty Trash confirmation button")
        }
        empty.performClick(nil)
        try await until("native confirm begins deletion") { app.pendingTrashDeletion == nil }
        try check(app.trashDeletionJob != nil || !FileOperationSafety.exists(failed),
                  "native Empty Trash confirmation starts the captured deletion")
        try await until("Trash deletion completes") { app.trashDeletionJob == nil }
        try check(try fm.contentsOfDirectory(atPath: trash.path).isEmpty,
                  "confirmed deletion empties the fixture and leaves the Trash directory intact")
        try check(app.alert == nil && !app.transfers.hasActive, "successful Trash deletion finishes progress without an error")
    }
}
