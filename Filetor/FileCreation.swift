import Foundation

enum NewFileKind: String, CaseIterable, Identifiable {
    case text, markdown, csv, json, empty
    var id: String { rawValue }
    var title: String {
        switch self {
        case .text: return "Text Document (.txt)"
        case .markdown: return "Markdown Document (.md)"
        case .csv: return "CSV Document (.csv)"
        case .json: return "JSON Document (.json)"
        case .empty: return "Empty File"
        }
    }
    var filename: String {
        switch self {
        case .text: return "untitled.txt"
        case .markdown: return "untitled.md"
        case .csv: return "untitled.csv"
        case .json: return "untitled.json"
        case .empty: return "untitled"
        }
    }
    var contents: Data { Data((self == .json ? "{}\n" : "").utf8) }
}

enum FileCreation {
    static func canCreate(in directory: URL) -> Bool {
        guard directory.isFileURL, !TrashLocation.contains(directory) else { return false }
        let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    static func create(_ kind: NewFileKind, in directory: URL) throws -> URL {
        guard canCreate(in: directory) else {
            throw FileOperationSafety.failure("Choose a regular folder to create a file.")
        }
        let base = directory.appendingPathComponent(kind.filename)
        for _ in 0..<100 {
            let url = FileTools.unique(base)
            do {
                // Exclusive creation also protects a file that appears after naming.
                try kind.contents.write(to: url, options: .withoutOverwriting)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists { continue }
        }
        throw FileOperationSafety.failure("Could not find an available file name. Please try again.")
    }
}
