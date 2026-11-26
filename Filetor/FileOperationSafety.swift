import Foundation
import Darwin

/// Shared filesystem rules for list, tree, search and drag selections.
nonisolated enum FileOperationSafety {
    /// Lexical path relative to a standardized enumeration root, including "/" itself.
    struct RelativeRoot {
        private let path: String
        private let prefix: String

        init(_ root: URL) {
            path = root.standardizedFileURL.path
            prefix = path == "/" ? "/" : path + "/"
        }

        func relative(_ url: URL) -> String? {
            let full = url.standardizedFileURL.path
            if full == path { return "" }
            guard let match = full.range(of: prefix, options: [.anchored, .literal]) else { return nil }
            return String(full[match.upperBound...])
        }
    }

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "Filetor", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    static func sameItem(_ a: URL, _ b: URL) -> Bool {
        var sa = stat(), sb = stat()
        return lstat(a.path, &sa) == 0 && lstat(b.path, &sb) == 0
            && sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
    }

    /// Includes equality, resolves directory aliases, and respects component boundaries.
    static func contains(_ parent: URL, _ child: URL) -> Bool {
        let root = parent.resolvingSymlinksInPath().standardizedFileURL
        var path = child.resolvingSymlinksInPath().standardizedFileURL.path
        while true {
            if path == root.path || sameItem(root, URL(fileURLWithPath: path)) { return true }
            guard path != "/", !path.isEmpty else { return false }
            let next = (path as NSString).deletingLastPathComponent
            guard next != path else { return false }
            path = next
        }
    }

    /// A selected directory already includes its selected descendants. Symlinks are leaves.
    static func topLevel(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        let sorted = urls.filter { seen.insert($0.standardizedFileURL.path).inserted }.sorted {
            if $0.pathComponents.count != $1.pathComponents.count { return $0.pathComponents.count < $1.pathComponents.count }
            return $0.path < $1.path
        }
        var result: [URL] = []
        for url in sorted {
            if result.contains(where: { ancestor in
                let v = try? ancestor.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return v?.isDirectory == true && v?.isSymbolicLink != true && contains(ancestor, url.deletingLastPathComponent())
            }) { continue }
            result.append(url)
        }
        return result
    }
}

/// Once the destination is complete, atomically remove the source name before
/// recursive cleanup. A partial remove must never look like an intact source.
nonisolated enum SourceRetirement {
    static func run(_ source: URL, remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) throws -> URL? {
        let staging = source.deletingLastPathComponent().appending(path: ".filetor-moved-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: source, to: staging)
        do { try remove(staging); return nil }
        catch { return staging }
    }
}

/// A reversible two-phase rename. Each failure restores every name already changed.
nonisolated enum RenameTransaction {
    typealias Move = (from: URL, to: URL)

    static func run(_ moves: [Move], move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws {
        guard !moves.isEmpty else { return }
        let sources = Set(moves.map { $0.from.standardizedFileURL.path })
        guard sources.count == moves.count else { throw FileOperationSafety.failure(L10n.tr("A file was selected more than once.")) }
        var destinations = Set<String>()
        for m in moves {
            let name = m.to.lastPathComponent
            guard FileOperationSafety.validName(name), m.from.deletingLastPathComponent().standardizedFileURL == m.to.deletingLastPathComponent().standardizedFileURL else {
                throw FileOperationSafety.failure(L10n.tr("Invalid file name."))
            }
            guard destinations.insert(m.to.standardizedFileURL.path).inserted else {
                throw FileOperationSafety.failure(L10n.tr("Two files would get the same name."))
            }
            if FileOperationSafety.exists(m.to), !moves.contains(where: { FileOperationSafety.sameItem($0.from, m.to) }) {
                throw FileOperationSafety.failure(L10n.tr("\"\(name)\" already exists."))
            }
            if moves.contains(where: { other in
                other.from != m.from && FileOperationSafety.contains(other.from, m.from.deletingLastPathComponent())
            }) { throw FileOperationSafety.failure(L10n.tr("Rename folders and their contents separately.")) }
        }
        var staged: [(original: URL, temporary: URL, final: URL)] = []
        var committed = 0
        do {
            for m in moves {
                let tmp = m.from.deletingLastPathComponent().appending(path: ".filetor-rename-\(UUID().uuidString)")
                try move(m.from, tmp)
                staged.append((m.from, tmp, m.to))
            }
            for entry in staged {
                try move(entry.temporary, entry.final)
                committed += 1
            }
        } catch {
            let originalError = error.localizedDescription
            var recovery: [String] = []
            // Move finals back to their temporary names first, so swaps can roll back too.
            for entry in staged.prefix(committed).reversed() {
                do { try move(entry.final, entry.temporary) }
                catch { recovery.append("\(entry.final.path): \(error.localizedDescription)") }
            }
            for entry in staged.reversed() where FileOperationSafety.exists(entry.temporary) {
                do { try move(entry.temporary, entry.original) }
                catch { recovery.append(L10n.tr("Recover \(entry.temporary.path) to \(entry.original.path): \(error.localizedDescription)")) }
            }
            throw FileOperationSafety.failure(originalError + (recovery.isEmpty ? L10n.tr("\nOriginal names restored.") : L10n.tr("\nRecovery needed:\n") + recovery.joined(separator: "\n")))
        }
    }
}
