import Foundation

/// A snapshot of the choices at the moment the user confirms synchronization.
nonisolated struct SyncPreparation: Sendable {
    let rows: [SyncRow]
    let leftRoot: URL
    let rightRoot: URL

    typealias Item = (src: URL, dstDir: URL)
    typealias CreateDirectory = @Sendable (URL) throws -> Void

    struct Plan: Sendable {
        var right: [Item] = []
        var left: [Item] = []
        var errors: [String] = []
    }

    static func createDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func prepare(control: TransferControl, create: CreateDirectory) -> Plan? {
        var plan = Plan()
        var ready: [URL: Bool] = [:]
        var failureCount = 0
        for row in rows {
            guard !control.cancelled else { return nil }
            let root: URL, source: URL?
            switch row.action {
            case .skip: continue
            case .toRight: root = rightRoot; source = row.left?.url
            case .toLeft: root = leftRoot; source = row.right?.url
            }
            guard let source else { continue }
            let directory = root.appending(path: row.rel, directoryHint: .notDirectory).deletingLastPathComponent()
            if ready[directory] == nil {
                do {
                    try create(directory)
                    ready[directory] = true
                } catch {
                    ready[directory] = false
                    failureCount += 1
                    if plan.errors.count < 5 { plan.errors.append("\(directory.path): \(error.localizedDescription)") }
                }
            }
            guard ready[directory] == true else { continue }
            if row.action == .toRight { plan.right.append((source, directory)) }
            else { plan.left.append((source, directory)) }
        }
        if failureCount > plan.errors.count {
            plan.errors.append(L10n.tr("… and \(failureCount - plan.errors.count) more"))
        }
        return control.cancelled ? nil : plan
    }
}
