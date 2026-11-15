import Foundation

/// Bitwarden's five types under 1Password's names for them (D11). A type this
/// app has never heard of still decodes, lists and shows, and is never
/// written back.
enum ItemType: Hashable {
    case login, secureNote, card, identity, sshKey
    case unknown(Int)

    init(rawValue: Int) {
        switch rawValue {
        case 1: self = .login
        case 2: self = .secureNote
        case 3: self = .card
        case 4: self = .identity
        case 5: self = .sshKey
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: Int {
        switch self {
        case .login: return 1
        case .secureNote: return 2
        case .card: return 3
        case .identity: return 4
        case .sshKey: return 5
        case .unknown(let value): return value
        }
    }
}

/// A key the app cannot do without was not in what `bw` sent. The store
/// locks with `sentence`, which names the route, and nothing traps.
struct ShapeError: Error, Equatable {
    let missing: String
    /// The route that was being read, once something that knows it has seen
    /// the error go by (`on`).
    var route: String?

    init(missing: String, route: String? = nil) {
        self.missing = missing
        self.route = route
    }

    /// The same error, naming `route` unless it already names one.
    func on(_ route: String) -> ShapeError {
        ShapeError(missing: missing, route: self.route ?? route)
    }

    var sentence: String {
        guard let route else { return "The engine's answer had no \(missing)." }
        return "The engine's answer to \(route) had no \(missing)."
    }
}

struct Item: Identifiable, Equatable {
    /// Empty on an item that has not been saved yet.
    let id: String
    let type: ItemType
    var name: String
    var notes: String?
    var favorite: Bool
    var folderID: String?
    let organizationID: String?
    /// The item asks for the master password again before giving anything up.
    var reprompt: Bool
    var fields: [Field]
    var payload: Payload
    var passwordHistory: [PasswordHistoryEntry]
    let attachments: [Attachment]
    let collectionIDs: [String]
    let created: Date?
    let revised: Date?
    let deleted: Date?
    let archived: Date?

    /// The object this was decoded from. `patched` is the only reader that
    /// turns it back into something to send.
    let raw: JSONValue

    enum Payload: Equatable {
        case login(Login)
        case secureNote
        case card(Card)
        case identity(Identity)
        case sshKey(SSHKey)
        /// The payload of a type this app does not know, whichever key it
        /// arrived under.
        case unknown([String: JSONValue])
    }

    var login: Login? {
        if case .login(let login) = payload { return login }
        return nil
    }

    var isInTrash: Bool { deleted != nil }
    var isArchived: Bool { archived != nil }

    init(json: JSONValue) throws {
        guard let name = json["name"]?.string else { throw ShapeError(missing: "name") }
        guard let type = json["type"]?.int else { throw ShapeError(missing: "type") }
        raw = json
        id = json["id"]?.string ?? ""
        self.type = ItemType(rawValue: type)
        self.name = name
        notes = json["notes"]?.string
        favorite = json["favorite"]?.bool ?? false
        folderID = json["folderId"]?.string
        organizationID = json["organizationId"]?.string
        reprompt = json["reprompt"]?.int == 1
        fields = (json["fields"]?.array ?? []).map(Field.init(json:))
        passwordHistory = (json["passwordHistory"]?.array ?? []).map(PasswordHistoryEntry.init(json:))
        attachments = (json["attachments"]?.array ?? []).map(Attachment.init(json:))
        collectionIDs = (json["collectionIds"]?.array ?? []).compactMap(\.string)
        created = json["creationDate"]?.string.flatMap(VaultDate.parse)
        revised = json["revisionDate"]?.string.flatMap(VaultDate.parse)
        deleted = json["deletedDate"]?.string.flatMap(VaultDate.parse)
        archived = json["archivedDate"]?.string.flatMap(VaultDate.parse)

        switch self.type {
        case .login: payload = .login(Login(json: json["login"] ?? .null))
        case .secureNote: payload = .secureNote
        case .card: payload = .card(Card(json: json["card"] ?? .null))
        case .identity: payload = .identity(Identity(json: json["identity"] ?? .null))
        case .sshKey: payload = .sshKey(SSHKey(json: json["sshKey"] ?? .null))
        case .unknown:
            // Whatever is left once the keys every item has are taken away.
            let rest = (json.object ?? [:]).filter { !Item.commonKeys.contains($0.key) }
            let objects = rest.compactMap { $0.value.object }
            payload = .unknown(objects.count == 1 ? objects[0] : rest)
        }
    }

    private static let commonKeys: Set<String> = [
        "id", "object", "organizationId", "folderId", "type", "reprompt", "name", "notes",
        "favorite", "fields", "collectionIds", "revisionDate", "creationDate", "deletedDate",
        "archivedDate", "passwordHistory", "attachments", "key", "login", "card", "identity",
        "secureNote", "sshKey",
    ]

    /// The object to send for `edited`, which is this item after the editor
    /// has had it: the JSON this item was read from, with only the keys whose
    /// values differ replaced. Nothing else in the app builds JSON for a
    /// write. A passkey under `login.fido2Credentials`, and any key upstream
    /// adds after this was written, go back exactly as they came, because
    /// nothing here ever held them (`docs/notes.md`, "What an item looks
    /// like").
    ///
    /// A passkey made here goes on after the ones the login has, which is
    /// the one way into that list: nothing in the model holds it.
    ///
    /// Nil for a type this app does not know: it is never written (D11).
    func patched(_ edited: Item, holding passkey: MadePasskey? = nil) -> JSONValue? {
        if case .unknown = type { return nil }
        let before = Dictionary(uniqueKeysWithValues: modeled.map { ($0.path, $0.value) })
        let object = edited.modeled.reduce(raw) { object, leaf in
            before[leaf.path] == leaf.value ? object : object.setting(leaf.path, to: leaf.value)
        }
        guard let passkey else { return object }
        guard case .login = payload else { return nil }
        let kept = raw["login"]?["fido2Credentials"]?.array ?? []
        return object.setting(["login", "fido2Credentials"], to: .array(kept + [passkey.entry]))
    }

    /// The object to create a second one of this from: what `patched` gives
    /// for it with "copy" after its name, without the id, so the engine makes
    /// a new item, without the passkeys, which belong to the one account a
    /// site gave them to and stay with the original, without the
    /// attachments, whose files nobody has copied, and without the day it
    /// was archived, so the copy of an archived item is in the open. Nil
    /// where `patched` is.
    func copied() -> JSONValue? {
        var named = self
        named.name = "\(name) copy"
        guard var members = patched(named)?.object else { return nil }
        members["id"] = nil
        members["attachments"] = nil
        members[Shelf.archive.rawValue] = nil
        members[Shelf.trash.rawValue] = nil
        var copy = JSONValue.object(members)
        if case .login = payload { copy = copy.setting(["login", "fido2Credentials"], to: .array([])) }
        return copy
    }

    /// Where the engine keeps the day an item was put away. Nothing sets
    /// either in an object that is sent: the engine has a route for each.
    enum Shelf: String {
        case archive = "archivedDate"
        case trash = "deletedDate"
    }

    /// This item as the engine now has it, after a route that answers with
    /// nothing has put it on a shelf or taken it off: the same object with
    /// the one date changed.
    func put(on shelf: Shelf, at date: Date?) -> Item {
        let stamped = raw.setting([shelf.rawValue], to: JSONValue(date.map(VaultDate.string)))
        return (try? Item(json: stamped)) ?? self
    }

    /// This item as the server has it once its folder is deleted: the same
    /// object, in no folder.
    func outsideItsFolder() -> Item {
        (try? Item(json: raw.setting(["folderId"], to: .null))) ?? self
    }

    /// How many earlier passwords an item keeps, which is Bitwarden's own
    /// number.
    static let historyKept = 5

    /// This item with `old` first among its earlier passwords, as used
    /// until `date`, and no more of them than are kept.
    func remembering(_ old: String, at date: Date) -> Item {
        var remembered = self
        remembered.passwordHistory = Array(
            ([PasswordHistoryEntry(password: old, lastUsed: date)] + passwordHistory).prefix(Self.historyKept)
        )
        return remembered
    }

    /// False for a type this app does not know, which `patched` gives
    /// nothing for.
    var canBeWritten: Bool {
        if case .unknown = type { return false }
        return true
    }

    /// Every value this app can change, with where it lives in the object.
    private var modeled: [(path: [String], value: JSONValue)] {
        var leaves: [(path: [String], value: JSONValue)] = [
            (["name"], .string(name)),
            (["notes"], JSONValue(notes)),
            (["favorite"], .bool(favorite)),
            (["folderId"], JSONValue(folderID)),
            (["reprompt"], .int(reprompt ? 1 : 0)),
            (["fields"], .array(fields.map(\.json))),
            (["passwordHistory"], .array(passwordHistory.map(\.json))),
        ]
        switch payload {
        case .login(let login):
            leaves += [
                (["login", "username"], JSONValue(login.username)),
                (["login", "password"], JSONValue(login.password)),
                (["login", "totp"], JSONValue(login.totp)),
                (["login", "uris"], .array(login.uris.map(\.json))),
            ]
        case .card(let card):
            leaves += [
                (["card", "cardholderName"], JSONValue(card.cardholderName)),
                (["card", "brand"], JSONValue(card.brand)),
                (["card", "number"], JSONValue(card.number)),
                (["card", "expMonth"], JSONValue(card.expMonth)),
                (["card", "expYear"], JSONValue(card.expYear)),
                (["card", "code"], JSONValue(card.code)),
            ]
        case .identity(let identity):
            leaves += Identity.Key.allCases.map {
                (["identity", $0.rawValue], JSONValue(identity[$0]))
            }
        case .sshKey(let key):
            leaves += [
                (["sshKey", "privateKey"], JSONValue(key.privateKey)),
                (["sshKey", "publicKey"], JSONValue(key.publicKey)),
                (["sshKey", "keyFingerprint"], JSONValue(key.fingerprint)),
            ]
        case .secureNote, .unknown:
            break
        }
        return leaves
    }
}

extension Item: Redacted {
    var redactedLabel: String { "Item(\(id), type \(type.rawValue))" }
}

struct Login: Equatable, Redacted {
    var username: String?
    var password: String?
    /// A bare base32 secret, an `otpauth://` URI or `steam://<secret>`.
    var totp: String?
    var uris: [LoginURI]
    let passwordRevised: Date?
    /// When each passkey was made. The passkeys themselves stay in the item's
    /// raw object and are never copied into the model.
    let passkeysCreated: [Date?]

    init(json: JSONValue) {
        username = json["username"]?.string
        password = json["password"]?.string
        totp = json["totp"]?.string
        uris = (json["uris"]?.array ?? []).map(LoginURI.init(json:))
        passwordRevised = json["passwordRevisionDate"]?.string.flatMap(VaultDate.parse)
        passkeysCreated = (json["fido2Credentials"]?.array ?? []).map {
            $0["creationDate"]?.string.flatMap(VaultDate.parse)
        }
    }

    var redactedLabel: String { "Login" }
}

extension Login {
    /// What a login's username is called, from what is in it: "email" for
    /// an address and "username" for anything else, nothing at all
    /// included. Bitwarden keeps one value, `login.username`, and this is
    /// only the word over it: the details, the form as it is typed into,
    /// Quick Access and a linked field all ask here.
    static func word(forUsername username: String?) -> String {
        isEmail(username) ? "email" : "username"
    }

    var usernameWord: String { Login.word(forUsername: username) }

    /// Something before one @ and a dotted host after it, whatever the
    /// letters and whatever their case. A space anywhere, a second @, a
    /// host with no dot in it and one that begins or ends with a dot, as
    /// an address half typed does, are no address: the value is what is
    /// copied and typed, so it is judged as it stands and never trimmed.
    static func isEmail(_ username: String?) -> Bool {
        guard let username, !username.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }) else { return false }
        let halves = username.split(separator: "@", omittingEmptySubsequences: false)
        guard halves.count == 2, !halves[0].isEmpty else { return false }
        let labels = halves[1].split(separator: ".", omittingEmptySubsequences: false)
        return labels.count > 1 && !labels.contains { $0.isEmpty }
    }
}

