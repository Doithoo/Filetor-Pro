import Foundation
import Darwin

nonisolated enum BuiltinPreviewKind: Equatable {
    case folder, zip, text, markdown, json, plist, system

    static func forURL(_ url: URL) -> Self {
        let item = FileItem(url: url)
        if item.expandable { return .folder }
        if item.isDirectory || item.isSymbolicLink { return .system }
        let ext = url.pathExtension.lowercased()
        if ext == "zip" { return .zip }
        if ["md", "markdown", "mdown"].contains(ext) { return .markdown }
        if ext == "json" || ext == "geojson" { return .json }
        if ext == "plist" { return .plist }
        let extensions: Set<String> = ["txt", "log", "csv", "tsv", "swift", "m", "mm", "h", "c", "cpp", "cc", "hpp", "cs", "java", "kt", "kts", "py", "pyw", "rb", "go", "rs", "js", "jsx", "ts", "tsx", "vue", "svelte", "html", "htm", "css", "scss", "less", "sh", "bash", "zsh", "fish", "sql", "r", "lua", "php", "yaml", "yml", "toml", "ini", "conf", "cfg", "xml", "jsonl", "ndjson", "gitignore", "env", "dockerfile", "makefile"]
        let names: Set<String> = ["readme", "license", "licence", "copying", "authors", "changelog", "makefile", "dockerfile", ".gitignore", ".gitattributes", ".editorconfig", ".env", ".zshrc", ".bashrc"]
        return extensions.contains(ext) || names.contains(url.lastPathComponent.lowercased()) ? .text : .system
    }
}

/// Never open devices, FIFOs or symbolic links as preview data sources.
nonisolated final class PreviewFile {
    let handle: FileHandle
    let size: UInt64
    init(_ url: URL) throws {
        let fd = url.withUnsafeFileSystemRepresentation { Darwin.open($0!, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else {
            Darwin.close(fd)
            throw Self.error(L10n.tr("Preview requires a readable regular file."))
        }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        size = UInt64(info.st_size)
    }
    deinit { try? handle.close() }

    func read(at offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, offset <= size, UInt64(count) <= size - offset else { throw Self.error(L10n.tr("The file is incomplete or changed while being read.")) }
        try handle.seek(toOffset: offset)
        var result = Data()
        while result.count < count {
            let part = try handle.read(upToCount: count - result.count) ?? Data()
            guard !part.isEmpty else { throw Self.error(L10n.tr("The file changed while being read. Refresh to try again.")) }
            result.append(part)
        }
        return result
    }

    static func error(_ message: String) -> NSError {
        NSError(domain: "FiletorPreview", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

nonisolated enum PreviewWork {
    private static let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "Filetor archive and text previews"
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()

    static func start<T: Sendable>(_ work: @escaping @Sendable (Operation) throws -> T,
                                  completion: @escaping @MainActor @Sendable (Result<T, Error>) -> Void) -> Operation {
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak operation] in
            guard let operation, !operation.isCancelled else { return }
            let result = Result { try work(operation) }
            guard !operation.isCancelled else { return }
            Task { @MainActor in completion(result) }
        }
        queue.addOperation(operation)
        return operation
    }
}
