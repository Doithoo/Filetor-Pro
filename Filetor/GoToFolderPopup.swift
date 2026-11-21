import SwiftUI

/// Mouse-first folder browsing shared by the toolbar and breadcrumb disclosures.
struct GoToFolderPopup: View {
    let app: AppModel
    let pane: PaneModel
    let showsPlaces: Bool
    let focusPath: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var model: FolderNavigationModel
    @State private var action = FolderNavigationAction()
    @State private var source: Source = .folder
    @State private var selected: Int?
    @State private var pathError: String?
    @FocusState private var focused: Bool

    enum Source: String, CaseIterable { case folder = "Folders", favorites = "Favorites", recent = "Recent" }

    init(app: AppModel, pane: PaneModel, initialURL: URL? = nil, showsPlaces: Bool = true, focusPath: Bool = false) {
        self.app = app; self.pane = pane
        self.showsPlaces = showsPlaces; self.focusPath = focusPath
        _model = State(initialValue: FolderNavigationModel(base: initialURL ?? pane.currentURL, showHidden: pane.showHidden))
    }

    private var entries: [PathCandidate] {
        switch source {
        case .folder: return model.entries
        case .favorites: return app.favorites.urls.map { PathCandidate(url: $0, directory: true) }
        case .recent: return RecentFolders.shared.urls.filter { $0 != pane.currentURL }.map { PathCandidate(url: $0, directory: true) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(showsPlaces ? "Go to Folder" : "Subfolders").font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 20, height: 20) }
                    .buttonStyle(.plain).help("Close").accessibilityLabel("Close folder browser")
            }
            if showsPlaces {
                HStack {
                    TextField("Type or paste a path", text: Binding(get: { model.path }, set: {
                        source = .folder; selected = nil; pathError = nil; action.stop(); model.edit($0)
                    }))
                    .textFieldStyle(.roundedBorder).focused($focused)
                    .onSubmit { submit() }
                    .onKeyPress(.downArrow) { select(1); return .handled }
                    .onKeyPress(.upArrow) { select(-1); return .handled }
                    .onKeyPress(.tab) { complete(); return .handled }
                    Button("Go") { submit() }.disabled(action.opening)
                }
                Picker("Locations", selection: $source) {
                    ForEach(Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            if source == .folder {
                HStack(spacing: 8) {
                    Button { action.stop(); model.back(); selected = nil } label: { Image(systemName: "chevron.left") }
                        .disabled(!model.canGoBack).help("Back in folder browser")
                    Button { browse(model.directory.deletingLastPathComponent()) } label: { Image(systemName: "arrow.up") }
                        .disabled(model.directory.path == "/").help("Browse parent folder")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.completing ? "Matching paths" : folderName(model.directory))
                            .fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                        if !model.completing {
                            Text((model.directory.path as NSString).abbreviatingWithTildeInPath)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 0)
                    if !model.completing { Button("Open") { open(model.directory) }.help("Open this folder") }
                }.buttonStyle(.borderless)
            } else {
                HStack {
                    Text(source == .favorites ? "Your sidebar favorites" : "Recently opened folders").foregroundStyle(.secondary)
                    Spacer()
                    if source == .recent, !RecentFolders.shared.urls.isEmpty {
                        Button("Clear") { RecentFolders.shared.clear() }.buttonStyle(.borderless)
                    }
                }.font(.caption)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            row(entry, selected: selected == index).id(entry.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: selected) { _, index in
                    if let index, entries.indices.contains(index) { proxy.scrollTo(entries[index].id) }
                }
            }
            .overlay {
                if source == .folder && model.loading { ProgressView().controlSize(.small) }
                else if entries.isEmpty && (source != .folder || model.error == nil) {
                    Text(emptyMessage).foregroundStyle(.secondary).font(.callout)
                }
            }
            if let error = action.error ?? pathError ?? (source == .folder ? model.error : nil) {
                HStack(alignment: .top) {
                    Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    Spacer(minLength: 0)
                    if source == .folder { Button("Retry") { model.refresh() }.controlSize(.small) }
                }
            }
            if action.opening { ProgressView("Opening…").controlSize(.small) }
            Divider()
            Text("Click a name to open. Click › to browse inside.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: showsPlaces ? 440 : 360, height: showsPlaces ? 480 : 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focused = focusPath; model.refresh() }
        .onChange(of: source) { _, _ in selected = nil; pathError = nil; action.stop() }
        .onChange(of: app.active.id) { _, _ in if app.active !== pane { dismiss() } }
        .onChange(of: pane.currentURL) { _, _ in dismiss() }
        .onChange(of: pane.showHidden) { _, _ in dismiss() }
        .onDisappear { model.stop(); action.stop() }
        .background { Button("") { dismiss() }.keyboardShortcut(.cancelAction).hidden() }
    }

    private var emptyMessage: String {
        switch source {
        case .folder: model.completing ? "No matching paths" : "No subfolders"
        case .favorites: "Add folders to Favorites in the sidebar."
        case .recent: "Folders you open will appear here."
        }
    }

    private func folderName(_ url: URL) -> String { url.path == "/" ? "/" : url.lastPathComponent }

    private func row(_ entry: PathCandidate, selected: Bool) -> some View {
        HStack(spacing: 0) {
            Button { open(entry.url) } label: {
                HStack(spacing: 9) {
                    Image(systemName: entry.directory ? "folder" : "doc")
                        .foregroundStyle(entry.directory ? Color.accentColor : .secondary).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source == .favorites ? app.favorites.place(for: entry.url).name : folderName(entry.url))
                            .lineLimit(1).truncationMode(.middle)
                        if source != .folder {
                            Text((entry.url.path as NSString).abbreviatingWithTildeInPath)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).padding(.vertical, 8).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Open " + entry.url.path)
            .accessibilityIdentifier("folder-open:" + entry.url.path)
            if entry.directory {
                Button { browse(entry.url) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.borderless).help("Browse subfolders of " + folderName(entry.url))
                .accessibilityLabel("Browse subfolders of " + folderName(entry.url))
                .accessibilityIdentifier("folder-browse:" + entry.url.path)
            }
        }
        .background(selected ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private func browse(_ url: URL) {
        source = .folder; selected = nil; pathError = nil; focused = false; action.stop()
        model.browse(url)
    }

    private func select(_ direction: Int) {
        guard !entries.isEmpty else { return }
        selected = min(max((selected ?? (direction > 0 ? -1 : entries.count)) + direction, 0), entries.count - 1)
    }

    private func complete() {
        let index = selected ?? 0
        guard entries.indices.contains(index) else { return }
        let entry = entries[index]
        if entry.directory { browse(entry.url); focused = true }
        else { model.edit(entry.url.path); selected = nil }
    }

    private func submit() {
        if let selected, entries.indices.contains(selected) { open(entries[selected].url); return }
        do { open(try PathCompletion.url(for: model.path, base: model.directory)) }
        catch { pathError = error.localizedDescription }
    }

    private func open(_ url: URL) { action.open(url, app: app, pane: pane) { dismiss() } }
}

/// A native popover anchored to the visible Go To button, overflow menu, or toolbar.
struct FolderNavigationPopover: ViewModifier {
    let app: AppModel
    let enabled: Bool

    func body(content: Content) -> some View {
        content.popover(isPresented: Binding(get: { enabled && app.showGoToFolder }, set: {
            if enabled { app.showGoToFolder = $0 }
        }), arrowEdge: .bottom) {
            GoToFolderPopup(app: app, pane: app.active, focusPath: app.goToFolderFocusPath)
        }
    }
}
