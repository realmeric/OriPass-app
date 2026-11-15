import CryptoKit
import Foundation
import XCTest
@testable import OriPass

/// A phone's answer, with a real P-256 key standing in for the one in the
/// phone's enclave and each end of the wire a socketpair. What the phone signs
/// is worked out here from the line it was sent, so the code and this file do
/// not lean on each other.
@MainActor
final class PhoneApprovalTests: XCTestCase {
    private static let signer = AppSigner(bundleID: "dev.oricode", team: "ABCDE12345")
    private static let oriCode = AgentPeer(names: ["ssh", "zsh", "OriCode"], app: "/Applications/OriCode.app",
                                           destination: "buzul", signer: signer)
    private static let terminal = AgentPeer(names: ["ssh", "zsh", "Terminal"], app: "/System/Applications/Terminal.app",
                                            signer: AppSigner(bundleID: "com.apple.Terminal", team: AppSigner.apple))
    private static let session = Data("the session the host signed".utf8)
    private static let ed25519 = AgentFixture.ed25519.blob

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    /// OriCode's end of the wire.
    private struct End {
        let end: Int32

        init(end: Int32, waiting seconds: Int = 3) {
            self.end = end
            var wait = timeval(tv_sec: seconds, tv_usec: 0)
            setsockopt(end, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
            var on: Int32 = 1
            setsockopt(end, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        }

        func say(_ object: [String: Any]) {
            var object = object
            object["v"] = 1
            sayBytes(try! JSONSerialization.data(withJSONObject: object) + [10])
        }

        func sayBytes(_ bytes: Data) {
            _ = bytes.withUnsafeBytes { write(end, $0.baseAddress, $0.count) }
        }

        /// The next line, or nil at the end of the wait or of the connection.
        func hear() async -> [String: Any]? {
            let end = self.end
            let line: Data? = await Task.detached {
                var line = Data()
                var byte: UInt8 = 0
                while read(end, &byte, 1) == 1 {
                    if byte == 10 { return line }
                    line.append(byte)
                }
                return nil
            }.value
            return line.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }

        /// Nothing comes, for as long as it would take something to.
        func staysQuiet() async -> Bool {
            var wait = timeval(tv_sec: 0, tv_usec: 300_000)
            setsockopt(end, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
            return await hear() == nil
        }
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

    private let phone = P256.Signing.PrivateKey()
    private var directories: [URL] = []
    private var ends: [Int32] = []
    private var keeping: [SSHAgent] = []

    override func tearDown() async throws {
        keeping.forEach { $0.end() }
        keeping = []
        ends.forEach { close($0) }
        ends = []
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
    }

    private var phoneKey: Data { phone.publicKey.x963Representation }

    private func folder() -> URL {
        // Short: `sun_path` holds 104 bytes.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("op-\(UUID().uuidString.prefix(8))")
        directories.append(directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func rig(hasPhone: Bool = true, phonePath: URL? = nil, identifiers: [String] = [],
                     addWindow: TimeInterval = 5) async -> Rig {
        let directory = folder()
        let enclave = FakeEnclave()
        let seal = PasswordSeal(directory: directory, enclave: enclave)
        let backend = FakeBackend(items: AgentFixture.vault, folders: [], password: "demo")
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        let clock = Clock()
        let passes = AgentPasses(now: { clock.now }, wake: { _, _ in NSObject() })
        let door = Door(store: store, seal: seal, passes: passes, isInFront: { false })
        door.preferences.settings.lock.unlockWithFinger = true
        if hasPhone { door.preferences.settings.ssh.phone = SSHPhone(name: "Telefon", publicKey: phoneKey) }
        let authoriser = FakeAuthoriser()
        authoriser.onWithdraw = { [enclave] in enclave.withdraw() }
        let stage = RememberingAgentStage()
        let agent = SSHAgent(door: door, authoriser: authoriser, stage: stage, phonePath: phonePath,
                             phoneIdentifiers: identifiers, addPhoneWindow: addWindow, now: { clock.now }, patience: 1)
        await door.unlock(with: SecretBytes("demo")).value
        keeping.append(agent)
        return Rig(store: store, door: door, enclave: enclave, authoriser: authoriser, stage: stage, agent: agent, clock: clock)
    }

    private func give(_ rig: Rig, signer: AppSigner = signer, keys: [AgentFixture.Key] = AgentFixture.all.map(\.key)) -> AgentPass {
        rig.door.passes.knownHosts = { [] }
        let held = keys.map { fixture -> AgentPass.Held in
            (rig.agent.passKeys.first { $0.blob == fixture.blob }!, PrivateHalf(fixture.text)!)
        }
        return rig.door.passes.give(held, appName: "OriCode", signer: signer, for: .oneHour)!
    }

    private func wire(_ rig: Rig, hello: Bool = true) async -> End {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        rig.agent.phones.adopt(pair[1])
        ends.append(pair[0])
        let end = End(end: pair[0])
        if hello {
            end.say(["type": "hello"])
            let welcome = await end.hear()
            XCTAssertEqual(welcome?["type"] as? String, "welcome")
        }
        return end
    }

    private func caller(_ rig: Rig, peer: AgentPeer = oriCode) -> AgentCaller {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        rig.agent.adopt(pair[1], peer: peer)
        ends.append(pair[0])
        return AgentCaller(end: pair[0])
    }

    private struct Host {
        let key = Curve25519.Signing.PrivateKey()

        var blob: Data {
            var blob = Data()
            blob.appendCounted(Data("ssh-ed25519".utf8))
            blob.appendCounted(key.publicKey.rawRepresentation)
            return blob
        }
    }

    private func bind(_ caller: AgentCaller, _ host: Host, forwarded: Bool = false) async {
        var signature = Data()
        signature.appendCounted(Data("ssh-ed25519".utf8))
        signature.appendCounted(try! host.key.signature(for: Self.session))
        let took = await caller.bind(host: host.blob, session: Self.session, signature: signature, forwarded: forwarded)
        XCTAssertTrue(took)
    }

    private func login(key: Data = ed25519) -> Data {
        var data = Data()
        data.appendCounted(Self.session)
        data.append(50)
        data.appendCounted(Data("him".utf8))
        data.appendCounted(Data("ssh-connection".utf8))
        data.appendCounted(Data("publickey".utf8))
        data.append(1)
        data.appendCounted(Data("ssh-ed25519".utf8))
        data.appendCounted(key)
        return data
    }

    /// `field(x)` from the card, written again.
    private static func field(_ bytes: Data) -> Data {
        var count = UInt32(bytes.count).bigEndian
        return withUnsafeBytes(of: &count) { Data($0) } + bytes
    }

    private static func field(_ words: String) -> Data { field(Data(words.utf8)) }

    /// `message` from the card, from a line as the phone received it.
    private static func message(_ line: [String: Any], altering: String? = nil, id: String? = nil, nonce: Data? = nil) -> Data {
        var hashed = Data()
        for name in ["act", "words", "app", "appID", "key", "keyFingerprint", "host", "hostKey", "expires"] {
            hashed += field(name == altering ? "altered" : line[name] as? String ?? "")
        }
        let raw = nonce ?? Data(base64Encoded: line["nonce"] as? String ?? "") ?? Data()
        return Data("oripass.approve.v1".utf8) + [0] + field(id ?? line["id"] as? String ?? "") + field(raw)
            + Data(SHA256.hash(data: hashed))
    }

    private func approve(_ line: [String: Any], _ signed: Data, on end: End, by key: P256.Signing.PrivateKey? = nil) throws {
        let signature = try (key ?? phone).signature(for: signed)
        end.say(["type": "approve", "id": line["id"] as? String ?? "", "signature": signature.derRepresentation.base64EncodedString()])
    }

    private func next(_ end: End) async throws -> [String: Any] {
        let line = await end.hear()
        return try XCTUnwrap(line)
    }

    private func until(_ isSo: () -> Bool) async {
        for _ in 0..<600 where !isSo() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func closed(_ line: [String: Any]?, _ outcome: String, reason: String? = nil, file: StaticString = #filePath, l: UInt = #line) {
        XCTAssertEqual(line?["type"] as? String, "closed", file: file, line: l)
        XCTAssertEqual(line?["outcome"] as? String, outcome, file: file, line: l)
        XCTAssertEqual(line?["reason"] as? String, reason, file: file, line: l)
    }

    // MARK: The bytes

    /// The request on OP-88's card and the bytes it says are signed.
    func testTheMessageIsTheCardsTo() {
        let request = PhoneRequest(id: "6f1d2c3a-0b7e-4f10-9a55-3e1c7a2b9d04", nonce: Data(0..<32), act: .stranger,
                                   words: "OriCode wants to use an SSH key\nKey: Sunucu anahtarı\nGoing to: buzul\nHost key: SHA256:DemoDemoDemoDemoDemoDemoDemoDemoDemoDemoDem\nAsked by: ssh › zsh › claude › OriCode",
                                   app: "OriCode", appID: "com.realmeric.oricode", key: "Sunucu anahtarı",
                                   keyFingerprint: "SHA256:KeyDemoKeyDemoKeyDemoKeyDemoKeyDemoKeyDemoK", host: "buzul",
                                   hostKey: "SHA256:DemoDemoDemoDemoDemoDemoDemoDemoDemoDemoDem", expires: "2026-11-02T21:03:00Z")
        func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex(request.wordsHash), "e50a7383763f73c21489aa4985b93bc6abacc8bd28e6f3f5240b04eb92c920c8")
        XCTAssertEqual(request.message.count, 127)
        XCTAssertEqual(hex(request.message), "6f7269706173732e617070726f76652e7631000000002436663164326333612d30623765"
            + "2d346631302d396135352d3365316337613262396430340000002000010203040506"
            + "0708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1fe50a7383763f73c21489"
            + "aa4985b93bc6abacc8bd28e6f3f5240b04eb92c920c8")
    }

    func testATimeIsWrittenAsTheCardWritesIt() {
        XCTAssertEqual(PhoneWire.time(Date(timeIntervalSince1970: 1_793_653_380)), "2026-11-02T21:03:00Z")
    }

    func testAFingerprintIsEightBytesInFours() {
        let fingerprint = PhoneWire.fingerprint(of: phoneKey)
        let hash = SHA256.hash(data: phoneKey).prefix(8).map { String(format: "%02X", $0) }.joined()
        XCTAssertEqual(fingerprint.replacingOccurrences(of: "-", with: ""), hash)
        XCTAssertEqual(fingerprint.split(separator: "-").map(\.count), [4, 4, 4, 4])
    }

    // MARK: A yes

    func testAYesSignsOneRequestFromThePassAndTheVaultStaysShut() async throws {
        let rig = await rig()
        let pass = give(rig)
        await rig.store.lock()
        rig.enclave.holds = true
        let end = await wire(rig)
        let host = Host()
        let caller = caller(rig)
        await bind(caller, host)
        let data = login()
        async let signed = caller.sign(data, with: Self.ed25519)

        let line = try await next(end)
        XCTAssertEqual(line["type"] as? String, "request")
        XCTAssertEqual(line["act"] as? String, "stranger")
        XCTAssertEqual(line["app"] as? String, "OriCode")
        XCTAssertEqual(line["appID"] as? String, "dev.oricode")
        XCTAssertEqual(line["key"] as? String, "ed25519")
        XCTAssertEqual(line["host"] as? String, "buzul")
        XCTAssertEqual(line["hostKey"] as? String, SSHFingerprint(of: host.blob))
        XCTAssertEqual(Data(base64Encoded: line["nonce"] as? String ?? "")?.count, 32)
        let words = try XCTUnwrap(line["words"] as? String)
        XCTAssertTrue(words.hasPrefix("OriCode wants to connect to buzul\nKey: ed25519\n"), words)
        XCTAssertEqual(rig.stage.showing?.words, words, "what the phone shows is what the card says")
        XCTAssertEqual(rig.stage.showing?.key?.name, "ed25519", "the pass has the name, with the vault shut")
        XCTAssertEqual(rig.stage.showing?.patience, 2, "twice the plain card's")

        try approve(line, Self.message(line), on: end)
        closed(await end.hear(), "approved")
        let signature = await signed
        XCTAssertTrue(SSHVerifies(try XCTUnwrap(signature), over: data, by: Self.ed25519))
        XCTAssertEqual(rig.store.state, .locked, "a phone opens nothing")
        XCTAssertTrue(rig.authoriser.asked.isEmpty)
        XCTAssertEqual(pass.phoned, 1)
        XCTAssertEqual(pass.logins, 0)
    }

    func testWithTheVaultOpenTheFingerIsWaitedForAndThePhoneAnswersFirst() async throws {
        let rig = await rig()
        let pass = give(rig)
        rig.authoriser.holds = true
        let end = await wire(rig)
        async let signed = caller(rig).sign(Data("anything at all".utf8), with: Self.ed25519)
        let line = try await next(end)
        XCTAssertEqual(line["act"] as? String, "signature")
        XCTAssertEqual(line["host"] as? String, "buzul", "what the process says, as on the card")
        await until { !rig.authoriser.asked.isEmpty }
        try approve(line, Self.message(line), on: end)
        closed(await end.hear(), "approved")
        let signature = await signed
        XCTAssertNotNil(signature)
        XCTAssertEqual(pass.phoned, 1)
        XCTAssertEqual(rig.authoriser.withdrawn, 1, "the finger stopped being asked for")
    }

    /// Nothing here is the lid's: he is away, and the phone is all there is.
    func testWithNoFingerThePhoneStillAnswersOverAShutVaultAndThereIsNoPassword() async throws {
        let rig = await rig()
        give(rig)
        await rig.store.lock()
        rig.enclave.hasFinger = false
        let end = await wire(rig)
        async let signed = caller(rig).sign(Data("anything at all".utf8), with: Self.ed25519)
        let line = try await next(end)
        let question = try XCTUnwrap(rig.stage.showing)
        XCTAssertFalse(question.hasFinger)
        XCTAssertFalse(question.offersPassword)
        XCTAssertFalse(question.offersPass)
        XCTAssertFalse(question.offersSpan)
        XCTAssertFalse(question.sentence.contains("touch"), question.sentence)
        try approve(line, Self.message(line), on: end)
        let signature = await signed
        XCTAssertNotNil(signature)
    }

    func testAYesTeachesNothing() async throws {
        let rig = await rig()
        let pass = give(rig)
        await rig.store.lock()
        rig.enclave.holds = true
        let end = await wire(rig)
        let host = Host()
        let first = caller(rig)
        await bind(first, host)
        async let signed = first.sign(login(), with: Self.ed25519)
        let line = try await next(end)
        rig.stage.showing?.keepsAllowing = true
        try approve(line, Self.message(line), on: end)
        closed(await end.hear(), "approved")
        _ = await signed
        XCTAssertEqual(rig.door.passes.standing.count, 1)
        XCTAssertTrue(rig.door.passes.standing.first === pass, "the row on the card gave nothing")

        let second = caller(rig)
        await bind(second, host)
        async let again = second.sign(login(), with: Self.ed25519)
        let next = try await next(end)
        XCTAssertEqual(next["type"] as? String, "request", "the same stranger, asked again")
        XCTAssertNotEqual(next["id"] as? String, line["id"] as? String)
        XCTAssertNotEqual(next["nonce"] as? String, line["nonce"] as? String)
        end.say(["type": "deny", "id": next["id"] as? String ?? ""])
        let refused = await again
        XCTAssertNil(refused)
    }

    func testAForwardedCallerOverAShutVaultCanBeGivenTheList() async throws {
        let rig = await rig()
        let pass = give(rig, keys: [AgentFixture.ed25519, AgentFixture.p256])
        await rig.store.lock()
        rig.enclave.holds = true
        let end = await wire(rig)
        let caller = caller(rig)
        await bind(caller, Host(), forwarded: true)
        async let listed = caller.list()
        let line = try await next(end)
        XCTAssertEqual(line["act"] as? String, "list")
        XCTAssertEqual(line["key"] as? String, "")
        XCTAssertEqual(line["keyFingerprint"] as? String, "")
        try approve(line, Self.message(line), on: end)
        closed(await end.hear(), "approved")
        let list = await listed
        XCTAssertEqual(list, pass.keys.map(\.blob))
        XCTAssertEqual(pass.signatures, 0, "a list is no signature")

        async let signed = caller.sign(login(), with: Self.ed25519)
        let next = try await next(end)
        XCTAssertEqual(next["act"] as? String, "forwarded")
        try approve(next, Self.message(next), on: end)
        let signature = await signed
        XCTAssertNotNil(signature)
        XCTAssertEqual(pass.phoned, 1)
    }

    // MARK: A yes that does not hold

    private enum Spoiled {
        case word(String), key, nonce, id, late, passEnded, noSignature
    }

    private func refuses(_ spoiled: Spoiled, reason: String, file: StaticString = #filePath, line l: UInt = #line) async throws {
        let rig = await rig()
        let pass = give(rig)
        rig.authoriser.answer = false
        rig.authoriser.holds = true
        let end = await wire(rig)
        async let signed = caller(rig).sign(Data("anything at all".utf8), with: Self.ed25519)
        let line = try await next(end)
        await until { !rig.authoriser.asked.isEmpty }
        switch spoiled {
        case .word(let name): try approve(line, Self.message(line, altering: name), on: end)
        case .key: try approve(line, Self.message(line), on: end, by: P256.Signing.PrivateKey())
        case .nonce: try approve(line, Self.message(line, nonce: Data(repeating: 9, count: 32)), on: end)
        case .id: try approve(line, Self.message(line, id: UUID().uuidString.lowercased()), on: end)
        case .late:
            rig.clock.now.addTimeInterval(2)
            try approve(line, Self.message(line), on: end)
        case .passEnded:
            // Another stands, so the wire does.
            give(rig, signer: AppSigner(bundleID: "dev.other", team: "ABCDE12345"))
            rig.door.passes.end(pass)
            try approve(line, Self.message(line), on: end)
        case .noSignature:
            end.say(["type": "approve", "id": line["id"] as? String ?? ""])
        }
        closed(await end.hear(), "refused", reason: reason, file: file, l: l)
        XCTAssertNotNil(rig.stage.showing, "the card stays up for the finger", file: file, line: l)
        XCTAssertEqual(pass.phoned, 0, file: file, line: l)
        rig.stage.showing?.deny()
        rig.authoriser.release(false)
        let signature = await signed
        XCTAssertNil(signature, file: file, line: l)
    }

    func testAnAlteredWordInAnyFieldIsRefused() async throws {
        for name in ["act", "words", "app", "appID", "key", "keyFingerprint", "host", "hostKey", "expires"] {
            try await refuses(.word(name), reason: "bad-signature")
        }
    }

    func testAnotherKeyAnotherNonceAndAnotherIdAreRefused() async throws {
        try await refuses(.key, reason: "bad-signature")
        try await refuses(.nonce, reason: "bad-signature")
        try await refuses(.id, reason: "bad-signature")
        try await refuses(.noSignature, reason: "bad-signature")
    }

    func testPastItsExpiryIsRefused() async throws {
        try await refuses(.late, reason: "expired")
    }

    func testAPassThatEndedFirstIsRefused() async throws {
        try await refuses(.passEnded, reason: "no-pass")
    }

    func testASecondApproveIsAReplayAndSignsNothingMore() async throws {
        let rig = await rig()
        let pass = give(rig)
        await rig.store.lock()
        rig.enclave.holds = true
        let end = await wire(rig)
        let signed = caller(rig)
        async let first = signed.sign(Data("anything at all".utf8), with: Self.ed25519)
        let line = try await next(end)
        try approve(line, Self.message(line), on: end)
        closed(await end.hear(), "approved")
        _ = await first
        try approve(line, Self.message(line), on: end)
        closed(await end.hear(), "refused", reason: "replay")
        XCTAssertEqual(pass.phoned, 1)
    }

    func testAWrongSignatureSpendsTheRequestAndTheRightOneThenComesTooLate() async throws {
        let rig = await rig()
        let pass = give(rig)
        rig.authoriser.holds = true
        let end = await wire(rig)
        async let signed = caller(rig).sign(Data("anything at all".utf8), with: Self.ed25519)
        let line = try await next(end)
        await until { !rig.authoriser.asked.isEmpty }
        try approve(line, Self.message(line), on: end, by: P256.Signing.PrivateKey())
        closed(await end.hear(), "refused", reason: "bad-signature")
        try approve(line, Self.message(line), on: end)
        closed(await end.hear(), "refused", reason: "replay")
        XCTAssertEqual(pass.phoned, 0)
        rig.authoriser.release(true)
        let answered = await signed
        XCTAssertNotNil(answered, "his finger still could")
    }

    // MARK: Nothing goes out

    func testNoRequestForAnyoneElse() async throws {
        let rig = await rig()
        give(rig, keys: [AgentFixture.ed25519])
        rig.authoriser.answer = false
        let end = await wire(rig)
        // Another app, one with no signature, a key the pass does not hold.
        _ = await caller(rig, peer: Self.terminal).sign(Data("anything at all".utf8), with: Self.ed25519)
        _ = await caller(rig, peer: AgentPeer(names: ["ssh"], app: "/bin/sh")).sign(Data("anything at all".utf8), with: Self.ed25519)
        _ = await caller(rig).sign(Data("anything at all".utf8), with: AgentFixture.p256.blob)
        XCTAssertEqual(rig.authoriser.asked.count, 3, "each went to the card")
        let quiet = await end.staysQuiet()
        XCTAssertTrue(quiet)
    }

    func testNoRequestForWhatAPassSignsByItself() async throws {
        let rig = await rig()
        give(rig)
        await rig.store.lock()
        rig.enclave.holds = true
        let end = await wire(rig)
        var commit = Data("SSHSIG".utf8)
        commit.appendCounted(Data("git".utf8))
        commit.appendCounted(Data())
        commit.appendCounted(Data("sha512".utf8))
        commit.appendCounted(Data(repeating: 7, count: 64))
        let signed = await caller(rig).sign(commit, with: Self.ed25519)
        XCTAssertNotNil(signed)
        let quiet = await end.staysQuiet()
        XCTAssertTrue(quiet)
        XCTAssertTrue(rig.stage.shown.isEmpty)
    }

    func testNoRequestForAShutVaultsOwnOpening() async throws {
        let rig = await rig()
        await rig.store.lock()
        rig.enclave.cancels = true
        let end = await wire(rig)
        let listed = await caller(rig).list()
        XCTAssertNil(listed)
        let quiet = await end.staysQuiet()
        XCTAssertTrue(quiet)
        XCTAssertNil(rig.stage.shown.last?.phoneRequest)
        XCTAssertEqual(rig.stage.shown.last?.patience, 1, "sixty seconds and not 120")
    }

    func testNoRequestWithNoPhoneRegistered() async throws {
        let rig = await rig(hasPhone: false)
        give(rig)
        rig.authoriser.answer = false
        let end = await wire(rig)
        let signed = await caller(rig).sign(Data("anything at all".utf8), with: Self.ed25519)
        XCTAssertNil(signed)
        let quiet = await end.staysQuiet()
        XCTAssertTrue(quiet)
    }

    // MARK: How one ends

    func testThePhonesDenyIsANoAndTheMacsCardGoes() async throws {
        let rig = await rig()
        let pass = give(rig)
        rig.authoriser.holds = true
        let end = await wire(rig)
        async let signed = caller(rig).sign(Data("anything at all".utf8), with: Self.ed25519)
        let line = try await next(end)
        await until { !rig.authoriser.asked.isEmpty }
        end.say(["type": "deny", "id": line["id"] as? String ?? ""])
        closed(await end.hear(), "denied")
        let signature = await signed
        XCTAssertNil(signature)
        XCTAssertNil(rig.stage.showing)
        XCTAssertEqual(pass.signatures, 0)
    }

    func testAFingerAtTheMacEndsThePhonesWayIn() async throws {
        let rig = await rig()
        rig.authoriser.holds = true
        let pass = give(rig)
        let end = await wire(rig)
        async let signed = caller(rig).sign(Data("anything at all".utf8), with: Self.ed25519)
        let line = try await next(end)
        await until { !rig.authoriser.asked.isEmpty }
        rig.authoriser.release(true)
        closed(await end.hear(), "answered-at-mac")
        let signature = await signed
        XCTAssertNotNil(signature)
        try approve(line, Self.message(line), on: end)
        closed(await end.hear(), "refused", reason: "replay")
        XCTAssertEqual(pass.phoned, 0)
    }

    func testDenyAtTheMacIsDenied() async throws {
        let rig = await rig()
        rig.authoriser.holds = true
        give(rig)
        let end = await wire(rig)
        async let signed = caller(rig).sign(Data("anything at all".utf8), with: Self.ed25519)
        _ = await end.hear()
        await until { !rig.authoriser.asked.isEmpty }
        rig.stage.showing?.deny()
        closed(await end.hear(), "denied")
        _ = await signed
    }

    func testTheClockIsExpired() async throws {
        let rig = await rig()
        rig.authoriser.holds = true
        give(rig)
        let end = await wire(rig)
        async let signed = caller(rig).sign(Data("anything at all".utf8), with: Self.ed25519)
        _ = await end.hear()
        closed(await end.hear(), "expired")
        _ = await signed
    }

    func testALockIsWithdrawn() async throws {
        let rig = await rig()
        rig.authoriser.holds = true
        give(rig)
        let end = await wire(rig)
        async let signed = caller(rig).sign(Data("anything at all".utf8), with: Self.ed25519)
        _ = await end.hear()
        await until { !rig.authoriser.asked.isEmpty }
        await rig.store.lock()
        closed(await end.hear(), "withdrawn")
        _ = await signed
    }

    func testARequestIsSentAgainDownANewConnection() async throws {
        let rig = await rig()
        rig.authoriser.holds = true
        give(rig)
        let first = await wire(rig)
        async let signed = caller(rig).sign(Data("anything at all".utf8), with: Self.ed25519)
        let line = try await next(first)
        await until { !rig.authoriser.asked.isEmpty }
        let second = await wire(rig)
        let again = try await next(second)
        XCTAssertEqual(again["id"] as? String, line["id"] as? String)
        XCTAssertEqual(again["nonce"] as? String, line["nonce"] as? String)
        try approve(again, Self.message(again), on: second)
        closed(await second.hear(), "approved")
        let signature = await signed
        XCTAssertNotNil(signature)
    }

    // MARK: The wire

    func testNothingCountsBeforeHelloAndBadLinesAreSaidSo() async throws {
        let rig = await rig()
        give(rig)
        let end = await wire(rig, hello: false)
        end.say(["type": "deny", "id": "x"])
        var line = await end.hear()
        XCTAssertEqual(line?["code"] as? String, "no-hello")
        XCTAssertEqual(line?["id"] as? String, "x")
        end.sayBytes(Data("not json\n".utf8))
        line = await end.hear()
        XCTAssertEqual(line?["code"] as? String, "bad-line")
        end.say(["type": "hello", "ignored": true])
        line = await end.hear()
        XCTAssertEqual(line?["type"] as? String, "welcome")
        XCTAssertEqual((line?["phone"] as? [String: String])?["name"], "Telefon")
        XCTAssertEqual((line?["phone"] as? [String: String])?["fingerprint"], PhoneWire.fingerprint(of: phoneKey))
        end.say(["type": "dance"])
        line = await end.hear()
        XCTAssertEqual(line?["code"] as? String, "unknown-type")
        end.sayBytes(Data(#"{"v":2,"type":"hello"}"#.utf8) + [10])
        line = await end.hear()
        XCTAssertEqual(line?["code"] as? String, "unknown-type")
        end.say(["type": "approve", "id": "nobody", "signature": ""])
        line = await end.hear()
        XCTAssertEqual(line?["code"] as? String, "unknown-id")
        end.say(["type": "deny", "id": "nobody"])
        line = await end.hear()
        XCTAssertEqual(line?["code"] as? String, "unknown-id")
    }

    func testALineOverTheCapClosesTheConnection() async throws {
        let rig = await rig()
        give(rig)
        let end = await wire(rig)
        end.sayBytes(Data(repeating: 65, count: PhoneWire.most + 1))
        let said = await end.hear()
        XCTAssertNil(said)
    }

    func testAWelcomeWithNoPhoneSaysNull() async throws {
        let rig = await rig(hasPhone: false)
        let end = await wire(rig, hello: false)
        end.say(["type": "hello"])
        let line = await end.hear()
        XCTAssertTrue(line?["phone"] is NSNull)
    }

    // MARK: The socket

    private func connect(to path: URL) -> Int32? {
        let end = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let written = Array(path.path.utf8CString).map { UInt8(bitPattern: $0) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: written) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(end, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            close(end)
            return nil
        }
        ends.append(end)
        return end
    }

    private var approveCount: Int { Instruments.live.filter { $0.owner == "SSHAgent" && $0.name == "approve" }.count }

    func testNoFileWithoutAPassAndAPhoneAndTheLastPassTakesIt() async throws {
        let path = folder().appendingPathComponent("approve.sock")
        let rig = await rig(hasPhone: false, phonePath: path, identifiers: [AppInfo.bundleID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        let pass = give(rig)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path), "a pass and no phone")
        XCTAssertEqual(approveCount, 0)
        rig.door.preferences.settings.ssh.phone = SSHPhone(name: "Telefon", publicKey: phoneKey)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(approveCount, 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)

        let end = End(end: try XCTUnwrap(connect(to: path)))
        end.say(["type": "hello"])
        let welcome = await end.hear()
        XCTAssertEqual(welcome?["type"] as? String, "welcome", "its own signature is what the test's door takes")

        rig.door.passes.end(pass)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(approveCount, 0)
        let cut = await end.hear()
        XCTAssertNil(cut, "the connection went with it")
    }

    func testALockLeavesItWithThePass() async throws {
        let path = folder().appendingPathComponent("approve.sock")
        let rig = await rig(phonePath: path, identifiers: [AppInfo.bundleID])
        give(rig)
        await rig.store.lock()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        rig.door.passes.endAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testAPeerThatIsNotOriCodeIsClosedOnBeforeAByte() async throws {
        let path = folder().appendingPathComponent("approve.sock")
        let rig = await rig(phonePath: path, identifiers: PeerCheck.oriCode)
        give(rig)
        let end = End(end: try XCTUnwrap(connect(to: path)))
        end.say(["type": "hello"])
        let said = await end.hear()
        XCTAssertNil(said)
    }

    func testOriCodeIsWhoTheCardNamesAndMoltenOnlyInADebugBuild() {
        XCTAssertTrue(PeerCheck.oriCode.contains("com.realmeric.oricode"))
        XCTAssertEqual(PeerCheck.oriCode.contains("com.realmeric.oricode.molten"), PeerCheck.takesDebuggable)
    }

    func testARunningProcessThatCouldBeAttachedToIsNobodyInARelease() async throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        ends += pair
        XCTAssertTrue(PeerCheck().signs(pair[0], as: AppInfo.bundleID))
        XCTAssertFalse(PeerCheck(takesDebuggable: false).signs(pair[0], as: AppInfo.bundleID))
        XCTAssertFalse(PeerCheck(team: "ABCDE12345").signs(pair[0], as: AppInfo.bundleID))
        XCTAssertFalse(PeerCheck().signs(pair[0], as: "com.realmeric.oricode"))
    }

    // MARK: Adding a phone

    private func registration(name: String = "Telefon", key: P256.Signing.PrivateKey? = nil, signedBy: P256.Signing.PrivateKey? = nil) throws -> [String: Any] {
        let key = key ?? phone
        let publicKey = key.publicKey.x963Representation
        let signed = Data("oripass.register.v1".utf8) + [0] + Self.field(name) + Self.field(publicKey)
        return ["type": "register", "name": name, "publicKey": publicKey.base64EncodedString(),
                "proof": try (signedBy ?? key).signature(for: signed).derRepresentation.base64EncodedString()]
    }

    func testAPhoneIsAddedWithAFingerOnACardThatNamesIt() async throws {
        let path = folder().appendingPathComponent("approve.sock")
        let rig = await rig(hasPhone: false, phonePath: path, identifiers: [AppInfo.bundleID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        let phones = rig.agent.phones
        let added = Task { await phones.waitForPhone() }
        await until { FileManager.default.fileExists(atPath: path.path) }
        let end = End(end: try XCTUnwrap(connect(to: path)))
        end.say(["type": "hello"])
        _ = await end.hear()
        rig.authoriser.holds = true
        end.say(try registration())
        await until { rig.stage.showing != nil }
        let question = try XCTUnwrap(rig.stage.showing)
        let fingerprint = PhoneWire.fingerprint(of: phoneKey)
        XCTAssertEqual(question.adding?.fingerprint, fingerprint)
        XCTAssertEqual(question.statement, "OriCode wants to add Telefon")
        XCTAssertFalse(question.offersPass)
        XCTAssertFalse(question.offersSpan)
        await until { !rig.authoriser.asked.isEmpty }
        XCTAssertEqual(rig.authoriser.asked, [.phone])
        rig.authoriser.release(true)
        let line = await end.hear()
        XCTAssertEqual(line?["type"] as? String, "registered")
        XCTAssertEqual(line?["fingerprint"] as? String, fingerprint)
        let found = await added.value
        XCTAssertTrue(found)
        XCTAssertEqual(rig.door.preferences.settings.ssh.phone, SSHPhone(name: "Telefon", publicKey: phoneKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path), "no pass stands, so the door shuts")
    }

    private func refusesRegistration(_ line: [String: Any], reason: String, denied: Bool = false,
                                     file: StaticString = #filePath, l: UInt = #line) async throws {
        let rig = await rig(hasPhone: false, addWindow: 5)
        let phones = rig.agent.phones
        let added = reason == "not-waiting" ? nil : Task { await phones.waitForPhone() }
        rig.authoriser.answer = !denied
        await Task.yield()
        let end = await wire(rig)
        end.say(line)
        let said = await end.hear()
        XCTAssertEqual(said?["type"] as? String, "refused", file: file, line: l)
        XCTAssertEqual(said?["reason"] as? String, reason, file: file, line: l)
        XCTAssertNil(rig.door.preferences.settings.ssh.phone, file: file, line: l)
        phones.stopWaiting()
        _ = await added?.value
    }

    func testARegistrationThatDoesNotHoldIsRefused() async throws {
        try await refusesRegistration(try registration(), reason: "not-waiting")
        try await refusesRegistration(try registration(signedBy: P256.Signing.PrivateKey()), reason: "bad-proof")
        var altered = try registration()
        altered["name"] = "Another"
        try await refusesRegistration(altered, reason: "bad-proof")
        try await refusesRegistration(try registration(name: String(repeating: "x", count: 65)), reason: "bad-proof")
        try await refusesRegistration(try registration(), reason: "denied", denied: true)
    }

    func testAFormerPhoneIsReplacedAndItsSignatureGoesWithIt() async throws {
        let rig = await rig()
        let pass = give(rig)
        let phones = rig.agent.phones
        let end = await wire(rig)
        let another = P256.Signing.PrivateKey()
        let added = Task { await phones.waitForPhone() }
        await Task.yield()
        end.say(try registration(name: "Yeni", key: another))
        let said = await end.hear()
        XCTAssertEqual(said?["type"] as? String, "registered")
        _ = await added.value
        XCTAssertEqual(rig.door.preferences.settings.ssh.phone?.name, "Yeni")

        rig.authoriser.answer = false
        rig.authoriser.holds = true
        async let signed = caller(rig).sign(Data("anything at all".utf8), with: Self.ed25519)
        let line = try await next(end)
        await until { !rig.authoriser.asked.isEmpty }
        try approve(line, Self.message(line), on: end)
        closed(await end.hear(), "refused", reason: "bad-signature")
        rig.authoriser.release(false)
        _ = await signed
        XCTAssertEqual(pass.phoned, 0)
    }

    func testTheWaitEndsByItself() async throws {
        let rig = await rig(hasPhone: false, addWindow: 0.05)
        let found = await rig.agent.phones.waitForPhone()
        XCTAssertFalse(found)
    }

    func testTheRoomAddsWaitsAndForgets() async throws {
        let rig = await rig()
        var stopped = false
        var finish: CheckedContinuation<Bool, Never>?
        let rooms = Rooms(door: rig.door, hands: .init(waitForPhone: {
            await withCheckedContinuation { finish = $0 }
        }, stopWaitingForPhone: {
            stopped = true
            finish?.resume(returning: false)
        }))
        let waiting = rooms.addPhone()
        await until { rooms.isWaitingForPhone && finish != nil }
        rooms.cancelPhone()
        await waiting.value
        XCTAssertTrue(stopped)
        XCTAssertFalse(rooms.isWaitingForPhone)
        rooms.forgetPhone()
        XCTAssertNil(rig.door.preferences.settings.ssh.phone)
    }

    func testSignOutTakesThePhone() async throws {
        let rig = await rig()
        await rig.door.signOut()
        XCTAssertNil(rig.door.preferences.settings.ssh.phone)
    }

    func testLockAndForgetLeavesThePhone() async throws {
        let rig = await rig()
        await rig.door.lockAndForget()
        XCTAssertNotNil(rig.door.preferences.settings.ssh.phone)
    }

    // MARK: What he can see

    func testAnAnswerByPhoneIsToldApart() async throws {
        let rig = await rig()
        let pass = give(rig)
        await rig.store.lock()
        rig.enclave.holds = true
        let end = await wire(rig)
        async let signed = caller(rig).sign(Data("anything at all".utf8), with: Self.ed25519)
        let line = try await next(end)
        try approve(line, Self.message(line), on: end)
        _ = await signed
        XCTAssertTrue(pass.summary.hasPrefix("5 keys · 1 by phone, the last at "), pass.summary)
        await rig.door.unlock(with: SecretBytes("demo")).value
        XCTAssertEqual(rig.door.passReport, "OriCode's pass signed 1 request by phone.")
    }

    func testTheCardSaysThePhoneWasAsked() async throws {
        let rig = await rig()
        rig.authoriser.holds = true
        give(rig)
        let end = await wire(rig)
        async let signed = caller(rig).sign(Data("anything at all".utf8), with: Self.ed25519)
        let line = try await next(end)
        XCTAssertEqual(rig.stage.showing?.phoneRequest, line["id"] as? String)
        await until { !rig.authoriser.asked.isEmpty }
        rig.stage.showing?.deny()
        _ = await signed
    }
}
