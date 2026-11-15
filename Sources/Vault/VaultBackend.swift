import Foundation

/// The one line between the app and whatever holds the vault. `bw` stands
/// behind it now (`ServeBackend`), a fake stands behind it in every test and
/// in the demo, and Bitwarden's SDK is meant to be able to one day. It is
/// small on purpose: every method here is one the SDK would have to answer
/// too.
///
/// The password is a `SecretBytes`, which can be overwritten with zeros.
/// `unlock` and `confirm` wipe the one they were handed before they return,
/// whichever way they return. Nothing comes back from either: the session
/// an engine makes of a password is the engine's own, and the only thing
/// that opens the vault from outside it is the password (D7).
@MainActor
protocol VaultBackend: AnyObject {
    /// The engine went away by itself while the vault was open. Whoever holds
    /// the vault has to lock.
    var onEngineLost: (() -> Void)? { get set }

    func status() async throws -> VaultStatus

    /// Opens the vault with the master password. `VaultError.refused` is
    /// the engine saying it is not the one.
    func unlock(password: SecretBytes) async throws
    /// Asks an engine that is already open whether this is the master
    /// password. `VaultError.refused` is the answer no, in the engine's
    /// sentence, and the vault stays open after it.
    func confirm(password: SecretBytes) async throws
    /// Shuts the vault, and the engine with it.
    func close() async
    /// Shuts the vault and has the engine end the session it made at the
    /// unlock first, so that it opens nothing afterwards for anyone.
    func endSession() async
    /// Takes the account off this Mac: the engine forgets it and whatever it
    /// kept on disk for it is removed. Only signing in brings one back.
    func signOut() async

    func sync() async throws
    func items() async throws -> [Item]
    func trash() async throws -> [Item]
    func folders() async throws -> [Folder]
    /// The collections this account can see, none for one in no organisation.
    func collections() async throws -> [SharedCollection]

    /// The engine's own example of an object, by the name `bw get template`
    /// knows it under: `item`, `item.login` and its siblings. Its values
    /// are examples and its keys are the shape (`Item.blank`).
    func template(_ name: String) async throws -> JSONValue
    /// `object` is a template with the form's values in it.
    func create(_ object: JSONValue) async throws -> Item
    /// `object` is what `Item.patched` returned.
    func save(_ item: Item, as object: JSONValue) async throws -> Item
    /// To the trash, or past it.
    func delete(_ item: Item, permanently: Bool) async throws
    func restore(_ item: Item) async throws
    func archive(_ item: Item) async throws
    func unarchive(_ item: Item) async throws

    func createFolder(named name: String) async throws -> Folder
    func rename(_ folder: Folder, to name: String) async throws -> Folder
    func delete(_ folder: Folder) async throws

    func generate(_ recipe: PasswordRecipe) async throws -> String

    /// Writes the decrypted attachment to `destination`.
    func fetch(_ attachment: Attachment, of item: Item, to destination: URL) async throws
    func attach(_ file: URL, to item: Item) async throws -> Item
}

struct VaultStatus: Equatable {
    enum State: Equatable {
        case noCLI, loggedOut, locked, unlocked
    }

    var state: State
    var email: String?
    var server: String?
    var lastSync: Date?
}

enum VaultError: Error, Equatable {
    /// There is no `bw` to run.
    case noCLI
    case loggedOut
    case locked
    /// The engine said no, in its own sentence.
    case refused(String)
    case timeout
    /// The connection, not the vault: it hung up, or what came was no answer.
    case transport
    /// The engine answered, with this HTTP status and nothing in its own
    /// envelope: it would not hear the request at all. A `bw` whose rule for
    /// who may ask has moved looks like this, and it is not a dead connection.
    case turnedAway(Int)

    static func turnedAwaySentence(_ status: Int) -> String {
        "The engine turned the request away with HTTP \(status) and no reason. This bw may not be one OriPass was written for."
    }
}

/// What the generator is asked for (OP-40).
enum PasswordRecipe: Equatable {
    case random(length: Int, digits: Bool, symbols: Bool)
    case memorable(words: Int, separator: String, capitals: Bool, number: Bool)
    case pin(digits: Int)
}
