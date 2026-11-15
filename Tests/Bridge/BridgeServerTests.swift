import Foundation
import XCTest
@testable import OriPass

/// The door as a file in a temporary directory, which is the one place a
/// test makes a socket file. The process that hosts the tests is the caller
/// that is let in, under its own name, and `/usr/bin/nc` is the one that is
/// not. No browser is started.
@MainActor
final class BridgeServerTests: XCTestCase {
    /// What the tests' own host is signed as.
    private static let itself = PeerCheck(identifiers: [.safari: AppInfo.bundleID])

    private var directory: URL!
    private var kept: [BrowserDoor] = []

    /// Short: `sun_path` holds 104 bytes and `$TMPDIR` has used about 50.
    private var path: URL { directory.appendingPathComponent("bridge") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("op-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() async throws {
        kept = []
        try? FileManager.default.removeItem(at: directory)
    }

    private func open(_ peers: PeerCheck = itself) async -> (door: BrowserDoor, store: VaultStore) {
        let backend = DemoVault.backend()
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        let door = BrowserDoor(store: store, reprompt: Reprompt(store: store, authoriser: FakeAuthoriser()),
                               preferences: Preferences(), path: path, peers: peers)
        kept.append(door)
        await store.unlock(password: SecretBytes(DemoVault.password))
        return (door, store)
    }

    private func dial() throws -> Int32 {
        let end = socket(AF_UNIX, SOCK_STREAM, 0)
        var wait = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(end, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(end, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let written = Array(path.path.utf8CString).map { UInt8(bitPattern: $0) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: written) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(end, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(connected, 0, "\(errno)")
        return end
    }

    private func hello(on end: Int32) throws {
        try BridgeWire.write(Data(#"{"v":1,"type":"hello"}"#.utf8), to: end)
    }

    /// What the door answers, as a type, and nil if it closed on the caller.
    private func answer(on end: Int32) async -> String? {
        await Task.detached { () -> String? in
            guard let body = try? BridgeWire.read(from: end),
                  let said = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            else { return nil }
            return said["type"] as? String
        }.value
    }

    private func until(_ isSo: () -> Bool) async {
        for _ in 0..<400 where !isSo() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private var doors: [Instruments.Entry] { Instruments.live.filter { $0.owner == "Bridge" } }

    // MARK: Who is calling

    func testThisProcessIsTakenUnderItsOwnName() async throws {
        _ = await open()
        let end = try dial()
        defer { close(end) }
        try hello(on: end)
        let said = await answer(on: end)
        XCTAssertEqual(said, "ready")
    }

    func testTheCallerIsNamedByItsSignatureAndNotByItsMessage() async throws {
        let (door, _) = await open(PeerCheck(identifiers: [.host: AppInfo.bundleID]))
        let end = try dial()
        defer { close(end) }
        // The same process, under the host's name, so its origin counts.
        try BridgeWire.write(Data(#"{"v":1,"type":"hello","browser":"com.apple.Safari"}"#.utf8), to: end)
        let said = await answer(on: end)
        XCTAssertEqual(said, "unknown")
        XCTAssertEqual(door.connected, 0)
    }

    func testAProcessOfAnotherTeamIsTurnedAway() async throws {
        _ = await open(PeerCheck(team: "ABCDE12345", identifiers: [.safari: AppInfo.bundleID]))
        let end = try dial()
        defer { close(end) }
        try hello(on: end)
        let said = await answer(on: end)
        XCTAssertNil(said)
    }

    func testAProcessUnderAnotherNameIsTurnedAway() async throws {
        _ = await open(PeerCheck())
        let end = try dial()
        defer { close(end) }
        try hello(on: end)
        let said = await answer(on: end)
        XCTAssertNil(said)
    }

    /// `/usr/bin/nc` is Apple's and has no team: a real process that is not
    /// this one, sending a hello that nobody reads.
    func testAnotherProcessIsClosedOnBeforeAByteIsRead() async throws {
        let (door, _) = await open()
        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        run.arguments = ["-U", path.path]
        let said = Pipe(), sent = Pipe()
        run.standardInput = sent
        run.standardOutput = said
        run.standardError = FileHandle.nullDevice
        try run.run()
        sent.fileHandleForWriting.write(Data([22, 0, 0, 0]) + Data(#"{"v":1,"type":"hello"}"#.utf8))
        sent.fileHandleForWriting.closeFile()
        let heard = await Task.detached { said.fileHandleForReading.readDataToEndOfFile() }.value
        run.waitUntilExit()
        XCTAssertTrue(heard.isEmpty, "\(heard.count) bytes to a stranger")
        XCTAssertEqual(door.connected, 0)
    }

    func testAPeerAnyoneMayAttachToIsTurnedAwayByAReleaseBuild() async throws {
        _ = await open(PeerCheck(identifiers: [.safari: AppInfo.bundleID], takesDebuggable: false))
        let end = try dial()
        defer { close(end) }
        try hello(on: end)
        let said = await answer(on: end)
        XCTAssertNil(said)
    }

    // MARK: The file and the lock

    func testTheFileIsOnlyForThisUserAndGoesAtTheLock() async throws {
        let (door, store) = await open()
        XCTAssertTrue(door.isOpen)
        let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)

        await store.lock()
        XCTAssertFalse(door.isOpen)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testInstrumentsCountsOneListenerWhileUnlockedAndNoneWhileLocked() async throws {
        XCTAssertEqual(doors.count, 0)
        let (_, store) = await open()
        XCTAssertEqual(doors.map(\.name), ["door"])
        await store.lock()
        XCTAssertEqual(doors.count, 0)
        await store.unlock(password: SecretBytes(DemoVault.password))
        XCTAssertEqual(doors.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        await store.lock()
        XCTAssertEqual(doors.count, 0)
    }

    func testALockedStoreHasNoDoorAtAll() async throws {
        let backend = DemoVault.backend()
        let store = VaultStore(backend: backend)
        let door = BrowserDoor(store: store, reprompt: Reprompt(store: store, authoriser: FakeAuthoriser()),
                               preferences: Preferences(), path: path, peers: Self.itself)
        XCTAssertFalse(door.isOpen)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(doors.count, 0)
    }

    func testAFileLeftByARunThatWasKilledIsTakenOver() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: path)
        let (door, _) = await open()
        XCTAssertTrue(door.isOpen)
        let end = try dial()
        defer { close(end) }
        try hello(on: end)
        let said = await answer(on: end)
        XCTAssertEqual(said, "ready")
    }

    func testTheLockCutsEveryConnectionBeforeItEmptiesTheStore() async throws {
        let (door, store) = await open()
        XCTAssertFalse(store.shelves.all.isEmpty)
        let first = try dial(), second = try dial()
        defer {
            close(first)
            close(second)
        }
        try hello(on: first)
        try hello(on: second)
        let said = await [answer(on: first), answer(on: second)]
        XCTAssertEqual(said, ["ready", "ready"])
        XCTAssertEqual(door.connected, 2)

        var heldAtTheCut = -1, connectedAtTheCut = -1, heldAtTheEnd = -1
        let willLock = NotificationCenter.default.addObserver(forName: VaultStore.willLock, object: store, queue: nil) { _ in
            MainActor.assumeIsolated {
                heldAtTheCut = store.shelves.all.count
                connectedAtTheCut = door.connected
            }
        }
        let didLock = NotificationCenter.default.addObserver(forName: VaultStore.didLock, object: store, queue: nil) { _ in
            MainActor.assumeIsolated { heldAtTheEnd = store.shelves.all.count }
        }
        defer {
            NotificationCenter.default.removeObserver(willLock)
            NotificationCenter.default.removeObserver(didLock)
        }
        await store.lock()

        XCTAssertGreaterThan(heldAtTheCut, 0, "the store was emptied first")
        XCTAssertEqual(connectedAtTheCut, 0, "a connection outlived the store's last turn")
        XCTAssertEqual(heldAtTheEnd, 0)
        let after = await [answer(on: first), answer(on: second)]
        XCTAssertEqual(after, [nil, nil])
    }

    func testAPathTooLongForASocketIsNotOpened() async throws {
        let long = directory.appendingPathComponent(String(repeating: "x", count: 120))
        let backend = DemoVault.backend()
        let store = VaultStore(backend: backend)
        let door = BrowserDoor(store: store, reprompt: Reprompt(store: store, authoriser: FakeAuthoriser()),
                               preferences: Preferences(), path: long, peers: Self.itself)
        await store.unlock(password: SecretBytes(DemoVault.password))
        XCTAssertFalse(door.isOpen)
        await store.lock()
    }
}
