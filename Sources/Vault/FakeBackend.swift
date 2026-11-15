import Foundation

/// A vault held in memory, for every test and for `OP_DEMO`. It counts what
/// it is asked, and can be told to refuse, to be slow or to be offline.
///
/// It keeps the vault twice, the way the real one does: `atRest` stands for
/// what is on the server and on disk, and `held` is what is open. `close`
/// empties the second.
@MainActor
final class FakeBackend: VaultBackend {
    /// What 2026.9.1 answers `POST /unlock` with for a wrong password.
    static let wrongPassword = "Cryptography error, The decryption operation failed"
    static let offline = "The server could not be reached."
    /// What 2026.9.1 answers a write made from a copy older than the
    /// server's: the server's answer, whole, behind the name of its own
    /// error.
    static let outOfDate = "EditCipherError: error in response: status code 400 Bad Request: "
        + #"{"object":"error","message":"The item cannot be saved because it is out of date. "#
        + #"To edit this item, first sync your vault, or log out and back in.","validationErrors":null,"#
        + #""exceptionMessage":null,"exceptionStackTrace":null,"innerExceptionMessage":null}"#

    /// What an engine does with the earlier passwords of an item whose
    /// password a save has changed.
    enum HistoryHabit {
        /// Keeps the list it was sent.
        case asSent
        /// Keeps the list it held and puts the old password first in it,
        /// which is what 2026.9.1 was seen to do, and this fake's own habit.
        case itsOwn
        /// Puts the old password first in the list it was sent.
        case onTop
    }

    /// What 2026.9.1 answers for a template it does not have, which a
    /// key's is.
    static let noTemplate = "Unknown template object."
    /// The CLI's sentence, read in `get.command.ts` for a one-time code and
    /// an attachment, and seen from 2026.9.1 for an archive.
    static let needsPremium = "Premium status is required to use this feature."

    private var password: SecretBytes
    private var atRest: (items: [JSONValue], folders: [JSONValue])
    private var held: (items: [JSONValue], folders: [JSONValue])?

    /// Every call, by name, in the order it came.
    private(set) var calls: [String] = []
    /// When set, every call that reaches the vault throws it.
    var refusal: VaultError?
    var delay: TimeInterval = 0
    /// How long each `status` takes, the first asked first: a whole `bw`
    /// starting and stopping, which is what one is with no child serving.
    var statusDelays: [TimeInterval] = []
    /// How long `endSession` waits before the vault is shut: its `POST
    /// /lock` stands in the connection behind whatever was asked first.
    var goingTakes: TimeInterval = 0
    var isOffline = false
    var isLoggedIn = true
    var email = "demo@oripass.invalid"
    /// Nil is Bitwarden's own, as the CLI says it.
    var server: String?
    var lastSync: Date?
    /// What `sync` brings from the server, applied once. Until it has been,
    /// a save of an item that is another there is refused as out of date.
    var incoming: (items: [JSONValue], folders: [JSONValue])?
    var historyHabit = HistoryHabit.itsOwn
    /// An account without Premium, which the engine will not archive for.
    var isFree = false
    /// An engine that takes a passkey and hands the item back without it.
    var losesPasskeys = false
    /// The object the last `save` was handed, and the last `create`.
    private(set) var lastSaved: JSONValue?
    private(set) var lastCreated: JSONValue?
    /// An organisation's collections. The demo's account is in none.
    var collections: [JSONValue] = []
    /// What `GET /object/template/<name>` answers for each name, with the
    /// keys 2026.9.1 sent and the examples it is remembered to put under
    /// them.
    var templates = FakeBackend.templates
    private var templateRefusals: [String: VaultError] = [:]
    /// What `generate` answers whatever it is asked for, when a test wants
    /// one answer. Without it the answer is the demo's for that recipe.
    var generated: String?
    var attachmentBodies: [String: Data] = [:]
    /// What `fetch` and `attach` throw and nothing else does: an account
    /// without Premium is refused those two (`docs/notes.md`, "Where
    /// Premium draws its lines").
    var attachmentRefusal: VaultError?
    /// Run when `fetch` has written its file, before it answers.
    var onFetched: (() async -> Void)?
    /// Run when `items` has read the list, before it answers: a change
    /// that lands in that gap is one the list has not heard of.
    var onItemsRead: (() async -> Void)?
    private var shortItems: [Set<String>] = []
    private var shortTrash: [Set<String>] = []
    var now: () -> Date = Date.init

