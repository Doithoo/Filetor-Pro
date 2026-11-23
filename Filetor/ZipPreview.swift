import Foundation
import CoreFoundation

nonisolated struct ZipPreviewEntry: Sendable {
    let path: String
    let size: UInt64
    let packedSize: UInt64
    let directory: Bool
    let encrypted: Bool
    let symbolicLink: Bool
    let modified: Date?
}

/// Reads the ZIP central directory only. No extraction, decompression or execution.
nonisolated enum ZipPreviewReader {
    static let entryLimit = 10_000
    static let directoryByteLimit = 16 * 1024 * 1024
    struct Listing: Sendable {
        let entries: [ZipPreviewEntry]
        let total: UInt64
        let limited: Bool
    }

    static func read(_ url: URL, cancelled: () -> Bool = { false }) throws -> Listing {
        let file = try PreviewFile(url)
        guard file.size >= 22 else { throw PreviewFile.error("Not a complete ZIP archive.") }
        let tailLength = Int(min(file.size, 65_557))
        let tail = [UInt8](try file.read(at: file.size - UInt64(tailLength), count: tailLength))
        var end: Int?
        for offset in stride(from: tail.count - 22, through: 0, by: -1) {
            if number(tail, offset, 4) == 0x06054b50,
               offset + 22 + Int(number(tail, offset + 20, 2)) == tail.count { end = offset; break }
        }
        guard let end else { throw PreviewFile.error("ZIP directory not found. The archive may be incomplete or encrypted.") }
        guard number(tail, end + 4, 2) == 0, number(tail, end + 6, 2) == 0 else {
            throw PreviewFile.error("Multi-volume ZIP previews are not supported.")
        }
        var total = number(tail, end + 10, 2)
        var directorySize = number(tail, end + 12, 4)
        var directoryOffset = number(tail, end + 16, 4)
        var directoryEnd = file.size - UInt64(tailLength) + UInt64(end)
        if total == 0xffff || directorySize == 0xffffffff || directoryOffset == 0xffffffff {
            guard directoryEnd >= 20 else { throw PreviewFile.error("Invalid ZIP64 directory.") }
            let locator = [UInt8](try file.read(at: directoryEnd - 20, count: 20))
            guard number(locator, 0, 4) == 0x07064b50, number(locator, 4, 4) == 0, number(locator, 16, 4) == 1 else {
                throw PreviewFile.error("Missing or multi-volume ZIP64 directory.")
            }
            let location = number(locator, 8, 8)
            let record = [UInt8](try file.read(at: location, count: 56))
            guard number(record, 0, 4) == 0x06064b50, number(record, 4, 8) >= 44,
                  number(record, 16, 4) == 0, number(record, 20, 4) == 0,
                  number(record, 24, 8) == number(record, 32, 8), location <= directoryEnd - 20 else {
                throw PreviewFile.error("Invalid or multi-volume ZIP64 archive.")
            }
            total = number(record, 32, 8)
            directorySize = number(record, 40, 8)
            directoryOffset = number(record, 48, 8)
            directoryEnd = location
        } else if number(tail, end + 8, 2) != total {
            throw PreviewFile.error("Multi-volume ZIP previews are not supported.")
        }
        guard directoryOffset <= directoryEnd, directorySize <= directoryEnd - directoryOffset else {
            throw PreviewFile.error("ZIP directory extends beyond the archive.")
        }
        let length = Int(min(directorySize, UInt64(directoryByteLimit)))
        let bytes = [UInt8](try file.read(at: directoryOffset, count: length))
        var entries: [ZipPreviewEntry] = []
        var offset = 0
        while UInt64(entries.count) < total && entries.count < entryLimit {
            guard !cancelled() else { throw CancellationError() }
            if bytes.count - offset < 46 {
                if directorySize > UInt64(bytes.count) { break }
                throw PreviewFile.error("Truncated ZIP directory entry.")
            }
            guard number(bytes, offset, 4) == 0x02014b50 else { throw PreviewFile.error("Invalid ZIP directory entry.") }
            let nameLength = Int(number(bytes, offset + 28, 2))
            let extraLength = Int(number(bytes, offset + 30, 2))
            let commentLength = Int(number(bytes, offset + 32, 2))
            let entryLength = 46 + nameLength + extraLength + commentLength
            if entryLength > bytes.count - offset {
                if directorySize > UInt64(bytes.count) { break }
                throw PreviewFile.error("Truncated ZIP filename or metadata.")
            }
            guard nameLength > 0, number(bytes, offset + 34, 2) == 0 else {
                throw PreviewFile.error("Invalid or multi-volume ZIP entry.")
            }
            let flags = number(bytes, offset + 8, 2)
            let nameData = Data(bytes[(offset + 46)..<(offset + 46 + nameLength)])
            let cp437 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(0x0400))
            let name = String(data: nameData, encoding: .utf8) ?? ((flags & 0x800 == 0) ? String(data: nameData, encoding: cp437) : nil)
            guard let name, !name.contains("\0") else { throw PreviewFile.error("The ZIP contains an invalid filename.") }
            var size = number(bytes, offset + 24, 4)
            var packed = number(bytes, offset + 20, 4)
            if size == 0xffffffff || packed == 0xffffffff {
                var extra = offset + 46 + nameLength
                let endExtra = extra + extraLength
                var found = false
                while extra + 4 <= endExtra {
                    let tag = number(bytes, extra, 2)
                    let sizeExtra = Int(number(bytes, extra + 2, 2))
                    extra += 4
                    guard sizeExtra <= endExtra - extra else { throw PreviewFile.error("Invalid ZIP64 entry metadata.") }
                    if tag == 1 {
                        var cursor = extra
                        if size == 0xffffffff {
                            guard cursor + 8 <= extra + sizeExtra else { throw PreviewFile.error("Missing ZIP64 file size.") }
                            size = number(bytes, cursor, 8); cursor += 8
                        }
                        if packed == 0xffffffff {
                            guard cursor + 8 <= extra + sizeExtra else { throw PreviewFile.error("Missing ZIP64 compressed size.") }
                            packed = number(bytes, cursor, 8)
                        }
                        found = true
                        break
                    }
                    extra += sizeExtra
                }
                guard found else { throw PreviewFile.error("Missing ZIP64 size metadata.") }
            }
            let attributes = number(bytes, offset + 38, 4)
            let unix = number(bytes, offset + 5, 1) == 3
            let link = unix && ((attributes >> 16) & 0xf000) == 0xa000
            let directory = name.hasSuffix("/") || (unix && ((attributes >> 16) & 0xf000) == 0x4000)
            let date = number(bytes, offset + 14, 2), time = number(bytes, offset + 12, 2)
            let components = DateComponents(year: Int((date >> 9) + 1980), month: Int((date >> 5) & 15), day: Int(date & 31),
                                            hour: Int(time >> 11), minute: Int((time >> 5) & 63), second: Int((time & 31) * 2))
            entries.append(.init(path: name, size: size, packedSize: packed, directory: directory, encrypted: flags & 1 != 0,
                                 symbolicLink: link, modified: date == 0 ? nil : Calendar(identifier: .gregorian).date(from: components)))
            offset += entryLength
        }
        return .init(entries: entries, total: total, limited: UInt64(entries.count) < total)
    }

    private static func number(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<count { value |= UInt64(bytes[offset + index]) << (8 * index) }
        return value
    }
}

