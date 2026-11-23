import Foundation

/// Trash is browsed as a real folder, so selection, previews, tabs and back/forward
/// use the existing pane model. Other disks have their own per-user Trash folders.
enum TrashLocation {
    nonisolated static var home: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
    }

    nonisolated static func isRoot(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if path == home.standardizedFileURL.path { return true }
        let parts = url.standardizedFileURL.pathComponents
        return parts.count == 5 && parts[1] == "Volumes" && parts[3] == ".Trashes"
            && parts[4] == String(getuid())
    }

    nonisolated static func contains(_ url: URL) -> Bool { root(containing: url) != nil }

    nonisolated static func root(containing url: URL) -> URL? {
        var current = url.standardizedFileURL
        while current.path != "/" {
            if isRoot(current) { return current }
            current.deleteLastPathComponent()
        }
        return nil
    }

    nonisolated static func url(on volume: URL) throws -> URL {
        try FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                    appropriateFor: volume, create: false)
    }
}

extension AppModel {
    func openTrash(at url: URL = TrashLocation.home) {
        showGoToFolder = false
        showSearchPopup = false
        active.clearSearch(); active.clearTag()
        if active.currentURL.standardizedFileURL == url.standardizedFileURL { active.load() }
        else { active.navigate(to: url) }
    }

    func openTrash(on volume: URL) {
        let pane = active
        showGoToFolder = false
        showSearchPopup = false
        let origin = pane.currentURL
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try TrashLocation.url(on: volume) }
            }.value
            guard active === pane, pane.currentURL == origin else { return }
            switch result {
            case .success(let url): openTrash(at: url)
            case .failure(let error): alert = "Cannot open Trash on this disk: \(error.localizedDescription)"
            }
        }
    }
}
