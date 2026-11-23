import AppKit

/// Use the system's document associations, not a hard-coded list of archive products.
enum OpenWithApplications {
    static func candidates(
        for selection: Set<URL>,
        applications: (URL) -> [URL] = { NSWorkspace.shared.urlsForApplications(toOpen: $0) },
        preferred: (URL) -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: $0) },
        isInstalled: (URL) -> Bool = {
            $0.pathExtension.lowercased() == "app" &&
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        },
        displayName: (URL) -> String = { FileManager.default.displayName(atPath: $0.path) }
    ) -> [URL] {
        let files = selection.sorted { $0.path < $1.path }
        guard let first = files.first else { return [] }
        func normalized(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardizedFileURL }
        var matches = Set(applications(first).map(normalized).filter(isInstalled))
        // A multi-selection must be supported in full, not just its first file.
        for file in files.dropFirst() {
            if matches.isEmpty { break }
            matches.formIntersection(applications(file).map(normalized))
        }
        let defaultApp = preferred(first).map(normalized)
        return matches.sorted { a, b in
            if a == defaultApp { return true }
            if b == defaultApp { return false }
            let comparison = displayName(a).localizedStandardCompare(displayName(b))
            return comparison == .orderedSame ? a.path < b.path : comparison == .orderedAscending
        }
    }
}
