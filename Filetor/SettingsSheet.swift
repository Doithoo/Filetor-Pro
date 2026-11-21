import SwiftUI
import ServiceManagement

struct SettingsSheet: View {
    let app: AppModel
    @Environment(\.closePanel) private var dismiss

    @AppStorage("appearance") private var appearance = 0
    @AppStorage("accent") private var accent = 0
    @AppStorage("textSize") private var textSize = 1
    @AppStorage("compactRows") private var compactRows = false
    @AppStorage("striped") private var striped = true
    @AppStorage("foldersFirst") private var foldersFirst = true
    @AppStorage("calculateFolderSizes") private var calcFolderSizes = false
    @AppStorage("statusBar") private var statusBar = true
    @AppStorage("startDual") private var startDual = true
    @AppStorage("showSidebar") private var showSidebar = true
    @AppStorage("showHidden") private var showHidden = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    static let accents: [Color] = [.blue, .purple, Color(red: 1.0, green: 0.16, blue: 0.67), .red, .orange, .green, .gray]
    static let sizeNames = ["S", "M", "L", "XL", "Turbo"]

    private var s: CGFloat { UIScale.value(textSize) }

    private var aboutLine: String { "\(ProductInfo.name) \(ProductInfo.version)" }
    private var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
    }

    var body: some View {
        ScrollView(.vertical) {
            settingsContent
        }
        .frame(width: 570 * s, height: min(840 * s, max(320, (NSApp.keyWindow?.contentLayoutRect.height ?? 800) - 50)))
    }

    @ViewBuilder private var settingsContent: some View {
        @Bindable var tb = app.toolbarModel
        @Bindable var am = app
        let w = 340 * s   // width of the control column; Done aligns to its right edge

        VStack(alignment: .leading, spacing: 20) {
            Text("Settings").font(.system(size: 22 * s))

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 28, verticalSpacing: 16) {
                GridRow {
                    Text("Appearance")
                    SegmentedChoice(options: ["Light", "Dark", "Auto"], selection: $appearance, scale: s)
                }
                GridRow {
                    Text("Accent colour")
                    HStack(spacing: 12) {
                        ForEach(Array(Self.accents.enumerated()), id: \.offset) { i, color in
                            Circle()
                                .fill(color)
                                .frame(width: 22 * s, height: 22 * s)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(accent == i ? 0.9 : 0), lineWidth: 2).padding(-4))
                                .onTapGesture { accent = i; AccentStore.shared.index = i }
                        }
                    }
                }
                GridRow {
                    Text("Text size")
                    SegmentedChoice(options: Self.sizeNames, selection: $textSize, scale: s, width: w)
                }
                GridRow(alignment: .firstTextBaseline) {
                    Text("Rows")
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Compact rows", isOn: $compactRows)
                        Toggle("Alternating row colours", isOn: $striped)
                        Toggle("Keep folders on top", isOn: $foldersFirst)
                        Toggle("Calculate all folder sizes", isOn: $calcFolderSizes)
                            .onChange(of: calcFolderSizes) { _, _ in app.reloadPanes() }
                    }
                }
                GridRow(alignment: .firstTextBaseline) {
                    Text("Window")
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Show item count and free space", isOn: $statusBar)
                        Toggle("Open with two panes", isOn: $startDual)
                        Toggle("Show sidebar", isOn: $showSidebar)
                        Toggle("Show info panel", isOn: $am.showInfo)
                    }
                }
                GridRow {
                    Text("Toolbar")
                    HStack(spacing: 14) {
                        Button("Customize Toolbar…") {
                            dismiss()
                            DispatchQueue.main.async { app.showCustomize = true }
                        }
                        .buttonStyle(PathsButtonStyle(scale: s))
                        Toggle("Show labels", isOn: $tb.showLabels)
                            .onChange(of: tb.showLabels) { _, _ in app.toolbarModel.save() }
                    }
                }
                GridRow {
                    Text("Hidden files")
                    Toggle("Show hidden files", isOn: $showHidden)
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Button("Done") { dismiss() }
                        .buttonStyle(PathsButtonStyle(scale: s, prominent: true))
                        .keyboardShortcut(.defaultAction)
                        .background { Button("") { dismiss() }.keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0) }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { app.updater.automaticallyChecks },
                    set: { app.updater.setAutomaticChecks($0) }
                ))
                Toggle("Download updates automatically", isOn: Binding(
                    get: { app.updater.automaticallyDownloads },
                    set: { app.updater.setAutomaticDownloads($0) }
                ))
                .disabled(!app.updater.automaticallyChecks)
                Text("Updates come from the Filetor Pro release channel. Your settings are kept.")
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("Check for updates…") { app.updater.check() }
                        .buttonStyle(PathsButtonStyle(scale: s))
                        .disabled(!app.updater.canCheck)
                    Text(app.updater.message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 300 * s, alignment: .leading)
                }
                if let date = app.updater.lastCheck {
                    Text("Last checked: \(date.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8 * s) {
                Text("Folder access").fontWeight(.semibold)
                FolderAccessBox(scale: s)
            }
            Divider()
            VStack(alignment: .leading, spacing: 9 * s) {
                Text(aboutLine).fontWeight(.semibold)
                if !copyright.isEmpty { Text(copyright).foregroundStyle(.secondary) }
                HStack {
                    Link("github.com/\(UpdateChecker.repo)", destination: URL(string: "https://github.com/\(UpdateChecker.repo)")!)
                    Spacer(minLength: 14)
                    Link("Release notes", destination: URL(string: "https://github.com/\(UpdateChecker.repo)/releases")!)
                }
            }
        }
        .toggleStyle(PathsCheckboxStyle(scale: s))
        .font(.system(size: 13 * s))
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: showHidden) { _, v in app.setHidden(v) }
    }
}
