import SwiftUI

enum PaneSplitAxis: String, Codable, CaseIterable {
    case horizontal, vertical
    var title: String { self == .horizontal ? "Split Horizontally (Top / Bottom)" : "Split Vertically (Left / Right)" }
}

/// Stable group identities make nested layout edits independent of array indices.
indirect enum PaneLayout: Codable, Equatable {
    case pane(UUID)
    case split(id: UUID, axis: PaneSplitAxis, ratio: Double, first: PaneLayout, second: PaneLayout)

    var id: UUID {
        switch self { case .pane(let id), .split(let id, _, _, _, _): return id }
    }
    var leaves: [UUID] {
        switch self {
        case .pane(let id): return [id]
        case .split(_, _, _, let a, let b): return a.leaves + b.leaves
        }
    }
    func splitting(_ target: UUID, with newID: UUID, axis: PaneSplitAxis) -> PaneLayout {
        switch self {
        case .pane(let id):
            return id == target ? .split(id: UUID(), axis: axis, ratio: 0.5, first: self, second: .pane(newID)) : self
        case .split(let id, let direction, let ratio, let a, let b):
            return .split(id: id, axis: direction, ratio: ratio,
                          first: a.splitting(target, with: newID, axis: axis), second: b.splitting(target, with: newID, axis: axis))
        }
    }
    func removing(_ target: UUID) -> PaneLayout? {
        switch self {
        case .pane(let id): return id == target ? nil : self
        case .split(let id, let axis, let ratio, let a, let b):
            let first = a.removing(target), second = b.removing(target)
            if let first, let second { return .split(id: id, axis: axis, ratio: ratio, first: first, second: second) }
            return first ?? second
        }
    }
    func resizing(_ target: UUID, ratio value: Double) -> PaneLayout {
        switch self {
        case .pane: return self
        case .split(let id, let axis, let ratio, let a, let b):
            return .split(id: id, axis: axis, ratio: id == target ? min(max(value, 0.05), 0.95) : ratio,
                          first: a.resizing(target, ratio: value), second: b.resizing(target, ratio: value))
        }
    }
    /// Move whole groups, preserving their tabs, histories and closed-tab stacks.
    func moving(_ source: UUID, to target: UUID, placement: PanePlacement) -> PaneLayout? {
        guard source != target, leaves.contains(source), leaves.contains(target) else { return nil }
        if placement == .center { return exchanging(source, target) }
        guard let remaining = removing(source) else { return nil }
        return remaining.inserting(source, beside: target, placement: placement)
    }

    private func exchanging(_ a: UUID, _ b: UUID) -> PaneLayout {
        switch self {
        case .pane(let id): return .pane(id == a ? b : id == b ? a : id)
        case .split(let id, let axis, let ratio, let first, let second):
            return .split(id: id, axis: axis, ratio: ratio, first: first.exchanging(a, b), second: second.exchanging(a, b))
        }
    }

    private func inserting(_ source: UUID, beside target: UUID, placement: PanePlacement) -> PaneLayout {
        switch self {
        case .pane(let id):
            guard id == target else { return self }
            let before = placement == .left || placement == .top
            let axis: PaneSplitAxis = placement == .left || placement == .right ? .vertical : .horizontal
            return .split(id: UUID(), axis: axis, ratio: 0.5,
                          first: before ? .pane(source) : self, second: before ? self : .pane(source))
        case .split(let id, let axis, let ratio, let first, let second):
            return .split(id: id, axis: axis, ratio: ratio,
                          first: first.inserting(source, beside: target, placement: placement),
                          second: second.inserting(source, beside: target, placement: placement))
        }
    }

    func valid(for groups: [UUID]) -> Bool {
        var nodes = Set<UUID>()
        func visit(_ node: PaneLayout, depth: Int) -> Bool {
            guard depth <= 32, nodes.insert(node.id).inserted else { return false }
            switch node {
            case .pane: return true
            case .split(_, _, let r, let a, let b): return r.isFinite && r > 0 && r < 1 && visit(a, depth: depth + 1) && visit(b, depth: depth + 1)
            }
        }
        return visit(self, depth: 0) && leaves.count == groups.count && Set(leaves) == Set(groups)
    }
    static func row(_ ids: [UUID]) -> PaneLayout {
        precondition(!ids.isEmpty)
        guard ids.count > 1 else { return .pane(ids[0]) }
        return .split(id: UUID(), axis: .vertical, ratio: 1 / Double(ids.count), first: .pane(ids[0]), second: row(Array(ids.dropFirst())))
    }
    var minimumSize: CGSize {
        switch self {
        case .pane: return CGSize(width: 280, height: 240)
        case .split(_, let axis, _, let a, let b):
            let x = a.minimumSize, y = b.minimumSize
            return axis == .vertical ? CGSize(width: x.width + y.width + 7, height: max(x.height, y.height))
                : CGSize(width: max(x.width, y.width), height: x.height + y.height + 7)
        }
    }
}

struct PaneDestination: Identifiable {
    let id: UUID
    let title: String
    let directory: URL
}

struct PaneChoice: Identifiable {
    let id = UUID()
    let title: String
    let destinations: [PaneDestination]
    let perform: (PaneDestination) -> Void
}

struct PaneChoiceView: View {
    let choice: PaneChoice
    let app: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(choice.title).font(.headline)
            Text("Choose a destination pane").foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(choice.destinations) { destination in
                        Button {
                            app.selectPaneDestination(destination, for: choice.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(destination.title)
                                Text(destination.directory.path).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }.buttonStyle(.plain).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                            .toolbarHelp(destination.directory.path)
                    }
                }
            }.frame(maxHeight: 320)
            HStack { Spacer(); Button("Cancel") { app.pendingPaneChoice = nil }.keyboardShortcut(.cancelAction) }
        }.padding(20).frame(width: 440)
    }
}
