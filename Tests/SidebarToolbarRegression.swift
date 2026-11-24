import SwiftUI
import AppKit

extension Regression {
    static func sidebarToolbarTests(_ root: URL) async throws {
        UserDefaults.standard.set("Favorites,Devices,Cloud,Shared,Searches,Tags", forKey: "sidebarOrder")
        UserDefaults.standard.set("Devices,Cloud,Shared,Searches,Tags", forKey: "sidebarCollapsed")
        let folder = try folder(root, "Sidebar toolbar")
        let trash = try self.folder(folder, "Trash fixture")
        let item = try file(trash, "Recovered document.txt")
        let app = AppModel()
        defer { app.stop() }
        app.groups.forEach { $0.current.navigate(to: folder) }
        app.toolbarModel.entries = ["backfwd", "goTo", "hidden", "info", "trash", "view", "search"].map { ToolbarEntry(kind: $0) }
        app.toolbarModel.showLabels = false
        let toolbar = app.toolbarModel.entries
        let favorites = app.favorites.urls
        let home = FileManager.default.homeDirectoryForCurrentUser
        let specialFolders = [
            "Applications": "square.grid.2x2", "Desktop": "menubar.dock.rectangle",
            "Documents": "doc", "Downloads": "arrow.down.circle", "Library": "books.vertical",
            "Movies": "film", "Music": "music.note", "Pictures": "photo", "Public": "person.2"
        ]
        for (name, symbol) in specialFolders.sorted(by: { $0.key < $1.key }) {
            let url = home.appending(path: name)
            let place = app.favorites.place(for: url)
            try check(place.icon == symbol && place.url == url && NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                      "\(name) favorite uses an available dedicated native symbol without changing its destination")
            let ordinary = folder.appending(path: name)
            try check(app.favorites.place(for: ordinary).icon == "folder",
                      "ordinary folders named \(name) retain the regular folder symbol")
        }
        try check(app.favorites.place(for: URL(fileURLWithPath: "/Applications")).icon == "square.grid.2x2"
                  && app.favorites.place(for: home.appending(path: "Pictures/../Music")).icon == "music.note"
                  && app.favorites.urls == favorites,
                  "special icons recognize system Applications and normalized paths without rewriting favorites")
        app.activeIndex = 1
        let left = app.groups[0].current, right = app.groups[1].current
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: HStack(spacing: 0) {
            SidebarView(app: app, trashURL: trash).frame(width: 210)
            VStack(spacing: 0) {
                CustomToolbar(app: app)
                FileListView(pane: right, app: app, isActive: true)
            }
        }.background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        func helpViews(_ view: NSView) -> [ToolbarHelpView] {
            (view as? ToolbarHelpView).map { [$0] } ?? view.subviews.flatMap(helpViews)
        }
        func help(_ prefix: String) -> ToolbarHelpView? {
            helpViews(host).first { $0.toolTip?.hasPrefix(prefix) == true }
        }
        func click(_ view: NSView) {
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
            }
        }
        try await Task.sleep(for: .milliseconds(500))
        try check(help("Get Info — Select") != nil && help("Move to Trash — Select") != nil,
                  "disabled icon-only toolbar actions expose native tooltips with selection guidance")
        try check(["List View", "Icon View"].allSatisfy { help($0) != nil } && help("Column View") == nil,
                  "toolbar offers only list and icon view controls with native hover descriptions")
        try check(helpViews(host).allSatisfy { $0.hitTest(.zero) == nil },
                  "native tooltip views never intercept toolbar or sidebar clicks")
        guard let row = help("Open this Mac’s Trash") else { throw FileOperationSafety.failure("Missing sidebar Trash button") }
        click(row)
        try await until("sidebar Trash opens") { right.currentURL == trash && !right.loading }
        try check(right.items.map(\.url) == [item] && left.currentURL == folder,
                  "sidebar Trash mouse click lists its contents in only the active pane")
        try check(app.favorites.urls == favorites && app.toolbarModel.entries == toolbar && !app.toolbarModel.showLabels,
                  "adding Trash and hover help preserves favorites and icon-only toolbar IDs and order")
        right.selection = [item]
        try await Task.sleep(for: .milliseconds(120))
        try check(help("Get Info")?.toolTip == "Get Info" && help("Move to Trash")?.toolTip == "Move to Trash",
                  "hover explanations update when a selection enables actions")
        guard let back = help("Back") else { throw FileOperationSafety.failure("Missing Back button") }
        click(back)
        try await until("Trash back navigation") { right.currentURL == folder }
        try check(right.currentURL == folder && left.currentURL == folder,
                  "leaving Trash through Back restores the previous folder")
        guard let hidden = help("Show Hidden Files") else { throw FileOperationSafety.failure("Missing hidden-files button") }
        click(hidden)
        try await until("dynamic hidden tooltip") { help("Hide Hidden Files") != nil }
        try check(right.showHidden, "a tooltip-bearing toggle remains clickable and describes its next action")
        guard let icons = help("Icon View") else { throw FileOperationSafety.failure("Missing Icon View") }
        click(icons)
        try await until("tooltip view switch") { right.viewMode == 1 }
        try check(right.viewMode == 1, "view-mode hover help does not block switching views")
        guard let list = help("List View") else { throw FileOperationSafety.failure("Missing List View") }
        click(list)
        try await until("return to list view") { right.viewMode == 0 }
        try check(right.treeActive && left.viewMode == 0, "returning to list restores folder expansion in only the active pane")
        try check(TrashLocation.isRoot(TrashLocation.home)
                  && TrashLocation.contains(TrashLocation.home.appending(path: "Nested/file.txt"))
                  && !TrashLocation.contains(TrashLocation.home.deletingLastPathComponent().appending(path: ".Trash-other")),
                  "Trash detection respects folder boundaries and descendants")
        let external = URL(fileURLWithPath: "/Volumes/Fixture/.Trashes/\(getuid())")
        try check(TrashLocation.isRoot(external) && !TrashLocation.isRoot(URL(fileURLWithPath: "/Volumes/Fixture/.Trashes/\(getuid() + 1)")),
                  "external-disk Trash detection is limited to the current user")
        let titled = PaneModel(url: TrashLocation.home)
        defer { titled.stop() }
        try check(titled.title == "Trash", "Trash tabs use a readable title instead of a hidden-folder name")

        // Render the real sidebar with the new symbols using only the test app's preferences.
        app.favorites.insert(specialFolders.keys.sorted().map { home.appending(path: $0) }, before: nil)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appending(path: "sidebar-trash-toolbar.png"))
        }
    }
}
