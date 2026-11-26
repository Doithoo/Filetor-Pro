import SwiftUI
import AppKit

/// Privacy grants belong to the running code identity, not just the displayed app name.
enum FolderAccess {
    /// The system TCC database can only be opened by an app that has Full Disk Access.
    static var hasFullDiskAccess: Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return false
    }

    enum Status { case on, lost, off }

    private static let hadKey = "hadFullDiskAccess"

    /// `lost`: A previous probe succeeded, but access no longer applies to this running process.
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

    static func revealCurrentApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    static var trashAccessExplanation: String {
        if hasFullDiskAccess {
            return L10n.tr("macOS denied access to this Trash folder even though the Full Disk Access probe succeeded. Check this disk’s availability and folder permissions, then retry.")
        }
        return L10n.tr("macOS is not applying Full Disk Access to this running copy. If Filetor Pro is already enabled in System Settings, remove that entry and add the current app again, then quit and reopen it. Reveal Current App locates the exact copy to add.")
    }

    /// Written by the actual GUI process, so diagnosis does not confuse a
    /// terminal's permissions with the installed application's privacy grants.
    /// Records no filenames, folder contents, or private TCC database contents.
    static func recordDiagnostics() {
        let fullDiskAccess = hasFullDiskAccess
        let trash = TrashLocation.home
        Task {
            let result = await Task.detached(priority: .utility) {
                Result { _ = try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) }
            }.value
            var report: [String: Any] = [
                "checkedAt": ISO8601DateFormatter().string(from: Date()),
                "applicationPath": Bundle.main.bundleURL.path,
                "version": ProductInfo.version,
                "pid": ProcessInfo.processInfo.processIdentifier,
                "fullDiskAccessProbe": fullDiskAccess
            ]
            switch result {
            case .success: report["homeTrashReadable"] = true
            case .failure(let error):
                let ns = error as NSError
                report["homeTrashReadable"] = false
                report["errorDomain"] = ns.domain
                report["errorCode"] = ns.code
                if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                    report["underlyingDomain"] = underlying.domain
                    report["underlyingCode"] = underlying.code
                }
            }
            let directory = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support/Filetor Pro/Diagnostics")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: directory.appending(path: "folder-access.json"), options: .atomic)
            } catch { /* Diagnostics must not interrupt browsing. */ }
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
                HStack {
                    Button(L10n.tr("Open Privacy Settings")) { FolderAccess.openPrivacySettings() }
                    Button(L10n.tr("Reveal Current App")) { FolderAccess.revealCurrentApplication() }
                }
                .buttonStyle(PathsButtonStyle(scale: s))
                .padding(.top, 4 * s)
            }
        }
        .padding(12 * s)
        .background(RoundedRectangle(cornerRadius: 8 * s).strokeBorder(Color.primary.opacity(0.12)))
        .onAppear { status = FolderAccess.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = FolderAccess.status
        }
    }

    private var title: String {
        switch status {
        case .on: return L10n.tr("Full Disk Access is on")
        case .lost: return L10n.tr("Full Disk Access needs to be set again")
        case .off: return L10n.tr("macOS asks for each folder separately")
        }
    }

    private var detail: String {
        switch status {
        case .on: return L10n.tr("\(ProductInfo.name) passed the Full Disk Access probe. File permissions and disk availability still apply.")
        case .lost: return L10n.tr("\(ProductInfo.name) previously had access, but macOS is not applying it to this running copy. Older temporary signatures can leave a stale enabled entry.")
        case .off: return L10n.tr("Full Disk Access allows access to privacy-protected locations, including Trash. It does not override file permissions.")
        }
    }

    private var action: String? {
        switch status {
        case .on: return nil
        case .lost: return L10n.tr("Open Privacy Settings, remove \(ProductInfo.name) from the list, use Reveal Current App to add this exact copy again and restart \(ProductInfo.name).")
        case .off: return L10n.tr("Open Privacy Settings, add this exact copy using Reveal Current App and restart \(ProductInfo.name).")
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
            Text(L10n.tr("Allow access to your folders")).font(.system(size: 22 * s))
            Text(L10n.tr("macOS may request permission when \(ProductInfo.name) opens Desktop, Documents, Downloads, an external disk or a network disk."))
            Text(L10n.tr("To stop the prompts, add \(ProductInfo.name) to **Full Disk Access**: click Open Privacy Settings, add this exact copy using Reveal Current App and restart \(ProductInfo.name)."))
            Button(L10n.tr("Reveal Current App")) { FolderAccess.revealCurrentApplication() }
                .buttonStyle(PathsButtonStyle(scale: s))
            Text(L10n.tr("Your files stay on your Mac. Update checks contact GitHub; file contents are not uploaded. You can change folder access later in Settings."))
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Spacer()
                Button(L10n.tr("Not now")) { dismiss() }
                    .buttonStyle(PathsButtonStyle(scale: s))
                    .keyboardShortcut(.cancelAction)
                Button(L10n.tr("Open Privacy Settings")) {
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
