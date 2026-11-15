import Foundation

/// What the editor's form holds for an item (`docs/look.md`, "Editing"):
/// every value as the text in its field, so that nothing in it is absent,
/// only empty. The parts that are another type's stay empty. `applied` turns it back into an item, and takes from the form
/// only the parts that are no longer what the item had, so a username that
/// was `null` and was never typed into does not go back as an empty string.
struct EditorForm: Equatable, Redacted {
    struct Address: Equatable, Identifiable {
        /// Its place in the item for one the item had, and a number past
        /// every place for one added here.
        let id: Int
        var uri: String
        /// Nil is the account's default.
        var match: URIMatch?
    }

    struct CustomField: Equatable, Identifiable, Redacted {
        let id: Int
        var name: String
        /// A boolean's is `true` or `false`, as Bitwarden writes it, and a
        /// linked field's is empty.
        var value: String
        var kind: Field.Kind
        var linkedID: Int?

        var redactedLabel: String { "CustomField(\(id))" }

        var isOn: Bool {
            get { value == "true" }
            set { value = newValue ? "true" : "false" }
        }

        /// The field as an item holds it: an empty name or value is none.
        var field: Field {
            switch kind {
            case .text, .hidden:
                return Field(name: name.isEmpty ? nil : name, value: value.isEmpty ? nil : value, kind: kind)
            case .boolean:
                return Field(name: name.isEmpty ? nil : name, value: isOn ? "true" : "false", kind: kind)
            case .linked:
                return Field(name: name.isEmpty ? nil : name, value: nil, kind: kind, linkedID: linkedID)
            }
        }
    }

    struct CardPart: Equatable, Redacted {
        var holder = ""
        /// One of `Card.brands`, or whatever else the item came with.
        var brand = ""
        var number = ""
        /// `1` to `12`, as Bitwarden writes a month.
        var month = ""
        var year = ""
        var code = ""

        var redactedLabel: String { "CardPart" }
    }

    /// An identity's eighteen values by their keys, three of them numbers
    /// the form hides. A dictionary would spell them out when printed.
    struct IdentityPart: Equatable, Redacted {
        private var held: [Identity.Key: String] = [:]

        var redactedLabel: String { "IdentityPart" }

        subscript(key: Identity.Key) -> String? {
            get { held[key] }
            set { held[key] = newValue }
        }
    }

    /// A key's three values, which are only ever changed together, by a
    /// paste (`PastedKey`).
    struct KeyPart: Equatable, Redacted {
        var privateKey = ""
        var publicKey = ""
        var fingerprint = ""

        var redactedLabel: String { "KeyPart" }
    }

    /// An identity's rows in the order the details read them, the short
    /// ones two to a row.
    static let identityRows: [[Identity.Key]] = [
        [.title, .firstName], [.middleName, .lastName], [.company], [.email], [.phone], [.username],
        [.address1], [.address2], [.address3], [.postalCode, .city], [.state, .country],
        [.ssn], [.passportNumber], [.licenseNumber],
    ]

    /// What a linked field of each type can point at, by Bitwarden's
    /// numbers (`ItemDetail.linked`). A note and a key have nothing.
    static func linkable(in type: ItemType, username: String? = nil) -> [(id: Int, name: String)] {
        switch type {
        case .login:
            return [(100, Login.word(forUsername: username)), (101, "password")]
        case .card:
            return [(300, "cardholder name"), (304, "brand"), (305, "number"), (301, "expiry month"),
                    (302, "expiry year"), (303, "security code")]
        case .identity:
            return identityRows.joined().map { ($0.linkedID, $0.label) }
        case .secureNote, .sshKey, .unknown:
            return []
        }
    }

    var title: String
    var username: String
    /// What the username's field is called while it holds this.
    var usernameWord: String { Login.word(forUsername: username) }
    var password: String
    /// The one-time code's secret, as it is kept: bare, or an `otpauth://`
    /// address.
    var totp: String
    var addresses: [Address]
    var card = CardPart()
    var identity = IdentityPart()
    var key = KeyPart()
    var fields: [CustomField]
    var notes: String
    var isFavourite: Bool
    /// Bitwarden's `reprompt`: the item asks again before it gives
    /// anything up (`Reprompt`).
    var asksAgain: Bool
    /// Nil is Personal.
    var folderID: String?

