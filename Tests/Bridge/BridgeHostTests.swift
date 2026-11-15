import Foundation
import XCTest
@testable import OriPass

/// The host as it was built, over pipes, against a `BridgeServer` under a home
/// of the test's own. Under `/tmp`, since `sun_path` holds 104 bytes and the
/// door's path under `$TMPDIR` would be 112.
///
/// Only Orion may start the real one, and no browser is started here, so a
/// test that gets past that asks a copy: the same binary with this process
/// where Orion is, one string for another of the same length, signed again
/// under the name it had. Nothing in the host can be told to look elsewhere,
/// which a switch for a test would have been.
@MainActor
final class BridgeHostTests: XCTestCase {
    private static let built = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/oripass-bridge")
    private static let orion = #"anchor apple generic and certificate leaf[subject.OU] = "TFVG979488" and identifier "com.kagi.kagimacOS""#
    private static let itself = #"anchor apple generic and certificate leaf[subject.OU] = ""# + PeerCheck.team + #"" and identifier "com.meric.oripass" "#
    private static let origin = "chrome-extension://abc/"

    private var home: URL!
    private var server: BridgeServer?
    private var heard: [BridgeRequest] = []
    private var held: CheckedContinuation<BridgeAnswer, Never>?

    private var path: URL { BridgeWire.door(under: home) }

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: "/tmp/op-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        held?.resume(returning: .refused(.gone))
        server?.cut()
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: The host

