import Combine
import Observation
import Sparkle

/// One preference for the complete automatic check, download and install cycle.
@Observable
final class AutomaticUpdateSettings {
    private(set) var isEnabled: Bool
    @ObservationIgnored private let updater: SPUUpdater
    @ObservationIgnored private var subscriptions = Set<AnyCancellable>()
    @ObservationIgnored private var applying = false

    init(updater: SPUUpdater) {
        self.updater = updater
        isEnabled = updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
        // Sparkle's own update dialog can also change these preferences.
        // Keep both settings aligned, without reacting to intermediate writes.
        updater.publisher(for: \.automaticallyChecksForUpdates, options: [.new])
            .sink { [weak self] in self?.setEnabled($0) }.store(in: &subscriptions)
        updater.publisher(for: \.automaticallyDownloadsUpdates, options: [.new])
            .sink { [weak self] in self?.setEnabled($0) }.store(in: &subscriptions)
    }

    func setEnabled(_ enabled: Bool) {
        guard !applying else { return }
        applying = true
        defer { applying = false }
        // Sparkle only accepts download preference changes while checks are on.
        if enabled {
            updater.automaticallyChecksForUpdates = true
            updater.automaticallyDownloadsUpdates = true
        } else {
            updater.automaticallyDownloadsUpdates = false
            updater.automaticallyChecksForUpdates = false
        }
        isEnabled = updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
    }

    static func migratePreferences(_ defaults: UserDefaults) {
        let key = "unifiedAutomaticUpdatesMigrated.v1"
        guard !defaults.bool(forKey: key) else { return }
        // The previous check preference determines the new combined switch.
        // Respect opt-outs, including the original legacy preference.
        let enabled = defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool
            ?? defaults.object(forKey: "autoUpdate") as? Bool ?? true
        defaults.set(enabled, forKey: "SUEnableAutomaticChecks")
        defaults.set(enabled, forKey: "SUAutomaticallyUpdate")
        defaults.set(true, forKey: key)
    }
}
