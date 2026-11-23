import SwiftUI

/// File actions for the icon view.
struct FileItemMenu: View {
    let item: FileItem
    let pane: PaneModel
    let app: AppModel
    private var targets: Set<URL> { pane.selection.contains(item.url) ? pane.selection : [item.url] }

    var body: some View {
        Button("Open") { app.activate(pane); pane.open(targets) }
        OpenWithContextMenu(urls: targets, app: app)
        if item.isDirectory && !item.isPackage {
            Button("Open in New Tab") { app.activate(pane); app.activeGroup.newTab(at: item.url) }
            Button("Open in New Window") { app.openWindow?(item.url) }
        }
        Divider()
        Button("Cut") { app.activate(pane); FileClipboard.shared.write(targets, cut: true) }
        Button("Copy") { app.activate(pane); FileClipboard.shared.write(targets) }
        Button("Paste") {
            app.activate(pane)
            FileClipboard.shared.paste(into: item.url.deletingLastPathComponent(), app: app)
        }
        .disabled(!FileClipboard.shared.canPaste || !FileCreation.canCreate(in: item.url.deletingLastPathComponent()))
        Divider()
        Button("Rename…") { app.activate(pane); app.beginRename(targets) }
        Button("Duplicate") { app.activate(pane); app.duplicate(targets) }
        Button("Copy to…") { app.activate(pane); app.chooseFolderAndTransfer(targets, move: false) }
        Button("Move to…") { app.activate(pane); app.chooseFolderAndTransfer(targets, move: true) }
        Divider()
        Button("Quick Look") { app.activate(pane); app.quickLook(targets) }
        if targets.contains(where: { FileTools.isImage($0) }) {
            Button("Convert Image…") { app.activate(pane); app.convertURLs = targets.filter { FileTools.isImage($0) } }
        }
        Button("Touch — Set Modified Date to Now") { app.activate(pane); app.touch(targets) }
        Button("Get Info") { app.getInfo(targets) }
        ArchiveContextActions(urls: targets, app: app, pane: pane)
        if !targets.allSatisfy({ TrashLocation.contains($0) }) {
            Button("Move to Trash") { app.activate(pane); app.trash(targets) }
        }
        Button("Delete Immediately…", role: .destructive) { app.activate(pane); app.deleteImmediately(targets) }
    }
}

struct FolderBackgroundMenu: View {
    let pane: PaneModel
    let app: AppModel
    let directory: URL
    private var canCreate: Bool {
        !pane.searchActive && pane.tagFilter == nil && FileCreation.canCreate(in: directory)
    }

    var body: some View {
        Button("New Folder") { app.newFolder(in: pane, directory: directory) }.disabled(!canCreate)
        Menu("New File") {
            ForEach(NewFileKind.allCases) { kind in
                Button(kind.title) { app.newFile(kind, in: pane, directory: directory) }
            }
        }.disabled(!canCreate)
        Divider()
        Button("Paste") {
            app.activate(pane)
            FileClipboard.shared.paste(into: directory, app: app)
        }.disabled(!canCreate || !FileClipboard.shared.canPaste)
        Divider()
        Button("Refresh") { app.activate(pane); pane.reloadKeepingSelection() }
    }
}