    var redactedLabel: String { "EditorForm" }

    init(item: Item) {
        title = item.name
        username = item.login?.username ?? ""
        password = item.login?.password ?? ""
        totp = item.login?.totp ?? ""
        addresses = (item.login?.uris ?? []).enumerated().map { Address(id: $0, uri: $1.uri, match: $1.match) }
        fields = item.fields.enumerated().map { place, field in
            CustomField(id: place, name: field.name ?? "", value: field.value ?? "", kind: field.kind,
                        linkedID: field.linkedID)
        }
        notes = item.notes ?? ""
        isFavourite = item.favorite
        asksAgain = item.reprompt
        folderID = item.folderID
        switch item.payload {
        case .card(let held):
            card = CardPart(holder: held.cardholderName ?? "", brand: held.brand ?? "", number: held.number ?? "",
                            month: held.expMonth ?? "", year: held.expYear ?? "", code: held.code ?? "")
        case .identity(let held):
            for key in Identity.Key.allCases { identity[key] = held[key] ?? "" }
        case .sshKey(let held):
            key = KeyPart(privateKey: held.privateKey ?? "", publicKey: held.publicKey ?? "",
                          fingerprint: held.fingerprint ?? "")
        case .login, .secureNote, .unknown:
            break
        }
    }

    /// `item` with what the form now says. A part of the form that still
    /// says what `item` says leaves that part of the item exactly as it
    /// was, down to the one address or the one custom field, so `patched`
    /// finds nothing to send for it. An address left empty is not kept.
    func applied(to item: Item) -> Item {
        let was = EditorForm(item: item)
        var edited = item
        edited.name = title
        if notes != was.notes { edited.notes = Self.written(notes) }
        edited.favorite = isFavourite
        edited.reprompt = asksAgain
        edited.folderID = folderID
        if fields != was.fields {
            edited.fields = fields.map { field in
                was.fields.first { $0.id == field.id } == field ? item.fields[field.id] : field.field
            }
        }
        switch item.payload {
        case .login(let login):
            edited.payload = .login(applied(to: login, was: was))
        case .card(var held):
            if card.holder != was.card.holder { held.cardholderName = Self.written(card.holder) }
            if card.brand != was.card.brand { held.brand = Self.written(card.brand) }
            if card.number != was.card.number { held.number = Self.written(card.number) }
            if card.month != was.card.month { held.expMonth = Self.written(card.month) }
            if card.year != was.card.year {
                held.expYear = Self.written(card.year.trimmingCharacters(in: .whitespaces))
            }
            if card.code != was.card.code { held.code = Self.written(card.code) }
            edited.payload = .card(held)
        case .identity(var held):
            for key in Identity.Key.allCases where identity[key] != was.identity[key] {
                held[key] = Self.written(identity[key] ?? "")
            }
            edited.payload = .identity(held)
        case .sshKey(var held):
            if key != was.key {
                held.privateKey = Self.written(key.privateKey)
                held.publicKey = Self.written(key.publicKey)
                held.fingerprint = Self.written(key.fingerprint)
            }
            edited.payload = .sshKey(held)
        case .secureNote, .unknown:
            break
        }
        return edited
    }

    private func applied(to held: Login, was: EditorForm) -> Login {
        var login = held
        if username != was.username { login.username = Self.written(username) }
        if password != was.password { login.password = Self.written(password) }
        if totp != was.totp { login.totp = Self.written(totp) }
        if addresses != was.addresses {
            login.uris = addresses.compactMap { address in
                if was.addresses.first(where: { $0.id == address.id }) == address { return login.uris[address.id] }
                let uri = address.uri.trimmingCharacters(in: .whitespacesAndNewlines)
                return uri.isEmpty ? nil : LoginURI(uri: uri, match: address.match)
            }
        }
        return login
    }

    private static func written(_ text: String) -> String? { text.isEmpty ? nil : text }