/// ZIP names are display data, never filesystem destinations.
final class ZipPreviewNode: NSObject {
    let name: String
    let path: String
    var entry: ZipPreviewEntry?
    var children: [ZipPreviewNode] = []
    init(name: String, path: String) { self.name = name; self.path = path }
}

enum ZipPreviewTree {
    static func build(_ listing: ZipPreviewReader.Listing) -> (root: ZipPreviewNode, limited: Bool) {
        let root = ZipPreviewNode(name: "", path: "")
        var nodes: [String: ZipPreviewNode] = ["": root]
        var nodeCount = 1
        var limited = listing.limited
        for entry in listing.entries {
            let parts = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            if parts.count > 64 || nodeCount + parts.count + 1 > 20_000 { limited = true; continue }
            // Keep ambiguous/unsafe paths as literal leaf labels; never normalize away '..'.
            if parts.contains("..") || parts.contains(".") || entry.path.hasPrefix("/") || entry.path.contains("\\") {
                let node = ZipPreviewNode(name: entry.path, path: entry.path)
                node.entry = entry
                root.children.append(node)
                nodeCount += 1
                continue
            }
            var parent = root
            var path = ""
            for part in parts where !part.isEmpty {
                path += String(part) + "/"
                if let existing = nodes[path] { parent = existing }
                else {
                    let child = ZipPreviewNode(name: String(part), path: path)
                    nodes[path] = child
                    nodeCount += 1
                    parent.children.append(child)
                    parent = child
                }
            }
            // Preserve duplicate central-directory entries instead of silently replacing one.
            if parent.entry != nil {
                let duplicate = ZipPreviewNode(name: entry.path + " (duplicate)", path: entry.path)
                duplicate.entry = entry
                root.children.append(duplicate)
                nodeCount += 1
            } else { parent.entry = entry }
        }
        func sort(_ node: ZipPreviewNode) {
            node.children.sort {
                let a = !$0.children.isEmpty || $0.entry?.directory == true
                let b = !$1.children.isEmpty || $1.entry?.directory == true
                if a != b { return a }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            node.children.forEach(sort)
        }
        sort(root)
        return (root, limited)
    }
}
