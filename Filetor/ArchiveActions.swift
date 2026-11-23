import SwiftUI

/// Keka's public Services entry points, independent of its Finder extension.
enum KekaIntegration {
    enum Action: String { case compress, extract
        var title: String { self == .compress ? "Compress using Keka" : "Extract using Keka" }
        var message: String { self == .compress ? "serviceCompress" : "serviceExtract" }
    }
    struct Installation {
        let url: URL
        let services: [String: String]
        let extensions: Set<String>

        init?(url: URL) {
            guard let bundle = Bundle(url: url), bundle.bundleIdentifier == "com.aone.keka" else { return nil }
            self.url = url
            var services: [String: String] = [:]
            for service in bundle.object(forInfoDictionaryKey: "NSServices") as? [[String: Any]] ?? [] {
                if let message = service["NSMessage"] as? String,
                   let names = service["NSMenuItem"] as? [String: String], let name = names["default"],
                   (service["NSSendTypes"] as? [String])?.contains("NSFilenamesPboardType") == true {
                    services[message] = name
                }
            }
            self.services = services
            let types = bundle.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] ?? []
            self.extensions = Set(types.flatMap { $0["CFBundleTypeExtensions"] as? [String] ?? [] }.map { $0.lowercased() }).subtracting(["*"])
        }

        func accepts(_ urls: Set<URL>, action: Action) -> Bool {
            guard !urls.isEmpty, services[action.message] != nil else { return false }
            return action == .compress || urls.allSatisfy {
                extensions.contains($0.pathExtension.lowercased()) && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
        }
    }

    static var installed: Installation? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.aone.keka").flatMap(Installation.init)
    }

    static func send(_ urls: Set<URL>, action: Action,
                     installation: Installation? = installed,
                     perform: (String, NSPasteboard) -> Bool = { NSPerformService($0, $1) }) -> String? {
        guard let installation, installation.accepts(urls, action: action),
              let service = installation.services[action.message] else {
            return "Keka is not available for this selection. Use Open With to choose another application."
        }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        // Keka declares the legacy filenames type, not public.file-url. Do not use the user's clipboard.
        let type = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        pasteboard.declareTypes([type], owner: nil)
        pasteboard.setPropertyList(FileOperationSafety.topLevel(Array(urls)).map(\.path), forType: type)
        guard perform(service, pasteboard) else {
            return "Could not send the selection to Keka. Open Keka once and enable its Services in System Settings → Keyboard → Keyboard Shortcuts → Services, then try again."
        }
        return nil
    }
}

/// Shared action availability and labels for AppKit and SwiftUI context menus.
enum ArchiveMenuAction: String, CaseIterable, Identifiable {
    case compress, extract, kekaCompress, kekaExtract
    var id: String { rawValue }
    var title: String {
        switch self {
        case .compress: return "Compress to ZIP"
        case .extract: return "Extract Archive"
        case .kekaCompress: return "Compress using Keka"
        case .kekaExtract: return "Extract using Keka"
        }
    }
    var help: String {
        switch self {
        case .kekaCompress, .kekaExtract: return "Uses Keka’s format, output location and source-deletion settings."
        case .compress: return "Create a ZIP in the current folder. Original files are kept."
        case .extract: return "Extract into a new folder here. Original archives and existing files are kept."
        }
    }
    static func available(for urls: Set<URL>, keka: KekaIntegration.Installation? = KekaIntegration.installed) -> [Self] {
        guard !urls.isEmpty else { return [] }
        var actions: [Self] = [.compress]
        if urls.allSatisfy(FileTools.isArchive) { actions.append(.extract) }
        if keka?.accepts(urls, action: .compress) == true { actions.append(.kekaCompress) }
        if keka?.accepts(urls, action: .extract) == true { actions.append(.kekaExtract) }
        return actions
    }
    func perform(_ urls: Set<URL>, app: AppModel) {
        switch self {
        case .compress: app.compress(urls)
        case .extract: app.decompress(urls)
        case .kekaCompress, .kekaExtract:
            if let error = KekaIntegration.send(urls, action: self == .kekaCompress ? .compress : .extract) { app.alert = error }
        }
    }
}

struct ArchiveContextActions: View {
    let urls: Set<URL>
    let app: AppModel
    let pane: PaneModel
    var body: some View {
        ForEach(ArchiveMenuAction.available(for: urls)) { action in
            Button(action.title) { app.activate(pane); action.perform(urls, app: app) }.help(action.help)
        }
    }
}

struct OpenWithContextMenu: View {
    let urls: Set<URL>
    let app: AppModel
    var body: some View {
        Menu("Open With") {
            ForEach(app.openApps(for: urls), id: \.self) { url in
                Button(FileManager.default.displayName(atPath: url.path)) { app.open(urls, with: url) }
            }
            Divider()
            Button("Other…") { app.chooseApplication(for: urls) }
        }
    }
}

extension AppModel {
    func chooseApplication(for urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Open"
        panel.message = "Choose an application to open the selected files."
        guard panel.runModal() == .OK, let application = panel.url else { return }
        open(urls, with: application)
    }

    func startArchiveOperation(_ urls: Set<URL>, extracting: Bool) {
        guard !urls.isEmpty else { return }
        let pane = active
        let directory = pane.currentURL
        let list = urls.sorted { $0.path < $1.path }
        let job = TransferJob(title: extracting ? "Extracting \(list.count) archive(s)" : "Compressing to ZIP")
        job.indeterminate = true
        transfers.jobs.append(job)
        Task {
            job.currentName = "Waiting for other file operations…"
            let acquired = await TransferScheduler.shared.acquire(job.id)
            guard acquired, !job.control.cancelled else {
                if acquired { TransferScheduler.shared.release(job.id) }
                transfers.jobs.removeAll { $0.id == job.id }
                return
            }
            let poller = Task {
                while !Task.isCancelled {
                    job.currentName = job.control.snapshot.name
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            let result = await Task.detached(priority: .userInitiated) {
                extracting ? ArchiveOperations.extract(list, in: directory, control: job.control)
                           : ArchiveOperations.compress(list, in: directory, control: job.control)
            }.value
            poller.cancel()
            TransferScheduler.shared.release(job.id)
            job.indeterminate = false
            job.fraction = 1
            job.isFinished = true
            job.currentName = result.cancelled ? "Cancelled; completed results were kept" : (result.failures.isEmpty ? "Completed" : "Completed with errors")
            pane.reloadKeepingSelection()
            if !result.failures.isEmpty { alert = result.failures.joined(separator: "\n") + (extracting ? "\nEncrypted or unsupported archives can be opened with Keka or another archive application." : "") }
            try? await Task.sleep(for: .seconds(1))
            transfers.jobs.removeAll { $0.id == job.id }
        }
    }
}
