import AppKit

nonisolated struct TextPreviewDocument: Sendable {
    let source: String
    let formatted: String
    let kind: BuiltinPreviewKind
    let encoding: String
    let notice: String?
    let truncated: Bool
}

nonisolated enum TextPreviewReader {
    static let byteLimit = 1_048_576
    static let characterLimit = 160_000
    static let lineLimit = 10_000

    static func read(_ url: URL, kind: BuiltinPreviewKind, cancelled: () -> Bool = { false }) throws -> TextPreviewDocument {
        guard !cancelled() else { throw CancellationError() }
        let file = try PreviewFile(url)
        let data = try file.read(at: 0, count: Int(min(file.size, UInt64(byteLimit))))
        var truncated = file.size > UInt64(data.count)
        var encoding = "UTF-8"
        var notice: String?
        var source: String
        if kind == .plist && data.starts(with: Data("bplist".utf8)) {
            guard !truncated else { throw PreviewFile.error("This binary property list is too large to preview (1 MB limit).") }
            let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            let xml = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
            source = String(decoding: xml, as: UTF8.self)
            encoding = "Binary plist → XML"
        } else {
            var bytes = data
            let textEncoding: String.Encoding
            var trim = 3
            if bytes.starts(with: [0xff, 0xfe, 0, 0]) {
                textEncoding = .utf32LittleEndian; encoding = "UTF-32 LE"; bytes.removeFirst(4)
            } else if bytes.starts(with: [0, 0, 0xfe, 0xff]) {
                textEncoding = .utf32BigEndian; encoding = "UTF-32 BE"; bytes.removeFirst(4)
            } else if bytes.starts(with: [0xff, 0xfe]) {
                textEncoding = .utf16LittleEndian; encoding = "UTF-16 LE"; bytes.removeFirst(2); trim = 3
            } else if bytes.starts(with: [0xfe, 0xff]) {
                textEncoding = .utf16BigEndian; encoding = "UTF-16 BE"; bytes.removeFirst(2); trim = 3
            } else {
                textEncoding = .utf8
                if bytes.starts(with: [0xef, 0xbb, 0xbf]) { bytes.removeFirst(3) }
            }
            var decoded = String(data: bytes, encoding: textEncoding)
            // A bounded prefix may end halfway through a multi-byte character.
            if truncated {
                while decoded == nil && trim > 0 && !bytes.isEmpty {
                    bytes.removeLast(); trim -= 1
                    decoded = String(data: bytes, encoding: textEncoding)
                }
            }
            guard let decoded else { throw PreviewFile.error("Unsupported text encoding. Save as UTF-8 or Unicode with a byte-order mark to preview.") }
            guard !decoded.unicodeScalars.contains(where: { $0.value == 0 || ($0.value < 32 && ![9, 10, 12, 13].contains($0.value)) }) else {
                throw PreviewFile.error("This file contains binary data rather than readable text.")
            }
            source = decoded
        }
        if source.count > characterLimit { source = String(source.prefix(characterLimit)); truncated = true }
        let sourceLines = source.split(separator: "\n", maxSplits: lineLimit, omittingEmptySubsequences: false)
        if sourceLines.count > lineLimit { source = sourceLines.prefix(lineLimit).joined(separator: "\n"); truncated = true }
        var formatted = source
        if !truncated && kind == .json {
            do {
                _ = try JSONSerialization.jsonObject(with: Data(source.utf8), options: [.fragmentsAllowed])
                formatted = prettyJSON(source)
            } catch { notice = "Invalid JSON · Showing source" }
        } else if !truncated && kind == .plist && encoding == "UTF-8" {
            do {
                let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                let output = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
                formatted = String(decoding: output, as: UTF8.self)
            } catch { notice = "Invalid property list · Showing source" }
        }
        if formatted.count > characterLimit { formatted = String(formatted.prefix(characterLimit)); truncated = true }
        let formattedLines = formatted.split(separator: "\n", maxSplits: lineLimit, omittingEmptySubsequences: false)
        if formattedLines.count > lineLimit { formatted = formattedLines.prefix(lineLimit).joined(separator: "\n"); truncated = true }
        guard !cancelled() else { throw CancellationError() }
        return .init(source: source, formatted: formatted, kind: kind, encoding: encoding, notice: notice, truncated: truncated)
    }

    /// Re-indent tokens without rewriting numbers, escapes, key order or duplicate keys.
    private static func prettyJSON(_ source: String) -> String {
        var output = "", quoted = false, escaped = false, depth = 0
        func newline() { output += "\n" + String(repeating: "  ", count: min(depth, 40)) }
        for character in source {
            if quoted {
                output.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else {
                switch character {
                case "\"": quoted = true; output.append(character)
                case "{", "[": output.append(character); depth += 1; newline()
                case "}", "]": depth = max(0, depth - 1); newline(); output.append(character)
                case ",": output.append(character); newline()
                case ":": output += ": "
                default: if !character.isWhitespace { output.append(character) }
                }
            }
            if output.utf8.count > characterLimit * 4 { break }
        }
        return output
    }
}

enum TextPreviewStyle {
    static func code(_ text: String, language: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.labelColor])
        if ["txt", "log", "csv", "tsv"].contains(language.lowercased()) { return result }
        let language = language.lowercased()
        let hashComments = ["py", "pyw", "python", "rb", "ruby", "sh", "bash", "zsh", "fish", "yaml", "yml", "toml", "r", "conf", "ini"].contains(language)
        let slashComments = !["json", "geojson"].contains(language)
        let keywords: Set<String> = ["true", "false", "null", "nil", "None", "True", "False", "let", "var", "const", "func", "function", "class", "struct", "enum", "interface", "protocol", "extension", "import", "from", "def", "return", "if", "else", "elif", "for", "while", "switch", "case", "break", "continue", "guard", "try", "catch", "throw", "throws", "async", "await", "public", "private", "static", "final", "override", "new", "export", "default", "type", "in", "as", "is", "self", "this", "super", "fn", "impl", "use", "pub", "mut", "match", "package", "SELECT", "FROM", "WHERE"]
        let units = Array(text.utf16)
        func letter(_ c: UInt16) -> Bool { (65...90).contains(c) || (97...122).contains(c) || c == 95 }
        func digit(_ c: UInt16) -> Bool { (48...57).contains(c) }
        var index = 0, tokens = 0
        // Linear scanning keeps adversarial strings/comments from stalling the UI.
        while index < units.count && tokens < 20_000 {
            let start = index, c = units[index]
            let next = index + 1 < units.count ? units[index + 1] : 0
            var color: NSColor?
            if (hashComments && c == 35) || (slashComments && c == 47 && next == 47) {
                while index < units.count && units[index] != 10 && units[index] != 13 { index += 1 }
                color = .secondaryLabelColor
            } else if slashComments && c == 47 && next == 42 {
                index += 2
                while index < units.count {
                    if units[index] == 42 && index + 1 < units.count && units[index + 1] == 47 { index += 2; break }
                    index += 1
                }
                color = .secondaryLabelColor
            } else if c == 34 || c == 39 || c == 96 {
                index += 1
                while index < units.count {
                    let current = units[index]
                    if current == 92 { index = min(units.count, index + 2); continue }
                    index += 1
                    if current == c || ((current == 10 || current == 13) && c != 96) { break }
                }
                color = .systemRed
            } else if letter(c) {
                index += 1
                while index < units.count && (letter(units[index]) || digit(units[index])) { index += 1 }
                if keywords.contains(String(decoding: units[start..<index], as: UTF16.self)) { color = .systemPurple }
            } else if digit(c) {
                index += 1
                while index < units.count && (digit(units[index]) || units[index] == 46) { index += 1 }
                color = .systemBlue
            } else { index += 1 }
            if let color {
                result.addAttribute(.foregroundColor, value: color, range: NSRange(location: start, length: index - start))
                tokens += 1
            }
        }
        return result
    }

    /// Native text layout for common Markdown blocks; no HTML, scripts or image fetching.
    static func markdown(_ source: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        var fence: String?
        var codeLines: [String] = []
        var language = ""
        func flushCode() {
            guard !codeLines.isEmpty else { return }
            let block = NSMutableAttributedString(attributedString: code(codeLines.joined(separator: "\n") + "\n", language: language))
            block.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor, range: NSRange(location: 0, length: block.length))
            result.append(block)
            codeLines.removeAll()
        }
        for original in source.components(separatedBy: .newlines) {
            let trimmed = original.trimmingCharacters(in: .whitespaces)
            if let marker = fence {
                if trimmed.hasPrefix(marker) { flushCode(); fence = nil }
                else { codeLines.append(original) }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(while: { $0 == trimmed.first! }))
                fence = marker
                language = String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                continue
            }
            var line = original
            var size: CGFloat = 14
            var bold = false
            var quote = false
            let hashes = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
                line = String(trimmed.dropFirst(hashes + 1)); size = CGFloat(28 - hashes * 2); bold = true
            } else if trimmed.hasPrefix("> ") {
                line = String(trimmed.dropFirst(2)); quote = true
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                line = "• " + trimmed.dropFirst(2)
            } else if ["---", "***", "___"].contains(trimmed) {
                line = "────────────────────────"
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = bold ? 10 : 5
            paragraph.lineSpacing = 3
            if quote { paragraph.headIndent = 18; paragraph.firstLineHeadIndent = 18 }
            let rendered = inline(line, size: size, bold: bold, muted: quote)
            let block = NSMutableAttributedString(attributedString: rendered)
            block.append(NSAttributedString(string: "\n"))
            block.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: block.length))
            result.append(block)
        }
        flushCode()
        return result
    }

    private static func inline(_ text: String, size: CGFloat, bold: Bool, muted: Bool) -> NSAttributedString {
        // Images remain their alternative text; links are inert text, not executable URLs.
        guard let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.labelColor])
        }
        let output = NSMutableAttributedString(string: "")
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) : NSFont.systemFont(ofSize: size, weight: bold || intent.contains(.stronglyEmphasized) ? .semibold : .regular)
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: muted ? NSColor.secondaryLabelColor : NSColor.labelColor]
            if intent.contains(.code) { attributes[.backgroundColor] = NSColor.quaternaryLabelColor }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            output.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return output
    }
}

