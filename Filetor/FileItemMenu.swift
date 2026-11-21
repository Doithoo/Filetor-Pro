import SwiftUI

/// Basic actions shared by the icon and column views.
struct FileItemMenu: View {
    let item: FileItem
    let pane: PaneModel
    let app: AppModel
    private var targets: Set<URL> { pane.selection.contains(item.url) ? pane.selection : [item.url] }

    var body: some View {
        Button("Open") { app.activate(pane); pane.open(targets) }
        if item.isDirectory && !item.isPackage {
            Button("Open in New Tab") { app.activate(pane); app.activeGroup.newTab(at: item.url) }
            Button("Open in New Window") { app.openWindow?(item.url) }
        }
        Divider()
        Button("Rename…") { app.activate(pane); app.beginRename(targets) }
        Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(Array(targets) as [NSURL])
        }
        Button("Duplicate") { app.activate(pane); app.duplicate(targets) }
        Button("Copy to…") { app.activate(pane); app.chooseFolderAndTransfer(targets, move: false) }
        Button("Move to…") { app.activate(pane); app.chooseFolderAndTransfer(targets, move: true) }
        Divider()
        Button("Quick Look") { app.activate(pane); app.quickLook(targets) }
        Button("Get Info") { app.getInfo(targets) }
        Button("Compress") { app.activate(pane); app.compress(targets) }
        Button("Move to Trash") { app.activate(pane); app.trash(targets) }
    }
}
