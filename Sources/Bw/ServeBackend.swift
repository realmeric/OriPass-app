import Foundation

/// The engine that is `bw`: a `BwChild` that lives while the vault is open
/// and a `ServeClient` that talks to it. Every call is the route
/// `docs/notes.md` names for it, and nothing here knows a key or a cipher
/// (D4).
@MainActor
final class ServeBackend: VaultBackend {
    var onEngineLost: (() -> Void)?

    private let preferredPath: String?
    private let finder: BwBinary.Finder
    private let runDirectory: URL
    private let dataDirectory: URL
    private var binary: URL?
    private var child: BwChild?
    /// The child that has been started and has not yet answered. `close`
    /// stops it too: a lock does not wait for `bw` to come up.
    private var starting: BwChild?

    private let deadline: TimeInterval

    private var client: ServeClient? {
        child?.connection.map { ServeClient(connection: $0, deadline: deadline) }
    }

    /// `deadline` is how long one answer is waited for. An answer that has
    /// not come by then ends the child: there is one connection to it, and
    /// a late answer on it would be read as the next request's.
    init(preferredPath: String? = nil, finder: @escaping BwBinary.Finder = BwBinary.standardFinder,
         runDirectory: URL = AppPaths.run, dataDirectory: URL = AppPaths.bwData,
         deadline: TimeInterval = 60) {
        self.preferredPath = preferredPath
        self.finder = finder
        self.runDirectory = runDirectory
        self.dataDirectory = dataDirectory
        self.deadline = deadline
    }

    // MARK: Opening and shutting

    /// A child that a crash or a `kill -9` of the app left, if it did not
    /// go by itself as every one seen has: killed as the app next opens,
    /// and not only when the vault next does (D6). Never while this
    /// backend has a child of its own.
    func clearLeftovers() {
        guard child == nil, starting == nil else { return }
        BwChild.clearLeftovers(in: runDirectory)
    }

    func status() async throws -> VaultStatus {
        if let client {
            let answer = try await client.call("GET", "/status")
            return try Self.status(from: answer["template"], route: "/status")
        }
        guard let binary = find() else { return VaultStatus(state: .noCLI) }
        // No child is serving, so this is a whole `bw` starting and stopping.
        let said = await BwBinary.run(binary, ["status"], dataDirectory: dataDirectory)
        guard said.status == 0, let json = try? JSONValue(data: Data(said.output.utf8)) else {
            throw VaultError.refused(said.error)
        }
        return try Self.status(from: json, route: "bw status")
    }

    /// A new child, and the password down its connection. The answer
    /// carries the session `bw` made, which is not read out of it, kept or
    /// written: nothing here wipes the bytes it arrived in, and the child
    /// that would take it goes at the lock.
    func unlock(password: SecretBytes) async throws {
        defer { password.wipe() }
        let client = try await start()
        let mine = child
        do {
            try await Self.send(password, to: client)
        } catch {
            // Only its own: closed under the password, another unlock may
            // have a child here by now.
            if child === mine { await close() }
            throw error
        }
    }

    /// `POST /unlock` again, of the child that is already serving. Nothing
    /// is shut when it says no.
    func confirm(password: SecretBytes) async throws {
        defer { password.wipe() }
        try await Self.send(password, to: try reach())
    }

    private static func send(_ password: SecretBytes, to client: ServeClient) async throws {
        let body = SecretBytes(capacity: password.count + 32)
        body.append("{\"password\":")
        body.append(password.jsonString())
        body.append("}")
        defer { body.wipe() }
        _ = try await client.call("POST", "/unlock", secret: body)
    }

    /// Let go of before they are stopped, so that a child started while
    /// these are on their way out is not taken for one of them.
    func close() async {
        let going = [child, starting].compactMap { $0 }
        child = nil
        starting = nil
        for child in going { await child.stop() }
    }

    /// `POST /lock` to a child that is serving, and then the child goes.
    /// With no child there is nothing to end: the session one made was in
    /// its memory and nowhere else, and went when it did.
    func endSession() async {
        if let client { _ = try? await client.call("POST", "/lock") }
        await close()
    }

    /// `bw logout`, which no child need be serving for, and then the
    /// folder it keeps its state in is emptied, so that nothing of the
    /// account is left there whatever the command did (`docs/notes.md`,
    /// "Signing out").
    func signOut() async {
        await close()
        if let binary = find() {
            let said = await BwBinary.run(binary, ["logout"], dataDirectory: dataDirectory)
            Log.app.info("bw logout ended with \(said.status, privacy: .public)")
        }
        let files = FileManager.default
        for name in (try? files.contentsOfDirectory(atPath: dataDirectory.path)) ?? [] {
            try? files.removeItem(at: dataDirectory.appendingPathComponent(name))
        }
    }

    // MARK: Reading

