import Foundation
import AppKit
import SwiftUI

extension Regression {
    static func navigationTests(_ root: URL) async throws {
        let suite = "FiletorNavigationTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let entries = ["sidebar", "backfwd", "title", "space", "copy", "view"].map { ToolbarEntry(kind: $0) }
        defaults.set(try JSONEncoder().encode(entries), forKey: "toolbar.entries.v1")
        defaults.set(false, forKey: "toolbar.showLabels.v1")
        ToolbarModel.migrateNavigationButton(defaults)
        let migrated = try JSONDecoder().decode([ToolbarEntry].self, from: defaults.data(forKey: "toolbar.entries.v1")!)
        try check(migrated.map(\.kind) == ["sidebar", "backfwd", "goTo", "title", "space", "copy", "view"] && migrated.filter { $0.kind != "goTo" } == entries,
                  "navigation toolbar migration inserts one button while preserving item IDs and order")
        try check(!defaults.bool(forKey: "toolbar.showLabels.v1"), "navigation migration preserves toolbar label preference")
        defaults.set(try JSONEncoder().encode(entries), forKey: "toolbar.entries.v1")
        ToolbarModel.migrateNavigationButton(defaults)
        try check(try JSONDecoder().decode([ToolbarEntry].self, from: defaults.data(forKey: "toolbar.entries.v1")!) == entries,
                  "removing the Go To button is respected on subsequent launches")

        let dir = try folder(root, "Navigation 中文")
        let nested = try folder(dir, "Projects")
        let target = try folder(nested, "设计 资料")
        for i in 0..<18 { _ = try folder(dir, "Folder \(i)") }
        _ = try folder(dir, ".private")
        _ = try folder(dir, "Example.app")
        let file = try file(dir, "report.txt")
        let model = FolderNavigationModel(base: dir, showHidden: false)
        model.refresh()
        try await until("folder dropdown load") { !model.loading }
        try check(model.entries.count == 19 && model.entries.allSatisfy(\.directory), "folder dropdown lists all subfolders beyond twelve and excludes packages, files and hidden folders")
        let recent = RecentFolders(defaults: defaults)
        model.browse(nested)
        try await until("nested folder dropdown") { !model.loading }
        try check(model.directory == nested && model.entries.map(\.url) == [target] && recent.urls.isEmpty, "browsing inside a dropdown does not record a visited folder")
        model.back()
        try await until("folder browser back") { !model.loading }
        try check(model.directory == dir && !model.canGoBack, "folder browser back restores its previous browsing location")
        model.edit(dir.path + "/report")
        try await until("typed file completion") { !model.loading }
        try check(model.entries.map(\.url) == [file], "typing a path still offers matching files")
        model.browse(nested); model.browse(dir)
        try await until("latest browsed directory") { !model.loading }
        try check(model.entries.contains { $0.url == nested } && !model.entries.contains { $0.url == target }, "rapid mouse browsing discards superseded directory results")
        model.browse(dir.appending(path: "Missing"))
        try await until("missing folder") { !model.loading }
        try check(model.error != nil && model.entries.isEmpty, "unavailable folders show an error without stale entries")
        model.browse(dir); model.stop()
        try await Task.sleep(for: .milliseconds(140))
        try check(!model.loading && model.entries.isEmpty, "closing folder navigation cancels pending reads")
        recent.record(dir); recent.record(nested); recent.record(dir)
        try check(recent.urls == [dir, nested] && RecentFolders(defaults: defaults).urls == [dir, nested], "recent folders deduplicate and persist in most-recent order")
        for i in 0..<25 { recent.record(dir.appending(path: "Folder \(i)")) }
        try check(recent.urls.count == 20, "recent folder history has a bounded size")
        recent.clear()
        try check(RecentFolders(defaults: defaults).urls.isEmpty, "clearing recent folders persists")

        let app = AppModel()
        defer { app.stop() }
        let left = PaneModel(url: dir), right = PaneModel(url: nested)
        app.groups[0].tabs = [left]; app.groups[1].tabs = [right]
        app.activeIndex = 1
        let action = FolderNavigationAction()
        var completed = false
        action.open(target, app: app, pane: right) { completed = true }
        try await until("right pane navigation") { !action.opening }
        try check(completed && right.currentURL == target && left.currentURL == dir, "opening a dropdown result navigates only its captured pane")
        completed = false
        action.open(dir, app: app, pane: right) { completed = true }
        app.activeIndex = 0
        try await until("changed active pane") { !action.opening }
        try check(!completed && right.currentURL == target && left.currentURL == dir, "switching panes cancels a pending dropdown destination")
        action.open(nested, app: app, pane: left) { completed = true }; action.stop()
        try await Task.sleep(for: .milliseconds(100))
        try check(!completed && left.currentURL == dir, "closing a dropdown prevents pending navigation")
        try await navigationUITests(app, root: dir, nested: nested, target: target)
        try await navigationWorkspaceUITests(root)
    }

