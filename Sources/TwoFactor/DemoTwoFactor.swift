import Foundation

/// The list of sites that take a one-time code for the demo vault, which
/// asks nobody: a source that answers from memory in the file's own shape,
/// so the demo, the shots and the tour read a list as the app does and no
/// request leaves the Mac. The sites are the ones the demo's logins are at,
/// and GitHub, whose login has a code already.
enum DemoTwoFactor {
    static let sites = ["github.com", "google.com", "spotify.com", "digitalocean.com", "cloudflare.com",
                        "slack.com", "notion.so", "figma.com", "linear.app", "vercel.com"]

    /// `isOn` is the switch, which a shot turns for the surfaces that are
    /// of it.
    static func checker(isOn: @escaping @Sendable () -> Bool = { true }) -> TwoFactorCheck {
        TwoFactorCheck(source: Source(), isOn: isOn)
    }

    struct Source: TwoFactorSource {
        func fetch() async -> Data? {
            let entries = sites.map { "\"\($0)\":{\"methods\":[\"totp\"],\"documentation\":\"https://\($0)/help\"}" }
            // And one that offers no code, as the full list has.
            let none = "\"example.com\":{}"
            return Data("{\((entries + [none]).joined(separator: ","))}".utf8)
        }
    }
}
