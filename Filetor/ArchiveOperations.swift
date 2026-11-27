import Foundation
import Darwin

/// System tools only. Each result is staged privately, then published without replacing an existing item.
nonisolated enum ArchiveOperations {
    enum Kind: Equatable { case container, gzip, bzip2 }
    struct Format: Equatable {
        let kind: Kind
        let name: String
    }
    struct Result: Sendable {
        var outputs: [URL] = []
        var failures: [String] = []
        var cancelled = false
    }

    static func format(_ url: URL) -> Format? {
        let name = url.lastPathComponent
        let lower = name.lowercased()
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz2", ".tbz", ".txz", ".zip", ".tar"] {
            if lower.hasSuffix(suffix), name.count > suffix.count {
                return Format(kind: .container, name: String(name.dropLast(suffix.count)))
            }
        }
        for (suffix, kind) in [(".gz", Kind.gzip), (".bz2", Kind.bzip2)] {
            if lower.hasSuffix(suffix), name.count > suffix.count {
                return Format(kind: kind, name: String(name.dropLast(suffix.count)))
            }
        }
        return nil
    }

    static func canExtract(_ url: URL) -> Bool {
        format(url) != nil && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    static func run(_ executable: String, _ arguments: [String], in staging: URL,
                    cwd: URL? = nil, output: URL? = nil, control: TransferControl) throws {
        if control.cancelled { throw CancellationError() }
        let errors = staging.appending(path: ".command-errors-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: errors.path, contents: nil) else {
            throw FileOperationSafety.failure(L10n.tr("Could not create the archive operation log."))
        }
        defer { try? FileManager.default.removeItem(at: errors) }
        let errorHandle = try FileHandle(forWritingTo: errors)
        defer { try? errorHandle.close() }
        var outputHandle: FileHandle?
        if let output {
            guard FileManager.default.createFile(atPath: output.path, contents: nil) else {
                throw FileOperationSafety.failure(L10n.tr("Could not create the decompressed file."))
            }
            outputHandle = try FileHandle(forWritingTo: output)
        }
        defer { try? outputHandle?.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle ?? FileHandle.nullDevice
        process.standardError = errorHandle
        var environment = ProcessInfo.processInfo.environment
        for key in ["TAR_OPTIONS", "TAR_READER_OPTIONS", "TAR_WRITER_OPTIONS", "GZIP", "BZIP", "BZIP2", "XZ_OPT", "XZ_DEFAULTS"] {
            environment.removeValue(forKey: key)
        }
        process.environment = environment
        try process.run()
        var cancellationTime: Date?
        while process.isRunning {
            if control.cancelled {
                if cancellationTime == nil { cancellationTime = Date(); process.terminate() }
                else if Date().timeIntervalSince(cancellationTime!) > 2 { kill(process.processIdentifier, SIGKILL) }
            }
            Thread.sleep(forTimeInterval: 0.04)
        }
        process.waitUntilExit()
        if control.cancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            let handle = try FileHandle(forReadingFrom: errors)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 16_384) ?? Data()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw FileOperationSafety.failure(text.isEmpty ? L10n.tr("The archive operation failed.") : text)
        }
    }

    private static func stage(in directory: URL) throws -> URL {
        let stage = directory.appending(path: ".filetor-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return stage
    }

    private static func publish(_ staged: URL, named name: String, in directory: URL, control: TransferControl) throws -> URL {
        if control.cancelled { throw CancellationError() }
        let target = FileTools.unique(directory.appending(path: name))
        // FileManager.moveItem refuses to replace an existing destination, including a race after unique().
        try FileManager.default.moveItem(at: staged, to: target)
        return target
    }

    static func compress(_ selection: [URL], in directory: URL, control: TransferControl) -> Result {
        var result = Result()
        let urls = FileOperationSafety.topLevel(selection)
        guard let first = urls.first else { return result }
        do {
            if control.cancelled { throw CancellationError() }
            for url in urls {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory == true, values.isSymbolicLink != true, FileOperationSafety.contains(url, directory) {
                    throw FileOperationSafety.failure(L10n.tr("Choose an output folder outside the folders being compressed."))
                }
            }
            let staging = try stage(in: directory)
            defer { try? FileManager.default.removeItem(at: staging) }
            let archive = staging.appending(path: "Archive.zip")
            control.setName(first.lastPathComponent)
            control.setTotal(1)
            let firstValues = try first.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if urls.count == 1 && firstValues.isSymbolicLink != true {
                var args = ["-c", "-k", "--sequesterRsrc"]
                if firstValues.isDirectory == true { args.append("--keepParent") }
                try run("/usr/bin/ditto", args + [first.path, archive.path], in: staging, control: control)
            } else {
                var root = first.deletingLastPathComponent().standardizedFileURL
                while !urls.allSatisfy({
                    let parent = $0.deletingLastPathComponent().standardizedFileURL.path
                    return parent == root.path || parent.hasPrefix(root.path == "/" ? "/" : root.path + "/")
                }) {
                    let next = root.deletingLastPathComponent()
                    if next == root { break }
                    root = next
                }
                let prefix = root.path == "/" ? "/" : root.path + "/"
                let paths = urls.map { "./" + String($0.standardizedFileURL.path.dropFirst(prefix.count)) }
                try run("/usr/bin/zip", ["-r", "-y", archive.path, "--"] + paths, in: staging, cwd: root, control: control)
            }
            let name = urls.count == 1 ? first.lastPathComponent + ".zip" : "Archive.zip"
            result.outputs.append(try publish(archive, named: name, in: directory, control: control))
            control.add(1)
        } catch is CancellationError { result.cancelled = true }
        catch { result.failures.append(error.localizedDescription) }
        return result
    }

    /// Without an explicit destination each archive is unpacked beside its source.
    static func extract(_ urls: [URL], in destination: URL? = nil, control: TransferControl) -> Result {
        var result = Result()
        control.setTotal(Int64(urls.count))
        for url in urls {
            do {
                if control.cancelled { throw CancellationError() }
                guard canExtract(url), let format = format(url), FileOperationSafety.validName(format.name) else {
                    throw FileOperationSafety.failure(L10n.tr("This format is not supported by built-in extraction. Use Open With to choose another application."))
                }
                control.setName(url.lastPathComponent)
                let directory = destination ?? url.deletingLastPathComponent()
                let staging = try stage(in: directory)
                defer { try? FileManager.default.removeItem(at: staging) }
                let contents = staging.appending(path: "Contents")
                try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: false)
                switch format.kind {
                case .container:
                    // Keep bsdtar's traversal/symlink protections; never pass -P or restore owner IDs.
                    // A nonempty random passphrase disables interactive prompts; encrypted input fails closed.
                    try run("/usr/bin/tar", ["-xf", url.path, "-C", contents.path, "--no-same-owner", "--no-same-permissions", "--mac-metadata", "--no-fflags", "--passphrase", UUID().uuidString], in: staging, control: control)
                case .gzip, .bzip2:
                    try run(format.kind == .gzip ? "/usr/bin/gzip" : "/usr/bin/bzip2", ["-dc", url.path],
                            in: staging, output: contents.appending(path: format.name), control: control)
                }
                result.outputs.append(try publish(contents, named: format.name, in: directory, control: control))
                control.add(1)
            } catch is CancellationError { result.cancelled = true; break }
            catch {
                result.failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                control.add(1)
            }
        }
        return result
    }
}
