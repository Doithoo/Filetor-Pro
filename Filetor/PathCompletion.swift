import Foundation
import Observation

nonisolated struct PathCandidate: Identifiable, Equatable, Sendable {
    let url: URL
    let directory: Bool
    var id: URL { url }
}

@Observable final class PathCompletion {
    let base: URL
    var text: String
    private(set) var candidates: [PathCandidate] = []
    private(set) var loading = false
    private(set) var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(base: URL) {
        self.base = base
        text = (base.path as NSString).abbreviatingWithTildeInPath + (base.path == "/" ? "" : "/")
    }

    nonisolated private static func input(_ text: String) throws -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2, (value.first == "\"" && value.last == "\"") || (value.first == "'" && value.last == "'") {
            value = String(value.dropFirst().dropLast())
        }
        guard !value.contains("\0") else { throw FileOperationSafety.failure("Enter a valid file path.") }
        return value
    }

    nonisolated static func url(for text: String, base: URL) throws -> URL {
        var value = try input(text)
        if value.hasPrefix("file://"), let url = URL(string: value), url.isFileURL {
            return url.standardizedFileURL
        }
        guard !value.contains("://") else { throw FileOperationSafety.failure("Enter a local or mounted-volume path.") }
        value = (value as NSString).expandingTildeInPath
        if value.isEmpty { return base.standardizedFileURL }
        return URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: base.path, isDirectory: true)).standardizedFileURL
    }

    nonisolated static func list(_ text: String, base: URL, limit: Int? = 12,
                                foldersOnly: Bool = false, showHidden: Bool = false) throws -> [PathCandidate] {
        var value = try input(text)
        // Split incomplete input before standardizing: URL normalization removes
        // a trailing dot, which is also the prefix for hidden-file completion.
        if value.hasPrefix("file://"), let components = URLComponents(string: value),
           let decoded = components.percentEncodedPath.removingPercentEncoding {
            value = decoded
        }
        let inside = value.isEmpty || value.hasSuffix("/") || value == "~"
        let slash = value.lastIndex(of: "/")
        let prefixStart = slash.map { value.index(after: $0) } ?? value.startIndex
        let prefix = inside ? "" : String(value[prefixStart...])
        let parentText = inside ? value : slash.map { String(value[...$0]) } ?? ""
        let parent = try url(for: parentText, base: base)
        let urls = try FileManager.default.contentsOfDirectory(at: parent,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey], options: showHidden || prefix.hasPrefix(".") ? [] : [.skipsHiddenFiles])
        var results: [PathCandidate] = []
        for url in urls {
            try Task.checkCancellation()
            guard prefix.isEmpty || url.lastPathComponent.range(of: prefix, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil else { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            let directory = values?.isDirectory == true && values?.isPackage != true
            if foldersOnly && !directory { continue }
            results.append(PathCandidate(url: url.standardizedFileURL, directory: directory))
        }
        results.sort {
            if $0.directory != $1.directory { return $0.directory }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
        return limit.map { Array(results.prefix($0)) } ?? results
    }

    func update() {
        stop()
        let version = UUID(); generation = version
        let input = text, base = base
        candidates = []; error = nil; loading = true
        task = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            let worker = Task.detached(priority: .userInitiated) { try Self.list(input, base: base) }
            let result = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, self.generation == version else { return }
            self.loading = false
            switch result {
            case .success(let entries): self.candidates = entries
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }

    func stop() { task?.cancel(); task = nil; generation = UUID(); loading = false }

    nonisolated static func destination(_ url: URL) throws -> PathCandidate {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return PathCandidate(url: url.standardizedFileURL, directory: values.isDirectory == true && values.isPackage != true)
    }
}
