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

    enum Status { case on, lost, off }

    private static let hadKey = "hadFullDiskAccess"

    /// `lost`: Filetor had the access before, but macOS no longer applies it (a new build has a new signature).
    static var status: Status {
        if hasFullDiskAccess {
            UserDefaults.standard.set(true, forKey: hadKey)
            return .on
        }
        return UserDefaults.standard.bool(forKey: hadKey) ? .lost : .off
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    private static let askedKey = "folderAccessAsked"

    /// Shows the notice once, and only when the access is not on yet.
    @MainActor static func askOnFirstLaunch(_ app: AppModel) {
        guard status != .on, !UserDefaults.standard.bool(forKey: askedKey) else { return }
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
    @State private var status = FolderAccess.status

    var body: some View {
        let s = scale
        VStack(alignment: .leading, spacing: 6 * s) {
            HStack(spacing: 7 * s) {
                Circle().fill(status == .on ? Color.green : Color.orange).frame(width: 8 * s, height: 8 * s)
                Text(title)
            }
            Text(detail)
                .foregroundStyle(.secondary)
                .frame(width: 400 * s, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Text(action)
                    .fontWeight(.semibold)
                    .frame(width: 400 * s, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if status != .on {
                Button("Open Privacy Settings") { FolderAccess.openPrivacySettings() }
                    .buttonStyle(PathsButtonStyle(scale: s))
                    .padding(.top, 4 * s)
            }
        }
        .padding(12 * s)
        .background(RoundedRectangle(cornerRadius: 8 * s).strokeBorder(Color.primary.opacity(0.12)))
        .onAppear { status = FolderAccess.status }
    }

    private var title: String {
        switch status {
        case .on: return "Full Disk Access is on"
        case .lost: return "Full Disk Access needs to be set again"
        case .off: return "macOS asks for each folder separately"
        }
    }

    private var detail: String {
        switch status {
        case .on: return "Filetor can open all folders without asking."
        case .lost: return "Filetor had Full Disk Access, but macOS drops it after an update."
        case .off: return "Full Disk Access stops the prompts for Desktop, Documents, Downloads, external and network disks."
        }
    }

    private var action: String? {
        switch status {
        case .on: return nil
        case .lost: return "Open Privacy Settings, remove Filetor from the list, drag Filetor.app in again and restart Filetor."
        case .off: return "Open Privacy Settings, drag Filetor.app into the list and restart Filetor."
        }
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
            Text("To stop the prompts, add Filetor to **Full Disk Access**: click Open Privacy Settings, drag Filetor.app into the list and restart Filetor.")
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
