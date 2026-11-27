import AppKit
import SwiftUI

extension Regression {
    static func archiveActionsTests(_ root: URL) async throws {
        let inputs = try folder(root, "压缩 输入"), output = try folder(root, "解压 输出")
        let payload = "中文 payload\n" + String(repeating: "1234567890", count: 200)
        let original = try file(inputs, "-中文 空格.txt", payload)
        let source = try folder(inputs, "资料")
        let leaf = try file(source, "文件.txt", payload)
        let scratch = try folder(root, "Archive commands")
        func packed(_ ext: String, flags: [String]) throws -> URL {
            let archive = inputs.appending(path: "资料." + ext)
            try ArchiveOperations.run("/usr/bin/tar", flags + [archive.path, "-C", inputs.path, "资料"], in: scratch, control: TransferControl())
            return archive
        }
        for (ext, flags) in [("tar", ["-cf"]), ("tar.gz", ["-czf"]), ("tgz", ["-czf"]),
                             ("tar.bz2", ["-cjf"]), ("tbz2", ["-cjf"]), ("tbz", ["-cjf"]),
                             ("tar.xz", ["-cJf"]), ("txz", ["-cJf"])] {
            let archive = try packed(ext, flags: flags)
            let result = ArchiveOperations.extract([archive], in: output, control: TransferControl())
            if !result.failures.isEmpty { print(result.failures.joined(separator: "\n")) }
            try check(result.failures.isEmpty && result.outputs.count == 1 && contents(result.outputs[0].appending(path: "资料/文件.txt")) == payload
                      && FileTools.exists(archive), "built-in extraction preserves Unicode data and source for \(ext)")
            try check(result.outputs[0].lastPathComponent.hasPrefix("资料") && !result.outputs[0].lastPathComponent.contains(".tar"),
                      "compound \(ext) removes the full archive suffix and keeps existing results")
        }
        for (ext, tool) in [("gz", "/usr/bin/gzip"), ("bz2", "/usr/bin/bzip2")] {
            let archive = inputs.appending(path: "-中文 空格.txt." + ext)
            try ArchiveOperations.run(tool, ["-c", original.path], in: scratch, output: archive, control: TransferControl())
            let result = ArchiveOperations.extract([archive], in: output, control: TransferControl())
            try check(result.failures.isEmpty && contents(result.outputs[0].appending(path: "-中文 空格.txt")) == payload
                      && contents(original) == payload && FileTools.exists(archive), "raw \(ext) becomes one complete file, not a TAR error")
        }
        let compressed = ArchiveOperations.compress([original, leaf], in: output, control: TransferControl())
        try check(compressed.failures.isEmpty && compressed.outputs.count == 1, "ZIP compression stages a multi-folder selection")
        let expanded = ArchiveOperations.extract(compressed.outputs, in: output, control: TransferControl())
        try check(expanded.failures.isEmpty && contents(expanded.outputs[0].appending(path: "资料/文件.txt")) == payload
                  && contents(expanded.outputs[0].appending(path: "-中文 空格.txt")) == payload, "built-in ZIP round trip preserves multi-selection paths")
        let again = ArchiveOperations.compress([original, leaf], in: output, control: TransferControl())
        try check(again.outputs.first?.lastPathComponent == "Archive 2.zip" && FileTools.exists(compressed.outputs[0]), "ZIP creation keeps existing archives")
        let selfZip = ArchiveOperations.compress([source], in: source, control: TransferControl())
        try check(!selfZip.failures.isEmpty && selfZip.outputs.isEmpty, "compression refuses to include its own output directory")
        let cancelled = TransferControl(); cancelled.cancelled = true
        let stopped = ArchiveOperations.extract(compressed.outputs, in: output, control: cancelled)
        try check(stopped.cancelled && stopped.outputs.isEmpty, "cancelled extraction never publishes an incomplete directory")
        let runningControl = TransferControl()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { runningControl.cancelled = true }
        let start = Date()
        do {
            try await Task.detached { try ArchiveOperations.run("/bin/sleep", ["5"], in: scratch, control: runningControl) }.value
            throw FileOperationSafety.failure("Expected running command cancellation")
        } catch is CancellationError {
            try check(Date().timeIntervalSince(start) < 3, "cancelling an active archive command stops its child process promptly")
        }
        let before = Set(try fm.contentsOfDirectory(atPath: output.path))
        let broken = try file(inputs, "Broken.tar.gz", "not an archive")
        let bad = ArchiveOperations.extract([broken], in: output, control: TransferControl())
        try check(!bad.failures.isEmpty && before == Set(try fm.contentsOfDirectory(atPath: output.path)), "failed extraction removes staging and leaves no misleading empty result")
        let damagedStream = try file(inputs, "Broken.gz", "not gzip")
        let damagedResult = ArchiveOperations.extract([damagedStream], in: output, control: TransferControl())
        try check(!damagedResult.failures.isEmpty && before == Set(try fm.contentsOfDirectory(atPath: output.path)), "failed raw decompression removes its partial output")
        let metadataFile = try file(inputs, "Metadata.txt", "metadata")
        try check(FileTools.run("/usr/bin/xattr", ["-w", "com.filetor.fixture", "preserved", metadataFile.path]) == nil, "create metadata fixture")
        let metadataArchive = ArchiveOperations.compress([metadataFile], in: output, control: TransferControl())
        let metadataResult = ArchiveOperations.extract(metadataArchive.outputs, in: output, control: TransferControl())
        let metadataCopy = metadataResult.outputs.first?.appending(path: "Metadata.txt")
        try check(metadataCopy != nil && FileTools.run("/usr/bin/xattr", ["-p", "com.filetor.fixture", metadataCopy!.path]) == nil,
                  "native ZIP round trip preserves macOS extended metadata")
        let empty = inputs.appending(path: "Empty.zip")
        try Data([0x50,0x4b,0x05,0x06] + Array(repeating: 0, count: 18)).write(to: empty)
        let emptyResult = ArchiveOperations.extract([empty], in: output, control: TransferControl())
        try check(emptyResult.failures.isEmpty && (try fm.contentsOfDirectory(atPath: emptyResult.outputs[0].path)).isEmpty, "valid empty ZIP produces an empty result folder")
        let encrypted = inputs.appending(path: "Encrypted.zip")
        try check(FileTools.run("/usr/bin/zip", ["-q", "-P", "fixture-password", encrypted.path, "./-中文 空格.txt"], cwd: inputs) == nil, "create encrypted archive fixture")
        let encryptedResult = ArchiveOperations.extract([encrypted], in: output, control: TransferControl())
        try check(!encryptedResult.failures.isEmpty && encryptedResult.outputs.isEmpty && FileTools.exists(encrypted), "encrypted ZIP fails promptly without deleting the source or publishing partial data")
        let rawXZ = try file(inputs, "Raw.xz", "fixture")
        let notArchive = try folder(inputs, "Directory.zip")
        try check(!FileTools.isArchive(rawXZ) && !FileTools.isArchive(notArchive), "unsupported raw XZ and archive-named directories are not offered built-in extraction")
        let mixed = ArchiveOperations.extract([broken, empty], in: output, control: TransferControl())
        try check(mixed.failures.count == 1 && mixed.outputs.count == 1, "batch extraction reports errors while preserving successful results")

        // Construct tiny TAR fixtures directly so dangerous member names are not normalized by an archiver.
        func entry(_ name: String, type: UInt8 = 48, link: String = "", data: Data = Data()) -> Data {
            var h = [UInt8](repeating: 0, count: 512)
            func put(_ s: String, at: Int, count: Int) { for (i,b) in s.utf8.prefix(count).enumerated() { h[at+i] = b } }
            put(name, at: 0, count: 100); put("0000644", at: 100, count: 7)
            put("0000000", at: 108, count: 7); put("0000000", at: 116, count: 7)
            put(String(format: "%011o", data.count), at: 124, count: 11)
            put("00000000000", at: 136, count: 11)
            for i in 148..<156 { h[i] = 32 }
            h[156] = type; put(link, at: 157, count: 100); put("ustar", at: 257, count: 5)
            put(String(format: "%06o", h.reduce(0) { $0 + Int($1) }), at: 148, count: 6); h[154] = 0
            return Data(h) + data + Data(repeating: 0, count: (512 - data.count % 512) % 512)
        }
        let outside = try file(root, "outside.txt", "untouched")
        let traversal = inputs.appending(path: "Traversal.tar")
        try (entry("../../../outside.txt", data: Data("replace".utf8)) + Data(repeating: 0, count: 1024)).write(to: traversal)
        let traversalResult = ArchiveOperations.extract([traversal], in: output, control: TransferControl())
        try check(!traversalResult.failures.isEmpty && contents(outside) == "untouched" && traversalResult.outputs.isEmpty, "TAR traversal cannot escape staging or publish partial results")
        let zipTraversal = inputs.appending(path: "Traversal.zip")
        try Data(base64Encoded: "UEsDBBQAAAAAAFg5d11FJJ0MBwAAAAcAAAAUAAAALi4vLi4vLi4vb3V0c2lkZS50eHRyZXBsYWNlUEsBAhQDFAAAAAAAWDl3XUUknQwHAAAABwAAABQAAAAAAAAAAAAAAIABAAAAAC4uLy4uLy4uL291dHNpZGUudHh0UEsFBgAAAAABAAEAQgAAADkAAAAAAA==")!.write(to: zipTraversal)
        let zipTraversalResult = ArchiveOperations.extract([zipTraversal], in: output, control: TransferControl())
        try check(!zipTraversalResult.failures.isEmpty && contents(outside) == "untouched" && zipTraversalResult.outputs.isEmpty,
                  "ZIP traversal cannot escape staging or publish partial results")
        let symlink = inputs.appending(path: "Link.tar")
        try (entry("redirect", type: 50, link: root.path) + entry("redirect/outside.txt", data: Data("replace".utf8)) + Data(repeating: 0, count: 1024)).write(to: symlink)
        let symlinkResult = ArchiveOperations.extract([symlink], in: output, control: TransferControl())
        try check(!symlinkResult.failures.isEmpty && contents(outside) == "untouched", "archive symlinks cannot redirect writes outside staging")
        try check(!(try fm.contentsOfDirectory(atPath: output.path)).contains { $0.hasPrefix(".filetor-archive-") }, "successful and failed archive operations release their staging directories")

        try check(ArchiveMenuAction.available(for: [compressed.outputs[0]]) == [.compress, .extract], "ZIP context menus expose only built-in compression and extraction")
        try check(ArchiveMenuAction.available(for: [rawXZ]) == [.compress], "unsupported archives use Open With instead of product-specific actions")
        try check(ArchiveMenuAction.available(for: [original, compressed.outputs[0]]) == [.compress], "mixed files are not partially extracted")
        try check(ArchiveMenuAction.available(for: [notArchive]) == [.compress], "archive-named folders remain compression targets")
        let appA = try folder(root, "A Archive.app"), appB = try folder(root, "B Archive.app")
        let missing = root.appending(path: "Uninstalled.app")
        let lookup: (URL) -> [URL] = { $0 == empty ? [appA, appB, appA, missing] : [appB] }
        let single = OpenWithApplications.candidates(for: [empty], applications: lookup, preferred: { _ in appB })
        try check(single == [appB, appA], "Open With prioritizes the default and removes duplicate or uninstalled applications")
        let shared = OpenWithApplications.candidates(for: [empty, rawXZ], applications: lookup, preferred: { _ in appA })
        try check(shared == [appB], "Open With only offers applications supporting the entire selection")
        let unknown = OpenWithApplications.candidates(for: [original], applications: { _ in [] }, preferred: { _ in nil })
        try check(unknown.isEmpty, "unknown formats leave the manual Other application picker available")
        let emptySelection = OpenWithApplications.candidates(for: [], applications: { _ in fatalError("Unexpected lookup") })
        try check(emptySelection.isEmpty, "empty selection does not query application associations")
        try fm.removeItem(at: appB)
        let afterRemoval = OpenWithApplications.candidates(for: [empty], applications: lookup, preferred: { _ in appB })
        try check(afterRemoval == [appA], "uninstalling an associated application immediately removes its stale menu candidate")

        let app = AppModel()
        let pane = app.active
        pane.navigate(to: output)
        defer { app.stop() }
        app.decompress([empty])
        try check(app.transfers.hasActive && app.transfers.jobs.first?.indeterminate == true, "native extraction is visible in the existing operations UI")
        let job = app.transfers.jobs.first!
        try await until("archive operation completes") { job.isFinished }
        try check(app.alert == nil && job.fraction == 1 && !job.indeterminate, "native extraction reports completion through its owning workspace")
        let downloads = try folder(root, "Downloads")
        let archives = try folder(downloads, "Archives"), other = try folder(downloads, "Other")
        let archiveA = archives.appending(path: "Example.zip"), archiveB = other.appending(path: "Example.zip")
        try fm.copyItem(at: compressed.outputs[0], to: archiveA)
        try fm.copyItem(at: archiveA, to: archiveB)
        pane.navigate(to: downloads)
        try await until("download folder loads") { !pane.loading }
        pane.expand(archives); pane.expand(other)
        try await until("inline archives appear") { [archiveA, archiveB].allSatisfy(Set(pane.sortedItems.map(\.url)).contains) }
        pane.selection = [archiveA]
        ArchiveMenuAction.extract.perform(pane.selection, app: app)
        let inlineJob = app.transfers.jobs.last!
        try await until("inline extraction finishes") { inlineJob.isFinished && !pane.loading }
        let besideA = archives.appending(path: "Example")
        try check(contents(besideA.appending(path: "资料/文件.txt")) == payload
                  && pane.sortedItems.contains { $0.url.path == besideA.path }
                  && !FileTools.exists(downloads.appending(path: "Example")),
                  "extracting an inline archive creates a visible sibling inside its expanded folder")
        let marker = try file(besideA, "keep.txt")
        ArchiveMenuAction.extract.perform([archiveA, archiveB], app: app)
        let batchJob = app.transfers.jobs.last!
        try await until("cross-folder extraction finishes") { batchJob.isFinished }
        try check(contents(archives.appending(path: "Example 2/资料/文件.txt")) == payload
                  && contents(other.appending(path: "Example/资料/文件.txt")) == payload
                  && contents(marker) == "fixture" && FileTools.exists(archiveA) && FileTools.exists(archiveB)
                  && !FileTools.exists(downloads.appending(path: "Example")),
                  "same-name archives use their own parents and preserve existing results and source archives")
        let lock = UUID()
        let acquired = await TransferScheduler.shared.acquire(lock)
        try check(acquired, "reserve operation queue for cancellation test")
        app.compress([original])
        let queued = app.transfers.jobs.last!
        try await Task.sleep(for: .milliseconds(60))
        app.transfers.cancel(queued)
        TransferScheduler.shared.release(lock)
        try await until("queued archive cancels") { !app.transfers.jobs.contains { $0.id == queued.id } }
        try check(queued.control.cancelled, "queued archive jobs can be cancelled without writing output")
    }
}
