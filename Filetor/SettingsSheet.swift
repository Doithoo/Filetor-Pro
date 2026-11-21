import SwiftUI
import ServiceManagement

/// Standard macOS controls, grouped without changing existing preference identities.
struct SettingsSheet: View {
    let app: AppModel
    @Environment(\.closePanel) private var dismiss
    enum Page: String, CaseIterable, Identifiable {
        case general = "General", appearance = "Appearance", browsing = "Browsing"
        case window = "Window & Toolbar", updates = "Updates", access = "Folder Access", about = "About"
        var id: Self { self }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .appearance: "paintpalette"
            case .browsing: "list.bullet"
            case .window: "macwindow"
            case .updates: "arrow.down.circle"
            case .access: "folder.badge.gearshape"
            case .about: "info.circle"
            }
        }
    }
    @State var page: Page = .general
    @AppStorage("appearance") private var appearance = 0
    @AppStorage("accent") private var accent = 0
    @AppStorage("textSize") private var textSize = 1
    @AppStorage("listRowHeight") private var listRowHeight = 25.0
    @AppStorage("gridIconSize") private var gridIconSize = 52.0
    @AppStorage("showExtensions") private var showExtensions = true
    @AppStorage("iconPreviews") private var iconPreviews = false
    @AppStorage("striped") private var striped = true
    @AppStorage("foldersFirst") private var foldersFirst = true
    @AppStorage("calculateFolderSizes") private var calcFolderSizes = false
    @AppStorage("statusBar") private var statusBar = true
    @AppStorage("startDual") private var startDual = true
    @AppStorage("showSidebar") private var showSidebar = true
    @AppStorage("showHidden") private var showHidden = false
    @State private var loginError: String?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    static let accents: [Color] = [.blue, .purple, Color(red: 1.0, green: 0.16, blue: 0.67), .red, .orange, .green, .gray]
    static let sizeNames = ["S", "M", "L", "XL", "Turbo"]
    private var s: CGFloat { UIScale.value(textSize) }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Page.allCases) { item in
                            Button { page = item } label: {
                                Label(item.rawValue, systemImage: item.symbol)
                                    .font(.system(size: 13, weight: page == item ? .semibold : .regular))
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10).padding(.vertical, 9)
                                    .contentShape(Rectangle())
                                    .background(page == item ? Color.accentColor.opacity(0.16) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(page == item ? .isSelected : [])
                        }
                    }.padding(8)
                }
                .frame(width: min(190, geometry.size.width * 0.32))
                .background(Color(nsColor: .controlBackgroundColor))
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text(page.rawValue).font(.title2.bold())
                    Form { pageContent }
                        .formStyle(.grouped)
                    HStack {
                        Spacer()
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: min(740, max(450, (NSApp.keyWindow?.contentLayoutRect.width ?? 850) - 40)),
               height: min(560, max(320, (NSApp.keyWindow?.contentLayoutRect.height ?? 700) - 60)))
        .background(Color(nsColor: .windowBackgroundColor))
        .background { Button("") { dismiss() }.keyboardShortcut(.cancelAction).hidden() }
        .onAppear { DisplayPreferences.migrate() }
        .onChange(of: showHidden) { _, value in app.setHidden(value) }
        .onChange(of: calcFolderSizes) { _, _ in app.reloadPanes() }
    }

    @ViewBuilder private var pageContent: some View {
        @Bindable var toolbar = app.toolbarModel
        @Bindable var model = app
        switch page {
        case .general:
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                            loginError = error.localizedDescription
                        }
                    }
                if let loginError { Text(loginError).foregroundStyle(.secondary) }
                Toggle("Open new windows with two panes", isOn: $startDual)
                Toggle("Show hidden files", isOn: $showHidden)
            }
        case .appearance:
            Section {
                Picker("Appearance", selection: $appearance) {
                    Text("Light").tag(0); Text("Dark").tag(1); Text("Auto").tag(2)
                }
                Picker("Accent colour", selection: $accent) {
                    ForEach(Array(["Blue", "Purple", "Pink", "Red", "Orange", "Green", "Grey"].enumerated()), id: \.offset) { i, title in
                        Text(title).tag(i)
                    }
                }.onChange(of: accent) { _, value in AccentStore.shared.index = value }
                Picker("Text size", selection: $textSize) {
                    ForEach(Array(Self.sizeNames.enumerated()), id: \.offset) { i, name in Text(name).tag(i) }
                }
            }
        case .browsing:
            Section("Size") {
                Slider(value: $listRowHeight, in: 20...56, step: 1) {
                    Text("List row height: \(Int(listRowHeight))")
                }
                Slider(value: $gridIconSize, in: 32...128, step: 4) {
                    Text("Grid icon size: \(Int(gridIconSize))")
                }
            }
            Section("Files") {
                Toggle("Show file extensions", isOn: $showExtensions)
                Toggle("Show file thumbnails", isOn: $iconPreviews)
                Text("Thumbnails load as files become visible. Space still opens system Quick Look.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Alternating row colours", isOn: $striped)
                Toggle("Keep folders on top", isOn: $foldersFirst)
                Toggle("Calculate all folder sizes", isOn: $calcFolderSizes)
            }
        case .window:
            Section {
                Toggle("Show item count and free space", isOn: $statusBar)
                Toggle("Show sidebar", isOn: $showSidebar)
                Toggle("Show info panel", isOn: $model.showInfo)
            }
            Section("Toolbar") {
                Toggle("Show labels", isOn: $toolbar.showLabels)
                    .onChange(of: toolbar.showLabels) { _, _ in app.toolbarModel.save() }
                Button("Customize Toolbar…") {
                    dismiss()
                    DispatchQueue.main.async { app.showCustomize = true }
                }
            }
        case .updates:
            Section {
                Toggle("Automatically check for and install updates", isOn: Binding(
                    get: { app.updater.automaticallyUpdates }, set: { app.updater.setAutomaticUpdates($0) }))
                Text("Updates download in the background and install when you quit. You can also check and install now.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Check for updates…") { app.updater.check() }.disabled(!app.updater.canCheck)
                Text(app.updater.message).foregroundStyle(.secondary)
                if let date = app.updater.lastCheck {
                    Text("Last checked: \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .access:
            Section { FolderAccessBox(scale: min(s, 1.2)) }
        case .about:
            Section {
                Text("\(ProductInfo.name) \(ProductInfo.version)").font(.headline)
                Text(Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? "")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Project on GitHub", destination: URL(string: "https://github.com/\(UpdateChecker.repo)")!)
                Link("Release notes", destination: URL(string: "https://github.com/\(UpdateChecker.repo)/releases")!)
            }
        }
    }
}
