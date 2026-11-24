import SwiftUI
import Observation

/// One thing ⌘Z can take back and ⇧⌘Z can do again. The closures return an error message, or nil when it worked.
struct SyncBatchState {
    var remaining: Int
    var parts: [(undo: () async -> String?, redo: () async -> String?, count: Int)] = []
}

struct UndoStep {
    let title: String
    let undo: () async -> String?
    let redo: () async -> String?
}

@Observable
final class PaneGroup: Identifiable {
    let id: UUID
    init(id: UUID = UUID()) { self.id = id }
    var tabs: [PaneModel] = [PaneModel()]
    var selected = 0
    private var closed: [PaneSnapshot] = []
    var canReopen: Bool { !closed.isEmpty }

    func cycle(_ offset: Int) { selected = (selected + offset + tabs.count) % tabs.count }

    func reorder(_ id: UUID, before target: UUID) {
        guard let from = tabs.firstIndex(where: { $0.id == id }), let to = tabs.firstIndex(where: { $0.id == target }), from != to else { return }
        let active = current.id
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
        selected = tabs.firstIndex(where: { $0.id == active }) ?? 0
    }

    func reopen() {
        guard let state = closed.popLast() else { return }
        tabs.append(state.makePane())
        selected = tabs.count - 1
    }

    var current: PaneModel { tabs[min(selected, tabs.count - 1)] }

    func newTab() {
        tabs.append(PaneModel(url: current.currentURL))
        selected = tabs.count - 1
    }

    func newTab(at url: URL) {
        tabs.append(PaneModel(url: url))
        selected = tabs.count - 1
    }

    func close(at index: Int) {
        guard tabs.count > 1, tabs.indices.contains(index) else { return }
        closed.append(PaneSnapshot(tabs[index]))
        if closed.count > 20 { closed.removeFirst() }
        tabs[index].stop()
        tabs.remove(at: index)
        if index < selected { selected -= 1 }
        selected = min(selected, tabs.count - 1)
    }
}

@Observable
final class AppModel {
    static var windowLocations: [UUID: URL] = [:]
    private static var hasRestoredInitialWindow = false
    let workspaceID: UUID
    var openWindow: ((URL?) -> Void)?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func activate(_ pane: PaneModel) {
        if let index = groups.firstIndex(where: { $0.current === pane }) {
            guard focusedPaneID == nil || focusedPaneID == groups[index].id else { return }
            activeIndex = index
        }
    }
    var groups = [PaneGroup(), PaneGroup()]
    var activeIndex = 0
    var layout: PaneLayout = .pane(UUID())
    var focusedPaneID: UUID?
    var pendingPaneChoice: PaneChoice?
    var paneDrag: PaneDragPayload?
    var visibleGroups: [PaneGroup] {
        if let focusedPaneID, let group = groups.first(where: { $0.id == focusedPaneID }) { return [group] }
        return layout.leaves.compactMap { id in groups.first { $0.id == id } }
    }
    var dual: Bool {
        get { visibleGroups.count > 1 }
        set {
            if newValue {
                focusedPaneID = nil
                if groups.count == 1 { splitPane(active, axis: .vertical) }
            } else { focusedPaneID = activeGroup.id }
            pendingPaneChoice = nil
            paneDrag = nil
            saveSession()
        }
    }
    var canSplitPane: Bool { groups.count < 16 }
    let transfers = TransferManager()
    let toolbarModel = ToolbarModel()
    var sidebarVisibility: NavigationSplitViewVisibility =
        (UserDefaults.standard.object(forKey: "showSidebar") as? Bool ?? true) ? .all : .detailOnly
    var showCustomize = false
    var showSettings = false
    var showShortcuts = false
    var focusSearch = 0
    /// True while the toolbar Search field is on screen.
    var searchFieldVisible = false
    /// Fallback filter bar under the breadcrumbs (used when the toolbar has no Search field).
    var showFilterBar = false
    var filterBarFocus = 0

