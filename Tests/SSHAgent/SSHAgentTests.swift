import Foundation
import XCTest
@testable import OriPass

/// Keys made by `ssh-keygen` for this run, in a temporary directory, for no
/// host and with no passphrase, and thrown away with it.
enum AgentFixture {
    struct Key {
        let file: URL
        let text: String
        let publicLine: String

        /// The public half as the protocol writes it.
        var blob: Data { Data(base64Encoded: String(publicLine.split(separator: " ")[1]))! }
    }

    static let directory: URL = {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oripass-agent-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private static func made(_ name: String, _ arguments: [String], passphrase: String = "") -> Key {
        let file = directory.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-q", "-N", passphrase, "-C", "invented", "-f", file.path] + arguments
        try! process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)
        return Key(file: file, text: try! String(contentsOf: file),
                   publicLine: try! String(contentsOf: file.appendingPathExtension("pub")))
    }

    static let ed25519 = made("ed25519", ["-t", "ed25519"])
    static let p256 = made("p256", ["-t", "ecdsa", "-b", "256"])
    static let p384 = made("p384", ["-t", "ecdsa", "-b", "384"])
    static let p521 = made("p521", ["-t", "ecdsa", "-b", "521"])
    static let rsa = made("rsa", ["-t", "rsa", "-b", "2048"])
    static let locked = made("locked", ["-t", "ed25519"], passphrase: "invented")

    static let all: [(name: String, key: Key)] = [
        ("ed25519", ed25519), ("p256", p256), ("p384", p384), ("p521", p521), ("rsa", rsa),
    ]

    static func item(_ id: Int, _ name: String, _ key: String) -> JSONValue {
        .object([
            "object": .string("item"), "id": .string("00000000-0000-0000-0000-\(String(format: "%012d", id))"),
            "organizationId": .null, "folderId": .null, "type": .int(5), "reprompt": .int(0), "name": .string(name),
            "notes": .null, "favorite": .bool(false), "collectionIds": .array([]), "passwordHistory": .null,
            "creationDate": .string("2025-01-01T00:00:00.000Z"), "revisionDate": .string("2025-06-01T00:00:00.000Z"),
            "sshKey": .object(["privateKey": .string(key), "publicKey": .string(""), "keyFingerprint": .string("")]),
        ])
    }

    /// One item for each kind, by the kind's name.
    static var vault: [JSONValue] {
        all.enumerated().map { item($0.offset + 1, $0.element.name, $0.element.key.text) }
    }
}

/// A caller's end, which is a client of the protocol and knows nothing of
/// the app's types beyond what it sends.
struct AgentCaller {
    let end: Int32

