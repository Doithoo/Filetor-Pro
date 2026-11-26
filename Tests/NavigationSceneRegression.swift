import AppKit
import SwiftUI

/// Uses the production WindowGroup and ContentView composition, including the
/// system toolbar host which is absent from isolated NSHostingView tests.
struct NavigationRegressionScene: App {
    let app: AppModel
    let root: URL
    @State private var started = false

    init() {
        UserDefaults.standard.removePersistentDomain(forName: "FiletorRegression")
        UserDefaults.standard.set(true, forKey: "folderAccessAsked")
        UserDefaults.standard.set(false, forKey: "showSidebar")
        NSWindow.allowsAutomaticWindowTabbing = false
        root = FileManager.default.temporaryDirectory.appending(path: "FiletorScene-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root.appending(path: "Projects"), withIntermediateDirectories: true)
        app = AppModel()
        app.sidebarVisibility = .detailOnly
        app.toolbarModel.entries = ["sidebar", "backfwd", "goTo", "flex", "hidden", "terminal", "trash", "move", "info", "copyPath", "customize", "view", "search"].map { ToolbarEntry(kind: $0) }
        app.toolbarModel.showLabels = true
        app.groups.forEach { $0.current.navigate(to: root) }
    }

    var body: some Scene {
        WindowGroup("Filetor Navigation Regression") {
            ContentView(app: app)
                .task {
                    guard !started else { return }
                    started = true
                    await verify()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 700)
        .commands { HelpCommands() }
    }

    private func verify() async {
        func cleanup() {
            app.stop()
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removePersistentDomain(forName: "FiletorRegression")
        }
        do {
            try await Task.sleep(for: .milliseconds(600))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
                throw FileOperationSafety.failure("Missing SwiftUI workspace window")
            }
            window.setContentSize(NSSize(width: 1100, height: 700))
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(200))

            if L10n.language == "zh-Hans" {
                try await Regression.localizationSceneTests(app: app, window: window)
                print("All \(Regression.checks) Chinese real-window checks passed.")
                cleanup()
                NSApp.terminate(nil)
                return
            }

            func click(_ target: NSWindow, x: CGFloat, fromTop: CGFloat) {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: target.frame.height - fromTop), modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber, context: nil,
                                                  eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                    target.sendEvent(event)
                }
            }
            func popover() -> NSWindow? {
                NSApp.windows.first { $0 !== window && $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
            }
            func assertOpen(_ message: String) async throws {
                try await Regression.until(message) { app.showGoToFolder && popover() != nil }
                try await Task.sleep(for: .milliseconds(300))
                try Regression.check(app.showGoToFolder && popover() != nil, message)
            }
            func close() async throws {
                app.showGoToFolder = false
                try await Regression.until("scene popover closes") { popover() == nil }
                try await Task.sleep(for: .milliseconds(100))
            }

            click(window, x: 216, fromTop: 42)
            try await assertOpen("real WindowGroup keeps Go To open after a mouse click")
            try Regression.check(window.toolbar?.isVisible != true, "system toolbar stays hidden while Go To is open")
            try Regression.snapshotNavigationWindow(name: "go-to-scene")
            if let browser = popover() { click(browser, x: 428, fromTop: 40) }
            try await Regression.until("mouse closes scene popover") { !app.showGoToFolder && popover() == nil }
            click(window, x: 216, fromTop: 42)
            try await assertOpen("Go To can reopen after clicking its close button")
            try await close()

            app.sidebarVisibility = .all
            try await Task.sleep(for: .milliseconds(500))
            app.activateGoToFolder()
            try await assertOpen("Go To stays open with the sidebar visible")
            try Regression.check(window.toolbar?.isVisible != true, "showing the sidebar does not restore the system toolbar")
            try await close()

            let goTo = app.toolbarModel.entries.remove(at: 2)
            app.toolbarModel.entries.append(goTo)
            // The sidebar and long toolbar put Go To in the overflow menu.
            try await Task.sleep(for: .milliseconds(200))
            ToolCatalog.def("goTo")!.run(app)
            try await assertOpen("overflow Go To action has a working popover anchor")
            try await close()

            app.toolbarModel.entries.removeAll { $0.kind == "goTo" }
            try await Task.sleep(for: .milliseconds(200))
            app.activateGoToFolder()
            try await assertOpen("menu navigation still opens when Go To is removed from the toolbar")
            try await close()

            app.sidebarVisibility = .detailOnly
            app.showInfo = false
            try await Task.sleep(for: .milliseconds(350))
            let savedToolbar = app.toolbarModel.entries
            click(window, x: window.frame.width - 30, fromTop: 42)
            try await Regression.until("trailing info control opens") { app.showInfo }
            try Regression.check(UserDefaults.standard.bool(forKey: "showInfoPanel"), "right-edge info control opens and persists the panel")
            try Regression.check(app.toolbarModel.entries == savedToolbar && app.toolbarModel.entries.contains { $0.kind == "info" }
                                 && ToolCatalog.def("info")?.title == "Get Info" && ToolCatalog.def("info")?.needsSelection == true,
                                 "Get Info keeps its saved position and requires a selection independently of the panel switch")
            try await Task.sleep(for: .milliseconds(200))
            snapshot(window, name: "info-panel-open")
            click(window, x: window.frame.width - 30, fromTop: 42)
            try await Regression.until("trailing info control closes") { !app.showInfo }
            try Regression.check(!UserDefaults.standard.bool(forKey: "showInfoPanel"), "second click closes the info panel and persists its state")

            window.setContentSize(NSSize(width: 800, height: 700))
            try await Task.sleep(for: .milliseconds(350))
            click(window, x: window.frame.width - 30, fromTop: 42)
            try await Regression.until("narrow info control opens") { app.showInfo }
            try Regression.check(app.showInfo, "info control stays clickable when toolbar items overflow")
            try await Task.sleep(for: .milliseconds(250))
            snapshot(window, name: "info-panel-narrow")
            app.toolbarModel.entries = []
            app.toolbarModel.showLabels = false
            try await Task.sleep(for: .milliseconds(250))
            click(window, x: window.frame.width - 30, fromTop: 48)
            try await Regression.until("empty toolbar info control closes") { !app.showInfo }
            try Regression.check(!app.showInfo, "info control stays available with an empty icon-only toolbar")
            app.toolbarModel.entries = savedToolbar
            app.toolbarModel.showLabels = true
            window.setContentSize(NSSize(width: 1100, height: 700))
            try await Regression.addressBarTests(window: window, app: app, root: root)
            try await Regression.helpMenuTests(workspace: window)
            print("\nAll \(Regression.checks) real-window navigation checks passed.")
        } catch {
            cleanup()
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
        cleanup()
        NSApp.terminate(nil)
    }

    private func snapshot(_ window: NSWindow, name: String) {
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let url = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appending(path: name + ".png")
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
