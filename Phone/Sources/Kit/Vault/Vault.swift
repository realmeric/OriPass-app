import CryptoKit
import Foundation

/// The vault opened: the sync's answer with its keys unwrapped, from which
/// items are decrypted when they are asked for. All of it, one item, or
/// the little of each the extension's list needs.
struct Vault: Sendable {
    let answer: SyncAnswer
    let userKey: VaultKey
    /// Each organisation's key, by its id.
    let organisationKeys: [String: VaultKey]
    let premium: Bool

    /// Why an item could not be opened, counted and never shown wrong.
    enum Unread: Equatable, Sendable, Hashable {
        case newerEncryption
        case wrongKey
        case noOrganisationKey
        case unreadable
    }

    init(data: Data, userKey: VaultKey) throws {
        let answer = try Cipher.decoder.decode(SyncAnswer.self, from: data)
        self.answer = answer
        self.userKey = userKey
        premium = answer.profile.premium ?? false
        var keys: [String: VaultKey] = [:]
        let wrapped = answer.profile.accountKeys?.publicKeyEncryptionKeyPair?.wrappedPrivateKey ?? answer.profile.privateKey
        // A private key that does not open leaves the organisations' items
        // unread and the account's own as they are.
        if let wrapped, let organisations = answer.profile.organizations, !organisations.isEmpty,
           let privateKey = try? RSAPrivateKey(pkcs8: EncString(wrapped).decrypt(with: userKey)) {
            for organisation in organisations {
                guard let sealed = organisation.key,
                      let key = try? VaultKey(EncString(sealed).decrypt(with: privateKey)) else { continue }
                keys[organisation.id] = key
            }
        }
        organisationKeys = keys
    }

    var count: Int { answer.ciphers.count }

    /// Every item that opens, and why each one that did not.
    func items() -> (items: [Item], unread: [String: Unread]) {
        var items: [Item] = []
        var unread: [String: Unread] = [:]
        for cipher in answer.ciphers {
            do {
                items.append(try Opener(cipher: cipher, vault: self).item())
            } catch {
                unread[cipher.id] = Vault.reason(error)
            }
        }
        return (items, unread)
    }

    func item(id: String) throws -> Item {
        guard let cipher = answer.ciphers.first(where: { $0.id == id }) else { throw CryptoError.unreadable }
        return try Opener(cipher: cipher, vault: self).item()
    }

    /// The live items' summaries, the trash and the archive left out.
    func summaries() -> [Summary] {
        answer.ciphers.compactMap { cipher in
            guard cipher.deletedDate == nil, cipher.archivedDate == nil else { return nil }
            return try? Opener(cipher: cipher, vault: self).summary()
        }
    }

    /// The key an item's strings are encrypted under: its own, or its
    /// organisation's, or the user's.
    func key(for id: String) throws -> VaultKey {
        guard let cipher = answer.ciphers.first(where: { $0.id == id }) else { throw CryptoError.unreadable }
        return try Opener(cipher: cipher, vault: self).key
    }

    func folders() -> [(id: String, name: String)] {
        (answer.folders ?? []).compactMap { folder in
            guard let name = try? folder.name.map({ try EncString($0).decryptString(with: userKey) }) else { return nil }
            return (folder.id, name)
        }
    }

    static func reason(_ error: Error) -> Unread {
        if error is Missing { return .noOrganisationKey }
        switch error as? CryptoError {
        case .unsupported(type: 7): return .newerEncryption
        case .wrongKey: return .wrongKey
        default: return .unreadable
        }
    }

    struct Missing: Error {}

    /// One cipher's strings under its key: its own when it has one, sealed
    /// under the user's or its organisation's.
    private struct Opener {
        let cipher: Cipher
        let key: VaultKey

        init(cipher: Cipher, vault: Vault) throws {
            self.cipher = cipher
            var base = vault.userKey
            if let organisation = cipher.organizationId {
                guard let key = vault.organisationKeys[organisation] else { throw Missing() }
                base = key
            }
            if let own = cipher.key {
                key = try VaultKey(EncString(own).decrypt(with: base))
            } else {
                key = base
            }
        }

        func text(_ value: String?) throws -> String? {
            guard let value, !value.isEmpty else { return nil }
            return try EncString(value).decryptString(with: key)
        }

