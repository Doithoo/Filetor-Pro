import Foundation

/// Product branding is independent of the stable preferences and update identity.
enum ProductInfo {
    static let name = "Filetor Pro"
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }

    // Sparkle preserves a custom installation filename when replacing an app.
    static var applicationFilename: String {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url.lastPathComponent : "\(name).app"
    }
}
