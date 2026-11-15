import CryptoKit
import Foundation
import XCTest
@testable import OriPass

/// A pass, over a socketpair and a driven clock: what it matches, what it
/// holds and every way it ends. The bytes are read back after each end, from
/// a reference to the allocation the pass held and not through the pass.
@MainActor
final class AgentPassTests: XCTestCase {
    private static let signer = AppSigner(bundleID: "dev.oricode", team: "ABCDE12345")
    private static let oriCode = AgentPeer(names: ["ssh", "zsh", "OriCode"], app: "/Applications/OriCode.app",
                                           destination: "alpen", signer: signer)
    private static let terminalSigner = AppSigner(bundleID: "com.apple.Terminal", team: AppSigner.apple)
    private static let terminal = AgentPeer(names: ["ssh-keygen", "git", "zsh", "Terminal"],
                                            app: "/System/Applications/Utilities/Terminal.app", signer: terminalSigner)
    private static let session = Data("the session the host signed".utf8)

    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    /// The one-shot the pass book would have set, for a test to fire.
    private final class Alarm {
        var at: Date?
        var fire: (@MainActor () -> Void)?
    }

    private struct Rig {
        let store: VaultStore
        let door: Door
        let enclave: FakeEnclave
        let authoriser: FakeAuthoriser
        let stage: RememberingAgentStage
        let agent: SSHAgent
        let clock: Clock
        let alarm: Alarm
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

    private func rig(isOpen: Bool = true) async -> Rig {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oripass-pass-\(UUID().uuidString)")
        directories.append(directory)
        let enclave = FakeEnclave()
        let seal = PasswordSeal(directory: directory, enclave: enclave)
        let backend = FakeBackend(items: AgentFixture.vault, folders: [], password: "demo")
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        let clock = Clock()
        let alarm = Alarm()
        let passes = AgentPasses(now: { clock.now }, wake: { at, fire in
            alarm.at = at
            alarm.fire = fire
            return alarm
        })
        let door = Door(store: store, seal: seal, passes: passes, isInFront: { false })
        door.preferences.settings.lock.unlockWithFinger = true
        let authoriser = FakeAuthoriser()
        let stage = RememberingAgentStage()
        let agent = SSHAgent(door: door, authoriser: authoriser, stage: stage, now: { clock.now }, patience: 0.2)
        await door.unlock(with: SecretBytes("demo")).value
        if !isOpen { await store.lock() }
        keeping.append(agent)
        return Rig(store: store, door: door, enclave: enclave, authoriser: authoriser, stage: stage, agent: agent,
                   clock: clock, alarm: alarm)
    }

    private func caller(of agent: SSHAgent, peer: AgentPeer = oriCode) -> AgentCaller {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        agent.adopt(pair[1], peer: peer)
        ends.append(pair[0])
        return AgentCaller(end: pair[0])
    }

    private func key(_ rig: Rig, _ blob: Data = AgentFixture.ed25519.blob) -> AgentKey {
        rig.agent.passKeys.first { $0.blob == blob }!
    }

    /// Given by the book directly, with the card's finger left out. `hosts`
    /// is what `known_hosts` says as it is given.
    @discardableResult
    private func give(_ rig: Rig, knowing hosts: [Data] = [], signer: AppSigner = signer, span: PassSpan = .oneHour,
                      keys: [AgentFixture.Key] = AgentFixture.all.map(\.key)) -> AgentPass {
        rig.door.passes.knownHosts = { Set(hosts) }
        let held = keys.map { fixture -> AgentPass.Held in (key(rig, fixture.blob), PrivateHalf(fixture.text)!) }
        return rig.door.passes.give(held, appName: signer == Self.signer ? "OriCode" : "Terminal", signer: signer, for: span)!
    }

    private struct Host {
        let key = Curve25519.Signing.PrivateKey()

        var blob: Data {
            var blob = Data()
            blob.appendCounted(Data("ssh-ed25519".utf8))
            blob.appendCounted(key.publicKey.rawRepresentation)
            return blob
        }

        func signature(over session: Data) -> Data {
            var written = Data()
            written.appendCounted(Data("ssh-ed25519".utf8))
            written.appendCounted(try! key.signature(for: session))
            return written
        }
    }

    private func bind(_ caller: AgentCaller, _ host: Host, session: Data = session, forwarded: Bool = false) async -> Bool {
        await caller.bind(host: host.blob, session: session, signature: host.signature(over: session),
                          forwarded: forwarded)
    }

    /// What `ssh` asks a key to sign when it logs in.
    private func login(session: Data = session, key: Data = AgentFixture.ed25519.blob, hostKey: Data? = nil) -> Data {
        var data = Data()
        data.appendCounted(session)
        data.append(50)
        data.appendCounted(Data("him".utf8))
        data.appendCounted(Data("ssh-connection".utf8))
        data.appendCounted(Data((hostKey == nil ? "publickey" : "publickey-hostbound-v00@openssh.com").utf8))
        data.append(1)
        data.appendCounted(Data("ssh-ed25519".utf8))
        data.appendCounted(key)
        if let hostKey { data.appendCounted(hostKey) }
        return data
    }

    /// What `ssh-keygen -Y sign` asks a key to sign.
    private static func sshsig(magic: String = "SSHSIG", namespace: String = "git", reserved: Data = Data(),
                               hash: String = "sha512", digest: Data = Data(repeating: 7, count: 64)) -> Data {
        var data = Data(magic.utf8)
        data.appendCounted(Data(namespace.utf8))
        data.appendCounted(reserved)
        data.appendCounted(Data(hash.utf8))
        data.appendCounted(digest)
        return data
    }

    private func assertAsked(_ rig: Rig, _ answer: Data?, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(answer, why, file: file, line: line)
        XCTAssertFalse(rig.authoriser.asked.isEmpty && rig.enclave.asked.isEmpty && rig.stage.shown.isEmpty,
                       "\(why): somebody should have been asked", file: file, line: line)
    }

    // MARK: A login

    func testALoginToAKnownHostSignsWithNoFingerOverAShutVault() async throws {
        let rig = await rig()
        let host = Host()
        let pass = give(rig, knowing: [host.blob])
        await rig.store.lock()
        let caller = caller(of: rig.agent)
        let bound = await bind(caller, host)
        XCTAssertTrue(bound)
        let data = login()
        let signature = await caller.sign(data, with: AgentFixture.ed25519.blob)
        XCTAssertTrue(SSHVerifies(try XCTUnwrap(signature), over: data, by: AgentFixture.ed25519.blob))
        XCTAssertEqual(rig.store.state, .locked, "nothing opened the vault")
        XCTAssertTrue(rig.authoriser.asked.isEmpty)
        XCTAssertTrue(rig.enclave.asked.isEmpty)
        XCTAssertTrue(rig.stage.shown.isEmpty)
        XCTAssertEqual(pass.logins, 1)
        XCTAssertEqual(pass.commits, 0)
    }

    func testALoginSignsWithTheVaultOpenToo() async throws {
        let rig = await rig()
        let host = Host()
        give(rig, knowing: [host.blob])
        let caller = caller(of: rig.agent)
        _ = await bind(caller, host)
        let signed = await caller.sign(login(), with: AgentFixture.ed25519.blob)
        XCTAssertNotNil(signed)
        XCTAssertTrue(rig.authoriser.asked.isEmpty)
    }