        func uris() throws -> [Item.Uri] {
            try (cipher.login?.uris ?? []).compactMap { uri in
                guard let plain = try text(uri.uri) else { return nil }
                // A checksum that does not match is an address moved from
                // another item, and is dropped as Bitwarden's apps drop it.
                if let checksum = try text(uri.uriChecksum),
                   checksum != Data(SHA256.hash(data: Data(plain.utf8))).base64EncodedString() { return nil }
                return Item.Uri(uri: plain, match: uri.match)
            }
        }

        func item() throws -> Item {
            var login: Item.Login?
            if let part = cipher.login {
                login = Item.Login(
                    username: try text(part.username), password: try text(part.password), totp: try text(part.totp),
                    passwordRevised: part.passwordRevisionDate, uris: try uris(),
                    passkeys: try (part.fido2Credentials ?? []).map(passkey))
            }
            var values: [(key: String, value: String)] = []
            let order: [String]
            let part: [String: String?]?
            switch Item.Kind(cipher.type) {
            case .card: (order, part) = (Vault.cardOrder, cipher.card)
            case .identity: (order, part) = (Vault.identityOrder, cipher.identity)
            case .sshKey: (order, part) = (Vault.sshOrder, cipher.sshKey)
            default: (order, part) = ([], nil)
            }
            for name in order {
                if let sealed = part?[name] ?? nil, let plain = try text(sealed) { values.append((name, plain)) }
            }
            return Item(
                id: cipher.id, kind: Item.Kind(cipher.type), name: try text(cipher.name) ?? "",
                notes: try text(cipher.notes), favorite: cipher.favorite ?? false, folderId: cipher.folderId,
                organizationId: cipher.organizationId, deleted: cipher.deletedDate != nil,
                archived: cipher.archivedDate != nil, asksAgain: (cipher.reprompt ?? 0) == 1,
                revised: cipher.revisionDate, created: cipher.creationDate, login: login, values: values,
                fields: try (cipher.fields ?? []).map {
                    Item.Field(type: $0.type, name: try text($0.name), value: try text($0.value), linkedId: $0.linkedId)
                },
                history: try (cipher.passwordHistory ?? []).compactMap { entry in
                    try text(entry.password).map { ($0, entry.lastUsedDate) }
                })
        }

        func summary() throws -> Summary {
            Summary(
                id: cipher.id, kind: Item.Kind(cipher.type), name: try text(cipher.name) ?? "",
                username: try text(cipher.login?.username), uris: try uris(),
                hasPassword: cipher.login?.password?.isEmpty == false, hasTotp: cipher.login?.totp?.isEmpty == false,
                passkeys: try (cipher.login?.fido2Credentials ?? []).map { credential in
                    Summary.PasskeySummary(credentialId: try text(credential["credentialId"] ?? nil) ?? "",
                                           rpId: try text(credential["rpId"] ?? nil) ?? "",
                                           userName: try text(credential["userName"] ?? nil),
                                           userHandle: try text(credential["userHandle"] ?? nil))
                },
                favorite: cipher.favorite ?? false, asksAgain: (cipher.reprompt ?? 0) == 1)
        }

        func passkey(_ credential: [String: String?]) throws -> Item.Passkey {
            func value(_ name: String) throws -> String? { try text(credential[name] ?? nil) }
            return Item.Passkey(
                credentialId: try value("credentialId") ?? "", rpId: try value("rpId") ?? "",
                rpName: try value("rpName"), userName: try value("userName"),
                userDisplayName: try value("userDisplayName"), userHandle: try value("userHandle"),
                keyValue: try value("keyValue") ?? "", keyAlgorithm: try value("keyAlgorithm"), counter: try value("counter"),
                discoverable: try value("discoverable") == "true")
        }
    }

    static let cardOrder = ["cardholderName", "brand", "number", "expMonth", "expYear", "code"]
    static let identityOrder = ["title", "firstName", "middleName", "lastName", "username", "company", "email", "phone",
                                "address1", "address2", "address3", "city", "state", "postalCode", "country",
                                "ssn", "passportNumber", "licenseNumber"]
    static let sshOrder = ["privateKey", "publicKey", "keyFingerprint"]
}
