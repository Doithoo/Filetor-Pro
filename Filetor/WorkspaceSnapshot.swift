import Foundation

struct WorkspaceSnapshot: Codable {
    let panes: [[PaneSnapshot]]
    let selected: [Int]
    let active: Int
    let dual: Bool
}

struct PaneSnapshot: Codable {
    let path: String
    let view: Int
    let hidden: Bool
    let expanded: [String]
    let sort: String
    let ascending: Bool

    init(_ pane: PaneModel) {
        path = pane.currentURL.path
        view = pane.viewMode
        hidden = pane.showHidden
        expanded = pane.expanded.map(\.path)
        sort = pane.sortOrder.first.map { FileTableView.Coordinator.key(for: $0) } ?? "name"
        ascending = pane.sortOrder.first?.order != .reverse
    }

    func makePane() -> PaneModel {
        let pane = PaneModel(url: URL(fileURLWithPath: path))
        // Legacy column-view tabs and unknown values reopen as expandable lists.
        pane.viewMode = view == 1 ? 1 : 0
        pane.showHidden = hidden
        pane.expanded = Set(expanded.map { URL(fileURLWithPath: $0) })
        let order: SortOrder = ascending ? .forward : .reverse
        switch sort {
        case "size": pane.sortOrder = [KeyPathComparator(\FileItem.size, order: order)]
        case "modified": pane.sortOrder = [KeyPathComparator(\FileItem.modified, order: order)]
        case "created": pane.sortOrder = [KeyPathComparator(\FileItem.created, order: order)]
        case "added": pane.sortOrder = [KeyPathComparator(\FileItem.added, order: order)]
        case "lastOpened": pane.sortOrder = [KeyPathComparator(\FileItem.lastOpened, order: order)]
        case "folder": pane.sortOrder = [KeyPathComparator(\FileItem.folder, comparator: .localizedStandard, order: order)]
        case "kind": pane.sortOrder = [KeyPathComparator(\FileItem.kind, order: order)]
        case "tags": pane.sortOrder = [KeyPathComparator(\FileItem.tagsText, order: order)]
        default: pane.sortOrder = [KeyPathComparator(\FileItem.name, comparator: .localizedStandard, order: order)]
        }
        return pane
    }
}