    /// The form after the item under it was changed somewhere else: every
    /// part he had not touched now says what `newer` says, and every part
    /// he had is as he left it. The addresses are one part and the custom
    /// fields another, so a list he changed at all is his whole.
    func rebased(from older: Item, onto newer: Item) -> EditorForm {
        let was = EditorForm(item: older)
        var form = EditorForm(item: newer)
        if title != was.title { form.title = title }
        if username != was.username { form.username = username }
        if password != was.password { form.password = password }
        if totp != was.totp { form.totp = totp }
        if addresses != was.addresses { form.addresses = addresses }
        if card.holder != was.card.holder { form.card.holder = card.holder }
        if card.brand != was.card.brand { form.card.brand = card.brand }
        if card.number != was.card.number { form.card.number = card.number }
        if card.month != was.card.month { form.card.month = card.month }
        if card.year != was.card.year { form.card.year = card.year }
        if card.code != was.card.code { form.card.code = card.code }
        for key in Identity.Key.allCases where identity[key] != was.identity[key] { form.identity[key] = identity[key] }
        if key != was.key { form.key = key }
        if fields != was.fields { form.fields = fields }
        if notes != was.notes { form.notes = notes }
        if isFavourite != was.isFavourite { form.isFavourite = isFavourite }
        if asksAgain != was.asksAgain { form.asksAgain = asksAgain }
        if folderID != was.folderID { form.folderID = folderID }
        return form
    }
}

extension URIMatch {
    /// What the menu behind an address calls the rule.
    var name: String {
        switch self {
        case .baseDomain: return "Base domain"
        case .host: return "Host"
        case .startsWith: return "Starts with"
        case .exact: return "Exact"
        case .regularExpression: return "Regular expression"
        case .never: return "Never"
        }
    }

    /// The rule that is no rule: whatever the account matches by.
    static let defaultName = "Default"
}

extension Field.Kind {
    /// What "add more" calls each kind of custom field.
    var name: String {
        switch self {
        case .text: return "Text"
        case .hidden: return "Hidden"
        case .boolean: return "Tick box"
        case .linked: return "Linked"
        }
    }
}

extension Card {
    /// The brands Bitwarden's own forms offer, as it spells them.
    static let brands = ["Visa", "Mastercard", "Amex", "Discover", "Diners Club", "JCB", "Maestro", "UnionPay",
                         "RuPay", "Other"]

    /// The twelve months, as the expiry's menu names them.
    static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                         "October", "November", "December"]

    /// `7` and `07` as `07`, and anything that is no month as it is.
    static func month(_ written: String) -> String {
        let trimmed = written.trimmingCharacters(in: .whitespaces)
        return Int(trimmed).flatMap { (1...12).contains($0) ? String(format: "%02d", $0) : nil } ?? trimmed
    }
}

extension Identity.Key {
    /// What the form calls the row, which is what the details call it.
    var label: String {
        switch self {
        case .title: return "title"
        case .firstName: return "first name"
        case .middleName: return "middle name"
        case .lastName: return "last name"
        case .company: return "company"
        case .email: return "email"
        case .phone: return "phone"
        case .username: return "username"
        case .address1: return "address"
        case .address2: return "address, second line"
        case .address3: return "address, third line"
        case .city: return "city"
        case .state: return "state"
        case .postalCode: return "postal code"
        case .country: return "country"
        case .ssn: return "social security number"
        case .passportNumber: return "passport number"
        case .licenseNumber: return "licence number"
        }
    }

    /// Bitwarden's number for a linked field that points here.
    var linkedID: Int {
        switch self {
        case .title: return 400
        case .middleName: return 401
        case .address1: return 402
        case .address2: return 403
        case .address3: return 404
        case .city: return 405
        case .state: return 406
        case .postalCode: return 407
        case .country: return 408
        case .company: return 409
        case .email: return 410
        case .phone: return 411
        case .ssn: return 412
        case .username: return 413
        case .passportNumber: return 414
        case .licenseNumber: return 415
        case .firstName: return 416
        case .lastName: return 417
        }
    }
}
