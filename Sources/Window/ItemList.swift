import Foundation

/// What the item list draws (`docs/look.md`, "The item list"): the entries of
/// one sidebar row, narrowed to a category and to what was typed into the
/// filter, in the order he asked for and under the headings that order
/// gives. A value, arranged once and read by every frame after it.
struct ItemList {
    /// All Categories and the five (D11). A type this app does not know is
    /// in no category of its own and is listed under All.
    enum Category: String, CaseIterable, Codable {
        case all, login, secureNote, card, identity, sshKey

        var type: ItemType? {
            switch self {
            case .all: return nil
            case .login: return .login
            case .secureNote: return .secureNote
            case .card: return .card
            case .identity: return .identity
            case .sshKey: return .sshKey
            }
        }

        var name: String {
            switch self {
            case .all: return "All Categories"
            case .login: return "Logins"
            case .secureNote: return "Secure Notes"
            case .card: return "Credit Cards"
            case .identity: return "Identities"
            case .sshKey: return "SSH Keys"
            }
        }

        var glyph: Glyph { type.map(Glyph.category) ?? .categories }
    }

    enum Key: String, CaseIterable, Codable {
        case title, created, modified

        var name: String {
            switch self {
            case .title: return "Title"
            case .created: return "Date Created"
            case .modified: return "Date Modified"
            }
        }

        /// The two directions, the one a key starts in first.
        var directions: [String] {
            self == .title ? ["A to Z", "Z to A"] : ["Newest First", "Oldest First"]
        }
    }

    struct Sort: Equatable {
        var key = Key.title
        /// Z to A, or oldest first.
        var isReversed = false
    }

    struct Section: Identifiable {
        let heading: String
        let entries: [Entry]
        /// A heading can come twice in one list, so the first row under it
        /// is part of its name.
        var id: String { "\(heading) \(entries.first?.id ?? "")" }
    }

    static let empty = ItemList([], category: .all, sort: Sort(), filter: "")

    let sections: [Section]
    /// The rows in the order they are drawn, which is the order the arrow
    /// keys walk.
    let entries: [Entry]
    let sort: Sort
    private let places: [String: Int]

    init(_ listed: [Entry], category: Category, sort: Sort, filter: String,
         calendar: Calendar = .current) {
        var kept = listed
        if let type = category.type {
            kept = kept.filter { $0.item.type == type }
        }
        let wanted = Self.filed(filter.trimmingCharacters(in: .whitespaces))
        if !wanted.isEmpty {
            kept = kept.filter {
                Self.filed($0.item.name).contains(wanted)
                    || Self.filed($0.item.secondLine ?? "").contains(wanted)
            }
        }

        var filing: [(heading: String, entries: [Entry])] = []
        func file(_ entry: Entry, under heading: String) {
            if filing.last?.heading == heading {
                filing[filing.count - 1].entries.append(entry)
            } else {
                filing.append((heading, [entry]))
            }
        }

        switch sort.key {
        case .title:
            var filed = kept.map { (entry: $0, title: Self.filed($0.item.name)) }
            filed.sort { one, other in
                switch one.title.compare(other.title, options: .numeric, range: nil, locale: Self.turkish) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return one.entry.id < other.entry.id
                }
            }
            if sort.isReversed { filed.reverse() }
            for row in filed { file(row.entry, under: Self.initial(ofFiled: row.title)) }
        case .created, .modified:
            let dated = kept.map { (entry: $0, date: sort.key == .created ? $0.item.created : $0.item.revised) }
            // An item with no date comes last, whichever way the rest run.
            let sorted = dated.sorted { one, other in
                guard let first = one.date, let second = other.date, first != second else {
                    if (one.date == nil) != (other.date == nil) { return one.date != nil }
                    return one.entry.id < other.entry.id
                }
                return sort.isReversed ? first < second : first > second
            }
            var month: (year: Int, month: Int, heading: String)?
            for row in sorted {
                guard let date = row.date else {
                    file(row.entry, under: "NO DATE")
                    continue
                }
                let parts = calendar.dateComponents([.year, .month], from: date)
                if month?.year != parts.year || month?.month != parts.month {
                    month = (parts.year ?? 0, parts.month ?? 0, Self.month(of: date, in: calendar))
                }
                file(row.entry, under: month?.heading ?? "")
            }
        }

