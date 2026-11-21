import AppKit
import Sparkle

/// Executed only in temporary fixture apps by test-updater.py.
@main
struct UpdateProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let driver = ProbeDriver()
        app.delegate = driver
        app.run()
        withExtendedLifetime(driver) {}
    }
}

final class ProbeDriver: NSObject, NSApplicationDelegate, SPUUserDriver, SPUUpdaterDelegate {
    var updater: SPUUpdater!
    private let info = Bundle.main.infoDictionary!
    private var logURL: URL { URL(fileURLWithPath: info["ProbeLog"] as! String) }

    func log(_ message: String) {
        let line = Data((message + "\n").utf8)
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        if let file = try? FileHandle(forWritingTo: logURL) {
            _ = try? file.seekToEnd()
            try? file.write(contentsOf: line)
            try? file.close()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if info["CFBundleVersion"] as? String == "2" {
            log(UserDefaults.standard.string(forKey: "toolbar.fixture") == "customized toolbar survives update" ? "INSTALLED_PREFERENCES_PRESERVED" : "PREFERENCES_LOST")
            NSApp.terminate(nil)
            return
        }
        UserDefaults.standard.set("customized toolbar survives update", forKey: "toolbar.fixture")
        UserDefaults.standard.synchronize()
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        do {
            try updater.start()
            updater.checkForUpdates()
        } catch {
            log("START_ERROR: \(error)")
            NSApp.terminate(nil)
        }
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { log("CHECKING") }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        log("FOUND: \(appcastItem.versionString)")
        reply(.install)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { log("NOTES_ERROR: \(error)") }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        log("NO_UPDATE")
        acknowledgement()
        NSApp.terminate(nil)
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let ns = error as NSError
        log("UPDATE_ERROR: \(ns.domain):\(ns.code) \(ns.localizedDescription)")
        acknowledgement()
        NSApp.terminate(nil)
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { log("DOWNLOADING") }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() { log("EXTRACTING") }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        log("READY")
        reply(.install)
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) { log("INSTALLING") }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        log("FINISHED: \(relaunched)")
        acknowledgement()
    }
    func dismissUpdateInstallation() { log("DISMISSED") }
}
