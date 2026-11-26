import SwiftUI

/// File actions for the icon view.
struct FileItemMenu: View {
    let item: FileItem
    let pane: PaneModel
    let app: AppModel
    private var targets: Set<URL> { pane.selection.contains(item.url) ? pane.selection : [item.url] }

    var body: some View {
        Button(L10n.tr("Open")) { app.activate(pane); pane.open(targets) }
        if targets.count == 1 && item.canShowPackageContents {
            Button(L10n.tr("Show Package Contents")) { app.activate(pane); pane.showPackageContents(item.url) }
        }
        OpenWithContextMenu(urls: targets, app: app)
        if item.isDirectory && !item.isPackage {
            Button(L10n.tr("Open in New Tab")) { app.activate(pane); app.activeGroup.newTab(at: item.url) }
            Button(L10n.tr("Open in New Window")) { app.openWindow?(item.url) }
        }
        Divider()
        Button(L10n.tr("Cut")) { app.activate(pane); FileClipboard.shared.write(targets, cut: true) }
        Button(L10n.tr("Copy")) { app.activate(pane); FileClipboard.shared.write(targets) }
        Button(L10n.tr("Paste")) {
            app.activate(pane)
            FileClipboard.shared.paste(into: item.url.deletingLastPathComponent(), app: app)
        }
        .disabled(!FileClipboard.shared.canPaste || !FileCreation.canCreate(in: item.url.deletingLastPathComponent()))
        Divider()
        Button(L10n.tr("Rename…")) { app.activate(pane); app.beginRename(targets) }
        Button(L10n.tr("Duplicate")) { app.activate(pane); app.duplicate(targets) }
        Button(L10n.tr("Copy to…")) { app.activate(pane); app.chooseFolderAndTransfer(targets, move: false) }
        Button(L10n.tr("Move to…")) { app.activate(pane); app.chooseFolderAndTransfer(targets, move: true) }
        Divider()
        Button(L10n.tr("Quick Look")) { app.activate(pane); app.quickLook(targets) }
        if targets.contains(where: { FileTools.isImage($0) }) {
            Button(L10n.tr("Convert Image…")) { app.activate(pane); app.convertURLs = targets.filter { FileTools.isImage($0) } }
        }
        Button(L10n.tr("Touch — Set Modified Date to Now")) { app.activate(pane); app.touch(targets) }
        Button(L10n.tr("Get Info")) { app.getInfo(targets) }
        ArchiveContextActions(urls: targets, app: app, pane: pane)
        if !targets.allSatisfy({ TrashLocation.contains($0) }) {
            Button(L10n.tr("Move to Trash")) { app.activate(pane); app.trash(targets) }
        }
        Button(L10n.tr("Delete Immediately…"), role: .destructive) { app.activate(pane); app.deleteImmediately(targets) }
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
        Button(L10n.tr("New Folder")) { app.newFolder(in: pane, directory: directory) }.disabled(!canCreate)
        Menu(L10n.tr("New File")) {
            ForEach(NewFileKind.allCases) { kind in
                Button(kind.title) { app.newFile(kind, in: pane, directory: directory) }
            }
        }.disabled(!canCreate)
        Divider()
        Button(L10n.tr("Paste")) {
            app.activate(pane)
            FileClipboard.shared.paste(into: directory, app: app)
        }.disabled(!canCreate || !FileClipboard.shared.canPaste)
        Divider()
        Button(L10n.tr("Refresh")) { app.activate(pane); pane.reloadKeepingSelection() }
        Divider()
        ForEach(PaneSplitAxis.allCases, id: \.self) { axis in
            Button(axis.title) { app.splitPane(pane, axis: axis) }.disabled(!app.canSplitPane)
        }
    }
}