    func activateSearch() {
        showPalette = false
        showGoToFolder = false
        showSearchPopup = true
    }
    var showSearchPopup = false
    var showGoToFolder = false
    var goToFolderFocusPath = false
    func activateGoToFolder(focusPath: Bool = true) {
        showPalette = false
        showSearchPopup = false
        goToFolderFocusPath = focusPath
        showGoToFolder = true
    }
    var showPalette = false
    var showConnect = false
    let favorites = FavoritesStore()
    let network = NetworkBrowser()
    /// Files being renamed together in the batch rename dialog.
    var batchRename: [URL]?
    /// Info panel on the right (Get Info). Persisted.
    var showInfo = UserDefaults.standard.bool(forKey: "showInfoPanel") {
        didSet { UserDefaults.standard.set(showInfo, forKey: "showInfoPanel") }
    }
    let updater = UpdateChecker.shared
    private static let liveModels = NSHashTable<AppModel>.weakObjects()
    private(set) var backgroundWrites = 0

    static var hasActiveFileOperations: Bool {
        liveModels.allObjects.contains { $0.transfers.hasActive || $0.historyBusy || $0.backgroundWrites > 0 }
    }

    static func saveAllWorkspaces() {
        liveModels.allObjects.forEach { $0.saveSession() }
        UserDefaults.standard.synchronize()
    }
    /// Files collected in the sidebar Drop Stack.
    var dropStack: [URL] = []
    var alert: String?
    /// Items waiting for the "Delete Immediately?" confirmation.
    var pendingDelete: [URL]?
    var pendingTrashDeletion: TrashDeletion?
    var preparingTrashDeletion = false
    var trashDeletionJob: TransferJob?
    /// Images in the Optimize dialog.
    var optimizeURLs: [URL]?
    /// New Project Folder dialog.
    var projectDialog = false
    /// Saved search being created or edited; nil when the dialog is closed.
    var savedSearchDialog: SavedSearch?
    /// Folder being archived; nil when the dialog is closed.
    var archiveFolder: URL?
    /// Images in the Convert dialog.
    var convertURLs: Set<URL>?
    /// Result of Find Duplicates or Compare Folders.
    var report: Report?
    /// Large Files panel.
    var largeFiles: LargeFiles?
    var showFolderAccess = false
    var sync: SyncSession?
    var renameTarget: URL?
    var renameText = ""
    /// Steps that ⌘Z can undo, and steps that ⇧⌘Z can do again (newest last).
    private(set) var undoSteps: [UndoStep] = []
    private(set) var redoSteps: [UndoStep] = []
    /// Transfers that belong to one Synchronize run; they become a single undo step.
    @ObservationIgnored var syncBatches: [UUID: SyncBatchState] = [:]
    var undoTitle: String? { undoSteps.last.map { "Undo " + $0.title } }
    var redoTitle: String? { redoSteps.last.map { "Redo " + $0.title } }

    func pushUndo(_ title: String, undo: @escaping () async -> String?, redo: @escaping () async -> String?) {
        undoSteps.append(UndoStep(title: title, undo: undo, redo: redo))
        if undoSteps.count > 50 { undoSteps.removeFirst() }
        redoSteps.removeAll()
    }

    private(set) var historyBusy = false

    private var textFieldHasFocus: Bool { NSApp.keyWindow?.firstResponder is NSTextView }

    /// ⌘Z. In a text field it undoes the typing; otherwise it takes back the last file operation.
    func undo() {
        if textFieldHasFocus {
            NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
            return
        }
        guard !historyBusy, !transfers.hasActive, let step = undoSteps.popLast() else { NSSound.beep(); return }
        historyBusy = true
        Task {
            let id = UUID()
            _ = await TransferScheduler.shared.acquire(id)
            if let error = await step.undo() { undoSteps.append(step); alert = error }
            else { redoSteps.append(step) }
            TransferScheduler.shared.release(id)
            historyBusy = false
            refresh()
        }
    }

    /// ⇧⌘Z.
    func redo() {
        if textFieldHasFocus {
            NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
            return
        }
        guard !historyBusy, !transfers.hasActive, let step = redoSteps.popLast() else { NSSound.beep(); return }
        historyBusy = true
        Task {
            let id = UUID()
            _ = await TransferScheduler.shared.acquire(id)
            if let error = await step.redo() { redoSteps.append(step); alert = error }
            else { undoSteps.append(step) }
            TransferScheduler.shared.release(id)
            historyBusy = false
            refresh()
        }
    }

