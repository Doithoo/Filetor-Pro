import SwiftUI

@main struct FiletorApp: App {
    @NSApplicationDelegateAdaptor(FiletorApplicationDelegate.self) private var applicationDelegate
    init() {
        DisplayPreferences.migrate()
        ToolbarModel.migrateNavigationButton()
        // Filetor has its own tabs; the system tab bar would draw over the toolbar.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup(ProductInfo.name, id: "workspace", for: UUID.self) { $workspaceID in
            WorkspaceRoot(workspaceID: workspaceID)
        } defaultValue: {
            UUID()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 700)
        .commands { WorkspaceCommands() }
    }
}

private struct WorkspaceCommands: Commands {
    @FocusedValue(\.filetorWorkspace) private var focusedWorkspace
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { UpdateChecker.shared.check() }
                .disabled(!UpdateChecker.shared.canCheck)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Window") { openWindow(id: "workspace", value: UUID()) }
                .keyboardShortcut("n", modifiers: .command)
            if let app = focusedWorkspace {
                Button("New Tab") { app.newTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Reopen Closed Tab") { app.activeGroup.reopen() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(!app.activeGroup.canReopen)
                Button("Next Tab") { app.activeGroup.cycle(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Tab") { app.activeGroup.cycle(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
            }
        }
        if let app = focusedWorkspace {
            CommandGroup(replacing: .appInfo) {
                Button("About \(ProductInfo.name)") {
                    let link = "https://github.com/\(UpdateChecker.repo)"
                    let credits = NSMutableAttributedString(
                        string: "github.com/\(UpdateChecker.repo)",
                        attributes: [
                            .link: URL(string: link)!,
                            .font: NSFont.systemFont(ofSize: 11),
                        ]
                    )
                    let center = NSMutableParagraphStyle()
                    center.alignment = .center
                    credits.addAttribute(.paragraphStyle, value: center, range: NSRange(location: 0, length: credits.length))
                    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
                }
            }
            CommandGroup(replacing: .undoRedo) {
                Button(app.undoTitle ?? "Undo") { app.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(app.historyBusy)
                Button(app.redoTitle ?? "Redo") { app.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(app.historyBusy)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { app.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button(app.showInfo ? "Hide Info Panel" : "Show Info Panel") { app.showInfo.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Button(app.showShortcuts ? "Hide Keyboard Shortcuts" : "Show Keyboard Shortcuts") { app.showShortcuts.toggle() }
                    .keyboardShortcut("k", modifiers: [.command, .option])
                Button("Actions…") { app.showPalette.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Expand Selected Folders") {
                    for url in app.active.selection where FileItem(url: url).expandable { app.active.expand(url) }
                }.disabled(!app.active.treeActive)
                Button("Collapse All Folders") { app.active.collapseAll() }
                    .disabled(app.active.expanded.isEmpty)
                Button("Search") { app.activateSearch() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Go to Folder…") { app.activateGoToFolder() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Customize Toolbar…") { app.showCustomize = true }
                Button("Restore Toolbar Defaults") { app.toolbarModel.restoreDefaults() }
            }
            CommandMenu("Commands") {
                Menu("Open with") {
                    ForEach(app.openApps(for: app.active.selection), id: \.self) { appURL in
                        Button(FileManager.default.displayName(atPath: appURL.path)) {
                            app.open(app.active.selection, with: appURL)
                        }
                    }
                }
                .disabled(app.active.selection.isEmpty)
                Divider()
                Button("New Folder") { app.newFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Project Folder…") { app.projectDialog = true }
                Button("Rename…") { app.beginRename(app.active.selection) }
                    .keyboardShortcut(.f2, modifiers: [])
                Divider()
                Button("Duplicate") { app.duplicate(app.active.selection) }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(app.active.selection.isEmpty)
                Button("Copy to…") { app.chooseFolderAndTransfer(app.active.selection, move: false) }
                    .disabled(app.active.selection.isEmpty)
                Button("Move to…") { app.chooseFolderAndTransfer(app.active.selection, move: true) }
                    .disabled(app.active.selection.isEmpty)
                Button("Move to Trash") { app.trash(app.active.selection) }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(app.active.selection.isEmpty)
                Button("Delete Immediately…") { app.deleteImmediately(app.active.selection) }
                    .keyboardShortcut(.delete, modifiers: [.command, .option])
                    .disabled(app.active.selection.isEmpty)
                Divider()
                Button("Copy to Other Pane") { app.transfer(app.active.selection, move: false) }
                    .keyboardShortcut(.f5, modifiers: [])
                Button("Move to Other Pane") { app.transfer(app.active.selection, move: true) }
                    .keyboardShortcut(.f6, modifiers: [])
                Divider()
                Button("Get Info") { app.getInfo(app.active.selection) }
                    .keyboardShortcut("i", modifiers: .command)
                    .disabled(app.active.selection.isEmpty)
                Button("Compress to ZIP") { app.compress(app.active.selection) }
                    .disabled(app.active.selection.isEmpty)
                Button("Extract Archive") { app.decompress(app.active.selection) }
                    .disabled(app.active.selection.isEmpty || !app.active.selection.allSatisfy(FileTools.isArchive))
                Divider()
                Button("Rotate Left") { app.rotateImages(app.active.selection, degrees: 270) }
                    .disabled(app.active.selection.isEmpty)
                Button("Rotate Right") { app.rotateImages(app.active.selection, degrees: 90) }
                    .disabled(app.active.selection.isEmpty)
                Menu("Convert Image") {
                    Button("PNG") { app.convertImages(app.active.selection, format: "png", ext: "png") }
                    Button("JPEG") { app.convertImages(app.active.selection, format: "jpeg", ext: "jpg") }
                    Button("HEIC") { app.convertImages(app.active.selection, format: "heic", ext: "heic") }
                    Button("TIFF") { app.convertImages(app.active.selection, format: "tiff", ext: "tiff") }
                    if FileTools.canWriteWebP {
                        Button("WebP") { app.convertImages(app.active.selection, format: "webp", ext: "webp") }
                    }
                }
                .disabled(app.active.selection.isEmpty)
                Button("Optimize…") { app.optimizeImages(app.active.selection) }
                    .disabled(app.active.selection.isEmpty)
                Button("Strip Metadata") { app.stripMetadata(app.active.selection) }
                    .disabled(app.active.selection.isEmpty)
                Divider()
                Button("Find Duplicates…") { app.findDuplicates() }
                Button("Large Files…") { app.findLargeFiles() }
                Button("Compare Folders…") { app.compareFolders() }
                Button("Synchronize…") { app.synchronize() }
            }
            CommandGroup(replacing: .saveItem) {
                Button("Close Tab") { app.closeTab() }
                    .keyboardShortcut("w", modifiers: .command)
            }
        }
    }
}

final class FiletorApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UpdateChecker.shared.start()
        FolderAccess.recordDiagnostics()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        FolderAccess.recordDiagnostics()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !AppModel.hasActiveFileOperations else {
            let alert = NSAlert()
            alert.messageText = "File operations are still running"
            alert.informativeText = "Finish or cancel the file operations before quitting or restarting \(ProductInfo.name)."
            alert.addButton(withTitle: "Keep \(ProductInfo.name) Open")
            alert.runModal()
            return .terminateCancel
        }
        AppModel.saveAllWorkspaces()
        return .terminateNow
    }
}
