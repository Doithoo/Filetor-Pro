import AppKit
import Quartz

extension Regression {
    static func folderPreviewTests(_ root: URL) async throws {
        let directory = try folder(root, "Folder preview 中文")
        let nested = try folder(directory, "Design")
        let deep = try folder(nested, "Drafts")
        _ = try file(deep, "Untouched.txt")
        let document = try file(directory, "Notes.txt", "A native folder preview")
        _ = try file(directory, ".hidden")
        let package = try folder(directory, "Fixture.app")
        let bundleContents = try folder(package, "Contents")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.filetor.preview.fixture", "CFBundlePackageType": "APPL"],
                                           format: .xml, options: 0).write(to: bundleContents.appending(path: "Info.plist"))
        let link = directory.appending(path: "Folder link")
        try fm.createSymbolicLink(at: link, withDestinationURL: nested)
        let listing = try FolderPreviewReader.read(directory, showHidden: false, limit: 100)
        try check(listing.items.count == 4 && !listing.truncated && !listing.items.contains { $0.name == ".hidden" },
                  "folder preview enumerates only immediate visible entries")
        try check(listing.items.first?.url.path == nested.path && listing.items.first?.expandable == true,
                  "folder preview sorts expandable folders before files")
        try check(listing.items.first { $0.url.path == link.path }?.expandable == false && listing.items.first { $0.url.path == package.path }?.expandable == false,
                  "folder preview does not traverse symbolic links or application packages")
        try check(listing.items.first { $0.url.path == document.path }?.size == 23,
                  "folder preview reports file metadata without calculating recursive folder sizes")
        let all = try FolderPreviewReader.read(directory, showHidden: true, limit: 100)
        try check(all.items.count == 5, "hidden items can be included without changing browsing preferences")
        let limited = try FolderPreviewReader.read(directory, showHidden: true, limit: 2)
        try check(limited.items.count == 2 && limited.truncated, "large directory previews explicitly report truncation")
        do {
            _ = try FolderPreviewReader.read(directory, showHidden: true, limit: 100, cancelled: { true })
            throw FileOperationSafety.failure("Expected cancellation")
        } catch is CancellationError { try check(true, "cancelled folder previews stop enumerating") }
        do {
            _ = try FolderPreviewReader.read(link, showHidden: true, limit: 100)
            throw FileOperationSafety.failure("Expected symlink rejection")
        } catch { try check(!(error.localizedDescription.contains("Expected")), "redirected folder previews are rejected before enumeration") }

        let controller = FolderPreviewController()
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 900, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { controller.hide(); window.close() }
        controller.closePreview = { [weak controller] in controller?.hide() }
        controller.show([directory], relativeTo: window, showHidden: false)
        try await until("native folder list loads") { controller.model.root?.loaded == true }
        try check(controller.outline.numberOfRows == 4 && controller.panel.isVisible,
                  "native folder preview displays contents without using Quick Look")
        let folderNode = controller.model.root!.children.first { $0.item?.url.path == nested.path }!
        try check(!folderNode.loaded && folderNode.children.isEmpty, "subfolders remain unread until expanded")
        controller.panel.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let disclosure = controller.outline.frameOfOutlineCell(atRow: 0)
        let point = controller.outline.convert(NSPoint(x: disclosure.midX, y: disclosure.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            controller.panel.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: controller.panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
        }
        try await until("folder disclosure loads children") { folderNode.loaded }
        try check(folderNode.children.first?.item?.url.path == deep.path && controller.outline.numberOfRows == 5,
                  "native disclosure expands exactly the requested folder")
        let deepNode = folderNode.children.first!
        try check(!deepNode.loaded, "expansion does not recursively scan grandchildren")
        controller.outline.collapseItem(folderNode)
        try check(controller.outline.numberOfRows == 4, "native disclosure collapses folder contents")

        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(controller.panel.contentView!)
        try check(!views.contains { $0 is QLPreviewView }, "folder rendering contains no extension-backed Quick Look view")
        let hiddenButton = views.compactMap { $0 as? NSButton }.first { $0.toolTip == "Show hidden items" }!
        hiddenButton.performClick(nil)
        try await until("hidden preview button") { controller.model.root?.loaded == true }
        try check(controller.model.showHidden && controller.outline.numberOfRows == 5,
                  "native hidden-items button reloads the folder contents")
        _ = try file(directory, "New file.txt")
        let refresh = views.compactMap { $0 as? NSButton }.first { $0.toolTip == "Refresh folder preview" }!
        refresh.performClick(nil)
        try await until("refresh preview button") { controller.model.root?.loaded == true }
        try check(controller.outline.numberOfRows == 6, "native refresh button discovers new files")
        var opened: URL?
        controller.openFolder = { opened = $0 }
        views.compactMap { $0 as? NSButton }.first { $0.title == "Open Folder" }!.performClick(nil)
        try check(opened == directory, "Open Folder targets the currently previewed folder")

        if let view = controller.panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appending(path: "builtin-folder-preview.png"))
        }
        controller.panel.setContentSize(NSSize(width: 580, height: 340))
        controller.panel.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(150))
        if let view = controller.panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appending(path: "builtin-folder-preview-dark-narrow.png"))
        }
        try check(controller.outline.numberOfRows == 6 && controller.panel.contentView!.bounds.width == 580,
                  "narrow dark preview retains the loaded contents and native scrolling")
        controller.panel.appearance = nil
        controller.show([directory, document], relativeTo: window, showHidden: false)
        controller.nextItem()
        try check(controller.currentURL == document && controller.model.root == nil,
                  "mixed selections use the system file preview and stop folder reads")
        controller.previousItem()
        try await until("mixed selection returns to folder") { controller.model.root?.loaded == true }
        try check(controller.currentURL == directory, "mixed selections return to the built-in folder preview")
        let empty = try folder(root, "Empty preview")
        controller.show([empty], relativeTo: window, showHidden: true)
        try await until("empty preview loads") { controller.model.root?.loaded == true }
        try check(controller.model.root?.children.first?.message == "This folder is empty.", "empty folders show an explicit empty state")

        let missing = directory.appending(path: "Missing")
        controller.model.show(missing, showHidden: false)
        try await until("missing preview error") { controller.model.root?.loaded == true || controller.model.root?.error != nil }
        try check(controller.model.root?.error != nil, "unavailable folders show a recoverable read error")
        let denied = try folder(root, "Denied preview")
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
        controller.model.show(denied, showHidden: true)
        try await until("denied preview error") { controller.model.root?.loaded == true }
        try check(controller.model.root?.error != nil, "permission failures are not presented as empty folders")
        controller.model.show(directory, showHidden: true)
        controller.model.show(empty, showHidden: true)
        try await until("replacement preview loads") { controller.model.root?.loaded == true }
        try check(controller.model.root?.item?.url.path == empty.path && controller.model.root?.children.first?.item == nil,
                  "late directory results cannot overwrite a newer preview")
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: controller.panel.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        controller.panel.sendEvent(escape)
        try await Task.sleep(for: .milliseconds(100))
        try check(controller.model.root == nil && controller.outline.numberOfRows == 0 && !controller.panel.isVisible,
                  "closing folder preview releases its tree and native rows and cancels pending reads")
    }
}
