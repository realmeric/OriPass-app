import Foundation

/// What a vault holds, in counts and never a value: items by type, the
/// encrypted strings by their type, the items that did not open and why,
/// and how the master key is made. What a person reads off the phone for the
/// notes.
struct Census: Sendable, Equatable {
    var items: [String: Int] = [:]
    var strings: [Int: Int] = [:]
    var unread: [String: Int] = [:]
    var withOwnKey = 0
    var withCode = 0
    var withPasskey = 0
    var inOrganisations = 0
    var inTrash = 0

    init(vault: Vault, data: Data) {
        for cipher in vault.answer.ciphers {
            items[Census.name(Item.Kind(cipher.type)), default: 0] += 1
            if cipher.key != nil { withOwnKey += 1 }
            if cipher.login?.totp?.isEmpty == false { withCode += 1 }
            if cipher.login?.fido2Credentials?.isEmpty == false { withPasskey += 1 }
            if cipher.organizationId != nil { inOrganisations += 1 }
            if cipher.deletedDate != nil { inTrash += 1 }
        }
        for reason in vault.items().unread.values { unread["\(reason)", default: 0] += 1 }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ciphers = json["ciphers"] { Census.count(ciphers, into: &strings) }
    }

    static func name(_ kind: Item.Kind) -> String {
        switch kind {
        case .login: "Logins"
        case .note: "Notes"
        case .card: "Cards"
        case .identity: "Identities"
        case .sshKey: "SSH Keys"
        case .unknown(let type): "Type \(type)"
        }
    }

    /// Every string in the ciphers that reads as an encrypted one, by type.
    private static func count(_ value: Any, into strings: inout [Int: Int]) {
        switch value {
        case let text as String:
            if let string = try? EncString(text) { strings[string.type, default: 0] += 1 }
            else if text.hasPrefix("7.") { strings[7, default: 0] += 1 }
        case let list as [Any]:
            for element in list { count(element, into: &strings) }
        case let object as [String: Any]:
            for (key, element) in object where key != "id" && !key.hasSuffix("Id") && !key.hasSuffix("Date") {
                count(element, into: &strings)
            }
        default:
            break
        }
    }
}