final class TextPreviewView: NSView {
    let textView = NSTextView()
    let scroll = NSScrollView()
    let mode = NSSegmentedControl(labels: ["Reading", "Source"], trackingMode: .selectOne, target: nil, action: nil)
    private let summary = NSTextField(labelWithString: "")
    private var document: TextPreviewDocument?
    private var language = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 18, height: 14)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.backgroundColor = .textBackgroundColor
        textView.setAccessibilityLabel("File preview text")
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        mode.target = self; mode.action = #selector(changeReadingMode)
        mode.selectedSegment = 0
        let find = NSButton(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Find in preview")!, target: self, action: #selector(findText))
        find.bezelStyle = .texturedRounded
        find.toolTip = "Find in preview (⌘F)"
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingMiddle
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = NSStackView(views: [mode, summary, spacer, find])
        bar.spacing = 12
        for view in [bar, scroll] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            bar.topAnchor.constraint(equalTo: topAnchor), bar.heightAnchor.constraint(equalToConstant: 30),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ document: TextPreviewDocument, language: String) {
        self.document = document
        self.language = language
        mode.isHidden = document.kind == .text
        mode.selectedSegment = 0
        summary.stringValue = document.encoding + (document.truncated ? " · Limited preview" : "")
        summary.toolTip = summary.stringValue
        render()
    }

    @objc func changeReadingMode() { render() }
    @objc func findText() {
        window?.makeFirstResponder(textView)
        let item = NSMenuItem()
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performFindPanelAction(item)
    }

    private func render() {
        guard let document else { return }
        let source = mode.selectedSegment == 1
        let text: NSAttributedString
        if document.kind == .markdown && !source { text = TextPreviewStyle.markdown(document.source) }
        else { text = TextPreviewStyle.code(source ? document.source : document.formatted, language: language) }
        textView.textStorage?.setAttributedString(text)
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }
}
