import SwiftUI

/// Column view: each selected folder opens its contents in a new column to the right.
struct ColumnsView: View {
    let pane: PaneModel
    let app: AppModel
    let scale: CGFloat
    @FocusState private var fileListFocused: Bool
    /// Folders opened to the right of the first column (the first column is the pane's current folder).
    @State private var chain: [URL] = []
    @State private var picked: [Int: URL] = [:]

    private var roots: [URL] { [pane.currentURL] + chain }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(roots.enumerated()), id: \.offset) { i, url in
                        ColumnList(url: url, pane: pane, app: app, scale: scale, showHidden: pane.showHidden, selected: picked[i]) { item in
                            choose(item, in: i)
                        } open: { item in
                            pane.open([item.url])
                        }
                        .frame(width: 240 * scale)
                        .id(i)
                        Divider()
                    }
                }
            }
            .onChange(of: roots.count) { _, n in
                withAnimation { proxy.scrollTo(n - 1, anchor: .trailing) }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($fileListFocused)
        .onKeyPress(.space, phases: .down) { press in
            guard press.modifiers.intersection([.command, .option, .control]).isEmpty,
                  !pane.selection.isEmpty else { return .ignored }
            app.activate(pane)
            app.quickLook(pane.selection, toggle: true)
            return .handled
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: pane.currentURL) { _, _ in chain = []; picked = [:] }
    }

    private func choose(_ item: FileItem, in column: Int) {
        fileListFocused = true
        app.activate(pane)
        chain = Array(chain.prefix(column))
        picked = picked.filter { $0.key < column }
        picked[column] = item.url
        if item.isDirectory && !item.isPackage { chain.append(item.url) }
        pane.selection = [item.url]
    }
}

private struct ColumnList: View {
    let url: URL
    let pane: PaneModel
    let app: AppModel
    let scale: CGFloat
    let showHidden: Bool
    let selected: URL?
    let onSelect: (FileItem) -> Void
    let open: (FileItem) -> Void

    @AppStorage("showExtensions") private var showExtensions = true
    @AppStorage("iconPreviews") private var previews = false
    @AppStorage("foldersFirst") private var foldersFirst = true
    @State private var items: [FileItem] = []
    @State private var error: String?
    @State private var loading = true
    private var refreshKey: String { "\(url.path)|\(showHidden)|\(pane.revision)|\(foldersFirst)" }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    let on = selected == item.url
                    HStack(spacing: 6 * scale) {
                        FileIcon(item: item, side: 17 * scale, previews: previews)
                            .frame(width: 17 * scale, height: 17 * scale)
                        Text(item.displayName(showExtension: showExtensions)).lineLimit(1)
                        Spacer(minLength: 0)
                        if item.isDirectory && !item.isPackage {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10 * scale, weight: .semibold))
                                .foregroundStyle(on ? Color.white : Color.primary.opacity(0.4))
                        }
                    }
                    .font(.system(size: 13 * scale))
                    .foregroundStyle(on ? Color.white : Color.primary)
                    .padding(.horizontal, 8)
                    .frame(height: 24 * scale)
                    .background(on ? Color.filetor : Color.clear)
                    .contentShape(Rectangle())
                    .draggable(item.url)
                    .contextMenu { FileItemMenu(item: item, pane: pane, app: app) }
                    .onTapGesture(count: 2) { open(item) }
                    .onTapGesture { onSelect(item) }
                }
            }
        }
        .overlay {
            if loading && items.isEmpty { ProgressView() }
            else if let error { Text(error).font(.caption).padding() }
        }
        .task(id: refreshKey) {
            loading = true
            let root = url, hidden = showHidden
            let worker = Task.detached(priority: .userInitiated) { try PaneModel.readDirectory(root, hidden: hidden) }
            let result = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            loading = false
            switch result {
            case .success(let files):
                let sorted = files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                items = foldersFirst ? sorted.filter(\.isDirectory) + sorted.filter { !$0.isDirectory } : sorted
                error = nil
            case .failure(let failure): items = []; error = failure.localizedDescription
            }
        }
    }
}
