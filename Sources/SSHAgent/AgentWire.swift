import Foundation

/// OpenSSH's agent protocol as `docs/notes.md`, "The SSH agent", writes it
/// down: four bytes of length, most significant first, and that many bytes,
/// the first of which says what they are. The one place its shapes are.
enum AgentWire {
    /// `AGENT_MAX_LEN` in OpenSSH. A length over this closes the connection
    /// before its body is read.
    static let most = 256 * 1024

    /// The next message, whole. Empty is a message too, which is a failure
    /// and not an end.
    static func read(from descriptor: Int32) throws -> Data {
        var length: UInt32 = 0
        try withUnsafeMutableBytes(of: &length) { try BridgeWire.fill($0, from: descriptor) }
        let count = Int(UInt32(bigEndian: length))
        guard count <= most else { throw BridgeWire.Failure.tooLong }
        var body = Data(count: count)
        try body.withUnsafeMutableBytes { try BridgeWire.fill($0, from: descriptor) }
        return body
    }

    static func write(_ body: Data, to descriptor: Int32) throws {
        var length = UInt32(body.count).bigEndian
        try withUnsafeBytes(of: &length) { try BridgeWire.send($0, to: descriptor) }
        try body.withUnsafeBytes { try BridgeWire.send($0, to: descriptor) }
    }
}

/// A walk along counted bytes, over a message or a key file. It hands back
/// the bytes where they lie, so a private half is read without a copy.
struct SSHReader {
    private var rest: UnsafeRawBufferPointer

    init(_ bytes: UnsafeRawBufferPointer) {
        rest = bytes
    }

    var isAtEnd: Bool { rest.isEmpty }

    mutating func byte() -> UInt8? {
        guard let first = rest.first else { return nil }
        rest = UnsafeRawBufferPointer(rebasing: rest.dropFirst())
        return first
    }

    /// Four bytes, most significant first.
    mutating func number() -> Int? {
        guard rest.count >= 4 else { return nil }
        defer { rest = UnsafeRawBufferPointer(rebasing: rest.dropFirst(4)) }
        return rest.prefix(4).reduce(0) { $0 << 8 | Int($1) }
    }

    /// A length and that many bytes.
    mutating func string() -> UnsafeRawBufferPointer? {
        guard let length = number(), rest.count >= length else { return nil }
        defer { rest = UnsafeRawBufferPointer(rebasing: rest.dropFirst(length)) }
        return UnsafeRawBufferPointer(rebasing: rest.prefix(length))
    }

    /// A number of any size, with the zeros in front of it taken off.
    mutating func integer() -> UnsafeRawBufferPointer? {
        guard let bytes = string() else { return nil }
        return UnsafeRawBufferPointer(rebasing: bytes.drop { $0 == 0 })
    }

    /// `string`, kept. Not for anything secret.
    mutating func data() -> Data? {
        string().map { Data($0) }
    }

    /// `string`, as a name.
    mutating func word() -> String? {
        string().flatMap { String(bytes: $0, encoding: .utf8) }
    }
}

extension Data {
    mutating func appendNumber(_ number: Int) {
        var written = UInt32(number).bigEndian
        Swift.withUnsafeBytes(of: &written) { append(contentsOf: $0) }
    }

    /// A length and these bytes.
    mutating func appendCounted(_ bytes: some Collection<UInt8>) {
        appendNumber(bytes.count)
        append(contentsOf: bytes)
    }

    /// A number of any size, as the protocol writes one: no zeros in front
    /// of it, and one where its first bit would make it negative.
    mutating func appendInteger(_ bytes: some Collection<UInt8>) {
        let value = bytes.drop { $0 == 0 }
        let isNegative = value.first.map { $0 >= 0x80 } ?? false
        appendNumber(value.count + (isNegative ? 1 : 0))
        if isNegative { append(0) }
        append(contentsOf: value)
    }
}

/// `session-bind@openssh.com`: which host this connection is for, by the key
/// that host signed the session with, and whether it reached here by agent
/// forwarding.
struct SessionBind: Equatable {
    let hostKey: Data
    let session: Data
    let signature: Data
    let isForwarded: Bool
}

/// What `ssh` hands the agent to sign when it logs in, as far as a pass reads
/// it. The session comes first, so a signature made over this is good on that
/// session and nowhere else. Nil for anything else, and for a login with
/// another key in it.
struct UserAuthRequest: Equatable {
    /// `SSH2_MSG_USERAUTH_REQUEST`.
    private static let kind: UInt8 = 50
    private static let service = "ssh-connection"
    private static let method = "publickey"
    private static let hostBound = "publickey-hostbound-v00@openssh.com"

    let session: Data
    /// The server's key, which a client names when the server offers to
    /// hear it.
    let hostKey: Data?

