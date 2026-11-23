import AppKit
import Quartz

/// Built-in previews for folders, ZIP and text; system Quick Look for other formats.
final class SystemQuickLook: NSResponder, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = SystemQuickLook()
    private(set) var urls: [URL] = []
    private weak var owner: AnyObject?
    private weak var sourceWindow: NSWindow?
    private weak var sourceResponder: NSResponder?
    private(set) var builtinPreview: BuiltinPreviewController?
    private(set) var usesBuiltinPreview = false

    func show(_ urls: [URL], owner: AnyObject, window: NSWindow) {
        guard !urls.isEmpty else { return }
        if sourceWindow !== window {
            detachSourceWindow()
            sourceWindow = window
            nextResponder = window.nextResponder
            window.nextResponder = self
        }
        self.owner = owner
        self.urls = urls
        sourceResponder = window.firstResponder
        window.makeKeyAndOrderFront(nil)
        present()
    }

    private func present() {
        guard let window = sourceWindow else { return }
        // A mixed selection stays in one panel, with system previews for its files.
        let showBuiltin = urls.contains { BuiltinPreviewKind.forURL($0) != .system }
        if showBuiltin {
            if QLPreviewPanel.sharedPreviewPanelExists() {
                let panel = QLPreviewPanel.shared()!
                if panel.currentController as AnyObject? === self { panel.orderOut(nil) }
                usesBuiltinPreview = true
                panel.updateController()
            }
            usesBuiltinPreview = true
            if builtinPreview == nil {
                let controller = BuiltinPreviewController()
                controller.closePreview = { [weak self] in self?.close() }
                controller.openFolder = { [weak self] url in
                    guard let self, let app = self.owner as? AppModel else { return }
                    self.close()
                    app.active.navigate(to: url)
                }
                builtinPreview = controller
            }
            builtinPreview?.show(urls, relativeTo: window, showHidden: (owner as? AppModel)?.active.showHidden ?? false)
            return
        }
        builtinPreview?.hide()
        usesBuiltinPreview = false
        window.makeKeyAndOrderFront(nil)
        let panel = QLPreviewPanel.shared()!
        panel.updateController()
        panel.makeKeyAndOrderFront(nil)
        guard panel.currentController as AnyObject? === self else { close(); return }
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
    }

    func toggle(_ urls: [URL], owner: AnyObject, window: NSWindow) {
        if self.owner === owner, isVisible { close() }
        else { show(urls, owner: owner, window: window) }
    }

    var isVisible: Bool {
        builtinPreview?.panel.isVisible == true || (QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible)
    }

    func update(_ urls: [URL], owner: AnyObject) {
        guard self.owner === owner, isVisible else { return }
        sourceResponder = sourceWindow?.firstResponder
        guard self.urls != urls else { return }
        guard !urls.isEmpty else { close(); return }
        self.urls = urls
        present()
    }

    func close(owner: AnyObject) {
        if self.owner === owner { close() }
    }

    func close() {
        let restoreFocus = builtinPreview?.panel.isKeyWindow == true
        builtinPreview?.hide()
        usesBuiltinPreview = false
        if QLPreviewPanel.sharedPreviewPanelExists(),
           QLPreviewPanel.shared().currentController as AnyObject? === self {
            QLPreviewPanel.shared().orderOut(nil)
        }
        if restoreFocus, let window = sourceWindow {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(sourceResponder)
        }
        detachSourceWindow()
        owner = nil
        urls = []
        if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared().updateController() }
    }

    private func detachSourceWindow() {
        if sourceWindow?.nextResponder === self { sourceWindow?.nextResponder = nextResponder }
        nextResponder = nil
        sourceWindow = nil
        sourceResponder = nil
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { !usesBuiltinPreview && !urls.isEmpty && owner != nil }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
        if event.keyCode == 53 || event.charactersIgnoringModifiers == " " { close(); return true }
        // Let the preview extension handle its own keys first; forward unhandled arrows to the list.
        if [123, 124, 125, 126].contains(event.keyCode), let table = sourceResponder as? NSTableView {
            table.keyDown(with: event)
            return true
        }
        return false
    }
}
