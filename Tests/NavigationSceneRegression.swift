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
            print("\nAll \(Regression.checks) real-window navigation checks passed.")
        } catch {
            cleanup()
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
        cleanup()
        NSApp.terminate(nil)
    }
}
