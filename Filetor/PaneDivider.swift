import SwiftUI
import AppKit

/// One native hit target owns the pointer, hover feedback and drag. A background
/// cursor-only view can lose cursor updates to the hosting view above it.
struct PaneDivider: NSViewRepresentable {
    let axis: PaneSplitAxis
    let fraction: Double
    let available: CGFloat
    let onResize: (Double) -> Void
    let onFinish: () -> Void
    let onBalance: () -> Void

    func makeNSView(context: Context) -> PaneDividerView { PaneDividerView() }

    func updateNSView(_ view: PaneDividerView, context: Context) {
        view.axis = axis
        view.fraction = fraction
        view.available = available
        view.onResize = onResize
        view.onFinish = onFinish
        view.onBalance = onBalance
        view.setAccessibilityLabel(axis == .vertical ? L10n.tr("Resize Left and Right Panes") : L10n.tr("Resize Top and Bottom Panes"))
        view.window?.invalidateCursorRects(for: view)
    }
}

final class PaneDividerView: NSView {
    var axis: PaneSplitAxis = .vertical
    var fraction: Double = 0.5
    var available: CGFloat = 1
    var onResize: (Double) -> Void = { _ in }
    var onFinish: () -> Void = {}
    var onBalance: () -> Void = {}
    private(set) var isHovering = false
    private(set) var isDragging = false
    private var tracking: NSTrackingArea?
    private var dragOrigin: NSPoint = .zero
    private var dragFraction: Double = 0.5
    private var dragAvailable: CGFloat = 1
    var resizeCursor: NSCursor { axis == .vertical ? .resizeLeftRight : .resizeUpDown }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = L10n.tr("Drag to resize panes; double-click to balance")
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityHelp(toolTip)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() { addCursorRect(visibleRect, cursor: resizeCursor) }
    override func cursorUpdate(with event: NSEvent) { resizeCursor.set() }
    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
        resizeCursor.set()
    }
    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
        if !isDragging { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        resizeCursor.set()
        if event.clickCount == 2 { onBalance(); return }
        dragOrigin = event.locationInWindow
        dragFraction = fraction
        dragAvailable = max(available, 1)
        isDragging = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        // Window coordinates increase upward; horizontal splits grow downward.
        let delta = axis == .vertical ? event.locationInWindow.x - dragOrigin.x : dragOrigin.y - event.locationInWindow.y
        onResize(dragFraction + delta / dragAvailable)
        resizeCursor.set()
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging { isDragging = false; onFinish() }
        isHovering = visibleRect.contains(convert(event.locationInWindow, from: nil))
        needsDisplay = true
        (isHovering ? resizeCursor : NSCursor.arrow).set()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            if isDragging { isDragging = false; onFinish() }
            if isHovering { isHovering = false; NSCursor.arrow.set() }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = isHovering || isDragging
        (highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.16) : NSColor.labelColor.withAlphaComponent(0.06)).setFill()
        bounds.fill()
        if highlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.65).setFill()
            let grip = axis == .vertical
                ? NSRect(x: bounds.midX - 1, y: bounds.midY - 12, width: 2, height: 24)
                : NSRect(x: bounds.midX - 12, y: bounds.midY - 1, width: 24, height: 2)
            NSBezierPath(roundedRect: grip, xRadius: 1, yRadius: 1).fill()
        }
    }
}
