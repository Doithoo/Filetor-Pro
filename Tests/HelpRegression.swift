import SwiftUI
import AppKit

extension Regression {
    static func helpTests() async throws {
        let state = HelpState()
        state.query = "  EXPAND  "
        try check(state.topics.contains { $0.title == "Expand folders in place" }, "offline help search ignores case and surrounding spaces")
        state.query = "Full Disk Access"
        try check(state.topics.count == 1 && state.topics[0].title == "Trash and folder access", "help search finds access troubleshooting within topic text")
        state.query = "no-such-help-topic-123"
        try check(state.topics.isEmpty && state.shortcutGroups.isEmpty, "help search exposes an empty result instead of unrelated content")
        state.query = ""
        try check(state.shortcutGroups.flatMap(\.entries).count == Shortcuts.groups.flatMap(\.entries).count,
                  "help includes every existing shortcut without the compact panel's row limit")
        state.query = "Quick Look"
        try check(state.shortcutGroups.count == 1 && state.shortcutGroups[0].entries.first?.keys == "Space", "shortcut search reuses the production shortcut reference")
        for link in SupportLink.allCases {
            var opened: URL?
            let success = link.open { opened = $0; return true }
            guard let url = opened, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw FileOperationSafety.failure("Support action did not open a URL")
            }
            try check(success && url.scheme == "https" && url.host == "github.com" && components.path.hasPrefix("/Doithoo/Filetor-Pro"),
                      "\(link.title) opens this product's independent HTTPS repository")
            if link == .issue || link == .suggestion {
                let body = components.queryItems?.first { $0.name == "body" }?.value ?? ""
                try check(components.path.hasSuffix("/issues/new") && body.contains(SupportLink.appInformation)
                          && body.contains("\n") && !body.contains(NSHomeDirectory()) && !body.contains(rootPathForHelpTest),
                          "feedback action creates an editable draft with versions and no private paths")
            }
        }
        try check(!SupportLink.issue.open { _ in false }, "failure to launch a browser is reported to the caller")
        let center = HelpCenter.shared
        defer { center.window?.close() }
        center.show()
        guard let window = center.window else { throw FileOperationSafety.failure("Help window missing") }
        try await Task.sleep(for: .milliseconds(200))
        try check(window.isVisible && window.styleMask.contains(.titled) && window.styleMask.contains(.resizable), "help opens in a native titled resizable window without a workspace")
        center.state.query = "stale search"
        center.show(.shortcuts)
        try check(center.window === window && center.state.page == .shortcuts && center.state.query.isEmpty, "shortcuts reuses the help window and clears an old search")
        window.close()
        center.show(.guide)
        try check(center.window === window && window.isVisible && center.state.page == .guide, "closing and reopening help restores the same usable window")
        try await Task.sleep(for: .milliseconds(150))
        snapshotHelp(window, name: "help-guide")
        center.show(.shortcuts)
        try await Task.sleep(for: .milliseconds(100))
        snapshotHelp(window, name: "help-shortcuts")
        center.state.query = "no-such-help-topic-123"
        try await Task.sleep(for: .milliseconds(100))
        snapshotHelp(window, name: "help-no-results")
    }

    private static let rootPathForHelpTest = "/Applications/Filetor Pro.app"

    static func helpMenuTests(workspace: NSWindow) async throws {
        guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == "Help" })?.submenu else {
            throw FileOperationSafety.failure("Missing native Help menu")
        }
        menu.update()
        let titles = menu.items.map(\.title)
        let expected = ["Filetor Pro Help", "Keyboard Shortcuts"] + SupportLink.allCases.map(\.title)
        try check(expected.allSatisfy(titles.contains), "native Help menu contains guide, shortcuts, feedback, suggestions, release notes and project links")
        try check(menu.items.filter { $0.title == "Filetor Pro Help" }.count == 1
                  && !menu.items.contains { $0.action == NSSelectorFromString("showHelp:") },
                  "custom help replaces the unavailable system Help Book action")
        guard let index = menu.items.firstIndex(where: { $0.title == "Filetor Pro Help" }) else {
            throw FileOperationSafety.failure("Missing guide action")
        }
        menu.performActionForItem(at: index)
        try await until("Help menu opens window") { HelpCenter.shared.window?.isVisible == true }
        try check(HelpCenter.shared.state.page == .guide && NSApp.modalWindow == nil, "real menu action opens the offline guide without an unavailable-help alert")
        if let shortcuts = menu.items.firstIndex(where: { $0.title == "Keyboard Shortcuts" }) {
            menu.performActionForItem(at: shortcuts)
        }
        try await until("Help shortcuts action") { HelpCenter.shared.state.page == .shortcuts }
        try check(HelpCenter.shared.window?.isVisible == true, "Help shortcuts action works while the help window has focus")
        HelpCenter.shared.window?.close()
        workspace.orderOut(nil)
        defer { HelpCenter.shared.window?.close(); workspace.makeKeyAndOrderFront(nil) }
        try await Task.sleep(for: .milliseconds(100))
        menu.update()
        menu.performActionForItem(at: index)
        try await until("Help without workspace") { HelpCenter.shared.window?.isVisible == true }
        try check(!workspace.isVisible && HelpCenter.shared.state.page == .guide, "Help menu remains functional without a visible workspace")
    }

    private static func snapshotHelp(_ window: NSWindow, name: String) {
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let url = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appending(path: name + ".png")
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
