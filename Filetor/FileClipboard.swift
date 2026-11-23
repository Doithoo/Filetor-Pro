import AppKit
import Observation

/// File URLs stay interoperable with other apps. Move intent belongs only to
/// this process and this exact pasteboard generation, never to an external flag.
@Observable
final class FileClipboard {
    static let shared = FileClipboard()
    let pasteboard: NSPasteboard
    private var cutGeneration: Int?
    private var movingGeneration: Int?
    private var observedGeneration: Int
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        observedGeneration = pasteboard.changeCount
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.observedGeneration = self.pasteboard.changeCount
            }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    var urls: [URL] {
        let _ = observedGeneration
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter(\.isFileURL)
    }
    var isCut: Bool { cutGeneration == pasteboard.changeCount }
    var canPaste: Bool { !urls.isEmpty && movingGeneration != pasteboard.changeCount }

    func write(_ selection: Set<URL>, cut: Bool = false) {
        let files = FileOperationSafety.topLevel(Array(selection).filter(\.isFileURL))
        guard !files.isEmpty else { return }
        pasteboard.clearContents()
        let written = pasteboard.writeObjects(files as [NSURL])
        observedGeneration = pasteboard.changeCount
        cutGeneration = cut && written ? pasteboard.changeCount : nil
    }

    func paste(into directory: URL, app: AppModel) {
        guard canPaste, FileCreation.canCreate(in: directory) else { return }
        let move = isCut
        let generation = pasteboard.changeCount
        let sources = FileOperationSafety.topLevel(urls)
        // Moving back into the same parent is a no-op, including directory aliases.
        let items = sources.filter {
            !move || !FileOperationSafety.sameItem($0.deletingLastPathComponent(), directory)
        }.map { (src: $0, dstDir: directory) }
        guard !items.isEmpty else { return }
        if move { movingGeneration = generation }
        app.transfers.start(items: items, move: move) { [self] records in
            guard move else { return }
            if movingGeneration == generation { movingGeneration = nil }
            // A later Copy/Cut (even from another app) must survive this completion.
            guard pasteboard.changeCount == generation, cutGeneration == generation else { return }
            let moved = Set(records.filter(\.moved).map(\.src))
            let remaining = sources.filter { !moved.contains($0) && FileOperationSafety.exists($0) }
            if remaining.isEmpty {
                pasteboard.clearContents()
                observedGeneration = pasteboard.changeCount
                cutGeneration = nil
            } else if remaining != sources {
                write(Set(remaining), cut: true)
            }
        }
    }
}
