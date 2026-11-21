import Foundation

/// One write job at a time across all windows; queued jobs can be cancelled.
@MainActor
final class TransferScheduler {
    static let shared = TransferScheduler()
    private var owner: UUID?
    private var waiting: [(UUID, CheckedContinuation<Bool, Never>)] = []

    func acquire(_ id: UUID) async -> Bool {
        if owner == nil { owner = id; return true }
        return await withCheckedContinuation { waiting.append((id, $0)) }
    }

    func cancel(_ id: UUID) {
        if let i = waiting.firstIndex(where: { $0.0 == id }) {
            waiting.remove(at: i).1.resume(returning: false)
        }
    }

    func release(_ id: UUID) {
        guard owner == id else { return }
        if waiting.isEmpty { owner = nil }
        else {
            let next = waiting.removeFirst()
            owner = next.0
            next.1.resume(returning: true)
        }
    }
}
