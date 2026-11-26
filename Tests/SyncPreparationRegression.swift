import Foundation

extension Regression {
    static func syncPreparationTests(_ root: URL) async throws {
        let left = try folder(root, "sync-prep-left"), right = try folder(root, "sync-prep-right")
        let nested = try folder(left, "正常"), blocked = try folder(left, "blocked")
        _ = try file(nested, "one.txt", "one"); _ = try file(nested, "two.txt", "two")
        _ = try file(blocked, "three.txt"); _ = try file(blocked, "four.txt")
        let obstacle = try file(right, "blocked", "keep this")
        let fromRight = try folder(right, "other")
        _ = try file(fromRight, "one.txt", "back")
        func session() -> SyncSession {
            let session = SyncSession(left: left, right: right)
            session.rows = FolderAnalysis.syncRows(left, right)
            session.applyDirection()
            // A file on the receiving side prevents creation of this directory.
            // Do not copy that file back into the existing source directory.
            for i in session.rows.indices where session.rows[i].rel == "blocked" { session.rows[i].action = .skip }
            session.loading = false
            return session
        }

        let app = AppModel(), selected = session(), entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        defer { resume.signal(); app.stop() }
        app.sync = selected
        app.runSync(selected) { dir in
            if Thread.isMainThread { throw FileOperationSafety.failure("Preparation ran on main thread") }
            if dir.lastPathComponent == "正常" {
                entered.signal()
                guard resume.wait(timeout: .now() + 4) == .success else { throw FileOperationSafety.failure("Unresponsive UI") }
            }
            try SyncPreparation.createDirectory(dir)
        }
        // Entering twice must not start a second copy from a stale sheet.
        app.runSync(selected)
        try await until("slow background directory preparation") { entered.wait(timeout: .now()) == .success }
        try check(app.sync == nil && app.transfers.jobs.count == 1 && AppModel.hasActiveFileOperations,
                  "main actor stays responsive and tracks one job during slow sync preparation")
        resume.signal()
        try await until("two-way sync complete") { !app.transfers.hasActive }
        let copy = right.appending(path: "正常/one.txt"), reverse = left.appending(path: "other/one.txt")
        try check(contents(copy) == "one" && contents(right.appending(path: "正常/two.txt")) == "two" && contents(reverse) == "back",
                  "a failed destination does not block good files in either direction")
        try check(contents(obstacle) == "keep this" && app.alert?.components(separatedBy: "\n").count == 1 && app.alert?.contains(obstacle.path) == true,
                  "repeated errors for one destination are reported once and leave existing files untouched")
        try check(app.undoSteps.count == 1 && app.syncBatches.isEmpty, "both directions finish as a single undo step")
        app.undo()
        try await until("sync undo") { !app.historyBusy }
        try check(!fm.fileExists(atPath: copy.path) && !fm.fileExists(atPath: reverse.path) && contents(nested.appending(path: "one.txt")) == "one",
                  "undo reverses both successful directions and leaves originals intact")

        let delayed = session(), started = DispatchSemaphore(value: 0), finish = DispatchSemaphore(value: 0)
        defer { finish.signal() }
        app.sync = delayed
        app.runSync(delayed) { _ in started.signal(); _ = finish.wait(timeout: .now() + 4) }
        try await until("cancellable preparation") { started.wait(timeout: .now()) == .success }
        guard let job = app.transfers.jobs.first(where: { !$0.isFinished }) else { throw FileOperationSafety.failure("Missing preparation job") }
        app.transfers.cancel(job)
        finish.signal()
        try await until("cancelled sync released") { !app.transfers.hasActive }
        try check(app.undoSteps.isEmpty && app.syncBatches.isEmpty && !fm.fileExists(atPath: copy.path) && !fm.fileExists(atPath: reverse.path),
                  "cancelling during preparation starts no transfer and creates no undo step")

        let onlyBad = session()
        onlyBad.rows.removeAll { !$0.rel.hasPrefix("blocked/") }
        app.sync = onlyBad
        app.runSync(onlyBad)
        try await until("failed preparation released") { !app.transfers.hasActive }
        try check(app.syncBatches.isEmpty && app.undoSteps.isEmpty, "zero usable destinations leave no pending sync batch")

        app.redo()
        try await until("sync redo") { !app.historyBusy }
        try check(contents(copy) == "one" && contents(reverse) == "back",
                  "redo restores both directions after a cancelled or failed preparation")

        // Isolate the planning workload from file copying: 10,000 selected
        // paths in 20 folders. Creating each directory twice must fail the test.
        let target = try folder(root, "bulk-plan")
        let rows = (0..<10_000).map { i in
            let rel = "目录-\(i % 20)/项目-\(i).txt"
            return SyncRow(rel: rel, left: SyncSide(url: left.appending(path: rel, directoryHint: .notDirectory), size: 1, date: .distantPast), right: nil, action: .toRight)
        }
        let snapshot = SyncPreparation(rows: rows, leftRoot: left, rightRoot: target)
        let plan = await Task.detached {
            snapshot.prepare(control: TransferControl()) {
                if FileOperationSafety.exists($0) { throw FileOperationSafety.failure("Directory prepared twice") }
                try SyncPreparation.createDirectory($0)
            }
        }.value
        try check(plan?.right.count == 10_000 && plan?.errors.isEmpty == true && (try fm.contentsOfDirectory(atPath: target.path)).count == 20,
                  "10,000 sync rows prepare exactly 20 distinct destinations and retain every file")
    }
}
