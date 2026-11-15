import Foundation

/// The host of an address, in the one form the icon server and the cache's
/// file names can take: lower case, letters, digits, dots and hyphens, at
/// least one dot, and not an IP address.
enum SiteHost {
    /// Nil for an address with no site in it: an app's identifier
    /// (`androidapp://`), a bare word, an IP address, a name that is not
    /// plain ASCII.
    static func of(_ address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Bitwarden keeps "example.com/login" as it was typed.
        let full = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: full),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = components.host?.lowercased()
        else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        return isValid(host) ? host : nil
    }

    /// Fit to be a file name and a path in a URL, which is also what keeps
    /// `../` out of the cache's directory.
    static func isValid(_ host: String) -> Bool {
        guard host.count <= 253, host.contains(".") else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") }) else { return false }
        guard host.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2E || $0 == 0x2D })
        else { return false }
        // 192.168.0.1 has a site's shape and no icon.
        return !labels.allSatisfy { $0.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } }
    }
}

extension Item {
    /// The host of a login's first address, which is where its icon is
    /// asked for. A login with no address, and every other type, has none.
    var iconHost: String? {
        guard let first = login?.uris.first else { return nil }
        return SiteHost.of(first.uri)
    }
}
