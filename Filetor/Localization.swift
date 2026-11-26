import Foundation

/// Keep translated presentation separate from persisted identifiers and user data.
nonisolated enum L10n {
    enum Language: String, CaseIterable, Identifiable {
        case system, english = "en", simplifiedChinese = "zh-Hans"
        var id: Self { self }
        var title: String {
            switch self {
            case .system: L10n.tr("Follow System")
            case .english: "English"
            case .simplifiedChinese: "简体中文"
            }
        }
    }

    static let preferenceKey = "interfaceLanguage"
    static func selection(in defaults: UserDefaults = .standard) -> Language {
        Language(rawValue: defaults.string(forKey: preferenceKey) ?? "system") ?? .system
    }

    /// AppleLanguages is app-scoped; this also lets AppKit and Sparkle choose the
    /// same language at the next launch without changing the system language.
    static func save(_ language: Language, in defaults: UserDefaults = .standard) {
        defaults.set(language.rawValue, forKey: preferenceKey)
        if language == .system { defaults.removeObject(forKey: "AppleLanguages") }
        else { defaults.set([language.rawValue], forKey: "AppleLanguages") }
    }

    static func resolve(_ preferences: [String]) -> String {
        Bundle.preferredLocalizations(from: ["en", "zh-Hans"], forPreferences: preferences).first ?? "en"
    }

    static let launchSelection = selection()
    static let language = resolve(UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? Locale.preferredLanguages)

    static func resourceBundle(for language: String) -> Bundle? {
        if let path = Bundle.main.path(forResource: language, ofType: "lproj") { return Bundle(path: path) }
        // The command-line regression runner carries the same bundled resources.
        let resources = Bundle.main.bundleURL.appending(path: "Resources/\(language).lproj")
        return Bundle(url: resources)
    }

    private static let bundle = resourceBundle(for: language)

    static func key(_ key: String) -> String {
        bundle?.localizedString(forKey: key, value: key, table: nil) ?? key
    }

    /// Typed interpolation keeps user filenames and paths out of translation keys.
    struct Message: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
        let key: String
        let arguments: [String]
        init(stringLiteral value: String) { key = value; arguments = [] }
        init(stringInterpolation: StringInterpolation) {
            key = stringInterpolation.key; arguments = stringInterpolation.arguments
        }
        struct StringInterpolation: StringInterpolationProtocol {
            var key = ""
            var arguments: [String] = []
            init(literalCapacity: Int, interpolationCount: Int) {
                key.reserveCapacity(literalCapacity)
                arguments.reserveCapacity(interpolationCount)
            }
            mutating func appendLiteral(_ literal: String) { key += literal }
            mutating func appendInterpolation<T>(_ value: T) {
                key += "{\(arguments.count)}"
                arguments.append(String(describing: value))
            }
        }
    }

    static func tr(_ message: Message) -> String { render(key(message.key), arguments: message.arguments) }

    /// Replace placeholders in one pass, never re-interpreting an inserted value.
    static func render(_ template: String, arguments: [String]) -> String {
        var result = "", index = template.startIndex
        while index < template.endIndex {
            if template[index] == "{", let end = template[index...].firstIndex(of: "}"),
               let slot = Int(template[template.index(after: index)..<end]), arguments.indices.contains(slot) {
                result += arguments[slot]
                index = template.index(after: end)
            } else {
                result.append(template[index]); index = template.index(after: index)
            }
        }
        return result
    }
}
