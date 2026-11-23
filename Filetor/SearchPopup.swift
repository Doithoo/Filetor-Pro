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
            Text("Search").font(.title2.bold())
            Text(pane.currentURL.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            TextField("Name contains", text: $name).textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { apply() }
            Form {
                Picker("Scope", selection: $recursive) {
                    Text("This folder").tag(false); Text("Include subfolders").tag(true)
                }
                Picker("Kind", selection: $criteria.kind) {
                    Text("Any").tag("")
                    ForEach(SearchGroup.all, id: \.key) { Text($0.title).tag($0.key) }
                }
                TextField("Extensions", text: $criteria.extensions, prompt: Text("pdf, jpg, txt"))
                Picker("Modified", selection: $criteria.days) {
                    Text("Any time").tag(0); Text("Last 7 days").tag(7)
                    Text("Last 30 days").tag(30); Text("Last year").tag(365)
                }
                TextField("At least (MB)", text: $minimum, prompt: Text("Any size"))
                TextField("At most (MB)", text: $maximum, prompt: Text("Any size"))
            }.formStyle(.grouped)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            Text("Search by name, type, modification date or file size.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Clear") { name = ""; criteria = SearchCriteria(); minimum = ""; maximum = ""; error = nil }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Search") { apply() }.keyboardShortcut(.defaultAction)
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
                throw FileOperationSafety.failure("The minimum size must not exceed the maximum.")
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
