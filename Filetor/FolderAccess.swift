import SwiftUI
import AppKit

/// Full Disk Access: the one permission that stops macOS asking for each protected folder separately.
enum FolderAccess {
    /// The system TCC database can only be opened by an app that has Full Disk Access.
    static var hasFullDiskAccess: Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return false
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    private static let askedKey = "folderAccessAsked"

    /// Shows the notice once, and only when the access is not on yet.
    @MainActor static func askOnFirstLaunch(_ app: AppModel) {
        guard !UserDefaults.standard.bool(forKey: askedKey), !hasFullDiskAccess else { return }
        UserDefaults.standard.set(true, forKey: askedKey)
        Task {
            try? await Task.sleep(for: .seconds(0.7))
            app.showFolderAccess = true
        }
    }
}

/// Status and button, shown in Settings.
struct FolderAccessBox: View {
    let scale: CGFloat
    @State private var granted = FolderAccess.hasFullDiskAccess

    var body: some View {
        let s = scale
        VStack(alignment: .leading, spacing: 6 * s) {
            HStack(spacing: 7 * s) {
                Circle().fill(granted ? Color.green : Color.orange).frame(width: 8 * s, height: 8 * s)
                Text(granted ? "Full Disk Access is on" : "macOS asks for each folder separately")
            }
            Text(granted
                 ? "Filetor can open all folders without asking."
                 : "Full Disk Access stops the prompts for Desktop, Documents, Downloads, external and network disks. Open Privacy Settings, drag Filetor.app into the list (or click + and choose it), turn it on and restart Filetor.")
                .foregroundStyle(.secondary)
                .frame(width: 400 * s, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if !granted {
                Button("Open Privacy Settings") { FolderAccess.openPrivacySettings() }
                    .buttonStyle(PathsButtonStyle(scale: s))
                    .padding(.top, 4 * s)
            }
        }
        .padding(12 * s)
        .background(RoundedRectangle(cornerRadius: 8 * s).strokeBorder(Color.primary.opacity(0.12)))
        .onAppear { granted = FolderAccess.hasFullDiskAccess }
    }
}

/// Notice shown once on the first launch.
struct FolderAccessPrompt: View {
    @Environment(\.closePanel) private var dismiss
    @AppStorage("textSize") private var textSize = 1
    private var s: CGFloat { UIScale.value(textSize) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * s) {
            Text("Allow access to your folders").font(.system(size: 22 * s))
            Text("macOS asks for permission every time Filetor opens Desktop, Documents, Downloads, an external disk or a network disk.")
            Text("To stop the prompts, add Filetor to **Full Disk Access**. Click Open Privacy Settings, drag Filetor.app into the list (or click + and choose it), turn it on and restart Filetor.")
            Text("Filetor does not send anything anywhere. You can change this later in Settings, under Folder access.")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Spacer()
                Button("Not now") { dismiss() }
                    .buttonStyle(PathsButtonStyle(scale: s))
                    .keyboardShortcut(.cancelAction)
                Button("Open Privacy Settings") {
                    FolderAccess.openPrivacySettings()
                    dismiss()
                }
                .buttonStyle(PathsButtonStyle(scale: s, prominent: true))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 10 * s)
        }
        .font(.system(size: 13 * s))
        .fixedSize(horizontal: false, vertical: true)
        .padding(28)
        .frame(width: 460 * s)
    }
}
