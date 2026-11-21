import Foundation

/// Each item remembers completed phases, so retrying a partially failed undo is safe.
/// Called serially by the workspace's history task, off the main actor.
nonisolated final class TransferHistory: @unchecked Sendable {
    private struct Entry {
        var record: TransferRecord
        var savedResult: URL?
        var resultAtDestination = true
        var originalAtDestination = false
    }
    private var entries: [Entry]
    private let lock = NSLock()
    private let fm = FileManager.default

    init(_ records: [TransferRecord]) { entries = records.map { Entry(record: $0) } }

    private func move(_ source: URL, to destination: URL) throws {
        guard !FileOperationSafety.exists(destination) else {
            throw FileOperationSafety.failure("\(destination.path) already exists. Move it aside before retrying.")
        }
        try fm.moveItem(at: source, to: destination)
    }

    private func preserve(_ url: URL) throws -> URL {
        var result: NSURL?
        do {
            try fm.trashItem(at: url, resultingItemURL: &result)
            guard let result else { throw FileOperationSafety.failure("The system did not return a recovery location for \(url.path).") }
            return result as URL
        } catch {
            guard FileOperationSafety.exists(url) else { throw error }
            let backup = url.deletingLastPathComponent().appending(path: ".filetor-undo-\(UUID().uuidString)")
            try move(url, to: backup)
            return backup
        }
    }

    func undo() -> String? {
        lock.lock(); defer { lock.unlock() }
        var errors: [String] = []
        for i in entries.indices.reversed() {
            let r = entries[i].record
            let originalDestination = r.originalURL ?? r.dst
            do {
                if entries[i].resultAtDestination {
                    if r.moved {
                        try fm.createDirectory(at: r.src.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try move(r.dst, to: r.src)
                    } else {
                        entries[i].savedResult = try preserve(r.dst)
                    }
                    entries[i].resultAtDestination = false
                }
                if let original = r.trashed, !entries[i].originalAtDestination {
                    try move(original, to: originalDestination)
                    entries[i].originalAtDestination = true
                }
            } catch { errors.append("\(r.dst.path): \(error.localizedDescription)") }
        }
        return errors.isEmpty ? nil : errors.joined(separator: "\n") + "\nCompleted items are remembered. Retry Undo after resolving the problem."
    }

    func redo() -> String? {
        lock.lock(); defer { lock.unlock() }
        var errors: [String] = []
        for i in entries.indices {
            let r = entries[i].record
            let originalDestination = r.originalURL ?? r.dst
            do {
                if entries[i].originalAtDestination {
                    // Keep the restored original on its own volume until redo commits.
                    let backup = originalDestination.deletingLastPathComponent().appending(path: ".filetor-backup-\(UUID().uuidString)")
                    try move(originalDestination, to: backup)
                    entries[i].record.trashed = backup
                    entries[i].originalAtDestination = false
                }
                if !entries[i].resultAtDestination {
                    guard let source = r.moved ? r.src : entries[i].savedResult else {
                        throw FileOperationSafety.failure("The undo recovery item is unavailable.")
                    }
                    try move(source, to: r.dst)
                    entries[i].resultAtDestination = true
                    entries[i].savedResult = nil
                }
            } catch {
                // If redo could not commit, put the original destination back.
                if !entries[i].resultAtDestination, !entries[i].originalAtDestination,
                   let original = entries[i].record.trashed, !FileOperationSafety.exists(originalDestination) {
                    do { try move(original, to: originalDestination); entries[i].originalAtDestination = true }
                    catch { errors.append("Original preserved at \(original.path).") }
                }
                errors.append("\(r.dst.path): \(error.localizedDescription)")
            }
        }
        return errors.isEmpty ? nil : errors.joined(separator: "\n") + "\nCompleted items are remembered. Retry Redo after resolving the problem."
    }
}
