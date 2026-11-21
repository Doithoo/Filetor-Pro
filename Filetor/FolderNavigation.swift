import Foundation
import Observation

@Observable final class RecentFolders {
    static let shared = RecentFolders()
    private static let key = "recentFolders.v1"
    private let defaults: UserDefaults
    private(set) var urls: [URL]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var seen = Set<URL>()
        urls = (defaults.stringArray(forKey: Self.key) ?? []).compactMap {
            guard $0.hasPrefix("/") else { return nil }
            let url = URL(fileURLWithPath: $0).standardizedFileURL
            return seen.insert(url).inserted ? url : nil
        }.prefix(20).map { $0 }
    }

    func record(_ url: URL) {
        guard url.isFileURL else { return }
        let url = url.standardizedFileURL
        guard urls.first != url else { return }
        urls.removeAll { $0 == url }
        urls.insert(url, at: 0)
        urls = Array(urls.prefix(20))
        defaults.set(urls.map(\.path), forKey: Self.key)
    }

    func clear() { urls = []; defaults.removeObject(forKey: Self.key) }
}

/// Browsing this model never navigates a pane. Only opening a result does.
@Observable final class FolderNavigationModel {
    let base: URL
    let showHidden: Bool
    private(set) var directory: URL
    private(set) var path: String
    private(set) var entries: [PathCandidate] = []
    private(set) var loading = false
    private(set) var error: String?
    private(set) var completing = false
    private var history: [URL] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    var canGoBack: Bool { !history.isEmpty }

    init(base: URL, showHidden: Bool) {
        self.base = base.standardizedFileURL
        directory = base.standardizedFileURL
        path = Self.pathText(base)
        self.showHidden = showHidden
    }

    static func pathText(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath + (url.path == "/" ? "" : "/")
    }

    func browse(_ url: URL) {
        let target = url.standardizedFileURL
        if target != directory { history.append(directory) }
        directory = target
        path = Self.pathText(target)
        completing = false
        refresh()
    }

    func back() {
        guard let previous = history.popLast() else { return }
        directory = previous; path = Self.pathText(previous); completing = false
        refresh()
    }

    func edit(_ value: String) {
        guard value != path else { return }
        path = value
        completing = true
        refresh(debounce: true)
    }

    func refresh(debounce: Bool = false) {
        stop()
        let version = UUID(); generation = version
        let path = path, base = directory, hidden = showHidden, completing = completing
        entries = []; error = nil; loading = true
        task = Task { [weak self] in
            if debounce {
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            }
            let worker = Task.detached(priority: .userInitiated) {
                try PathCompletion.list(path, base: base, limit: nil,
                                        foldersOnly: !completing, showHidden: hidden)
            }
            let result = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, self.generation == version else { return }
            self.loading = false
            switch result {
            case .success(let entries): self.entries = entries
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }

    func stop() { task?.cancel(); task = nil; generation = UUID(); loading = false }
}

/// Commits to the captured pane, even when another pane was active on opening.
@Observable final class FolderNavigationAction {
    private(set) var opening = false
    private(set) var error: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    func open(_ url: URL, app: AppModel, pane: PaneModel, completion: @escaping () -> Void) {
        stop(); error = nil; opening = true
        task = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { try PathCompletion.destination(url) }
            let result = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled else { return }
            self.opening = false
            guard app.active === pane, app.groups.contains(where: { $0.tabs.contains(where: { $0 === pane }) }) else { return }
            switch result {
            case .success(let destination):
                pane.clearSearch(); pane.clearTag()
                if destination.directory { pane.navigate(to: destination.url) }
                else { pane.navigateSelecting(destination.url) }
                completion()
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }

    func stop() { task?.cancel(); task = nil; opening = false; error = nil }
}