struct LoginURI: Equatable {
    var uri: String
    /// Nil is the account's default, which is base domain.
    var match: URIMatch?

    init(uri: String, match: URIMatch? = nil) {
        self.uri = uri
        self.match = match
    }

    init(json: JSONValue) {
        uri = json["uri"]?.string ?? ""
        match = json["match"]?.int.flatMap(URIMatch.init(rawValue:))
    }

    var json: JSONValue {
        .object(["uri": .string(uri), "match": match.map { .int(Int64($0.rawValue)) } ?? .null])
    }
}

enum URIMatch: Int, CaseIterable {
    case baseDomain = 0, host, startsWith, exact, regularExpression, never
}

struct Card: Equatable, Redacted {
    var cardholderName: String?
    var brand: String?
    var number: String?
    var expMonth: String?
    var expYear: String?
    var code: String?

    init(json: JSONValue) {
        cardholderName = json["cardholderName"]?.string
        brand = json["brand"]?.string
        number = json["number"]?.string
        expMonth = json["expMonth"]?.string
        expYear = json["expYear"]?.string
        code = json["code"]?.string
    }

    var redactedLabel: String { "Card" }

    /// The last four characters of a card number, for the one place in the
    /// list and the one in the details that show them, or nil for a number
    /// under eight characters, which would have half of itself in them and
    /// is hidden whole.
    static func lastFour(of number: String?) -> String? {
        let written = (number ?? "").filter { !$0.isWhitespace }
        return written.count >= 8 ? String(written.suffix(4)) : nil
    }
}