    init(items: [JSONValue], folders: [JSONValue], password: String) {
        atRest = (items, folders)
        self.password = SecretBytes(password)
    }

    func count(of call: String) -> Int { calls.filter { $0 == call }.count }

    var isOpen: Bool { held != nil }
    var heldCount: Int { (held?.items.count ?? 0) + (held?.folders.count ?? 0) }

    var onEngineLost: (() -> Void)?

    /// What `bw` exiting by itself looks like from here.
    func die() {
        held = nil
        onEngineLost?()
    }

    // MARK: VaultBackend

    func status() async throws -> VaultStatus {
        calls.append("status")
        if !statusDelays.isEmpty {
            try await Task.sleep(nanoseconds: UInt64(statusDelays.removeFirst() * 1_000_000_000))
        }
        guard isLoggedIn else { return VaultStatus(state: .loggedOut) }
        return VaultStatus(state: isOpen ? .unlocked : .locked, email: email,
                           server: server, lastSync: lastSync)
    }

    /// What changing the master password in the web vault looks like from
    /// here: the one this was made with opens nothing afterwards.
    func changePassword(to password: String) {
        self.password = SecretBytes(password)
    }

    func unlock(password: SecretBytes) async throws {
        calls.append("unlock")
        let isRight = password.matches(self.password)
        password.wipe()
        try await pause()
        guard isLoggedIn else { throw VaultError.loggedOut }
        if let refusal { throw refusal }
        guard isRight else { throw VaultError.refused(Self.wrongPassword) }
        held = atRest
    }

    func confirm(password: SecretBytes) async throws {
        calls.append("confirm")
        let isRight = password.matches(self.password)
        password.wipe()
        try await pause()
        guard isOpen else { throw VaultError.locked }
        if let refusal { throw refusal }
        guard isRight else { throw VaultError.refused(Self.wrongPassword) }
    }

    func signOut() async {
        calls.append("signOut")
        held = nil
        isLoggedIn = false
    }

    func close() async {
        calls.append("close")
        held = nil
    }

    func endSession() async {
        calls.append("endSession")
        if goingTakes > 0 { try? await Task.sleep(nanoseconds: UInt64(goingTakes * 1_000_000_000)) }
        held = nil
    }

    func sync() async throws {
        calls.append("sync")
        try await reach()
        if isOffline { throw VaultError.refused(Self.offline) }
        if let incoming {
            atRest = incoming
            held = incoming
            self.incoming = nil
        }
        lastSync = now()
    }

    /// The next reads of the two lists leave these ids out, one set for
    /// each read, as an engine does that answers short with a 200
    /// (`docs/notes.md`, "When a list comes back short").
    func readShort(_ reads: [Set<String>]) {
        shortItems = reads
        shortTrash = reads
    }

    func items() async throws -> [Item] {
        calls.append("items")
        let out = shortItems.isEmpty ? [] : shortItems.removeFirst()
        let listed = try await reach().items.filter { $0["deletedDate"]?.string == nil }
            .filter { !out.contains($0["id"]?.string ?? "") }.map(Item.init(json:))
        await onItemsRead?()
        return listed
    }

    func trash() async throws -> [Item] {
        calls.append("trash")
        let out = shortTrash.isEmpty ? [] : shortTrash.removeFirst()
        return try await reach().items.filter { $0["deletedDate"]?.string != nil }
            .filter { !out.contains($0["id"]?.string ?? "") }.map(Item.init(json:))
    }

    func folders() async throws -> [Folder] {
        calls.append("folders")
        return try await reach().folders.compactMap(Folder.init(json:))
    }

    func collections() async throws -> [SharedCollection] {
        calls.append("collections")
        try await reach()
        return collections.compactMap(SharedCollection.init(json:))
    }

