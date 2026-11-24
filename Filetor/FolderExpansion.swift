import Foundation

/// Bounded recursive enumeration for the inline list. Packages and links remain leaves.
nonisolated enum FolderExpansion {
    struct Limits: Sendable {
        var folders = 2_000
        var items = 20_000
        var depth = 64
    }

    struct Result: Sendable {
        var children: [URL: [FileItem]] = [:]
        var errors: [URL: String] = [:]
        var limited = false
    }

    static func read(roots: [FileItem], hidden: Bool, limits: Limits) throws -> Result {
        var result = Result()
        var queue = roots.filter(\.expandable).map { ($0.url, 1) }
        var index = 0
        var count = roots.count
        while index < queue.count {
            try Task.checkCancellation()
            guard index < limits.folders, count < limits.items else {
                result.limited = true
                break
            }
            let (url, depth) = queue[index]
            index += 1
            guard depth <= limits.depth else { result.limited = true; continue }
            do {
                let urls = try FileManager.default.contentsOfDirectory(at: url,
                    includingPropertiesForKeys: FileItem.keys,
                    options: hidden ? [] : [.skipsHiddenFiles])
                // Never display a partial directory as though it were complete.
                guard urls.count <= limits.items - count else { result.limited = true; continue }
                let children = try urls.map { child in
                    try Task.checkCancellation()
                    return FileItem(url: child)
                }
                count += children.count
                result.children[url] = children
                queue += children.filter(\.expandable).map { ($0.url, depth + 1) }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result.errors[url] = error.localizedDescription
            }
        }
        return result
    }
}
