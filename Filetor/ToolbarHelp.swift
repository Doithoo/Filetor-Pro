import SwiftUI
import AppKit

/// Register AppKit tooltips over the whole control, including disabled buttons.
/// The view never consumes clicks or interferes with toolbar dragging/popovers.
struct ToolbarHelp: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> ToolbarHelpView { ToolbarHelpView() }

    func updateNSView(_ view: ToolbarHelpView, context: Context) {
        if view.toolTip != text { view.toolTip = text }
    }
}

final class ToolbarHelpView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var mouseDownCanMoveWindow: Bool { false }
}

extension View {
    func toolbarHelp(_ text: String) -> some View {
        background(ToolbarHelp(text: text))
            .accessibilityHint(text)
    }
}
