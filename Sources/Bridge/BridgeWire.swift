import Foundation
import Security

/// What goes through the door for the browser, as `docs/notes.md` "The door
/// for the browser" writes it down: a four byte length and then that much
/// JSON. The host for Orion is built with this file and with nothing else of
/// the app's, and the browser's own framing is the same.
enum BridgeWire {
    static let version = 1
    /// A length over this closes the connection before its body is read.
    static let most = 1_048_576
    /// The team this code is signed by, read from its own signature, so no
    /// file of the repo names one: the build takes it from `Team.xcconfig`
    /// or `OP_TEAM`. Empty for code with no team, which then finds no door.
    static let team: String = {
        var code: SecCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(unsafeBitCast(code, to: SecStaticCode.self),
                                            SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess
        else { return "" }
        return (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String ?? ""
    }()

    /// The group the door stands in. A group under the team's own prefix
    /// needs no provisioning profile on macOS.
    static let group = "\(team).oripass"

    /// Whatever a read of the door's waits for, as the host's `alarm` does,
    /// a finger included.
    static let patience = 30

    /// Where a process with no group of its own looks for the door, under
    /// the home it was given.
    static func door(under home: URL) -> URL {
        home.appendingPathComponent("Library/Group Containers/\(group)/bridge")
    }

    /// Where the system says the door is, for a process that carries the
    /// group, which a sandbox has to ask for since its home is its own.
    static var doorInTheGroup: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("bridge")
    }

    /// One message through the door on a connection of its own, the caller's
    /// `hello` first. Nil with no door, or one that closed with no answer,
    /// which only the caller can put a word to. The door wants `hello` once
    /// on a connection and this one is the caller's, so an extension's own is
    /// answered with it and goes no further (`docs/notes.md`, "The host for
    /// Orion").
    static func pass(_ message: Data, saying hello: Data, to path: URL) -> Data? {
        guard let door = dial(path) else { return nil }
        defer { close(door) }
        guard (try? write(hello, to: door)) != nil, let standing = try? read(from: door) else { return nil }
        guard kind(of: message) != "hello", kind(of: standing) == "ready" else { return standing }
        guard (try? write(message, to: door)) != nil else { return nil }
        return try? read(from: door)
    }

    static func kind(of body: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["type"] as? String
    }

    /// A connection with nothing said on it yet. A pipe that has gone is an
    /// error from `write` here and not a signal, whoever is calling.
    private static func dial(_ path: URL) -> Int32? {
        let end = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let written = Array(path.path.utf8CString).map { UInt8(bitPattern: $0) }
        guard end >= 0 else { return nil }
        var on: Int32 = 1
        var wait = timeval(tv_sec: patience, tv_usec: 0)
        setsockopt(end, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(end, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        guard written.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(end)
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: written) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(end, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(end)
            return nil
        }
        return end
    }

    enum Failure: Error {
        /// The other end closed, or this one was cut.
        case hungUp
        case tooLong
    }

    /// The next message, whole.
    static func read(from descriptor: Int32) throws -> Data {
        var length: UInt32 = 0
        try withUnsafeMutableBytes(of: &length) { try fill($0, from: descriptor) }
        let count = Int(UInt32(littleEndian: length))
        guard count <= most else { throw Failure.tooLong }
        var body = Data(count: count)
        try body.withUnsafeMutableBytes { try fill($0, from: descriptor) }
        return body
    }

    static func write(_ body: Data, to descriptor: Int32) throws {
        var length = UInt32(body.count).littleEndian
        try withUnsafeBytes(of: &length) { try send($0, to: descriptor) }
        try body.withUnsafeBytes { try send($0, to: descriptor) }
    }

    static func fill(_ buffer: UnsafeMutableRawBufferPointer, from descriptor: Int32) throws {
        var filled = 0
        while filled < buffer.count {
            let got = Darwin.read(descriptor, buffer.baseAddress! + filled, buffer.count - filled)
            if got < 0, errno == EINTR { continue }
            guard got > 0 else { throw Failure.hungUp }
            filled += got
        }
    }

    static func send(_ buffer: UnsafeRawBufferPointer, to descriptor: Int32) throws {
        var sent = 0
        while sent < buffer.count {
            let wrote = Darwin.write(descriptor, buffer.baseAddress! + sent, buffer.count - sent)
            if wrote < 0, errno == EINTR { continue }
            guard wrote > 0 else { throw Failure.hungUp }
            sent += wrote
        }
    }
}
