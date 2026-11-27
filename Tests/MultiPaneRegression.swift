import AppKit
import SwiftUI

extension Regression {
    static func multiPaneTests(_ root: URL) async throws {
        let scratch = try folder(root, "Multi Pane")
        let a = try folder(scratch, "Source 中文"), b = try folder(scratch, "Target B"), c = try folder(scratch, "Target C")
        let original = try file(a, "note.txt", "multi-pane fixture")
        let pane = PaneModel(url: a), second = PaneModel(url: b)
        defer { pane.stop(); second.stop() }
        pane.showHidden = true
        pane.viewMode = 1
        pane.sortOrder = [KeyPathComparator(\FileItem.size, order: .reverse)]
        let legacy = WorkspaceSnapshot(panes: [[PaneSnapshot(pane)], [PaneSnapshot(second)]], selected: [0, 0], active: 1, dual: false)
        let app = AppModel()
        defer { app.stop() }
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: JSONEncoder().encode(legacy))
        app.restoreWorkspace(decoded)
        try check(app.groups.count == 2 && app.active.currentURL == b && app.visibleGroups.count == 1,
                  "legacy focused workspace restores the active pane and retains hidden tabs")
        let hidden = app.groups[0]
        hidden.newTab(at: c)
        app.splitPane(app.active, axis: .horizontal)
        try check(app.groups.count == 2 && app.visibleGroups.count == 2 && hidden.tabs.count == 2
                  && hidden.current.currentURL == c && app.activeGroup === hidden,
                  "splitting a legacy focused pair reveals its hidden tabs without adding a third pane")
        app.restoreWorkspace(decoded)
        app.dual = true
        let source = app.groups[0], targetB = app.groups[1]
        app.splitPane(source.current, axis: .horizontal)
        let third = app.activeGroup
        try check(app.groups.count == 3 && app.layout.leaves == [source.id, third.id, targetB.id],
                  "splitting a nonactive pane inserts beside that pane, preserving existing group identities")
        try check(third.current.currentURL == a && third.current.viewMode == 1 && third.current.showHidden
                  && third.current.sortOrder.first?.order == .reverse && third.current !== source.current,
                  "new pane copies location and view preferences into an independent tab")
        third.current.navigate(to: c)
        try check(source.current.currentURL == a, "navigation in a split pane leaves its source unchanged")
        app.layout = app.layout.resizing(app.layout.id, ratio: 0.63)
        app.saveSession()
        let stored = try JSONDecoder().decode(WorkspaceSnapshot.self, from: UserDefaults.standard.data(forKey: "workspace.\(app.workspaceID.uuidString)")!)
        let restored = AppModel(workspaceID: app.workspaceID)
        try check(restored.layout == app.layout && restored.groups.map(\.id) == app.groups.map(\.id)
                  && restored.activeGroup.id == third.id, "nested split directions, divider ratio and active pane survive session restoration")
        restored.stop()
        let tree = app.layout
        app.dual = false
        try check(app.visibleGroups.map(\.id) == [third.id] && app.activeGroup.id == third.id,
                  "focus mode shows the active pane without resetting to the first pane")
        let focused = AppModel(workspaceID: app.workspaceID)
        try check(focused.focusedPaneID == third.id && focused.layout == tree && focused.groups.count == 3,
                  "focus mode persists all hidden panes and restores the correct active group")
        focused.stop()
        app.dual = true
        try check(app.layout == tree && app.visibleGroups.count == 3, "leaving focus mode restores the full layout")
        third.newTab(at: b)
        let count = app.groups.count
        app.closeTab(in: third, at: 1)
        try check(app.groups.count == count && third.tabs.count == 1 && third.current.currentURL == c,
                  "closing one of several tabs retains its pane and previous tab")

