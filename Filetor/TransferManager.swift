import SwiftUI
import Observation

@Observable
final class TransferJob: Identifiable {
    let id = UUID()
    let title: String
    let control = TransferControl()
    var fraction: Double = 0
    var currentName = ""
    var isFinished = false
    var cancellable = true
    var indeterminate = false

    init(title: String) { self.title = title }
}

final class ConflictRequest: Identifiable {
    let id = UUID()
    let info: ConflictInfo
    let jobID: UUID
    let continuation: CheckedContinuation<ConflictAnswer, Never>
    init(info: ConflictInfo, jobID: UUID, continuation: CheckedContinuation<ConflictAnswer, Never>) {
        self.info = info
        self.jobID = jobID
        self.continuation = continuation
    }
}

@Observable
final class TransferManager {
    var jobs: [TransferJob] = []
    private var queue: [ConflictRequest] = []

    var onFinished: (() -> Void)?
    var onError: ((String) -> Void)?
    var onCompleted: ((_ move: Bool, _ records: [TransferRecord], _ batch: UUID?) -> Void)?

    var pending: ConflictRequest? { queue.first }
    var hasActive: Bool { jobs.contains { !$0.isFinished } }
    var overall: Double {
        let active = jobs.filter { !$0.isFinished }
        guard !active.isEmpty else { return 0 }
        return active.map(\.fraction).reduce(0, +) / Double(active.count)
    }

    func start(items: [(src: URL, dstDir: URL)], move: Bool, conflict: ConflictChoice? = nil, batch: UUID? = nil,
               completion: (([TransferRecord]) -> Void)? = nil) {
        guard !items.isEmpty else { return }
        let verb = move ? L10n.tr("Moving") : L10n.tr("Copying")
        let title = items.count == 1 ? "\(verb) \(items[0].src.lastPathComponent)" : L10n.tr("\(verb) \(items.count) items")
        let job = TransferJob(title: title)
        jobs.append(job)

        let engine = TransferEngine(move: move, control: job.control, preset: conflict) { [weak self] info in
            await self?.askUser(info, job: job) ?? ConflictAnswer(choice: .stop, applyToAll: false)
        }
        let pairs = items

        Task {
            job.currentName = L10n.tr("Waiting for other file operations…")
            let acquired = await TransferScheduler.shared.acquire(job.id)
            guard acquired, !job.control.cancelled else {
                if acquired { TransferScheduler.shared.release(job.id) }
                jobs.removeAll { $0.id == job.id }
                if batch != nil { onCompleted?(move, [], batch) }
                completion?([])
                return
            }
            // Poll shared progress while the engine works in the background.
            let poller = Task { @MainActor in
                while !Task.isCancelled {
                    let s = job.control.snapshot
                    job.fraction = min(Double(s.done) / Double(s.total), 1)
                    job.currentName = s.name
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            let failures = await Task.detached(priority: .userInitiated) {
                await engine.run(items: pairs)
            }.value
            poller.cancel()
            TransferScheduler.shared.release(job.id)
            if !job.control.cancelled && failures.isEmpty { job.fraction = 1 }
            job.currentName = job.control.cancelled ? L10n.tr("Cancelled") : (failures.isEmpty ? L10n.tr("Completed") : L10n.tr("Completed with errors"))
            job.isFinished = true
            onFinished?()
            if !engine.records.isEmpty || batch != nil { onCompleted?(move, engine.records, batch) }
            completion?(engine.records)
            if !failures.isEmpty {
                onError?(failures.joined(separator: "\n"))
            }
            try? await Task.sleep(for: .seconds(1))
            jobs.removeAll { $0.id == job.id }
        }
    }

    func cancel(_ job: TransferJob) {
        guard job.cancellable, !job.isFinished else { return }
        job.control.cancelled = true
        TransferScheduler.shared.cancel(job.id)
        let cancelled = queue.filter { $0.jobID == job.id }
        queue.removeAll { $0.jobID == job.id }
        cancelled.forEach { $0.continuation.resume(returning: ConflictAnswer(choice: .stop, applyToAll: false)) }
        job.currentName = L10n.tr("Cancelling…")
    }

    func cancelAll() { jobs.forEach { cancel($0) } }

    private func askUser(_ info: ConflictInfo, job: TransferJob) async -> ConflictAnswer {
        guard !job.control.cancelled else { return ConflictAnswer(choice: .stop, applyToAll: false) }
        return await withCheckedContinuation { cont in
            queue.append(ConflictRequest(info: info, jobID: job.id, continuation: cont))
        }
    }

    func answer(_ choice: ConflictChoice, applyToAll: Bool) {
        guard !queue.isEmpty else { return }
        let req = queue.removeFirst()
        req.continuation.resume(returning: ConflictAnswer(choice: choice, applyToAll: applyToAll))
    }
}

// MARK: - Views

struct ConflictSheet: View {
    let request: ConflictRequest
    let manager: TransferManager
    @State private var applyToAll = false

    private func describe(isDir: Bool, size: Int64, date: Date?) -> String {
        let s = isDir ? L10n.tr("Folder") : ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        let d = date?.formatted(date: .abbreviated, time: .shortened) ?? ""
        return d.isEmpty ? s : "\(s), \(d)"
    }

    var body: some View {
        let i = request.info
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("\"\(i.name)\" already exists in this location."))
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("Existing: ") + describe(isDir: i.dstIsDir, size: i.dstSize, date: i.dstDate))
                Text(L10n.tr("New: ") + describe(isDir: i.srcIsDir, size: i.srcSize, date: i.srcDate))
            }
            .foregroundStyle(.secondary)

            Toggle(L10n.tr("Apply to all"), isOn: $applyToAll)

            HStack {
                Button(L10n.tr("Stop")) { manager.answer(.stop, applyToAll: false) }
                Spacer()
                Button(L10n.tr("Skip")) { manager.answer(.skip, applyToAll: applyToAll) }
                Button(L10n.tr("Keep Both")) { manager.answer(.keepBoth, applyToAll: applyToAll) }
                if i.srcIsDir && i.dstIsDir {
                    Button(L10n.tr("Merge")) { manager.answer(.merge, applyToAll: applyToAll) }
                }
                Button(L10n.tr("Replace")) { manager.answer(.replace, applyToAll: applyToAll) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled()
    }
}

struct TransferList: View {
    let manager: TransferManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(manager.jobs) { job in
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.title).font(.callout)
                    HStack {
                        if job.indeterminate { ProgressView().controlSize(.small) }
                        else { ProgressView(value: job.fraction) }
                        if job.cancellable && !job.isFinished {
                          Button { manager.cancel(job) } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .help(L10n.tr("Cancel"))
                        }
                    }
                    Text(job.currentName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}
