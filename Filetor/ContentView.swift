import SwiftUI

struct ContentView: View {
    let app: AppModel
    @AppStorage("appearance") private var appearance = 0
    @AppStorage("accent") private var accent = 0
    @AppStorage("showSidebar") private var showSidebar = true
    @AppStorage("textSize") private var textSize = 1

    /// Sets the appearance on the whole app. `preferredColorScheme(nil)` does not reset the window after Light or Dark was chosen.
    private static func applyAppearance(_ value: Int) {
        NSApp.appearance = value == 0 ? NSAppearance(named: .aqua) : (value == 1 ? NSAppearance(named: .darkAqua) : nil)
    }

    var body: some View {
        @Bindable var model = app
        let pane = app.active

        NavigationSplitView(columnVisibility: $model.sidebarVisibility) {
            SidebarView(app: app)
                .navigationSplitViewColumnWidth(min: 160, ideal: 200 * UIScale.value(textSize), max: 420)
                .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 34) }
        } detail: {
            VStack(spacing: 0) {
                CustomToolbar(app: app)
                    .padding(.leading, app.sidebarVisibility == .detailOnly && !app.toolbarModel.contains("sidebar") ? 36 : 0)
                    .padding(.top, app.sidebarVisibility == .detailOnly ? 16 : 0)
                    .overlay(alignment: .leading) {
                        if app.sidebarVisibility == .detailOnly && !app.toolbarModel.contains("sidebar") {
                            Button { app.sidebarVisibility = .all } label: {
                                Image(systemName: "sidebar.left")
                                    .font(.system(size: 16 * UIScale.value(textSize), weight: .light))
                                    .foregroundStyle(Color.primary.opacity(0.6))
                                    .frame(width: 32, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Show Sidebar")
                            .padding(.leading, 10)
                            .padding(.top, 16)
                        }
                    }
                Divider()
                HStack(spacing: 0) {
                    DualPaneView(app: app)
                    if app.showInfo {
                        Divider()
                        InfoPanel(app: app)
                    }
                }
                    .alert(ProductInfo.name, isPresented: Binding(
                        get: { app.alert != nil },
                        set: { if !$0 { app.alert = nil } }
                    )) {
                        Button("OK") {}
                    } message: {
                        Text(app.alert ?? "")
                    }
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .overlay(alignment: .bottom) {
            if app.showShortcuts {
                ShortcutsPanel(app: app).transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(app.showShortcuts ? .easeOut(duration: 0.16) : .easeIn(duration: 0.10), value: app.showShortcuts)
        .overlay(alignment: .bottom) {
            ActionsHint(app: app).padding(.bottom, 52)
        }
        .overlay {
            ZStack {
                if app.showPalette { CommandPalette(app: app).transition(.opacity) }
            }
            .animation(app.showPalette ? .easeOut(duration: 0.16) : .easeIn(duration: 0.10), value: app.showPalette)
        }
        .onAppear {
            Self.applyAppearance(appearance)
            FolderAccess.askOnFirstLaunch(app)
        }
        .onChange(of: appearance) { _, v in Self.applyAppearance(v) }
        .tint(SettingsSheet.accents[min(max(accent, 0), SettingsSheet.accents.count - 1)])
        .navigationTitle(pane.title)
        .toolbar(removing: .sidebarToggle)
        // Preserve the toolbar host while native popovers are open. Replacing
        // NSToolbar during presentation immediately dismisses those popovers.
        .toolbarVisibility(.hidden, for: .automatic)
        .background {
            // Keyboard shortcuts (the toolbar buttons are drawn by CustomToolbar).
            Group {
                Button("Back") { app.active.goBack() }.keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Forward") { app.active.goForward() }.keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Back ") { app.active.goBack() }.keyboardShortcut("[", modifiers: .command)
                Button("Forward ") { app.active.goForward() }.keyboardShortcut("]", modifiers: .command)
                Button("Enclosing") { app.active.goUp() }.keyboardShortcut(.upArrow, modifiers: .command)
                Button("Hidden") { app.active.toggleHidden() }.keyboardShortcut(".", modifiers: [.command, .shift])
                Button("Reload") { app.active.load() }.keyboardShortcut("r", modifiers: [.command, .option])
                if app.showPalette {
                    Button("Close Palette") { app.showPalette = false }.keyboardShortcut(.escape, modifiers: [])
                } else if app.showShortcuts {
                    Button("Close Shortcuts") { app.showShortcuts = false }.keyboardShortcut(.escape, modifiers: [])
                }
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
        .sheet(item: Binding(
            get: { app.transfers.pending },
            set: { _ in }
        )) { request in
            ConflictSheet(request: request, manager: app.transfers)
        }
        .modifier(AppAlerts(app: app))
        .task {
            app.network.onError = { app.alert = $0 }
            app.network.onMounted = { app.active.navigate(to: $0) }
            app.network.start()
        }
        .modifier(ToolPanels(app: app))
        .floatingPanel(isPresented: $model.showConnect) {
            ConnectSheet(app: app)
        }
        .floatingPanel(isPresented: $model.showSearchPopup) {
            SearchPopup(app: app, pane: app.active)
        }
        .floatingPanel(isPresented: $model.showSettings) {
            SettingsSheet(app: app)
        }
        .floatingPanel(isPresented: $model.showFolderAccess) {
            FolderAccessPrompt()
        }
        .floatingPanel(isPresented: Binding(get: { model.report != nil }, set: { if !$0 { model.report = nil } })) {
            ReportPanel(app: app)
        }
        .floatingPanel(isPresented: Binding(get: { model.largeFiles != nil }, set: { if !$0 { model.largeFiles = nil } })) {
            LargeFilesPanel(app: app)
        }
        .floatingPanel(isPresented: Binding(get: { model.sync != nil }, set: { if !$0 { model.sync = nil } })) {
            SyncPanel(app: app)
        }
        .floatingPanel(isPresented: Binding(get: { app.pendingPaneChoice != nil }, set: { if !$0 { app.pendingPaneChoice = nil } })) {
            if let choice = app.pendingPaneChoice { PaneChoiceView(choice: choice, app: app) }
        }
        .floatingPanel(isPresented: $model.showCustomize) {
            CustomizeSheet(app: app)
        }
        .onChange(of: showSidebar) { _, v in app.sidebarVisibility = v ? .all : .detailOnly }
        .onChange(of: pane.selection) { _, _ in app.refreshQuickLook() }
        .onChange(of: pane.id) { _, _ in app.refreshQuickLook() }
        .onChange(of: pane.currentURL) { _, _ in app.refreshQuickLook() }
        .onChange(of: app.sidebarVisibility) { _, v in showSidebar = (v != .detailOnly) }
    }
}

struct PaneContainer: View {
    let app: AppModel
    let group: PaneGroup

    init(app: AppModel, group: PaneGroup) { self.app = app; self.group = group }
    init(app: AppModel, index: Int) { self.init(app: app, group: app.groups[index]) }

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(group: group, app: app)
            FileListView(pane: group.current, app: app, isActive: app.dual && app.activeGroup.id == group.id).id(group.current.id)
        }
        .frame(minWidth: 280)
        .overlay {
            if app.paneDrag != nil { PaneDropSurface(app: app, groupID: group.id) }
        }
        .simultaneousGesture(TapGesture().onEnded { app.activate(group.current) })
    }
}

struct TabStrip: View {
    let group: PaneGroup
    let app: AppModel
    @AppStorage("textSize") private var textSize = 1
    private var closeTitle: String {
        group.tabs.count > 1 ? "Close Tab" : (app.groups.count > 1 ? "Close Pane" : "Close Window")
    }

    var body: some View {
        HStack(spacing: 0) {
            if app.dual {
                PaneDragHandle(app: app, groupID: group.id)
                    .frame(width: 24 * UIScale.value(textSize), height: 28 * UIScale.value(textSize))
                    .padding(.leading, 3)
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(group.tabs.enumerated()), id: \.element.id) { i, tab in
                            let name = tab.title
                            HStack(spacing: 6) {
                                Text(name).lineLimit(1)
                                Button { app.closeTab(in: group, at: i) } label: {
                                    Image(systemName: "xmark").font(.caption2)
                                        .frame(width: 20, height: 20)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(closeTitle)
                                .toolbarHelp(closeTitle)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .frame(maxWidth: 170)
                            .background(i == group.selected ? Color.primary.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                            .onTapGesture { group.selected = i; app.activate(tab) }
                            .draggable(tab.id.uuidString)
                            .dropDestination(for: String.self) { values, _ in
                                guard let value = values.first, let id = UUID(uuidString: value) else { return false }
                                group.reorder(id, before: tab.id)
                                return true
                            }
                            .contextMenu {
                                Button("Open in New Window") { app.openWindow?(tab.currentURL) }
                                Button(closeTitle) { app.closeTab(in: group, at: i) }
                                Button("Reopen Closed Tab") { group.reopen() }.disabled(!group.canReopen)
                            }
                            .id(tab.id)
                        }
                    }
                    .padding(.leading, 8)
                    .padding(.vertical, 4)
                }
                .onChange(of: group.current.id, initial: true) { _, id in
                    proxy.scrollTo(id)
                }
            }
            // Keep the only New Tab button reachable even when the strip overflows.
            Button {
                group.newTab()
                app.activate(group.current)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 30 * UIScale.value(textSize), height: 26 * UIScale.value(textSize))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New Tab")
            .help("New Tab (⌘T)")
        }
        .font(.system(size: 12 * UIScale.value(textSize)))
        .background(.bar)
    }
}

/// Retains the existing view name while rendering an arbitrary split tree.
struct DualPaneView: View {
    let app: AppModel
    var body: some View {
        GeometryReader { geometry in
            let tree = app.focusedPaneID.map { PaneLayout.pane($0) } ?? app.layout
            let minimum = tree.minimumSize
            ScrollView([.horizontal, .vertical]) {
                PaneLayoutView(app: app, node: tree)
                    .frame(width: max(geometry.size.width, minimum.width),
                           height: max(geometry.size.height, minimum.height))
            }
        }
    }
}

struct PaneLayoutView: View {
    let app: AppModel
    let node: PaneLayout

    var body: some View {
        switch node {
        case .pane(let id):
            if let group = app.groups.first(where: { $0.id == id }) { PaneContainer(app: app, group: group) }
        case .split(let id, let axis, let ratio, let first, let second):
            GeometryReader { geometry in
                let vertical = axis == .vertical
                let available = max((vertical ? geometry.size.width : geometry.size.height) - 7, 1)
                let lo = (vertical ? first.minimumSize.width : first.minimumSize.height) / available
                let hi = 1 - (vertical ? second.minimumSize.width : second.minimumSize.height) / available
                let fraction = min(max(ratio, lo), max(lo, hi))
                let stack = vertical ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                stack {
                    AnyView(PaneLayoutView(app: app, node: first))
                        .frame(width: vertical ? available * fraction : nil, height: vertical ? nil : available * fraction)
                    PaneDivider(axis: axis, fraction: fraction, available: available,
                                onResize: { value in
                                    app.layout = app.layout.resizing(id, ratio: min(max(value, lo), max(lo, hi)))
                                }, onFinish: { app.saveSession() }, onBalance: {
                                    app.layout = app.layout.resizing(id, ratio: 0.5)
                                    app.saveSession()
                                })
                        .frame(width: vertical ? 7 : nil, height: vertical ? nil : 7)
                    AnyView(PaneLayoutView(app: app, node: second))
                        .frame(width: vertical ? available * (1 - fraction) : nil, height: vertical ? nil : available * (1 - fraction))
                }
            }
        }
    }
}

/// The alerts live in their own modifier so the main view body stays quick to type-check.
struct AppAlerts: ViewModifier {
    let app: AppModel

    func body(content: Content) -> some View {
        content
            .alert("Delete Immediately?", isPresented: Binding(
            get: { app.pendingDelete != nil },
            set: { if !$0 { app.pendingDelete = nil } }
        )) {
            Button("Delete", role: .destructive) { app.confirmDelete() }
            Button("Cancel", role: .cancel) { app.pendingDelete = nil }.keyboardShortcut(.defaultAction)
        } message: {
            let urls = app.pendingDelete ?? []
            Text(urls.count == 1
                 ? "\"\(urls[0].lastPathComponent)\" will be deleted right away. You can't undo this."
                 : "\(urls.count) items will be deleted right away. You can't undo this.")
        }
        .alert(app.pendingTrashDeletion?.title ?? "Empty Trash?", isPresented: Binding(
            get: { app.pendingTrashDeletion != nil },
            set: { if !$0 { app.pendingTrashDeletion = nil } }
        )) {
            Button(app.pendingTrashDeletion?.emptying == true ? "Empty Trash" : "Delete Permanently", role: .destructive) {
                app.confirmTrashDeletion()
            }
            Button("Cancel", role: .cancel) { app.pendingTrashDeletion = nil }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(app.pendingTrashDeletion?.message ?? "")
        }
    }
}

/// Dialogs for image tools, batch rename and project folders, kept out of ContentView.body for the same reason.
private struct ToolPanels: ViewModifier {
    let app: AppModel

    func body(content: Content) -> some View {
        content
        .floatingPanel(isPresented: Binding(get: { app.convertURLs != nil }, set: { if !$0 { app.convertURLs = nil } })) {
            if let urls = app.convertURLs { ConvertSheet(app: app, urls: urls) }
        }
        .floatingPanel(isPresented: Binding(get: { app.projectDialog }, set: { app.projectDialog = $0 })) {
            ProjectFolderSheet(app: app)
        }
        .floatingPanel(isPresented: Binding(get: { app.savedSearchDialog != nil }, set: { if !$0 { app.savedSearchDialog = nil } })) {
            if let search = app.savedSearchDialog { SavedSearchSheet(app: app, initial: search) }
        }
        .floatingPanel(isPresented: Binding(get: { app.archiveFolder != nil }, set: { if !$0 { app.archiveFolder = nil } })) {
            if let folder = app.archiveFolder { ArchiveSheet(app: app, folder: folder) }
        }
        .floatingPanel(isPresented: Binding(get: { app.optimizeURLs != nil }, set: { if !$0 { app.optimizeURLs = nil } })) {
            if let urls = app.optimizeURLs { OptimizeSheet(app: app, urls: urls) }
        }
        .floatingPanel(isPresented: Binding(get: { app.batchRename != nil }, set: { if !$0 { app.batchRename = nil } })) {
            if let urls = app.batchRename { BatchRenameSheet(app: app, urls: urls) }
        }
    }
}