    func testEveryKeyItHoldsSigns() async throws {
        let rig = await rig()
        let host = Host()
        let pass = give(rig, knowing: [host.blob])
        await rig.store.lock()
        for (name, fixture) in AgentFixture.all {
            let caller = caller(of: rig.agent)
            _ = await bind(caller, host)
            let data = login(key: fixture.blob)
            // SHA-2 for RSA, which the other kinds do not read.
            let signature = await caller.sign(data, with: fixture.blob, flags: 2)
            XCTAssertTrue(SSHVerifies(try XCTUnwrap(signature, name), over: data, by: fixture.blob), name)
        }
        XCTAssertEqual(pass.logins, AgentFixture.all.count)
    }

    func testALoginNeedsABoundSessionAndAHostBoundLoginMustNameTheBoundHost() async throws {
        let rig = await rig()
        let host = Host()
        give(rig, knowing: [host.blob])
        await rig.store.lock()
        rig.enclave.cancels = true
        let unbound = caller(of: rig.agent)
        let refused = await unbound.sign(login(), with: AgentFixture.ed25519.blob)
        assertAsked(rig, refused, "no session-bind")

        let caller = caller(of: rig.agent)
        _ = await bind(caller, host)
        let another = await caller.sign(login(hostKey: Host().blob), with: AgentFixture.ed25519.blob)
        XCTAssertNil(another, "the login names a host that was not bound")
        let right = await caller.sign(login(hostKey: host.blob), with: AgentFixture.ed25519.blob)
        XCTAssertNotNil(right)
    }

    func testEachOtherCallerIsAsked() async throws {
        let rig = await rig()
        let host = Host()
        give(rig, knowing: [host.blob])
        await rig.store.lock()
        rig.enclave.cancels = true

        let sameName = AgentPeer(names: ["ssh", "OriCode"], app: "/Applications/OriCode.app", destination: "alpen",
                                 signer: AppSigner(bundleID: "dev.oricode.fake", team: "ABCDE12345"))
        let otherTeam = AgentPeer(names: ["ssh", "OriCode"], app: "/Applications/OriCode.app", destination: "alpen",
                                  signer: AppSigner(bundleID: "dev.oricode", team: "ZZZZZ99999"))
        let unsigned = AgentPeer(names: ["ssh", "OriCode"], app: "/Applications/OriCode.app", destination: "alpen")
        for (peer, why) in [(sameName, "same name, another app"), (otherTeam, "another team"), (unsigned, "no signature"),
                            (Self.terminal, "Terminal")] {
            let caller = caller(of: rig.agent, peer: peer)
            _ = await bind(caller, host)
            let listed = await caller.list()
            XCTAssertNil(listed, "\(why): the finger is the only way to a list")
            let signed = await caller.sign(login(), with: AgentFixture.ed25519.blob)
            XCTAssertNil(signed, why)
            let commit = await caller.sign(Self.sshsig(), with: AgentFixture.ed25519.blob)
            XCTAssertNil(commit, why)
        }
        XCTAssertFalse(rig.enclave.asked.isEmpty, "each of them went to the finger")
    }

    func testAKeyItDoesNotHoldAndAForwardedConnectionAreAsked() async throws {
        let rig = await rig()
        let host = Host()
        give(rig, knowing: [host.blob], keys: [AgentFixture.ed25519])

        // With the vault open, so each of these reaches the question.
        rig.authoriser.answer = false
        let otherKey = caller(of: rig.agent)
        _ = await bind(otherKey, host)
        let p256 = AgentFixture.p256.blob
        let notHeld = await otherKey.sign(login(key: p256), with: p256)
        assertAsked(rig, notHeld, "a key made after the pass")
        XCTAssertEqual(rig.authoriser.asked.count, 1)

        let forwarded = caller(of: rig.agent)
        _ = await bind(forwarded, host, forwarded: true)
        let through = await forwarded.sign(login(), with: AgentFixture.ed25519.blob)
        XCTAssertNil(through, "forwarded")
        XCTAssertEqual(rig.authoriser.asked.count, 2)

        // First for this host and then forwarded: forwarded stays.
        let both = caller(of: rig.agent)
        _ = await bind(both, host)
        _ = await bind(both, host, forwarded: true)
        let after = await both.sign(login(), with: AgentFixture.ed25519.blob)
        XCTAssertNil(after, "forwarded after the login")
        XCTAssertEqual(rig.authoriser.asked.count, 3)
    }

    /// A caller under the app that saw a real host's bind, and wants a
    /// signature good on some other session.
    func testABindReplayedDoesNotSignForAnotherSession() async throws {
        let rig = await rig()
        let host = Host()
        give(rig, knowing: [host.blob])
        rig.authoriser.answer = false
        let caller = caller(of: rig.agent)
        _ = await bind(caller, host)
        let elsewhere = await caller.sign(login(session: Data("the session of a host nobody allowed".utf8)),
                                          with: AgentFixture.ed25519.blob)
        assertAsked(rig, elsewhere, "the data holds another session")
        let notALogin = await caller.sign(Data("anything at all".utf8), with: AgentFixture.ed25519.blob)
        XCTAssertNil(notALogin, "the data is no login")
        XCTAssertEqual(rig.authoriser.asked.count, 2)
    }

    func testABindThatDoesNotVerifyIsNoBind() async throws {
        let rig = await rig()
        let host = Host()
        give(rig, knowing: [host.blob])
        rig.authoriser.answer = false
        let caller = caller(of: rig.agent)
        let forged = await caller.bind(host: host.blob, session: Self.session,
                                       signature: Host().signature(over: Self.session), forwarded: false)
        XCTAssertFalse(forged)
        let signed = await caller.sign(login(), with: AgentFixture.ed25519.blob)
        assertAsked(rig, signed, "a host key that did not sign")
    }

    // MARK: A host never seen

    func testAHostNeverSeenIsAskedAndAFingerMakesItKnownForThePasssLife() async throws {
        let rig = await rig()
        let stranger = Host()
        let pass = give(rig, knowing: [Host().blob])
        let first = caller(of: rig.agent)
        _ = await bind(first, stranger)
        let signed = await first.sign(login(), with: AgentFixture.ed25519.blob)
        XCTAssertNotNil(signed, "he answered")
        XCTAssertEqual(rig.authoriser.asked, [.sign])
        XCTAssertEqual(pass.logins, 0, "a finger signed it, and the pass did not")

        await rig.store.lock()
        let second = caller(of: rig.agent)
        _ = await bind(second, stranger)
        let again = await second.sign(login(), with: AgentFixture.ed25519.blob)
        XCTAssertNotNil(again)
        XCTAssertEqual(rig.authoriser.asked, [.sign], "nobody was asked the second time")
        XCTAssertEqual(rig.store.state, .locked)
        XCTAssertEqual(pass.logins, 1)
    }