        sections = filing.map { Section(heading: $0.heading, entries: $0.entries) }
        self.sort = sort
        entries = sections.flatMap(\.entries)
        places = Dictionary(entries.enumerated().map { ($1.id, $0) }) { first, _ in first }
    }

    /// What a search found, in the order it found them and under one
    /// heading that counts them.
    init(found: [Entry]) {
        let heading = "\(found.count) \(found.count == 1 ? "RESULT" : "RESULTS")"
        sections = found.isEmpty ? [] : [Section(heading: heading, entries: found)]
        sort = Sort()
        entries = found
        places = Dictionary(found.enumerated().map { ($1.id, $0) }) { first, _ in first }
    }

    var isEmpty: Bool { entries.isEmpty }

    func place(of id: String) -> Int? { places[id] }

    /// The grey line at the top of the sort menu.
    var caption: String {
        "\(entries.count) \(entries.count == 1 ? "ITEM" : "ITEMS") SORTED BY"
    }

    /// The first row whose title starts with what was typed, as the list
    /// stands.
    func first(titled letters: String) -> Entry? {
        let wanted = Self.filed(letters)
        guard !wanted.isEmpty else { return nil }
        return entries.first { Self.filed($0.item.name).hasPrefix(wanted) }
    }

    // MARK: Filing

    private static let turkish = Locale(identifier: "tr_TR")
    /// The letters a Turkish reader files apart from the ones they look
    /// like. Every other mark over or under a letter is ignored.
    private static let ownLetters: Set<Character> = ["ç", "ğ", "ö", "ş", "ü"]

    /// A title as it is compared: in small letters the Turkish way, so that
    /// I is ı and İ is i, and with its accents taken off, so that "Éclair"
    /// files with "eclair" and "kâr" with "kar".
    static func filed(_ title: String) -> String {
        var out = ""
        for letter in title.lowercased(with: turkish) {
            if ownLetters.contains(letter) {
                out.append(letter)
            } else {
                out += String(letter).folding(options: .diacriticInsensitive, locale: turkish)
            }
        }
        return out
    }

    /// The heading a title is filed under when the list is sorted by title:
    /// its first letter as a capital, İ for "iş" and I for "ılgaz", and one
    /// heading for everything that starts with no letter at all.
    static func initial(of title: String) -> String {
        initial(ofFiled: filed(title))
    }

    private static func initial(ofFiled title: String) -> String {
        guard let first = title.first(where: { !$0.isWhitespace }), first.isLetter else { return "#" }
        return String(first).uppercased(with: turkish)
    }

    /// "MARCH 2025". The app's sentences are English, and so are its months.
    private static func month(of date: Date, in calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "LLLL yyyy"
        return formatter.string(from: date).uppercased()
    }
}

extension Item {
    /// A row's grey line (`docs/look.md`, "The item list"), which never
    /// carries a value the details would hide: a card's is its brand and the
    /// last four of its number, where the details show them too.
    var secondLine: String? {
        let line: String?
        switch payload {
        case .login(let login):
            line = login.username
        case .card(let card):
            let tail = Card.lastFour(of: card.number).map { "•••• \($0)" }
            line = [card.brand, tail].compactMap { $0 }.joined(separator: " ")
        case .identity(let identity):
            line = [Identity.Key.firstName, .middleName, .lastName].compactMap { identity[$0] }
                .filter { !$0.isEmpty }.joined(separator: " ")
        case .secureNote:
            line = notes?.split(whereSeparator: \.isNewline).first.map(String.init)
        case .sshKey(let key):
            line = key.fingerprint
        case .unknown:
            line = nil
        }
        let trimmed = line?.trimmingCharacters(in: .whitespaces) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