    /// The one template that is refused from here on, and with what.
    func refuse(_ name: String, with refusal: VaultError) {
        templateRefusals[name] = refusal
    }

    func template(_ name: String) async throws -> JSONValue {
        calls.append("template")
        try await reach()
        if let refusal = templateRefusals[name] { throw refusal }
        guard let template = templates[name] else { throw VaultError.refused(Self.noTemplate) }
        return template
    }

    func create(_ object: JSONValue) async throws -> Item {
        calls.append("create")
        lastCreated = object
        try await write()
        let stamp = JSONValue.string(VaultDate.string(now()))
        let made = kept(object).setting(["id"], to: .string(UUID().uuidString.lowercased()))
            .setting(["object"], to: .string("item"))
            .setting(["creationDate"], to: stamp).setting(["revisionDate"], to: stamp)
        held?.items.append(made)
        atRest = held ?? atRest
        return try Item(json: made)
    }

    func save(_ item: Item, as object: JSONValue) async throws -> Item {
        calls.append("save")
        lastSaved = object
        let habit = historyHabit
        let stamp = VaultDate.string(now())
        let kept = kept(object)
        return try await replace(item, isEdit: true) { held in
            guard let old = held["login"]?["password"]?.string, !old.isEmpty,
                  old != object["login"]?["password"]?.string, habit != .asSent else { return kept }
            let entry = JSONValue.object(["lastUsedDate": .string(stamp), "password": .string(old)])
            let rest = (habit == .itsOwn ? held : object)["passwordHistory"]?.array ?? []
            return kept.setting(["passwordHistory"], to: .array(Array(([entry] + rest).prefix(Item.historyKept))))
        }
    }

    private func kept(_ object: JSONValue) -> JSONValue {
        losesPasskeys ? object.setting(["login", "fido2Credentials"], to: .array([])) : object
    }

    func delete(_ item: Item, permanently: Bool) async throws {
        calls.append(permanently ? "deletePermanently" : "delete")
        if permanently {
            try await write()
            held?.items.removeAll { $0["id"]?.string == item.id }
            atRest = held ?? atRest
        } else {
            let stamp = JSONValue.string(VaultDate.string(now()))
            _ = try await replace(item) { $0.setting(["deletedDate"], to: stamp) }
        }
    }

    func restore(_ item: Item) async throws {
        calls.append("restore")
        _ = try await replace(item) { $0.setting(["deletedDate"], to: .null) }
    }

    func archive(_ item: Item) async throws {
        calls.append("archive")
        if isFree { throw VaultError.refused(Self.needsPremium) }
        let stamp = JSONValue.string(VaultDate.string(now()))
        _ = try await replace(item) { $0.setting(["archivedDate"], to: stamp) }
    }

    func unarchive(_ item: Item) async throws {
        calls.append("unarchive")
        _ = try await replace(item) { $0.setting(["archivedDate"], to: .null) }
    }

    func createFolder(named name: String) async throws -> Folder {
        calls.append("createFolder")
        try await write()
        let made = JSONValue.object(["object": .string("folder"), "name": .string(name),
                                     "id": .string(UUID().uuidString.lowercased())])
        held?.folders.append(made)
        atRest = held ?? atRest
        return Folder(id: made["id"]?.string ?? "", name: name)
    }

    func rename(_ folder: Folder, to name: String) async throws -> Folder {
        calls.append("renameFolder")
        try await write()
        guard let index = held?.folders.firstIndex(where: { $0["id"]?.string == folder.id }),
              let renamed = held?.folders[index].setting(["name"], to: .string(name)),
              let folder = Folder(json: renamed) else {
            throw VaultError.refused("Not found.")
        }
        held?.folders[index] = renamed
        atRest = held ?? atRest
        return folder
    }

    func delete(_ folder: Folder) async throws {
        calls.append("deleteFolder")
        try await write()
        held?.folders.removeAll { $0["id"]?.string == folder.id }
        // What the server does with a deleted folder's items: they stay, in
        // no folder.
        let orphaned = (held?.items ?? []).map {
            $0["folderId"]?.string == folder.id ? $0.setting(["folderId"], to: .null) : $0
        }
        held?.items = orphaned
        atRest = held ?? atRest
    }

