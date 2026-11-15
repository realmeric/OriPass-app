import Foundation

/// What the details column draws for one item (`docs/look.md`, "Item
/// details"), worked out once when the item is chosen: which rows there are
/// and in what order. A row with nothing in it is not here, so the view
/// draws what it is given and decides nothing.
///
/// The outlined group is each type's own: a login's username and password,
/// a card's number and expiry, an identity's name and address, a key's two
/// halves, and for a type this app does not know every key it came with. The
/// custom fields, the notes and the two dates are every type's.
struct ItemDetail: Redacted {
    /// What stands in for a value that is not shown. The same ten dots
    /// whatever is under them, so a row does not give away a length.
    static let dots = String(repeating: "•", count: 10)

    /// The id of a login's password row, which is the one that says how
    /// strong it is.
    static let passwordRow = "password"

    /// The id of a login's one-time code, in the details and in the form.
    static let codeRow = "totp"

    /// What VoiceOver is given in a hidden value's place.
    static let concealed = "concealed"

    /// A card's number before its last four. Three groups whatever the
    /// length, so the row does not say whether it is a Visa or an Amex.
    static let numberDots = "•••• •••• ••••"

    /// The banner over a type this app has never heard of, and what Edit
    /// says when it is held under the pointer (D11).
    static let unknownNotice = "\(AppInfo.name) can show this kind of item and cannot change it."
    static let unknownEditHelp = "\(AppInfo.name) does not know how to write this kind of item back, so it is shown and never changed."

    struct Row: Identifiable, Redacted {
        enum Value {
            case text(String)
            /// Drawn and said only while the row is revealed.
            case hidden(String)
            /// A number drawn as dots and its last few characters, which
            /// are the only part of it the row shows. Held whole, like
            /// `hidden`.
            case masked(String, last: String)
            case tick(Bool)
            /// The name of the field this one points at.
            case pointer(String)
            /// A one-time code, which is a different six digits every half
            /// minute and so is worked out when it is drawn or copied. Nil
            /// when the item's secret cannot be read.
            case code(Totp?)
        }

        let id: String
        let label: String
        let value: Value
        /// False for a row that only says something about the item, a
        /// passkey's date: there is nothing in it to paste anywhere.
        var copies = true

        /// What a click copies, a reveal shows and Large Type spells out.
        /// Nil for a tick and for a pointer at another field.
        var whole: String? {
            guard copies else { return nil }
            switch value {
            case .text(let text): return text
            case .hidden(let value): return value
            case .masked(let whole, _): return whole
            case .tick, .pointer, .code: return nil
            }
        }

        /// The same at `moment`, which is all a one-time code depends on.
        func whole(at moment: Date) -> String? {
            if case .code(let totp) = value { return totp?.code(at: moment) }
            return whole
        }

        var isHidden: Bool {
            switch value {
            case .hidden, .masked: return true
            default: return false
            }
        }

        /// What the row says to someone who cannot see it.
        var spoken: String {
            switch value {
            case .text(let text): return text
            case .hidden: return ItemDetail.concealed
            case .masked(_, let last): return "\(ItemDetail.concealed), ending \(last)"
            case .tick(let isOn): return isOn ? "yes" : "no"
            case .pointer(let name): return "the same as \(name)"
            // The digits are said by what draws them, which knows the time.
            // And this is what is said of one that is held back.
            case .code(let totp): return totp == nil ? Totp.invalid : ItemDetail.concealed
            }
        }

        /// The same, for a row that may be standing revealed: what is on the
        /// screen, and so the value itself only then.
        func said(revealed: Bool) -> String {
            revealed && isHidden ? whole ?? spoken : spoken
        }

        var redactedLabel: String { "Row(\(id))" }
    }

    /// One address, in the three parts it is coloured by.
    struct Website: Identifiable, Equatable {
        let id: Int
        /// `https://`, or nothing when none was written.
        let scheme: String
        /// Empty when the address is nothing a browser opens, and then
        /// `rest` is all of it.
        let host: String
        let rest: String
        /// What a click on the host opens.
        let link: URL?
        /// The address as it was written, which is what a click copies.
        let written: String
        /// The row's name among the item's rows.
        var row: String { "website-\(id)" }

