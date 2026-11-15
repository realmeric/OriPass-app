import Foundation

/// HTTP/1.1 to `bw serve` over the one connection it was born with
/// (`ServeConnection`): a request at a time, the answer split by hand.
///
/// It knows the envelope and nothing about the vault. A call returns the
/// `data` value or throws a `VaultError`. Bodies are never logged in either
/// direction; the log line is the method, the route, the status and the time.
struct ServeClient {
    let connection: ServeConnection
    var deadline: TimeInterval = 60

    /// The Host every request names, the readiness probe's included. A
    /// connected socket has no port, and `bw serve` asks for one all the same:
    /// with origin protection on, which is its default and is left on, it
    /// answers 403 unless Host is `localhost`, `127.0.0.1`, `[::1]` or the
    /// Mac's name followed by its `--port`, and that option is 8087 when it
    /// is not given, which it never is here. A bare `localhost` passes only
    /// on port 80 or 443. An Origin header is refused whatever it says, so
    /// none is sent (`docs/notes.md`, "`bw serve`").
    static let host = "localhost:8087"

    struct Response {
        let status: Int
        let body: Data
    }

    /// The `data` of the envelope `bw serve` wraps every answer in.
    func call(_ method: String, _ path: String, body: Data? = nil) async throws -> JSONValue {
        try await call(method, path, secret: body.map(SecretBytes.init))
    }

    func call(_ method: String, _ path: String, json: JSONValue) async throws -> JSONValue {
        try await call(method, path, body: try json.data())
    }

    /// The same, for a body that must not outlive the request: the one that
    /// carries the master password.
    func call(_ method: String, _ path: String, secret body: SecretBytes?) async throws -> JSONValue {
        let response = try await send(method, path, body: body, type: "application/json")
        let envelope = try Self.envelope(of: response)
        if envelope["success"]?.bool == true { return envelope["data"] ?? .null }
        switch envelope["message"]?.string {
        case "You are not logged in.": throw VaultError.loggedOut
        case "Vault is locked.": throw VaultError.locked
        case let message?: throw VaultError.refused(message)
        case nil:
            // Valid JSON that is neither an answer nor a refusal is not a
            // dead connection: the envelope itself has changed.
            if envelope.object != nil, envelope["success"] == nil {
                throw ShapeError(missing: "success", route: String(path.split(separator: "?")[0]))
            }
            throw VaultError.transport
        }
    }

    /// An answer read as the envelope. One that is whole and is not JSON
    /// under a status that is no success is `bw` turning the request away
    /// before any route saw it, which is what origin protection does: the
    /// status is kept and the body is dropped unread and unlogged.
    static func envelope(of response: Response) throws -> JSONValue {
        if let envelope = try? JSONValue(data: response.body) { return envelope }
        throw (200..<300).contains(response.status) ? VaultError.transport : VaultError.turnedAway(response.status)
    }

    /// The exchange itself, for the one answer that is not an envelope: an
    /// attachment's bytes.
    func send(_ method: String, _ path: String, body: SecretBytes?, type: String) async throws -> Response {
        // Every request is wiped once it is sent, the one with the password
        // in it included. No `Connection` header: the connection is kept,
        // which is what HTTP/1.1 does when nothing is said.
        guard Self.isOneTarget(path) else { throw VaultError.refused(ServeBackend.oddID) }
        let wire = SecretBytes(capacity: 256 + (body?.count ?? 0))
        wire.append("\(method) \(path) HTTP/1.1\r\nHost: \(Self.host)\r\n")
        if let body {
            wire.append("Content-Type: \(type)\r\nContent-Length: \(body.count)\r\n\r\n")
            wire.append(body)
        } else {
            wire.append("\r\n")
        }
        defer { wire.wipe() }

        let started = Date()
        do {
            let response = try await connection.exchange(wire, deadline: deadline)
            Log.bw.debug("\(Self.logLine(method, path, status: response.status, since: started), privacy: .public)")
            return response
        } catch {
            Log.bw.debug("\(Self.logLine(method, path, status: nil, since: started), privacy: .public)")
            if let failure = error as? ServeConnection.Failure {
                throw failure == .timedOut ? VaultError.timeout : VaultError.transport
            }
            throw error
        }
    }

