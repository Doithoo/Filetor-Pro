import AppKit
import SwiftUI

extension Regression {
    static func fileContextActionsTests(_ root: URL) async throws {
        let scratch = try folder(root, "Context Actions")
        let source = try folder(scratch, "Source"), destination = try folder(scratch, "Destination")
        let original = try file(source, "中文 笔记.txt", "keep me")
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        let clipboard = FileClipboard(pasteboard: pb)
        let app = AppModel()
        let left = PaneModel(url: source), right = PaneModel(url: destination)
        app.groups[0].tabs = [left]; app.groups[1].tabs = [right]
        defer { app.stop() }
        try await until("clipboard panes ready") { !left.loading && !right.loading }

        clipboard.write([original], cut: true)
        try check(contents(original) == "keep me" && clipboard.isCut, "Cut records intent without modifying the source")
        pb.clearContents(); pb.setString("plain text", forType: .string)
        try check(!clipboard.isCut && !clipboard.canPaste, "external text replaces stale cut intent and disables file paste")
        clipboard.write([original], cut: true)
        pb.clearContents(); pb.writeObjects([original as NSURL])
        try check(!clipboard.isCut && clipboard.canPaste, "external file copy is never interpreted as an old cut")
        clipboard.paste(into: destination, app: app)
        try await until("clipboard copy") { !app.transfers.hasActive }
        try check(contents(original) == "keep me" && contents(destination.appendingPathComponent(original.lastPathComponent)) == "keep me",
                  "file URL paste copies contents and preserves the original")
        try check(clipboard.canPaste && !clipboard.isCut && app.undoTitle?.hasPrefix("Undo Copy") == true, "copy paste stays reusable and enters undo history")

        let moveTarget = try folder(scratch, "Move Target")
        clipboard.write([original], cut: true)
        clipboard.paste(into: source, app: app)
        try check(!app.transfers.hasActive && clipboard.isCut && FileTools.exists(original), "same-folder cut paste is a harmless no-op")
        clipboard.paste(into: moveTarget, app: app)
        let activeCount = app.transfers.jobs.count
        clipboard.paste(into: destination, app: app)
        try check(app.transfers.jobs.count == activeCount && !clipboard.canPaste, "a pending cut cannot be pasted twice")
        try await until("clipboard move") { !app.transfers.hasActive }
        let moved = moveTarget.appendingPathComponent(original.lastPathComponent)
        try check(!FileTools.exists(original) && contents(moved) == "keep me" && !clipboard.canPaste,
                  "successful cut paste moves the item and consumes the cut clipboard")
        app.undo()
        try await until("clipboard move undo") { !app.historyBusy }
        try check(contents(original) == "keep me" && !FileTools.exists(moved), "cut paste can be undone without losing contents")

        clipboard.write([original], cut: true)
        clipboard.paste(into: destination, app: app)
        try await until("cut paste conflict") { app.transfers.pending != nil }
        app.transfers.cancel(app.transfers.jobs.first { !$0.isFinished }!)
        try await until("cancelled cut paste") { !app.transfers.hasActive }
        try check(clipboard.canPaste && clipboard.isCut && contents(original) == "keep me", "cancelled cut paste retains files and retryable cut intent")

        let second = try file(source, "other.txt", "second")
        clipboard.write([original, second], cut: true)
        clipboard.paste(into: destination, app: app)
        try await until("partial cut conflict") { app.transfers.pending != nil }
        app.transfers.answer(.skip, applyToAll: true)
        try await until("partial cut completion") { !app.transfers.hasActive }
        try check(clipboard.urls == [original] && clipboard.isCut && !FileTools.exists(second),
                  "partial cut paste leaves only skipped source files on the clipboard")

        clipboard.paste(into: destination, app: app)
        try await until("replacement clipboard conflict") { app.transfers.pending != nil }
        clipboard.write([destination.appendingPathComponent("other.txt")])
        app.transfers.answer(.skip, applyToAll: true)
        try await until("replacement clipboard completion") { !app.transfers.hasActive }
        try check(!clipboard.isCut && clipboard.urls == [destination.appendingPathComponent("other.txt")],
                  "finishing an old paste never overwrites a newer clipboard")

        let parent = try folder(source, "Parent"), child = try file(parent, "child.txt")
        clipboard.write([parent, child])
        try check(clipboard.urls == [parent], "copying a tree selection includes each subtree only once")
        clipboard.write([parent], cut: true)
        clipboard.paste(into: parent, app: app)
        try await until("invalid cut destination") { !app.transfers.hasActive }
        try check(clipboard.isCut && FileTools.exists(child) && app.alert != nil, "recursive cut paste reports failure and retains the original")
        app.alert = nil

        for kind in NewFileKind.allCases {
            let created = try FileCreation.create(kind, in: destination)
            try check(try Data(contentsOf: created) == kind.contents, "new \(kind.rawValue) document has appropriate initial contents")
        }
        let existing = destination.appendingPathComponent("untitled.txt")
        try Data("existing text".utf8).write(to: existing)
        let unique = try FileCreation.create(.text, in: destination)
        try check(unique.lastPathComponent == "untitled 2.txt" && contents(existing) == "existing text", "new documents use a unique name without overwriting existing files")
        let json = destination.appendingPathComponent("untitled.json")
        try check((try JSONSerialization.jsonObject(with: Data(contentsOf: json))) is [String: Any], "new JSON is valid rather than a misleading empty file")
        let alias = try folder(scratch, "Symlink Names")
        let broken = alias.appendingPathComponent("untitled.txt")
        try fm.createSymbolicLink(at: broken, withDestinationURL: alias.appendingPathComponent("missing.txt"))
        let besideLink = try FileCreation.create(.text, in: alias)
        try check(besideLink.lastPathComponent == "untitled 2.txt" && !FileTools.exists(alias.appendingPathComponent("missing.txt")),
                  "new files do not overwrite or follow an existing broken symlink")

        app.activeIndex = 0
        app.newFile(.markdown, in: right)
        let created = app.renameTarget!
        try check(created.deletingLastPathComponent() == destination && app.activeIndex == 1 && app.undoTitle == "Undo New File",
                  "new document targets the clicked pane and offers renaming plus undo")
        app.renameTarget = nil
        let step = app.undoSteps.last!
        let undoError = await step.undo()
        try check(undoError == nil && !FileTools.exists(created), "new document undo removes the created file")
        let redoError = await step.redo()
        try check(redoError == nil && FileTools.exists(created), "new document redo restores the same file")

        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: PaneContainer(app: app, index: 1))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        try await until("context menu table") { !right.loading && descendants(host).contains { $0 is QLTableView } }
        let table = descendants(host).compactMap { $0 as? QLTableView }.first!
        let coordinator = table.qlSource!
        let menu = NSMenu()
        app.activeIndex = 0
        coordinator.populateContextMenu(menu, row: -1)
        try check(app.activeIndex == 1 && ["New Folder", "New File", "Paste", "Select All", "Refresh"].allSatisfy { menu.item(withTitle: $0) != nil },
                  "blank-area context menu activates its pane and includes basic actions")
        let textItem = menu.item(withTitle: "New File")!.submenu!.item(withTitle: NewFileKind.text.title)!
        NSApp.sendAction(textItem.action!, to: textItem.target, from: textItem)
        try check(app.renameTarget?.deletingLastPathComponent() == destination, "native New File submenu creates in the right-clicked pane")
        app.renameTarget = nil
        try await until("new document table refresh") { !right.loading && table.numberOfRows > 0 }
        coordinator.populateContextMenu(menu, row: 0)
        try check(["Cut", "Copy", "Paste", "Rename…"].allSatisfy { menu.item(withTitle: $0) != nil }, "file context menu exposes Cut Copy Paste alongside Rename")
        try check(menu.item(withTitle: "Expand Folder") == nil && menu.item(withTitle: "Collapse Folder") == nil, "context menu keeps redundant expansion actions removed")
    }
}