    init(workspaceID: UUID = UUID()) {
        self.workspaceID = workspaceID
        layout = .row(groups.map(\.id))
        if !(UserDefaults.standard.object(forKey: "startDual") as? Bool ?? true) { focusedPaneID = groups[0].id }
        Self.liveModels.add(self)
        transfers.onFinished = { [weak self] in self?.refresh() }
        transfers.onError = { [weak self] message in self?.alert = message }
        transfers.onCompleted = { [weak self] move, records, batch in self?.recordTransferUndo(move: move, records: records, batch: batch) }
        if let location = Self.windowLocations.removeValue(forKey: workspaceID) {
            groups[0].tabs = [PaneModel(url: location)]
            groups[1].tabs = [PaneModel(url: location)]
        } else if UserDefaults.standard.data(forKey: "workspace.\(workspaceID.uuidString)") != nil || !Self.hasRestoredInitialWindow {
            restoreSession()
            Self.hasRestoredInitialWindow = true
        }
        for name in [NSApplication.willTerminateNotification, NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveSession() }
            })
        }
    }

    // MARK: Session restore

    func stop() {
        paneDrag = nil
        SystemQuickLook.shared.close(owner: self)
        saveSession()
        transfers.cancelAll()
        network.stop()
        openWindow = nil
        groups.forEach { $0.tabs.forEach { $0.stop() } }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    /// Saves every pane, nested split, divider ratio and tab for the next launch.
    func saveSession() {
        let session = WorkspaceSnapshot(panes: groups.map { $0.tabs.map(PaneSnapshot.init) }, selected: groups.map(\.selected), active: activeIndex, dual: dual, groupIDs: groups.map(\.id), layout: layout, focusedPaneID: focusedPaneID)
        guard let data = try? JSONEncoder().encode(session) else { return }
        UserDefaults.standard.set(data, forKey: "workspace.\(workspaceID.uuidString)")
        UserDefaults.standard.set(data, forKey: "workspace.last")
    }

    private func restoreSession() {
        let defaults = UserDefaults.standard
        let data = defaults.data(forKey: "workspace.\(workspaceID.uuidString)") ?? defaults.data(forKey: "workspace.last")
        if let data, let saved = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data) {
            restoreWorkspace(saved)
        } else if let legacy = defaults.dictionary(forKey: "session"), let tabs = legacy["tabs"] as? [[String]], tabs.count == 2 {
            for i in groups.indices where !tabs[i].isEmpty { groups[i].tabs = tabs[i].map { PaneModel(url: URL(fileURLWithPath: $0)) } }
        }
    }

    func restoreWorkspace(_ saved: WorkspaceSnapshot) {
        guard !saved.panes.isEmpty, saved.panes.count <= 16 else { return }
        groups.forEach { $0.tabs.forEach { $0.stop() } }
        let ids = saved.groupIDs
        let validIDs = ids?.count == saved.panes.count && Set(ids ?? []).count == saved.panes.count
        groups = saved.panes.enumerated().map { index, snapshots in
            let group = PaneGroup(id: validIDs ? ids![index] : UUID())
            if !snapshots.isEmpty { group.tabs = snapshots.map { $0.makePane() } }
            group.selected = min(max(saved.selected.indices.contains(index) ? saved.selected[index] : 0, 0), group.tabs.count - 1)
            return group
        }
        activeIndex = min(max(saved.active, 0), groups.count - 1)
        let groupIDs = groups.map(\.id)
        layout = saved.layout.flatMap { $0.valid(for: groupIDs) ? $0 : nil } ?? .row(groupIDs)
        focusedPaneID = saved.focusedPaneID.flatMap { groupIDs.contains($0) ? $0 : nil }
        if let focusedPaneID, let index = groups.firstIndex(where: { $0.id == focusedPaneID }) { activeIndex = index }
        else if !saved.dual { focusedPaneID = activeGroup.id }
    }

    var activeGroup: PaneGroup { groups[min(max(activeIndex, 0), groups.count - 1)] }
    var active: PaneModel { activeGroup.current }

    func newTab() { activeGroup.newTab() }

    func copyPath() {
        let sel = active.selection
        let paths = sel.isEmpty
            ? [active.currentURL.path]
            : sel.map(\.path).sorted()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    // MARK: More actions

    func openSelection() { active.open(active.selection) }

    func newFile(_ kind: NewFileKind = .text, in targetPane: PaneModel? = nil, directory: URL? = nil) {
        let pane = targetPane ?? active
        activate(pane)
        do {
            let url = try FileCreation.create(kind, in: directory ?? pane.currentURL)
            let steps = Self.createdSteps(url)
            pushUndo("New File", undo: steps.undo, redo: steps.redo)
            pane.load()
            pane.selection = [url]
            beginRename([url])
        } catch { alert = error.localizedDescription }
    }

    func duplicate(_ urls: Set<URL>) {
        let items = FileOperationSafety.topLevel(Array(urls)).map { (src: $0, dstDir: $0.deletingLastPathComponent()) }
        transfers.start(items: items, move: false)
    }

    func quickLook(_ urls: Set<URL>, toggle: Bool = false) {
        guard !urls.isEmpty, let window = NSApp.mainWindow ?? NSApp.keyWindow else { return }
        let ordered = orderedPreviewURLs(for: urls)
        if toggle { SystemQuickLook.shared.toggle(ordered, owner: self, window: window) }
        else { SystemQuickLook.shared.show(ordered, owner: self, window: window) }
    }

    func orderedPreviewURLs(for selected: Set<URL>) -> [URL] {
        let visible = active.sortedItems.map(\.url).filter { selected.contains($0) }
        // Preserve requested files that are not in the current visible listing.
        return visible + selected.subtracting(visible).sorted { $0.path < $1.path }
    }

    func refreshQuickLook() { SystemQuickLook.shared.update(orderedPreviewURLs(for: active.selection), owner: self) }

    func touch(_ urls: Set<URL>) {
        for url in FileOperationSafety.topLevel(Array(urls)) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        }
        refresh()
    }

    func openTerminal() {
        NSWorkspace.shared.open([active.currentURL],
                                withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    func airDrop(_ urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: Array(urls))
    }

    func compress(_ urls: Set<URL>) { startArchiveOperation(urls, extracting: false) }

    func decompress(_ urls: Set<URL>) { startArchiveOperation(urls, extracting: true) }

    /// Opens Finder's Get Info window for the selection through the system "Show Info in Finder" service.
    func getInfo(_ urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard(name: NSPasteboard.Name("com.davidpraznik.Filetor.getinfo"))
        pb.clearContents()
        pb.writeObjects(urls.sorted { $0.path < $1.path } as [NSURL])
        if !NSPerformService("Finder/Show Info", pb) {
            alert = "Could not open Get Info in Finder."
        }
    }

    func rotateImages(_ urls: Set<URL>, degrees: Int) {
        let list = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
        backgroundWrites += 1
        Task {
            defer { backgroundWrites -= 1 }
            let err = await Task.detached { FileTools.rotate(list, degrees: degrees) }.value
            refresh()
            if let err { alert = err }
        }
    }

    func stripMetadata(_ urls: Set<URL>) {
        let list = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
        backgroundWrites += 1
        Task {
            defer { backgroundWrites -= 1 }
            let err = await Task.detached { FileTools.stripMetadata(list) }.value
            refresh()
            if let err { alert = err }
        }
    }

    func convertImages(_ urls: Set<URL>, format: String, ext: String) {
        let list = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
        backgroundWrites += 1
        Task {
            defer { backgroundWrites -= 1 }
            let err = await Task.detached { FileTools.convert(list, format: format, ext: ext) }.value
            refresh()
            if let err { alert = err }
        }
    }

    func setHidden(_ value: Bool) {
        for g in groups {
            for t in g.tabs {
                t.showHidden = value
                t.load()
            }
        }
    }

    func splitPane(_ pane: PaneModel, axis: PaneSplitAxis) {
        guard canSplitPane, let source = groups.first(where: { $0.current === pane }) else { return }
        let added = PaneGroup()
        added.tabs = [PaneSnapshot(pane).makePane()]
        layout = layout.splitting(source.id, with: added.id, axis: axis)
        groups.append(added)
        focusedPaneID = nil
        activeIndex = groups.count - 1
        paneDrag = nil
        pendingPaneChoice = nil
        refreshQuickLook()
        saveSession()
    }

    func closeTab(in group: PaneGroup, at index: Int) {
        guard groups.contains(where: { $0 === group }), group.tabs.indices.contains(index) else { return }
        if group.tabs.count > 1 {
            group.close(at: index)
            refreshQuickLook()
            saveSession()
        } else if groups.count > 1, let remaining = layout.removing(group.id) {
            let activeID = activeGroup.id
            let order = layout.leaves
            let position = order.firstIndex(of: group.id) ?? 0
            let survivors = order.filter { $0 != group.id }
            let next = activeID == group.id ? survivors[min(position, survivors.count - 1)] : activeID
            group.tabs.forEach { $0.stop() }
            layout = remaining
            groups.removeAll { $0 === group }
            paneDrag = nil
            activeIndex = groups.firstIndex { $0.id == next } ?? 0
            if focusedPaneID == group.id { focusedPaneID = nil }
            pendingPaneChoice = nil
            refreshQuickLook()
            saveSession()
        } else { NSApp.keyWindow?.performClose(nil) }
    }

    func closeTab() { closeTab(in: activeGroup, at: activeGroup.selected) }

    func chooseOtherPane(from pane: PaneModel, title: String, perform: @escaping (PaneDestination) -> Void) {
        guard let source = visibleGroups.first(where: { $0.current === pane }) else { return }
        let candidates = visibleGroups.enumerated().filter { $0.element !== source }.map { index, group in
            PaneDestination(id: group.id, title: "Pane \(index + 1) — \(group.current.title)", directory: group.current.currentURL)
        }
        guard !candidates.isEmpty else { alert = "Split the pane or show all panes first."; return }
        if candidates.count == 1 { perform(candidates[0]) }
        else { pendingPaneChoice = PaneChoice(title: title, destinations: candidates, perform: perform) }
    }

    func selectPaneDestination(_ destination: PaneDestination, for choiceID: UUID) {
        guard let choice = pendingPaneChoice, choice.id == choiceID,
              let captured = choice.destinations.first(where: { $0.id == destination.id }),
              visibleGroups.contains(where: { $0.id == captured.id }) else { return }
        pendingPaneChoice = nil
        choice.perform(captured)
    }

    func startPaneDrag(_ groupID: UUID) -> PaneDragPayload? {
        guard dual, visibleGroups.contains(where: { $0.id == groupID }) else { return nil }
        let payload = PaneDragPayload(workspaceID: workspaceID, groupID: groupID, token: UUID())
        paneDrag = payload
        pendingPaneChoice = nil
        return payload
    }

    func endPaneDrag(_ payload: PaneDragPayload) {
        if paneDrag == payload { paneDrag = nil }
    }

    @discardableResult
    func movePane(_ source: UUID, to target: UUID, placement: PanePlacement) -> Bool {
        let visible = visibleGroups.map(\.id)
        guard dual, visible.contains(source), visible.contains(target),
              let moved = layout.moving(source, to: target, placement: placement),
              moved.valid(for: groups.map(\.id)) else { return false }
        layout = moved
        activeIndex = groups.firstIndex { $0.id == source } ?? activeIndex
        pendingPaneChoice = nil
        refreshQuickLook()
        saveSession()
        return true
    }

    // MARK: File operations (first version, runs on the main thread)

    /// Reloads every pane, for example after a setting that changes the listing.
    func reloadPanes() { refresh() }

    func refresh() {
        for g in groups { g.current.reloadKeepingSelection() }
    }

    func newFolder(in targetPane: PaneModel? = nil, directory: URL? = nil) {
        let pane = targetPane ?? active
        activate(pane)
        let destination = directory ?? pane.currentURL
        guard FileCreation.canCreate(in: destination) else { return }
        var name = "Untitled Folder"
        var n = 2
        while FileOperationSafety.exists(destination.appending(path: name)) {
            name = "Untitled Folder \(n)"
            n += 1
        }
        do {
            let folderURL = destination.appending(path: name)
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: false)
            let steps = Self.createdSteps(folderURL)
            pushUndo("New Folder", undo: steps.undo, redo: steps.redo)
            refresh()
            pane.selection = [folderURL]
            beginRename([folderURL])
        } catch {
            alert = error.localizedDescription
        }
    }

    /// Undo of a created item sends it to the Trash; redo takes it back out.
    static func createdSteps(_ url: URL) -> (undo: () async -> String?, redo: () async -> String?) {
        transferClosures([TransferRecord(src: url, dst: url, moved: false, trashed: nil)])
    }

    func trash(_ urls: Set<URL>) {
        // Off the main thread: on a network disk trashItem can take a while before it fails, which showed the spinning wheel.
        // The toolbar progress ring only shows up when it takes longer than a moment, so quick trashing causes no flicker.
        let job = TransferJob(title: "Moving to Trash")
        backgroundWrites += 1
        Task {
            defer { backgroundWrites -= 1 }
            let shower = Task {
                try? await Task.sleep(for: .milliseconds(400))
                if !Task.isCancelled { transfers.jobs.append(job) }
            }
            let r = await Task.detached(priority: .userInitiated) { Self.trashAll(urls, control: job.control) }.value
            shower.cancel()
            transfers.jobs.removeAll { $0.id == job.id }
            finishTrash(failed: r.failed, noTrash: r.noTrash, moved: r.moved)
        }
    }

    nonisolated private static func trashAll(_ urls: Set<URL>, control: TransferControl) -> (failed: [String], noTrash: [URL], moved: [(original: URL, trashed: URL)]) {
        var failed: [String] = []
        var noTrash: [URL] = []
        var moved: [(original: URL, trashed: URL)] = []
        for url in FileOperationSafety.topLevel(Array(urls)) {
            if control.cancelled { break }
            do {
                var result: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &result)
                if let result { moved.append((original: url, trashed: result as URL)) }
            } catch {
                // Network and some external volumes have no Trash; Finder offers to delete right away.
                if (error as? CocoaError)?.code == .featureUnsupported { noTrash.append(url) }
                else { failed.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
        }
        return (failed, noTrash, moved)
    }

    private func finishTrash(failed: [String], noTrash: [URL], moved movedItems: [(original: URL, trashed: URL)]) {
        if !noTrash.isEmpty { pendingDelete = noTrash.sorted { $0.path < $1.path } }
        if !movedItems.isEmpty {
            let steps = Self.transferClosures(movedItems.map { TransferRecord(src: $0.original, dst: $0.trashed, moved: true, trashed: nil) })
            pushUndo(movedItems.count == 1 ? "Move to Trash" : "Move to Trash (\(movedItems.count) items)", undo: steps.undo, redo: steps.redo)
        }
        refresh()
        if !failed.isEmpty { alert = failed.joined(separator: "\n") }
    }

    /// Asks first, then deletes without the Trash. This cannot be undone.
    func deleteImmediately(_ urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        if let first = urls.first, let root = TrashLocation.root(containing: first),
           urls.allSatisfy({ TrashLocation.root(containing: $0) == root }) {
            requestTrashDeletion(root: root, selection: urls)
            return
        }
        pendingDelete = FileOperationSafety.topLevel(Array(urls))
    }

    func confirmDelete() {
        guard let urls = pendingDelete else { return }
        pendingDelete = nil
        // Runs in the background and shows in the toolbar progress ring like a copy.
        let job = TransferJob(title: urls.count == 1 ? "Deleting \(urls[0].lastPathComponent)" : "Deleting \(urls.count) items")
        transfers.jobs.append(job)
        Task {
            var failed: [String] = []
            for (i, url) in urls.enumerated() {
                if job.control.cancelled { break }
                job.currentName = url.lastPathComponent
                if let error = await Task.detached(priority: .userInitiated, operation: { Self.remove(url) }).value { failed.append(error) }
                job.fraction = Double(i + 1) / Double(urls.count)
            }
            job.isFinished = true
            refresh()
            if !failed.isEmpty { alert = failed.joined(separator: "\n") }
            try? await Task.sleep(for: .seconds(1))
            transfers.jobs.removeAll { $0.id == job.id }
        }
    }

    nonisolated private static func remove(_ url: URL) -> String? {
        do { try FileManager.default.removeItem(at: url); return nil }
        catch { return "\(url.lastPathComponent): \(error.localizedDescription)" }
    }

    func beginRename(_ urls: Set<URL>) {
        if urls.count > 1 {
            batchRename = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            return
        }
        guard let url = urls.first else { return }
        let item = FileItem(url: url)
        let showExtension = UserDefaults.standard.object(forKey: "showExtensions") as? Bool ?? true
        renameText = item.displayName(showExtension: showExtension)
        renameHidesExtension = renameText != item.name
        renameTarget = url
    }

    private(set) var renameHidesExtension = false

    /// Renames in two steps through temporary names, so swaps and shifted numbering never collide.
    private static func moveViaTemps(_ moves: [(from: URL, to: URL)]) throws {
        try RenameTransaction.run(moves)
    }

    func applyBatchRename(_ pairs: [(URL, String)]) {
        guard pairs.allSatisfy({ FileOperationSafety.validName($0.1) }) else { alert = "Enter valid file names without slashes."; return }
        let moves = pairs
            .filter { $0.1 != $0.0.lastPathComponent }
            .map { (from: $0.0, to: $0.0.deletingLastPathComponent().appending(path: $0.1)) }
        do {
            try Self.moveViaTemps(moves)
            if !moves.isEmpty {
                pushUndo("Rename", undo: {
                    do { try Self.moveViaTemps(moves.map { (from: $0.to, to: $0.from) }); return nil }
                    catch { return error.localizedDescription }
                }, redo: {
                    do { try Self.moveViaTemps(moves); return nil }
                    catch { return error.localizedDescription }
                })
            }
        } catch {
            alert = "Rename failed: \(error.localizedDescription)"
        }
        refresh()
    }

    func commitRename() {
        guard let url = renameTarget else { return }
        renameTarget = nil
        let edited = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = FileNamePresentation.preservingExtension(edited, original: url.lastPathComponent, hidden: renameHidesExtension)
        renameHidesExtension = false
        guard !name.isEmpty, name != url.lastPathComponent else { return }
        guard !name.contains("/") else { alert = "A name cannot contain \"/\"."; return }
        let dest = url.deletingLastPathComponent().appending(path: name)
        if FileOperationSafety.exists(dest) && !FileOperationSafety.sameItem(url, dest) {
            alert = "\"\(name)\" already exists."
            return
        }
        applyBatchRename([(url, name)])
    }

    /// Files dropped onto a pane or folder (from the other pane, Drop Stack, Finder).
    /// Moves every pane that is inside the volume to Home, then ejects it off the main thread.
    func eject(_ volume: URL) {
        let prefix = volume.standardizedFileURL.path
        let home = URL(filePath: NSHomeDirectory())
        for g in groups {
            for t in g.tabs where t.currentURL.standardizedFileURL.path.hasPrefix(prefix) {
                t.navigate(to: home)
            }
        }
        DispatchQueue.global().async {
            try? NSWorkspace.shared.unmountAndEjectDevice(at: volume)
        }
    }

    func dropTransfer(_ urls: [URL], into dir: URL, move: Bool) {
        let items = urls
            .filter { $0 != dir && !(move && $0.deletingLastPathComponent() == dir) }
            .map { (src: $0, dstDir: dir) }
        transfers.start(items: items, move: move)
    }

    func transfer(_ urls: Set<URL>, move: Bool) {
        guard !urls.isEmpty else { return }
        chooseOtherPane(from: active, title: move ? "Move to Pane" : "Copy to Pane") { [weak self] target in
            self?.dropTransfer(Array(urls), into: target.directory, move: move)
        }
    }
}

extension KeyEquivalent {
    static let f2 = KeyEquivalent(Character(UnicodeScalar(NSF2FunctionKey)!))
    static let f5 = KeyEquivalent(Character(UnicodeScalar(NSF5FunctionKey)!))
    static let f6 = KeyEquivalent(Character(UnicodeScalar(NSF6FunctionKey)!))
}
