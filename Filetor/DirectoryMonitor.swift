import Foundation
import CoreServices

/// One recursive event stream per visible root, shared by windows showing the same folder.
@MainActor
final class DirectoryMonitor {
    static let shared = DirectoryMonitor()
    private var streams: [String: Stream] = [:]

    func observe(_ url: URL, changed: @escaping ([String]) -> Void) -> UUID {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let id = UUID()
        let stream = streams[path] ?? Stream(path: path)
        streams[path] = stream
        stream.listeners[id] = changed
        return id
    }

    func remove(_ id: UUID) {
        for (path, stream) in streams where stream.listeners.removeValue(forKey: id) != nil {
            if stream.listeners.isEmpty { stream.stop(); streams[path] = nil }
            break
        }
    }

    private final class Stream {
        var listeners: [UUID: ([String]) -> Void] = [:]
        private var stream: FSEventStreamRef?
        private var pending: Task<Void, Never>?
        private var retry: Task<Void, Never>?
        private var changedPaths = Set<String>()
        private var needsFullRefresh = false

        init(path: String) {
            guard !start(path: path) else { return }
            // Some volumes cannot start a recursive event stream. Reconcile only
            // these visible roots and retry so a transient failure heals itself.
            retry = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(4)) } catch { return }
                    guard let self else { return }
                    let started = self.start(path: path)
                    self.changed(paths: [], full: true)
                    if started { return }
                }
            }
        }

        private func start(path: String) -> Bool {
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            stream = FSEventStreamCreate(nil, { _, info, count, eventPaths, flags, _ in
                guard let info else { return }
                let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
                let full = (0..<count).contains { flags[$0] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 }
                MainActor.assumeIsolated {
                    Unmanaged<Stream>.fromOpaque(info).takeUnretainedValue().changed(paths: paths, full: full)
                }
            }, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes))
            guard let stream else { return false }
            FSEventStreamSetDispatchQueue(stream, .main)
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
                return false
            }
            return true
        }

        func changed(paths: [String], full: Bool) {
            changedPaths.formUnion(paths)
            needsFullRefresh = needsFullRefresh || full
            guard pending == nil else { return }
            pending = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard let self else { return }
                let paths = self.needsFullRefresh ? [] : Array(self.changedPaths)
                self.changedPaths.removeAll()
                self.needsFullRefresh = false
                self.pending = nil
                Array(self.listeners.values).forEach { $0(paths) }
            }
        }

        func stop() {
            retry?.cancel()
            pending?.cancel()
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            stream = nil
        }
    }
}
