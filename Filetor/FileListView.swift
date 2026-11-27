import SwiftUI

struct FileListView: View {
    @Bindable var pane: PaneModel
    let app: AppModel

    @AppStorage("textSize") private var textSize = 1
    @AppStorage("compactRows") private var compactRows = false
    @AppStorage("listRowHeight") private var rowHeight = 25.0
    @AppStorage("showExtensions") private var showExtensions = true
    @AppStorage("iconPreviews") private var previews = false
    @AppStorage("foldersFirst") private var foldersFirst = true
    @AppStorage("striped") private var striped = true
    @AppStorage("statusBar") private var statusBar = true
    @State private var visibilityOwner = UUID()
    var isActive = false

    private var scale: CGFloat { UIScale.value(textSize) }

    var body: some View {
        let _ = foldersFirst
        VStack(spacing: 0) {
            BreadcrumbBar(pane: pane, app: app)
                .zIndex(1)
            Divider()
            if let trashRoot = TrashLocation.root(containing: pane.currentURL) {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                    if let job = app.trashDeletionJob {
                        ProgressView(value: job.fraction).frame(width: 50)
                        Text(job.currentName).lineLimit(1)
                        Button(L10n.tr("Stop")) { app.transfers.cancel(job) }
                            .help(L10n.tr("Stop before the next item; completed deletions cannot be undone"))
                    } else {
                        Text(app.preparingTrashDeletion ? L10n.tr("Preparing…") : L10n.tr("Trash on this disk")).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button(L10n.tr("Move Out…")) {
                        app.activate(pane)
                        app.chooseFolderAndTransfer(pane.selection, move: true)
                    }
                    .disabled(pane.selection.isEmpty)
                    .help(L10n.tr("Move selected items out of Trash to a folder you choose"))
                    EmptyTrashButton(root: trashRoot, app: app, revision: pane.revision)
                }
                .font(.caption).foregroundStyle(.secondary).padding(8)
                Divider()
            }
            if app.showFilterBar && pane === app.active && !app.searchFieldVisible {
                FilterBar(pane: pane, app: app, scale: scale)
                Divider()
            }
            if pane.hasSearchFilters, pane.tagFilter == nil {
                HStack(spacing: 8) {
                    Text(([pane.filter, pane.criteria.summary].filter { !$0.isEmpty }).joined(separator: " · "))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(pane.searchSubfolders ? L10n.tr("Subfolders") : L10n.tr("This folder")).foregroundStyle(.secondary)
                    Button(L10n.tr("Edit…")) { app.activate(pane); app.activateSearch() }
                    Button(L10n.tr("Clear")) { pane.clearSearch() }
                }
                .font(.caption).padding(8)
                Divider()
            }
            table
                .overlay {
                    if pane.loading && pane.items.isEmpty {
                        ProgressView(L10n.tr("Loading folder…"))
                    } else if let message = pane.errorMessage, pane.items.isEmpty {
                        ContentUnavailableView {
                            Label(pane.trashAccessDenied ? L10n.tr("Allow access to Trash") : L10n.tr("Cannot open folder"), systemImage: "lock")
                        } description: {
                            Text(pane.trashAccessDenied
                                 ? FolderAccess.trashAccessExplanation
                                 : message)
                        } actions: {
                            if pane.trashAccessDenied {
                                Button(L10n.tr("Open Privacy Settings")) { FolderAccess.openPrivacySettings() }
                                Button(L10n.tr("Reveal Current App")) { FolderAccess.revealCurrentApplication() }
                            }
                            Button(L10n.tr("Retry")) { pane.load() }
                        }
                    }
                }
            if statusBar || pane.searchActive {
                Divider()
                HStack(spacing: 10) {
                    if pane.searching { ProgressView().controlSize(.small) }
                    Text(statusText)
                    if pane.searching {
                        Button(L10n.tr("Stop")) { pane.stopSearch() }.controlSize(.small)
                    }
                }
                .font(.system(size: 13 * scale))
                .foregroundStyle(Color.primary.opacity(0.55))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7 * scale)
                .background(isActive ? Color.filetor.opacity(0.16) : Color.primary.opacity(0.025))
            }
        }
        .onAppear { pane.setVisible(true, owner: visibilityOwner) }
        .onDisappear { pane.setVisible(false, owner: visibilityOwner) }
    }

    @ViewBuilder
    private var table: some View {
        if pane.viewMode == 1 {
            IconGridView(pane: pane, app: app, scale: scale)
        } else {
            listTable
        }
    }

    private var listTable: some View {
        FileTableView(
            pane: pane, app: app,
            items: pane.sortedItems,
            selection: pane.selection,
            sortOrder: pane.sortOrder,
            scale: scale,
            striped: striped,
            compact: compactRows,
            showFolder: pane.searchActive || pane.tagFilter != nil,
            rowSize: UserDefaults.standard.object(forKey: "listRowHeight") == nil ? nil : DisplayPreferences.rowHeight(rowHeight),
            showExtensions: showExtensions, previews: previews
        )
        .safeAreaInset(edge: .bottom) {
            if let error = pane.errorMessage, !pane.items.isEmpty {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button(L10n.tr("Dismiss")) { pane.errorMessage = nil }
                }.padding(8)
            }
        }
    }

    private var freeSpace: String {
        let v = try? pane.currentURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let b = v?.volumeAvailableCapacityForImportantUsage else { return "" }
        return ByteCountFormatter.string(fromByteCount: b, countStyle: .file) + L10n.tr(" available")
    }

    private var statusText: String {
        if let tag = pane.tagFilter {
            let n = pane.sortedItems.count
            let count = n == 1 ? L10n.tr("1 item") : L10n.tr("\(n) items")
            return (pane.tagSearching ? L10n.tr("Searching, ") : "") + (pane.savedSearchID != nil ? L10n.tr("\(count) in \(tag)") : L10n.tr("\(count) tagged \(tag)"))
        }
        if pane.searchActive {
            let n = pane.searchResults.count
            let results = n == 1 ? L10n.tr("1 result") : L10n.tr("\(n) results")
            let folders = pane.foldersScanned.formatted()
            return pane.searching ? L10n.tr("\(results), searching (\(folders) folders)") : L10n.tr("\(results) in \(folders) folders") + (pane.searchTruncated ? L10n.tr(" · Limit reached; narrow your search") : "")
        }
        let total = pane.sortedItems.count
        let selected = pane.selection.count
        let items = total == 1 ? L10n.tr("1 item") : L10n.tr("\(total) items")
        var text = selected > 0 ? L10n.tr("\(selected) of \(items) selected") : items
        let free = freeSpace
        if !free.isEmpty { text += ", " + free }
        return text
    }
}

// MARK: - Filter bar (fallback when the toolbar has no Search field)

struct FilterBar: View {
    @Bindable var pane: PaneModel
    let app: AppModel
    let scale: CGFloat
    @FocusState private var focused: Bool

    private func close() {
        pane.filter = ""
        app.showFilterBar = false
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.tr("Filter selected pane"), text: $pane.filter)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onKeyPress(.escape) { close(); return .handled }
                if !pane.filter.isEmpty {
                    Button { pane.filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12.5 * scale))
            .padding(.horizontal, 8)
            .padding(.vertical, 4 * scale)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            Picker("", selection: $pane.searchSubfolders) {
                Text(L10n.tr("This folder")).tag(false)
                Text(L10n.tr("Subfolders")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button(L10n.tr("Done")) { close() }
                .buttonStyle(.plain)
                .foregroundStyle(Color.filetor)
                .font(.system(size: 12.5 * scale))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .onAppear { focused = true }
        .onChange(of: app.filterBarFocus) { _, _ in focused = true }
    }
}