    func testAHostRefusedStaysAStranger() async throws {
        let rig = await rig()
        let stranger = Host()
        give(rig)
        rig.authoriser.answer = false
        let first = caller(of: rig.agent)
        _ = await bind(first, stranger)
        let refused = await first.sign(login(), with: AgentFixture.ed25519.blob)
        assertAsked(rig, refused, "a stranger")

        await rig.store.lock()
        rig.enclave.cancels = true
        let second = caller(of: rig.agent)
        _ = await bind(second, stranger)
        let again = await second.sign(login(), with: AgentFixture.ed25519.blob)
        XCTAssertNil(again)
    }

    /// `ssh -o StrictHostKeyChecking=accept-new` writes the file before it
    /// asks to sign, and so can anything else of his: the file counts as it
    /// stood when the pass was given.
    func testAHostWrittenToTheFileAfterThePassIsStillAStranger() async throws {
        let rig = await rig()
        let stranger = Host()
        give(rig)
        rig.door.passes.knownHosts = { [stranger.blob] }
        rig.authoriser.answer = false
        let caller = caller(of: rig.agent)
        _ = await bind(caller, stranger)
        let signed = await caller.sign(login(), with: AgentFixture.ed25519.blob)
        assertAsked(rig, signed, "written after the pass")
    }

    /// A yes to something that is no login says nothing of the host the
    /// connection happens to have bound.
    func testAYesToAnythingButALoginMakesNoHostKnown() async throws {
        let rig = await rig()
        let stranger = Host()
        give(rig)
        let first = caller(of: rig.agent)
        _ = await bind(first, stranger)
        let signed = await first.sign(Data("anything at all".utf8), with: AgentFixture.ed25519.blob)
        XCTAssertNotNil(signed)

        await rig.store.lock()
        rig.enclave.cancels = true
        let second = caller(of: rig.agent)
        _ = await bind(second, stranger)
        let again = await second.sign(login(), with: AgentFixture.ed25519.blob)
        XCTAssertNil(again)
    }

    /// Ten minutes for the key is nobody having looked at this host.
    func testAYesAlreadyStandingMakesNoHostKnown() async throws {
        let rig = await rig()
        give(rig)
        let first = caller(of: rig.agent)
        _ = await bind(first, Host())
        _ = await first.sign(login(), with: AgentFixture.ed25519.blob)
        XCTAssertEqual(rig.authoriser.asked, [.sign])

        let stranger = Host()
        let second = caller(of: rig.agent)
        _ = await bind(second, stranger)
        let signed = await second.sign(login(), with: AgentFixture.ed25519.blob)
        XCTAssertNotNil(signed)
        XCTAssertEqual(rig.authoriser.asked, [.sign], "the approval answered")

        await rig.store.lock()
        rig.enclave.cancels = true
        let third = caller(of: rig.agent)
        _ = await bind(third, stranger)
        let again = await third.sign(login(), with: AgentFixture.ed25519.blob)
        XCTAssertNil(again)
    }

    func testAForwardedYesMakesNoHostKnown() async throws {
        let rig = await rig()
        let host = Host()
        give(rig)
        let forwarded = caller(of: rig.agent)
        _ = await bind(forwarded, host, forwarded: true)
        let signed = await forwarded.sign(login(), with: AgentFixture.ed25519.blob)
        XCTAssertNotNil(signed)

        await rig.store.lock()
        rig.enclave.cancels = true
        let plain = caller(of: rig.agent)
        _ = await bind(plain, host)
        let again = await plain.sign(login(), with: AgentFixture.ed25519.blob)
        XCTAssertNil(again)
    }

    func testKnownHostsReadsTheKeyOfEveryLineWhateverItsName() throws {
        let plain = Host(), hashed = Host(), listed = Host(), tabbed = Host(), authority = Host(), revoked = Host()
        func b64(_ host: Host) -> String { host.blob.base64EncodedString() }
        let keys = KnownHosts.keys(in: """
        # a comment \(b64(Host()))
        alpen ssh-ed25519 \(b64(plain))
        |1|F1E1KeoE/eEWhi10WpGv4OdiO6Y=|3988QV0VE8wmZL7suNrYQLITLCg= ssh-ed25519 \(b64(hashed)) a comment
        alpen,[buzul]:2222,10.0.0.1 ssh-ed25519 \(b64(listed))
        tabbed\tssh-ed25519\t\(b64(tabbed))

        @cert-authority *.example.com ssh-ed25519 \(b64(authority))
        @revoked * ssh-ed25519 \(b64(revoked))
        again ssh-ed25519 \(b64(revoked))
        half a
        bad ssh-ed25519 !!!
        """)
        XCTAssertEqual(keys, [plain.blob, hashed.blob, listed.blob, tabbed.blob])
    }

    func testNoFileIsNoHostKnown() {
        XCTAssertEqual(KnownHosts.read(URL(fileURLWithPath: "/nonexistent/known_hosts")), [])
    }

    // MARK: A commit

    /// `git commit` signs through `ssh-keygen -Y sign`, which binds nothing.
    func testACommitSignsWithNoBindAndNobodyAskedOverAShutVault() async throws {
        let rig = await rig()
        let pass = give(rig)
        await rig.store.lock()
        let caller = caller(of: rig.agent)
        let data = Self.sshsig()
        let signature = await caller.sign(data, with: AgentFixture.ed25519.blob)
        XCTAssertTrue(SSHVerifies(try XCTUnwrap(signature), over: data, by: AgentFixture.ed25519.blob))
        XCTAssertEqual(rig.store.state, .locked)
        XCTAssertTrue(rig.authoriser.asked.isEmpty)
        XCTAssertTrue(rig.enclave.asked.isEmpty)
        XCTAssertTrue(rig.stage.shown.isEmpty)
        XCTAssertEqual(pass.commits, 1)
        XCTAssertEqual(pass.logins, 0)
    }

    func testACommitIsSignedUnderSha256Too() async throws {
        let rig = await rig()
        give(rig)
        let signed = await caller(of: rig.agent).sign(Self.sshsig(hash: "sha256", digest: Data(repeating: 1, count: 32)),
                                                      with: AgentFixture.ed25519.blob)
        XCTAssertNotNil(signed)
        XCTAssertTrue(rig.authoriser.asked.isEmpty)
    }

    func testAnotherNamespaceIsAsked() async throws {
        let rig = await rig()
        give(rig)
        rig.authoriser.answer = false
        for (index, namespace) in ["file", "email@example.com", "GIT", "git ", "gitsomething"].enumerated() {
            let signed = await caller(of: rig.agent).sign(Self.sshsig(namespace: namespace), with: AgentFixture.ed25519.blob)
            XCTAssertNil(signed, namespace)
            XCTAssertEqual(rig.authoriser.asked.count, index + 1, namespace)
        }
    }

    func testAForwardedCommitIsAsked() async throws {
        let rig = await rig()
        give(rig)
        rig.authoriser.answer = false
        let caller = caller(of: rig.agent)
        _ = await bind(caller, Host(), forwarded: true)
        let signed = await caller.sign(Self.sshsig(), with: AgentFixture.ed25519.blob)
        assertAsked(rig, signed, "forwarded")
    }

