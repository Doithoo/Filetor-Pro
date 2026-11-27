import AppKit

private final class FeedbackWindow: NSWindow {
    var deliveries: [NSEvent.EventType] = []
    override func sendEvent(_ event: NSEvent) { deliveries.append(event.type) }
}

extension Regression {
    static func interactionFeedbackTests(_ root: URL) async throws {
        let domain = "FiletorFeedbackTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        var cues: [InteractionFeedback.Cue] = []
        let feedback = InteractionFeedback(defaults: defaults) { cues.append($0) }
        for cue in InteractionFeedback.Cue.allCases {
            let duration = cue.loadSound()?.duration ?? 0
            try check(duration > 0 && duration < 0.2, "bundled short sound decodes: " + cue.rawValue)
        }
        let window = FeedbackWindow(contentRect: NSRect(x: 50, y: 50, width: 80, height: 80),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { feedback.stopMonitoring(); window.close() }
        func send(_ type: NSEvent.EventType) {
            let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: 10, y: 10), modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            NSApp.sendEvent(event)
        }
        feedback.startMonitoring()
        feedback.startMonitoring()
        send(.leftMouseDown); send(.leftMouseUp); send(.rightMouseDown); send(.rightMouseUp)
        try check(cues == [.click, .click] && window.deliveries.contains(.leftMouseDown), "one cue per press across repeated monitor setup; clicks still reach the window")
        defaults.set(false, forKey: InteractionFeedback.clickKey)
        send(.leftMouseDown)
        feedback.stopMonitoring()
        defaults.set(true, forKey: InteractionFeedback.clickKey)
        send(.leftMouseDown)
        try check(cues == [.click, .click], "muted clicks and stopped monitor are silent")
        cues.removeAll()

        let app = AppModel(feedback: feedback)
        defer { app.stop() }
        let source = try folder(root, "feedback-source"), dest = try folder(root, "feedback-destination")
        let a = try file(source, "one"), b = try file(source, "two")
        func transfer(_ files: [URL], move: Bool = true, conflict: ConflictChoice? = nil) async {
            await withCheckedContinuation { continuation in
                app.transfers.start(items: files.map { ($0, dest) }, move: move, conflict: conflict) { _ in continuation.resume() }
            }
        }
        await transfer([a,b])
        try check(cues == [.transfer] && !fm.fileExists(atPath: a.path) && contents(dest.appending(path: "two")) == "fixture",
                  "successful multi-file move plays one transfer cue")
        cues.removeAll()
        let again = try file(source, "one"), free = try file(source, "free")
        await transfer([again,free], conflict: .skip)
        await transfer([again], conflict: .stop)
        await transfer([dest.appending(path: "two")])
        await transfer([a.appendingPathComponent("missing")])
        try check(cues.isEmpty && contents(again) == "fixture" && contents(dest.appending(path: "free")) == "fixture",
                  "partial skip, stop, same-directory move and failure give no success cue")
        let copy = try file(source, "copy")
        await transfer([copy], move: false)
        try check(cues == [.transfer], "copy completes with the transfer cue")
        cues.removeAll()
        let gone = try file(source, "remove")
        app.deleteImmediately([gone, copy])
        try check(cues.isEmpty && fm.fileExists(atPath: gone.path), "asking to delete is silent")
        app.confirmDelete()
        try await until("delete completed") { !app.transfers.hasActive }
        try check(cues == [.removal] && !fm.fileExists(atPath: gone.path) && !fm.fileExists(atPath: copy.path),
                  "confirmed multi-file delete plays one distinct removal cue")
        cues.removeAll()
        app.deleteImmediately([gone,again]); app.confirmDelete()
        try await until("partial delete completed") { !app.transfers.hasActive }
        try check(cues.isEmpty && !fm.fileExists(atPath: again.path), "partial delete does not play success")
        let trash = try folder(root, "feedback-trash").resolvingSymlinksInPath()
        _ = try file(trash, "first"); _ = try file(trash, "second")
        app.pendingTrashDeletion = try TrashDeletion.snapshot(root: trash)
        app.confirmTrashDeletion()
        try await until("fixture trash emptied") { app.trashDeletionJob == nil }
        try check(cues == [.removal] && (try fm.contentsOfDirectory(atPath: trash.path)).isEmpty,
                  "emptying the fixture trash plays one removal cue")
        cues.removeAll()
        let disposable = try file(source, UUID().uuidString)
        let trashed: Set<URL> = await withCheckedContinuation { continuation in
            app.trash([disposable]) { continuation.resume(returning: $0) }
        }
        try check(cues == [.removal] && trashed.contains(disposable), "moving a fixture to Trash plays the removal cue")
        app.undo()
        try await until("restore disposable fixture") { !app.historyBusy }
        try check(contents(disposable) == "fixture", "trashed fixture is restored before cleanup")
        cues.removeAll()
        defaults.set(false, forKey: InteractionFeedback.operationsKey)
        let quiet = try file(source, "quiet")
        await transfer([quiet])
        try check(cues.isEmpty && contents(dest.appending(path: "quiet")) == "fixture", "muting operation sounds leaves transfers working")
    }
}
