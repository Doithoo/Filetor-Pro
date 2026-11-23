import Foundation
import Darwin
import SwiftUI

/// Capture only the items shown in the confirmation, including hidden items.
/// Never remove the Trash directory itself or follow a top-level symbolic link.
nonisolated struct TrashDeletion {
    nonisolated struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        nonisolated init(_ url: URL) throws {
            var value = stat()
            guard lstat(url.path, &value) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            device = value.st_dev; inode = value.st_ino; mode = value.st_mode
        }
        nonisolated var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
    }
    struct Item {
        let url: URL
        let identity: Identity
    }
    let root: URL
    let rootIdentity: Identity
    let items: [Item]
    let emptying: Bool
    let diskName: String

    nonisolated static func capture(root: URL, selection: Set<URL>? = nil) throws -> TrashDeletion {
        guard TrashLocation.isRoot(root) else {
            throw FileOperationSafety.failure("This location is not a supported Trash folder.")
        }
        return try snapshot(root: root, selection: selection)
    }

    /// Internal engine accepts a fixture root so tests never touch real Trash.
    nonisolated static func snapshot(root: URL, selection: Set<URL>? = nil) throws -> TrashDeletion {
        let root = root.standardizedFileURL
        let identity = try Identity(root)
        guard identity.isDirectory, root.resolvingSymlinksInPath().path == root.path else {
            throw FileOperationSafety.failure("Trash was redirected. Nothing was deleted.")
        }
        let urls = try selection.map { FileOperationSafety.topLevel(Array($0)) }
            ?? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let items = try urls.sorted { $0.path < $1.path }.map { url -> Item in
            let url = url.standardizedFileURL
            guard url.path != root.path, url.path.hasPrefix(root.path + "/"),
                  url.deletingLastPathComponent().resolvingSymlinksInPath().path == url.deletingLastPathComponent().path else {
                throw FileOperationSafety.failure("The selection is outside Trash or passes through a symbolic link.")
            }
            return Item(url: url, identity: try Identity(url))
        }
        let disk = (try? root.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? root.path
        return TrashDeletion(root: root, rootIdentity: identity, items: items, emptying: selection == nil, diskName: disk)
    }

    nonisolated func remove(_ item: Item) throws {
        guard try Identity(root) == rootIdentity,
              root.resolvingSymlinksInPath().path == root.path,
              item.url.path != root.path, item.url.path.hasPrefix(root.path + "/"),
              item.url.deletingLastPathComponent().resolvingSymlinksInPath().path == item.url.deletingLastPathComponent().path,
              try Identity(item.url) == item.identity else {
            throw FileOperationSafety.failure("The item or Trash folder changed after confirmation; skipped.")
        }
        try FileManager.default.removeItem(at: item.url)
    }

    var title: String { emptying ? "Empty Trash on “\(diskName)”?" : "Delete Selected Items Immediately?" }
    var message: String {
        let scope = emptying
            ? "All \(items.count) top-level items in this disk’s Trash, including hidden items and folder contents, will be permanently deleted. This ignores the current filter and selection. Other disks are not included."
            : "The \(items.count) selected items and their folder contents will be permanently deleted from Trash on “\(diskName)”."
        return scope + "\n\nYou cannot undo this. Items added at the top level after this confirmation was prepared are not included.\n\n" + root.path
    }
}

extension AppModel {
    func requestTrashDeletion(root: URL, selection: Set<URL>? = nil) {
        guard !preparingTrashDeletion, trashDeletionJob == nil, pendingTrashDeletion == nil else { return }
        preparingTrashDeletion = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try TrashDeletion.capture(root: root, selection: selection) }
            }.value
            preparingTrashDeletion = false
            switch result {
            case .success(let snapshot):
                if snapshot.items.isEmpty { alert = "Trash on this disk is already empty." }
                else { pendingTrashDeletion = snapshot }
            case .failure(let error): alert = "Cannot prepare Trash deletion: \(error.localizedDescription)"
            }
        }
    }

    func confirmTrashDeletion() {
        guard let snapshot = pendingTrashDeletion else { return }
        pendingTrashDeletion = nil
        let job = TransferJob(title: snapshot.emptying ? "Emptying Trash on \(snapshot.diskName)" : "Deleting selected Trash items")
        trashDeletionJob = job
        transfers.jobs.append(job)
        Task {
            job.currentName = "Waiting for other file operations…"
            let acquired = await TransferScheduler.shared.acquire(job.id)
            var failures: [String] = []
            var deleted = 0
            if acquired {
                for (index, item) in snapshot.items.enumerated() {
                    if job.control.cancelled { break }
                    job.currentName = item.url.lastPathComponent
                    let result = await Task.detached(priority: .userInitiated) {
                        Result { try snapshot.remove(item) }
                    }.value
                    switch result {
                    case .success: deleted += 1
                    case .failure(let error): failures.append("\(item.url.lastPathComponent): \(error.localizedDescription)")
                    }
                    job.fraction = Double(index + 1) / Double(snapshot.items.count)
                }
                TransferScheduler.shared.release(job.id)
            }
            job.isFinished = true
            job.currentName = job.control.cancelled ? "Stopped" : (failures.isEmpty ? "Completed" : "Completed with errors")
            trashDeletionJob = nil
            refresh()
            if !failures.isEmpty || job.control.cancelled {
                alert = "Deleted \(deleted) of \(snapshot.items.count) top-level items. "
                    + (job.control.cancelled ? "Stopped; completed deletions cannot be undone.\n" : "Some items could not be fully deleted.\n")
                    + failures.joined(separator: "\n")
            }
            try? await Task.sleep(for: .seconds(1))
            transfers.jobs.removeAll { $0.id == job.id }
        }
    }
}

struct EmptyTrashButton: View {
    let root: URL
    let app: AppModel
    var revision: Int = 0
    @State private var hasItems = false
    var body: some View {
        Button("Empty Trash…") { app.requestTrashDeletion(root: root) }
            .disabled(!hasItems || app.preparingTrashDeletion || app.trashDeletionJob != nil)
            .help("Permanently delete everything in this disk’s Trash, regardless of the filter or selection")
            .task(id: "\(root.path):\(revision)") {
                let value = await Task.detached(priority: .utility) {
                    guard TrashLocation.isRoot(root) else { return false }
                    return (try? FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty == false) ?? false
                }.value
                if !Task.isCancelled { hasItems = value }
            }
    }
}