    // MARK: -

    /// Whether `path` is one request target and nothing more: it starts
    /// at the root and is printable ASCII with no space in it. The line is
    /// written as it stands, so a space or a line's end here would end
    /// the target early and begin something else.
    static func isOneTarget(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7F }
    }

    /// Bytes that are one whole answer and nothing else.
    static func parse(_ raw: Data) throws -> Response {
        guard let whole = try answer(in: raw, isAll: true) else { throw VaultError.transport }
        return whole.response
    }

    /// The answer at the front of what has been read so far, with how many
    /// bytes of it are that answer's, or nil while more are still to come.
    /// The head is split from the body, and the body is as long as the
    /// head says, or is put back together when it came in chunks. An
    /// answer that says neither runs to the end of the connection, so it
    /// is whole only once `isAll` says nothing more is coming, and an
    /// answer that is not whole by then is a failure.
    static func answer(in raw: Data, isAll: Bool) throws -> (response: Response, length: Int)? {
        guard let gap = raw.range(of: Data("\r\n\r\n".utf8)) else {
            if isAll { throw VaultError.transport }
            return nil
        }
        let head = String(decoding: raw[raw.startIndex..<gap.lowerBound], as: UTF8.self)
            .components(separatedBy: "\r\n")
        let statusLine = head[0].split(separator: " ")
        guard statusLine.count >= 2, let status = Int(statusLine[1]) else { throw VaultError.transport }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        let rest = raw[gap.upperBound...]
        let headLength = raw.distance(from: raw.startIndex, to: gap.upperBound)
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let (body, length) = try unchunk(rest) else {
                if isAll { throw VaultError.transport }
                return nil
            }
            return (Response(status: status, body: body), headLength + length)
        }
        if let length = headers["content-length"].flatMap(Int.init) {
            guard rest.count >= length else {
                // Less than it promised means it hung up half way.
                if isAll { throw VaultError.transport }
                return nil
            }
            return (Response(status: status, body: Data(rest.prefix(length))), headLength + length)
        }
        guard isAll else { return nil }
        return (Response(status: status, body: Data(rest)), raw.count)
    }

    /// The chunks put together and how many bytes they took up, the last
    /// empty one and the line after it included, or nil when the last has
    /// not come yet.
    private static func unchunk(_ chunked: Data) throws -> (body: Data, length: Int)? {
        var body = Data()
        var rest = chunked[...]
        let lineEnd = Data("\r\n".utf8)
        while true {
            guard let end = rest.range(of: lineEnd) else { return nil }
            // A chunk's size may carry extensions after a semicolon.
            let sizeText = String(decoding: rest[rest.startIndex..<end.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                throw VaultError.transport
            }
            let start = end.upperBound
            if size == 0 {
                // Trailers, which nothing here reads, and the empty line
                // that ends them.
                var tail = rest[start...]
                while true {
                    guard let line = tail.range(of: lineEnd) else { return nil }
                    let wasEmpty = line.lowerBound == tail.startIndex
                    tail = tail[line.upperBound...]
                    if wasEmpty { return (body, chunked.count - tail.count) }
                }
            }
            guard rest.endIndex - start >= size + lineEnd.count else { return nil }
            body.append(rest[start..<start + size])
            rest = rest[(start + size + lineEnd.count)...]
        }
    }

    /// Every word a route is made of. Anything else in a path is an id, or
    /// something typed, and is not written down.
    private static let routeWords: Set<String> = [
        "status", "generate", "list", "object", "items", "folders", "collections",
        "organizations", "sync", "lock", "unlock", "restore", "archive", "attachment", "item",
        "folder", "template", "totp", "move", "confirm", "send",
    ]

    /// `PUT /object/item/:id 200 12ms`. The query is dropped whole, since a
    /// search is typed text.
    static func logLine(_ method: String, _ path: String, status: Int?, since started: Date) -> String {
        let route = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        let safe = route.split(separator: "/").map { segment -> String in
            routeWords.contains(String(segment)) || segment.hasPrefix("item.") ? String(segment) : ":id"
        }
        let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        return "\(method) /\(safe.joined(separator: "/")) \(status.map(String.init) ?? "failed") \(milliseconds)ms"
    }
}
