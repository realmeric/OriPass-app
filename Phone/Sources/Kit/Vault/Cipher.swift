import Foundation

/// The sync's answer as the server sent it, every secret still an encrypted
/// string. Only the keys this app reads are named; the rest stay in the
/// file and go back as they came when an item is written.
struct SyncAnswer: Decodable, Sendable {
    let profile: Profile
    let folders: [Folder]?
    let collections: [Collection]?
    let ciphers: [Cipher]
    let userDecryption: UserDecryption?

    struct Profile: Decodable, Sendable {
        let id: String
        let email: String?
        let premium: Bool?
        let key: String?
        let privateKey: String?
        let accountKeys: AccountKeys?
        let organizations: [Organization]?
    }

    struct AccountKeys: Decodable, Sendable {
        let publicKeyEncryptionKeyPair: KeyPair?

        struct KeyPair: Decodable, Sendable {
            let wrappedPrivateKey: String?
        }
    }

    struct Organization: Decodable, Sendable {
        let id: String
        let name: String?
        let key: String?
        let enabled: Bool?
    }

    struct Folder: Decodable, Sendable {
        let id: String
        let name: String?
    }

    struct Collection: Decodable, Sendable {
        let id: String
        let organizationId: String
        let name: String?
    }

    struct UserDecryption: Decodable, Sendable {
        let masterPasswordUnlock: MasterPasswordUnlock?

        struct MasterPasswordUnlock: Decodable, Sendable {
            let masterKeyEncryptedUserKey: String?
        }
    }
}

struct Cipher: Decodable, Sendable {
    let id: String
    let organizationId: String?
    let folderId: String?
    let type: Int
    let name: String?
    let notes: String?
    let favorite: Bool?
    let reprompt: Int?
    let key: String?
    let revisionDate: Date?
    let creationDate: Date?
    let deletedDate: Date?
    let archivedDate: Date?
    let login: Login?
    let card: [String: String?]?
    let identity: [String: String?]?
    let sshKey: [String: String?]?
    let fields: [Field]?
    let passwordHistory: [History]?

    struct Login: Decodable, Sendable {
        let username: String?
        let password: String?
        let totp: String?
        let passwordRevisionDate: Date?
        let uris: [Uri]?
        let fido2Credentials: [[String: String?]]?
    }

    struct Uri: Decodable, Sendable {
        let uri: String?
        let uriChecksum: String?
        let match: Int?
    }

    struct Field: Decodable, Sendable {
        let type: Int
        let name: String?
        let value: String?
        let linkedId: Int?
    }

    struct History: Decodable, Sendable {
        let password: String?
        let lastUsedDate: Date?
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = Cipher.dates.date(from: text) ?? Cipher.plainDates.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "a date"))
        }
        return decoder
    }()

    nonisolated(unsafe) private static let dates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plainDates = ISO8601DateFormatter()
}