        app.activate(source.current)
        app.transfer([original], move: false)
        try check(app.pendingPaneChoice?.destinations.count == 2 && !app.transfers.hasActive,
                  "three-pane copy waits for an explicit destination")
        let cancelled = app.pendingPaneChoice!
        app.pendingPaneChoice = nil
        app.selectPaneDestination(cancelled.destinations[0], for: cancelled.id)
        try check(!app.transfers.hasActive && contents(original) == "multi-pane fixture",
                  "cancelled destination selection cannot perform a stale transfer")
        app.transfer([original], move: false)
        let choice = app.pendingPaneChoice!
        let destination = choice.destinations.first { $0.id == third.id }!
        third.current.navigate(to: b)
        app.selectPaneDestination(destination, for: choice.id)
        try await until("multi-pane copy") { !app.transfers.hasActive }
        try check(contents(c.appending(path: "note.txt")) == "multi-pane fixture" && !FileTools.exists(b.appending(path: "note.txt")),
                  "copy uses the directory displayed in the chooser even after pane navigation")
        app.undo()
        try await until("multi-pane undo") { !app.historyBusy }
        try check(!FileTools.exists(c.appending(path: "note.txt")) && FileTools.exists(original), "multi-pane copy remains undoable")
        third.current.navigate(to: c)
        app.transfer([original], move: true)
        let moving = app.pendingPaneChoice!
        app.selectPaneDestination(moving.destinations.first { $0.id == targetB.id }!, for: moving.id)
        try await until("multi-pane move") { !app.transfers.hasActive }
        try check(!FileTools.exists(original) && contents(b.appending(path: "note.txt")) == "multi-pane fixture", "move reaches only the chosen pane")
        app.undo()
        try await until("multi-pane move undo") { !app.historyBusy }
        try check(FileTools.exists(original) && !FileTools.exists(b.appending(path: "note.txt")), "multi-pane move undo restores source")
        app.compareFolders()
        try check(app.pendingPaneChoice?.title == "Compare Folders" && app.report == nil, "comparison requests a target in multi-pane layouts")
        app.pendingPaneChoice = nil
        app.synchronize()
        let syncing = app.pendingPaneChoice!
        app.selectPaneDestination(syncing.destinations.first { $0.id == third.id }!, for: syncing.id)
        try await until("multi-pane sync scan") { app.sync?.loading == false }
        try check(app.sync?.leftRoot == a && app.sync?.rightRoot == c, "synchronization uses the active source and selected destination")
        app.sync = nil
        let originalOrder = app.layout.leaves
        try check(app.movePane(source.id, to: third.id, placement: .center)
                  && app.layout.leaves == originalOrder.map { $0 == source.id ? third.id : $0 == third.id ? source.id : $0 }
                  && source.current.currentURL == a && third.current.currentURL == c && targetB.current.currentURL == b,
                  "moving a pane to the center swaps layout positions without exchanging tab ownership")
        _ = app.movePane(source.id, to: third.id, placement: .center)
        app.closeTab(in: third, at: 0)
        try check(app.groups.count == 2 && app.layout.leaves == [source.id, targetB.id] && app.activeGroup.id == source.id,
                  "closing an inactive pane collapses its split without changing the active pane")
        app.transfer([original], move: false)
        try check(app.pendingPaneChoice == nil, "two-pane copy keeps its direct destination behavior")
        try await until("two-pane direct copy") { !app.transfers.hasActive }
        try check(contents(b.appending(path: "note.txt")) == "multi-pane fixture", "two-pane copy reaches the other pane")
        app.activate(targetB.current)
        app.closeTab(in: targetB, at: 0)
        try check(app.groups.count == 1 && app.activeGroup.id == source.id && app.layout == .pane(source.id),
                  "closing the active pane selects its surviving neighbor")

