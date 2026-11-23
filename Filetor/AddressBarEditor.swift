import SwiftUI
import AppKit

/// The editor belongs to one pane. Typing and completion never change its location.
struct AddressBarEditor: View {
    let pane: PaneModel
    let app: AppModel
    let scale: CGFloat
    let close: () -> Void
    @State private var model: PathCompletion
    @State private var action = FolderNavigationAction()
    @State private var selected: Int?
    @State private var pathError: String?

    init(pane: PaneModel, app: AppModel, scale: CGFloat, close: @escaping () -> Void) {
        self.pane = pane; self.app = app; self.scale = scale; self.close = close
        let model = PathCompletion(base: pane.currentURL)
        model.text = pane.currentURL.path + (pane.currentURL.path == "/" ? "" : "/")
        _model = State(initialValue: model)
    }

    private func edit(_ text: String) {
        action.stop(); pathError = nil; selected = nil
        model.text = text
        model.update(showHidden: pane.showHidden)
    }

    private func open(_ url: URL) {
        action.open(url, app: app, pane: pane, completion: close)
    }

    private func submit() {
        if let selected, model.candidates.indices.contains(selected) {
            open(model.candidates[selected].url)
        } else {
            do { open(try PathCompletion.url(for: model.text, base: model.base)) }
            catch { pathError = error.localizedDescription }
        }
    }

    private func move(_ delta: Int) {
        guard !model.candidates.isEmpty else { return }
        selected = min(model.candidates.count - 1, max(0, (selected ?? (delta > 0 ? -1 : model.candidates.count)) + delta))
    }

    private func complete() {
        let index = selected ?? 0
        guard model.candidates.indices.contains(index) else { return }
        let candidate = model.candidates[index]
        edit(candidate.url.path + (candidate.directory && candidate.url.path != "/" ? "/" : ""))
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            AddressTextField(text: model.text, scale: scale, edit: edit, submit: submit,
                             cancel: close, move: move, complete: complete, endEditing: {
                if !action.opening { close() }
            })
            .frame(minWidth: 20)
            Button(action: close) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless).help("Cancel path editing").accessibilityLabel("Cancel path editing")
        }
        .padding(.horizontal, 8)
        .frame(height: 30 * scale)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            suggestions.offset(y: 34 * scale)
        }
        .padding(.horizontal, 10 * scale)
        .onAppear { model.update(showHidden: pane.showHidden) }
        .onChange(of: pane.showHidden) { _, _ in selected = nil; model.update(showHidden: pane.showHidden) }
        .onDisappear { model.stop(); action.stop() }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = pathError ?? action.error ?? model.error {
                Text(error).foregroundStyle(.secondary).padding(10)
            } else if model.loading || action.opening {
                HStack { ProgressView().controlSize(.small); Text(action.opening ? "Opening…" : "Finding matches…") }
                    .foregroundStyle(.secondary).padding(10)
            } else if model.candidates.isEmpty {
                Text("No matching files or folders").foregroundStyle(.secondary).padding(10)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(model.candidates.enumerated()), id: \.element.id) { index, candidate in
                                Button { open(candidate.url) } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: candidate.directory ? "folder" : "doc")
                                            .foregroundStyle(selected == index ? Color.white : Color.secondary)
                                        Text(candidate.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: 0)
                                        if selected == index { Image(systemName: "return").font(.caption) }
                                    }
                                    .padding(.horizontal, 8).frame(height: 28 * scale)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(selected == index ? Color.white : Color.primary)
                                .background(selected == index ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                                .id(index)
                            }
                        }.padding(4)
                    }
                    .frame(height: min(CGFloat(model.candidates.count) * (28 * scale + 2) + 8, 248 * scale))
                    .onChange(of: selected) { _, index in if let index { proxy.scrollTo(index) } }
                }
            }
        }
        .font(.system(size: 13 * scale))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
    }
}

/// AppKit keeps standard selection/copy/paste and lets the input method handle
/// marked text before Return, Tab, Escape or arrows become navigation commands.
struct AddressTextField: NSViewRepresentable {
    let text: String
    let scale: CGFloat
    let edit: (String) -> Void
    let submit: () -> Void
    let cancel: () -> Void
    let move: (Int) -> Void
    let complete: () -> Void
    let endEditing: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = AddressInput()
        field.identifier = NSUserInterfaceItemIdentifier("breadcrumb-address")
        field.setAccessibilityLabel("Folder path")
        field.isBordered = false; field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.font = .systemFont(ofSize: 13 * scale)
        // Never replace the field editor's marked Chinese/Japanese composition.
        guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        if field.stringValue != text {
            field.stringValue = text
            field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
    }

    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        coordinator.active = false
        field.delegate = nil
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AddressTextField
        var active = true
        init(_ parent: AddressTextField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            parent.edit(field.stringValue)
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            // AppKit may end and restart editing while installing its field editor.
            // Also let a suggestion's mouse-up finish before dismissing on blur.
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, self.active, let field, field.window != nil,
                      field.currentEditor() == nil else { return }
                self.parent.endEditing()
            }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): parent.submit()
            case #selector(NSResponder.cancelOperation(_:)): parent.cancel()
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.insertTab(_:)): parent.complete()
            default: return false
            }
            return true
        }
    }
}

private final class AddressInput: NSTextField {
    private var initiallyFocused = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !initiallyFocused else { return }
        // SwiftUI can create the representable several run-loop turns before
        // attaching it. Request focus only after AppKit installs it in a window.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, !self.initiallyFocused else { return }
            self.initiallyFocused = true
            self.selectText(nil)
        }
    }
}
