import Foundation
import UniformTypeIdentifiers

/// The same explicit conditions are used for current-folder and recursive searches.
nonisolated struct SearchCriteria: Equatable, Sendable {
    var kind = ""
    var extensions = ""
    var days = 0
    var minBytes: Int64?
    var maxBytes: Int64?

    var isEmpty: Bool { kind.isEmpty && extensionList.isEmpty && days == 0 && minBytes == nil && maxBytes == nil }
    var extensionList: [String] {
        extensions.split(whereSeparator: { ", ;，".contains($0) })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased() }.filter { !$0.isEmpty }
    }

    static func bytes(fromMB text: String) throws -> Int64? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        guard let value = Double(text), value.isFinite, value >= 0,
              value * 1_000_000 < Double(Int64.max) else {
            throw FileOperationSafety.failure("Enter a non-negative size in MB.")
        }
        return Int64(value * 1_000_000)
    }

    func matches(_ item: FileItem, name: String, now: Date = Date()) -> Bool {
        matches(url: item.url, directory: item.isDirectory && !item.isPackage,
                size: item.size, modified: item.modified, name: name, now: now)
    }

    func matches(url: URL, directory: Bool, size: Int64?, modified: Date?, name: String, now: Date) -> Bool {
        if !name.isEmpty && url.lastPathComponent.range(of: name, options: [.caseInsensitive, .diacriticInsensitive]) == nil { return false }
        let ext = url.pathExtension.lowercased()
        if !extensionList.isEmpty && (directory || !extensionList.contains(ext)) { return false }
        switch kind {
        case "folders": if !directory { return false }
        case "images": if directory || UTType(filenameExtension: ext)?.conforms(to: .image) != true { return false }
        case "video": if directory || UTType(filenameExtension: ext)?.conforms(to: .movie) != true { return false }
        case "pdf": if directory || ext != "pdf" { return false }
        case "documents": if directory || !SearchGroup.documentExtensions.contains(ext) { return false }
        case "design": if directory || !SearchGroup.designExtensions.contains(ext) { return false }
        default: break
        }
        if days > 0 {
            let start = Calendar.current.startOfDay(for: now)
            guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: start),
                  let modified, modified >= cutoff else { return false }
        }
        if minBytes != nil || maxBytes != nil {
            guard !directory, let size else { return false }
            if let minBytes, size < minBytes { return false }
            if let maxBytes, size > maxBytes { return false }
        }
        return true
    }

    var summary: String {
        var parts: [String] = []
        if let title = SearchGroup.all.first(where: { $0.key == kind })?.title { parts.append(title) }
        if !extensionList.isEmpty { parts.append(extensionList.joined(separator: ", ")) }
        if days > 0 { parts.append("Last \(days) days") }
        if let minBytes { parts.append("≥ " + ByteCountFormatter.string(fromByteCount: minBytes, countStyle: .file)) }
        if let maxBytes { parts.append("≤ " + ByteCountFormatter.string(fromByteCount: maxBytes, countStyle: .file)) }
        return parts.joined(separator: " · ")
    }
}
