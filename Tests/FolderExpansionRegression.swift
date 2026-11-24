import SwiftUI
import AppKit

extension Regression {
    static func folderExpansionTests(_ root: URL) async throws {
        let dir = try folder(root, "Bulk tree"), a = try folder(dir, "A")
        let b = try folder(a, "中文 B"), empty = try folder(dir, "Empty")
        let leaf = try file(b, "leaf.txt"), top = try file(dir, "top.txt")
        let hidden = try folder(a, ".hidden")
        _ = try file(hidden, "secret.txt")
        let package = try folder(dir, "Fixture.app")
        _ = try folder(package, "Contents")
        let link = dir.appending(path: "Loop")
        try fm.createSymbolicLink(at: link, withDestinationURL: dir)
        let pane = PaneModel(url: dir)
        pane.showHidden = false
        pane.load()
        defer { pane.stop() }
        try await until("bulk root load") { !pane.loading }
        pane.expandAll()
        try check(pane.expandingAll, "bulk expansion exposes a cancellable busy state")
        try await until("recursive bulk expansion") { !pane.expandingAll }
        try check(pane.expanded == [a, b, empty], "bulk expands nested, empty and Chinese folders, excluding hidden folders, packages and links")
        try check(pane.sortedItems.contains { $0.url == leaf }, "nested files appear in the inline list")
        pane.selection = [leaf, top]
        pane.collapseAll()
        try check(pane.expanded.isEmpty && pane.selection == [top], "collapse all clears hidden descendant selection and keeps root selection")
        pane.expandAll(); pane.collapseAll()
        try await Task.sleep(for: .milliseconds(100))
        try check(!pane.expandingAll && pane.expanded.isEmpty, "collapse cancels pending expansion without late reopening")
        pane.expandAll(); pane.cancelExpandAll()
        pane.expandAll()
        try await until("replacement bulk task") { !pane.expandingAll }
        try check(pane.expanded.contains(b), "a cancelled task cannot cancel or overwrite a newer expansion")
        pane.collapseAll(); pane.expandAll(); pane.filter = "top"
        try await Task.sleep(for: .milliseconds(100))
        try check(!pane.expandingAll && pane.expanded.isEmpty && !pane.canExpandAll, "entering a search cancels expansion and disables tree actions")
        pane.filter = ""; pane.expandAll(); pane.viewMode = 1
        try check(!pane.expandingAll && !pane.canExpandAll && !pane.canCollapseAll, "icon view cancels expansion and disables both actions")
        pane.viewMode = 0; pane.expandAll(); pane.showTag("Fixture")
        try check(!pane.expandingAll && !pane.canExpandAll, "tag view cancels bulk expansion")
        pane.clearTag(); pane.expandAll(); pane.navigate(to: empty)
        try await until("navigate during expansion") { !pane.loading }
        try check(pane.expanded.isEmpty && !pane.expandingAll, "navigation rejects stale expansion results")
        pane.navigate(to: dir)
        try await until("return to bulk root") { !pane.loading }
        pane.expandAll(); pane.collapse(a)
        try await Task.sleep(for: .milliseconds(100))
        try check(pane.expanded.isEmpty, "manual collapse cancels recursive expansion")
        pane.expandAll(limits: .init(folders: 1, items: 100, depth: 64))
        try await until("folder count bound") { !pane.expandingAll }
        try check(pane.expanded.count == 1 && pane.errorMessage?.contains("display limit") == true, "folder limit bounds work and reports incomplete expansion")
        pane.collapseAll()
        let tree = try FolderExpansion.read(roots: [FileItem(url: a)], hidden: false, limits: .init(folders: 100, items: 100, depth: 1))
        try check(tree.limited && tree.children[a] != nil && tree.children[b] == nil, "depth bound stops nested traversal")
        let large = try folder(root, "Large")
        for i in 0..<5 { _ = try file(large, "file\(i)") }
        let limited = try FolderExpansion.read(roots: [FileItem(url: large)], hidden: false, limits: .init(folders: 100, items: 3, depth: 64))
        try check(limited.limited && limited.children.isEmpty, "item bound never presents a partially read directory as complete")
        let missing = try folder(root, "Removed")
        let removed = FileItem(url: missing)
        try fm.removeItem(at: missing)
        let errors = try FolderExpansion.read(roots: [removed, FileItem(url: a)], hidden: false, limits: .init())
        try check(errors.errors[missing] != nil && errors.children[b] != nil, "unreadable folders do not prevent expansion of accessible siblings")
        pane.toggleHidden()
        try await until("hidden root load") { !pane.loading }
        pane.expandAll()
        try await until("hidden bulk expansion") { !pane.expandingAll }
        try check(pane.expanded.contains(hidden), "bulk expansion honors Show Hidden Files")
        pane.collapseAll(); pane.expandAll(); pane.stop()
        try await Task.sleep(for: .milliseconds(100))
        try check(!pane.expandingAll && pane.expanded.isEmpty, "closing or hiding a pane cancels its pending work")

        let suite = "FolderExpansionToolbar-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let entries = ["backfwd", "enclosing", "view", "flex"].map { ToolbarEntry(kind: $0) }
        defaults.set(try JSONEncoder().encode(entries), forKey: "toolbar.entries.v1")
        defaults.set(false, forKey: "toolbar.showLabels.v1")
        let toolbar = ToolbarModel(defaults: defaults)
        try check(toolbar.entries == entries.filter { $0.kind != "enclosing" } && !toolbar.showLabels,
                  "migration removes only Enclosing Folder, preserving toolbar IDs, order and labels")
        toolbar.drop("new:enclosing", before: nil)
        toolbar.toggle("expandAll"); toolbar.toggle("collapseAll")
        try check(!toolbar.contains("enclosing") && toolbar.contains("expandAll") && toolbar.contains("collapseAll"), "customize rejects retired control and accepts both new actions")
        toolbar.toggle("expandAll")
        try check(!ToolbarModel(defaults: defaults).contains("expandAll"), "user removal of an expansion button survives relaunch")
        for id in ["expandAll", "collapseAll"] {
            try check(NSImage(systemSymbolName: ToolCatalog.symbol(id), accessibilityDescription: nil) != nil, "\(id) uses an available native symbol")
        }

        let app = AppModel()
        defer { app.stop() }
        app.groups.forEach { $0.current.navigate(to: dir) }
        try await until("toolbar panes loaded") { app.groups.allSatisfy { !$0.current.loading } }
        app.activeIndex = 1
        let active = app.active, other = app.groups[0].current
        app.toolbarModel.entries = ["expandAll", "collapseAll", "view"].map { ToolbarEntry(kind: $0) }
        app.toolbarModel.showLabels = false
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            CustomToolbar(app: app)
            FileListView(pane: active, app: app, isActive: true)
        })
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        func helpViews(_ view: NSView) -> [ToolbarHelpView] {
            (view as? ToolbarHelpView).map { [$0] } ?? view.subviews.flatMap(helpViews)
        }
        func click(_ prefix: String) throws {
            guard let view = helpViews(host).first(where: { $0.toolTip?.hasPrefix(prefix) == true }) else {
                throw FileOperationSafety.failure("Missing expansion tooltip: " + prefix)
            }
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
            }
        }
        try await Task.sleep(for: .milliseconds(300))
        try click("Expand All Folders")
        try await until("toolbar expands") { active.expanded.contains(b) && !active.expandingAll }
        try check(other.expanded.isEmpty, "native toolbar click expands only the active pane")
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appending(path: "folder-expansion-toolbar.png"))
        }
        try await Task.sleep(for: .milliseconds(100))
        try click("Collapse All Folders")
        try await until("toolbar collapses") { active.expanded.isEmpty }
        try check(active.sortedItems.allSatisfy { $0.url.deletingLastPathComponent() == dir }, "native collapse button returns to root rows")
        active.viewMode = 1
        try await Task.sleep(for: .milliseconds(100))
        try check(helpViews(host).filter { $0.toolTip?.contains("Use List View without search filters") == true }.count == 2,
                  "disabled icon-only controls explain how to enable folder expansion")
    }
}