    /// Each of these says `git` to anyone who only looks for the word.
    func testMalformedDataIsAsked() async throws {
        let rig = await rig()
        give(rig)
        rig.authoriser.answer = false
        var trailing = Self.sshsig()
        trailing.append(0)
        var truncated = Self.sshsig()
        truncated.removeLast()
        var prefixed = Data([0])
        prefixed.append(Self.sshsig())
        var counted = Data()
        counted.appendCounted(Self.sshsig())
        let malformed: [(String, Data)] = [
            ("empty", Data()),
            ("the magic alone", Data("SSHSIG".utf8)),
            ("another magic", Self.sshsig(magic: "SSHSIH")),
            ("the magic in small letters", Self.sshsig(magic: "sshsig")),
            ("a byte in front", prefixed),
            ("the magic counted", counted),
            ("a byte behind", trailing),
            ("a byte short", truncated),
            ("a reserved string", Self.sshsig(reserved: Data("x".utf8))),
            ("no namespace", Self.sshsig(namespace: "")),
            ("a null in the namespace", Self.sshsig(namespace: "git\0")),
            ("a hash nobody names", Self.sshsig(hash: "sha1", digest: Data(repeating: 7, count: 20))),
            ("sha512 of the wrong size", Self.sshsig(digest: Data(repeating: 7, count: 32))),
            ("sha256 of the wrong size", Self.sshsig(hash: "sha256")),
            ("no hash", Self.sshsig(digest: Data())),
        ]
        for (index, (why, data)) in malformed.enumerated() {
            XCTAssertNil(SSHSigData(data)?.isGit == true ? data : nil, why)
            let signed = await caller(of: rig.agent).sign(data, with: AgentFixture.ed25519.blob)
            XCTAssertNil(signed, why)
            XCTAssertEqual(rig.authoriser.asked.count, index + 1, why)
        }
    }

    func testTheShapeReadsItsNamespace() {
        XCTAssertEqual(SSHSigData(Self.sshsig())?.namespace, "git")
        XCTAssertEqual(SSHSigData(Self.sshsig())?.isGit, true)
        XCTAssertEqual(SSHSigData(Self.sshsig(namespace: "file"))?.namespace, "file")
        XCTAssertEqual(SSHSigData(Self.sshsig(namespace: "file"))?.isGit, false)
        // A slice of a larger buffer, as a parsed request's data may be.
        let slice = (Data([1, 2, 3]) + Self.sshsig()).dropFirst(3)
        XCTAssertEqual(SSHSigData(slice)?.namespace, "git")
    }

    // MARK: The listing

    func testOverAShutVaultItsAppListsEveryKeyItHoldsAndRaisesNoFinger() async throws {
        let rig = await rig()
        give(rig, keys: [AgentFixture.ed25519, AgentFixture.p384])
        await rig.store.lock()
        let listed = await caller(of: rig.agent).list()
        XCTAssertEqual(listed, [AgentFixture.ed25519.blob, AgentFixture.p384.blob])
        XCTAssertEqual(rig.store.state, .locked)
        XCTAssertTrue(rig.enclave.asked.isEmpty)
        XCTAssertTrue(rig.stage.shown.isEmpty)
    }

    /// `ssh` has to reach its signature for the card to ask about the host.
    func testOverAShutVaultAConnectionBoundToAStrangerStillLists() async throws {
        let rig = await rig()
        give(rig, keys: [AgentFixture.ed25519])
        await rig.store.lock()
        let caller = caller(of: rig.agent)
        _ = await bind(caller, Host())
        let listed = await caller.list()
        XCTAssertEqual(listed, [AgentFixture.ed25519.blob])
        XCTAssertTrue(rig.enclave.asked.isEmpty)
    }

    func testOverAShutVaultAForwardedConnectionListsNothing() async throws {
        let rig = await rig()
        give(rig)
        await rig.store.lock()
        rig.enclave.cancels = true
        let caller = caller(of: rig.agent)
        _ = await bind(caller, Host(), forwarded: true)
        let listed = await caller.list()
        XCTAssertNil(listed)
    }

    func testWithTheVaultOpenItsAppListsWhatAnyCallerLists() async throws {
        let rig = await rig()
        give(rig, keys: [AgentFixture.ed25519])
        let listed = await caller(of: rig.agent).list()
        XCTAssertEqual(listed?.count, AgentFixture.all.count)
    }

    // MARK: Its ends

    private func assertZeros(_ held: [SecretBytes], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(held.count, AgentFixture.all.count, "every key it held", file: file, line: line)
        for bytes in held {
            XCTAssertGreaterThan(bytes.count, 0, file: file, line: line)
            bytes.withBytes { bytes in
                XCTAssertTrue(bytes.allSatisfy { $0 == 0 }, "bytes left in memory", file: file, line: line)
            }
        }
    }

    func testWhatItHoldsIsEveryKeyUntilItEnds() async throws {
        let rig = await rig()
        let pass = give(rig)
        XCTAssertEqual(pass.keys.map(\.blob), AgentFixture.all.map(\.key.blob))
        XCTAssertEqual(pass.heldBytes.count, AgentFixture.all.count)
        XCTAssertFalse(pass.heldBytes.contains(where: \.isWiped))
        XCTAssertEqual(rig.door.passes.standing.count, 1)
    }

    func testItsTimeEndsItThroughTheTimerAndTheBytesAreZeros() async throws {
        let rig = await rig()
        let pass = give(rig, span: .fourHours)
        let held = pass.heldBytes
        XCTAssertEqual(rig.alarm.at, rig.clock.now.addingTimeInterval(4 * 60 * 60))
        rig.clock.now.addTimeInterval(4 * 60 * 60)
        rig.alarm.fire?()
        XCTAssertTrue(rig.door.passes.standing.isEmpty)
        assertZeros(held)
    }

    /// The Mac slept through it, or the timer is late: the clock is read at
    /// the match as well.
    func testAPassPastItsTimeDoesNotSignThoughTheTimerHasNotFired() async throws {
        let rig = await rig()
        let held = give(rig).heldBytes
        await rig.store.lock()
        rig.enclave.cancels = true
        rig.clock.now.addTimeInterval(60 * 60)
        let signed = await caller(of: rig.agent).sign(Self.sshsig(), with: AgentFixture.ed25519.blob)
        XCTAssertNil(signed)
        XCTAssertTrue(rig.door.passes.standing.isEmpty)
        assertZeros(held)
    }

    func testATimerThatFiresBeforeItsTimeLeavesThePassAndIsSetAgain() async throws {
        let rig = await rig()
        let pass = give(rig)
        rig.alarm.at = nil
        rig.alarm.fire?()
        XCTAssertEqual(rig.door.passes.standing.count, 1)
        XCTAssertEqual(rig.alarm.at, pass.ends)
    }

    func testTheTimerIsAtTheSoonestEndAndGoesWithTheLast() async throws {
        let rig = await rig()
        let long = give(rig, span: .oneDay)
        let short = give(rig, signer: Self.terminalSigner, span: .oneHour)
        XCTAssertEqual(rig.alarm.at, short.ends)
        XCTAssertEqual(Instruments.live.filter { $0.owner == "SSHAgent" && $0.name == "pass" }.count, 1)
        rig.door.passes.end(short)
        XCTAssertEqual(rig.alarm.at, long.ends)
        rig.door.passes.end(long)
        XCTAssertFalse(Instruments.live.contains { $0.owner == "SSHAgent" && $0.name == "pass" })
    }

