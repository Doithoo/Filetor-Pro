import AppKit
import SwiftUI

extension Regression {
    static func liveDirectoryTests(_ root: URL) async throws {
        let dir = try folder(root, "Live Downloads"), keep = try file(dir, "keep.txt")
        let pane = PaneModel(url: dir), app = AppModel()
        defer { app.stop(); pane.stop() }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let stack = NSStackView()
        window.contentView = stack
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }

        // Pane layout edits can mount the replacement before the outgoing view disappears.
        var outgoingGone = false, incomingReady = false
        let outgoing = NSHostingView(rootView: AnyView(FileListView(pane: pane, app: app)
            .onDisappear { outgoingGone = true }))
        stack.addArrangedSubview(outgoing)
        try await until("first directory view") { pane.items.contains { $0.url == keep } }
        let incoming = NSHostingView(rootView: FileListView(pane: pane, app: app)
            .onAppear { incomingReady = true })
        stack.addArrangedSubview(incoming)
        try await until("replacement directory view") { incomingReady }
        outgoing.rootView = AnyView(EmptyView())
        try await until("outgoing directory view disappears") { outgoingGone }
        try check(pane.isVisible, "retiring an outgoing view does not stop the replacement view’s listener")
        pane.selection = [keep]

        func external(_ exe: String, _ args: [String]) throws {
            if let error = FileTools.run(exe, args) { throw FileOperationSafety.failure(error) }
        }
        let temp = dir.appending(path: ".partial"), final = dir.appending(path: "下载完成.pdf")
        try external("/usr/bin/touch", [temp.path])
        try external("/bin/mv", [temp.path, final.path])
        try await until("download appears after replacing its visible view") { pane.sortedItems.contains { $0.url == final } }
        func table(in view: NSView) -> QLTableView? {
            if let table = view as? QLTableView { return table }
            for child in view.subviews { if let table = table(in: child) { return table } }
            return nil
        }
        try await until("native table displays the completed download") { table(in: incoming)?.qlSource?.rowByURL[final] != nil }
        try check(pane.isVisible && pane.selection == [keep], "external download completion updates a remounted pane without losing selection")

        let peer = PaneModel(url: dir)
        peer.viewMode = 1
        peer.setVisible(true)
        defer { peer.stop() }
        try await until("icon pane initial listing") { peer.items.contains { $0.url == final } }
        let moved = dir.appending(path: "renamed.pdf")
        try external("/bin/mv", [final.path, moved.path])
        try await until("both views see external rename") {
            [pane, peer].allSatisfy { p in p.sortedItems.contains { $0.url == moved } && !p.sortedItems.contains { $0.url == final } }
        }
        peer.setVisible(false)
        try external("/bin/rm", [moved.path])
        try await until("remaining listener sees deletion") { !pane.sortedItems.contains { $0.url == moved } }
        try check(pane.selection == [keep] && !peer.isVisible, "removing one listener leaves the other pane live")
        peer.setVisible(true)
        try await until("inactive tab catches up") { !peer.loading && !peer.items.contains { $0.url == moved } }
        try check(peer.items.contains { $0.url == keep }, "returning to a tab reconciles its current contents")

        let before = peer.revision
        peer.refreshVisibleDirectory()
        for _ in 0..<20 { peer.refreshVisibleDirectory() }
        try await until("refresh arriving during a read is reconciled") { !peer.loading && peer.revision >= before + 2 }
        try check(peer.revision == before + 2, "a burst during a read publishes its snapshot and one follow-up instead of restarting each read")

        let alias = root.appending(path: "Linked Downloads")
        try fm.createSymbolicLink(at: alias, withDestinationURL: dir)
        peer.navigate(to: alias)
        try await until("linked directory listing") { !peer.loading }
        let next = dir.appending(path: "new.txt")
        try external("/usr/bin/touch", [next.path])
        try await until("change through real path appears in linked directory") { peer.sortedItems.contains { $0.name == "new.txt" } }
        try check(peer.currentURL == alias.standardizedFileURL && peer.items.first { $0.name == "new.txt" }?.url.deletingLastPathComponent().path == alias.path, "watching the physical directory preserves the displayed link path")
    }
}
