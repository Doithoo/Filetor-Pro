import SwiftUI

/// Shared action availability and labels for AppKit and SwiftUI context menus.
enum ArchiveMenuAction: String, CaseIterable, Identifiable {
    case compress, extract
    var id: String { rawValue }
    var title: String {
        switch self {
        case .compress: return "Compress to ZIP"
        case .extract: return "Extract Archive"
        }
    }
    var help: String {
        switch self {
        case .compress: return "Create a ZIP in the current folder. Original files are kept."
        case .extract: return "Extract into a new folder here. Original archives and existing files are kept."
        }
    }
    static func available(for urls: Set<URL>) -> [Self] {
        guard !urls.isEmpty else { return [] }
        var actions: [Self] = [.compress]
        if urls.allSatisfy(FileTools.isArchive) { actions.append(.extract) }
        return actions
    }
    func perform(_ urls: Set<URL>, app: AppModel) {
        switch self {
        case .compress: app.compress(urls)
        case .extract: app.decompress(urls)
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
        let applications = app.openApps(for: urls)
        Menu("Open With") {
            ForEach(applications, id: \.self) { url in
                Button(FileManager.default.displayName(atPath: url.path)) { app.open(urls, with: url) }
            }
            if !applications.isEmpty { Divider() }
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
            if !result.failures.isEmpty { alert = result.failures.joined(separator: "\n") + (extracting ? "\nEncrypted or unsupported archives can be opened with another application using Open With." : "") }
            try? await Task.sleep(for: .seconds(1))
            transfers.jobs.removeAll { $0.id == job.id }
        }
    }
}
