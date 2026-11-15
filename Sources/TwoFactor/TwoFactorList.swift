import Foundation

/// The sites that take a one-time code, as 2fa.directory publishes them
/// (`docs/notes.md`, "Icons, breaches and the two-factor list"): the keys of
/// `v4/totp.json`, each a domain, with the methods it lists. The list is
/// public and says nothing of him, so it may be cached on disk and held in
/// memory for as long as the vault is open.
struct TwoFactorList: Equatable {
    /// Lower case domains, each of a site that offers `totp`.
    let domains: Set<String>

    /// Nil for anything that is not the list: not JSON, not an object, or
    /// one with no site on it that offers a code, which the real list never
    /// is and a captive portal's page always is.
    init?(_ body: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        var domains: Set<String> = []
        for (key, value) in object {
            let domain = key.lowercased()
            guard let entry = value as? [String: Any], let methods = entry["methods"] as? [Any],
                  methods.contains(where: { ($0 as? String) == "totp" }), SiteHost.isValid(domain) else { continue }
            domains.insert(domain)
        }
        guard !domains.isEmpty else { return nil }
        self.domains = domains
    }

    /// Whether a host is a listed domain or lies under one: `accounts.example.com`
    /// is offered by `example.com`, `notexample.com` is not. A bare top level
    /// is never looked for.
    func offers(host: String) -> Bool {
        var rest = Substring(host.lowercased())
        while let dot = rest.firstIndex(of: ".") {
            if domains.contains(String(rest)) { return true }
            rest = rest[rest.index(after: dot)...]
        }
        return false
    }

    /// Whether a login could be asked for a code and has none to give: one
    /// of its addresses is on the list and its one-time code is empty.
    func wants(_ item: Item) -> Bool {
        guard let login = item.login,
              login.totp?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true else { return false }
        return login.uris.contains { SiteHost.of($0.uri).map(offers(host:)) == true }
    }
}
