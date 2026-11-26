import SwiftUI
import AppKit
import Observation

enum SupportLink: CaseIterable {
    case issue, suggestion, releases, project

    var title: String {
        switch self {
        case .issue: L10n.tr("Report an Issue…")
        case .suggestion: L10n.tr("Suggest a Feature…")
        case .releases: L10n.tr("Release Notes")
        case .project: L10n.tr("Filetor Pro on GitHub")
        }
    }

    static var appInformation: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Development"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(ProductInfo.name) \(ProductInfo.version) (\(build))\nmacOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }

    var url: URL {
        var components = URLComponents(string: "https://github.com/\(UpdateChecker.repo)")!
        switch self {
        case .project: break
        case .releases: components.path += "/releases/latest"
        case .issue, .suggestion:
            components.path += "/issues/new"
            let body = self == .issue
                ? L10n.tr("## What happened?\n\n\n## Steps to reproduce\n1. \n\n## Expected behavior\n\n\n## App information\n\(Self.appInformation)\n\nPlease remove private paths or personal information from screenshots before submitting.")
                : L10n.tr("## What would you like to improve?\n\n\n## How would this help your workflow?\n\n\n## App information\n\(Self.appInformation)")
            components.queryItems = [URLQueryItem(name: "title", value: self == .issue ? "[Bug] " : "[Feature] "),
                                     URLQueryItem(name: "body", value: body)]
        }
        return components.url!
    }

    @discardableResult
    func open(using opener: (URL) -> Bool = { NSWorkspace.shared.open($0) }) -> Bool {
        opener(url)
    }

    func openInBrowser() {
        guard !open() else { return }
        let alert = NSAlert()
        alert.messageText = L10n.tr("Could not open the browser")
        alert.informativeText = L10n.tr("Check your default browser, or copy this address and open it manually:\n\(url.absoluteString)")
        alert.addButton(withTitle: L10n.tr("OK"))
        alert.addButton(withTitle: L10n.tr("Copy Link"))
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
    }
}

struct HelpCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button(L10n.tr("Filetor Pro Help")) { HelpCenter.shared.show(.guide) }
                .keyboardShortcut("?", modifiers: .command)
            Button(L10n.tr("Keyboard Shortcuts")) { HelpCenter.shared.show(.shortcuts) }
            Divider()
            Button(SupportLink.issue.title) { SupportLink.issue.openInBrowser() }
            Button(SupportLink.suggestion.title) { SupportLink.suggestion.openInBrowser() }
            Divider()
            Button(SupportLink.releases.title) { SupportLink.releases.openInBrowser() }
            Button(SupportLink.project.title) { SupportLink.project.openInBrowser() }
        }
    }
}

struct HelpTopic: Identifiable {
    let title: String
    let symbol: String
    let text: String
    var id: String { title }

    func matches(_ query: String) -> Bool {
        query.isEmpty || (title + " " + text).localizedCaseInsensitiveContains(query)
    }
}

enum HelpContent {
    static let topics: [HelpTopic] = [
        HelpTopic(title: L10n.tr("Browse and find files"), symbol: "folder",
                  text: L10n.tr("Use the sidebar to open favorites, disks and Trash. Click a breadcrumb’s arrow to browse its subfolders. The Go To toolbar button opens a folder browser; click blank space in the path bar to enter a full path. Path entry supports Chinese names and Tab completion. Search filters the active pane, with an option to include subfolders.")),
        HelpTopic(title: L10n.tr("Windows, tabs and panes"), symbol: "rectangle.split.2x1",
                  text: L10n.tr("Choose File → New Window for an independent workspace. Use + in a pane’s tab bar for a new tab. Right-click empty space to split horizontally (top/bottom) or vertically (left/right). Drag a divider to resize; double-click it to balance. Drag the dotted tab-bar grip to move a whole pane: drop in another pane’s center to swap, or at an edge to place it there. Closing the last tab closes its pane; closing the last pane closes the window.")),
        HelpTopic(title: L10n.tr("Expand folders in place"), symbol: "chevron.down.2",
                  text: L10n.tr("In List View, click the triangle beside a folder to browse its contents without leaving the current location. Add Expand All and Collapse All through Customize Toolbar, or use the View menu. These affect only the active pane. During expansion, click Stop Expanding to cancel. Search filters and Icon View disable inline expansion. Large trees stop at a display limit; open a subfolder to continue. Application packages and symbolic links are not expanded.")),
        HelpTopic(title: L10n.tr("Customize the toolbar"), symbol: "slider.horizontal.3",
                  text: L10n.tr("Right-click the toolbar and choose Customize Toolbar to add, remove or reorder tools. Choose Icon Only for a compact layout; hover over an icon for its description. The rightmost sidebar icon shows or hides the information panel. Get Info opens Finder’s information window for the selected files.")),
        HelpTopic(title: L10n.tr("Work with files and archives"), symbol: "doc.on.doc",
                  text: L10n.tr("Right-click a file for copy, cut, paste, Move to… and other actions. Right-click empty space to create a folder or a common file type. Compress to ZIP creates a ZIP archive. Extract Archive handles ZIP, TAR, common compressed TAR formats, GZIP and BZIP2. For other formats, use Open With; Other… lets you select an application manually. Right-click an application and choose Show Package Contents to browse inside it.")),
        HelpTopic(title: L10n.tr("Preview files"), symbol: "eye",
                  text: L10n.tr("Select a file or folder and press Space. Press Space or Escape again to close the preview. Built-in enhanced previews support folders, ZIP archives, common text and source files, Markdown, JSON and property lists. Images, PDFs and media use system Quick Look. Preview support for these built-in formats does not require Looq. Large inputs have preview limits.")),
        HelpTopic(title: L10n.tr("Trash and folder access"), symbol: "trash",
                  text: L10n.tr("Trash in the sidebar opens in the active pane. Use Move Out… to choose a recovery folder. Empty Trash… permanently deletes the contents of the displayed disk’s Trash after confirmation. If access is denied, add the installed Filetor Pro app in System Settings → Privacy & Security → Full Disk Access, enable it, then fully quit and reopen the app.")),
        HelpTopic(title: L10n.tr("Updates and feedback"), symbol: "bubble.left.and.bubble.right",
                  text: L10n.tr("Choose Filetor Pro → Check for Updates… to install a published update. Settings includes Automatically check for and install updates. Help → Release Notes shows what changed. Report an Issue… and Suggest a Feature… open a GitHub draft containing the app and macOS versions. A GitHub account and internet connection are needed to submit it; opening the draft does not submit feedback. File contents, paths and logs are not attached automatically."))
    ]
}

