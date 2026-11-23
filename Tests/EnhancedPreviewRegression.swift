import AppKit
import Quartz

extension Regression {
    static func enhancedPreviewTests(_ root: URL) async throws {
        let fixtures = try folder(root, "Enhanced preview")
        let nested = try folder(fixtures, "设计 资料")
        _ = try file(nested, "Notes.txt", "Hello 中文")
        let archive = root.appending(path: "Preview.zip")
        try check(FileTools.run("/usr/bin/ditto", ["-c", "-k", fixtures.path, archive.path]) == nil, "create ZIP fixture with the system archiver")
        let before = try fm.contentsOfDirectory(atPath: root.path).sorted()
        let listing = try ZipPreviewReader.read(archive)
        try check(listing.entries.contains { $0.path.hasSuffix("设计 资料/Notes.txt") && $0.size == 12 }, "ZIP preview reads Unicode paths and uncompressed sizes")
        let tree = ZipPreviewTree.build(listing)
        try check(!tree.root.children.isEmpty && !tree.limited, "ZIP entries form an expandable directory tree")
        try check(try fm.contentsOfDirectory(atPath: root.path).sorted() == before, "ZIP preview creates no extracted files")
        let encrypted = root.appending(path: "Encrypted.zip")
        try check(FileTools.run("/usr/bin/zip", ["-q", "-P", "preview-fixture", encrypted.path, "Notes.txt"], cwd: nested) == nil
                  && (try ZipPreviewReader.read(encrypted)).entries.first?.encrypted == true,
                  "encrypted ZIP entries are listed without prompting for or using a password")
        var original = [UInt8](try Data(contentsOf: archive))
        let end = original.count - 22
        func value(_ bytes: [UInt8], _ at: Int, _ width: Int) -> UInt64 {
            (0..<width).reduce(0) { $0 | (UInt64(bytes[at + $1]) << (8 * $1)) }
        }
        func put(_ bytes: inout [UInt8], _ at: Int, _ number: UInt64, _ width: Int) {
            for index in 0..<width { bytes[at + index] = UInt8(truncatingIfNeeded: number >> (8 * index)) }
        }
        try check(value(original, end, 4) == 0x06054b50, "system ZIP fixture has a standard end record")
        var extended = [UInt8](repeating: 0, count: 76)
        put(&extended, 0, 0x06064b50, 4); put(&extended, 4, 44, 8)
        put(&extended, 12, 45, 2); put(&extended, 14, 45, 2)
        put(&extended, 24, listing.total, 8); put(&extended, 32, listing.total, 8)
        put(&extended, 40, value(original, end + 12, 4), 8); put(&extended, 48, value(original, end + 16, 4), 8)
        put(&extended, 56, 0x07064b50, 4); put(&extended, 64, UInt64(end), 8); put(&extended, 72, 1, 4)
        var eocd = Array(original[end...])
        put(&eocd, 8, 0xffff, 2); put(&eocd, 10, 0xffff, 2)
        put(&eocd, 12, 0xffffffff, 4); put(&eocd, 16, 0xffffffff, 4)
        let zip64 = root.appending(path: "Extended.zip")
        try Data(Array(original[..<end]) + extended + eocd).write(to: zip64)
        try check(try ZipPreviewReader.read(zip64).entries.map(\.path) == listing.entries.map(\.path), "single-volume ZIP64 directory preserves all original entries")
        put(&original, end + 16, UInt64(original.count + 100), 4)
        let beyond = root.appending(path: "Beyond.zip")
        try Data(original).write(to: beyond)
        do { _ = try ZipPreviewReader.read(beyond); throw PreviewFile.error("Expected rejection") }
        catch { try check(!error.localizedDescription.contains("Expected"), "out-of-bounds ZIP directory offsets are rejected") }
        let emptyZip = root.appending(path: "Empty.zip")
        var emptyBytes = [UInt8](repeating: 0, count: 22)
        put(&emptyBytes, 0, 0x06054b50, 4)
        try Data(emptyBytes).write(to: emptyZip)
        try check(try ZipPreviewReader.read(emptyZip).total == 0, "empty ZIP is distinguished from malformed data")
        do {
            _ = try ZipPreviewReader.read(archive, cancelled: { true })
            throw PreviewFile.error("Expected cancellation")
        } catch is CancellationError { try check(true, "ZIP parsing supports cancellation") }
        let malformed = try file(root, "broken.zip", "PK not a ZIP")
        do { _ = try ZipPreviewReader.read(malformed); throw PreviewFile.error("Expected rejection") }
        catch { try check(!error.localizedDescription.contains("Expected"), "malformed ZIP fails with a readable error") }

        // Deliberately hostile central directory names remain display-only nodes.
        let unsafe = ZipPreviewReader.Listing(entries: [
            .init(path: "../../outside.txt", size: 8, packedSize: 8, directory: false, encrypted: false, symbolicLink: false, modified: nil),
            .init(path: "secret.txt", size: 16, packedSize: 24, directory: false, encrypted: true, symbolicLink: false, modified: nil),
            .init(path: "secret.txt", size: 17, packedSize: 25, directory: false, encrypted: true, symbolicLink: false, modified: nil)
        ], total: 3, limited: false)
        let unsafeTree = ZipPreviewTree.build(unsafe)
        try check(unsafeTree.root.children.count == 3 && unsafeTree.root.children.contains { $0.name == "../../outside.txt" },
                  "ZIP traversal names and duplicate entries are preserved without path resolution")
        let deep = ZipPreviewReader.Listing(entries: [.init(path: String(repeating: "dir/", count: 70) + "file", size: 0, packedSize: 0, directory: false, encrypted: false, symbolicLink: false, modified: nil)], total: 1, limited: false)
        try check(ZipPreviewTree.build(deep).limited, "excessively deep archive paths report a preview limit")

        let code = try file(root, "Example.swift", "// Greeting\nlet name = \"你好\"\nprint(name)\n")
        let markdown = try file(root, "Readme.md", "# Filetor Pro\n\n**Native** previews with *readable* text.\n\n- Folder contents\n- ZIP contents\n\n> Local files stay local.\n\n```swift\nlet message = \"你好\"\n```\n[Documentation](https://example.invalid)\n![Remote image](https://example.invalid/image.png)\n")
        let json = try file(root, "Data.json", "{\"large\":123456789012345678901234567890,\"greeting\":\"你好\",\"items\":[1,true,null]}")
        let jsonDocument = try TextPreviewReader.read(json, kind: .json)
        try check(jsonDocument.formatted.contains("\n") && jsonDocument.formatted.contains("123456789012345678901234567890"),
                  "JSON formatting preserves exact numeric tokens and Unicode")
        try check(jsonDocument.source == contents(json) && !jsonDocument.truncated, "JSON source remains available without changing the file")
        let invalid = try file(root, "Invalid.json", "{ nope }")
        let invalidDocument = try TextPreviewReader.read(invalid, kind: .json)
        try check(invalidDocument.notice != nil && invalidDocument.formatted == invalidDocument.source, "invalid JSON falls back to its original source")
        let utf16 = root.appending(path: "Unicode.txt")
        try (Data([0xff, 0xfe]) + "你好 world".data(using: .utf16LittleEndian)!).write(to: utf16)
        try check(try TextPreviewReader.read(utf16, kind: .text).source == "你好 world", "UTF-16 BOM text decodes without losing Chinese characters")
        let binary = root.appending(path: "Binary.txt")
        try Data([0, 1, 2, 3]).write(to: binary)
        do { _ = try TextPreviewReader.read(binary, kind: .text); throw PreviewFile.error("Expected rejection") }
        catch { try check(!error.localizedDescription.contains("Expected"), "binary data with a text extension is rejected") }
        let large = try file(root, "Large.txt", String(repeating: "中文", count: 200_000))
        let largeDocument = try TextPreviewReader.read(large, kind: .text)
        try check(largeDocument.truncated && largeDocument.source.count <= TextPreviewReader.characterLimit,
                  "large Unicode text is bounded and clearly marked as partial")
        let manyLines = try file(root, "ManyLines.md", String(repeating: "text\n", count: 15_000))
        let manyLinesDocument = try TextPreviewReader.read(manyLines, kind: .markdown)
        try check(manyLinesDocument.truncated && manyLinesDocument.source.components(separatedBy: "\n").count <= TextPreviewReader.lineLimit,
                  "large line counts cannot create an unbounded native document layout")
        let plist = root.appending(path: "Settings.plist")
        try PropertyListSerialization.data(fromPropertyList: ["name": "Filetor Pro", "enabled": true], format: .binary, options: 0).write(to: plist)
        try check(try TextPreviewReader.read(plist, kind: .plist).formatted.contains("<true/>"), "binary property lists render as readable XML")
        let link = root.appending(path: "Link.swift")
        try fm.createSymbolicLink(at: link, withDestinationURL: code)
        try check(BuiltinPreviewKind.forURL(link) == .system, "symbolic links retain the system preview route")
        do { _ = try PreviewFile(link); throw PreviewFile.error("Expected rejection") }
        catch { try check(!error.localizedDescription.contains("Expected"), "bounded file reader refuses symbolic links") }
        let fifo = root.appending(path: "Pipe.txt")
        guard mkfifo(fifo.path, 0o600) == 0 else { throw PreviewFile.error("Could not create pipe fixture") }
        do { _ = try PreviewFile(fifo); throw PreviewFile.error("Expected rejection") }
        catch { try check(!error.localizedDescription.contains("Expected"), "named pipes cannot block a preview read") }
        let styled = TextPreviewStyle.code(contents(code), language: "swift")
        let keyword = (styled.string as NSString).range(of: "let")
        try check(styled.attribute(.foregroundColor, at: keyword.location, effectiveRange: nil) as? NSColor == .systemPurple,
                  "native code preview highlights language keywords")
        let formattedMarkdown = TextPreviewStyle.markdown(contents(markdown))
        try check(formattedMarkdown.string.hasPrefix("Filetor Pro\n") && !formattedMarkdown.string.contains("**Native**"),
                  "Markdown renders headings and inline emphasis")
        var hasActiveResources = false
        formattedMarkdown.enumerateAttributes(in: NSRange(location: 0, length: formattedMarkdown.length)) { attrs, _, _ in
            if attrs[.attachment] != nil || attrs[.link] != nil { hasActiveResources = true }
        }
        try check(!hasActiveResources, "Markdown does not load remote images or create executable links")

        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 900, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        let preview = BuiltinPreviewController()
        preview.closePreview = { [weak preview] in preview?.hide() }
        defer { preview.hide(); window.close() }
        func snapshot(_ name: String) throws {
            guard let view = preview.panel.contentView else { return }
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appending(path: name + ".png"))
        }
        preview.show([archive, code, markdown, json], relativeTo: window, showHidden: false)
        try await until("ZIP contents load") { !preview.loading }
        try check(preview.zipRoot != nil && preview.outline.numberOfRows > 0, "native ZIP preview displays its directory without a Quick Look view")
        if let first = preview.zipRoot?.children.first { preview.outline.expandItem(first) }
        try snapshot("builtin-zip-preview")
        preview.nextItem()
        try await until("code loads") { !preview.loading }
        try check(preview.textPreview?.textView.string == contents(code) && preview.textPreview?.textView.isEditable == false,
                  "mixed selection switches from ZIP to selectable read-only code")
        try snapshot("builtin-code-preview")
        let findKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: preview.panel.windowNumber, context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)!
        try check(preview.panel.performKeyEquivalent(with: findKey), "Command-F routes to the preview find bar")
        try await until("native find bar opens") { preview.textPreview?.scroll.isFindBarVisible == true }
        try check(preview.textPreview?.scroll.isFindBarVisible == true, "text preview exposes the native find interface")
        preview.nextItem()
        try await until("Markdown loads") { !preview.loading }
        try check(preview.textPreview?.textView.string.hasPrefix("Filetor Pro") == true, "Markdown opens in reading mode")
        try snapshot("builtin-markdown-preview")
        preview.textPreview?.mode.selectedSegment = 1
        preview.textPreview?.changeReadingMode()
        try check(preview.textPreview?.textView.string == contents(markdown), "Markdown Source displays exact original markup")
        preview.nextItem()
        try await until("JSON loads") { !preview.loading }
        try check(preview.textPreview?.textView.string == jsonDocument.formatted, "JSON opens with native formatted text")
        preview.panel.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(100))
        try snapshot("builtin-json-dark")
        preview.show([large], relativeTo: window, showHidden: false)
        preview.show([code], relativeTo: window, showHidden: false)
        try await until("latest text wins") { !preview.loading }
        try check(preview.textPreview?.textView.string == contents(code), "outdated text results cannot replace the new selection")
        preview.hide()
        try check(preview.textPreview == nil && preview.zipRoot == nil && !preview.loading, "closing built-in preview releases text, archive trees and pending reads")
    }
}
