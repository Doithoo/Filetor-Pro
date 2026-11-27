import AppKit

/// Mouse-down acknowledges input; the separate result cue acknowledges a completed job.
@MainActor final class InteractionFeedback {
    enum Cue: String, CaseIterable {
        case click = "FiletorClick", transfer = "FiletorTransfer", removal = "FiletorRemoval"

        func loadSound() -> NSSound? {
            let bundle = Bundle.main
            let url = bundle.url(forResource: rawValue, withExtension: "wav")
                ?? bundle.url(forResource: rawValue, withExtension: "wav", subdirectory: "Sounds")
                ?? bundle.bundleURL.appending(path: "Resources/\(rawValue).wav")
            return NSSound(contentsOf: url, byReference: false)
        }
    }

    static let clickKey = "feedback.mouseClicks"
    static let operationsKey = "feedback.fileOperations"
    static let shared: InteractionFeedback = {
        var sounds: [Cue: NSSound] = [:]
        return InteractionFeedback(defaults: .standard) { cue in
            guard let sound = sounds[cue] ?? cue.loadSound() else { return }
            sounds[cue] = sound
            if sound.isPlaying { sound.stop() }
            sound.volume = cue == .click ? 0.33 : 0.48
            sound.play()
        }
    }()

    private let defaults: UserDefaults
    private let playback: (Cue) -> Void
    private var monitor: Any?
    init(defaults: UserDefaults, playback: @escaping (Cue) -> Void) {
        self.defaults = defaults
        self.playback = playback
    }

    func play(_ cue: Cue) {
        let key = cue == .click ? Self.clickKey : Self.operationsKey
        if defaults.object(forKey: key) as? Bool ?? true { playback(cue) }
    }

    func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.window != nil { self?.play(.click) }
            return event
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