    init(end: Int32) {
        self.end = end
        var wait = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(end, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(end, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// The answer, or nil if the agent closed on it.
    func ask(_ body: Data) async -> Data? {
        let end = self.end
        return await Task.detached {
            do {
                try AgentWire.write(body, to: end)
                return try AgentWire.read(from: end)
            } catch {
                return nil
            }
        }.value
    }

    func list() async -> [Data]? {
        guard let body = await ask(Data([11])) else { return nil }
        return body.withUnsafeBytes { bytes -> [Data]? in
            var reader = SSHReader(bytes)
            guard reader.byte() == 12, let count = reader.number() else { return nil }
            var blobs: [Data] = []
            for _ in 0..<count {
                guard let blob = reader.data(), reader.string() != nil else { return nil }
                blobs.append(blob)
            }
            return blobs
        }
    }

    /// The signature, or nil for a failure.
    func sign(_ data: Data, with key: Data, flags: UInt32 = 0) async -> Data? {
        var body = Data([13])
        body.appendCounted(key)
        body.appendCounted(data)
        body.appendNumber(Int(flags))
        guard let answer = await ask(body) else { return nil }
        return answer.withUnsafeBytes { bytes -> Data? in
            var reader = SSHReader(bytes)
            guard reader.byte() == 14 else { return nil }
            return reader.data()
        }
    }

    /// `session-bind@openssh.com`, and whether the agent took it.
    func bind(host: Data, session: Data, signature: Data, forwarded: Bool) async -> Bool {
        var body = Data([27])
        body.appendCounted(Data(AgentRequest.bindName.utf8))
        body.appendCounted(host)
        body.appendCounted(session)
        body.appendCounted(signature)
        body.append(forwarded ? 1 : 0)
        return await ask(body) == Data([6])
    }
}

/// The agent over a socketpair, and the fake vault, enclave and question
/// behind it. No file, and no finger.
@MainActor
final class SSHAgentTests: XCTestCase {
    private static let ssh = AgentPeer(names: ["ssh", "zsh", "Terminal"], app: "/System/Applications/Terminal.app")
    private static let other = AgentPeer(names: ["ssh", "zsh", "OriCode"], app: "/Applications/OriCode.app")
    private static let data = Data("what is being signed".utf8)
    private static let flags256: UInt32 = 2
    private static let flags512: UInt32 = 4

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private struct Rig {
        let store: VaultStore
        let door: Door
        let enclave: FakeEnclave
        let authoriser: FakeAuthoriser
        let stage: RememberingAgentStage
        let agent: SSHAgent
        let clock: Clock
    }

    private var directories: [URL] = []
    private var ends: [Int32] = []
    private var keeping: [Any] = []

    override func tearDown() async throws {
        ends.forEach { close($0) }
        ends = []
        keeping = []
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
    }

    /// A vault of one key of each kind, open unless told otherwise, with a
    /// password sealed for a finger unless told otherwise.
    private func rig(items: [JSONValue] = AgentFixture.vault, isOpen: Bool = true, hasSeal: Bool = true,
                     patience: TimeInterval = 5) async -> Rig {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oripass-agent-seal-\(UUID().uuidString)")
        directories.append(directory)
        let enclave = FakeEnclave()
        let seal = PasswordSeal(directory: directory, enclave: enclave)
        let backend = FakeBackend(items: items, folders: [], password: "demo")
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        let door = Door(store: store, seal: hasSeal ? seal : nil, isInFront: { false })
        door.preferences.settings.lock.unlockWithFinger = hasSeal
        let authoriser = FakeAuthoriser()
        let stage = RememberingAgentStage()
        let clock = Clock()
        let agent = SSHAgent(door: door, authoriser: authoriser, stage: stage, now: { clock.now }, patience: patience)
        await door.unlock(with: SecretBytes("demo")).value
        if !isOpen { await store.lock() }
        keeping.append(agent)
        return Rig(store: store, door: door, enclave: enclave, authoriser: authoriser, stage: stage, agent: agent,
                   clock: clock)
    }

    private func caller(of rig: Rig, as peer: AgentPeer = ssh) -> AgentCaller {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        rig.agent.adopt(pair[1], peer: peer)
        ends.append(pair[0])
        return AgentCaller(end: pair[0])
    }

    private func signingOnce(_ rig: Rig, as peer: AgentPeer = ssh) async -> Data? {
        await caller(of: rig, as: peer).sign(Self.data, with: AgentFixture.ed25519.blob)
    }

    private func algorithm(of signature: Data) -> String? {
        signature.withUnsafeBytes { bytes in
            var reader = SSHReader(bytes)
            return reader.word()
        }
    }

    // MARK: Signing

    func testEveryKindOfKeyIsListedAndSignsWhatAVerifierTakes() async throws {
        let rig = await rig()
        let caller = caller(of: rig)
        let list = await caller.list()
        XCTAssertEqual(list, AgentFixture.all.map(\.key.blob))
        let wanted = [("ed25519", "ssh-ed25519", UInt32(0)), ("p256", "ecdsa-sha2-nistp256", 0),
                      ("p384", "ecdsa-sha2-nistp384", 0), ("p521", "ecdsa-sha2-nistp521", 0),
                      ("rsa", "rsa-sha2-256", Self.flags256), ("rsa", "rsa-sha2-512", Self.flags512)]
        for (name, signedAs, flags) in wanted {
            let key = try XCTUnwrap(AgentFixture.all.first { $0.name == name }).key
            let signature = await caller.sign(Self.data, with: key.blob, flags: flags)
            let made = try XCTUnwrap(signature, name)
            XCTAssertEqual(algorithm(of: made), signedAs)
            XCTAssertTrue(SSHVerifies(made, over: Self.data, by: key.blob), name)
            XCTAssertFalse(SSHVerifies(made, over: Data("something else".utf8), by: key.blob), name)
        }
    }

    func testRSAIsNeverSignedUnderSHA1() async {
        let rig = await rig()
        let answer = await caller(of: rig).sign(Self.data, with: AgentFixture.rsa.blob, flags: 0)
        XCTAssertNil(answer)
        XCTAssertEqual(rig.authoriser.asked, [], "nobody is asked about what would be refused anyway")
    }

    func testWhatTheAgentDoesNotDoIsAFailure() async {
        let rig = await rig()
        let caller = caller(of: rig)
        var extensionOfNoUse = Data([27])
        extensionOfNoUse.appendCounted(Data("query".utf8))
        // Add, add with a constraint, remove, remove all, lock and unlock.
        for body in [Data([17]), Data([25]), Data([18]), Data([19]), Data([22]), Data([23]), Data([200]),
                     extensionOfNoUse, Data()] {
            let answer = await caller.ask(body)
            XCTAssertEqual(answer, Data([5]), "\(body.first ?? 0)")
        }
    }

    func testAKeyOutOfTheVaultIsRefused() async {
        let rig = await rig(items: [AgentFixture.item(1, "one", AgentFixture.ed25519.text)])
        let answer = await caller(of: rig).sign(Self.data, with: AgentFixture.p256.blob)
        XCTAssertNil(answer)
    }

    func testAKeyThatCannotSignIsNotListed() async throws {
        let rig = await rig(items: [
            AgentFixture.item(1, "kept", AgentFixture.ed25519.text),
            AgentFixture.item(2, "behind a passphrase", AgentFixture.locked.text),
            AgentFixture.item(3, "invented", DemoVault.pastedKey),
            AgentFixture.item(4, "no file", "not a key"),
        ])
        let list = await caller(of: rig).list()
        XCTAssertEqual(list, [AgentFixture.ed25519.blob])
    }

    func testALengthOverTheCapClosesTheConnection() async {
        let rig = await rig()
        let caller = caller(of: rig)
        var length = UInt32(AgentWire.most + 1).bigEndian
        withUnsafeBytes(of: &length) { _ = write(caller.end, $0.baseAddress, 4) }
        let read = await Task.detached { try? AgentWire.read(from: caller.end) }.value
        XCTAssertNil(read)
    }

    func testTheDemoVaultsKeySigns() async throws {
        let half = try XCTUnwrap(PrivateHalf(DemoVault.agentKey))
        let key = try XCTUnwrap(half.publicKey)
        XCTAssertEqual(key.kind, .ed25519)
        let signature = try XCTUnwrap(half.sign(Self.data))
        XCTAssertTrue(SSHVerifies(signature, over: Self.data, by: key.blob))
        XCTAssertNil(PrivateHalf(DemoVault.pastedKey)?.publicKey, "the shape of a key and no key")

        let rig = await rig(items: DemoVault.objects().items)
        let list = await caller(of: rig).list()
        XCTAssertEqual(list, [key.blob], "the one in the demo vault that signs")
    }

    func testThePrivateHalfSaysNothing() throws {
        let half = try XCTUnwrap(PrivateHalf(AgentFixture.ed25519.text))
        XCTAssertEqual("\(half)", "PrivateHalf")
        var dumped = ""
        dump(half, to: &dumped)
        XCTAssertFalse(dumped.contains("file"))
        let blob = try XCTUnwrap(half.publicKey?.blob)
        XCTAssertEqual(blob, AgentFixture.ed25519.blob)
        half.wipe()
        XCTAssertNil(half.sign(Self.data), "nothing is left to sign with")
    }

    // MARK: A shut vault

    func testOverAShutVaultOneFingerAnswersTheListAndTheSignature() async {
        let rig = await rig(isOpen: false)
        let caller = caller(of: rig)
        let list = await caller.list()
        XCTAssertEqual(list?.count, AgentFixture.all.count)
        XCTAssertEqual(rig.store.state, .unlocked)
        XCTAssertEqual(rig.enclave.asked, [Door.agentReason])
        let signature = await caller.sign(Self.data, with: AgentFixture.ed25519.blob)
        XCTAssertNotNil(signature)
        XCTAssertEqual(rig.enclave.asked.count, 1)
        XCTAssertEqual(rig.authoriser.asked, [], "the finger that opened the vault was the answer")
    }

    func testTheCardNamesWhoWantsAShutVaultOpened() async throws {
        let rig = await rig(isOpen: false)
        _ = await caller(of: rig).list()
        let question = try XCTUnwrap(rig.stage.shown.first)
        XCTAssertNil(question.key)
        XCTAssertEqual(question.chain, "ssh › zsh › Terminal")
        XCTAssertTrue(question.statement.contains("Terminal"))
        XCTAssertNil(rig.stage.showing, "the card goes with the finger")
    }

    func testDenyOverAShutVaultTakesTheSheetDown() async throws {
        let rig = await rig(isOpen: false)
        rig.stage.deniesAtOnce = true
        _ = await caller(of: rig).list()
        XCTAssertEqual(rig.authoriser.withdrawn, 1)
    }

    func testWithNoFingerToAskForThereIsNoCard() async {
        let rig = await rig(isOpen: false, hasSeal: false)
        _ = await caller(of: rig).list()
        XCTAssertTrue(rig.stage.shown.isEmpty)
    }

    func testAWithdrawalReachesTheSheet() {
        let enclave = FakeEnclave()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oripass-agent-seal-\(UUID().uuidString)")
        directories.append(directory)
        let store = VaultStore(backend: DemoVault.backend())
        OwnerCheck(store: store, seal: PasswordSeal(directory: directory, enclave: enclave), stage: nil).withdraw()
        XCTAssertEqual(enclave.withdrawn, 1)
    }

    func testTheFingerGoesStaleOnALongConnection() async {
        let rig = await rig(isOpen: false, patience: 0.5)
        let caller = caller(of: rig)
        _ = await caller.list()
        rig.clock.now.addTimeInterval(1)
        let signature = await caller.sign(Self.data, with: AgentFixture.ed25519.blob)
        XCTAssertNotNil(signature)
        XCTAssertEqual(rig.authoriser.asked, [.sign], "too long after the finger to be what it was for")
    }

    func testTheFingerOfTheListStandsForTheNextSshAsAnApproval() async {
        let rig = await rig(isOpen: false)
        let first = caller(of: rig)
        _ = await first.list()
        _ = await first.sign(Self.data, with: AgentFixture.ed25519.blob)
        let second = await signingOnce(rig)
        XCTAssertNotNil(second)
        XCTAssertEqual(rig.authoriser.asked, [])
    }

    func testASignatureOverAShutVaultTakesOneFingerToo() async {
        let rig = await rig(isOpen: false)
        let signature = await signingOnce(rig)
        XCTAssertNotNil(signature)
        XCTAssertEqual(rig.enclave.asked.count, 1)
        XCTAssertEqual(rig.authoriser.asked, [])
    }

    func testTwoCallersOverAShutVaultShareOneFinger() async {
        let rig = await rig(isOpen: false)
        async let one = caller(of: rig).list()
        async let two = caller(of: rig, as: Self.other).list()
        let (first, second) = await (one, two)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(rig.enclave.asked.count, 1)
    }

    func testARefusedFingerFailsAndLeavesItShut() async {
        let rig = await rig(isOpen: false)
        rig.enclave.cancels = true
        let list = await caller(of: rig).list()
        XCTAssertNil(list)
        XCTAssertEqual(rig.store.state, .locked)
        XCTAssertNil(rig.door.agentRefusal, "he said no, and needs no telling")
    }

    func testWithNoSealTheRequestFailsAndTheLockScreenSaysWhy() async {
        let rig = await rig(isOpen: false, hasSeal: false)
        let list = await caller(of: rig).list()
        XCTAssertNil(list)
        XCTAssertEqual(rig.enclave.asked, [])
        XCTAssertEqual(rig.door.agentRefusal, Door.agentWaited)
        await rig.door.unlock(with: SecretBytes("demo")).value
        XCTAssertNil(rig.door.agentRefusal)
    }

    func testAPasswordBeingTriedIsWaitedFor() async {
        let rig = await rig(isOpen: false)
        rig.door.unlock(with: SecretBytes("demo"))
        let list = await caller(of: rig).list()
        XCTAssertNotNil(list)
    }

    // MARK: Who is asked, and for how long

    func testAYesIsOneKeyForOneAppForTenMinutes() async {
        let rig = await rig()
        var signature = await signingOnce(rig)
        XCTAssertNotNil(signature)
        XCTAssertEqual(rig.authoriser.asked, [.sign])

        signature = await signingOnce(rig)
        XCTAssertNotNil(signature, "a second ssh inside the window")
        XCTAssertEqual(rig.authoriser.asked.count, 1)

        signature = await signingOnce(rig, as: Self.other)
        XCTAssertNotNil(signature)
        XCTAssertEqual(rig.authoriser.asked.count, 2, "another app")

        signature = await caller(of: rig).sign(Self.data, with: AgentFixture.p256.blob)
        XCTAssertNotNil(signature)
        XCTAssertEqual(rig.authoriser.asked.count, 3, "another key")

        rig.clock.now.addTimeInterval(10 * 60 - 1)
        signature = await signingOnce(rig)
        XCTAssertEqual(rig.authoriser.asked.count, 3)

        rig.clock.now.addTimeInterval(2)
        signature = await signingOnce(rig)
        XCTAssertNotNil(signature)
        XCTAssertEqual(rig.authoriser.asked.count, 4, "the window ran out")
    }

    func testEachUseIsAskedEachUse() async {
        let rig = await rig()
        rig.door.preferences.settings.ssh.approval = .eachUse
        _ = await signingOnce(rig)
        _ = await signingOnce(rig)
        XCTAssertEqual(rig.authoriser.asked.count, 2)
    }

    func testUntilTheLockLastsUntilTheLock() async {
        let rig = await rig()
        rig.door.preferences.settings.ssh.approval = .untilLock
        _ = await signingOnce(rig)
        rig.clock.now.addTimeInterval(24 * 60 * 60)
        let signature = await signingOnce(rig)
        XCTAssertNotNil(signature)
        XCTAssertEqual(rig.authoriser.asked.count, 1)
    }

    func testAShorterChoiceTakesTheLongerOneWithIt() async {
        let rig = await rig()
        _ = await signingOnce(rig)
        rig.door.preferences.settings.ssh.approval = .eachUse
        rig.agent.follow(rig.door.preferences.settings.ssh)
        _ = await signingOnce(rig)
        XCTAssertEqual(rig.authoriser.asked.count, 2)
    }

    func testANoFailsAndIsNotRemembered() async {
        let rig = await rig()
        rig.authoriser.answer = false
        var signature = await signingOnce(rig)
        XCTAssertNil(signature)
        rig.authoriser.answer = true
        signature = await signingOnce(rig)
        XCTAssertNotNil(signature)
        XCTAssertEqual(rig.authoriser.asked.count, 2)
    }

    func testTheCardSaysWhoIsAskingAndDenyIsANo() async throws {
        let rig = await rig()
        rig.authoriser.holds = true
        let asking = Task { await self.signingOnce(rig) }
        await until { rig.stage.showing != nil }
        let question = try XCTUnwrap(rig.stage.showing)
        XCTAssertEqual(question.chain, "ssh › zsh › Terminal")
        XCTAssertTrue(question.statement.contains("Terminal"))
        XCTAssertEqual(question.key?.name, "ed25519")
        question.deny()
        let signature = await asking.value
        XCTAssertNil(signature)
        XCTAssertNil(rig.stage.showing)
    }

    func testNobodyAnsweringIsANoAfterTheWait() async {
        let rig = await rig(patience: 0.05)
        rig.authoriser.holds = true
        let signature = await signingOnce(rig)
        XCTAssertNil(signature)
        XCTAssertEqual(rig.authoriser.withdrawn, 1)
        XCTAssertNil(rig.stage.showing)
    }

    func testAWaitingCallerTakesTheYesOfTheOneBeforeIt() async {
        let rig = await rig()
        rig.authoriser.holds = true
        async let one = signingOnce(rig)
        async let two = signingOnce(rig)
        await until { !rig.authoriser.asked.isEmpty }
        // Long enough for the second to have come to the question.
        try? await Task.sleep(nanoseconds: 50_000_000)
        rig.authoriser.release(true)
        let (first, second) = await (one, two)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(rig.authoriser.asked.count, 1)
    }

    // MARK: session-bind

    private func hostSigns(_ session: Data) -> (key: Data, signature: Data)? {
        guard let half = PrivateHalf(AgentFixture.p256.text), let signature = half.sign(session) else { return nil }
        return (AgentFixture.p256.blob, signature)
    }

    func testABindNamesTheHostOnTheCard() async throws {
        let rig = await rig()
        rig.authoriser.holds = true
        let caller = caller(of: rig)
        let session = Data("session".utf8)
        let host = try XCTUnwrap(hostSigns(session))
        let took = await caller.bind(host: host.key, session: session, signature: host.signature, forwarded: false)
        XCTAssertTrue(took)
        let asking = Task { await caller.sign(Self.data, with: AgentFixture.ed25519.blob) }
        await until { rig.stage.showing != nil }
        XCTAssertEqual(rig.stage.showing?.host, SSHFingerprint(of: host.key))
        XCTAssertEqual(rig.stage.showing?.isForwarded, false)
        rig.authoriser.release(true)
        let signature = await asking.value
        XCTAssertNotNil(signature)
    }

    func testABindOfAHostThatDidNotSignIsRefused() async throws {
        let rig = await rig()
        let caller = caller(of: rig)
        let host = try XCTUnwrap(hostSigns(Data("another session".utf8)))
        let took = await caller.bind(host: host.key, session: Data("session".utf8), signature: host.signature,
                                     forwarded: false)
        XCTAssertFalse(took)
    }

    func testAConnectionBoundToAuthenticateTakesNoSecondBind() async throws {
        let rig = await rig()
        let caller = caller(of: rig)
        let host = try XCTUnwrap(hostSigns(Data("one".utf8)))
        let first = await caller.bind(host: host.key, session: Data("one".utf8), signature: host.signature, forwarded: false)
        let second = await caller.bind(host: host.key, session: Data("one".utf8), signature: host.signature, forwarded: false)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
    }

    func testForwardingIsAskedEveryTime() async throws {
        let rig = await rig()
        let caller = caller(of: rig)
        let session = Data("session".utf8)
        let host = try XCTUnwrap(hostSigns(session))
        let took = await caller.bind(host: host.key, session: session, signature: host.signature, forwarded: true)
        XCTAssertTrue(took)
        for count in 1...3 {
            let signature = await caller.sign(Self.data, with: AgentFixture.ed25519.blob)
            XCTAssertNotNil(signature)
            XCTAssertEqual(rig.authoriser.asked.count, count)
        }
    }

    func testAForwardedCallerIsAskedWhatAnApprovalWouldHaveLetThrough() async throws {
        let rig = await rig()
        _ = await signingOnce(rig)
        let caller = caller(of: rig)
        let session = Data("session".utf8)
        let host = try XCTUnwrap(hostSigns(session))
        _ = await caller.bind(host: host.key, session: session, signature: host.signature, forwarded: true)
        _ = await caller.sign(Self.data, with: AgentFixture.ed25519.blob)
        XCTAssertEqual(rig.authoriser.asked.count, 2)
    }

    func testABindThatSaysForwardedCountsEvenWithNoProof() async {
        let rig = await rig()
        _ = await signingOnce(rig)
        let caller = caller(of: rig)
        let took = await caller.bind(host: Data("nonsense".utf8), session: Data(), signature: Data(), forwarded: true)
        XCTAssertFalse(took)
        _ = await caller.sign(Self.data, with: AgentFixture.ed25519.blob)
        XCTAssertEqual(rig.authoriser.asked.count, 2)
    }

    func testTheFingerThatOpenedTheVaultIsNoAnswerForAForwardedCaller() async throws {
        let rig = await rig(isOpen: false)
        let caller = caller(of: rig)
        _ = await caller.list()
        let session = Data("session".utf8)
        let host = try XCTUnwrap(hostSigns(session))
        _ = await caller.bind(host: host.key, session: session, signature: host.signature, forwarded: true)
        _ = await caller.sign(Self.data, with: AgentFixture.ed25519.blob)
        XCTAssertEqual(rig.authoriser.asked, [.sign])
    }

    // MARK: The lock

    func testTheLockForgetsEveryApprovalAndCutsEveryCaller() async {
        let rig = await rig()
        let caller = caller(of: rig)
        _ = await caller.sign(Self.data, with: AgentFixture.ed25519.blob)
        await rig.store.lock()
        XCTAssertEqual(rig.agent.connected, 0)
        let answer = await caller.ask(Data([11]))
        XCTAssertNil(answer, "the connection was cut")

        // Through a finger and back: nothing of before stands.
        let signature = await signingOnce(rig)
        XCTAssertNotNil(signature)
        _ = await signingOnce(rig, as: Self.other)
        XCTAssertEqual(rig.authoriser.asked.count, 2, "the first one's, and the other app's")
    }

    func testALockUnderAQuestionIsANo() async {
        let rig = await rig()
        rig.authoriser.holds = true
        let caller = caller(of: rig)
        let asking = Task { await caller.ask(Data([11])) }
        _ = await asking.value
        let signing = Task { await caller.sign(Self.data, with: AgentFixture.ed25519.blob) }
        await until { !rig.authoriser.asked.isEmpty }
        await rig.store.lock()
        let signature = await signing.value
        XCTAssertNil(signature)
        XCTAssertEqual(rig.authoriser.withdrawn, 1)
    }

    func testAKeyTrashedSinceTheListSignsNothing() async throws {
        let rig = await rig(items: [AgentFixture.item(1, "one", AgentFixture.ed25519.text)])
        let caller = caller(of: rig)
        _ = await caller.list()
        let entry = try XCTUnwrap(rig.store.entry(id: "00000000-0000-0000-0000-000000000001"))
        _ = try await rig.store.apply(.delete, to: entry.id)
        let signature = await caller.sign(Self.data, with: AgentFixture.ed25519.blob)
        XCTAssertNil(signature)
    }

    // MARK: The password, with no finger

    func testWithNoFingerTheMasterPasswordAnswers() async throws {
        let rig = await rig(hasSeal: false)
        let stage = RememberingQuestion()
        let check = OwnerCheck(store: rig.store, seal: nil, stage: stage)
        let agent = SSHAgent(door: rig.door, authoriser: check, stage: nil)
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        agent.adopt(pair[1], peer: Self.ssh)
        ends.append(pair[0])
        let asking = Task { await AgentCaller(end: pair[0]).sign(Self.data, with: AgentFixture.ed25519.blob) }
        await until { stage.showing != nil }
        let question = try XCTUnwrap(stage.showing)
        XCTAssertEqual(question.act, .sign)
        question.submit(SecretBytes("demo"))
        let signature = await asking.value
        XCTAssertNotNil(signature)
        keeping.append(agent)
    }

    private func until(_ isSo: () -> Bool) async {
        for _ in 0..<400 where !isSo() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: Who

    func testTheChainEndsAtTheOutermostApp() {
        let paths: [pid_t: String] = [
            40: "/usr/bin/ssh", 30: "/bin/zsh", 20: "/opt/homebrew/bin/claude",
            10: "/Applications/OriCode.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper",
            9: "/sbin/launchd-child",
        ]
        let parents: [pid_t: pid_t] = [40: 30, 30: 20, 20: 10, 10: 9]
        let peer = AgentPeer.walk(from: 40, path: { paths[$0] }, parent: { parents[$0] })
        XCTAssertEqual(peer.names, ["ssh", "zsh", "claude", "OriCode"])
        XCTAssertEqual(peer.app, "/Applications/OriCode.app")
    }

    /// `git` from Xcode's folder, run by an agent: its approval and its pass
    /// are the agent's app's, and the folder `git` lies in has no say.
    func testAnAppInTheMiddleOfTheChainIsNotTheOneThatAnswers() {
        let paths: [pid_t: String] = [
            40: "/usr/bin/ssh", 30: "/Applications/Xcode.app/Contents/Developer/usr/libexec/git-core/git",
            20: "/bin/zsh", 10: "/Applications/OriCode.app/Contents/MacOS/OriCode",
        ]
        let parents: [pid_t: pid_t] = [40: 30, 30: 20, 20: 10, 10: 1]
        let peer = AgentPeer.walk(from: 40, path: { paths[$0] }, parent: { parents[$0] })
        XCTAssertEqual(peer.names, ["ssh", "git", "zsh", "OriCode"])
        XCTAssertEqual(peer.app, "/Applications/OriCode.app")
        XCTAssertEqual(peer.appProcess, 10)
    }

    func testWithNoAppTheChainEndsBelowLaunchd() {
        let peer = AgentPeer.walk(from: 7, path: { $0 == 7 ? "/usr/bin/ssh" : "/bin/sh" },
                                  parent: { $0 == 7 ? 6 : 1 })
        XCTAssertEqual(peer.names, ["ssh", "sh"])
        XCTAssertEqual(peer.app, "/bin/sh")
    }

    func testAProcessNobodyCanNameIsSaidSo() {
        let peer = AgentPeer.walk(from: 7, path: { _ in nil }, parent: { _ in nil })
        XCTAssertEqual(peer.names, [])
        XCTAssertEqual(peer.appName, AgentPeer.unknown)
    }
}

/// The card for a test: it remembers what it was asked and puts nothing on
/// the screen.
@MainActor
final class RememberingAgentStage: AgentStage {
    private(set) var showing: AgentQuestion?
    private(set) var shown: [AgentQuestion] = []
    var deniesAtOnce = false
    /// What the panel says of itself. False is a card that could not come
    /// up, and the system's sheet.
    var comesUp = true
    /// What he does on the card as it comes up.
    var onShow: (AgentQuestion) -> Void = { _ in }

    func show(_ question: AgentQuestion) -> Bool {
        showing = question
        shown.append(question)
        onShow(question)
        if deniesAtOnce { question.deny() }
        return comesUp
    }

    func close() { showing = nil }
}
