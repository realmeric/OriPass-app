import Foundation

/// What a search reads instead of the items: for each of them its title, its
/// username, the hosts of its addresses, the names of its custom fields and
/// its notes, folded so that "is bankasi" and "İŞ BANKASI" are the same
/// letters. A password, a hidden field, a card's number, a code's secret and
/// a key are never put in it, so none of them can be found by typing it, and
/// neither can the value of any custom field, hidden or not.
///
/// The text is one run of bytes with a zero after every part, which is what
/// lets a word be looked for in all of it at once and never found across two
/// parts. The store makes one behind each revision, off the main thread, and
/// drops it at the lock (D6); it is held in memory and written nowhere.
final class SearchIndex {
    /// Where a word was found, best first. An item's place among the results
    /// is the worst of its words'.
    private enum Rank {
        static let startsTitle: UInt8 = 0
        static let startsWord: UInt8 = 1
        static let inTitle: UInt8 = 2
        static let inUsername: UInt8 = 3
        static let inHost: UInt8 = 4
        static let elsewhere: UInt8 = 5
        static let nowhere: UInt8 = 6
    }

    private enum Part: UInt8 {
        case title, username, host, rest
    }

    /// Most recently changed first, which is the order ties are left in
    /// when nobody says which items were used last.
    private let entries: [Entry]
    /// The logins among them with their addresses read, for Quick Access
    /// to suggest from. Made here because here is off the main thread, and
    /// dropped with the rest at the lock.
    let logins: [Suggestions.Login]
    private var text: [UInt8] = []
    /// Where each part starts in `text`, and one more for where the last
    /// ends.
    private var starts: [Int] = []
    private var kinds: [UInt8] = []
    private var owners: [Int] = []
    /// Where each item's title starts.
    private var titles: [Int] = []

    var count: Int { entries.count }
    /// For the test that holds the making of one to another thread.
    let wasMadeOnMain = Thread.isMainThread

    init(_ listed: [Entry]) {
        entries = listed.sorted { one, other in
            guard let first = one.item.revised, let second = other.item.revised, first != second else {
                if (one.item.revised == nil) != (other.item.revised == nil) { return one.item.revised != nil }
                return one.id < other.id
            }
            return first > second
        }
        logins = entries.compactMap { Suggestions.Login($0) }
        for (owner, entry) in entries.enumerated() {
            let item = entry.item
            titles.append(text.count)
            add(item.name, .title, of: owner)
            if let login = item.login {
                if let username = login.username { add(username, .username, of: owner) }
                for address in login.uris {
                    if let host = Self.host(of: address.uri) { add(host, .host, of: owner) }
                }
            }
            for field in item.fields {
                if let name = field.name { add(name, .rest, of: owner) }
            }
            if let notes = item.notes { add(notes, .rest, of: owner) }
        }
        starts.append(text.count)
    }

    private func add(_ words: String, _ part: Part, of owner: Int) {
        guard !words.isEmpty else { return }
        starts.append(text.count)
        kinds.append(part.rawValue)
        owners.append(owner)
        // A line break in a note is a space here, and nothing in a part is
        // the zero that ends it.
        text.append(contentsOf: Self.folded(words).utf8.lazy.map { $0 < 0x20 ? 0x20 : $0 })
        text.append(0)
    }

    /// A site's name where the address has one, and whatever stands where a
    /// host would for a router at 192.168.1.1.
    private static func host(of address: String) -> String? {
        SiteHost.of(address) ?? URLComponents(string: address)?.host
    }

    // MARK: Asking

    /// Every item that has all of the query's words in it somewhere: first
    /// those whose title starts with the query, then those with a word of
    /// the title that does, then a title that holds it, then a username,
    /// then a host, then the rest. Among items found in the same place,
    /// those in `usedLast` lead, in its order, and the rest follow by the
    /// date they were changed.
    func search(_ query: String, usedLast: [String] = []) -> [Entry] {
        let words = Self.words(of: query)
        guard !words.isEmpty, !entries.isEmpty else { return [] }
        var worst = places(of: words[0])
        for word in words.dropFirst() {
            let next = places(of: word)
            for owner in worst.indices where next[owner] > worst[owner] { worst[owner] = next[owner] }
        }
        if words.count > 1 {
            // "is bankasi" starts "İş Bankası", though its second word does
            // not start the title.
            let phrase = Array(words.joined(separator: [0x20]))
            for owner in worst.indices where worst[owner] < Rank.nowhere {
                let start = titles[owner]
                if text.count - start >= phrase.count, text[start..<start + phrase.count].elementsEqual(phrase) {
                    worst[owner] = Rank.startsTitle
                }
            }
        }
        var ranked = [[Entry]](repeating: [], count: Int(Rank.nowhere))
        for (owner, rank) in worst.enumerated() where rank < Rank.nowhere {
            ranked[Int(rank)].append(entries[owner])
        }
        guard !usedLast.isEmpty else { return ranked.flatMap { $0 } }
        let turn = Dictionary(usedLast.enumerated().map { ($1, $0) }) { first, _ in first }
        return ranked.flatMap { found -> [Entry] in
            let used = found.filter { turn[$0.id] != nil }
            guard !used.isEmpty else { return found }
            return used.sorted { (turn[$0.id] ?? 0) < (turn[$1.id] ?? 0) } + found.filter { turn[$0.id] == nil }
        }
    }

    /// The best place one word was found in each item.
    private func places(of word: [UInt8]) -> [UInt8] {
        var best = [UInt8](repeating: Rank.nowhere, count: entries.count)
        text.withUnsafeBytes { text in
            guard let base = text.baseAddress else { return }
            var from = 0
            var part = 0
            while from < text.count,
                  let found = memmem(base + from, text.count - from, word, word.count) {
                let at = base.distance(to: UnsafeRawPointer(found))
                while starts[part + 1] <= at { part += 1 }
                let rank: UInt8
                switch kinds[part] {
                case Part.title.rawValue:
                    if at == starts[part] {
                        rank = Rank.startsTitle
                    } else {
                        rank = Self.endsWord(text[at - 1]) ? Rank.startsWord : Rank.inTitle
                    }
                case Part.username.rawValue: rank = Rank.inUsername
                case Part.host.rawValue: rank = Rank.inHost
                default: rank = Rank.elsewhere
                }
                let owner = owners[part]
                if rank < best[owner] { best[owner] = rank }
                // Only a title's later words can do better than this one.
                from = rank == Rank.inTitle ? at + 1 : starts[part + 1]
            }
        }
        return best
    }

    /// A space, a hyphen, a dot: anything plain that is not a letter or a
    /// digit. A byte of a letter like ş is none of them.
    private static func endsWord(_ byte: UInt8) -> Bool {
        byte < 0x80 && !(byte >= 0x30 && byte <= 0x39) && !(byte >= 0x61 && byte <= 0x7A)
    }

    // MARK: Folding

    /// Small letters with nothing over or under them, the Turkish way and
    /// the lazy way at once: İ, I, ı and i are all i, and ş is s, so a
    /// title is found by whoever types it on whichever keyboard.
    static func folded(_ words: String) -> String {
        words.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "ı", with: "i")
    }

    private static func words(of query: String) -> [[UInt8]] {
        folded(query).split(whereSeparator: \.isWhitespace).map { Array($0.utf8) }
            .filter { !$0.contains { $0 < 0x20 } }
    }
}

extension SearchIndex: Redacted {
    var redactedLabel: String { "SearchIndex(\(entries.count) items)" }
}