    func testRevokeWipes() async throws {
        let rig = await rig()
        let pass = give(rig)
        let held = pass.heldBytes
        Rooms(door: rig.door).revoke(pass)
        XCTAssertTrue(rig.door.passes.standing.isEmpty)
        assertZeros(held)
    }

    func testRevokeAllInTheMarksMenuWipes() async throws {
        let rig = await rig()
        let first = give(rig).heldBytes
        let second = give(rig, signer: Self.terminalSigner).heldBytes
        rig.door.passes.endAll()
        XCTAssertTrue(rig.door.passes.standing.isEmpty)
        assertZeros(first)
        assertZeros(second)
    }

    func testALockLeavesItAndLockAndForgetDoesNot() async throws {
        let rig = await rig()
        let held = give(rig).heldBytes
        await rig.store.lock()
        XCTAssertEqual(rig.door.passes.standing.count, 1, "an ordinary lock leaves it")
        XCTAssertFalse(held.contains(where: \.isWiped))
        await rig.door.lockAndForget()
        XCTAssertTrue(rig.door.passes.standing.isEmpty)
        assertZeros(held)
    }

    func testTurningTouchIDOffIsLockAndForget() async throws {
        let rig = await rig()
        let held = give(rig).heldBytes
        await rig.door.setFinger(false)
        XCTAssertTrue(rig.door.passes.standing.isEmpty)
        assertZeros(held)
    }

    func testSignOutWipes() async throws {
        let rig = await rig()
        let held = give(rig).heldBytes
        await rig.door.signOut()
        XCTAssertTrue(rig.door.passes.standing.isEmpty)
        assertZeros(held)
    }

    func testTheEngineSayingNobodyIsSignedInWipes() async throws {
        let rig = await rig()
        let held = give(rig).heldBytes
        await rig.store.signOut()
        XCTAssertTrue(rig.door.passes.standing.isEmpty)
        assertZeros(held)
    }

    func testAQuitWipes() async throws {
        let rig = await rig()
        let held = give(rig).heldBytes
        rig.agent.end()
        XCTAssertTrue(rig.door.passes.standing.isEmpty)
        assertZeros(held)
    }

    func testTheSwitchOffWipesAndAnotherChoiceOfApprovalDoesNot() async throws {
        let rig = await rig()
        let held = give(rig).heldBytes
        var choices = SSHChoices()
        choices.isOn = true
        choices.approval = .untilLock
        rig.agent.follow(choices)
        XCTAssertEqual(rig.door.passes.standing.count, 1)
        choices.isOn = false
        rig.agent.follow(choices)
        XCTAssertTrue(rig.door.passes.standing.isEmpty)
        assertZeros(held)
    }

    func testAnotherSetOfFingersEndsItAtTheNextRequest() async throws {
        let rig = await rig()
        let held = give(rig).heldBytes
        rig.enclave.cancels = true
        // Before the lock screen would see it: past that the seal is gone.
        await rig.store.lock()
        rig.enclave.enrolAnotherFinger()
        let signed = await caller(of: rig.agent).sign(Self.sshsig(), with: AgentFixture.ed25519.blob)
        XCTAssertNil(signed)
        XCTAssertTrue(rig.door.passes.standing.isEmpty)
        assertZeros(held)
    }

    func testAnotherSetOfFingersEndsItAtTheLockScreen() async throws {
        let rig = await rig()
        let held = give(rig).heldBytes
        rig.enclave.enrolAnotherFinger()
        await rig.store.lock()
        XCTAssertTrue(rig.door.passes.standing.isEmpty, "the lock screen came up")
        assertZeros(held)
    }

    /// `Enclave.fingerprints` is nil with the lid shut, and a shut lid is
    /// what a Mac left at work may well have.
    func testAShutLidIsNotAnotherFinger() async throws {
        let rig = await rig()
        let host = Host()
        give(rig, knowing: [host.blob])
        await rig.store.lock()
        rig.enclave.hasFinger = false
        let caller = caller(of: rig.agent)
        _ = await bind(caller, host)
        let signed = await caller.sign(login(), with: AgentFixture.ed25519.blob)
        XCTAssertNotNil(signed)
    }

    func testWithNoMarkOfTheFingersNoPassIsGivenAndEveryKeyIsWiped() async throws {
        let rig = await rig()
        rig.enclave.hasFinger = false
        let held = AgentFixture.all.map { fixture -> AgentPass.Held in (key(rig, fixture.key.blob), PrivateHalf(fixture.key.text)!) }
        let pass = rig.door.passes.give(held, appName: "OriCode", signer: Self.signer, for: .oneHour)
        XCTAssertNil(pass)
        assertZeros(held.map(\.half.heldBytes))
    }

    func testASecondPassForTheSameAppReplacesTheFirstAndWipesIt() async throws {
        let rig = await rig()
        let first = give(rig).heldBytes
        give(rig)
        XCTAssertEqual(rig.door.passes.standing.count, 1)
        assertZeros(first)
    }

    func testAPassForAnotherAppLeavesThisOne() async throws {
        let rig = await rig()
        let held = give(rig).heldBytes
        give(rig, signer: Self.terminalSigner)
        XCTAssertEqual(rig.door.passes.standing.count, 2)
        XCTAssertFalse(held.contains(where: \.isWiped))
    }

    func testAPassThatHasEndedSignsNothing() async throws {
        let rig = await rig()
        let pass = give(rig)
        rig.door.passes.end(pass)
        XCTAssertNil(pass.sign(login(), with: AgentFixture.ed25519.blob, flags: 0))
    }

    /// RSA's two check numbers and its SHA-1 are the key's to refuse, as
    /// without a pass.
    func testThroughAPassAnRSAKeyStillSignsNoSHA1() async throws {
        let rig = await rig()
        let host = Host()
        give(rig, knowing: [host.blob])
        await rig.store.lock()
        let caller = caller(of: rig.agent)
        _ = await bind(caller, host)
        let data = login(key: AgentFixture.rsa.blob)
        let sha1 = await caller.sign(data, with: AgentFixture.rsa.blob)
        XCTAssertNil(sha1)
        let sha2 = await caller.sign(data, with: AgentFixture.rsa.blob, flags: 2)
        XCTAssertTrue(SSHVerifies(try XCTUnwrap(sha2), over: data, by: AgentFixture.rsa.blob))
    }

    func testItSaysNothingOfWhatItHolds() async throws {
        let rig = await rig()
        let pass = give(rig)
        XCTAssertEqual("\(pass)", "AgentPass")
        XCTAssertEqual(String(reflecting: pass), "AgentPass")
        XCTAssertTrue(Mirror(reflecting: pass).children.isEmpty)
    }

    // MARK: Being given one

    private func question(_ rig: Rig, peer: AgentPeer = oriCode) async throws -> AgentCaller {
        let caller = caller(of: rig.agent, peer: peer)
        _ = await bind(caller, Host())
        return caller
    }

