import Foundation

/// What the bundle says about itself, in one place.
enum AppInfo {
    static let name = "OriPass"

    /// The defaults domain, the log subsystem and the Application Support
    /// folder all hang off this, so the fallback is the real value rather than
    /// a placeholder.
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.meric.oripass"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}