struct Identity: Equatable, Redacted {
    /// The keys as `bw` spells them, in the order the details read them.
    enum Key: String, CaseIterable {
        case title, firstName, middleName, lastName, company, email, phone, username
        case address1, address2, address3, city, state, postalCode, country
        case ssn, passportNumber, licenseNumber

        var isHidden: Bool { self == .ssn || self == .passportNumber || self == .licenseNumber }
    }

    private var values: [Key: String]

    init(json: JSONValue) {
        values = [:]
        for key in Key.allCases { values[key] = json[key.rawValue]?.string }
    }

    subscript(key: Key) -> String? {
        get { values[key] }
        set { values[key] = newValue }
    }

    var redactedLabel: String { "Identity" }
}

struct SSHKey: Equatable, Redacted {
    var privateKey: String?
    var publicKey: String?
    var fingerprint: String?

    init(json: JSONValue) {
        privateKey = json["privateKey"]?.string
        publicKey = json["publicKey"]?.string
        fingerprint = json["keyFingerprint"]?.string
    }

    var redactedLabel: String { "SSHKey" }
}

struct Field: Equatable, Redacted {
    enum Kind: Int, CaseIterable {
        case text = 0, hidden, boolean, linked
    }

    var name: String?
    var value: String?
    var kind: Kind
    /// For a linked field, which of the item's own fields it points at.
    var linkedID: Int?