        init(id: Int, address: String) {
            self.id = id
            let written = address.trimmingCharacters(in: .whitespacesAndNewlines)
            let scheme = written.range(of: "://").map { String(written[..<$0.upperBound]) } ?? ""
            let after = written.dropFirst(scheme.count)
            let host = after.prefix { !"/?#".contains($0) }
            // Bitwarden keeps "example.com/login" as it was typed, and a
            // browser would take it as https.
            let whole = scheme.isEmpty ? "https://" + written : written
            self.written = written
            guard !host.isEmpty, host.contains(".") || !scheme.isEmpty,
                  let link = URLComponents(string: whole)?.url, NoteText.mayOpen(link)
            else {
                self.scheme = ""
                self.host = ""
                rest = written
                self.link = nil
                return
            }
            self.scheme = scheme
            self.host = String(host)
            rest = String(after.dropFirst(host.count))
            self.link = link
        }
    }

    let id: String
    let item: Item
    let title: String
    let vault: Vault
    let isFavourite: Bool
    /// The outlined group.
    let main: [Row]
    let websites: [Website]
    /// The custom fields, in the order the item holds them.
    let fields: [Row]
    /// The files that go with the item, in the order it holds them.
    let attachments: [File]
    let note: NoteText?
    let edited: Date?
    let created: Date?
    /// A sentence over the outline, for a type this app can show and not
    /// change.
    let notice: String?
    /// Why Edit does nothing for good, and nil when it will one day.
    let editHelp: String?

    var canEdit: Bool { editHelp == nil }

    var redactedLabel: String { "ItemDetail(\(id))" }

    init(item: Item, vault: Vault, calendar: Calendar = .current, locale: Locale = .current) {
        id = item.id
        self.item = item
        title = item.name
        self.vault = vault
        isFavourite = item.favorite
        edited = item.revised
        created = item.created

        let isUnknown: Bool
        if case .unknown = item.type { isUnknown = true } else { isUnknown = false }
        notice = isUnknown ? Self.unknownNotice : nil
        editHelp = isUnknown ? Self.unknownEditHelp : nil
        main = Self.rows(of: item, calendar: calendar, locale: locale)

        websites = (item.login?.uris ?? []).enumerated().compactMap { place, address in
            address.uri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : Website(id: place, address: address.uri)
        }

        fields = item.fields.enumerated().compactMap { place, field in
            let id = "field-\(place)"
            let label = field.name.flatMap { $0.isEmpty ? nil : $0 } ?? "field"
            switch field.kind {
            case .text:
                guard let value = field.value, !value.isEmpty else { return nil }
                return Row(id: id, label: label, value: .text(value))
            case .hidden:
                guard let value = field.value, !value.isEmpty else { return nil }
                return Row(id: id, label: label, value: .hidden(value))
            case .boolean:
                return Row(id: id, label: label, value: .tick(field.value == "true"))
            case .linked:
                return Row(id: id, label: label, value: .pointer(Self.linked(field.linkedID, username: item.login?.username)))
            }
        }

        attachments = item.attachments.enumerated().map { File(place: $0, attachment: $1) }

        let read = item.notes.map(NoteText.init(markdown:))
        note = read?.isEmpty == false ? read : nil
    }

    // MARK: What a row gives up

    /// The id the notes are copied under.
    static let notesRow = "notes"

    /// What the row called `id` holds, whole: a field's value, an address as
    /// it was written, the notes as they were typed, and the one-time code
    /// that stands at `moment`.
    func value(of id: String, at moment: Date = Date()) -> String? {
        if id == Self.notesRow { return note == nil ? nil : item.notes }
        if let row = (main + fields).first(where: { $0.id == id }) { return row.whole(at: moment) }
        return websites.first { $0.row == id }?.written
    }

    func isHidden(_ id: String) -> Bool {
        (main + fields).first { $0.id == id }?.isHidden ?? false
    }

    /// The rows the arrows stop on, from the top: every one with something
    /// to copy.
    var stops: [String] {
        (main.map(\.id) + websites.map(\.row) + fields.map(\.id) + [Self.notesRow]).filter { value(of: $0) != nil }
    }

    /// Every row ⌘R shows and hides.
    var hiddenRows: [String] { (main + fields).filter(\.isHidden).map(\.id) }

    /// The row ⌘C copies: a login's username, a card's number, the first
    /// thing the outline says for the rest, and a note's own words when the
    /// item has nothing else.
    var primaryRow: String? {
        let preferred: String
        switch item.payload {
        case .login: preferred = "username"
        case .card: preferred = "number"
        default: preferred = ""
        }
        if main.contains(where: { $0.id == preferred }) { return preferred }
        if case .login = item.payload { return nil }
        return main.first { $0.whole != nil }?.id ?? (note == nil ? nil : Self.notesRow)
    }