    init?(_ data: Data, key: Data) {
        guard let (session, hostKey) = data.withUnsafeBytes({ bytes -> (Data, Data?)? in
            var reader = SSHReader(bytes)
            guard let session = reader.data(), !session.isEmpty, reader.byte() == Self.kind, reader.string() != nil,
                  reader.word() == Self.service, let method = reader.word(), reader.byte() == 1,
                  reader.string() != nil, reader.data() == key
            else { return nil }
            switch method {
            case Self.method:
                return reader.isAtEnd ? (session, nil) : nil
            case Self.hostBound:
                guard let hostKey = reader.data(), reader.isAtEnd else { return nil }
                return (session, hostKey)
            default:
                return nil
            }
        }) else { return nil }
        self.session = session
        self.hostKey = hostKey
    }
}

/// What `ssh-keygen -Y sign` hands the agent to sign, as `PROTOCOL.sshsig`
/// writes it: six bytes of magic with no length, a namespace, a reserved
/// string, the name of a hash and a hash of that size. `git` signs a commit or
/// a tag this way under the namespace `git`. It begins with those six letters
/// where a login begins with its session, so it logs in nowhere, and it says
/// nothing of any host or session, so a signature over it is good for as long
/// as the key is. Nil for anything else, and for a reserved string with
/// something in it, since OpenSSH writes it empty.
struct SSHSigData: Equatable {
    private static let magic = Data("SSHSIG".utf8)
    private static let git = "git"
    /// `ssh-keygen`'s two, by how long each is.
    private static let hashes = ["sha256": 32, "sha512": 64]

    let namespace: String

    /// A commit or a tag: git asks for nothing else in this namespace.
    var isGit: Bool { namespace == Self.git }

    init?(_ data: Data) {
        guard data.starts(with: Self.magic), let namespace = data.dropFirst(Self.magic.count).withUnsafeBytes({ bytes -> String? in
            var reader = SSHReader(bytes)
            guard let namespace = reader.word(), !namespace.isEmpty, reader.string()?.isEmpty == true,
                  let width = reader.word().flatMap({ Self.hashes[$0] }), reader.string()?.count == width,
                  reader.isAtEnd
            else { return nil }
            return namespace
        }) else { return nil }
        self.namespace = namespace
    }
}

/// What a caller asks. Everything the agent does not do arrives as `other`,
/// and is a failure: adding and removing keys, the agent's own lock.
enum AgentRequest: Equatable, Redacted {
    case identities
    case sign(key: Data, data: Data, flags: UInt32)
    case bind(SessionBind)
    /// How many passes stand, for a script about to quit the app.
    case passes
    case other

    /// `SSH2_AGENTC_REQUEST_IDENTITIES` and its neighbours.
    private enum Kind {
        static let identities: UInt8 = 11
        static let sign: UInt8 = 13
        static let `extension`: UInt8 = 27
    }

    static let bindName = "session-bind@openssh.com"
    static let passesName = "passes@oripass"

    init(_ body: Data) {
        self = body.withUnsafeBytes { bytes -> AgentRequest in
            var reader = SSHReader(bytes)
            switch reader.byte() {
            case Kind.identities:
                return .identities
            case Kind.sign:
                guard let key = reader.data(), let data = reader.data(), let flags = reader.number(),
                      reader.isAtEnd
                else { return .other }
                return .sign(key: key, data: data, flags: UInt32(flags))
            case Kind.extension:
                let name = reader.word()
                if name == Self.passesName { return reader.isAtEnd ? .passes : .other }
                guard name == Self.bindName, let hostKey = reader.data(), let session = reader.data(),
                      let signature = reader.data(), let isForwarded = reader.byte(), reader.isAtEnd
                else { return .other }
                return .bind(SessionBind(hostKey: hostKey, session: session, signature: signature,
                                         isForwarded: isForwarded != 0))
            default:
                return .other
            }
        }
    }

    var redactedLabel: String {
        switch self {
        case .identities: return "AgentRequest.identities"
        case .sign: return "AgentRequest.sign"
        case .bind: return "AgentRequest.bind"
        case .passes: return "AgentRequest.passes"
        case .other: return "AgentRequest.other"
        }
    }
}

/// What it answers.
enum AgentAnswer: Equatable {
    case failure, success
    case identities([AgentKey])
    case signature(Data)
    /// A success, and a count after it.
    case count(Int)

    var body: Data {
        switch self {
        case .failure:
            return Data([5])
        case .success:
            return Data([6])
        case .identities(let keys):
            var body = Data([12])
            body.appendNumber(keys.count)
            for key in keys {
                body.appendCounted(key.blob)
                body.appendCounted(Data(key.name.utf8))
            }
            return body
        case .signature(let signature):
            var body = Data([14])
            body.appendCounted(signature)
            return body
        case .count(let count):
            var body = Data([6])
            body.appendNumber(count)
            return body
        }
    }
}