    private func until(_ isSo: () -> Bool) async {
        for _ in 0..<400 where !isSo() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// The card's stage holds the answer back until the test has opened the
    /// row, as he would before he touched the sensor.
    func testTheRowOnTheCardGivesThatAppAPassForEveryKeyAndKnowsThisHost() async throws {
        let rig = await rig()
        rig.authoriser.holds = true
        let caller = caller(of: rig.agent)
        let host = Host()
        _ = await bind(caller, host)
        async let signed = caller.sign(login(), with: AgentFixture.ed25519.blob)
        await until { !rig.authoriser.asked.isEmpty }
        let question = try XCTUnwrap(rig.stage.shown.last)
        XCTAssertTrue(question.offersPass)
        question.keepsAllowing = true
        question.keptFor = .eightHours
        rig.authoriser.release(true)
        let signature = await signed
        XCTAssertNotNil(signature)

        let pass = try XCTUnwrap(rig.door.passes.standing.first)
        XCTAssertEqual(pass.keys.map(\.blob), AgentFixture.all.map(\.key.blob))
        XCTAssertEqual(pass.signer, Self.signer)
        XCTAssertEqual(pass.appName, "OriCode")
        XCTAssertEqual(pass.ends, rig.clock.now.addingTimeInterval(8 * 60 * 60))
        XCTAssertEqual(rig.authoriser.asked, [.sign], "one finger")

        await rig.store.lock()
        let next = self.caller(of: rig.agent)
        _ = await bind(next, host)
        let again = await next.sign(login(), with: AgentFixture.ed25519.blob)
        XCTAssertNotNil(again, "the host on the card is known to the pass it gave")
        XCTAssertEqual(pass.logins, 1)
    }

    /// A commit's card has no host to name, and the finger that gives the
    /// pass answers that same request.
    func testACommitsCardGivesAPassAndAnswersThatRequest() async throws {
        let rig = await rig()
        rig.authoriser.holds = true
        let caller = caller(of: rig.agent)
        let data = Self.sshsig()
        async let signed = caller.sign(data, with: AgentFixture.ed25519.blob)
        await until { !rig.authoriser.asked.isEmpty }
        let question = try XCTUnwrap(rig.stage.shown.last)
        XCTAssertNil(question.host)
        XCTAssertTrue(question.offersPass)
        question.keepsAllowing = true
        rig.authoriser.release(true)
        let signature = await signed
        XCTAssertTrue(SSHVerifies(try XCTUnwrap(signature), over: data, by: AgentFixture.ed25519.blob))
        XCTAssertEqual(rig.door.passes.standing.count, 1)

        await rig.store.lock()
        let next = await self.caller(of: rig.agent).sign(Self.sshsig(), with: AgentFixture.ed25519.blob)
        XCTAssertNotNil(next, "the next commit is the pass's")
        XCTAssertEqual(rig.door.passes.standing.first?.commits, 1)
        XCTAssertEqual(rig.authoriser.asked, [.sign])
    }

    /// The finger opens the vault, the pass is read out of it, and the
    /// signature that was waiting goes through.
    func testAShutVaultsCardGivesAPassToo() async throws {
        let rig = await rig()
        await rig.store.lock()
        rig.stage.onShow = {
            XCTAssertNil($0.key)
            XCTAssertTrue($0.offersPass)
            $0.keepsAllowing = true
            $0.keptFor = .fourHours
        }
        let data = Self.sshsig()
        let signature = await caller(of: rig.agent).sign(data, with: AgentFixture.ed25519.blob)
        XCTAssertTrue(SSHVerifies(try XCTUnwrap(signature), over: data, by: AgentFixture.ed25519.blob))
        XCTAssertEqual(rig.store.state, .unlocked)
        let pass = try XCTUnwrap(rig.door.passes.standing.first)
        XCTAssertEqual(pass.keys.count, AgentFixture.all.count)
        XCTAssertEqual(pass.ends, rig.clock.now.addingTimeInterval(4 * 60 * 60))
    }

    func testARowLeftShutGivesNone() async throws {
        let rig = await rig()
        let caller = try await question(rig)
        let signed = await caller.sign(login(), with: AgentFixture.ed25519.blob)
        XCTAssertNotNil(signed)
        XCTAssertTrue(rig.door.passes.standing.isEmpty)
    }

    func testADeniedCardGivesNone() async throws {
        let rig = await rig()
        rig.authoriser.holds = true
        let caller = try await question(rig)
        async let signed = caller.sign(login(), with: AgentFixture.ed25519.blob)
        await until { !rig.authoriser.asked.isEmpty }
        let question = try XCTUnwrap(rig.stage.shown.last)
        question.keepsAllowing = true
        question.deny()
        rig.authoriser.release(false)
        let answer = await signed
        XCTAssertNil(answer)
        XCTAssertTrue(rig.door.passes.standing.isEmpty)
    }

    func testThePasswordInPlaceOfAFingerGivesNone() async throws {
        let rig = await rig()
        rig.authoriser.hasFinger = false
        let caller = try await question(rig)
        async let signed = caller.sign(login(), with: AgentFixture.ed25519.blob)
        await until { !rig.stage.shown.isEmpty }
        let question = try XCTUnwrap(rig.stage.shown.last)
        XCTAssertFalse(question.offersPass)
        question.keepsAllowing = true
        question.usePassword()
        _ = await signed
        XCTAssertTrue(rig.door.passes.standing.isEmpty)
    }

    func testTheRowIsOfferedOnAnyCardFromASignedAppWithAFinger() {
        func question(key: AgentQuestion.Key? = .init(name: "k", fingerprint: "f"), host: String? = "SHA256:h",
                      forwarded: Bool = false, finger: Bool = true, peer: AgentPeer = AgentPassTests.oriCode) -> AgentQuestion {
            AgentQuestion(peer: peer, key: key, host: host, isForwarded: forwarded, hasFinger: finger,
                          approval: .tenMinutes) {}
        }
        XCTAssertTrue(question().offersPass)
        XCTAssertTrue(question(key: nil).offersPass, "over a shut vault")
        XCTAssertTrue(question(host: nil).offersPass, "a commit, which has no host")
        XCTAssertFalse(question(forwarded: true).offersPass, "a forwarded yes is for that one request")
        XCTAssertFalse(question(finger: false).offersPass)
        XCTAssertFalse(question(peer: AgentPeer(names: ["ssh"], app: "/bin/sh")).offersPass)
    }

    func testTheCardsSentenceSaysItIsTheWholeApp() {
        let question = AgentQuestion(peer: Self.oriCode, key: nil, host: nil, isForwarded: false, hasFinger: true,
                                     approval: .tenMinutes) {}
        XCTAssertTrue(question.passSentence.contains("the whole of OriCode"), question.passSentence)
        XCTAssertTrue(question.passSentence.contains("Every SSH key"), question.passSentence)
    }

    /// The sentence at the top says what a touch gives, and with the row
    /// open that is the pass and not the span.
    func testWithTheRowOpenTheCardSaysATouchGivesThePass() {
        func question(key: AgentQuestion.Key?) -> AgentQuestion {
            AgentQuestion(peer: Self.oriCode, key: key, purpose: .commit, host: nil, isForwarded: false, hasFinger: true,
                          approval: .tenMinutes) {}
        }
        let open = question(key: .init(name: "k", fingerprint: "f"))
        XCTAssertTrue(open.sentence.contains("for 10 minutes"), open.sentence)
        open.keepsAllowing = true
        open.keptFor = .eightHours
        XCTAssertEqual(open.sentence, "A touch allows this and gives OriCode a pass for 8 hours.")
        XCTAssertEqual(open.statement, "OriCode wants to sign a commit")
        let shut = question(key: nil)
        shut.keepsAllowing = true
        XCTAssertEqual(shut.sentence, "A touch opens the vault and gives OriCode a pass for 1 hour.")
    }

    func testAForwardedYesWithTheRowOpenLeavesNoPass() async throws {
        let rig = await rig()
        rig.authoriser.holds = true
        let caller = caller(of: rig.agent)
        _ = await bind(caller, Host(), forwarded: true)
        async let signed = caller.sign(login(), with: AgentFixture.ed25519.blob)
        await until { !rig.authoriser.asked.isEmpty }
        let question = try XCTUnwrap(rig.stage.shown.last)
        question.keepsAllowing = true
        rig.authoriser.release(true)
        _ = await signed
        XCTAssertTrue(rig.door.passes.standing.isEmpty)
    }

    func testNewPassIsOneFingerForAnAppAndEveryKey() async throws {
        let rig = await rig()
        let host = Host()
        rig.door.passes.knownHosts = { [host.blob] }
        let app = PassApp(name: "OriCode", signer: Self.signer)
        let given = await rig.agent.give(to: app, for: .fourHours)
        XCTAssertTrue(given)
        XCTAssertEqual(rig.authoriser.asked, [.pass])
        let pass = try XCTUnwrap(rig.door.passes.standing.first)
        XCTAssertEqual(pass.appName, "OriCode")
        XCTAssertEqual(pass.keys.map(\.blob), AgentFixture.all.map(\.key.blob))

        // `known_hosts` as it stood when it was given.
        await rig.store.lock()
        let caller = caller(of: rig.agent)
        _ = await bind(caller, host)
        let signed = await caller.sign(login(), with: AgentFixture.ed25519.blob)
        XCTAssertNotNil(signed)
    }

    func testNewPassRefusedByTheFingerHoldsNothing() async throws {
        let rig = await rig()
        rig.authoriser.answer = false
        let given = await rig.agent.give(to: PassApp(name: "OriCode", signer: Self.signer), for: .oneHour)
        XCTAssertFalse(given)
        XCTAssertTrue(rig.door.passes.standing.isEmpty)
    }

    func testNewPassWantsAFingerAndAnOpenVault() async throws {
        let rig = await rig()
        let app = PassApp(name: "OriCode", signer: Self.signer)
        rig.authoriser.hasFinger = false
        var given = await rig.agent.give(to: app, for: .oneHour)
        XCTAssertFalse(given)
        XCTAssertTrue(rig.authoriser.asked.isEmpty)
        rig.authoriser.hasFinger = true
        await rig.store.lock()
        given = await rig.agent.give(to: app, for: .oneHour)
        XCTAssertFalse(given)
        XCTAssertTrue(rig.agent.passKeys.isEmpty)
    }

    func testAVaultWithNoKeyGivesNoPass() async throws {
        let store = VaultStore(backend: FakeBackend(items: [], folders: [], password: "demo"))
        let door = Door(store: store, isInFront: { false })
        door.passes.fingers = { Data() }
        let authoriser = FakeAuthoriser()
        let agent = SSHAgent(door: door, authoriser: authoriser)
        keeping.append(agent)
        await door.unlock(with: SecretBytes("demo")).value
        let given = await agent.give(to: PassApp(name: "OriCode", signer: Self.signer), for: .oneHour)
        XCTAssertFalse(given)
        XCTAssertTrue(authoriser.asked.isEmpty, "no finger for nothing")
    }

    func testTheRoomOffersNewPassWithAnOpenVaultAndAFinger() async throws {
        let rig = await rig()
        var hasFinger = true
        var given: (PassApp, PassSpan)?
        let app = PassApp(name: "OriCode", signer: Self.signer)
        let rooms = Rooms(door: rig.door, hands: .init(passKeys: { [self] in [key(rig)] }, passApps: { [app] },
                                                       hasFinger: { hasFinger }, givePass: {
                                                           given = ($0, $1)
                                                           return true
                                                       }))
        XCTAssertNil(rooms.passRefusal)
        hasFinger = false
        XCTAssertEqual(rooms.passRefusal, Rooms.passNeedsFinger)
        hasFinger = true

        await rooms.beginPass().value
        XCTAssertEqual(rooms.newPass?.app, app)
        rooms.newPass?.span = .oneDay
        await rooms.givePass().value
        XCTAssertNil(rooms.newPass)
        XCTAssertEqual(given?.0, app)
        XCTAssertEqual(given?.1, .oneDay)

        await rig.store.lock()
        XCTAssertEqual(rooms.passRefusal, Rooms.passNeedsVault)
    }

    func testTheFormIsNotReadyWithNoKeyInTheVault() {
        XCTAssertFalse(Rooms.NewPass(keys: [], apps: [PassApp(name: "OriCode", signer: Self.signer)]).isReady)
    }

    func testTheFormGoesAtTheLockWithTheKeysItCounts() async throws {
        let rig = await rig()
        let rooms = Rooms(door: rig.door, hands: .init(passKeys: { [self] in [key(rig)] },
                                                       passApps: { [PassApp(name: "OriCode", signer: Self.signer)] },
                                                       hasFinger: { true }))
        await rooms.beginPass().value
        XCTAssertNotNil(rooms.newPass)
        await rig.store.lock()
        XCTAssertNil(rooms.newPass)
    }

    func testARefusedFingerLeavesTheFormUpSayingSo() async throws {
        let rig = await rig()
        let app = PassApp(name: "OriCode", signer: Self.signer)
        let rooms = Rooms(door: rig.door, hands: .init(passKeys: { [self] in [key(rig)] }, passApps: { [app] },
                                                       hasFinger: { true }, givePass: { _, _ in false }))
        await rooms.beginPass().value
        await rooms.givePass().value
        XCTAssertEqual(rooms.newPass?.problem, Rooms.NewPass.refused)
        XCTAssertEqual(rooms.newPass?.isAsking, false)
    }

    // MARK: What he can see

    private func signLogin(_ rig: Rig, host: Host, peer: AgentPeer = oriCode) async throws {
        let caller = caller(of: rig.agent, peer: peer)
        _ = await bind(caller, host)
        let signed = await caller.sign(login(), with: AgentFixture.ed25519.blob)
        XCTAssertNotNil(signed)
    }

    private func signCommit(_ rig: Rig, peer: AgentPeer = oriCode) async throws {
        let signed = await caller(of: rig.agent, peer: peer).sign(Self.sshsig(), with: AgentFixture.ed25519.blob)
        XCTAssertNotNil(signed)
    }

    func testARowSaysWhatItHoldsAndWhatWasSignedCommitsAndLoginsApart() async throws {
        let rig = await rig()
        let host = Host()
        let pass = give(rig, knowing: [host.blob])
        XCTAssertEqual(pass.summary, "5 keys · nothing signed yet")
        await rig.store.lock()
        try await signCommit(rig)
        XCTAssertTrue(pass.summary.hasPrefix("5 keys · 1 commit, the last at "), pass.summary)
        try await signLogin(rig, host: host)
        try await signLogin(rig, host: host)
        try await signCommit(rig)
        XCTAssertEqual(pass.logins, 2)
        XCTAssertEqual(pass.commits, 2)
        XCTAssertEqual(pass.signatures, 4)
        XCTAssertEqual(pass.lastSignature, rig.clock.now)
        XCTAssertTrue(pass.summary.hasPrefix("5 keys · 2 commits, 2 logins, the last at "), pass.summary)
    }

    func testTheMarksMenuHasItsRowsOnlyWhileAPassStandsAndRevokeAllEndsThem() async throws {
        let rig = await rig()
        let quick = QuickAccess(door: rig.door, present: { _ in })
        defer { quick.end() }
        let menu = MarkMenu(door: rig.door, quick: quick, lock: LockCommands(door: rig.door), showApp: {}, quickKey: { nil })
        let bare = menu.rows().map(\.command)
        XCTAssertFalse(bare.contains(.passes))
        let held = give(rig).heldBytes
        give(rig, signer: Self.terminalSigner)
        XCTAssertEqual(menu.rows().first { $0.command == .passes }?.title, "2 SSH passes are running")
        XCTAssertEqual(menu.rows().first { $0.command == .passes }?.isEnabled, false)
        XCTAssertEqual(menu.rows().first { $0.command == .revokePasses }?.title, "Revoke All")
        XCTAssertNotNil(menu.menu().items.first { $0.identifier == MarkMenu.identifier(.revokePasses) })
        menu.perform(.revokePasses)
        XCTAssertEqual(menu.rows().map(\.command), bare)
        assertZeros(held)
    }

    func testTheLockScreensLineCountsWhatIsRunning() {
        XCTAssertNil(AgentPasses.running(0))
        XCTAssertEqual(AgentPasses.running(1), "1 SSH pass is running")
        XCTAssertEqual(AgentPasses.running(3), "3 SSH passes are running")
    }

    func testTheFirstUnlockAfterSignaturesSaysHowManyByWhichAppAndOnlyThat() async throws {
        let rig = await rig()
        let host = Host()
        give(rig, knowing: [host.blob])
        await rig.store.lock()
        try await signLogin(rig, host: host)
        try await signLogin(rig, host: host)
        await rig.door.unlock(with: SecretBytes("demo")).value
        XCTAssertEqual(rig.door.passReport, "OriCode's pass signed 2 logins for alpen.")
        rig.door.dismissPassReport()
        XCTAssertNil(rig.door.passReport)
        await rig.store.lock()
        await rig.door.unlock(with: SecretBytes("demo")).value
        XCTAssertNil(rig.door.passReport, "it was said once")
    }

    func testAPassThatEndedBeforeTheUnlockIsStillReported() async throws {
        let rig = await rig()
        let host = Host()
        give(rig, knowing: [host.blob])
        await rig.store.lock()
        try await signLogin(rig, host: host)
        rig.clock.now.addTimeInterval(60 * 60)
        rig.alarm.fire?()
        await rig.door.unlock(with: SecretBytes("demo")).value
        XCTAssertEqual(rig.door.passReport, "OriCode's pass signed 1 login for alpen.")
    }

    func testCommitsAndLoginsAreToldApart() async throws {
        let rig = await rig()
        let host = Host()
        give(rig, knowing: [host.blob])
        await rig.store.lock()
        try await signCommit(rig)
        try await signCommit(rig)
        try await signCommit(rig)
        try await signLogin(rig, host: host)
        await rig.door.unlock(with: SecretBytes("demo")).value
        XCTAssertEqual(rig.door.passReport, "OriCode's pass signed 3 commits and 1 login for alpen.")
    }

    func testCommitsAloneNameNoHost() async throws {
        let rig = await rig()
        give(rig)
        await rig.store.lock()
        try await signCommit(rig)
        await rig.door.unlock(with: SecretBytes("demo")).value
        XCTAssertEqual(rig.door.passReport, "OriCode's pass signed 1 commit.")
    }

    func testTwoHostsAndTwoAppsAreOneLine() async throws {
        let rig = await rig()
        let first = Host(), second = Host()
        give(rig, knowing: [first.blob, second.blob])
        give(rig, knowing: [first.blob], signer: Self.terminalSigner)
        await rig.store.lock()
        try await signLogin(rig, host: first)
        try await signLogin(rig, host: first)
        try await signCommit(rig)
        let elsewhere = AgentPeer(names: ["ssh", "OriCode"], app: "/Applications/OriCode.app", destination: "buzul",
                                  signer: Self.signer)
        try await signLogin(rig, host: second, peer: elsewhere)
        try await signCommit(rig, peer: Self.terminal)
        await rig.door.unlock(with: SecretBytes("demo")).value
        XCTAssertEqual(rig.door.passReport, "OriCode's pass signed 1 commit and 2 logins for alpen, and 2 more.")
    }

    func testAnUnlockWithNothingSignedSaysNothing() async throws {
        let rig = await rig()
        give(rig)
        await rig.store.lock()
        await rig.door.unlock(with: SecretBytes("demo")).value
        XCTAssertNil(rig.door.passReport)
    }

    func testTheLineGoesAtTheLock() async throws {
        let rig = await rig()
        give(rig)
        await rig.store.lock()
        try await signCommit(rig)
        await rig.door.unlock(with: SecretBytes("demo")).value
        XCTAssertNotNil(rig.door.passReport)
        await rig.store.lock()
        XCTAssertNil(rig.door.passReport)
    }

    // MARK: Who an app is

    /// A process this test ran, by what the system says of it.
    private func started(_ file: String, _ arguments: [String] = ["30"]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: file)
        process.arguments = arguments
        try process.run()
        addTeardownBlock { process.terminate() }
        return process
    }

    func testThisAppIsKnownByItsSignature() throws {
        let signer = try XCTUnwrap(AppSigner.of(getpid()), "a Debug build is signed by the team")
        XCTAssertEqual(signer, AppSigner(bundleID: AppInfo.bundleID, team: PeerCheck.team))
    }

    func testAppleHasNoTeamAndIsAnchoredAll() throws {
        let process = try started("/bin/sleep")
        XCTAssertEqual(AppSigner.of(process.processIdentifier)?.team, AppSigner.apple)
    }

    /// The team's name is in the code's own directory for anyone to write.
    /// What holds it is the certificate.
    func testACopySignedAdHocUnderThisAppsNameIsNobody() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oripass-signer-\(UUID().uuidString)")
        directories.append(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent("sleep")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: copy)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", "--identifier", AppInfo.bundleID, copy.path]
        try sign.run()
        sign.waitUntilExit()
        XCTAssertEqual(sign.terminationStatus, 0)
        let process = try started(copy.path)
        XCTAssertNil(AppSigner.of(process.processIdentifier))
    }

    func testAProcessThatIsGoneIsNobody() {
        XCTAssertNil(AppSigner.of(99_999_999))
    }
}
