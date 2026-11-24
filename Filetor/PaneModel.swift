import SwiftUI
import Observation

@Observable
final class PaneModel: Identifiable {
    let id = UUID()
    var currentURL: URL = FileManager.default.homeDirectoryForCurrentUser
    var items: [FileItem] = []
    var selection = Set<URL>()
    var sortOrder: [KeyPathComparator<FileItem>] = [
        KeyPathComparator(\FileItem.name, comparator: .localizedStandard)
    ]
    var errorMessage: String?
    private(set) var trashAccessDenied = false
    var loading = false
    var searchTruncated = false
    var isVisible = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadGeneration = UUID()
    @ObservationIgnored private var lastRecordedDirectory: URL?
    var revision = 0
    var criteria = SearchCriteria() { didSet { if !treeActive { cancelExpandAll() }; if searchSubfolders { restartSearch() } } }
    var hasSearchFilters: Bool { !filter.isEmpty || !criteria.isEmpty }
    @ObservationIgnored private var pendingSelection: URL?
    var filter = "" { didSet { if !treeActive { cancelExpandAll() }; if searchSubfolders { restartSearch() } } }
    /// Search the filter text in all subfolders instead of only filtering the current folder.
    var searchSubfolders = UserDefaults.standard.bool(forKey: "searchSubfolders") {
        didSet {
            UserDefaults.standard.set(searchSubfolders, forKey: "searchSubfolders")
            restartSearch()
        }
    }
    var searchResults: [FileItem] = []
    var searching = false
    var foldersScanned = 0
    /// Name of the tag whose files are shown (a Spotlight search over the whole Mac), nil in a normal folder.
    var tagFilter: String? { didSet { if !treeActive { cancelExpandAll() } } }
    /// Set when the list shows a saved search (tagFilter then holds its name).
    var savedSearchID: UUID?
    var tagResults: [FileItem] = []
    var tagSearching = false
    @ObservationIgnored private var tagTask: Task<Void, Never>?
    var title: String { tagFilter ?? (TrashLocation.isRoot(currentURL) ? "Trash" : CloudLocation.title(for: currentURL)) }
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    var searchActive: Bool { tagFilter == nil && searchSubfolders && hasSearchFilters }
    /// 0 = list, 1 = icons
    var viewMode = 0 { didSet { if !treeActive { cancelExpandAll() } } }
    var showHidden = UserDefaults.standard.bool(forKey: "showHidden") { didSet { cancelExpandAll() } }

    private var backStack: [URL] = []
    private var forwardStack: [URL] = []

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { currentURL.path != "/" }

    var sortedItems: [FileItem] {
        let visible: [FileItem]
        if tagFilter != nil {
            visible = filter.isEmpty ? tagResults : tagResults.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        } else {
            visible = searchActive ? searchResults
                : hasSearchFilters ? items.filter { criteria.matches($0, name: filter) } : items
        }
        let top = ordered(visible)
        return treeActive && !expanded.isEmpty ? flatten(top) : top
    }

    private func ordered(_ list: [FileItem]) -> [FileItem] {
        let sorted = list.sorted(using: sortOrder)
        let foldersFirst = UserDefaults.standard.object(forKey: "foldersFirst") as? Bool ?? true
        guard foldersFirst else { return sorted }
        return sorted.filter { $0.isDirectory } + sorted.filter { !$0.isDirectory }
    }

    // MARK: Folders opened in place (list view)

    /// Folders that are open in the list. Kept while moving between folders, cleared only by closing them.
    var expanded = Set<URL>()
    private var children: [URL: [FileItem]] = [:]
    var loadingFolders = Set<URL>()
    var expansionErrors: [URL: String] = [:]
    @ObservationIgnored private var expansionTasks: [URL: Task<Void, Never>] = [:]

    private(set) var expandingAll = false
    @ObservationIgnored private var expandAllTask: Task<Void, Never>?
    @ObservationIgnored private var expandAllGeneration = UUID()

    var canExpandAll: Bool { treeActive && !loading && items.contains(where: \.expandable) }
    var canCollapseAll: Bool { treeActive && (expandingAll || !expanded.isEmpty) }

    func cancelExpandAll() {
        expandAllTask?.cancel()
        expandAllTask = nil
        expandAllGeneration = UUID()
        expandingAll = false
    }

    func toggleExpandAll() {
        if expandingAll { cancelExpandAll() } else { expandAll() }
    }

