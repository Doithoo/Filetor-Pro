import SwiftUI

struct GoToFolderPopup: View {
    let app: AppModel
    let pane: PaneModel
    @Environment(\.closePanel) private var dismiss
    @State private var model: PathCompletion
    @State private var selected: Int? = nil
    @State private var error: String?
    @State private var opening = false
    @State private var navigation: Task<Void, Never>?
    @FocusState private var focused: Bool

    init(app: AppModel, pane: PaneModel) {
        self.app = app; self.pane = pane
        _model = State(initialValue: PathCompletion(base: pane.currentURL))
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Text("Go to Folder").font(.title2.bold())
            TextField("Type or paste a path", text: $model.text)
                .textFieldStyle(.roundedBorder).focused($focused).disabled(opening)
                .onSubmit { submit() }
                .onKeyPress(.downArrow) { select(1); return .handled }
                .onKeyPress(.upArrow) { select(-1); return .handled }
                .onKeyPress(.tab) { complete(); return .handled }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.candidates.enumerated()), id: \.element.id) { index, entry in
                        Button { open(entry.url) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: entry.directory ? "folder" : "doc").frame(width: 20)
                                Text(entry.url.lastPathComponent).lineLimit(1)
                                Spacer()
                                Text(entry.directory ? "Folder" : "File").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(9)
                            .contentShape(Rectangle())
                            .background(selected == index ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain).disabled(opening)
                    }
                }
            }
            .frame(minHeight: 100, maxHeight: .infinity)
            if model.loading || opening { ProgressView(opening ? "Opening…" : "Reading folder…").controlSize(.small) }
            if let message = error ?? model.error { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            Text("↑ ↓ select · Tab completes · Return opens · Esc closes")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Go") { submit() }.keyboardShortcut(.defaultAction).disabled(opening)
            }
        }
        .padding(20)
        .frame(width: min(560, max(340, (NSApp.keyWindow?.contentLayoutRect.width ?? 700) - 60)),
               height: min(490, max(300, (NSApp.keyWindow?.contentLayoutRect.height ?? 650) - 60)))
        .onAppear { focused = true; model.update() }
        .onChange(of: model.text) { _, _ in selected = nil; error = nil; model.update() }
        .onChange(of: app.active.id) { _, _ in dismiss() }
        .onDisappear { model.stop(); navigation?.cancel() }
    }

    private func select(_ direction: Int) {
        guard !model.candidates.isEmpty else { return }
        selected = min(max((selected ?? (direction > 0 ? -1 : model.candidates.count)) + direction, 0), model.candidates.count - 1)
    }

    private func complete() {
        let index = selected ?? 0
        guard model.candidates.indices.contains(index) else { return }
        let entry = model.candidates[index]
        model.text = (entry.url.path as NSString).abbreviatingWithTildeInPath + (entry.directory ? "/" : "")
    }

    private func submit() {
        if let selected, model.candidates.indices.contains(selected) { open(model.candidates[selected].url); return }
        do { open(try PathCompletion.url(for: model.text, base: pane.currentURL)) }
        catch { self.error = error.localizedDescription }
    }

    private func open(_ url: URL) {
        guard !opening else { return }
        opening = true; error = nil
        navigation = Task {
            let worker = Task.detached(priority: .userInitiated) { try PathCompletion.destination(url) }
            let result = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
            guard !Task.isCancelled, app.active === pane else { return }
            opening = false
            switch result {
            case .success(let destination):
                pane.clearSearch()
                pane.clearTag()
                if destination.directory { pane.navigate(to: destination.url) }
                else { pane.navigateSelecting(destination.url) }
                dismiss()
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}
