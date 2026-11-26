import SwiftUI
import Observation

/// Sidebar favorites: folders the user keeps, saved between launches.
@Observable
final class FavoritesStore {
    private(set) var urls: [URL]
    private static let key = "favorites.v1"

    init() {
        if let saved = UserDefaults.standard.array(forKey: Self.key) as? [String] {
            urls = saved.map { URL(filePath: $0) }
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            urls = [
                home,
                home.appending(path: "Desktop"),
                home.appending(path: "Documents"),
                home.appending(path: "Downloads"),
                URL(filePath: "/Applications"),
            ]
        }
    }

    private func save() {
        UserDefaults.standard.set(urls.map(\.path), forKey: Self.key)
    }

    /// Adds folders (or moves existing ones) before `target`; with no target they go to the end.
    func insert(_ new: [URL], before target: URL?) {
        for u in new {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue else { continue }
            urls.removeAll { $0 == u }
            if let target, let i = urls.firstIndex(of: target) {
                urls.insert(u, at: i)
            } else {
                urls.append(u)
            }
        }
        save()
    }

    /// Moves a favorite to the position of `target`, used while dragging to reorder.
    func move(_ url: URL, onto target: URL) {
        guard let from = urls.firstIndex(of: url), let to = urls.firstIndex(of: target), from != to else { return }
        urls.remove(at: from)
        urls.insert(url, at: to)
        save()
    }

    func remove(_ url: URL) {
        urls.removeAll { $0 == url }
        save()
    }

    func contains(_ url: URL) -> Bool { urls.contains(url) }

    func place(for url: URL) -> Place {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch url.standardizedFileURL.path {
        case home.path: return Place(name: L10n.tr("Home"), icon: "house", url: url)
        case home.appending(path: "Desktop").path: return Place(name: L10n.tr("Desktop"), icon: "menubar.dock.rectangle", url: url)
        case home.appending(path: "Documents").path: return Place(name: L10n.tr("Documents"), icon: "doc", url: url)
        case home.appending(path: "Downloads").path: return Place(name: L10n.tr("Downloads"), icon: "arrow.down.circle", url: url)
        case "/Applications", home.appending(path: "Applications").path:
            return Place(name: L10n.tr("Applications"), icon: "square.grid.2x2", url: url)
        case home.appending(path: "Movies").path:
            return Place(name: L10n.tr("Movies"), icon: "film", url: url)
        case home.appending(path: "Music").path:
            return Place(name: L10n.tr("Music"), icon: "music.note", url: url)
        case home.appending(path: "Pictures").path:
            return Place(name: L10n.tr("Pictures"), icon: "photo", url: url)
        case home.appending(path: "Library").path:
            return Place(name: L10n.tr("Library"), icon: "books.vertical", url: url)
        case home.appending(path: "Public").path:
            return Place(name: L10n.tr("Public"), icon: "person.2", url: url)
        default: return Place(name: url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent, icon: "folder", url: url)
        }
    }
}