@Observable
final class HelpState {
    enum Page: String, CaseIterable, Identifiable {
        case guide = "User Guide", shortcuts = "Keyboard Shortcuts"
        var id: Self { self }
    }
    var page: Page = .guide
    var query = ""
    var search: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var topics: [HelpTopic] { HelpContent.topics.filter { $0.matches(search) } }
    var shortcutGroups: [ShortcutGroup] {
        Shortcuts.groups.compactMap { group in
            let entries = group.entries.filter {
                search.isEmpty || (L10n.key(group.title) + " " + L10n.key($0.name) + " " + $0.keys).localizedCaseInsensitiveContains(search)
            }
            return entries.isEmpty ? nil : ShortcutGroup(title: group.title, entries: entries)
        }
    }
}

/// A single native help window, available even with no workspace open.
final class HelpCenter {
    static let shared = HelpCenter()
    let state = HelpState()
    private(set) var window: NSWindow?

    func show(_ page: HelpState.Page = .guide) {
        state.page = page
        state.query = ""
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = L10n.tr("Filetor Pro Help")
            window.identifier = NSUserInterfaceItemIdentifier("filetor-help")
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.contentMinSize = NSSize(width: 580, height: 420)
            window.contentView = NSHostingView(rootView: HelpView(state: state))
            window.center()
            self.window = window
        }
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct HelpView: View {
    @Bindable var state: HelpState

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                        .resizable().frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.tr("Filetor Pro Help")).font(.title2.bold())
                        Text(L10n.tr("Guides and shortcuts for everyday file management.")).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                HStack(spacing: 16) {
                    Picker(L10n.tr("Help section"), selection: $state.page) {
                        ForEach(HelpState.Page.allCases) { Text(L10n.key($0.rawValue)).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 290)
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(L10n.tr("Search help"), text: $state.query).textFieldStyle(.plain)
                            .accessibilityIdentifier("help-search")
                        if !state.query.isEmpty {
                            Button { state.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).help(L10n.tr("Clear Search"))
                                .accessibilityLabel(L10n.tr("Clear Search"))
                        }
                    }.padding(7).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                }
            }.padding(22)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if state.page == .guide {
                        ForEach(state.topics) { topic in
                            GroupBox {
                                VStack(alignment: .leading, spacing: 9) {
                                    Label(topic.title, systemImage: topic.symbol).font(.headline)
                                    Text(topic.text).foregroundStyle(.secondary).lineSpacing(3).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }.padding(8)
                            }
                        }
                    } else {
                        ForEach(state.shortcutGroups) { group in
                            GroupBox(L10n.key(group.title)) {
                                VStack(spacing: 10) {
                                    ForEach(Array(group.entries.enumerated()), id: \.offset) { _, entry in
                                        HStack {
                                            Text(L10n.key(entry.name))
                                            Spacer()
                                            Text(entry.keys).foregroundStyle(.secondary).monospaced()
                                        }
                                    }
                                }.padding(8).textSelection(.enabled)
                            }
                        }
                    }
                    if state.page == .guide ? state.topics.isEmpty : state.shortcutGroups.isEmpty {
                        ContentUnavailableView.search(text: state.search)
                            .frame(maxWidth: .infinity, minHeight: 180)
                    }
                }.padding(22)
            }.id(state.page)
            Divider()
            HStack {
                Text(L10n.tr("Filetor Pro \(ProductInfo.version)")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("Report an Issue…")) { SupportLink.issue.openInBrowser() }
                Button(L10n.tr("Copy App Information")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(SupportLink.appInformation, forType: .string)
                }.help(L10n.tr("Copy the app and macOS versions for a support request"))
            }.padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
