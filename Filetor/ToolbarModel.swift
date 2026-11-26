import SwiftUI
import Observation

struct ToolbarEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: String
}

struct ToolDef: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var needsSelection = false
    var needsDual = false
    var isEnabled: ((AppModel) -> Bool)? = nil
    var isOn: ((AppModel) -> Bool)? = nil
    let run: (AppModel) -> Void
}

enum ToolCatalog {
    /// Items drawn by dedicated views instead of a plain button.
    static let special: [String: (title: String, symbol: String)] = [
        "backfwd": ("Back/Forward", "chevron.left.chevron.right"),
        "title": ("Title", "textformat"),
        "search": ("Search", "magnifyingglass"),
        "view": ("View", "list.bullet"),
        "space": ("Space", "rectangle.dashed"),
        "flex": ("Flexible Space", "arrow.left.and.right"),
    ]

    static let buttons: [ToolDef] = [
        ToolDef(id: "sidebar", title: L10n.tr("Sidebar"), symbol: "sidebar.left",
                isOn: { $0.sidebarVisibility != .detailOnly },
                run: { $0.sidebarVisibility = ($0.sidebarVisibility == .detailOnly) ? .all : .detailOnly }),
        ToolDef(id: "expandAll", title: L10n.tr("Expand All"), symbol: "chevron.down.2",
                isEnabled: { $0.active.expandingAll || $0.active.canExpandAll },
                isOn: { $0.active.expandingAll }, run: { $0.active.toggleExpandAll() }),
        ToolDef(id: "collapseAll", title: L10n.tr("Collapse All"), symbol: "chevron.up.2",
                isEnabled: { $0.active.canCollapseAll }, run: { $0.active.collapseAll() }),
        ToolDef(id: "goTo", title: L10n.tr("Go To"), symbol: "folder",
                isOn: { $0.showGoToFolder }, run: { $0.activateGoToFolder(focusPath: false) }),
        ToolDef(id: "dual", title: L10n.tr("Pane Layout"), symbol: "rectangle.split.2x1",
                isOn: { $0.dual }, run: { $0.dual.toggle() }),
        ToolDef(id: "quickLook", title: L10n.tr("Quick Look"), symbol: "eye", needsSelection: true,
                run: { $0.quickLook($0.active.selection) }),
        ToolDef(id: "hidden", title: L10n.tr("Hidden Files"), symbol: "eye.slash",
                isOn: { $0.active.showHidden }, run: { $0.active.toggleHidden() }),
        ToolDef(id: "newFolder", title: L10n.tr("New Folder"), symbol: "folder.badge.plus",
                run: { $0.newFolder() }),
        ToolDef(id: "projectFolder", title: L10n.tr("New Project Folder"), symbol: "folder.badge.gearshape",
                run: { $0.projectDialog = true }),
        ToolDef(id: "newFile", title: L10n.tr("New File"), symbol: "doc.badge.plus",
                run: { $0.newFile() }),
        ToolDef(id: "newTab", title: L10n.tr("New Tab"), symbol: "plus",
                run: { $0.newTab() }),
        ToolDef(id: "open", title: L10n.tr("Open"), symbol: "folder", needsSelection: true,
                run: { $0.openSelection() }),
        ToolDef(id: "rename", title: L10n.tr("Rename"), symbol: "pencil", needsSelection: true,
                run: { $0.beginRename($0.active.selection) }),
        ToolDef(id: "duplicate", title: L10n.tr("Duplicate"), symbol: "plus.square.on.square", needsSelection: true,
                run: { $0.duplicate($0.active.selection) }),
        ToolDef(id: "copy", title: L10n.tr("Copy"), symbol: "doc.on.doc", needsSelection: true, needsDual: true,
                run: { $0.transfer($0.active.selection, move: false) }),
        ToolDef(id: "move", title: L10n.tr("Move"), symbol: "arrow.right.doc.on.clipboard", needsSelection: true, needsDual: true,
                run: { $0.transfer($0.active.selection, move: true) }),
        ToolDef(id: "trash", title: L10n.tr("Move to Trash"), symbol: "trash", needsSelection: true,
                run: { $0.trash($0.active.selection) }),
        ToolDef(id: "compress", title: L10n.tr("Compress to ZIP"), symbol: "arrow.down.right.and.arrow.up.left", needsSelection: true,
                run: { $0.compress($0.active.selection) }),
        ToolDef(id: "decompress", title: L10n.tr("Extract Archive"), symbol: "arrow.up.left.and.arrow.down.right", needsSelection: true,
                run: { $0.decompress($0.active.selection) }),
        ToolDef(id: "convert", title: L10n.tr("Convert"), symbol: "arrow.triangle.2.circlepath", needsSelection: true,
                run: { let images = $0.active.selection.filter { FileTools.isImage($0) }; $0.convertURLs = images.isEmpty ? nil : images }),
        ToolDef(id: "optimize", title: L10n.tr("Optimize"), symbol: "photo", needsSelection: true,
                run: { $0.optimizeImages($0.active.selection) }),
        ToolDef(id: "stripMeta", title: L10n.tr("Strip Metadata"), symbol: "eraser", needsSelection: true,
                run: { $0.stripMetadata($0.active.selection) }),
        ToolDef(id: "touch", title: L10n.tr("Touch"), symbol: "clock", needsSelection: true,
                run: { $0.touch($0.active.selection) }),
        ToolDef(id: "copyPath", title: L10n.tr("Copy Path"), symbol: "link",
                run: { $0.copyPath() }),
        ToolDef(id: "terminal", title: L10n.tr("Terminal"), symbol: "apple.terminal",
                run: { $0.openTerminal() }),
        ToolDef(id: "reload", title: L10n.tr("Reload"), symbol: "arrow.clockwise",
                run: { $0.active.load() }),
        ToolDef(id: "airdrop", title: L10n.tr("AirDrop"), symbol: "airplayaudio", needsSelection: true,
                run: { $0.airDrop($0.active.selection) }),
        ToolDef(id: "info", title: L10n.tr("Get Info"), symbol: "info.circle", needsSelection: true,
                run: { $0.getInfo($0.active.selection) }),
        ToolDef(id: "connect", title: L10n.tr("Connect"), symbol: "globe",
                run: { $0.showConnect = true }),
        ToolDef(id: "customize", title: L10n.tr("Settings"), symbol: "gearshape",
                run: { $0.showSettings = true }),
    ]

