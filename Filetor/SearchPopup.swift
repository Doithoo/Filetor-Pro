import SwiftUI

struct SearchPopup: View {
    let app: AppModel
    let pane: PaneModel
    @Environment(\.closePanel) private var dismiss
    @FocusState private var focused: Bool
    @State private var name: String
    @State private var criteria: SearchCriteria
    @State private var recursive: Bool
    @State private var minimum: String
    @State private var maximum: String
    @State private var error: String?

    init(app: AppModel, pane: PaneModel) {
        self.app = app; self.pane = pane
        _name = State(initialValue: pane.filter)
        _criteria = State(initialValue: pane.criteria)
        _recursive = State(initialValue: pane.searchSubfolders)
        _minimum = State(initialValue: pane.criteria.minBytes.map { String(Double($0) / 1_000_000) } ?? "")
        _maximum = State(initialValue: pane.criteria.maxBytes.map { String(Double($0) / 1_000_000) } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("Search")).font(.title2.bold())
            Text(pane.currentURL.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            TextField(L10n.tr("Name contains"), text: $name).textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { apply() }
            Form {
                Picker(L10n.tr("Scope"), selection: $recursive) {
                    Text(L10n.tr("This folder")).tag(false); Text(L10n.tr("Include subfolders")).tag(true)
                }
                Picker(L10n.tr("Kind"), selection: $criteria.kind) {
                    Text(L10n.tr("Any")).tag("")
                    ForEach(SearchGroup.all, id: \.key) { Text(L10n.key($0.title)).tag($0.key) }
                }
                TextField(L10n.tr("Extensions"), text: $criteria.extensions, prompt: Text(L10n.tr("pdf, jpg, txt")))
                Picker(L10n.tr("Modified"), selection: $criteria.days) {
                    Text(L10n.tr("Any time")).tag(0); Text(L10n.tr("Last 7 days")).tag(7)
                    Text(L10n.tr("Last 30 days")).tag(30); Text(L10n.tr("Last year")).tag(365)
                }
                TextField(L10n.tr("At least (MB)"), text: $minimum, prompt: Text(L10n.tr("Any size")))
                TextField(L10n.tr("At most (MB)"), text: $maximum, prompt: Text(L10n.tr("Any size")))
            }.formStyle(.grouped)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            Text(L10n.tr("Search by name, type, modification date or file size."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L10n.tr("Clear")) { name = ""; criteria = SearchCriteria(); minimum = ""; maximum = ""; error = nil }
                Spacer()
                Button(L10n.tr("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("Search")) { apply() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: min(540, max(340, (NSApp.keyWindow?.contentLayoutRect.width ?? 700) - 60)))
        .frame(height: min(560, max(390, (NSApp.keyWindow?.contentLayoutRect.height ?? 700) - 60)))
        .onAppear { focused = true }
        .onChange(of: app.active.id) { _, _ in if app.active !== pane { dismiss() } }
    }

    private func apply() {
        do {
            var result = criteria
            result.minBytes = try SearchCriteria.bytes(fromMB: minimum)
            result.maxBytes = try SearchCriteria.bytes(fromMB: maximum)
            if let minimum = result.minBytes, let maximum = result.maxBytes, minimum > maximum {
                throw FileOperationSafety.failure(L10n.tr("The minimum size must not exceed the maximum."))
            }
            pane.clearTag()
            pane.criteria = result
            pane.filter = name.trimmingCharacters(in: .whitespacesAndNewlines)
            pane.searchSubfolders = recursive
            pane.selection.removeAll()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
