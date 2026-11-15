import Foundation

/// An address as the matching reads it: what was written, and the host,
/// the port and the site in it.
struct Address {
    let written: String
    /// Lower case, and nil when nothing in the address is a host, which
    /// is every address whose scheme is not `http` or `https`.
    let host: String?
    /// Only when it is written and is not the scheme's own.
    let port: Int?
    /// The part of the host that is the site (`PublicSuffix.site`). An IP
    /// address and a name of one label, `localhost` or a router's, are
    /// their own.
    let site: String?

    init(_ written: String, suffixes: PublicSuffix = .standard) {
        self.written = written
        let trimmed = written.trimmingCharacters(in: .whitespacesAndNewlines)
        // "example.com/login" is kept as it was typed.
        let components = URLComponents(string: trimmed.contains("://") ? trimmed : "https://" + trimmed)
        let scheme = components?.scheme?.lowercased() ?? ""
        // Only the web's two schemes name a host. `androidapp://` and
        // `iosapp://`, which Bitwarden's phone apps write, are followed by
        // a package name, and the tail of one read as a site
        // (`com.google.android.gm`, `android.gm`) is a domain anybody can
        // register. Such an address is still text to the rules that read
        // text.
        var host = scheme == "http" || scheme == "https" ? components?.host?.lowercased() : nil
        if host?.hasSuffix(".") == true { host?.removeLast() }
        if host?.isEmpty == true { host = nil }
        self.host = host
        let own = ["http": 80, "https": 443][scheme]
        port = host == nil ? nil : components?.port.flatMap { $0 == own ? nil : $0 }
        site = host.map { host in
            let isNumbers = host.allSatisfy { $0.isNumber || $0 == "." } || host.contains(":")
            return isNumbers ? host : suffixes.site(of: host) ?? host
        }
    }

    /// The address of a page a browser is on. Nil for anything else a tab
    /// can hold: a blank one, a file, the browser's own pages.
    static func page(_ written: String, suffixes: PublicSuffix = .standard) -> Address? {
        guard let scheme = URLComponents(string: written)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        let address = Address(written, suffixes: suffixes)
        return address.host == nil ? nil : address
    }
}

extension URIMatch {
    /// Whether a login's address, under this rule, is the page's. The six
    /// are Bitwarden's, with its meanings: the same site, the same host and
    /// port, the page's address starting with the login's, the two equal,
    /// the login's read as a pattern, and never.
    func holds(_ own: Address, for page: Address) -> Bool {
        guard !own.written.isEmpty else { return false }
        switch self {
        case .baseDomain:
            return own.site != nil && own.site == page.site
        case .host:
            return own.host != nil && own.host == page.host && own.port == page.port
        case .startsWith:
            return page.written.hasPrefix(own.written)
        case .exact:
            return page.written == own.written
        case .regularExpression:
            // A pattern that does not read is nobody's.
            guard let pattern = try? NSRegularExpression(pattern: own.written, options: .caseInsensitive)
            else { return false }
            let whole = NSRange(page.written.startIndex..., in: page.written)
            return pattern.firstMatch(in: page.written, range: whole) != nil
        case .never:
            return false
        }
    }
}

extension LoginURI {
    /// An address with no rule of its own has the account's, which is the
    /// same site.
    var rule: URIMatch { match ?? .baseDomain }

    func belongs(to page: Address, suffixes: PublicSuffix = .standard) -> Bool {
        rule.holds(Address(uri, suffixes: suffixes), for: page)
    }
}