    static func def(_ id: String) -> ToolDef? { buttons.first { $0.id == id } }

    static func help(_ def: ToolDef, app: AppModel) -> String {
        if def.needsDual && !app.dual { return def.title + L10n.tr(" — Split the pane or show all panes first") }
        if def.needsSelection && app.active.selection.isEmpty { return def.title + L10n.tr(" — Select a file or folder first") }
        switch def.id {
        case "expandAll", "collapseAll":
            if def.id == "expandAll" && app.active.expandingAll { return L10n.tr("Stop Expanding Folders") }
            let title = def.id == "expandAll" ? L10n.tr("Expand All Folders") : L10n.tr("Collapse All Folders")
            if !app.active.treeActive { return title + L10n.tr(" — Use List View without search filters") }
            if def.id == "expandAll" && app.active.loading { return title + L10n.tr(" — Wait for the folder to load") }
            if def.id == "expandAll" && !app.active.canExpandAll { return title + L10n.tr(" — No folders to expand") }
            if def.id == "collapseAll" && !app.active.canCollapseAll { return title + L10n.tr(" — No expanded folders") }
            return title + L10n.tr(" in Active Pane")
        case "sidebar": return app.sidebarVisibility == .detailOnly ? L10n.tr("Show Sidebar") : L10n.tr("Hide Sidebar")
        case "hidden": return app.active.showHidden ? L10n.tr("Hide Hidden Files") : L10n.tr("Show Hidden Files")
        case "dual": return app.dual ? L10n.tr("Focus Active Pane") : (app.groups.count > 1 ? L10n.tr("Show All Panes") : L10n.tr("Split Vertically (Left / Right)"))
        default: return def.title
        }
    }

    static func title(_ kind: String) -> String { special[kind].map { L10n.key($0.title) } ?? def(kind)?.title ?? kind }
    static func symbol(_ kind: String) -> String { special[kind]?.symbol ?? def(kind)?.symbol ?? "questionmark" }

