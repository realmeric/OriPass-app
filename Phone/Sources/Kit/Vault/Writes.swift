import CryptoKit
import Foundation

/// What a form holds for a login or a note, in the clear, while it is open.
struct Draft: Equatable, Sendable, Redacted {
    var kind = Item.Kind.login
    var name = ""
    var username = ""
    var password = ""
    var uris: [String] = []
    var totp = ""
    var notes = ""
    var favorite = false
    /// A card's, an identity's or a key's values, under Bitwarden's names.
    var values: [String: String] = [:]
    /// A passkey just made, to go on the login beside any it has.
    var passkey: Item.Passkey?

    var redactedLabel: String { "Draft" }

    init(kind: Item.Kind = .login) {
        self.kind = kind
    }

    init(_ item: Item) {
        kind = item.kind
        name = item.name
        username = item.login?.username ?? ""
        password = item.login?.password ?? ""
        uris = item.login?.uris.map(\.uri) ?? []
        totp = item.login?.totp ?? ""
        notes = item.notes ?? ""
        favorite = item.favorite
        values = Dictionary(item.values.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    /// The JSON key the server keeps a type's values under.
    static func part(for kind: Item.Kind) -> String? {
        switch kind {
        case .card: "card"
        case .identity: "identity"
        case .sshKey: "sshKey"
        default: nil
        }
    }
}

/// The bodies of the two writes. An edit is the cipher as the server sent
/// it, with only the strings the form changed encrypted again under the
/// item's own key and every other string sent back as it came, so that a
/// passkey, a field or an attachment the app does not draw survives a save.
/// The old password goes first into the history when the password changed.
enum Writes {
    static func edit(_ raw: [String: Any], from item: Item, to draft: Draft, key: VaultKey, now: Date = .now) throws -> [String: Any] {
        var body = raw
        for name in ["object", "id", "edit", "viewPassword", "permissions", "data", "attachments", "collectionIds",
                     "organizationUseTotp", "creationDate", "deletedDate"] {
            body.removeValue(forKey: name)
        }
        body["lastKnownRevisionDate"] = raw["revisionDate"]
        body.removeValue(forKey: "revisionDate")
        let before = Draft(item)
        if draft.name != before.name { body["name"] = try seal(draft.name, key) }
        if draft.notes != before.notes { body["notes"] = draft.notes.isEmpty ? NSNull() : try seal(draft.notes, key) }
        if draft.favorite != before.favorite { body["favorite"] = draft.favorite }
        if let part = Draft.part(for: item.kind) {
            var values = raw[part] as? [String: Any] ?? [:]
            for name in Set(before.values.keys).union(draft.values.keys) {
                let now = draft.values[name] ?? ""
                if now != before.values[name] ?? "" { values[name] = try optional(now, key) }
            }
            body[part] = values
            return body
        }
        guard item.kind == .login else { return body }

        var login = raw["login"] as? [String: Any] ?? [:]
        if draft.username != before.username { login["username"] = try optional(draft.username, key) }
        if draft.totp != before.totp { login["totp"] = try optional(draft.totp, key) }
        if draft.password != before.password {
            login["password"] = try optional(draft.password, key)
            login["passwordRevisionDate"] = stamp(now)
            if !before.password.isEmpty {
                var history = raw["passwordHistory"] as? [Any] ?? []
                history.insert(["password": try seal(before.password, key), "lastUsedDate": stamp(now)], at: 0)
                body["passwordHistory"] = Array(history.prefix(5))
            }
        }
        if draft.uris != before.uris {
            let kept = raw["login"].flatMap { ($0 as? [String: Any])?["uris"] as? [[String: Any]] } ?? []
            login["uris"] = try draft.uris.filter { !$0.isEmpty }.map { uri in
                // An address the form did not change keeps its strings and rule.
                if let index = before.uris.firstIndex(of: uri), index < kept.count { return kept[index] }
                return try address(uri, key)
            }
        }
        if let passkey = draft.passkey {
            login["fido2Credentials"] = (login["fido2Credentials"] as? [Any] ?? []) + [try credential(passkey, key, now)]
        }
        body["login"] = login
        return body
    }

    static func create(_ draft: Draft, key: VaultKey, now: Date = .now) throws -> [String: Any] {
        let type = switch draft.kind {
        case .note: 2
        case .card: 3
        case .identity: 4
        case .sshKey: 5
        default: 1
        }
        var body: [String: Any] = [
            "type": type, "name": try seal(draft.name, key),
            "notes": draft.notes.isEmpty ? NSNull() : try seal(draft.notes, key),
            "favorite": draft.favorite, "reprompt": 0, "folderId": NSNull(), "organizationId": NSNull(),
        ]
        if let part = Draft.part(for: draft.kind) {
            body[part] = try draft.values.filter { !$0.value.isEmpty }.mapValues { try seal($0, key) }
        } else if draft.kind == .note {
            body["secureNote"] = ["type": 0]
        } else {
            var login: [String: Any] = [
                "username": try optional(draft.username, key), "password": try optional(draft.password, key),
                "totp": try optional(draft.totp, key),
                "uris": try draft.uris.filter { !$0.isEmpty }.map { try address($0, key) },
            ]
            if let passkey = draft.passkey { login["fido2Credentials"] = [try credential(passkey, key, now)] }
            body["login"] = login
        }
        return body
    }

    private static func seal(_ text: String, _ key: VaultKey) throws -> String {
        try EncString.encrypt(text, with: key).text
    }

    private static func optional(_ text: String, _ key: VaultKey) throws -> Any {
        text.isEmpty ? NSNull() : try seal(text, key)
    }

    private static func address(_ uri: String, _ key: VaultKey) throws -> [String: Any] {
        let checksum = Data(SHA256.hash(data: Data(uri.utf8))).base64EncodedString()
        return ["uri": try seal(uri, key), "uriChecksum": try seal(checksum, key), "match": NSNull()]
    }

    /// A passkey as the server keeps one: every value encrypted under the
    /// item's key, and its date alone in the clear.
    private static func credential(_ passkey: Item.Passkey, _ key: VaultKey, _ now: Date) throws -> [String: Any] {
        let values: [String: String?] = [
            "credentialId": passkey.credentialId, "keyType": "public-key", "keyAlgorithm": passkey.keyAlgorithm,
            "keyCurve": "P-256", "keyValue": passkey.keyValue, "rpId": passkey.rpId, "rpName": passkey.rpName,
            "userHandle": passkey.userHandle, "userName": passkey.userName, "userDisplayName": passkey.userDisplayName,
            "counter": passkey.counter, "discoverable": passkey.discoverable ? "true" : "false",
        ]
        var entry: [String: Any] = try values.mapValues { try $0.map { try seal($0, key) } ?? NSNull() }
        entry["creationDate"] = stamp(now)
        return entry
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// The cipher with that id, as the last sync sent it.
    static func raw(_ id: String, in data: Data) -> [String: Any]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ciphers = json["ciphers"] as? [[String: Any]] else { return nil }
        return ciphers.first { $0["id"] as? String == id }
    }
}
