import Foundation
import AppKit
import SwiftUI

extension Regression {
    static func browsingTests(_ root: URL) async throws {
        let defaultsName = "FiletorDisplayTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(true, forKey: "compactRows")
        defaults.set(["copy", "view", "search"], forKey: "toolbar-sentinel")
        DisplayPreferences.migrate(defaults)
        try check(defaults.double(forKey: "listRowHeight") == 20, "display migration retains compact row height")
        defaults.set(38.0, forKey: "listRowHeight")
        DisplayPreferences.migrate(defaults)
        try check(defaults.double(forKey: "listRowHeight") == 38 && defaults.stringArray(forKey: "toolbar-sentinel") == ["copy", "view", "search"], "display migration preserves later choices and unrelated settings")
        defaults.removeObject(forKey: "listRowHeight"); defaults.set(false, forKey: "compactRows")
        DisplayPreferences.migrate(defaults)
        try check(defaults.double(forKey: "listRowHeight") == 25, "display migration retains normal row height")

        let dir = try folder(root, "Browsing 中文")
        let fileURL = try file(dir, "报告.txt", "original")
        let dottedFolder = try folder(dir, "Project.v2")
        let dotFile = try file(dir, ".env.local")
        try check(FileItem(url: fileURL).displayName(showExtension: false) == "报告" && FileItem(url: dottedFolder).displayName(showExtension: false) == "Project.v2" && FileItem(url: dotFile).displayName(showExtension: false) == ".env.local", "extension hiding preserves dotted folders and dotfiles")
        let previousExtensions = UserDefaults.standard.object(forKey: "showExtensions")
        UserDefaults.standard.set(false, forKey: "showExtensions")
        defer {
            if let previousExtensions { UserDefaults.standard.set(previousExtensions, forKey: "showExtensions") }
            else { UserDefaults.standard.removeObject(forKey: "showExtensions") }
        }
        let app = AppModel()
        defer { app.stop() }
        app.active.navigate(to: dir)
        app.beginRename([fileURL])
        try check(app.renameText == "报告", "rename editor starts with the visible file name")
        app.renameText = "新报告"
        app.commitRename()
        let renamed = dir.appending(path: "新报告.txt")
        try check(contents(renamed) == "original" && !fm.fileExists(atPath: fileURL.path), "renaming a hidden extension retains the actual extension")
        app.beginRename([renamed]); app.renameText = ".."; app.commitRename()
        try check(contents(renamed) == "original", "hidden-extension rename does not turn invalid names into valid files")
        app.alert = nil

        let queryFolder = try folder(root, "Search Fixtures")
        let sub = try folder(queryFolder, "Nested")
        let pdf = try file(queryFolder, "项目.PDF", String(repeating: "x", count: 120))
        _ = try file(queryFolder, "项目.txt", String(repeating: "x", count: 120))
        let nestedPDF = try file(sub, "项目资料.pdf", String(repeating: "x", count: 200))
        let stale = try file(sub, "项目旧版.pdf", String(repeating: "x", count: 120))
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-40 * 86400)], ofItemAtPath: stale.path)
        let pane = PaneModel(url: queryFolder)
        pane.searchSubfolders = false
        pane.load()
        defer { pane.stop() }
        try await until("search fixture load") { !pane.loading }
        pane.criteria = SearchCriteria(kind: "pdf", days: 7, minBytes: 100, maxBytes: 250)
        pane.filter = "项目"
        try check(pane.sortedItems.map(\.url) == [pdf] && !pane.treeActive, "current-folder filters combine Chinese name, type, date and size")
        pane.searchSubfolders = true
        try await until("recursive structured search") { !pane.searching }
        try check(Set(pane.sortedItems.map(\.url)) == [pdf, nestedPDF], "recursive filters match the same conditions and exclude older files")
        pane.filter = "no match"; pane.filter = "项目"
        try await until("latest recursive query") { !pane.searching }
        try check(Set(pane.sortedItems.map(\.url)) == [pdf, nestedPDF], "rapid query edits discard stale results")
        let added = try file(sub, "项目新文件.pdf", String(repeating: "x", count: 180))
        pane.reloadKeepingSelection()
        try await until("refresh recursive results") { !pane.searching }
        try check(pane.sortedItems.contains { $0.url == added }, "refreshing a recursive search includes newly matching files")
        pane.clearSearch()
        try check(!pane.searchActive && pane.treeActive && pane.criteria.isEmpty, "clearing search restores folder browsing")
        pane.navigateSelecting(nestedPDF)
        try await until("file path navigation") { !pane.loading }
        try check(pane.currentURL == sub && pane.selection == [nestedPDF], "opening a file path selects it after asynchronous folder loading")
        pane.navigateSelecting(pdf)
        pane.navigate(to: dir)
        try await until("replacement navigation") { !pane.loading }
        try check(pane.currentURL == dir && !pane.selection.contains(pdf), "later navigation cannot inherit a stale requested selection")
        pane.navigateSelecting(dotFile)
        try await until("reveal explicit hidden file") { !pane.loading }
        try check(pane.showHidden && pane.selection == [dotFile] && pane.sortedItems.contains { $0.url == dotFile }, "opening a hidden file path reveals and selects it")
        for input in ["-1", "nan", "inf", "1e40", "not a size"] {
            do {
                _ = try SearchCriteria.bytes(fromMB: input)
                throw FileOperationSafety.failure("Invalid size was accepted")
            } catch { try check((error as NSError).localizedDescription != "Invalid size was accepted", "reject invalid search size: \(input)") }
        }
        try check(try SearchCriteria.bytes(fromMB: "1.5") == 1_500_000, "decimal search sizes are parsed without truncating MB")

        let pathFolder = try folder(root, "Path Fixtures")
        let chinese = try folder(pathFolder, "中文 项目")
        _ = try folder(pathFolder, "Alpha")
        _ = try file(pathFolder, ".hidden")
        _ = try file(pathFolder, "z.txt")
        try check(try PathCompletion.url(for: "\"中文 项目\"", base: pathFolder) == chinese, "quoted relative Chinese paths resolve against the current folder")
        try check(try PathCompletion.url(for: chinese.absoluteString, base: pathFolder) == chinese, "file URL paths decode spaces and Unicode")
        let entries = try PathCompletion.list(pathFolder.path + "/", base: pathFolder)
        try check(entries.filter(\.directory).count == 2 && !entries.contains { $0.url.lastPathComponent == ".hidden" }, "path candidates sort folders first and omit hidden files")
        try check(try PathCompletion.list(pathFolder.path + "/.", base: pathFolder).contains { $0.url.lastPathComponent == ".hidden" }, "typing a dot enables hidden path candidates")
        try check(try PathCompletion.list("\"../.\"", base: chinese).contains { $0.url.lastPathComponent == ".hidden" }, "quoted parent-relative completion preserves the hidden-file prefix")
        try check(try PathCompletion.list(pathFolder.absoluteString + (pathFolder.absoluteString.hasSuffix("/") ? "." : "/."), base: pathFolder).contains { $0.url.lastPathComponent == ".hidden" }, "file URL completion preserves the hidden-file prefix")
        let completion = PathCompletion(base: pathFolder)
        completion.text = pathFolder.path + "/A"; completion.update()
        completion.text = pathFolder.path + "/中文"; completion.update()
        try await until("latest path completion") { !completion.loading }
        try check(completion.candidates.map(\.url) == [chinese], "path completion applies only the latest input")
        completion.text = "/"; completion.update(); completion.stop()
        try await Task.sleep(for: .milliseconds(180))
        try check(!completion.loading && completion.candidates.isEmpty, "closing path completion cancels pending work")

        try await thumbnailTests(root)
        try await browsingSnapshots(app, folder: pathFolder)
        try await workspaceOwnershipTest(folder: pathFolder)
    }

    static func workspaceOwnershipTest(folder: URL) async throws {
        let id = UUID()
        AppModel.windowLocations[id] = folder
        defer { AppModel.windowLocations.removeValue(forKey: id) }
        _ = WorkspaceRoot(workspaceID: id)
        _ = WorkspaceRoot(workspaceID: id)
        try check(AppModel.windowLocations[id] == folder, "discarded SwiftUI window values cannot consume pending restoration")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: WorkspaceRoot(workspaceID: id))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try await until("retained workspace owner") { AppModel.windowLocations[id] == nil }
        try check(AppModel.windowLocations[id] == nil, "retained SwiftUI window creates its workspace model")
        AppModel.windowLocations[id] = folder
        host.rootView = WorkspaceRoot(workspaceID: id)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        try check(AppModel.windowLocations[id] == folder, "rebuilding a retained window keeps the existing workspace owner")
    }

    static func thumbnailTests(_ root: URL) async throws {
        let dir = try folder(root, "Thumbnails")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let blue = NSColor(deviceRed: 0.1, green: 0.4, blue: 0.9, alpha: 1)
        for y in 0..<48 { for x in 0..<48 { bitmap.setColor(blue, atX: x, y: y) } }
        let data = bitmap.representation(using: .png, properties: [:])!
        var items: [FileItem] = []
        for i in 0..<12 {
            let url = dir.appending(path: "image-\(i).png")
            try data.write(to: url); items.append(FileItem(url: url))
        }
        let loader = FileThumbnails()
        var callbacks = 0
        let tokens = items.map { loader.request($0, side: 52, scale: 2) { _ in callbacks += 1 } }
        try check(loader.activeCount <= 4 && loader.pendingCount == 12, "thumbnail generation bounds concurrency with queued visible files")
        tokens.forEach { loader.cancel($0) }
        try check(loader.activeCount == 0 && loader.pendingCount == 0, "cancelled views release queued and active thumbnail requests")
        try await Task.sleep(for: .milliseconds(250))
        try check(callbacks == 0, "cancelled thumbnails cannot update removed views")
        var done = false, image: NSImage?
        let token = loader.request(items[0], side: 52, scale: 2) { result in image = result; done = true }
        defer { loader.cancel(token) }
        try await until("native thumbnail generation") { done }
        try check(image != nil, "system thumbnail generator renders a real local image")
        let before = FileThumbnails.key(items[0], side: 52, scale: 2)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: items[0].url.path)
        let changed = FileItem(url: URL(fileURLWithPath: items[0].url.path))
        try check(before != FileThumbnails.key(changed, side: 52, scale: 2), "file modification invalidates thumbnail cache identity")
    }

    static func browsingSnapshots(_ app: AppModel, folder: URL) async throws {
        app.active.navigate(to: folder)
        try await until("snapshot folder") { !app.active.loading }
        func snapshot<V: View>(_ view: V, name: String, size: NSSize) async throws {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(100))
            let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            try await Task.sleep(for: .milliseconds(350))
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw FileOperationSafety.failure("Missing UI bitmap") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let out = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appending(path: name + ".png")
            try bitmap.representation(using: .png, properties: [:])!.write(to: out)
        }
        NSApp.appearance = NSAppearance(named: .aqua)
        try await snapshot(SettingsSheet(app: app, page: .browsing), name: "settings-browsing", size: NSSize(width: 800, height: 650))
        try await snapshot(SettingsSheet(app: app, page: .updates), name: "settings-updates-new", size: NSSize(width: 800, height: 650))
        try await snapshot(SettingsSheet(app: app, page: .browsing), name: "settings-narrow", size: NSSize(width: 600, height: 500))
        try await snapshot(CustomToolbar(app: app), name: "toolbar-narrow", size: NSSize(width: 500, height: 64))
        try await snapshot(SearchPopup(app: app, pane: app.active), name: "local-search", size: NSSize(width: 700, height: 660))
        try await snapshot(GoToFolderPopup(app: app, pane: app.active), name: "path-completion", size: NSSize(width: 700, height: 600))
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try await snapshot(SettingsSheet(app: app, page: .browsing), name: "settings-browsing-dark", size: NSSize(width: 800, height: 650))
        NSApp.appearance = nil
    }
}
