import SwiftUI

@main struct FiletorApp: App {
    @NSApplicationDelegateAdaptor(FiletorApplicationDelegate.self) private var applicationDelegate
    init() {
        _ = L10n.launchSelection
        _ = L10n.language
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
        .commands { WorkspaceCommands(); HelpCommands() }
    }
}

private struct WorkspaceCommands: Commands {
    @FocusedValue(\.filetorWorkspace) private var focusedWorkspace
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(L10n.tr("Check for Updates…")) { UpdateChecker.shared.check() }
                .disabled(!UpdateChecker.shared.canCheck)
        }
        CommandGroup(replacing: .newItem) {
            Button(L10n.tr("New Window")) { openWindow(id: "workspace", value: UUID()) }
                .keyboardShortcut("n", modifiers: .command)
            if let app = focusedWorkspace {
                Button(L10n.tr("New Tab")) { app.newTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button(L10n.tr("Reopen Closed Tab")) { app.activeGroup.reopen() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(!app.activeGroup.canReopen)
                Button(L10n.tr("Next Tab")) { app.activeGroup.cycle(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button(L10n.tr("Previous Tab")) { app.activeGroup.cycle(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
            }
        }
        if let app = focusedWorkspace {
            CommandGroup(replacing: .appInfo) {
                Button(L10n.tr("About \(ProductInfo.name)")) {
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
                Button(app.undoTitle ?? L10n.tr("Undo")) { app.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(app.historyBusy)
                Button(app.redoTitle ?? L10n.tr("Redo")) { app.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(app.historyBusy)
            }
            CommandGroup(replacing: .appSettings) {
                Button(L10n.tr("Settings…")) { app.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                if app.focusedPaneID != nil {
                    Button(L10n.tr("Show All Panes")) { app.dual = true }
                }
                Button(app.showInfo ? L10n.tr("Hide Info Panel") : L10n.tr("Show Info Panel")) { app.showInfo.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Button(app.showShortcuts ? L10n.tr("Hide Keyboard Shortcuts") : L10n.tr("Show Keyboard Shortcuts")) { app.showShortcuts.toggle() }
                    .keyboardShortcut("k", modifiers: [.command, .option])
                Button(L10n.tr("Actions…")) { app.showPalette.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                Button(L10n.tr("Expand Selected Folders")) {
                    for url in app.active.selection where FileItem(url: url).expandable { app.active.expand(url) }
                }.disabled(!app.active.treeActive)
                Button(app.active.expandingAll ? L10n.tr("Stop Expanding Folders") : L10n.tr("Expand All Folders")) {
                    app.active.toggleExpandAll()
                }.disabled(!app.active.expandingAll && !app.active.canExpandAll)
                Button(L10n.tr("Collapse All Folders")) { app.active.collapseAll() }
                    .disabled(!app.active.canCollapseAll)
                Button(L10n.tr("Search")) { app.activateSearch() }
                    .keyboardShortcut("f", modifiers: .command)
                Button(L10n.tr("Go to Folder…")) { app.activateGoToFolder() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button(L10n.tr("Customize Toolbar…")) { app.showCustomize = true }
                Button(L10n.tr("Restore Toolbar Defaults")) { app.toolbarModel.restoreDefaults() }
            }
            CommandMenu(L10n.tr("Commands")) {
                Menu(L10n.tr("Open with")) {
                    ForEach(app.openApps(for: app.active.selection), id: \.self) { appURL in
                        Button(FileManager.default.displayName(atPath: appURL.path)) {
                            app.open(app.active.selection, with: appURL)
                        }
                    }
                }
                .disabled(app.active.selection.isEmpty)
                Divider()
                Button(L10n.tr("New Folder")) { app.newFolder() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Menu(L10n.tr("New File")) {
                    ForEach(NewFileKind.allCases) { kind in
                        Button(kind.title) { app.newFile(kind) }
                    }
                }
                .disabled(app.active.searchActive || app.active.tagFilter != nil || !FileCreation.canCreate(in: app.active.currentURL))
                Button(L10n.tr("New Project Folder…")) { app.projectDialog = true }
                Button(L10n.tr("Rename…")) { app.beginRename(app.active.selection) }
                    .keyboardShortcut(.f2, modifiers: [])
                Divider()
                Button(L10n.tr("Duplicate")) { app.duplicate(app.active.selection) }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(app.active.selection.isEmpty)
                Button(L10n.tr("Copy to…")) { app.chooseFolderAndTransfer(app.active.selection, move: false) }
                    .disabled(app.active.selection.isEmpty)
                Button(L10n.tr("Move to…")) { app.chooseFolderAndTransfer(app.active.selection, move: true) }
                    .disabled(app.active.selection.isEmpty)
                Button(L10n.tr("Move to Trash")) { app.trash(app.active.selection) }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(app.active.selection.isEmpty)
                Button(L10n.tr("Delete Immediately…")) { app.deleteImmediately(app.active.selection) }
                    .keyboardShortcut(.delete, modifiers: [.command, .option])
                    .disabled(app.active.selection.isEmpty)
                Divider()
                Button(L10n.tr("Copy to Other Pane")) { app.transfer(app.active.selection, move: false) }
                    .keyboardShortcut(.f5, modifiers: [])
                Button(L10n.tr("Move to Other Pane")) { app.transfer(app.active.selection, move: true) }
                    .keyboardShortcut(.f6, modifiers: [])
                Divider()
                Button(L10n.tr("Get Info")) { app.getInfo(app.active.selection) }
                    .keyboardShortcut("i", modifiers: .command)
                    .disabled(app.active.selection.isEmpty)
                Button(L10n.tr("Compress to ZIP")) { app.compress(app.active.selection) }
                    .disabled(app.active.selection.isEmpty)
                Button(L10n.tr("Extract Archive")) { app.decompress(app.active.selection) }
                    .disabled(app.active.selection.isEmpty || !app.active.selection.allSatisfy(FileTools.isArchive))
                Divider()
                Button(L10n.tr("Rotate Left")) { app.rotateImages(app.active.selection, degrees: 270) }
                    .disabled(app.active.selection.isEmpty)
                Button(L10n.tr("Rotate Right")) { app.rotateImages(app.active.selection, degrees: 90) }
                    .disabled(app.active.selection.isEmpty)
                Menu(L10n.tr("Convert Image")) {
                    Button(L10n.tr("PNG")) { app.convertImages(app.active.selection, format: "png", ext: "png") }
                    Button(L10n.tr("JPEG")) { app.convertImages(app.active.selection, format: "jpeg", ext: "jpg") }
                    Button(L10n.tr("HEIC")) { app.convertImages(app.active.selection, format: "heic", ext: "heic") }
                    Button(L10n.tr("TIFF")) { app.convertImages(app.active.selection, format: "tiff", ext: "tiff") }
                    if FileTools.canWriteWebP {
                        Button(L10n.tr("WebP")) { app.convertImages(app.active.selection, format: "webp", ext: "webp") }
                    }
                }
                .disabled(app.active.selection.isEmpty)
                Button(L10n.tr("Optimize…")) { app.optimizeImages(app.active.selection) }
                    .disabled(app.active.selection.isEmpty)
                Button(L10n.tr("Strip Metadata")) { app.stripMetadata(app.active.selection) }
                    .disabled(app.active.selection.isEmpty)
                Divider()
                Button(L10n.tr("Find Duplicates…")) { app.findDuplicates() }
                Button(L10n.tr("Large Files…")) { app.findLargeFiles() }
                Button(L10n.tr("Compare Folders…")) { app.compareFolders() }
                Button(L10n.tr("Synchronize…")) { app.synchronize() }
            }
            CommandGroup(replacing: .saveItem) {
                Button(L10n.tr("Close Tab")) { app.closeTab() }
                    .keyboardShortcut("w", modifiers: .command)
            }
        }
    }
}

final class FiletorApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        InteractionFeedback.shared.startMonitoring()
        UpdateChecker.shared.start()
        FolderAccess.recordDiagnostics()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        FolderAccess.recordDiagnostics()
    }

    func applicationWillTerminate(_ notification: Notification) {
        InteractionFeedback.shared.stopMonitoring()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !AppModel.hasActiveFileOperations else {
            let alert = NSAlert()
            alert.messageText = L10n.tr("File operations are still running")
            alert.informativeText = L10n.tr("Finish or cancel the file operations before quitting or restarting \(ProductInfo.name).")
            alert.addButton(withTitle: L10n.tr("Keep \(ProductInfo.name) Open"))
            alert.runModal()
            return .terminateCancel
        }
        AppModel.saveAllWorkspaces()
        return .terminateNow
    }
}