    /// The row ⇧⌘C copies, when the item has a password.
    var passwordRowID: String? { main.contains { $0.id == Self.passwordRow } ? Self.passwordRow : nil }

    /// The row ⌥⌘C copies, when the item has a secret that makes a code.
    var codeRowID: String? { value(of: Self.codeRow) == nil ? nil : Self.codeRow }

    /// What a linked field points at, by the number Bitwarden gives each of
    /// an item's own fields (`docs/notes.md`, "What an item looks like").
    /// The numbers of the five types do not overlap, so one table serves
    /// them all. A login's username is called what `Login.word` calls the
    /// one it is handed.
    static func linked(_ id: Int?, username: String? = nil) -> String {
        switch id {
        case 100: return Login.word(forUsername: username)
        case 101: return "password"
        case 300: return "cardholder name"
        case 301: return "expiry month"
        case 302: return "expiry year"
        case 303: return "security code"
        case 304: return "brand"
        case 305: return "number"
        case 400: return "title"
        case 401: return "middle name"
        case 402: return "address"
        case 403: return "address"
        case 404: return "address"
        case 405: return "city"
        case 406: return "state"
        case 407: return "postal code"
        case 408: return "country"
        case 409: return "company"
        case 410: return "email"
        case 411: return "phone"
        case 412: return "social security number"
        case 413: return "username"
        case 414: return "passport number"
        case 415: return "licence number"
        case 416: return "first name"
        case 417: return "last name"
        case 418: return "name"
        default: return "another field"
        }
    }

    // MARK: The outlined group