    /// Read off the main thread and apply a single bounded tree update. Cancelling
    /// preserves the tree as it was before the request; stale workers cannot reopen it.
    func expandAll(limits: FolderExpansion.Limits = .init()) {
        guard canExpandAll, !expandingAll else { return }
        cancelExpansions()
        let generation = UUID()
        expandAllGeneration = generation
        expandingAll = true
        let root = currentURL, hidden = showHidden, roots = items
        expandAllTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                try FolderExpansion.read(roots: roots, hidden: hidden, limits: limits)
            }
            let result = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, self.expandAllGeneration == generation,
                  self.currentURL == root, self.treeActive, self.showHidden == hidden else { return }
            self.expandingAll = false
            self.expandAllTask = nil
            if case .success(let tree) = result {
                self.children.merge(tree.children) { _, new in new }
                self.expanded.formUnion(tree.children.keys)
                for url in tree.children.keys { self.expansionErrors[url] = nil }
                self.expansionErrors.merge(tree.errors) { _, new in new }
                TagStore.shared.remember(tree.children.values.flatMap { $0.flatMap(\.tags) })
                if tree.limited {
                    self.errorMessage = "Expansion stopped at the display limit (\(limits.folders) folders, \(limits.items) items, or \(limits.depth) levels). Open a subfolder to continue."
                } else if !tree.errors.isEmpty {
                    self.errorMessage = "Could not expand \(tree.errors.count) folder(s). Other accessible folders were expanded."
                }
            }
        }
    }

    /// The tree is only used in the plain list of a folder, not in search results, tag views or filtered lists.
    var treeActive: Bool { viewMode == 0 && tagFilter == nil && !searchActive && !hasSearchFilters }

    /// How deep a row is below the folder that is shown (0 = directly inside it).
    func level(of url: URL) -> Int {
        guard treeActive else { return 0 }
        return max(0, url.pathComponents.count - currentURL.pathComponents.count - 1)
    }

    private func flatten(_ list: [FileItem]) -> [FileItem] {
        var out: [FileItem] = []
        for item in list {
            out.append(item)
            if item.expandable, expanded.contains(item.url), let kids = children[item.url] {
                out += flatten(ordered(kids))
            }
        }
        return out
    }

    nonisolated static func readDirectory(_ dir: URL, hidden: Bool) throws -> [FileItem] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: FileItem.keys, options: hidden ? [] : [.skipsHiddenFiles])
        return try urls.map { url in
            try Task.checkCancellation()
            return FileItem(url: url)
        }
    }

    func toggleExpanded(_ url: URL) {
        let url = url.standardizedFileURL
        if expanded.contains(url) { collapse(url) } else { expand(url) }
    }

    func expand(_ url: URL) {
        let url = url.standardizedFileURL
        guard treeActive, !loadingFolders.contains(url), FileItem(url: url).expandable,
              url.path.hasPrefix(currentURL.path == "/" ? "/" : currentURL.path + "/") else { return }
        expanded.insert(url)
        loadingFolders.insert(url)
        expansionErrors[url] = nil
        let hidden = showHidden
        let root = currentURL
        expansionTasks[url]?.cancel()
        expansionTasks[url] = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { try Self.readDirectory(url, hidden: hidden) }
            let result = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, self.currentURL == root, self.expanded.contains(url) else { return }
            self.loadingFolders.remove(url)
            self.expansionTasks[url] = nil
            switch result {
            case .success(let items):
                self.children[url] = items
                TagStore.shared.remember(items.flatMap(\.tags))
            case .failure(let error):
                self.expanded.remove(url)
                self.expansionErrors[url] = error.localizedDescription
                self.errorMessage = "Could not expand \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    func collapse(_ url: URL) {
        cancelExpandAll()
        let url = url.standardizedFileURL
        let prefix = url.path + "/"
        for key in Array(expansionTasks.keys) where key == url || key.path.hasPrefix(prefix) {
            expansionTasks.removeValue(forKey: key)?.cancel()
            loadingFolders.remove(key)
        }
        expanded = expanded.filter { $0 != url && !$0.path.hasPrefix(prefix) }
        children = children.filter { $0.key != url && !$0.key.path.hasPrefix(prefix) }
        selection = selection.filter { !$0.path.hasPrefix(prefix) }
    }

    func collapseAll() {
        cancelExpandAll()
        expansionTasks.values.forEach { $0.cancel() }
        expansionTasks.removeAll()
        loadingFolders.removeAll()
        expanded.removeAll()
        children.removeAll()
        selection = selection.filter { $0.deletingLastPathComponent() == currentURL }
    }

    func setVisible(_ value: Bool) {
        guard value != isVisible else { return }
        isVisible = value
        if value {
            lastRecordedDirectory = nil
            reload(keepSelection: true); startWatching()
            if searchActive { restartSearch() }
            if tagFilter != nil { startTagQuery() }
        }
        else { stop() }
    }

    func stop() {
        isVisible = false
        stopWatching()
        loadTask?.cancel()
        loadGeneration = UUID()
        loading = false
        searchTask?.cancel()
        searching = false
        sizeTask?.cancel()
        tagTask?.cancel()
        cancelExpansions()
    }

    private func cancelExpansions() {
        cancelExpandAll()
        expansionTasks.values.forEach { $0.cancel() }
        expansionTasks.removeAll()
        loadingFolders.removeAll()
    }

    init(url: URL? = nil) {
        if let url { currentURL = url.standardizedFileURL }
    }

    func navigate(to url: URL) {
        pendingSelection = nil
        let target = url.standardizedFileURL
        if tagFilter != nil {
            clearTag()
            if target == currentURL { load(); return }
        }
        guard target != currentURL else { return }
        backStack.append(currentURL)
        forwardStack.removeAll()
        currentURL = target
        clearSearch()
        load()
    }

    func navigateSelecting(_ url: URL) {
        clearSearch()
        clearTag()
        let revealHidden = !showHidden && url.lastPathComponent.hasPrefix(".")
        let sameFolder = currentURL == url.deletingLastPathComponent().standardizedFileURL
        if revealHidden { showHidden = true }
        navigate(to: url.deletingLastPathComponent())
        if revealHidden && sameFolder { load() }
        if !loading, items.contains(where: { $0.url == url.standardizedFileURL }) {
            selection = [url.standardizedFileURL]
        } else {
            if !loading { load() }
            pendingSelection = url.standardizedFileURL
        }
    }

    func clearSearch() {
        pendingSelection = nil
        filter = ""
        criteria = SearchCriteria()
        stopSearch()
        searchResults = []
        selection.removeAll()
    }

    func goBack() {
        guard let prev = backStack.popLast() else { return }
        clearTag()
        forwardStack.append(currentURL)
        currentURL = prev
        clearSearch()
        load()
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        clearTag()
        backStack.append(currentURL)
        currentURL = next
        clearSearch()
        load()
    }

    func goUp() {
        guard canGoUp else { return }
        navigate(to: currentURL.deletingLastPathComponent())
    }

    /// Explicitly browse a package while ordinary Open keeps launching it.
    func showPackageContents(_ url: URL) {
        guard FileItem(url: url).canShowPackageContents else { return }
        navigate(to: url)
    }

    func open(_ urls: Set<URL>) {
        for url in urls {
            let item = FileItem(url: url)
            if item.isDirectory && !item.isPackage {
                navigate(to: url)
                return
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func toggleHidden() {
        showHidden.toggle()
        load()
    }

    func load() {
        cancelExpansions()
        sizeTask?.cancel()
        expansionErrors.removeAll()
        reload(keepSelection: false)
    }

    /// Re-reads the folder after a change made outside the app, keeping the selection.
    private func refresh() { reload(keepSelection: true) }

    /// Re-reads the folder (and the tag view) after a change made in the app, keeping the selection.
    func reloadKeepingSelection() {
        reload(keepSelection: true)
        if tagFilter != nil { startTagQuery() }
        if searchActive { restartSearch() }
    }

    // MARK: Tags

    /// Shows new tags on files without re-reading the folder.
    func applyTagChanges(_ map: [URL: [String]]) {
        for i in items.indices { if let t = map[items[i].url] { items[i].tags = t } }
        for key in Array(children.keys) {
            guard var list = children[key] else { continue }
            for i in list.indices { if let t = map[list[i].url] { list[i].tags = t } }
            children[key] = list
        }
        for i in searchResults.indices { if let t = map[searchResults[i].url] { searchResults[i].tags = t } }
        if tagFilter != nil {
            for i in tagResults.indices { if let t = map[tagResults[i].url] { tagResults[i].tags = t } }
        }
        if let f = tagFilter, savedSearchID == nil {
            let store = TagStore.shared
            tagResults.removeAll { item in map[item.url] != nil && !item.tags.contains { store.matches($0, f) } }
        }
    }

    func showSaved(_ search: SavedSearch) {
        savedSearchID = search.id
        tagFilter = search.name
        tagResults = []
        selection.removeAll()
        filter = ""
        criteria = SearchCriteria()
        startTagQuery()
    }

    func showTag(_ name: String) {
        savedSearchID = nil
        let onNetwork = (try? currentURL.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == false
        tagScanRoot = onNetwork ? currentURL : nil
        tagFilter = name
        tagResults = []
        selection.removeAll()
        filter = ""
        criteria = SearchCriteria()
        startTagQuery()
    }

    func clearTag() {
        tagTask?.cancel()
        tagFilter = nil
        savedSearchID = nil
        tagResults = []
        tagSearching = false
    }

    /// Folder to scan by hand when the tag view was opened on a network disk (Spotlight does not index those).
    @ObservationIgnored private var tagScanRoot: URL?

    private func startTagQuery() {
        tagTask?.cancel()
        guard let name = tagFilter else { return }
        tagSearching = true
        let saved = savedSearchID.flatMap { SavedSearchStore.shared.item($0) }
        let query = saved.map { $0.makeQuery() }
        let folder = saved?.folder ?? ""
        let scanRoot = saved == nil ? tagScanRoot : nil
        tagTask = Task { [weak self] in
            var urls: [URL]
            if let query { urls = await SpotlightSearch.run(query, onlyIn: folder) } else { urls = await TagQuery.run(name) }
            guard let self, !Task.isCancelled, self.tagFilter == name else { return }
            self.showTagResults(urls, finished: scanRoot == nil)
            guard let scanRoot else { return }
            let extra = await TagQuery.scan(name, root: scanRoot)
            guard !Task.isCancelled, self.tagFilter == name else { return }
            let known = Set(urls)
            urls += extra.filter { !known.contains($0) }
            self.showTagResults(urls, finished: true)
        }
    }

    private func showTagResults(_ urls: [URL], finished: Bool) {
        let home = NSHomeDirectory()
        tagResults = urls.map { url in
            var item = FileItem(url: url)
            var parent = url.deletingLastPathComponent().path
            if parent.hasPrefix(home) { parent = "~" + String(parent.dropFirst(home.count)) }
            item.folder = parent
            return item
        }
        if finished { tagSearching = false }
    }

    private func reload(keepSelection: Bool) {
        cancelExpandAll()
        loadTask?.cancel()
        let generation = UUID()
        loadGeneration = generation
        let root = currentURL
        let hidden = showHidden
        let base = root.path == "/" ? "/" : root.path + "/"
        let openFolders = expanded.filter { $0.path.hasPrefix(base) }.sorted { $0.pathComponents.count < $1.pathComponents.count }
        if !keepSelection { selection.removeAll(); items = []; children = [:] }
        loading = true
        errorMessage = nil
        trashAccessDenied = false
        loadTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                let items = try Self.readDirectory(root, hidden: hidden)
                var descendants: [URL: [FileItem]] = [:]
                for url in openFolders {
                    try Task.checkCancellation()
                    if let list = try? Self.readDirectory(url, hidden: hidden) { descendants[url] = list }
                }
                return (items, descendants)
            }
            let result = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, self.loadGeneration == generation, self.currentURL == root else { return }
            self.loading = false
            switch result {
            case .success(let (items, descendants)):
                self.items = items
                if self.isVisible && self.lastRecordedDirectory != root {
                    RecentFolders.shared.record(root)
                    self.lastRecordedDirectory = root
                }
                // Preserve expansions completed while the root was being refreshed.
                let completedMeanwhile = self.children.filter { !openFolders.contains($0.key) && self.expanded.contains($0.key) }
                self.children = descendants.filter { self.expanded.contains($0.key) }
                    .merging(completedMeanwhile) { _, newer in newer }
                for url in Array(self.expanded) where url.path.hasPrefix(base) && self.children[url] == nil && !self.loadingFolders.contains(url) {
                    self.expand(url)
                }
                TagStore.shared.remember(items.flatMap(\.tags))
                let present = Set(items.map(\.url)).union(self.children.values.flatMap { $0.map(\.url) })
                if self.tagFilter == nil && !self.searchActive {
                    self.selection = self.selection.intersection(present)
                }
                if let pending = self.pendingSelection, pending.deletingLastPathComponent() == root {
                    self.selection = present.contains(pending) ? [pending] : []
                    self.pendingSelection = nil
                }
                self.revision += 1
                self.startFolderSizes()
            case .failure(let error):
                self.items = []
                self.children = [:]
                self.errorMessage = error.localizedDescription
                self.trashAccessDenied = TrashLocation.contains(root)
                    && ((error as? CocoaError)?.code == .fileReadNoPermission
                        || (error as NSError).domain == NSPOSIXErrorDomain
                        && [Int(EACCES), Int(EPERM)].contains((error as NSError).code))
            }
        }
        if !keepSelection { startWatching(); if searchActive { restartSearch() } }
    }

    // MARK: Search in subfolders

    func stopSearch() {
        searchTask?.cancel()
        searching = false
    }

    func restartSearch() {
        searchTask?.cancel()
        searchResults = []
        foldersScanned = 0
        searchTruncated = false
        guard searchActive else { searching = false; return }
        searching = true
        let root = currentURL.standardizedFileURL
        let query = filter, criteria = criteria
        let hidden = showHidden
        searchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            let stream = AsyncStream<SearchBatch> { cont in
                let worker = Task.detached(priority: .userInitiated) {
                    Self.scan(root: root, query: query, criteria: criteria, hidden: hidden, into: cont)
                    cont.finish()
                }
                cont.onTermination = { _ in worker.cancel() }
            }
            for await batch in stream {
                guard let self, !Task.isCancelled else { return }
                let rootPath = root.path
                self.searchResults.append(contentsOf: batch.urls.map { url in
                    var item = FileItem(url: url)
                    let parent = url.deletingLastPathComponent().path
                    item.folder = parent == rootPath ? "" : String(parent.dropFirst(rootPath.count + 1))
                    return item
                })
                self.foldersScanned = batch.folders
                self.searchTruncated = batch.truncated
            }
            guard !Task.isCancelled else { return }
            self?.searching = false
        }
    }

    nonisolated private static func scan(root: URL, query: String, criteria: SearchCriteria, hidden: Bool, into cont: AsyncStream<SearchBatch>.Continuation) {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !hidden { options.insert(.skipsHiddenFiles) }
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey], options: options) else { return }
        let now = Date()
        var batch: [URL] = []
        var folders = 0
        var found = 0
        var last = Date()
        while let url = en.nextObject() as? URL {
            if Task.isCancelled { return }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey])
            let directory = values?.isDirectory == true && values?.isPackage != true
            if directory { folders += 1 }
            if criteria.matches(url: url, directory: directory, size: values?.fileSize.map(Int64.init),
                                modified: values?.contentModificationDate, name: query, now: now) {
                batch.append(url)
                found += 1
                if found >= 5000 { break }
            }
            if Date().timeIntervalSince(last) > 0.15 {
                cont.yield(SearchBatch(urls: batch, folders: folders))
                batch = []
                last = Date()
            }
        }
        cont.yield(SearchBatch(urls: batch, folders: folders, truncated: found >= 5000))
    }

    // MARK: Watching the folder for changes made outside the app

    @ObservationIgnored private var watchID: UUID?

    private func stopWatching() {
        if let watchID { DirectoryMonitor.shared.remove(watchID) }
        watchID = nil
    }

    private func startWatching() {
        stopWatching()
        guard isVisible else { return }
        watchID = DirectoryMonitor.shared.observe(currentURL) { [weak self] paths in
            guard let self, self.isVisible else { return }
            // Ignore unrelated changes deep inside collapsed folders (especially Home/Library).
            let visible = Set(([self.currentURL] + Array(self.expanded)).map { $0.resolvingSymlinksInPath().path })
            guard self.searchActive || paths.isEmpty || UserDefaults.standard.bool(forKey: "calculateFolderSizes") || paths.contains(where: {
                let path = URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
                return visible.contains(path) || visible.contains((path as NSString).deletingLastPathComponent)
            }) else { return }
            self.reloadKeepingSelection()
        }
    }

    @ObservationIgnored private var sizeTask: Task<Void, Never>?

    /// Calculates the total size of every folder in the background when "Calculate all folder sizes" is on.
    private func startFolderSizes() {
        sizeTask?.cancel()
        guard isVisible, UserDefaults.standard.bool(forKey: "calculateFolderSizes") else { return }
        let folders = items.filter(\.isDirectory).map(\.url)
        guard !folders.isEmpty else { return }
        let dir = currentURL
        sizeTask = Task { [weak self] in
            for url in folders {
                if Task.isCancelled { return }
                let worker = Task.detached(priority: .utility) { FileTools.size(of: url) }
                let size = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                if Task.isCancelled { return }
                guard let self, self.currentURL == dir,
                      let i = self.items.firstIndex(where: { $0.url == url }) else { continue }
                self.items[i].size = size
                self.items[i].sizeCalculated = true
            }
        }
    }
}

nonisolated struct SearchBatch: Sendable {
    var urls: [URL]
    var folders: Int
    var truncated = false
}
