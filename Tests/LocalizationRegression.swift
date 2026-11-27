import AppKit
import SwiftUI

extension Regression {
    static func localizationTests(_ root: URL) async throws {
        let chinese = L10n.language == "zh-Hans"
        try check(L10n.resolve(["zh-CN", "en"]) == "zh-Hans"
                  && L10n.resolve(["zh-Hans"]) == "zh-Hans"
                  && L10n.resolve(["en-US", "zh-Hans"]) == "en"
                  && L10n.resolve(["fr-FR", "en"]) == "en", "language resolution honors supported language priority and fallback")
        for language in ["en", "zh-Hans"] {
            try check(L10n.resourceBundle(for: language)?.url(forResource: "Localizable", withExtension: "strings") != nil,
                      "the app and test runner carry the \(language) resources")
        }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        for (day, hour, minute, prefix, suffix) in [(today, 0, 8, L10n.tr("Today, "), ":08"),
                                                    (today, 12, 0, L10n.tr("Today, "), ":00"),
                                                    (yesterday, 23, 59, L10n.tr("Yesterday, "), ":59")] {
            let date = cal.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
            let label = FileTableView.Coordinator.dateString(date)
            try check(label.hasPrefix(prefix) && label.hasSuffix(suffix), "file date column shows two minute digits: " + label)
        }
        let full = VolumeCapacity(available: 0, total: 1_000_000_000_000)
        try check(full?.available == 0 && VolumeCapacity(available: nil, total: 1_000_000_000_000) == nil
                  && VolumeCapacity(available: -1, total: 100) == nil && VolumeCapacity(available: 101, total: 100) == nil,
                  "volume capacity distinguishes a full disk from missing or inconsistent statistics")
        let sample = VolumeCapacity(available: 500_000_000_000, total: 1_000_000_000_000)!
        let freeLabel = ByteCountFormatter.string(fromByteCount: sample.available, countStyle: .file)
        let totalLabel = ByteCountFormatter.string(fromByteCount: sample.total, countStyle: .file)
        try check(sample.statusText == (chinese ? "\(freeLabel) 可用，共 \(totalLabel)" : "\(freeLabel) available of \(totalLabel)"),
                  "pane status includes both available space and total capacity in the selected language")
        let local = VolumeCapacity.read(at: root)
        let localFS = try fm.attributesOfFileSystem(forPath: root.path)
        try check(local != nil && local?.total == (localFS[.systemSize] as? NSNumber)?.int64Value,
                  "a subdirectory reports the capacity of its containing volume")
        let catalogKeys = SettingsSheet.Page.allCases.map(\.rawValue)
            + HelpState.Page.allCases.map(\.rawValue)
            + Shortcuts.groups.flatMap { [$0.title] + $0.entries.map(\.name) }
            + ToolCatalog.special.values.map(\.title)
            + SearchGroup.all.map(\.title)
            + FileTableView.Coordinator.optionalColumns.map(\.title)
            + ProjectTemplates.defaults.map(\.name)
        let chineseBundle = L10n.resourceBundle(for: "zh-Hans")!
        try check(catalogKeys.allSatisfy { chineseBundle.localizedString(forKey: $0, value: "__missing__", table: nil) != "__missing__" },
                  "every dynamic built-in catalog label has a translation")
        try check(L10n.tr("Copy") == (chinese ? "拷贝" : "Copy"), "the process loads its requested language")
        try check(L10n.key("not-a-translation-key") == "not-a-translation-key", "missing resources have a readable fallback")
        try check(L10n.render("{1} / {0}", arguments: ["报告{1}%@.txt", "原文件"]) == "原文件 / 报告{1}%@.txt",
                  "reordered placeholders never reinterpret filenames or percent characters")
        let filename = "报告{0}%@.txt"
        try check(L10n.tr("Could not expand \(filename): \("denied")").contains(filename), "typed interpolation preserves exact user data")
        let suite = "FiletorLanguageTest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["goTo", "info"], forKey: "toolbar-fixture")
        try check(L10n.selection(in: defaults) == .system, "new users follow the system language")
        for language in [L10n.Language.simplifiedChinese, .english, .system] {
            L10n.save(language, in: defaults)
            try check(L10n.selection(in: defaults) == language
                      && (defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String]) == (language == .system ? nil : [language.rawValue])
                      && defaults.stringArray(forKey: "toolbar-fixture") == ["goTo", "info"],
                      "saving \(language.rawValue) changes only app language preferences")
        }
        try check(L10n.tr("Copy") == (chinese ? "拷贝" : "Copy"), "saving language does not partially switch an already running interface")

