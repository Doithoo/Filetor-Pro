import Foundation
import Observation

extension Regression {
    static func duplicateReportTests(_ root: URL) throws {
        let source = try folder(root, "duplicate-fixture")
        let target = try folder(root, "sync-target")
        for name in ["甲", "乙", "丙"] {
            _ = try file(try folder(source, name), "同名.txt")
        }
        let base = FileOperationSafety.RelativeRoot(URL(filePath: "/"))
        try check(base.relative(URL(filePath: "/甲/同名.txt")) == "甲/同名.txt"
                  && base.relative(URL(filePath: "/乙/同名.txt")) == "乙/同名.txt",
                  "root scan keeps same-named files in their respective subdirectories")
        let sibling = source.deletingLastPathComponent().appending(path: "duplicate-fixture-extra/file")
        try check(FileOperationSafety.RelativeRoot(source).relative(sibling) == nil, "relative paths reject adjacent prefix siblings")
        let sync = FolderAnalysis.syncRows(source, target)
        try check(Set(sync.map(\.rel)) == ["甲/同名.txt", "乙/同名.txt", "丙/同名.txt"], "sync preserves three distinct relative destinations")
        var report = FolderAnalysis.duplicates(source)
        guard let section = report.sections.first, section.rows.count == 3 else {
            throw FileOperationSafety.failure("Expected three duplicates")
        }
        report.finishTrash(row: section.rows[0].id, section: section.id, moved: false)
        try check(report.sections[0].rows.count == 3, "failed trash leaves all copies visible")
        report.finishTrash(row: section.rows[0].id, section: section.id, moved: true)
        try check(report.sections[0].rows.count == 2 && report.sections[0].title.contains("2"), "duplicate count follows successful trash")
        report.finishTrash(row: section.rows[1].id, section: section.id, moved: true)
        try check(report.sections.isEmpty && report.summary == L10n.tr("No duplicate files found in \(source.lastPathComponent)."), "last remaining copy is no longer offered for removal")
    }

    static func qualityTests(_ root: URL) async throws {
        try duplicateReportTests(root)
        let dir = try folder(root, "rows"), target = try folder(root, "local-move")
        let a = try file(dir, "first.txt"), b = try file(dir, "second.txt")
        let pane = PaneModel(url: dir)
        pane.items = try PaneModel.readDirectory(dir, hidden: true)
        let initial = pane.sortedItems
        pane.selection = [b]
        let cached = pane.sortedItems
        let reused = initial.withUnsafeBufferPointer { first in cached.withUnsafeBufferPointer { first.baseAddress == $0.baseAddress } }
        try check(reused, "changing selection reuses the sorted row storage")
        let invalidated = DispatchSemaphore(value: 0)
        withObservationTracking { _ = pane.sortedItems } onChange: { invalidated.signal() }
        pane.filter = "second"
        try check(invalidated.wait(timeout: .now()) == .success, "an observer of a cached result receives row changes")
        try check(pane.sortedItems.map(\.name) == ["second.txt"], "filter invalidates cached rows")
        pane.filter = ""
        pane.items.removeAll { $0.name == "first.txt" }
        try check(pane.sortedItems.map(\.name) == ["second.txt"], "in-place mutation invalidates cached rows")
        let control = TransferControl(), moving = engine(true, control: control)
        let failures = await moving.run(items: [(dir, target)])
        try check(failures.isEmpty && control.snapshot.done == 1 && control.snapshot.total == 1 && contents(target.appending(path: "rows/first.txt")) == "fixture", "same-volume directory move completes as one item")
        try check(TransferHistory(moving.records).undo() == nil && contents(a) == "fixture", "directory move can still be undone")

        let app = AppModel(), gate = DispatchSemaphore(value: 0)
        defer { gate.signal(); app.stop() }
        let old = Report(kind: .comparison, title: "old", summary: "", sections: [])
        let new = Report(kind: .comparison, title: "new", summary: "", sections: [])
        app.startReport(old) { _ = gate.wait(timeout: .now() + 4); return old }
        let prior = app.reportWorker
        app.startReport(new) { new }
        try await until("new report completed") { app.reportWorker == nil }
        gate.signal()
        _ = await prior?.value
        await Task.yield()
        try check(prior?.isCancelled == true && app.report?.id == new.id && app.report?.title == "new", "replaced scan cannot overwrite a newer report")

        let started = DispatchSemaphore(value: 0)
        let obsolete = Task.detached { await InfoPanel.selectionSize([a, b]) { _ in
            started.signal()
            let end = Date().addingTimeInterval(3)
            while !Task.isCancelled && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
            return 100
        } }
        try check(started.wait(timeout: .now() + 2) == .success, "inspector size worker starts")
        obsolete.cancel()
        let size = await InfoPanel.selectionSize([b])
        let obsoleteSize = await obsolete.value
        try check(size == 7 && obsoleteSize == nil, "rapid inspector change discards the old result")

        // Emit enough NUL-separated paths to cross read boundaries, including multibyte names and newlines.
        let perl = URL(filePath: "/usr/bin/perl")
        let urls = await SpotlightSearch.results(executable: perl, arguments: ["-e", "for (1..9000) {print qq(/tmp/目录\\n$_\\0)}"])
        try check(urls.count == 3000 && urls.first?.path == "/tmp/目录\n1" && urls.last?.path == "/tmp/目录\n3000", "Spotlight streams Unicode and newline paths up to its result limit")
        let marker = root.appending(path: "query-started")
        let search = Task { await SpotlightSearch.results(executable: perl, arguments: ["-e", "open(my $f, '>', $ARGV[0]) or die; close $f; sleep 8", marker.path]) }
        try await until("query started") { fm.fileExists(atPath: marker.path) }
        let start = Date()
        search.cancel()
        let result = await search.value
        try check(result.isEmpty && Date().timeIntervalSince(start) < 3, "cancelling a silent Spotlight process returns promptly")
    }
}