    func sync() async throws {
        _ = try await reach().call("POST", "/sync")
    }

    func items() async throws -> [Item] {
        try await read("/list/object/items")
    }

    func trash() async throws -> [Item] {
        try await read("/list/object/items?trash=true")
    }

    func folders() async throws -> [Folder] {
        try await list("/list/object/folders").compactMap(Folder.init(json:))
    }

    func collections() async throws -> [SharedCollection] {
        try await list("/list/object/collections").compactMap(SharedCollection.init(json:))
    }

    // MARK: Writing

    func template(_ name: String) async throws -> JSONValue {
        let path = "/object/template/\(name)"
        guard let template = try await reach().call("GET", path)["template"], template.object != nil else {
            throw ShapeError(missing: "template", route: path)
        }
        return template
    }

    func create(_ object: JSONValue) async throws -> Item {
        try item(from: try await reach().call("POST", "/object/item", json: object), route: "/object/item")
    }

    func save(_ item: Item, as object: JSONValue) async throws -> Item {
        try self.item(from: try await reach().call("PUT", "/object/item/\(try Self.word(item.id))", json: object),
                      route: "/object/item/{id}")
    }

    func delete(_ item: Item, permanently: Bool) async throws {
        _ = try await reach().call("DELETE", "/object/item/\(try Self.word(item.id))" + (permanently ? "?permanent=true" : ""))
    }

    func restore(_ item: Item) async throws {
        _ = try await reach().call("POST", "/restore/item/\(try Self.word(item.id))")
    }

    func archive(_ item: Item) async throws {
        _ = try await reach().call("POST", "/archive/item/\(try Self.word(item.id))")
    }

    /// A guess, and one nobody could test: the route table has no way out of
    /// the archive of its own, `restore` is the only route that brings an
    /// item back from anywhere, and the account OP-2 ran on is refused the
    /// archive, so nothing was ever in it to bring back. What is known is
    /// that `restore` on an item in neither place is "Cipher is not in
    /// trash.", which is what he would read if the guess is wrong.
    func unarchive(_ item: Item) async throws {
        _ = try await reach().call("POST", "/restore/item/\(try Self.word(item.id))")
    }

    func createFolder(named name: String) async throws -> Folder {
        try folder(from: try await reach().call("POST", "/object/folder",
                                                 json: .object(["name": .string(name)])))
    }

    func rename(_ folder: Folder, to name: String) async throws -> Folder {
        try self.folder(from: try await reach().call("PUT", "/object/folder/\(try Self.word(folder.id))",
                                                      json: .object(["name": .string(name)])))
    }

    func delete(_ folder: Folder) async throws {
        _ = try await reach().call("DELETE", "/object/folder/\(try Self.word(folder.id))")
    }

    func generate(_ recipe: PasswordRecipe) async throws -> String {
        let answer = try await reach().call("GET", "/generate?" + Self.query(for: recipe))
        guard let password = answer["data"]?.string else { throw ShapeError(missing: "data", route: "/generate") }
        // The CLI makes nothing shorter than `shortest`, so a shorter PIN is
        // the front of a longer one. Its digits were drawn one by one.
        if case .pin(let digits) = recipe { return String(password.prefix(digits)) }
        return password
    }

    func fetch(_ attachment: Attachment, of item: Item, to destination: URL) async throws {
        let response = try await reach().send(
            "GET", "/object/attachment/\(try Self.word(attachment.id))?itemid=\(try Self.word(item.id))", body: nil, type: ""
        )
        guard response.status == 200 else {
            throw VaultError.refused(try ServeClient.envelope(of: response)["message"]?.string ?? "")
        }
        try response.body.write(to: destination, options: .atomic)
    }

    func attach(_ file: URL, to item: Item) async throws -> Item {
        let boundary = "oripass-\(UUID().uuidString)"
        let name = Self.quoted(file.lastPathComponent)
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        body.append(try Data(contentsOf: file))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let response = try await reach().send("POST", "/attachment?itemid=\(try Self.word(item.id))",
                                              body: SecretBytes(body),
                                              type: "multipart/form-data; boundary=\(boundary)")
        let envelope = try ServeClient.envelope(of: response)
        guard envelope["success"]?.bool == true, let data = envelope["data"] else {
            throw VaultError.refused(envelope["message"]?.string ?? "")
        }
        return try self.item(from: data, route: "/attachment")
    }

    // MARK: -

    /// What an act on an item, a file or a folder is refused with when its
    /// id is not one word of letters, digits and hyphens.
    static let oddID = "This id is not one \(AppInfo.name) will send to the engine."

