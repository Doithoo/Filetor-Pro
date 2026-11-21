import Foundation

enum DisplayPreferences {
    /// Preserve the actual old density, rather than replacing it with a new default.
    static func migrate(_ defaults: UserDefaults = .standard) {
        if defaults.object(forKey: "listRowHeight") == nil {
            defaults.set(defaults.bool(forKey: "compactRows") ? 20.0 : 25.0, forKey: "listRowHeight")
        }
    }

    static func rowHeight(_ value: Double) -> CGFloat {
        CGFloat(value.isFinite ? min(max(value, 20), 56) : 25)
    }

    static func iconSize(rowHeight: CGFloat) -> CGFloat { min(max(rowHeight - 8, 17), 40) }
}

nonisolated enum FileNamePresentation {
    static func display(_ name: String, directory: Bool, package: Bool, showExtension: Bool) -> String {
        guard !showExtension, !directory || package, !name.hasPrefix(".") else { return name }
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? name : base
    }

    static func preservingExtension(_ edited: String, original: String, hidden: Bool) -> String {
        guard hidden, FileOperationSafety.validName(edited) else { return edited }
        let suffix = (original as NSString).pathExtension
        guard !suffix.isEmpty, !edited.lowercased().hasSuffix("." + suffix.lowercased()) else { return edited }
        return edited + "." + suffix
    }
}
