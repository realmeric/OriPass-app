import Foundation

/// The logins that belong to what he is looking at, and the name they are
/// listed under: a site's when a browser said which page it is on, and
/// the app's when what is in front is no browser.
struct Suggestions {
    let heading: String
    let entries: [Entry]

    /// A login with its addresses already read for their hosts and sites,
    /// which is most of the work and is done once per revision, where the
    /// search index is made, and not when the hot key fires (D18).
    struct Login {
        let entry: Entry
        let addresses: [(rule: URIMatch, address: Address)]
        /// What an app is tried against: the sites of the addresses that
        /// do not say never, and the title as a search would read it. Nil
        /// when every address says never, and the login is to be offered
        /// to no app.
        let sites: [String]?
        let title: String

        init?(_ entry: Entry, suffixes: PublicSuffix = .standard) {
            guard let login = entry.item.login else { return nil }
            self.entry = entry
            addresses = login.uris.map { ($0.rule, Address($0.uri, suffixes: suffixes)) }
            let open = addresses.filter { $0.rule != .never }
            sites = addresses.isEmpty || !open.isEmpty ? open.compactMap(\.address.site) : nil
            title = SearchIndex.folded(entry.item.name)
        }
    }

    /// The logins with an address that is this page's by the address's own
    /// rule (`URIMatch.holds`). Those on the very host lead, then those
    /// used last, in that order, then the rest by title.
    static func forPage(_ page: Address, among listed: [Login], usedLast: [String] = []) -> Suggestions? {
        let found = listed.compactMap { login -> (Entry, Int)? in
            let own = login.addresses.filter { $0.rule.holds($0.address, for: page) }
            guard !own.isEmpty else { return nil }
            return (login.entry, own.contains { $0.address.host == page.host } ? 0 : 1)
        }
        guard !found.isEmpty, let site = page.site else { return nil }
        return Suggestions(heading: site, entries: ordered(found, usedLast))
    }

    /// For an app that is not a browser. Its name is tried as a site's
    /// (Slack and `slack.com`) and then as a login's title. Its bundle id
    /// read backwards is a site too, `com.spotify.client` being
    /// `spotify.com`, but that is the site of whoever made the app, and is
    /// the app's own only when the app is called after it: when the site's
    /// first label is a word of the app's name, or a login on that site has
    /// the name for its title. Every app of Apple's would otherwise offer
    /// the Apple account, so theirs are tried by name alone.
    ///
    /// A browser is offered nothing here. One that could not be asked, or
    /// would not say, is on a page nobody knows.
    ///
    /// A login whose addresses all say never is not offered, whatever it is
    /// called.
    static func forApp(_ app: FrontApp, among listed: [Login], usedLast: [String] = [],
                       suffixes: PublicSuffix = .standard) -> Suggestions? {
        guard !app.isBrowser else { return nil }
        let name = SearchIndex.folded(app.name)
        let word = name.filter { $0.isLetter || $0.isNumber }
        func isTitled(_ login: Login) -> Bool { login.title == name || login.title.hasPrefix(name + " ") }

        let backwards = app.isApples ? nil
            : app.bundleID.map { $0.lowercased().split(separator: ".").reversed().joined(separator: ".") }
        var site = backwards.flatMap { suffixes.site(of: $0) }
        if let made = site, word.count > 1 {
            let label = made.prefix { $0 != "." }
            let isNamed = label == word || name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(label)
            let isOwn = isNamed || listed.contains { $0.sites?.contains(made) == true && isTitled($0) }
            if !isOwn { site = nil }
        } else {
            site = nil
        }

        let found = listed.compactMap { login -> (Entry, Int)? in
            guard let sites = login.sites else { return nil }
            if let site, sites.contains(site) { return (login.entry, 0) }
            guard word.count > 1 else { return nil }
            if sites.contains(where: { $0.hasPrefix(word + ".") }) { return (login.entry, 1) }
            return isTitled(login) ? (login.entry, 2) : nil
        }
        guard !found.isEmpty else { return nil }
        return Suggestions(heading: app.name, entries: ordered(found, usedLast))
    }

    private static func ordered(_ found: [(entry: Entry, rank: Int)], _ usedLast: [String]) -> [Entry] {
        let turn = Dictionary(usedLast.enumerated().map { ($1, $0) }) { first, _ in first }
        return found.sorted { one, other in
            if one.rank != other.rank { return one.rank < other.rank }
            let first = turn[one.entry.id] ?? Int.max, second = turn[other.entry.id] ?? Int.max
            if first != second { return first < second }
            let order = one.entry.item.name.localizedStandardCompare(other.entry.item.name)
            return order == .orderedSame ? one.entry.id < other.entry.id : order == .orderedAscending
        }.map(\.entry)
    }
}

extension Suggestions: Redacted {
    var redactedLabel: String { "Suggestions(\(entries.count))" }
}

extension Suggestions.Login: Redacted {
    var redactedLabel: String { "Login(\(entry.id))" }
}
