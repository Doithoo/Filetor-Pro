import Foundation

/// Reads only one level, with bounded memory and shared background concurrency.
nonisolated enum FolderPreviewReader {
    struct Listing: Sendable {
        let items: [FileItem]
        let truncated: Bool
    }

    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Filetor folder previews"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    static func read(_ url: URL, showHidden: Bool, limit: Int,
                     cancelled: () -> Bool = { false }) throws -> Listing {
        guard !cancelled() else { throw CancellationError() }
        guard FileItem(url: URL(fileURLWithPath: url.path)).expandable else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnsupportedSchemeError,
                          userInfo: [NSLocalizedDescriptionKey: L10n.tr("This folder is no longer available. Refresh to try again.")])
        }
        var failure: Error?
        var options: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants, .skipsPackageDescendants]
        if !showHidden { options.insert(.skipsHiddenFiles) }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: FileItem.keys,
                options: options, errorHandler: { _, error in failure = error; return false }) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                          userInfo: [NSLocalizedDescriptionKey: L10n.tr("Could not read this folder. Check access permissions and disk availability.")])
        }
        var items: [FileItem] = []
        var truncated = false
        while let child = enumerator.nextObject() as? URL {
            guard !cancelled() else { throw CancellationError() }
            if items.count >= limit { truncated = true; break }
            items.append(FileItem(url: child))
        }
        if let failure { throw failure }
        guard !cancelled() else { throw CancellationError() }
        items.sort {
            if $0.expandable != $1.expandable { return $0.expandable }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return Listing(items: items, truncated: truncated)
    }

    static func start(_ url: URL, showHidden: Bool, limit: Int,
                      completion: @escaping @MainActor @Sendable (Result<Listing, Error>) -> Void) -> Operation {
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak operation] in
            guard let operation, !operation.isCancelled else { return }
            let result = Result { try read(url, showHidden: showHidden, limit: limit, cancelled: { operation.isCancelled }) }
            guard !operation.isCancelled else { return }
            Task { @MainActor in completion(result) }
        }
        queue.addOperation(operation)
        return operation
    }
}

final class FolderPreviewNode: NSObject {
    let item: FileItem?
    let message: String?
    var children: [FolderPreviewNode] = []
    var loaded = false
    var loading = false
    var truncated = false
    var error: String?

    init(item: FileItem) { self.item = item; self.message = nil }
    init(message: String) { self.item = nil; self.message = message }
}

/// Owns only the currently previewed tree; closing or changing items cancels reads.
final class FolderPreviewModel {
    static let perFolderLimit = 3_000
    static let totalLimit = 10_000
    private(set) var root: FolderPreviewNode?
    private(set) var showHidden = false
    private var generation = UUID()
    private var operations: [URL: Operation] = [:]
    private var reserved = 0
    private var loadedCount = 0
    var changed: ((FolderPreviewNode?) -> Void)?

    func show(_ url: URL, showHidden: Bool) {
        stop()
        self.showHidden = showHidden
        let node = FolderPreviewNode(item: FileItem(url: url))
        root = node
        load(node)
    }

    func stop() {
        generation = UUID()
        operations.values.forEach { $0.cancel() }
        operations.removeAll()
        reserved = 0
        loadedCount = 0
        root = nil
        changed?(nil)
    }

    func load(_ node: FolderPreviewNode) {
        guard !node.loaded, !node.loading, let item = node.item, node === root || item.expandable else { return }
        let limit = min(Self.perFolderLimit, Self.totalLimit - loadedCount - reserved)
        guard limit > 0 else {
            node.children = [.init(message: L10n.tr("Preview limit reached. Refresh or open this folder to see more."))]
            changed?(node === root ? nil : node)
            return
        }
        node.loading = true
        node.children = [.init(message: L10n.tr("Loading…"))]
        reserved += limit
        let generation = generation
        operations[item.url] = FolderPreviewReader.start(item.url, showHidden: showHidden, limit: limit) { [weak self, weak node] result in
            guard let self, let node, self.generation == generation else { return }
            self.operations.removeValue(forKey: item.url)
            self.reserved -= limit
            node.loading = false
            node.loaded = true
            switch result {
            case .success(let listing):
                node.truncated = listing.truncated
                self.loadedCount += listing.items.count
                node.children = listing.items.map { FolderPreviewNode(item: $0) }
                if listing.truncated {
                    node.children.append(.init(message: L10n.tr("Showing a limited preview (\(listing.items.count) items). Open the folder to see all items.")))
                } else if listing.items.isEmpty {
                    node.children = [.init(message: self.showHidden ? L10n.tr("This folder is empty.") : L10n.tr("No visible items. Hidden items may be present."))]
                }
            case .failure(let error):
                node.error = error.localizedDescription
                node.children = [.init(message: L10n.tr("Could not read folder: \(error.localizedDescription) Refresh to retry."))]
            }
            self.changed?(node === self.root ? nil : node)
        }
        changed?(node === root ? nil : node)
    }
}
