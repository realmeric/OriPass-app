import Foundation

/// Where an account lives: Bitwarden's US or EU cloud, or a server of one's
/// own at one address, which has the identity and the API under it.
enum Server: Codable, Equatable, Hashable, Sendable {
    case us
    case eu
    case own(URL)

    var identity: URL {
        switch self {
        case .us: URL(string: "https://identity.bitwarden.com")!
        case .eu: URL(string: "https://identity.bitwarden.eu")!
        case .own(let base): base.appending(path: "identity")
        }
    }

    var api: URL {
        switch self {
        case .us: URL(string: "https://api.bitwarden.com")!
        case .eu: URL(string: "https://api.bitwarden.eu")!
        case .own(let base): base.appending(path: "api")
        }
    }

    var icons: URL {
        switch self {
        case .us: URL(string: "https://icons.bitwarden.net")!
        case .eu: URL(string: "https://icons.bitwarden.eu")!
        case .own(let base): base.appending(path: "icons")
        }
    }

    var webVault: URL {
        switch self {
        case .us: URL(string: "https://vault.bitwarden.com")!
        case .eu: URL(string: "https://vault.bitwarden.eu")!
        case .own(let base): base
        }
    }

    /// A server of one's own from what was typed: https, or http on this
    /// phone itself, which is the stand-in on the simulator. Nil otherwise.
    static func own(typed: String) -> Server? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let host = url.host(), !host.isEmpty else { return nil }
        let local = host == "localhost" || host == "127.0.0.1"
        guard url.scheme == "https" || (url.scheme == "http" && local) else { return nil }
        return .own(url)
    }
}