    /// An id as it may go into a request line. An id is whatever the
    /// server's answer held, unencrypted, and the line is written by hand
    /// (`ServeClient.send`): a space and a line's end in one would be a
    /// second request, of the server's writing, to a child with the vault
    /// open, and a question mark would rewrite the query. Every id seen is
    /// a UUID. Anything that is not letters, digits and hyphens is sent
    /// nowhere.
    static func word(_ id: String) throws -> String {
        let isWord = !id.isEmpty && id.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2D
        }
        guard isWord else { throw VaultError.refused(oddID) }
        return id
    }

    /// A file's name as it goes between the quotes of a part's
    /// `filename`, RFC 7578's way: UTF-8 as it is, and a percent and two
    /// hex digits for what would end the quotes or the line, which is a
    /// double quote, a backslash and every control character.
    static func quoted(_ name: String) -> String {
        name.unicodeScalars.reduce(into: "") { quoted, scalar in
            if scalar == "\"" || scalar == "\\" || scalar.value < 0x20 || scalar.value == 0x7F {
                quoted += String(format: "%%%02X", scalar.value)
            } else {
                quoted.unicodeScalars.append(scalar)
            }
        }
    }

    /// The fewest characters the CLI will generate.
    static let shortest = 5

    /// The query `GET /generate` takes for each recipe: the CLI's own flag
    /// names, a switch given as `=true` and left out when it is off.
    static func query(for recipe: PasswordRecipe) -> String {
        var pairs: [(String, String)]
        switch recipe {
        case .random(let length, let digits, let symbols):
            pairs = [("length", String(length)), ("uppercase", "true"), ("lowercase", "true")]
            if digits { pairs.append(("number", "true")) }
            if symbols { pairs.append(("special", "true")) }
        case .memorable(let words, let separator, let capitals, let number):
            pairs = [("passphrase", "true"), ("words", String(words)), ("separator", separator)]
            if capitals { pairs.append(("capitalize", "true")) }
            if number { pairs.append(("includeNumber", "true")) }
        case .pin(let digits):
            pairs = [("length", String(max(digits, shortest))), ("number", "true")]
        }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return pairs.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }

    private func find() -> URL? {
        if binary == nil { binary = finder(preferredPath) }
        return binary
    }

    private func start() async throws -> ServeClient {
        await close()
        guard let binary = find() else { throw VaultError.noCLI }
        let child = BwChild(binary: binary, runDirectory: runDirectory, dataDirectory: dataDirectory)
        child.onExit = { [weak self, weak child] in
            guard let self, self.child === child else { return }
            self.child = nil
            self.onEngineLost?()
        }
        starting = child
        do {
            try await child.start()
        } catch {
            // Closed while it was coming up, which is a lock and no
            // failure of the child's.
            guard starting === child else { throw VaultError.locked }
            starting = nil
            switch error {
            case BwChild.Failure.exited("You are not logged in."): throw VaultError.loggedOut
            case BwChild.Failure.exited(let sentence): throw VaultError.refused(sentence)
            case BwChild.Failure.notReady: throw VaultError.timeout
            default: throw error
            }
        }
        guard starting === child else {
            await child.stop()
            throw VaultError.locked
        }
        starting = nil
        self.child = child
        guard let client else { throw VaultError.transport }
        return client
    }

    private func reach() throws -> ServeClient {
        guard let client else { throw VaultError.locked }
        return client
    }

    private func list(_ path: String) async throws -> [JSONValue] {
        guard let rows = try await reach().call("GET", path)["data"]?.array else {
            throw ShapeError(missing: "data", route: String(path.split(separator: "?")[0]))
        }
        return rows
    }

    /// The items a list route answers with. One without a name or a type
    /// is not skipped: the list is not what the app was written for, and
    /// the store locks with the route's name.
    private func read(_ path: String) async throws -> [Item] {
        let route = String(path.split(separator: "?")[0])
        return try await list(path).map { try item(from: $0, route: route) }
    }

    private func item(from json: JSONValue, route: String) throws -> Item {
        do { return try Item(json: json) } catch let shape as ShapeError { throw shape.on(route) }
    }

    private func folder(from json: JSONValue) throws -> Folder {
        guard let folder = Folder(json: json) else { throw ShapeError(missing: "id", route: "/object/folder") }
        return folder
    }

    /// `bw status` and `GET /status` answer with the same object. One with no
    /// `status` in it is not "logged out": that would send him to a sign-in
    /// for an account that is there.
    private static func status(from json: JSONValue?, route: String) throws -> VaultStatus {
        guard let json, let word = json["status"]?.string else {
            throw ShapeError(missing: "status", route: route)
        }
        let state: VaultStatus.State
        switch word {
        case "unlocked": state = .unlocked
        case "locked": state = .locked
        default: state = .loggedOut
        }
        return VaultStatus(state: state, email: json["userEmail"]?.string,
                           server: json["serverUrl"]?.string,
                           lastSync: json["lastSync"]?.string.flatMap(VaultDate.parse))
    }
}
