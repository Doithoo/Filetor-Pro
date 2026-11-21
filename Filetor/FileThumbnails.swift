import AppKit
import SwiftUI
import QuickLookThumbnailing

/// A shared, bounded queue. Cancelling a view also cancels its last outstanding request.
final class FileThumbnails {
    static let shared = FileThumbnails()
    static let maximumConcurrent = 4
    private let cache = NSCache<NSString, NSImage>()
    private final class Work {
        let request: QLThumbnailGenerator.Request
        var callbacks: [UUID: (NSImage?) -> Void] = [:]
        var running = false
        init(_ request: QLThumbnailGenerator.Request) { self.request = request }
    }
    private var work: [String: Work] = [:]
    private var queue: [String] = []
    private var tokens: [UUID: String] = [:]
    private(set) var activeCount = 0
    var pendingCount: Int { work.count }

    init() {
        cache.countLimit = 256
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    static func key(_ item: FileItem, side: CGFloat, scale: CGFloat) -> String {
        "\(item.url.path)|\(item.modified.timeIntervalSince1970)|\(item.size)|\(Int(ceil(side / 16) * 16))|\(scale)"
    }

    @discardableResult
    func request(_ item: FileItem, side: CGFloat, scale: CGFloat, completion: @escaping (NSImage?) -> Void) -> UUID {
        let token = UUID()
        guard !item.isDirectory else { completion(nil); return token }
        let key = Self.key(item, side: side, scale: scale)
        if let image = cache.object(forKey: key as NSString) { completion(image); return token }
        let job: Work
        if let existing = work[key] { job = existing }
        else {
            let step = ceil(side / 16) * 16
            job = Work(.init(fileAt: item.url, size: CGSize(width: step, height: step), scale: scale, representationTypes: .thumbnail))
            work[key] = job
            queue.append(key)
        }
        job.callbacks[token] = completion
        tokens[token] = key
        pump()
        return token
    }

    func cancel(_ token: UUID?) {
        guard let token, let key = tokens.removeValue(forKey: token), let job = work[key] else { return }
        job.callbacks.removeValue(forKey: token)
        guard job.callbacks.isEmpty else { return }
        work.removeValue(forKey: key)
        queue.removeAll { $0 == key }
        if job.running {
            activeCount -= 1
            QLThumbnailGenerator.shared.cancel(job.request)
        }
        pump()
    }

    private func pump() {
        while activeCount < Self.maximumConcurrent, !queue.isEmpty {
            let key = queue.removeFirst()
            guard let job = work[key] else { continue }
            job.running = true
            activeCount += 1
            QLThumbnailGenerator.shared.generateBestRepresentation(for: job.request) { [weak self, weak job] representation, _ in
                Task { @MainActor in
                    guard let self, let job, self.work[key] === job else { return }
                    let image = representation?.nsImage
                    if let image {
                        let pixels = job.request.size.width * job.request.size.height * job.request.scale * job.request.scale
                        self.cache.setObject(image, forKey: key as NSString, cost: Int(pixels * 4))
                    }
                    self.work.removeValue(forKey: key)
                    self.activeCount -= 1
                    let callbacks = job.callbacks
                    for token in callbacks.keys { self.tokens.removeValue(forKey: token) }
                    for callback in callbacks.values { callback(image) }
                    self.pump()
                }
            }
        }
    }
}

final class FileThumbnailView: NSImageView {
    private var token: UUID?
    private var item: FileItem?
    private var side: CGFloat = 17
    private var previews = false

    func configure(_ item: FileItem, side: CGFloat, previews: Bool) {
        guard self.item != item || self.side != side || self.previews != previews else { return }
        FileThumbnails.shared.cancel(token)
        token = nil
        self.item = item
        self.side = side
        self.previews = previews
        imageScaling = .scaleProportionallyUpOrDown
        image = NSWorkspace.shared.icon(forFile: item.url.path)
        if window != nil { start() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        FileThumbnails.shared.cancel(token)
        token = nil
        if window != nil { start() }
    }

    func stop() { FileThumbnails.shared.cancel(token); token = nil }

    private func start() {
        guard previews, let item, !item.isDirectory else { return }
        token = FileThumbnails.shared.request(item, side: side, scale: window?.backingScaleFactor ?? 2) { [weak self] image in
            if let image { self?.image = image }
        }
    }
}

struct FileIcon: NSViewRepresentable {
    let item: FileItem
    let side: CGFloat
    let previews: Bool

    func makeNSView(context: Context) -> FileThumbnailView { FileThumbnailView() }
    func updateNSView(_ view: FileThumbnailView, context: Context) {
        view.configure(item, side: side, previews: previews)
    }
    static func dismantleNSView(_ view: FileThumbnailView, coordinator: ()) { view.stop() }
}
