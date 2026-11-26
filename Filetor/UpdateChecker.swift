import SwiftUI
import Observation
import Combine
import Sparkle

/// One native updater for the application, shared by every window.
@Observable
final class UpdateChecker: NSObject, SPUUpdaterDelegate {
    enum State: Equatable {
        case idle, checking, upToDate, downloading, readyOnQuit, installing, waitingForOperations
        case available(version: String)
        case failed(String)
    }

    static let shared = UpdateChecker()
    static let repo = "Doithoo/Filetor-Pro"
    static let feedURL = "https://github.com/\(repo)/releases/latest/download/appcast.xml"
    private(set) var state: State = .idle
    private(set) var canCheck = false
    private(set) var automaticUpdates: AutomaticUpdateSettings?
    var automaticallyUpdates: Bool { automaticUpdates?.isEnabled ?? true }
    private(set) var lastCheck: Date?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var subscriptions = Set<AnyCancellable>()
    @ObservationIgnored private var relaunchTask: Task<Void, Never>?

    var isAvailable: Bool {
        if case .available = state { return true }
        return false
    }

    var installed: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Called once by the application, never from each window or from model tests.
    func start() {
        guard controller == nil else { return }
        AutomaticUpdateSettings.migratePreferences(UserDefaults.standard)
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).sink { [weak self] in self?.canCheck = $0 }.store(in: &subscriptions)
        automaticUpdates = AutomaticUpdateSettings(updater: updater)
        updater.publisher(for: \.lastUpdateCheckDate).sink { [weak self] in self?.lastCheck = $0 }.store(in: &subscriptions)
        do { try updater.start() }
        catch { state = .failed(error.localizedDescription) }
    }

    func setAutomaticUpdates(_ value: Bool) { automaticUpdates?.setEnabled(value) }

    func check() {
        start()
        guard canCheck else { return }
        state = .checking
        controller?.checkForUpdates(nil)
    }

    // Keep this release channel fixed even if a stale defaults value names another feed.
    func feedURLString(for updater: SPUUpdater) -> String? { Self.feedURL }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        state = .available(version: item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let error = error as NSError
        if let item = error.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem,
           !item.minimumOperatingSystemVersionIsOK || !item.arm64HardwareRequirementIsOK {
            state = .failed(L10n.tr("The latest release requires a newer macOS version or different hardware."))
        } else { state = .upToDate }
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        state = .downloading
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        AppModel.saveAllWorkspaces()
        state = .installing
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        state = .readyOnQuit
        return false // Let Sparkle install on a normal quit, or offer a user-initiated restart.
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard AppModel.hasActiveFileOperations else {
            AppModel.saveAllWorkspaces()
            return false
        }
        state = .waitingForOperations
        relaunchTask?.cancel()
        relaunchTask = Task { [weak self] in
            while AppModel.hasActiveFileOperations {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            AppModel.saveAllWorkspaces()
            self?.state = .installing
            installHandler()
        }
        return true
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) { AppModel.saveAllWorkspaces() }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        relaunchTask?.cancel()
        let nsError = error as NSError
        if nsError.domain == SUSparkleErrorDomain && nsError.code == SUError.noUpdateError.rawValue { return }
        state = .failed(error.localizedDescription)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if error == nil, state == .checking { state = .idle }
    }

    var message: String {
        switch state {
        case .idle: return L10n.tr("Updates from the Filetor Pro release channel.")
        case .checking: return L10n.tr("Checking for updates…")
        case .upToDate: return L10n.tr("\(ProductInfo.name) is up to date.")
        case .available(let version): return L10n.tr("Version \(version) is available.")
        case .downloading: return L10n.tr("Downloading and verifying the update…")
        case .readyOnQuit: return L10n.tr("Update ready. It will install when you quit.")
        case .installing: return L10n.tr("Preparing to install and restart…")
        case .waitingForOperations: return L10n.tr("Waiting for file operations to finish before restarting…")
        case .failed(let message): return message
        }
    }
}
