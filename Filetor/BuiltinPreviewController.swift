import AppKit
import Quartz

/// An application-owned panel for built-in previews, with a system fallback for other files.
final class BuiltinPreviewPanel: NSPanel {
    var dismissPreview: (() -> Void)?
    var findInPreview: (() -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "f", findInPreview?() == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           event.keyCode == 53 || (event.charactersIgnoringModifiers == " " && !isEditingFindField) {
            dismissPreview?()
            return
        }
        super.sendEvent(event)
    }

    private var isEditingFindField: Bool {
        (firstResponder as? NSTextView)?.isEditable == true
    }
}

final class BuiltinPreviewController: NSObject, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let model = FolderPreviewModel()
    let panel = BuiltinPreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                                  styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
    let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private let heading = NSTextField(labelWithString: "")
    private let path = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let content = NSView()
    private var filePreview: QLPreviewView?
    private(set) var textPreview: TextPreviewView?
    private(set) var zipRoot: ZipPreviewNode?
    private(set) var previewKind: BuiltinPreviewKind = .system
    private(set) var loading = false
    private var readOperation: Operation?
    private var readGeneration = UUID()
    private(set) var urls: [URL] = []
    private(set) var currentIndex = 0
    var currentURL: URL? { urls.indices.contains(currentIndex) ? urls[currentIndex] : nil }
    var closePreview: (() -> Void)?
    var openFolder: ((URL) -> Void)?
    private var showHidden = false
    private var previous: NSButton!
    private var next: NSButton!
    private var hidden: NSButton!
    private var refresh: NSButton!
    private var open: NSButton!

    override init() {
        super.init()
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.minSize = NSSize(width: 580, height: 340)
        panel.title = "Folder Preview"
        panel.delegate = self
        panel.dismissPreview = { [weak self] in self?.closePreview?() }
        panel.findInPreview = { [weak self] in
            guard let text = self?.textPreview else { return false }
            text.findText()
            return true
        }
        panel.setAccessibilityIdentifier("filetor-builtin-preview")

        previous = button("chevron.left", "Previous selected item", #selector(previousItem))
        next = button("chevron.right", "Next selected item", #selector(nextItem))
        hidden = button("eye.slash", "Show hidden items", #selector(toggleHidden))
        refresh = button("arrow.clockwise", "Refresh folder preview", #selector(reload))
        open = NSButton(title: "Open Folder", target: self, action: #selector(openCurrentFolder))
        open.bezelStyle = .rounded
        open.toolTip = "Open this folder in Filetor Pro"
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        heading.lineBreakMode = .byTruncatingMiddle
        path.font = .systemFont(ofSize: 11)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 32), icon.heightAnchor.constraint(equalToConstant: 32)])
        let titles = NSStackView(views: [heading, path])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 4
        titles.setContentHuggingPriority(.defaultLow, for: .horizontal)
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [icon, titles, previous, count, next, open])
        header.spacing = 10
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [status, spacer, hidden, refresh])
        footer.spacing = 10
        let root = NSView()
        panel.contentView = root
        for view in [header, content, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            header.heightAnchor.constraint(equalToConstant: 42),
            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            footer.heightAnchor.constraint(equalToConstant: 24)
        ])
        outline.headerView = NSTableHeaderView()
        outline.rowHeight = 28
        outline.usesAlternatingRowBackgroundColors = true
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.allowsColumnReordering = false
        outline.indentationPerLevel = 16
        outline.dataSource = self
        outline.delegate = self
        outline.setAccessibilityLabel("Folder contents")
        for (id, title, width) in [("name", "Name", 370.0), ("size", "Size", 80.0), ("kind", "Kind", 120.0), ("modified", "Date Modified", 150.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            column.minWidth = id == "name" ? 200 : 65
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = outline.tableColumns.first
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        model.changed = { [weak self] node in
            guard let self else { return }
            if let node { self.outline.reloadItem(node, reloadChildren: true) }
            else { self.outline.reloadData() }
            self.updateStatus()
        }
    }

    private func button(_ symbol: String, _ help: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: help)!, target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = help
        button.setAccessibilityLabel(help)
        return button
    }

    func show(_ urls: [URL], relativeTo window: NSWindow, showHidden: Bool) {
        let wasVisible = panel.isVisible
        self.urls = urls
        currentIndex = 0
        self.showHidden = showHidden
        renderCurrent()
        if !wasVisible {
            let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
            let x = min(max(window.frame.midX - panel.frame.width / 2, visible.minX), max(visible.minX, visible.maxX - panel.frame.width))
            let y = min(max(window.frame.midY - panel.frame.height / 2, visible.minY), max(visible.minY, visible.maxY - panel.frame.height))
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        cancelRead()
        model.stop()
        filePreview?.previewItem = nil
        filePreview?.close()
        filePreview?.removeFromSuperview()
        filePreview = nil
        textPreview = nil
        zipRoot = nil
        outline.reloadData()
        content.subviews.forEach { $0.removeFromSuperview() }
        urls = []
        currentIndex = 0
        panel.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) { closePreview?() }

    @objc func previousItem() { select(index: currentIndex - 1) }
    @objc func nextItem() { select(index: currentIndex + 1) }

    func select(index: Int) {
        guard urls.indices.contains(index) else { return }
        currentIndex = index
        renderCurrent()
    }

    @objc private func toggleHidden() {
        showHidden.toggle()
        renderCurrent()
    }

    @objc private func reload() { renderCurrent() }
    @objc private func openCurrentFolder() {
        guard let url = currentURL, FileItem(url: url).expandable else { return }
        openFolder?(url)
    }

    private func embed(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor), view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.topAnchor.constraint(equalTo: content.topAnchor), view.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
    }

    private func renderCurrent() {
        guard let url = currentURL else { return }
        cancelRead()
        model.stop()
        zipRoot = nil
        textPreview = nil
        filePreview?.previewItem = nil
        filePreview?.close()
        filePreview = nil
        content.subviews.forEach { $0.removeFromSuperview() }
        let item = FileItem(url: url)
        previewKind = BuiltinPreviewKind.forURL(url)
        let folder = previewKind == .folder
        panel.title = "Preview — \(item.name)"
        heading.stringValue = item.name.isEmpty || item.name == "/" ? FileManager.default.displayName(atPath: "/") : item.name
        path.stringValue = url.path
        path.toolTip = url.path
        icon.image = NSWorkspace.shared.icon(forFile: url.path)
        count.stringValue = "\(currentIndex + 1) / \(urls.count)"
        for view in [previous!, count, next!] { view.isHidden = urls.count < 2 }
        previous.isEnabled = currentIndex > 0
        next.isEnabled = currentIndex + 1 < urls.count
        hidden.isHidden = !folder
        refresh.isHidden = previewKind == .system
        refresh.toolTip = folder ? "Refresh folder preview" : "Refresh preview"
        open.isHidden = !folder
        hidden.image = NSImage(systemSymbolName: showHidden ? "eye" : "eye.slash", accessibilityDescription: nil)
        hidden.toolTip = showHidden ? "Hide hidden items" : "Show hidden items"
        hidden.setAccessibilityLabel(hidden.toolTip)
        if folder {
            outline.setAccessibilityLabel("Folder contents")
            embed(scroll)
            model.show(url, showHidden: showHidden)
            panel.makeFirstResponder(outline)
        } else if previewKind == .zip {
            outline.setAccessibilityLabel("ZIP contents")
            embed(scroll)
            outline.reloadData()
            startZip(url)
        } else if previewKind != .system {
            let text = TextPreviewView()
            textPreview = text
            embed(text)
            startText(url, kind: previewKind)
        } else {
            let preview = QLPreviewView(frame: content.bounds, style: .normal)!
            preview.autostarts = true
            embed(preview)
            filePreview = preview
            preview.previewItem = url as NSURL
            status.stringValue = "System Quick Look"
        }
    }

    private func cancelRead() {
        readGeneration = UUID()
        readOperation?.cancel()
        readOperation = nil
        loading = false
    }

    private func showReadError(_ error: Error) {
        textPreview = nil
        zipRoot = nil
        outline.reloadData()
        status.stringValue = "Could not preview file · Refresh to retry"
        let message = NSTextField(wrappingLabelWithString: error.localizedDescription)
        message.textColor = .secondaryLabelColor
        message.alignment = .center
        message.translatesAutoresizingMaskIntoConstraints = false
        content.subviews.forEach { $0.removeFromSuperview() }
        content.addSubview(message)
        NSLayoutConstraint.activate([
            message.centerXAnchor.constraint(equalTo: content.centerXAnchor), message.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -48)
        ])
    }

    private func startZip(_ url: URL) {
        loading = true
        status.stringValue = "Reading ZIP directory…"
        let generation = readGeneration
        readOperation = PreviewWork.start({ operation in try ZipPreviewReader.read(url, cancelled: { operation.isCancelled }) }) { [weak self] result in
            guard let self, self.readGeneration == generation else { return }
            self.loading = false
            self.readOperation = nil
            switch result {
            case .success(let listing):
                let tree = ZipPreviewTree.build(listing)
                self.zipRoot = tree.root
                self.outline.reloadData()
                let encrypted = listing.entries.contains { $0.encrypted }
                self.status.stringValue = "\(listing.entries.count) / \(listing.total) entries · \(tree.limited ? "Limited preview · " : "")\(encrypted ? "Encrypted entries · " : "")Nothing extracted"
                self.status.toolTip = self.status.stringValue
                if listing.total == 0 { self.status.stringValue = "Empty ZIP archive" }
                self.panel.makeFirstResponder(self.outline)
            case .failure(let error): self.showReadError(error)
            }
        }
    }

    private func startText(_ url: URL, kind: BuiltinPreviewKind) {
        loading = true
        status.stringValue = "Reading file…"
        let generation = readGeneration
        readOperation = PreviewWork.start({ operation in try TextPreviewReader.read(url, kind: kind, cancelled: { operation.isCancelled }) }) { [weak self] result in
            guard let self, self.readGeneration == generation else { return }
            self.loading = false
            self.readOperation = nil
            switch result {
            case .success(let document):
                self.textPreview?.show(document, language: kind == .json ? "json" : url.pathExtension.lowercased())
                var summary = document.notice ?? "\(document.source.components(separatedBy: .newlines).count) lines · Read only"
                if document.truncated { summary += " · Limited preview (1 MB / 160,000 characters / 10,000 lines)" }
                self.status.stringValue = summary
                self.status.toolTip = summary
                if let text = self.textPreview?.textView { self.panel.makeFirstResponder(text) }
            case .failure(let error): self.showReadError(error)
            }
        }
    }

    private func updateStatus() {
        guard let root = model.root else { return }
        if root.loading { status.stringValue = "Loading folder…" }
        else if root.error != nil { status.stringValue = "Unable to read folder · Check permissions and refresh" }
        else {
            let count = root.children.filter { $0.item != nil }.count
            status.stringValue = "\(root.truncated ? "First " : "")\(count) items\(root.truncated ? " · Limited preview" : "") · \(showHidden ? "Hidden items shown" : "Hidden items excluded")"
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if previewKind == .zip { return ((item as? ZipPreviewNode) ?? zipRoot)?.children.count ?? 0 }
        return ((item as? FolderPreviewNode) ?? model.root)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if previewKind == .zip {
            guard let parent = (item as? ZipPreviewNode) ?? zipRoot, parent.children.indices.contains(index) else { return ZipPreviewNode(name: "", path: "") }
            return parent.children[index]
        }
        // AppKit may finish a layout callback while focus changes after closing.
        guard let parent = (item as? FolderPreviewNode) ?? model.root,
              parent.children.indices.contains(index) else { return FolderPreviewNode(message: "") }
        return parent.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if let node = item as? ZipPreviewNode { return !node.children.isEmpty }
        return (item as? FolderPreviewNode)?.item?.expandable == true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        if let node = item as? FolderPreviewNode { model.load(node) }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        if item is ZipPreviewNode { return true }
        return (item as? FolderPreviewNode)?.item != nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let node = item as? ZipPreviewNode, let id = tableColumn?.identifier {
            let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCell(id)
            let folder = !node.children.isEmpty || node.entry?.directory == true
            let text: String
            switch id.rawValue {
            case "name": text = node.name
            case "size": text = node.entry.map { $0.directory ? "—" : ByteCountFormatter.string(fromByteCount: Int64(clamping: $0.size), countStyle: .file) } ?? "—"
            case "kind": text = (node.entry?.encrypted == true ? "Encrypted " : "") + (node.entry?.symbolicLink == true ? "Link" : folder ? "Folder" : "File")
            default: text = node.entry?.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—"
            }
            cell.textField?.stringValue = text
            cell.textField?.textColor = .labelColor
            cell.imageView?.image = NSImage(systemSymbolName: folder ? "folder" : "doc", accessibilityDescription: nil)
            cell.toolTip = node.path + (node.entry.map { "\nSize: \($0.size) bytes · Compressed: \($0.packedSize) bytes" } ?? "")
            cell.setAccessibilityLabel(text)
            return cell
        }
        guard let node = item as? FolderPreviewNode, let id = tableColumn?.identifier else { return nil }
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCell(id)
        let text: String
        if let entry = node.item {
            switch id.rawValue {
            case "name": text = entry.name
            case "size": text = entry.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
            case "kind": text = entry.isSymbolicLink ? "Symbolic Link" : entry.kind
            default: text = entry.modified == .distantPast ? "—" : entry.modified.formatted(date: .abbreviated, time: .shortened)
            }
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: entry.url.path)
        } else {
            text = id.rawValue == "name" ? node.message ?? "" : ""
            cell.imageView?.image = nil
        }
        cell.textField?.stringValue = text
        cell.textField?.textColor = node.item == nil ? .secondaryLabelColor : .labelColor
        cell.toolTip = node.item?.url.path ?? node.message
        cell.setAccessibilityLabel(text)
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: 12)
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        var leading = cell.leadingAnchor
        var inset: CGFloat = 4
        if id.rawValue == "name" {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyUpOrDown
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2), image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16), image.heightAnchor.constraint(equalToConstant: 16)
            ])
            leading = image.trailingAnchor
            inset = 6
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leading, constant: inset), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}
