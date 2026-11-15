import Foundation

/// The two places the app and its AutoFill extension both reach: the App
/// Group's container and the keychain group, whose name carries the team's
/// prefix and so is read from the bundle at run time.
enum Shared {
    static let appGroup = "group.com.meric.oripass"

    static var keychainGroup: String {
        Bundle.main.object(forInfoDictionaryKey: "OPKeychainGroup") as? String ?? "com.meric.oripass.shared"
    }

    /// Nil only where the entitlement is missing, which is a build that is
    /// not this app's.
    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
