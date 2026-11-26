import SwiftUI

// MARK: - Model

nonisolated struct LargeFile: Identifiable, Sendable {
    let url: URL
    /// Folder that holds the file, relative to the scanned folder ("" for the folder itself).
    let folder: String
    let size: Int64
    let date: Date
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

struct LargeFiles {
    let id = UUID()
    let root: URL
    var files: [LargeFile] = []
    var scanning = true

    var total: Int64 { files.reduce(0) { $0 + $1.size } }
}

// MARK: - Scan (runs off the main thread)

nonisolated enum LargeFileScan {
    static let limit = 200

    /// The biggest files in the folder and all its subfolders, largest first.
    static func run(_ root: URL) -> [LargeFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let base = FileOperationSafety.RelativeRoot(root)
        var best: [LargeFile] = []
        for case let url as URL in en {
            if Task.isCancelled { return [] }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            guard let rel = base.relative(url.deletingLastPathComponent()) else { continue }
            best.append(LargeFile(url: url, folder: rel, size: Int64(v.fileSize ?? 0), date: v.contentModificationDate ?? .distantPast))
            // Keep the list short while scanning huge folders.
            if best.count > limit * 10 {
                best.sort { $0.size > $1.size }
                best.removeLast(best.count - limit)
            }
        }
        best.sort { $0.size > $1.size }
        return Array(best.prefix(limit))
    }
}

extension AppModel {
    func findLargeFiles() {
        let root = active.currentURL
        let initial = LargeFiles(root: root)
        largeFiles = initial
        let worker = Task.detached(priority: .userInitiated) { LargeFileScan.run(root) }
        largeFileWorker = worker
        Task { [weak self] in
            let result = await worker.value
            guard let self, self.largeFiles?.id == initial.id else { return }
            self.largeFiles?.files = result
            self.largeFiles?.scanning = false
            self.largeFileWorker = nil
        }
    }

    func trashFromLargeFiles(_ file: LargeFile) {
        guard let id = largeFiles?.id else { return }
        trash([file.url]) { [weak self] moved in
            guard let self, self.largeFiles?.id == id, moved.contains(file.url) else { return }
            self.largeFiles?.files.removeAll { $0.id == file.id }
        }
    }

    func showLargeFile(_ file: LargeFile) {
        active.navigate(to: file.url.deletingLastPathComponent())
        active.selection = [file.url]
    }
}

// MARK: - Panel

struct LargeFilesPanel: View {
    let app: AppModel
    @Environment(\.closePanel) private var close
    @AppStorage("textSize") private var textSize = 1
    @State private var sortKey: SortKey = .size
    @State private var ascending = false

    enum SortKey { case name, date, size }

    private var s: CGFloat { UIScale.value(textSize) }

    private var sorted: [LargeFile] {
        let list = app.largeFiles?.files ?? []
        let out: [LargeFile]
        switch sortKey {
        case .name: out = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .date: out = list.sorted { $0.date < $1.date }
        case .size: out = list.sorted { $0.size < $1.size }
        }
        return ascending ? out : out.reversed()
    }

    private var summary: String {
        guard let data = app.largeFiles else { return "" }
        let name = data.root.lastPathComponent.isEmpty ? "/" : data.root.lastPathComponent
        if data.scanning { return L10n.tr("Scanning \(name)…") }
        if data.files.isEmpty { return L10n.tr("No files found in \(name).") }
        let total = ByteCountFormatter.string(fromByteCount: data.total, countStyle: .file)
        return L10n.tr("The \(data.files.count) largest files in \(name), \(total) together.")
    }

    private func pick(_ key: SortKey) {
        if sortKey == key { ascending.toggle() } else { sortKey = key; ascending = key == .name }
    }

    private func headerLabel(_ title: String, _ key: SortKey, trailing: Bool = false) -> some View {
        Button { pick(key) } label: {
            HStack(spacing: 3) {
                Text(title)
                if sortKey == key {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.system(size: 9 * s, weight: .semibold))
                }
            }
            .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(sortKey == key ? Color.primary : Color.secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("Large Files")).font(.system(size: 22 * s))
            Text(summary).foregroundStyle(.secondary)
            if let data = app.largeFiles, !data.files.isEmpty {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        headerLabel(L10n.tr("Name"), .name)
                        headerLabel(L10n.tr("Date Modified"), .date).frame(width: 120 * s)
                        headerLabel(L10n.tr("Size"), .size, trailing: true).frame(width: 76 * s)
                        Color.clear.frame(width: 62 * s, height: 1)
                    }
                    .font(.system(size: 12 * s, weight: .semibold))
                    .padding(.bottom, 6)
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(sorted) { file in
                                LargeFileRow(app: app, file: file, scale: s) { close() }
                                Divider().opacity(0.5)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: 360 * s)
                }
            }
            HStack {
                Spacer()
                Button(L10n.tr("Done")) { close() }
                    .buttonStyle(PathsButtonStyle(scale: s, prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .background { Button("") { close() }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0) }
            }
        }
        .font(.system(size: 13 * s))
        .padding(28)
        .frame(width: 640 * s)
    }
}

private struct LargeFileRow: View {
    let app: AppModel
    let file: LargeFile
    let scale: CGFloat
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).lineLimit(1).truncationMode(.middle)
                Text((file.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11.5 * scale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(file.date.formatted(date: .abbreviated, time: .omitted))
                .foregroundStyle(.secondary)
                .frame(width: 120 * scale, alignment: .leading)
            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                .frame(width: 76 * scale, alignment: .trailing)
            HStack(spacing: 6) {
                RowIconButton(symbol: "magnifyingglass", size: 13.5, help: L10n.tr("Show in Folder"), danger: false, scale: scale) {
                    app.showLargeFile(file)
                    close()
                }
                RowIconButton(symbol: "trash", size: 10.5, help: L10n.tr("Move to Trash"), danger: true, scale: scale) {
                    app.trashFromLargeFiles(file)
                }
            }
            .frame(width: 62 * scale)
        }
        .font(.system(size: 12.5 * scale))
        .padding(.vertical, 6)
    }
}

private struct RowIconButton: View {
    let symbol: String
    let size: CGFloat
    let help: String
    let danger: Bool
    let scale: CGFloat
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * scale))
                .foregroundStyle(hover ? (danger ? Color.red : Color.filetor) : Color.secondary)
                .frame(width: 28 * scale, height: 26 * scale)
                .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.primary.opacity(0.08) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
    }
}
