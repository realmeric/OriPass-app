import Foundation

/// One item of the open vault, decrypted. What the screens and the
/// extension read; it prints as its id and nothing more.
struct Item: Identifiable, Sendable, Redacted {
    enum Kind: Hashable, Sendable {
        case login, note, card, identity, sshKey
        case unknown(Int)

        init(_ type: Int) {
            switch type {
            case 1: self = .login
            case 2: self = .note
            case 3: self = .card
            case 4: self = .identity
            case 5: self = .sshKey
            default: self = .unknown(type)
            }
        }
    }

    let id: String
    let kind: Kind
    var name: String
    var notes: String?
    var favorite: Bool
    var folderId: String?
    var organizationId: String?
    var deleted: Bool
    var archived: Bool
    var asksAgain: Bool
    var revised: Date?
    var created: Date?
    var login: Login?
    /// A card's, an identity's and a key's values, in the order a screen
    /// shows them, under the server's names for them.
    var values: [(key: String, value: String)]
    var fields: [Field]
    var history: [(password: String, used: Date?)]

    var redactedLabel: String { "Item(\(id))" }

    struct Login: Sendable {
        var username: String?
        var password: String?
        var totp: String?
        var passwordRevised: Date?
        var uris: [Uri]
        var passkeys: [Passkey]
    }

    struct Uri: Sendable, Equatable {
        var uri: String
        /// Bitwarden's rule for matching it: nil is the account's default.
        var match: Int?
    }

    struct Field: Sendable {
        /// 0 text, 1 hidden, 2 a switch, 3 linked to another value.
        var type: Int
        var name: String?
        var value: String?
        var linkedId: Int?
    }

    /// A passkey kept in a login, with its private key as PKCS#8.
    struct Passkey: Sendable, Equatable {
        var credentialId: String
        var rpId: String
        var rpName: String?
        var userName: String?
        var userDisplayName: String?
        var userHandle: String?
        var keyValue: String
        var keyAlgorithm: String?
        var counter: String?
        var discoverable: Bool
    }

    var value: (String) -> String? {
        { key in values.first { $0.key == key }?.value }
    }
}

/// What the extension's list and the identity store need of an item, and
/// nothing more: decrypting it costs three strings a login.
struct Summary: Identifiable, Sendable, Equatable, Redacted {
    let id: String
    let kind: Item.Kind
    var name: String
    var username: String?
    var uris: [Item.Uri]
    var hasPassword: Bool
    var hasTotp: Bool
    var passkeys: [PasskeySummary]
    var favorite: Bool
    var asksAgain: Bool

    var redactedLabel: String { "Summary(\(id))" }

    struct PasskeySummary: Sendable, Equatable {
        var credentialId: String
        var rpId: String
        var userName: String?
        var userHandle: String?
    }
}