        let app = AppModel()
        defer { app.stop() }
        let directory = try folder(root, "Copy")
        _ = try file(directory, "原始{1}%@.txt")
        app.groups.forEach { $0.current.navigate(to: directory) }
        app.toolbarModel.entries = ["goTo", "info", "flex", "view"].map { ToolbarEntry(kind: $0) }
        app.toolbarModel.showLabels = false
        let entries = app.toolbarModel.entries
        try check(app.favorites.place(for: directory).name == "Copy", "ordinary folder names are not translated")
        try check(SearchCriteria(kind: "images").summary == (chinese ? "图像" : "Images"), "search summaries translate without changing search keys")
        let state = HelpState()
        state.query = chinese ? "废纸篓" : "Trash"
        try check(!state.topics.isEmpty, "offline help is searchable in the chosen language")
        state.query = chinese ? "快速查看" : "Quick Look"
        try check(state.shortcutGroups.flatMap(\.entries).contains { $0.keys == "Space" }, "translated shortcut search preserves keyboard bindings")

        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 650),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            CustomToolbar(app: app)
            PaneContainer(app: app, index: 0)
        })
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        try await until("localized file list") { !app.active.loading && descendants(host).contains { $0 is QLTableView } }
        try await Task.sleep(for: .milliseconds(250))
        let table = descendants(host).compactMap { $0 as? QLTableView }.first!
        try check(table.tableColumns.first?.title == (chinese ? "名称" : "Name")
                  && table.tableColumns.first?.identifier.rawValue == "name", "native column titles translate while saved column identifiers remain stable")
        let tooltips = descendants(host).compactMap { ($0 as? ToolbarHelpView)?.toolTip }
        try check(tooltips.contains { $0.hasPrefix(chinese ? "显示简介" : "Get Info") }, "icon-only toolbar exposes translated native tooltips")
        let menu = NSMenu()
        table.qlSource!.populateContextMenu(menu, row: -1)
        let create = menu.item(withTitle: L10n.tr("New File"))?.submenu?.item(withTitle: NewFileKind.text.title)
        try check(create != nil && menu.item(withTitle: L10n.tr("Paste")) != nil, "native blank-area menu and file templates are localized")
        NSApp.sendAction(create!.action!, to: create!.target, from: create!)
        try check(app.renameTarget?.lastPathComponent == "untitled.txt" && app.renameTarget?.deletingLastPathComponent() == directory,
                  "translated New File action still creates the expected file in its pane")
        app.renameTarget = nil
        try check(app.toolbarModel.entries == entries && !app.toolbarModel.showLabels, "localization preserves customized icon-only toolbar identities and order")

        let preview = BuiltinPreviewController()
        preview.show([directory], relativeTo: window, showHidden: false)
        defer { preview.panel.orderOut(nil) }
        try await until("localized folder preview") { preview.model.root?.loading == false }
        try check(preview.outline.tableColumns.first?.title == L10n.tr("Name") && preview.currentURL == directory,
                  "enhanced preview localizes its columns without changing the selected path")
        snapshotLocalization(preview.panel, name: "preview-\(L10n.language)")
    }

    static func localizationSceneTests(app: AppModel, window: NSWindow) async throws {
        try check(L10n.language == "zh-Hans", "Chinese real-window scene loads the Chinese resources")
        app.toolbarModel.showLabels = false
        app.sidebarVisibility = .all
        try await Task.sleep(for: .milliseconds(300))
        snapshotLocalization(window, name: "workspace-zh-Hans")
        let help = NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.item(withTitle: "Filetor Pro 帮助") != nil }
        try check(help?.item(withTitle: "报告问题…") != nil && help?.item(withTitle: "键盘快捷键") != nil,
                  "real native Help menu contains translated help and feedback actions")
        if let index = help?.items.firstIndex(where: { $0.title == "Filetor Pro 帮助" }) { help?.performActionForItem(at: index) }
        try await until("Chinese Help menu opens") { HelpCenter.shared.window?.isVisible == true }
        if let helpWindow = HelpCenter.shared.window { snapshotLocalization(helpWindow, name: "help-zh-Hans") }
        HelpCenter.shared.window?.close()
        for page in SettingsSheet.Page.allCases {
            let settings = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 760, height: 540), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            settings.isReleasedWhenClosed = false
            settings.contentView = NSHostingView(rootView: SettingsSheet(app: app, page: page))
            settings.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(150))
            snapshotLocalization(settings, name: "settings-\(page.rawValue)-zh-Hans")
            if page == .general {
                settings.appearance = NSAppearance(named: .darkAqua)
                try await Task.sleep(for: .milliseconds(150))
                snapshotLocalization(settings, name: "settings-dark-zh-Hans")
            }
            settings.orderOut(nil); settings.contentView = nil; settings.close()
        }
        try check(app.active.currentURL.lastPathComponent.hasPrefix("FiletorScene-"), "opening every translated settings page preserves the current directory")
    }

    static func snapshotLocalization(_ window: NSWindow, name: String) {
        let url = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appending(path: name + ".png")
        // Optional compositor capture includes vibrancy/Metal-backed regions
        // that AppKit's offscreen cache cannot render. Never require screen
        // recording permission for the ordinary regression suite.
        if ProcessInfo.processInfo.environment["FILETOR_CAPTURE_SCREENSHOTS"] == "1" {
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber), url.path]
            if (try? capture.run()) != nil {
                capture.waitUntilExit()
                if capture.terminationStatus == 0 { return }
            }
        }
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}