    func generate(_ recipe: PasswordRecipe) async throws -> String {
        calls.append("generate")
        // Made when it was asked for, however long the answer takes.
        let made = generated ?? DemoVault.generated(recipe)
        try await reach()
        return made
    }

    func fetch(_ attachment: Attachment, of item: Item, to destination: URL) async throws {
        calls.append("fetch")
        try await reach()
        if let attachmentRefusal { throw attachmentRefusal }
        guard let body = attachmentBodies[attachment.id] else { throw VaultError.refused("Not found.") }
        try body.write(to: destination)
        await onFetched?()
    }

    func attach(_ file: URL, to item: Item) async throws -> Item {
        calls.append("attach")
        if let attachmentRefusal {
            try await reach()
            throw attachmentRefusal
        }
        let body = try Data(contentsOf: file)
        let id = UUID().uuidString.lowercased()
        attachmentBodies[id] = body
        let added = JSONValue.object([
            "id": .string(id), "fileName": .string(file.lastPathComponent),
            "size": .string(String(body.count)), "sizeName": .string("\(body.count) bytes"),
        ])
        return try await replace(item) {
            $0.setting(["attachments"], to: .array(($0["attachments"]?.array ?? []) + [added]))
        }
    }

    // MARK: -

    private func pause() async throws {
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
    }

    /// What every call that reads the open vault goes through.
    @discardableResult
    private func reach() async throws -> (items: [JSONValue], folders: [JSONValue]) {
        try await pause()
        guard isLoggedIn else { throw VaultError.loggedOut }
        if let refusal { throw refusal }
        guard let held else { throw VaultError.locked }
        return held
    }

    private func write() async throws {
        try await reach()
        if isOffline { throw VaultError.refused(Self.offline) }
    }

    private func replace(_ item: Item, isEdit: Bool = false,
                         with change: (JSONValue) -> JSONValue) async throws -> Item {
        try await write()
        guard let index = held?.items.firstIndex(where: { $0["id"]?.string == item.id }),
              let current = held?.items[index] else {
            throw VaultError.refused("Not found.")
        }
        if isEdit, let theirs = incoming?.items.first(where: { $0["id"]?.string == item.id }), theirs != current {
            throw VaultError.refused(Self.outOfDate)
        }
        let changed = change(current)
            .setting(["revisionDate"], to: .string(VaultDate.string(now())))
        held?.items[index] = changed
        atRest = held ?? atRest
        return try Item(json: changed)
    }
}

extension FakeBackend {
    static let templates: [String: JSONValue] = [
        "item": .object([
            "passwordHistory": .array([]), "type": .int(1), "name": .string("Item name"),
            "notes": .string("Some notes about this item."), "favorite": .bool(false), "fields": .array([]),
            "reprompt": .int(0),
        ]),
        "item.login": .object([
            "uris": .array([]), "username": .string("jdoe"), "password": .string("myp@ssword123"),
            "totp": .string("JBSWY3DPEHPK3PXP"), "fido2Credentials": .array([]),
        ]),
        "item.securenote": .object(["type": .int(0)]),
        "item.card": .object([
            "cardholderName": .string("John Doe"), "brand": .string("visa"),
            "number": .string("4242424242424242"), "expMonth": .string("04"), "expYear": .string("2023"),
            "code": .string("123"),
        ]),
        "item.identity": .object([
            "title": .string("Mr"), "firstName": .string("John"), "middleName": .string("William"),
            "lastName": .string("Doe"), "address1": .string("123 Any St"), "address2": .string("Apt #123"),
            "city": .string("New York"), "state": .string("NY"),
            "postalCode": .string("10001"), "country": .string("US"), "company": .string("Acme Inc."),
            "email": .string("john@company.com"), "phone": .string("5555551234"), "ssn": .string("000-123-4567"),
            "username": .string("jdoe"), "passportNumber": .string("US-123456789"),
            "licenseNumber": .string("D123-12-123-12333"),
        ]),
    ]
}
