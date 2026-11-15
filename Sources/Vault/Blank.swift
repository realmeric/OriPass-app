import Foundation

extension ItemType {
    /// The key an item's own values sit under, and nil for a type this app
    /// does not know.
    var payloadKey: String? {
        switch self {
        case .login: return "login"
        case .secureNote: return "secureNote"
        case .card: return "card"
        case .identity: return "identity"
        case .sshKey: return "sshKey"
        case .unknown: return nil
        }
    }

    /// What `bw get template` calls the object under that key.
    var templateName: String? { payloadKey.map { "item.\($0.lowercased())" } }
}

extension Item {
    /// A key's three values, for an engine that has no template for a key.
    static let keyPart = JSONValue.object(["privateKey": .null, "publicKey": .null, "keyFingerprint": .null])

    /// An item of `type` that the engine has not been told of: its template
    /// for an item with its template for the type under the type's key, in
    /// `folder` or in none. The templates are examples, "Item name" and
    /// "jdoe" and a card number, so only their keys are kept: every string
    /// in them is gone and every list is empty. The form is filled from
    /// this as it is from any item, and `patched` then sends the template's
    /// own shape with what was typed in it.
    static func blank(_ type: ItemType, from template: JSONValue, part: JSONValue,
                      in folder: String?) throws -> Item {
        guard let key = type.payloadKey, template.object != nil, part.object != nil else {
            throw ShapeError(missing: "template")
        }
        return try Item(json: template.emptied
            .setting(["type"], to: .int(Int64(type.rawValue)))
            .setting(["name"], to: .string(""))
            .setting(["folderId"], to: JSONValue(folder))
            .setting([key], to: part.emptied))
    }

    /// Not saved yet, so the engine has given it no id.
    var isNew: Bool { id.isEmpty }
}

private extension JSONValue {
    /// The same keys with nothing said under them: no string, no member of
    /// a list. A number and a switch stay, which is a note's `type` and an
    /// item's `favorite`.
    var emptied: JSONValue {
        switch self {
        case .string: return .null
        case .array: return .array([])
        case .object(let members): return .object(members.mapValues(\.emptied))
        case .null, .bool, .int, .double: return self
        }
    }
}