        var invalid = stored
        invalid.layout = .split(id: UUID(), axis: .vertical, ratio: 0.5, first: .pane(source.id), second: .pane(source.id))
        app.restoreWorkspace(invalid)
        try check(app.layout.valid(for: app.groups.map(\.id)) && app.groups.count == 3,
                  "malformed layout falls back to a complete layout without discarding tabs")
        let only = WorkspaceSnapshot(panes: [[PaneSnapshot(pane)]], selected: [0], active: 0, dual: false)
        app.restoreWorkspace(only)
        try check(app.groups.count == 1 && app.visibleGroups.count == 1, "single-pane workspace restores without adding a second pane")
        for _ in 0..<20 { app.splitPane(app.active, axis: .vertical) }
        try check(app.groups.count == 16 && !app.canSplitPane && app.layout.valid(for: app.groups.map(\.id)),
                  "pane count is bounded at sixteen without corrupting the layout")
        app.restoreWorkspace(only)
        app.active.viewMode = 0
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Filetor Pro — Multi-pane Regression"
        let host = NSHostingView(rootView: DualPaneView(app: app)
            .background(Color(nsColor: .windowBackgroundColor))
            .floatingPanel(isPresented: Binding(get: { app.pendingPaneChoice != nil }, set: { if !$0 { app.pendingPaneChoice = nil } })) {
                if let choice = app.pendingPaneChoice { PaneChoiceView(choice: choice, app: app) }
            })
        window.contentView = host
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.acceptsMouseMovedEvents = true
        let originalPointer = NSEvent.mouseLocation
        func warpPointer(_ point: NSPoint) {
            CGWarpMouseCursorPosition(CGPoint(x: point.x, y: NSScreen.screens[0].frame.maxY - point.y))
        }
        defer { window.orderOut(nil); window.contentView = nil; window.close(); warpPointer(originalPointer) }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func tables() -> [QLTableView] { descendants(host).compactMap { $0 as? QLTableView } }
        func help(_ title: String) -> [ToolbarHelpView] { descendants(host).compactMap { $0 as? ToolbarHelpView }.filter { $0.toolTip == title } }
        func click(_ view: NSView) {
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
            }
        }
        try await until("single pane UI") { tables().count == 1 && !app.active.loading }
        func splitMenu(_ table: QLTableView, _ axis: PaneSplitAxis) throws {
            let menu = NSMenu()
            table.qlSource!.populateContextMenu(menu, row: -1)
            try check(PaneSplitAxis.allCases.allSatisfy { menu.item(withTitle: $0.title)?.isEnabled == true }, "blank-area menu exposes both split directions")
            let item = menu.item(withTitle: axis.title)!
            NSApp.sendAction(item.action!, to: item.target, from: item)
        }
        try splitMenu(tables()[0], .vertical)
        try await until("vertical split UI") { tables().count == 2 }
        try splitMenu(tables()[0], .horizontal)
        try await until("nested split UI") { tables().count == 3 && help("Close Pane").count == 3 }
        try await Task.sleep(for: .milliseconds(200))
        let frames = tables().map { $0.convert($0.bounds, to: host) }
        try check(frames.filter { $0.width > 280 && $0.height > 100 }.count == 3
                  && Set(frames.map { Int($0.midX) }).count == 2 && Set(frames.map { Int($0.midY) }).count == 3,
                  "real window renders side-by-side and stacked panes with usable table frames")
        // Send real divider mouse drags in both directions, then check the persisted tree.
        for horizontal in [false, true] {
            guard let divider = descendants(host).compactMap({ $0 as? PaneDividerView }).first(where: { ($0.axis == .horizontal) == horizontal }) else {
                throw FileOperationSafety.failure("Missing divider")
            }
            let start = divider.convert(NSPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: nil)
            let hit = host.hitTest(host.convert(start, from: nil))
            try check(hit === divider, "divider itself receives pointer events instead of an overlapping hosting view")
            // Begin outside the divider even if the user's pointer happened to
            // be resting there. AppKit emits mouseEntered only on a crossing.
            let outside = NSPoint(x: start.x + 35, y: start.y + 35)
            warpPointer(window.convertPoint(toScreen: outside))
            window.sendEvent(NSEvent.mouseEvent(with: .mouseMoved, location: outside, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!)
            try await until("divider exit before hover") { !divider.isHovering }
            if !window.isKeyWindow {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
            NSCursor.arrow.set()
            warpPointer(window.convertPoint(toScreen: start))
            window.sendEvent(NSEvent.mouseEvent(with: .mouseMoved, location: start, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!)
            try await until("divider hover cursor") { divider.isHovering && NSCursor.current == divider.resizeCursor }
            try check(NSCursor.current == (horizontal ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight),
                      "hovering a \(horizontal ? "horizontal" : "vertical") divider shows the correct native resize cursor")
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let name = horizontal ? "divider-hover-horizontal.png" : "divider-hover-vertical.png"
                let output = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appending(path: name)
                try bitmap.representation(using: .png, properties: [:])?.write(to: output)
            }
            let before = app.layout
            let end = NSPoint(x: start.x + (horizontal ? 0 : 75), y: start.y + (horizontal ? 45 : 0))
            for (type, point) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!)
            }
            try await Task.sleep(for: .milliseconds(100))
            try check(app.layout != before && app.layout.valid(for: app.groups.map(\.id)),
                      "real \(horizontal ? "horizontal" : "vertical") divider drag resizes its split")
            let resized = try JSONDecoder().decode(WorkspaceSnapshot.self, from: UserDefaults.standard.data(forKey: "workspace.\(app.workspaceID.uuidString)")!)
            try check(resized.layout == app.layout, "divider drag saves its new proportion")
            try check(!divider.isDragging, "releasing the mouse ends native divider dragging")
            // Double-click remains a native event and balances only this split.
            let center = divider.convert(NSPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: center, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: type == .leftMouseDown ? 1 : 0)!)
            }
            try await Task.sleep(for: .milliseconds(100))
            try check(abs(divider.fraction - 0.5) < 0.001, "native divider double-click restores equal proportions")
            let away = NSPoint(x: center.x + 35, y: center.y + 35)
            warpPointer(window.convertPoint(toScreen: away))
            window.sendEvent(NSEvent.mouseEvent(with: .mouseMoved, location: away, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!)
            try await until("divider hover ends") { !divider.isHovering && NSCursor.current != divider.resizeCursor }
            try check(!divider.isHovering, "leaving the divider clears its highlight and resize cursor")
        }
        app.active.navigate(to: a)
        app.groups.first { $0.id != app.activeGroup.id }!.current.navigate(to: b)
        var picked: UUID?
        app.chooseOtherPane(from: app.active, title: "Choose Pane") { picked = $0.id }
        let visibleChoice = app.pendingPaneChoice!
        let target = visibleChoice.destinations.first { $0.directory == b }!
        try await until("destination picker UI") { !help(b.path).isEmpty }
        click(help(b.path)[0])
        try await until("destination picker click") { app.pendingPaneChoice == nil }
        try check(picked == target.id, "destination picker receives a real click and selects the displayed group")
        try await Task.sleep(for: .milliseconds(200))
        window.setContentSize(NSSize(width: 480, height: 300))
        try await Task.sleep(for: .milliseconds(150))
        print("Small-window table frames: \(tables().map { $0.bounds })")
        try check(tables().allSatisfy { $0.bounds.width >= 250 && $0.bounds.height >= 70 },
                  "small windows retain usable pane sizes inside the scrollable layout")
        window.setContentSize(NSSize(width: 1100, height: 700))
        try await Task.sleep(for: .milliseconds(150))
        let output = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appending(path: "multi-pane-layout.png")
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: output)
        }
        click(help("Close Pane")[0])
        try await until("single tab close click") { app.groups.count == 2 && tables().count == 2 }
        try check(app.layout.valid(for: app.groups.map(\.id)), "single-tab close button removes a pane through a real mouse click")
        click(help("Close Pane")[0])
        try await until("last pane UI") { app.groups.count == 1 && help("Close Window").count == 1 }
        click(help("Close Window")[0])
        try await until("last tab closes window") { !window.isVisible }
        try check(app.groups.count == 1, "closing the last tab closes the window without creating an empty workspace")

        // Dock reopen creates a fresh workspace in the same process. A restored
        // one-pane snapshot above cannot exercise that initializer path.
        let defaults = UserDefaults.standard
        let previousStartDual = defaults.object(forKey: "startDual")
        defer { defaults.set(previousStartDual, forKey: "startDual") }
        defaults.set(false, forKey: "startDual")
        for axis in PaneSplitAxis.allCases {
            let reopened = AppModel()
            defer { reopened.stop() }
            let reopenedWindow = NSWindow(contentRect: window.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            reopenedWindow.isReleasedWhenClosed = false
            reopened.active.viewMode = 0
            let reopenedHost = NSHostingView(rootView: DualPaneView(app: reopened))
            reopenedWindow.contentView = reopenedHost
            reopenedWindow.makeKeyAndOrderFront(nil)
            defer { reopenedWindow.close() }
            func reopenedTables() -> [QLTableView] { descendants(reopenedHost).compactMap { $0 as? QLTableView } }
            try await until("reopened single pane") { reopenedTables().count == 1 }
            try check(reopened.groups.count == 1 && reopened.focusedPaneID == nil, "a reopened single pane has no hidden sibling")
            let sourceID = reopened.activeGroup.id
            try splitMenu(reopenedTables()[0], axis)
            guard case let .split(_, direction, ratio, .pane(first), .pane(second)) = reopened.layout else {
                throw FileOperationSafety.failure("Splitting the reopened window must produce exactly two leaves")
            }
            try check(direction == axis && ratio == 0.5 && first == sourceID && second == reopened.activeGroup.id
                      && reopened.groups.count == 2, "first split in a reopened window creates exactly two equal panes on the requested axis")
            try await until("two visible tables after reopen") { reopenedTables().count == 2 }
            reopened.closeTab()
            try check(reopened.layout == .pane(sourceID), "closing that split returns to the original single pane")
            reopened.closeTab()
            try await until("reopened window closes") { !reopenedWindow.isVisible }
        }
        for twoPanes in [false, true] {
            defaults.set(twoPanes, forKey: "startDual")
            let id = UUID()
            AppModel.windowLocations[id] = c
            let located = AppModel(workspaceID: id)
            defer { located.stop() }
            try check(located.groups.count == (twoPanes ? 2 : 1) && located.visibleGroups.count == located.groups.count
                      && located.groups.allSatisfy { $0.current.currentURL == c },
                      "opening a folder in a new window initializes only the requested panes at its location")
        }
    }
}