    private func tool(_ path: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let run = Process()
        run.executableURL = URL(fileURLWithPath: path)
        run.arguments = arguments
        let said = Pipe()
        run.standardOutput = said
        run.standardError = said
        try run.run()
        let output = String(decoding: said.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        run.waitUntilExit()
        return (run.terminationStatus, output)
    }

    private func copy(asking app: String = "com.meric.oripass") throws -> URL {
        var binary = try Data(contentsOf: Self.built)
        // The name with its terminator, or it is the one in the requirement.
        for (old, new) in [(Self.orion, Self.itself), ("com.meric.oripass\0", app + "\0")] {
            let found = try XCTUnwrap(binary.range(of: Data(old.utf8)), "\(old) is not in the host")
            binary.replaceSubrange(found, with: Data(new.utf8))
        }
        let file = home.appendingPathComponent("oripass-bridge")
        try binary.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        let signed = try tool("/usr/bin/codesign", [
            "--force", "--timestamp=none", "--options", "runtime", "--preserve-metadata=identifier,entitlements",
            "--sign", "Apple Development", file.path,
        ])
        XCTAssertEqual(signed.status, 0, signed.output)
        return file
    }

    /// Started with the message already in its pipe, which stays open as
    /// Orion leaves it, unless the test closes it.
    private func start(_ host: URL, sending message: Data? = nil) throws -> (run: Process, sent: Pipe, said: Pipe) {
        let run = Process(), sent = Pipe(), said = Pipe()
        run.executableURL = host
        run.arguments = [Self.origin]
        run.environment = ["CFFIXED_USER_HOME": home.path]
        run.standardInput = sent
        run.standardOutput = said
        run.standardError = FileHandle.nullDevice
        if let message { sent.fileHandleForWriting.write(message) }
        try run.run()
        return (run, sent, said)
    }

    /// Everything it said, once it has gone.
    private func ending(_ run: Process, said: Pipe) async -> Data {
        await Task.detached {
            let everything = said.fileHandleForReading.readDataToEndOfFile()
            run.waitUntilExit()
            return everything
        }.value
    }

    private func frame(_ json: String) -> Data {
        var length = UInt32(json.utf8.count).littleEndian
        return withUnsafeBytes(of: &length) { Data($0) } + Data(json.utf8)
    }

    /// One whole frame and nothing behind it, read for its `type`.
    private func type(in said: Data, file: StaticString = #filePath, line: UInt = #line) throws -> String? {
        XCTAssertGreaterThan(said.count, 4, file: file, line: line)
        var length: UInt32 = 0
        withUnsafeMutableBytes(of: &length) { $0.copyBytes(from: said.prefix(4)) }
        XCTAssertEqual(Int(UInt32(littleEndian: length)), said.count - 4, file: file, line: line)
        let body = try JSONSerialization.jsonObject(with: said.dropFirst(4)) as? [String: Any]
        return body?["type"] as? String
    }

    // MARK: The door

    private func openDoor(_ peers: PeerCheck = PeerCheck(), answering: @escaping (BridgeRequest) async -> BridgeAnswer) throws {
        let server = BridgeServer(path: path, peers: peers) { [weak self] request, _ in
            self?.heard.append(request)
            return await answering(request)
        }
        try server.open()
        self.server = server
    }

    private func gone() async {
        for _ in 0..<400 where server?.connected != 0 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(server?.connected, 0, "the door still has the host")
    }

    private func isHello(_ request: BridgeRequest) -> Bool {
        if case .hello = request { return true }
        return false
    }

    // MARK: One message

    func testOneMessageOneAnswerAndItIsGone() async throws {
        try openDoor { request in
            if case .hello = request { return .ready }
            return .logins(site: "example.com", [BridgeLogin(id: "one", title: "Example", username: "kanarya")])
        }
        let (run, sent, said) = try start(copy(), sending: frame(#"{"v":1,"type":"logins","url":"https://example.com/login"}"#))
        let everything = await ending(run, said: said)
        sent.fileHandleForWriting.closeFile()

        XCTAssertEqual(run.terminationStatus, 0)
        XCTAssertEqual(try type(in: everything), "logins")
        XCTAssertTrue(String(decoding: everything, as: UTF8.self).contains("kanarya"))
        XCTAssertEqual(heard.count, 2)
        guard case .hello(let origin, let browser)? = heard.first, case .logins(let url)? = heard.last else {
            return XCTFail("\(heard)")
        }
        XCTAssertEqual(origin, Self.origin)
        XCTAssertEqual(browser, "com.kagi.kagimacOS")
        XCTAssertEqual(url, "https://example.com/login")
        await gone()
    }

    func testAnExtensionsOwnHelloNamesNobody() async throws {
        try openDoor { _ in .ready }
        let hello = #"{"v":1,"type":"hello","origin":"chrome-extension://other/","browser":"com.apple.Safari"}"#
        let (run, sent, said) = try start(copy(), sending: frame(hello))
        let everything = await ending(run, said: said)
        sent.fileHandleForWriting.closeFile()

        XCTAssertEqual(try type(in: everything), "ready")
        XCTAssertEqual(heard.count, 1)
        guard case .hello(let origin, let browser)? = heard.first else { return XCTFail("\(heard)") }
        XCTAssertEqual(origin, Self.origin)
        XCTAssertEqual(browser, "com.kagi.kagimacOS")
    }

    func testAnOriginTheDoorHasNotLetInAsksNothingFurther() async throws {
        try openDoor { _ in .unknown }
        let (run, sent, said) = try start(copy(), sending: frame(#"{"v":1,"type":"fill","id":"one","url":"https://example.com/"}"#))
        let everything = await ending(run, said: said)
        sent.fileHandleForWriting.closeFile()

        XCTAssertEqual(try type(in: everything), "unknown")
        XCTAssertEqual(heard.count, 1)
        XCTAssertTrue(isHello(heard[0]))
    }

    // MARK: What it does not take

    func testAMessageOverTheCapIsNotPassedOn() async throws {
        try openDoor { _ in .ready }
        var length = UInt32(BridgeWire.most + 1).littleEndian
        let (run, sent, said) = try start(copy(), sending: withUnsafeBytes(of: &length) { Data($0) })
        let everything = await ending(run, said: said)
        sent.fileHandleForWriting.closeFile()

        XCTAssertTrue(everything.isEmpty, "\(everything.count) bytes")
        XCTAssertEqual(run.terminationStatus, 1)
        XCTAssertTrue(heard.isEmpty)
    }

    func testAMessageThatDoesNotReadIsNotPassedOn() async throws {
        try openDoor { _ in .ready }
        let (run, sent, said) = try start(copy(), sending: frame("not json"))
        let everything = await ending(run, said: said)
        sent.fileHandleForWriting.closeFile()

        XCTAssertTrue(everything.isEmpty, "\(everything.count) bytes")
        XCTAssertTrue(heard.isEmpty)
    }

    /// The real host, unchanged, and this process is no browser.
    func testAParentThatIsNotABrowserHearsNothing() async throws {
        try openDoor { _ in .ready }
        let (run, sent, said) = try start(Self.built, sending: frame(#"{"v":1,"type":"hello"}"#))
        let everything = await ending(run, said: said)
        sent.fileHandleForWriting.closeFile()

        XCTAssertTrue(everything.isEmpty, "\(everything.count) bytes to a stranger")
        XCTAssertEqual(run.terminationStatus, 1)
        XCTAssertTrue(heard.isEmpty)
        XCTAssertEqual(server?.connected, 0)
    }

    // MARK: The app not there

    func testNoDoorWithTheAppRunningIsLocked() async throws {
        let (run, sent, said) = try start(copy(), sending: frame(#"{"v":1,"type":"hello"}"#))
        let everything = await ending(run, said: said)
        sent.fileHandleForWriting.closeFile()

        XCTAssertEqual(try type(in: everything), "locked")
        XCTAssertEqual(run.terminationStatus, 0)
    }

    func testNoDoorAndNoAppIsClosed() async throws {
        let (run, sent, said) = try start(copy(asking: "com.meric.oripasz"), sending: frame(#"{"v":1,"type":"hello"}"#))
        let everything = await ending(run, said: said)
        sent.fileHandleForWriting.closeFile()

        XCTAssertEqual(try type(in: everything), "closed")
    }

    func testADoorThatClosesOnTheHostIsTheSameAsNoDoor() async throws {
        try openDoor(PeerCheck(team: "ABCDE12345")) { _ in .ready }
        let (run, sent, said) = try start(copy(), sending: frame(#"{"v":1,"type":"hello"}"#))
        let everything = await ending(run, said: said)
        sent.fileHandleForWriting.closeFile()

        XCTAssertEqual(try type(in: everything), "locked")
        XCTAssertTrue(heard.isEmpty)
    }

    func testTheAppGoingWhileAnAnswerIsAwaitedEndsIt() async throws {
        try openDoor { [weak self] request in
            if case .hello = request { return .ready }
            return await withCheckedContinuation { self?.held = $0 }
        }
        let (run, sent, said) = try start(copy(asking: "com.meric.oripasz"),
                                          sending: frame(#"{"v":1,"type":"logins","url":"https://example.com/"}"#))
        for _ in 0..<400 where held == nil {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNotNil(held)
        server?.cut()
        let everything = await ending(run, said: said)
        sent.fileHandleForWriting.closeFile()

        XCTAssertEqual(try type(in: everything), "closed")
    }

    // MARK: It leaves no process

    func testStandardInputClosingBeforeAMessageEndsIt() async throws {
        let (run, sent, said) = try start(copy())
        sent.fileHandleForWriting.closeFile()
        let everything = await ending(run, said: said)

        XCTAssertTrue(everything.isEmpty, "\(everything.count) bytes")
        XCTAssertEqual(run.terminationStatus, 1)
    }

    func testStandardInputClosingWhileAnAnswerIsAwaitedEndsIt() async throws {
        try openDoor { [weak self] request in
            if case .hello = request { return .ready }
            return await withCheckedContinuation { self?.held = $0 }
        }
        let (run, sent, said) = try start(copy(), sending: frame(#"{"v":1,"type":"fill","id":"one","url":"https://example.com/"}"#))
        for _ in 0..<400 where held == nil {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNotNil(held)
        sent.fileHandleForWriting.closeFile()
        let everything = await ending(run, said: said)

        XCTAssertTrue(everything.isEmpty, "\(everything.count) bytes")
        XCTAssertFalse(run.isRunning)
    }

    /// A host nobody sends anything and nobody hangs up on, which is the one
    /// test here that waits, and for as long as the card says.
    func testThirtySecondsEndIt() async throws {
        let began = Date()
        let (run, sent, said) = try start(copy())
        let everything = await ending(run, said: said)
        sent.fileHandleForWriting.closeFile()

        XCTAssertTrue(everything.isEmpty, "\(everything.count) bytes")
        XCTAssertEqual(run.terminationReason, .uncaughtSignal)
        XCTAssertEqual(Date().timeIntervalSince(began), 30, accuracy: 3)
    }

    // MARK: What the door knows it by

    func testTheBuiltHostIsSignedAsTheDoorExpects() throws {
        let read = try tool("/usr/bin/codesign", ["-dv", "--verbose=2", Self.built.path])
        XCTAssertTrue(read.output.contains("Identifier=\(BridgeCaller.host.rawValue)\n"), read.output)
        XCTAssertTrue(read.output.contains("(runtime)"), read.output)
        XCTAssertTrue(read.output.contains("TeamIdentifier=\(PeerCheck.team)\n"), read.output)
        let verified = try tool("/usr/bin/codesign", ["--verify", "--strict", Self.built.path])
        XCTAssertEqual(verified.status, 0, verified.output)
    }
}
