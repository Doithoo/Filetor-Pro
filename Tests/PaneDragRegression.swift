import SwiftUI
import AppKit

/// Supplies real pasteboard data to the native destination's drag callbacks.
final class PaneDraggingFixture: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .move
    var draggingLocation: NSPoint = .zero
    var draggedImageLocation: NSPoint = .zero
    var draggedImage: NSImage? { nil }
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingSource: Any?
    var draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func write(_ payload: PaneDragPayload) {
        draggingPasteboard.clearContents()
        draggingPasteboard.writeObjects([payload.pasteboardItem()!])
    }
}

extension Regression {
    static func paneDragTests(_ root: URL) async throws {
        let suite = "FiletorPaneToolbar." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let entries = ["sidebar", "swap", "goTo", "space", "swap", "view"].map { ToolbarEntry(kind: $0) }
        defaults.set(try JSONEncoder().encode(entries), forKey: "toolbar.entries.v1")
        defaults.set(false, forKey: "toolbar.showLabels.v1")
        let toolbar = ToolbarModel(defaults: defaults)
        try check(toolbar.entries == entries.filter { $0.kind != "swap" } && !toolbar.showLabels,
                  "removing Swap Panes preserves all other toolbar IDs, order and icon-only preference")
        try check(ToolbarModel(defaults: defaults).entries == toolbar.entries
                  && !ToolCatalog.palette.contains("swap") && !ToolCatalog.defaultKinds.contains("swap")
                  && ToolCatalog.def("swap") == nil && !CommandCatalog.all.contains(where: { $0.id == "swap" }),
                  "obsolete swap action stays removed from persisted settings, defaults and palettes")
        toolbar.toggle("swap"); toolbar.drop("new:swap", before: nil)
        try check(!toolbar.contains("swap"), "stale toolbar drag payloads cannot reintroduce Swap Panes")

        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let left = PaneLayout.split(id: UUID(), axis: .horizontal, ratio: 0.6, first: .pane(a), second: .pane(b))
        let right = PaneLayout.split(id: UUID(), axis: .horizontal, ratio: 0.4, first: .pane(c), second: .pane(d))
        let tree = PaneLayout.split(id: UUID(), axis: .vertical, ratio: 0.55, first: left, second: right)
        for placement in PanePlacement.allCases {
            let moved = tree.moving(a, to: d, placement: placement)!
            try check(moved.valid(for: [a, b, c, d]), "\(placement.rawValue) pane placement keeps every group exactly once")
            if placement == .center {
                try check(moved.id == tree.id && moved.leaves == [d, b, c, a], "center drop changes only leaf positions in the existing split tree")
            } else {
                let expected = placement == .left || placement == .top ? [b, c, a, d] : [b, c, d, a]
                try check(moved.leaves == expected, "\(placement.rawValue) drop collapses the old split and inserts next to its target")
            }
        }
        try check(tree.moving(a, to: a, placement: .left) == nil && tree.moving(UUID(), to: b, placement: .center) == nil,
                  "self drops and missing source panes cannot change a layout")
        let size = NSSize(width: 600, height: 400)
        for (point, expected) in [(NSPoint(x: 300, y: 200), PanePlacement.center), (NSPoint(x: 5, y: 200), .left),
                                  (NSPoint(x: 595, y: 200), .right), (NSPoint(x: 300, y: 5), .top), (NSPoint(x: 300, y: 395), .bottom)] {
            try check(PanePlacement.at(point, size: size) == expected, "drop zone resolves \(expected.rawValue) from pointer coordinates")
        }
        try check(PanePlacement.at(NSPoint(x: -1, y: 2), size: size) == nil, "points outside a pane do not propose a drop")

        let scratch = try folder(root, "Pane Movement")
        let one = try folder(scratch, "One"), two = try folder(scratch, "Two"), three = try folder(scratch, "Three")
        let document = try file(three, "note.txt", "untouched")
        let app = AppModel()
        defer { app.stop() }
        let panes = [one, two, three].map { PaneModel(url: $0) }
        defer { panes.forEach { $0.stop() } }
        app.restoreWorkspace(WorkspaceSnapshot(panes: panes.map { [PaneSnapshot($0)] }, selected: [0, 0, 0], active: 0, dual: true))
        let source = app.groups[0], target = app.groups[2]
        source.newTab(at: one)
        source.current.navigate(to: three)
        source.current.selection = [document]
        source.current.showHidden = true
        source.newTab(at: two); source.close(at: 2)
        let current = source.current, tabs = source.tabs.map(\.id)
        let layoutBefore = app.layout
        let drag = app.startPaneDrag(source.id)!
        try check(drag.pasteboardItem()?.types == [PaneDragPayload.pasteboardType], "pane payload exposes neither file URLs nor tab text types")
        app.endPaneDrag(drag)
        try check(app.layout == layoutBefore && app.paneDrag == nil, "cancelling a pane drag preserves layout")
        try check(app.movePane(source.id, to: target.id, placement: .top), "whole pane can move above a distant target")
        try check(source.tabs.map(\.id) == tabs && source.current === current && source.canReopen
                  && current.selection == [document] && current.canGoBack && current.showHidden && app.activeGroup === source,
                  "pane movement preserves all tabs, selection, history and closed tabs while following the moved pane")
        let restored = AppModel(workspaceID: app.workspaceID)
        try check(restored.layout == app.layout && restored.activeGroup.id == source.id && restored.activeGroup.tabs.count == 2,
                  "relaunch restores moved pane positions and the full tab group")
        restored.stop()
        app.dual = false
        try check(app.startPaneDrag(source.id) == nil && !app.movePane(source.id, to: target.id, placement: .left),
                  "focused single-pane mode cannot move hidden groups")
        app.dual = true

        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Filetor Pro — Pane Movement"
        let host = NSHostingView(rootView: DualPaneView(app: app).background(Color(nsColor: .windowBackgroundColor)))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func handles() -> [PaneDragHandleView] { descendants(host).compactMap { $0 as? PaneDragHandleView } }
        func surfaces() -> [PaneDropView] { descendants(host).compactMap { $0 as? PaneDropView } }
        try await until("pane handles appear") { handles().count == 3 && app.visibleGroups.allSatisfy { $0.current.isVisible } }
        try check(surfaces().isEmpty, "ordinary file and tab interaction has no pane-drop overlay")
        let fixture = PaneDraggingFixture()
        defer { fixture.draggingPasteboard.releaseGlobally() }
        fixture.draggingDestinationWindow = window
        let nativeSource = handles().first { $0.groupID == source.id }!
        fixture.draggingSource = nativeSource
        let payload = app.startPaneDrag(source.id)!
        fixture.write(payload)
        try await until("pane drop surfaces") { surfaces().count == 3 }
        let destination = surfaces().first { $0.groupID == target.id }!
        let center = NSPoint(x: destination.bounds.midX, y: destination.bounds.midY)
        fixture.draggingLocation = destination.convert(center, to: nil)
        let beforeHover = app.layout
        try check(destination.draggingEntered(fixture) == .move && destination.placement == .center && app.layout == beforeHover,
                  "native center hover previews an exchange without changing the layout")
        fixture.draggingLocation = destination.convert(NSPoint(x: destination.bounds.midX, y: 10), to: nil)
        try check(destination.draggingUpdated(fixture) == .move && destination.placement == .top && app.layout == beforeHover,
                  "moving to an edge updates only the placement preview")
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let output = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appending(path: "pane-move-preview.png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: output)
        }
        destination.draggingExited(fixture)
        try check(destination.placement == nil && app.layout == beforeHover, "leaving a drop target removes the preview without moving panes")
        fixture.draggingPasteboard.clearContents(); fixture.draggingPasteboard.setString(current.id.uuidString, forType: .string)
        try check(destination.draggingEntered(fixture).isEmpty && !destination.performDragOperation(fixture), "tab drag text cannot reorder panes")
        fixture.draggingPasteboard.clearContents(); fixture.draggingPasteboard.writeObjects([document as NSURL])
        try check(destination.draggingEntered(fixture).isEmpty && !destination.performDragOperation(fixture), "file drags cannot reorder panes or trigger pane operations")
        fixture.write(PaneDragPayload(workspaceID: app.workspaceID, groupID: source.id, token: UUID()))
        try check(destination.draggingEntered(fixture).isEmpty, "stale pane drag tokens are rejected")
        fixture.write(payload)
        let otherApp = AppModel()
        let foreign = PaneDragHandleView(); foreign.app = otherApp; foreign.groupID = source.id
        fixture.draggingSource = foreign
        try check(destination.draggingEntered(fixture).isEmpty, "a drag from another window cannot move this workspace's panes")
        otherApp.stop()
        fixture.draggingSource = nativeSource
        try check(destination.prepareForDragOperation(fixture) && destination.performDragOperation(fixture), "native pane drop commits a valid edge placement")
        try await until("pane overlays removed") { surfaces().isEmpty && app.paneDrag == nil }
        try check(source.tabs.map(\.id) == tabs && app.layout.valid(for: app.groups.map(\.id))
                  && contents(document) == "untouched" && !app.transfers.hasActive,
                  "dropping a pane preserves tabs and file contents without queueing a file transfer")
        try await until("moved panes remain live") { app.visibleGroups.allSatisfy { $0.current.isVisible } }
        try check(app.visibleGroups.allSatisfy { $0.current.isVisible }, "moved pane file lists remain live after SwiftUI reparenting")
        let cancelled = app.startPaneDrag(source.id)!
        try await until("cancel overlay appears") { !surfaces().isEmpty }
        app.endPaneDrag(cancelled)
        try await until("cancel overlay disappears") { surfaces().isEmpty }
        try check(app.paneDrag == nil, "ending a cancelled drag removes all hit-test overlays")

        // Start a real AppKit drag from its mouse events, then cancel with Escape.
        let liveSource = handles().first { $0.groupID == source.id }!
        let origin = liveSource.convert(NSPoint(x: liveSource.bounds.midX, y: liveSource.bounds.midY), to: nil)
        var sawNativeDrag = false
        let cancelTimer = Timer(timeInterval: 0.25, repeats: false) { _ in
            MainActor.assumeIsolated {
                sawNativeDrag = app.paneDrag != nil && liveSource.payload != nil
                let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
                NSApp.postEvent(escape, atStart: true)
            }
        }
        RunLoop.main.add(cancelTimer, forMode: .common)
        defer { cancelTimer.invalidate() }
        let fallback = Timer(timeInterval: 0.7, repeats: false) { _ in
            MainActor.assumeIsolated {
                if app.paneDrag != nil {
                    NSApp.postEvent(NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: -50, y: -50), modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                        eventNumber: 0, clickCount: 1, pressure: 0)!, atStart: true)
                }
            }
        }
        RunLoop.main.add(fallback, forMode: .common)
        defer { fallback.invalidate() }
        let beforeNative = app.layout
        for (type, point) in [(NSEvent.EventType.leftMouseDown, origin), (.leftMouseDragged, NSPoint(x: origin.x + 12, y: origin.y))] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        // SwiftUI removes the native drop surfaces on the render pass after
        // AppKit clears the drag payload; wait for both observable outcomes.
        try await until("native drag cancelled and overlays removed") {
            sawNativeDrag && app.paneDrag == nil && liveSource.payload == nil && surfaces().isEmpty
        }
        try check(app.layout == beforeNative && surfaces().isEmpty, "Escape cancels an actual native pane drag and clears its overlays without changing layout")
        cancelTimer.invalidate(); fallback.invalidate()

        let actualSource = handles().first { $0.groupID == source.id }!
        let actualOrigin = actualSource.convert(NSPoint(x: actualSource.bounds.midX, y: actualSource.bounds.midY), to: nil)
        let beforeDrop = app.layout
        var proposed = false
        var dropPoint: NSPoint?
        let originalPointer = NSEvent.mouseLocation
        func warp(_ screenPoint: NSPoint) {
            CGWarpMouseCursorPosition(CGPoint(x: screenPoint.x, y: NSScreen.screens[0].frame.maxY - screenPoint.y))
        }
        defer { warp(originalPointer) }
        let enterTimer = Timer(timeInterval: 0.2, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard let targetView = surfaces().first(where: { $0.groupID == target.id }) else { return }
                let point = targetView.convert(NSPoint(x: targetView.bounds.midX, y: targetView.bounds.midY), to: nil)
                dropPoint = point
                warp(window.convertPoint(toScreen: point))
                NSApp.postEvent(NSEvent.mouseEvent(with: .leftMouseDragged, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1)!, atStart: true)
            }
        }
        let dropTimer = Timer(timeInterval: 0.5, repeats: false) { _ in
            MainActor.assumeIsolated {
                proposed = surfaces().first(where: { $0.groupID == target.id })?.placement == .center
                let point = dropPoint ?? NSPoint(x: -50, y: -50)
                NSApp.postEvent(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 0)!, atStart: true)
            }
        }
        RunLoop.main.add(enterTimer, forMode: .common); RunLoop.main.add(dropTimer, forMode: .common)
        defer { enterTimer.invalidate(); dropTimer.invalidate() }
        warp(window.convertPoint(toScreen: actualOrigin))
        for (type, point) in [(NSEvent.EventType.leftMouseDown, actualOrigin), (.leftMouseDragged, NSPoint(x: actualOrigin.x + 12, y: actualOrigin.y))] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        try await until("native pane drop completes") { app.paneDrag == nil && actualSource.payload == nil && !dropTimer.isValid }
        try check(proposed && app.layout == beforeDrop.moving(source.id, to: target.id, placement: .center),
                  "native AppKit drag dispatch shows the center preview and commits the pane exchange on mouse release")
    }
}