    init(name: String?, value: String?, kind: Kind, linkedID: Int? = nil) {
        self.name = name
        self.value = value
        self.kind = kind
        self.linkedID = linkedID
    }

    init(json: JSONValue) {
        name = json["name"]?.string
        value = json["value"]?.string
        kind = json["type"]?.int.flatMap(Kind.init(rawValue:)) ?? .text
        linkedID = json["linkedId"]?.int
    }

    var json: JSONValue {
        .object([
            "name": JSONValue(name), "value": JSONValue(value), "type": .int(Int64(kind.rawValue)),
            "linkedId": linkedID.map { .int(Int64($0)) } ?? .null,
        ])
    }

    var redactedLabel: String { "Field(type \(kind.rawValue))" }
}

struct PasswordHistoryEntry: Equatable, Redacted {
    var password: String
    /// As `bw` wrote it, so an entry that was not touched goes back with the
    /// same string and not a reformatted one.
    var lastUsedDate: String?

    var lastUsed: Date? { lastUsedDate.flatMap(VaultDate.parse) }

    init(password: String, lastUsed: Date) {
        self.password = password
        lastUsedDate = VaultDate.string(lastUsed)
    }

    init(json: JSONValue) {
        password = json["password"]?.string ?? ""
        lastUsedDate = json["lastUsedDate"]?.string
    }

    var json: JSONValue {
        .object(["lastUsedDate": JSONValue(lastUsedDate), "password": .string(password)])
    }

    var redactedLabel: String { "PasswordHistoryEntry" }
}

struct Attachment: Equatable, Identifiable {
    let id: String
    let fileName: String
    /// Bytes, which `bw` sends as a string.
    let size: Int?
    let sizeName: String?

    init(json: JSONValue) {
        id = json["id"]?.string ?? ""
        fileName = json["fileName"]?.string ?? ""
        size = json["size"]?.string.flatMap(Int.init) ?? json["size"]?.int
        sizeName = json["sizeName"]?.string
    }
}

/// A vault, in this app's words (D9).
struct Folder: Equatable, Identifiable {
    let id: String
    var name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// Nil for the row `bw` adds to every list for the items in no folder,
    /// "No Folder", whose id 2026.9.1 sends as an empty string. The
    /// sidebar draws Personal for those itself.
    init?(json: JSONValue) {
        guard let id = json["id"]?.string, !id.isEmpty, let name = json["name"]?.string else { return nil }
        self.id = id
        self.name = name
    }
}

/// `bw` writes ISO 8601 in UTC, with fractional seconds on some dates and
/// without on others.
enum VaultDate {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let whole = ISO8601DateFormatter()

    static func parse(_ string: String) -> Date? {
        fractional.date(from: string) ?? whole.date(from: string)
    }

    static func string(_ date: Date) -> String {
        fractional.string(from: date)
    }
}
