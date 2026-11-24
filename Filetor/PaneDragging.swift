import AppKit
import SwiftUI

enum PanePlacement: String, CaseIterable {
    case center, left, right, top, bottom

    var title: String {
        switch self {
        case .center: return "Swap Pane Positions"
        case .left: return "Move Pane to Left"
        case .right: return "Move Pane to Right"
        case .top: return "Move Pane Above"
        case .bottom: return "Move Pane Below"
        }
    }

    /// Coordinates are flipped (origin at the top left), matching the preview.
    static func at(_ point: NSPoint, size: NSSize) -> PanePlacement? {
        guard size.width > 0, size.height > 0,
              NSRect(origin: .zero, size: size).contains(point) else { return nil }
        let edges: [(PanePlacement, CGFloat)] = [
            (.left, point.x / min(size.width * 0.25, 90)),
            (.right, (size.width - point.x) / min(size.width * 0.25, 90)),
            (.top, point.y / min(size.height * 0.25, 90)),
            (.bottom, (size.height - point.y) / min(size.height * 0.25, 90))
        ]
        if let edge = edges.min(by: { $0.1 < $1.1 }), edge.1 < 1 { return edge.0 }
        return .center
    }

    func preview(in bounds: NSRect) -> NSRect {
        var rect = bounds.insetBy(dx: 8, dy: 8)
        switch self {
        case .center: break
        case .left: rect.size.width /= 2
        case .right: rect.origin.x += rect.width / 2; rect.size.width /= 2
        case .top: rect.size.height /= 2
        case .bottom: rect.origin.y += rect.height / 2; rect.size.height /= 2
        }
        return rect
    }
}

/// A private pasteboard type keeps pane drags separate from tabs and files.
struct PaneDragPayload: Codable, Equatable {
    static let pasteboardType = NSPasteboard.PasteboardType("com.doithoo.FiletorPro.pane")
    let workspaceID: UUID
    let groupID: UUID
    let token: UUID

    func pasteboardItem() -> NSPasteboardItem? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        let item = NSPasteboardItem()
        item.setData(data, forType: Self.pasteboardType)
        return item
    }
}

struct PaneDragHandle: NSViewRepresentable {
    let app: AppModel
    let groupID: UUID
    func makeNSView(context: Context) -> PaneDragHandleView { PaneDragHandleView() }
    func updateNSView(_ view: PaneDragHandleView, context: Context) {
        view.app = app
        view.groupID = groupID
    }
}

final class PaneDragHandleView: NSView, NSDraggingSource {
    weak var app: AppModel?
    var groupID = UUID()
    private var tracking: NSTrackingArea?
    private var mouseOrigin: NSPoint?
    private(set) var payload: PaneDragPayload?
    private var hovering = false
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Drag this pane: drop in the center to swap, or at an edge to reposition"
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Move Pane")
        setAccessibilityHelp(toolTip)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }
    override func resetCursorRects() { addCursorRect(visibleRect, cursor: .openHand) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.openHand.set() }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true; NSCursor.openHand.set() }
    override func mouseExited(with event: NSEvent) {
        hovering = false; needsDisplay = true
        if payload == nil { NSCursor.arrow.set() }
    }
    override func mouseDown(with event: NSEvent) { mouseOrigin = event.locationInWindow }
    override func mouseUp(with event: NSEvent) { mouseOrigin = nil }

    override func mouseDragged(with event: NSEvent) {
        guard payload == nil, let origin = mouseOrigin,
              hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) >= 4,
              let app, let drag = app.startPaneDrag(groupID) else { return }
        guard let item = drag.pasteboardItem() else { app.endPaneDrag(drag); return }
        payload = drag
        let title = app.groups.first { $0.id == groupID }?.current.title ?? "Pane"
        let image = NSImage(size: NSSize(width: 200, height: 40), flipped: false) { rect in
            NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
            let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
            (title as NSString).draw(in: rect.insetBy(dx: 12, dy: 10), withAttributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor, .paragraphStyle: style
            ])
            return true
        }
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let point = convert(event.locationInWindow, from: nil)
        draggingItem.setDraggingFrame(NSRect(x: point.x - 10, y: point.y - 20, width: 200, height: 40), contents: image)
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if let payload { app?.endPaneDrag(payload) }
        payload = nil
        mouseOrigin = nil
        hovering = false
        needsDisplay = true
        NSCursor.arrow.set()
    }

    override func draw(_ dirtyRect: NSRect) {
        (hovering ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).setFill()
        for x in [-3, 3] as [CGFloat] {
            for y in [-5, 0, 5] as [CGFloat] {
                NSBezierPath(ovalIn: NSRect(x: bounds.midX + x - 1.2, y: bounds.midY + y - 1.2, width: 2.4, height: 2.4)).fill()
            }
        }
    }
}

struct PaneDropSurface: NSViewRepresentable {
    let app: AppModel
    let groupID: UUID
    func makeNSView(context: Context) -> PaneDropView { PaneDropView() }
    func updateNSView(_ view: PaneDropView, context: Context) { view.app = app; view.groupID = groupID }
}

/// Exists only for a pane drag, leaving ordinary file and tab drops untouched.
final class PaneDropView: NSView {
    weak var app: AppModel?
    var groupID = UUID()
    private(set) var placement: PanePlacement? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([PaneDragPayload.pasteboardType])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func acceptedPayload(_ sender: NSDraggingInfo) -> PaneDragPayload? {
        guard let app, app.dual,
              let source = sender.draggingSource as? PaneDragHandleView,
              source.app === app, source.window === window,
              let data = sender.draggingPasteboard.data(forType: PaneDragPayload.pasteboardType),
              let payload = try? JSONDecoder().decode(PaneDragPayload.self, from: data),
              payload == app.paneDrag, payload.workspaceID == app.workspaceID,
              payload.groupID == source.groupID, payload.groupID != groupID,
              app.visibleGroups.contains(where: { $0.id == payload.groupID }),
              app.visibleGroups.contains(where: { $0.id == groupID }) else { return nil }
        return payload
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptedPayload(sender) != nil else { placement = nil; return [] }
        placement = PanePlacement.at(convert(sender.draggingLocation, from: nil), size: bounds.size)
        return placement == nil ? [] : .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { placement = nil }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { acceptedPayload(sender) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let app, let payload = acceptedPayload(sender),
              let location = PanePlacement.at(convert(sender.draggingLocation, from: nil), size: bounds.size) else { return false }
        let moved = app.movePane(payload.groupID, to: groupID, placement: location)
        placement = nil
        app.endPaneDrag(payload)
        return moved
    }
    override func draggingEnded(_ sender: NSDraggingInfo) { placement = nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let placement else { return }
        let rect = placement.preview(in: bounds)
        let outline = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill(); outline.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke(); outline.lineWidth = 2; outline.stroke()
        let style = NSMutableParagraphStyle(); style.alignment = .center
        let label = NSRect(x: rect.minX + 8, y: rect.midY - 20, width: rect.width - 16, height: 40)
        (placement.title as NSString).draw(in: label, withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: style
        ])
    }
}
