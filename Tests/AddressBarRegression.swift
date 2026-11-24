import AppKit
import SwiftUI

extension Regression {
    static func addressBarTests(window: NSWindow, app: AppModel, root: URL) async throws {
        let root = root.standardizedFileURL
        let left = app.groups[0].current, right = app.groups[1].current
        left.navigate(to: root); right.navigate(to: root)
        let target = try folder(root, "设计 资料")
        let document = try file(root, "report.txt")
        func click(_ x: CGFloat, _ y: CGFloat) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: window.frame.height - y),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
            }
        }
        func field(in view: NSView? = nil) -> NSTextField? {
            guard let view = view ?? window.contentView else { return nil }
            if let field = view as? NSTextField, field.identifier?.rawValue == "breadcrumb-address" { return field }
            // A lazy compactMap/first can evaluate recursive matches repeatedly.
            // Visit each subtree once even while SwiftUI retains outgoing views.
            for child in view.subviews {
                if let match = field(in: child) { return match }
            }
            return nil
        }
        func editor() throws -> NSTextView {
            guard let view = field()?.currentEditor() as? NSTextView else { throw FileOperationSafety.failure("Address field has no editor") }
            return view
        }
        func key(_ code: UInt16, _ characters: String) {
            window.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!)
        }
        func openEditor() async throws {
            // Let SwiftUI replace the previous editor with the breadcrumb buttons.
            try await Task.sleep(for: .milliseconds(150))
            click(1050, 132)
            try await until("address text field focuses") { field()?.currentEditor() != nil }
        }
        func snapshot(_ name: String) throws {
            guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appending(path: name + ".png"))
        }
        func type(_ text: String) async throws {
            let view = try editor()
            view.insertText(text, replacementRange: NSRange(location: 0, length: (view.string as NSString).length))
            try await Task.sleep(for: .milliseconds(300))
        }
        try await Task.sleep(for: .milliseconds(350))
        app.activeIndex = 0
        try await openEditor()
        try check(app.active === right && field()?.stringValue == root.path + "/",
                  "right path blank area activates its pane and shows an absolute path")
        let selection = try editor().selectedRange()
        try check(selection.location == 0 && selection.length == (root.path + "/" as NSString).length,
                  "opening the address field selects the full path for copying or replacement")

        let composing = try editor()
        composing.setMarkedText("设", selectedRange: NSRange(location: 1, length: 0), replacementRange: composing.selectedRange())
        let address = field()!
        let delegate = address.delegate as! AddressTextField.Coordinator
        let consumed = delegate.control(address, textView: composing, doCommandBy: #selector(NSResponder.insertTab(_:)))
        try check(composing.hasMarkedText() && !consumed && right.currentURL == root,
                  "marked Chinese input keeps Tab under input-method control")
        try await type(root.path + "/设")
        try check(right.currentURL == root && left.currentURL == root, "typing a Chinese path does not navigate either pane")
        try snapshot("address-suggestions-light")
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(120))
        try snapshot("address-suggestions-dark")
        NSApp.appearance = NSAppearance(named: .aqua)
        key(48, "\t")
        try await until("Chinese completion fills address") { field()?.stringValue == target.path + "/" }
        try check(right.currentURL == root, "Tab completes a Chinese folder with spaces without navigating")
        key(36, "\r")
        try await until("address Return navigation") { right.currentURL == target && field() == nil }
        try check(left.currentURL == root, "Return opens the completed directory in only the right pane")

        try await openEditor()
        try await type(root.path + "/Missing")
        key(36, "\r")
        try await Task.sleep(for: .milliseconds(200))
        try check(field() != nil && right.currentURL == target, "an unavailable address keeps the editor open and preserves the location")
        key(53, "\u{1b}")
        try await until("Escape closes address") { field() == nil }
        try check(right.currentURL == target, "Escape cancels path editing without navigation")
        try await openEditor()
        try await type(root.path + "/Missing")
        key(36, "\r")
        try await Task.sleep(for: .milliseconds(150))
        click(750, 450)
        try await until("outside click closes an invalid address") { field() == nil }
        try check(right.currentURL == target, "an invalid address can also be dismissed by clicking outside")

        right.navigate(to: root)
        try await Task.sleep(for: .milliseconds(150))
        try await openEditor()
        try await type(root.path + "/设")
        click(720, 166)
        try await until("mouse address suggestion") { right.currentURL == target && field() == nil }
        try check(left.currentURL == root, "mouse suggestion overlays the table and opens only its own pane")

        try await openEditor()
        try await type(document.path)
        key(36, "\r")
        try await until("address file selection") { right.currentURL == root && right.selection.contains(document) && field() == nil }
        try check(right.selection.contains(document), "a file address opens its parent and selects the file")

        try await openEditor()
        try await type(root.path + "/设")
        key(125, "\u{f701}")
        key(36, "\r")
        try await until("arrow selection opens") { right.currentURL == target && field() == nil }
        try check(right.currentURL == target, "Down and Return open the highlighted path suggestion")

        try await openEditor()
        app.activeIndex = 0
        try await until("pane switch cancels editing") { field() == nil }
        try check(right.currentURL == target, "switching panes cancels unfinished address editing")
        click(1079, 132)
        try await until("right path search opens") { app.showSearchPopup && app.active === right }
        try await Task.sleep(for: .milliseconds(200))
        try check(app.showSearchPopup && app.active === right && left.currentURL == root,
                  "path search stays open for the clicked inactive pane")
        guard let searchEditor = window.firstResponder as? NSTextView else { throw FileOperationSafety.failure("Search has no focused input") }
        searchEditor.insertText("report", replacementRange: searchEditor.selectedRange())
        key(36, "\r")
        try await until("path search applies") { !app.showSearchPopup && right.filter == "report" }
        try check(left.filter.isEmpty, "path search applies its query only to the clicked pane")
        right.clearSearch()
        right.navigate(to: URL(fileURLWithPath: "/"))
        try await Task.sleep(for: .milliseconds(300))
        click(880, 132)
        try await until("blank breadcrumb space edits") { field()?.currentEditor() != nil }
        try check(field()?.stringValue == "/", "clicking blank breadcrumb space edits the full root path")
        click(750, 450)
        try await until("clicking table closes address") { field() == nil }
        try check(right.currentURL.path == "/", "clicking outside dismisses address suggestions without navigating")

        // A fully occupied, narrow path bar must retain a visible-space target
        // without putting a gesture over the folder and dropdown buttons.
        let deep = try folder(target, "Very long folder name with spaces and 中文路径")
        right.navigate(to: deep)
        window.setContentSize(NSSize(width: 800, height: 700))
        try await Task.sleep(for: .milliseconds(350))
        try snapshot("path-bar-without-pencil-narrow")
        app.activeIndex = 0
        click(window.frame.width - 50, 132)
        try await until("long path blank area edits") { field()?.currentEditor() != nil }
        try check(app.active === right && field()?.stringValue == deep.path + "/",
                  "long paths retain a blank editing target in a narrow inactive pane")
        key(53, "\u{1b}")
        try await until("long path edit cancels") { field() == nil }
        try check(right.currentURL == deep && left.currentURL == root,
                  "canceling a long path edit preserves both pane locations")
        window.setContentSize(NSSize(width: 1100, height: 700))
        right.navigate(to: root)
        try await Task.sleep(for: .milliseconds(300))
        try snapshot("path-bar-without-pencil")
    }
}