    private static func rows(of item: Item, calendar: Calendar, locale: Locale) -> [Row] {
        switch item.payload {
        case .login(let login):
            var rows: [Row] = []
            if let username = login.username, !username.isEmpty {
                rows.append(Row(id: "username", label: login.usernameWord, value: .text(username)))
            }
            if let password = login.password, !password.isEmpty {
                rows.append(Row(id: passwordRow, label: "password", value: .hidden(password)))
            }
            for (place, made) in login.passkeysCreated.enumerated() {
                rows.append(Row(id: "passkey-\(place)", label: "passkey",
                                value: .text(passkeySaid(made, calendar: calendar, locale: locale)), copies: false))
            }
            if let secret = login.totp, !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rows.append(Row(id: codeRow, label: "one-time code", value: .code(Totp(secret))))
            }
            return rows

        case .card(let card):
            return [
                text("holder", "cardholder name", card.cardholderName),
                text("brand", "brand", card.brand),
                number("number", "number", card.number),
                text("expiry", "expiry date", expiry(month: card.expMonth, year: card.expYear)),
                hidden("code", "security code", card.code),
            ].compactMap { $0 }

        case .identity(let identity):
            let name = [identity[.title], identity[.firstName], identity[.middleName], identity[.lastName]]
            return [
                text("name", "name", joined(name, " ")),
                text("company", "company", identity[.company]),
                text("email", "email", identity[.email]),
                text("phone", "phone", identity[.phone]),
                text("username", "username", identity[.username]),
                text("address", "address", address(of: identity)),
                hidden("ssn", "social security number", identity[.ssn]),
                hidden("passport", "passport number", identity[.passportNumber]),
                hidden("licence", "licence number", identity[.licenseNumber]),
            ].compactMap { $0 }

        case .sshKey(let key):
            return [
                text("public-key", "public key", key.publicKey),
                text("fingerprint", "fingerprint", key.fingerprint),
                hidden("private-key", "private key", key.privateKey),
            ].compactMap { $0 }

        case .secureNote:
            return []

        case .unknown(let payload):
            var rows: [Row] = []
            for key in payload.keys.sorted() {
                collect(payload[key] ?? .null, path: [key], into: &rows)
            }
            return rows
        }
    }

    /// What a passkey's row says: the day it was made, when the item says.
    static func passkeySaid(_ made: Date?, calendar: Calendar = .current, locale: Locale = .current) -> String {
        made.map { "Created \(written($0, time: false, calendar: calendar, locale: locale))" } ?? "Saved in this item"
    }

    /// A row for a value that is there, and nothing for one that is not.
    private static func text(_ id: String, _ label: String, _ value: String?) -> Row? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Row(id: id, label: label, value: .text(value))
    }

    private static func hidden(_ id: String, _ label: String, _ value: String?) -> Row? {
        guard let value, !value.isEmpty else { return nil }
        return Row(id: id, label: label, value: .hidden(value))
    }

    /// A card number shows its last four. One too short to hide anything
    /// behind four digits is hidden whole.
    private static func number(_ id: String, _ label: String, _ value: String?) -> Row? {
        guard let value, !value.isEmpty else { return nil }
        guard let last = Card.lastFour(of: value) else { return Row(id: id, label: label, value: .hidden(value)) }
        return Row(id: id, label: label, value: .masked(value, last: last))
    }

    /// Month and year as `10/2026`, or whichever of them was written.
    static func expiry(month: String?, year: String?) -> String? {
        let month = month?.trimmingCharacters(in: .whitespaces) ?? ""
        let year = year?.trimmingCharacters(in: .whitespaces) ?? ""
        let padded = Int(month).flatMap { (1...12).contains($0) ? String(format: "%02d", $0) : nil } ?? month
        return joined([padded, year], "/")
    }

    private static func joined(_ parts: [String?], _ separator: String) -> String? {
        let kept = parts.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return kept.isEmpty ? nil : kept.joined(separator: separator)
    }

    /// The street lines, then the postcode with the town, the state and the
    /// country, one to a line. Where a country puts the postcode is not
    /// something the item says.
    private static func address(of identity: Identity) -> String? {
        let lines = [
            identity[.address1], identity[.address2], identity[.address3],
            joined([identity[.postalCode], identity[.city]], " "), identity[.state], identity[.country],
        ]
        return joined(lines, "\n")
    }

    // MARK: A type that is not known

    /// Every scalar under `path`, one row each. A nested object or a list
    /// adds its keys or places to the label.
    private static func collect(_ value: JSONValue, path: [String], into rows: inout [Row]) {
        guard path.count <= 6 else { return }
        let id = "payload-" + path.joined(separator: ".")
        let label = path.map(spaced).joined(separator: " ")
        func shown(_ value: String) {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let secret = path.contains(where: suggestsSecret)
            rows.append(Row(id: id, label: label, value: secret ? .hidden(value) : .text(value)))
        }
        switch value {
        case .null: break
        case .string(let value): shown(value)
        case .int(let value): shown(String(value))
        case .double(let value): shown(String(value))
        case .bool(let value): rows.append(Row(id: id, label: label, value: .tick(value)))
        case .array(let values):
            for (place, member) in values.enumerated() { collect(member, path: path + [String(place + 1)], into: &rows) }
        case .object(let members):
            for key in members.keys.sorted() { collect(members[key] ?? .null, path: path + [key], into: &rows) }
        }
    }

    /// `issuingCountry` as "issuing country".
    private static func words(_ name: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in name {
            if "_-. ".contains(character) {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else if character.isUppercase, current.last?.isLowercase == true {
                words.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.lowercased() }
    }

    private static func spaced(_ name: String) -> String { words(name).joined(separator: " ") }

    /// Whether a key's name says its value is not to be left on the screen.
    /// It errs towards hiding: a number is hidden whatever it numbers.
    static func suggestsSecret(_ name: String) -> Bool {
        let secret: Set<String> = [
            "password", "passcode", "pass", "pin", "secret", "token", "key", "code", "cvv", "cvc", "number", "ssn",
            "private", "seed", "phrase", "credential", "credentials", "otp", "totp",
        ]
        let joined = name.lowercased().filter { $0.isLetter || $0.isNumber }
        return words(name).contains(where: secret.contains)
            || ["password", "passcode", "secret", "token", "apikey"].contains(where: joined.contains)
    }

    /// A date with its weekday, and the time to the second when asked: what
    /// "Last edited" is followed by.
    static func written(_ date: Date, time: Bool = true, calendar: Calendar = .current,
                        locale: Locale = .current) -> String {
        var style = Date.FormatStyle(date: .complete, time: time ? .standard : .omitted, locale: locale,
                                     calendar: calendar)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
}

extension VaultStore {
    /// The one vault an item is shown as living in (D9): its folder, or the
    /// first of its collections that this account lists, or Personal.
    func vault(of item: Item) -> Vault {
        let vaults = shelves.vaults
        if let folder = item.folderID, let found = vaults.first(where: { $0.id == .folder(folder) }) {
            return found
        }
        for collection in item.collectionIDs {
            if let found = vaults.first(where: { $0.id == .collection(collection) }) { return found }
        }
        return .personal
    }
}
