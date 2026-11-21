import SwiftUI
import Observation
import Combine
import Sparkle

/// One native updater for the application, shared by every window.
@Observable
final class UpdateChecker: NSObject, SPUUpdaterDelegate {
    enum State: Equatable {
        case idle, checking, upToDate, downloading, installing, waitingForOperations
        case available(version: String)
        case failed(String)
    }

    static let shared = UpdateChecker()
    static let repo = "Doithoo/Filetor"
    static let feedURL = "https://github.com/Doithoo/Filetor/releases/latest/download/appcast.xml"
    private(set) var state: State = .idle
    private(set) var canCheck = false
    private(set) var automaticallyChecks = true
    private(set) var automaticallyDownloads = false
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
        Self.migratePreferences(UserDefaults.standard)
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).sink { [weak self] in self?.canCheck = $0 }.store(in: &subscriptions)
        updater.publisher(for: \.automaticallyChecksForUpdates).sink { [weak self] in self?.automaticallyChecks = $0 }.store(in: &subscriptions)
        updater.publisher(for: \.automaticallyDownloadsUpdates).sink { [weak self] in self?.automaticallyDownloads = $0 }.store(in: &subscriptions)
        updater.publisher(for: \.lastUpdateCheckDate).sink { [weak self] in self?.lastCheck = $0 }.store(in: &subscriptions)
        do { try updater.start() }
        catch { state = .failed(error.localizedDescription) }
    }

    static func migratePreferences(_ defaults: UserDefaults) {
        // Migrate once; subsequent launches must respect changes made in Sparkle's UI.
        if defaults.object(forKey: "SUEnableAutomaticChecks") == nil,
           let legacy = defaults.object(forKey: "autoUpdate") as? Bool {
            defaults.set(legacy, forKey: "SUEnableAutomaticChecks")
        }
    }

    func setAutomaticChecks(_ value: Bool) { controller?.updater.automaticallyChecksForUpdates = value }
    func setAutomaticDownloads(_ value: Bool) { controller?.updater.automaticallyDownloadsUpdates = value }

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
            state = .failed("The latest release requires a newer macOS version or different hardware.")
        } else { state = .upToDate }
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        state = .downloading
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        AppModel.saveAllWorkspaces()
        state = .installing
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
        case .idle: return "Updates from the Filetor Pro release channel."
        case .checking: return "Checking for updates…"
        case .upToDate: return "\(ProductInfo.name) is up to date."
        case .available(let version): return "Version \(version) is available."
        case .downloading: return "Downloading and verifying the update…"
        case .installing: return "Preparing to install and restart…"
        case .waitingForOperations: return "Waiting for file operations to finish before restarting…"
        case .failed(let message): return message
        }
    }
}