    /// Order of the palette in the Customize sheet.
    static let palette: [String] = [
        "sidebar", "backfwd", "goTo", "title", "view", "expandAll", "collapseAll", "dual",
        "quickLook", "hidden", "newFolder", "projectFolder", "newFile", "newTab",
        "open", "rename", "duplicate", "copy", "move", "trash", "compress",
        "decompress", "convert", "optimize", "stripMeta", "touch", "copyPath", "terminal", "reload",
        "airdrop", "connect", "info", "customize", "search", "space", "flex",
    ]

    static let defaultKinds: [String] = [
        "sidebar", "backfwd", "goTo", "title", "flex", "airdrop", "terminal", "touch", "customize", "reload",
        "newFolder", "copyPath", "connect", "view", "expandAll", "collapseAll", "dual", "search",
    ]
}

@Observable
final class ToolbarModel {
    var entries: [ToolbarEntry]
    var showLabels: Bool

    private let defaults: UserDefaults
    private static let key = "toolbar.entries.v1"
    private static let labelsKey = "toolbar.showLabels.v1"

    /// Add the visible navigation entry once, keeping every existing item ID and order.
    /// Later removal through Customize is a user choice and must survive relaunch.
    static func migrateNavigationButton(_ defaults: UserDefaults = .standard) {
        let migration = "toolbar.goToMigrated.v1"
        guard !defaults.bool(forKey: migration) else { return }
        if let data = defaults.data(forKey: key) {
            guard var entries = try? JSONDecoder().decode([ToolbarEntry].self, from: data) else { return }
            if !entries.contains(where: { $0.kind == "goTo" }) {
                let anchor = entries.firstIndex { $0.kind == "backfwd" } ?? entries.firstIndex { $0.kind == "sidebar" }
                entries.insert(ToolbarEntry(kind: "goTo"), at: anchor.map { $0 + 1 } ?? 0)
                guard let updated = try? JSONEncoder().encode(entries) else { return }
                defaults.set(updated, forKey: key)
            }
        }
        defaults.set(true, forKey: migration)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([ToolbarEntry].self, from: data) {
            let kept = decoded.filter { $0.kind != "folderSize" && $0.kind != "swap" && $0.kind != "enclosing" }
            entries = kept
            if kept != decoded, let migrated = try? JSONEncoder().encode(kept) {
                defaults.set(migrated, forKey: Self.key)
            }
        } else {
            entries = ToolCatalog.defaultKinds.map { ToolbarEntry(kind: $0) }
        }
        showLabels = defaults.object(forKey: Self.labelsKey) as? Bool ?? true
    }

    func save() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.key)
        }
        defaults.set(showLabels, forKey: Self.labelsKey)
    }

    func restoreDefaults() {
        entries = ToolCatalog.defaultKinds.map { ToolbarEntry(kind: $0) }
        showLabels = true
        save()
    }

    func contains(_ kind: String) -> Bool { entries.contains { $0.kind == kind } }

    func toggle(_ kind: String) {
        guard ToolCatalog.palette.contains(kind) else { return }
        if kind == "space" || kind == "flex" {
            entries.append(ToolbarEntry(kind: kind))
        } else if let i = entries.firstIndex(where: { $0.kind == kind }) {
            entries.remove(at: i)
        } else {
            entries.append(ToolbarEntry(kind: kind))
        }
        save()
    }

    func drop(_ payload: String, before target: UUID?) {
        var entry: ToolbarEntry
        if payload.hasPrefix("new:") {
            let kind = String(payload.dropFirst(4))
            guard ToolCatalog.palette.contains(kind) else { return }
            if kind != "space" && kind != "flex" && contains(kind) { return }
            entry = ToolbarEntry(kind: kind)
        } else if payload.hasPrefix("move:"),
                  let id = UUID(uuidString: String(payload.dropFirst(5))),
                  let idx = entries.firstIndex(where: { $0.id == id }) {
            if id == target { return }
            entry = entries.remove(at: idx)
        } else {
            return
        }
        if let t = target, let ti = entries.firstIndex(where: { $0.id == t }) {
            entries.insert(entry, at: ti)
        } else {
            entries.append(entry)
        }
        save()
    }

    func removeDropped(_ payload: String) {
        guard payload.hasPrefix("move:"), let id = UUID(uuidString: String(payload.dropFirst(5))) else { return }
        entries.removeAll { $0.id == id }
        save()
    }
}