    static func navigationWorkspaceUITests(_ root: URL) async throws {
        UserDefaults.standard.set(true, forKey: "folderAccessAsked")
        UserDefaults.standard.set(false, forKey: "showSidebar")
        let app = AppModel()
        app.sidebarVisibility = .detailOnly
        app.toolbarModel.entries = ["sidebar", "backfwd", "goTo", "flex", "hidden", "terminal", "trash", "move", "info", "copyPath", "customize", "view", "search"].map { ToolbarEntry(kind: $0) }
        app.toolbarModel.showLabels = true
        app.active.navigate(to: root)
        let window = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ContentView(app: app))
        window.contentView = host
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { app.showGoToFolder = false; window.orderOut(nil); window.contentView = nil; window.close(); app.stop() }
        try await Task.sleep(for: .milliseconds(600))
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appending(path: "navigation-workspace.png"))
        }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: 216, y: window.frame.height - 42), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            window.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(400))
        try check(app.showGoToFolder && NSApp.windows.contains { $0 !== window && $0.isVisible && String(describing: type(of: $0)).contains("Popover") },
                  "Go To opens from the complete workspace with a customized toolbar")
    }

    static func navigationUITests(_ app: AppModel, root: URL, nested: URL, target: URL) async throws {
        app.toolbarModel.entries = ["backfwd", "goTo", "title", "flex", "view"].map { ToolbarEntry(kind: $0) }
        app.toolbarModel.showLabels = true
        let left = app.groups[0].current, right = app.groups[1].current
        left.navigate(to: nested); right.navigate(to: nested); app.activeIndex = 0
        let window = NSWindow(contentRect: NSRect(x: 150, y: 250, width: 1000, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            CustomToolbar(app: app)
            HStack(spacing: 0) { BreadcrumbBar(pane: left, app: app); BreadcrumbBar(pane: right, app: app) }
            Spacer()
        }.background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { app.showGoToFolder = false; window.orderOut(nil); window.contentView = nil; window.close() }
        func click(_ window: NSWindow, x: CGFloat, fromTop: CGFloat) {
            let location = NSPoint(x: x, y: window.contentLayoutRect.height - fromTop)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                window.sendEvent(event)
            }
        }
        func popover() -> NSWindow? {
            NSApp.windows.first { $0 !== window && $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        click(window, x: 148, fromTop: 26)
        try await until("mouse opened toolbar popover") { app.showGoToFolder && popover() != nil }
        try check(app.showGoToFolder, "mouse click opens the Go To toolbar popover")
        try await Task.sleep(for: .milliseconds(350))
        try snapshotNavigationWindow(name: "go-to-popover")
        guard let browser = popover() else { throw FileOperationSafety.failure("Missing folder popover") }
        click(browser, x: 142, fromTop: 109)
        try await Task.sleep(for: .milliseconds(150))
        try snapshotNavigationWindow(name: "go-to-favorites")
        click(browser, x: 223, fromTop: 109)
        try await Task.sleep(for: .milliseconds(150))
        try snapshotNavigationWindow(name: "go-to-recent")
        click(browser, x: 65, fromTop: 109)
        // The fixture has one child; the right-hand disclosure browses without opening it.
        click(browser, x: 410, fromTop: 201)
        try await Task.sleep(for: .milliseconds(300))
        try check(left.currentURL == nested, "mouse disclosure leaves the current pane location unchanged")
        try snapshotNavigationWindow(name: "go-to-browsed")
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(100))
        try snapshotNavigationWindow(name: "go-to-dark")
        NSApp.appearance = NSAppearance(named: .aqua)
        app.showGoToFolder = false
        try await until("toolbar popover closed") { popover() == nil }
        // The trailing breadcrumb disclosure is kept visible by the path bar's scroll alignment.
        click(window, x: 973, fromTop: 86)
        try await until("right breadcrumb popover") { app.active === right && popover() != nil }
        try await Task.sleep(for: .milliseconds(300))
        try check(app.active === right && popover() != nil, "mouse click on the right breadcrumb activates its pane and keeps its popover open")
        try snapshotNavigationWindow(name: "breadcrumb-popover")
        guard let breadcrumb = popover() else { throw FileOperationSafety.failure("Missing breadcrumb popover") }
        click(breadcrumb, x: 140, fromTop: 135)
        try await until("mouse opens right folder") { right.currentURL == target }
        try check(left.currentURL == nested, "opening a folder through the right breadcrumb leaves the left pane unchanged")
    }

    static func snapshotNavigationWindow(name: String) throws {
        for window in NSApp.windows where window.isVisible && window.contentView != nil {
            guard let view = window.contentView, window.frame.width < 700 else { continue }
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let url = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appending(path: name + ".png")
            try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        }
    }
}
