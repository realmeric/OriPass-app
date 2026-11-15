import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import SwiftUI
import XCTest
@testable import OriPass

/// The card over ssh: what it says in each of its four cases, where its
/// destination comes from, where it stands, and what a span chosen on it
/// does. What the sensor does with its context is checked by hand, since no
/// test can put a finger on it.
@MainActor
final class AgentCardTests: XCTestCase {
    private static let peer = AgentPeer(names: ["ssh", "zsh", "claude", "OriCode"], app: "/Applications/OriCode.app",
                                        destination: "alpen")
    private static let key = AgentQuestion.Key(name: "invented", fingerprint: "SHA256:invented")
    private static let host = "SHA256:hostinvented"
    private static let data = Data("what is signed".utf8)

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

    private func rig(isOpen: Bool = true, patience: TimeInterval = 5, password: Bool = false) async -> Rig {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oripass-card-\(UUID().uuidString)")
        directories.append(directory)
        let enclave = FakeEnclave()
        let seal = PasswordSeal(directory: directory, enclave: enclave)
        let backend = FakeBackend(items: AgentFixture.vault, folders: [], password: "demo")
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        let door = Door(store: store, seal: seal, isInFront: { false })
        door.preferences.settings.lock.unlockWithFinger = true
        let authoriser = FakeAuthoriser()
        authoriser.hasFinger = !password
        let stage = RememberingAgentStage()
        let clock = Clock()
        let agent = SSHAgent(door: door, authoriser: authoriser, stage: stage, now: { clock.now }, patience: patience)
        await door.unlock(with: SecretBytes("demo")).value
        if !isOpen { await store.lock() }
        keeping.append(agent)
        return Rig(store: store, door: door, enclave: enclave, authoriser: authoriser, stage: stage, agent: agent,
                   clock: clock)
    }

    private func caller(of agent: SSHAgent) -> AgentCaller {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        agent.adopt(pair[1], peer: Self.peer)
        ends.append(pair[0])
        return AgentCaller(end: pair[0])
    }

    private func signing(_ rig: Rig) async -> Data? {
        await caller(of: rig.agent).sign(Self.data, with: AgentFixture.ed25519.blob)
    }

    private func until(_ isSo: () -> Bool) async {
        for _ in 0..<400 where !isSo() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func question(key: AgentQuestion.Key? = key, host: String? = host, peer: AgentPeer = peer,
                          isForwarded: Bool = false, hasFinger: Bool = true) -> AgentQuestion {
        AgentQuestion(peer: peer, key: key, host: host, isForwarded: isForwarded, hasFinger: hasFinger,
                      approval: .tenMinutes) {}
    }

    private func spoken(_ question: AgentQuestion) -> String {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Metrics.agentCardShot), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: AgentCard(question: question, drawsFinger: false))
        window.contentView?.layoutSubtreeIfNeeded()
        return said(in: window.contentView).joined(separator: " ")
    }

    // MARK: The words

    func testThePlainQuestionSaysWhoWhichKeyWhereAndForHowLong() {
        let question = question()
        XCTAssertEqual(question.statement, "OriCode wants to connect to alpen")
        XCTAssertEqual(question.chain, "ssh › zsh › claude › OriCode")
        XCTAssertEqual(question.destination, "alpen")
        XCTAssertEqual(question.sentence, "A touch lets OriCode, and whatever it runs, use this key for 10 minutes. The key stays in OriPass.")
        XCTAssertNil(question.warning)
        XCTAssertNil(question.hostLine)
        XCTAssertTrue(question.offersSpan)
        XCTAssertEqual(question.span, .tenMinutes)

        let words = spoken(question)
        for word in [question.statement, "invented", "SHA256:invented", "alpen", Self.host, "Server's key", question.chain,
                     AgentCard.touchID, "Deny", "Each use", "Until the lock", "seconds left"] {
            XCTAssertTrue(words.contains(word), "VoiceOver is not given \(word): \(words)")
        }
        XCTAssertFalse(words.contains(AgentCard.usePassword))
    }

    func testAForwardedQuestionWarnsInItsOwnWordsAndHasNoSpan() {
        let question = question(isForwarded: true)
        XCTAssertEqual(question.warning, "This came from a remote host through agent forwarding, so it is asked every time.")
        XCTAssertFalse(question.offersSpan)
        XCTAssertEqual(question.span, .eachUse)
        XCTAssertEqual(question.destinationLabel, "Through")
        let words = spoken(question)
        XCTAssertTrue(words.contains("agent forwarding"), words)
        XCTAssertFalse(words.contains("10 minutes"), words)
        XCTAssertTrue(words.contains("Through, alpen"), words)
    }

    func testOverAShutVaultItSaysTheVaultWillOpenAndNamesNoKey() {
        let question = question(key: nil, host: nil)
        XCTAssertEqual(question.statement, "OriCode wants to open the vault")
        XCTAssertEqual(question.sentence, "A touch opens the vault and lets OriCode, and whatever it runs, use a key for 10 minutes.")
        let words = spoken(question)
        XCTAssertTrue(words.contains("A touch opens the vault"), words)
        XCTAssertFalse(words.contains("Key,"), words)
        XCTAssertTrue(question.offersSpan)
    }

    func testAForwardedCallerOverAShutVaultIsNotPromisedItsSignature() {
        let question = question(key: nil, host: nil, isForwarded: true)
        XCTAssertEqual(question.sentence, "A touch opens the vault.")
        XCTAssertNotNil(question.warning)
    }

    func testWithNoFingerTheButtonStandsInItsPlace() {
        let words = spoken(question(hasFinger: false))
        XCTAssertTrue(words.contains(AgentCard.usePassword), words)
        XCTAssertFalse(words.contains(AgentCard.touchID), words)
        XCTAssertTrue(words.contains("Deny"), words)
    }

    func testADestinationWithNoHostKeySaysItIsOnlyWhatTheProcessSays() {
        XCTAssertEqual(question(host: nil).hostLine, "The server has not proved this: it is only what the process says.")
    }

    func testTheCardSaysWhatTheSignatureIsFor() {
        func statement(_ purpose: AgentPurpose, destination: String? = nil, act: GitAct? = nil) -> String {
            let peer = AgentPeer(names: ["ssh", "OriCode"], app: "/Applications/OriCode.app", destination: destination, gitAct: act)
            return AgentQuestion(peer: peer, key: Self.key, purpose: purpose, host: nil, isForwarded: false, hasFinger: true,
                                 approval: .tenMinutes) {}.statement
        }
        XCTAssertEqual(statement(.commit), "OriCode wants to sign a commit")
        XCTAssertEqual(statement(.signature), "OriCode wants to sign something with an SSH key")
        XCTAssertEqual(statement(.login), "OriCode wants to connect to a server")
        XCTAssertEqual(statement(.login, destination: "github.com", act: .push), "OriCode wants to push to github.com")
        XCTAssertEqual(statement(.login, destination: "github.com", act: .fetch), "OriCode wants to fetch from github.com")
    }

    func testWhatATouchGivesFollowsTheSpanOnTheCard() {
        let question = question()
        question.span = .eachUse
        XCTAssertTrue(question.sentence.contains("use this key this once"), question.sentence)
        question.span = .untilLock
        XCTAssertTrue(question.sentence.contains("use this key until the vault locks"), question.sentence)
        XCTAssertEqual(self.question(isForwarded: true).sentence, "A touch allows this one request.")
    }

    func testGitsCommandIsReadForItsNameAndNothingElse() {
        let git = ["ssh", "-o", "SendEnv=GIT_PROTOCOL", "git@github.com"]
        XCTAssertEqual(SSHDestination.gitAct(git + ["git-receive-pack 'alpen/secret.git'"]), .push)
        XCTAssertEqual(SSHDestination.gitAct(git + ["git-upload-pack 'alpen/secret.git'"]), .fetch)
        XCTAssertEqual(SSHDestination.read(git + ["git-upload-pack 'alpen/secret.git'"]), "github.com")
        XCTAssertNil(SSHDestination.gitAct(git + ["rm -rf git-receive-pack"]))
        XCTAssertNil(SSHDestination.gitAct(git))
        XCTAssertEqual(SSHDestination.gitAct(["ssh", "--", "alpen", "git-receive-pack", "alpen"]), .push)
    }

    func testAProjectIsAFolderOrTheOneAboveAWorktree() {
        XCTAssertEqual(AgentPeer.project(in: "/Users/him/Developer/blackjack"), "blackjack")
        XCTAssertEqual(AgentPeer.project(in: "/Users/him/Developer/blackjack/.worktrees/t-b03753"), "blackjack")
        XCTAssertEqual(AgentPeer.project(in: "/Users/him/Developer/blackjack/.worktrees/t-b03753/ios"), "blackjack")
        XCTAssertNil(AgentPeer.project(in: "/"))
    }

    func testOnlyAGitCallerIsAskedWhereItWorks() {
        let paths: [pid_t: String] = [40: "/usr/bin/ssh-keygen", 30: "/usr/bin/git", 20: "/Applications/OriCode.app/Contents/MacOS/OriCode"]
        let parents: [pid_t: pid_t] = [40: 30, 30: 20, 20: 1]
        let folder: (pid_t) -> String? = { _ in "/Users/him/Developer/blackjack" }
        let git = AgentPeer.walk(from: 40, path: { paths[$0] }, parent: { parents[$0] }, folder: folder)
        XCTAssertEqual(git.project, "blackjack")
        let other = AgentPeer.walk(from: 20, path: { paths[$0] }, parent: { parents[$0] }, folder: folder)
        XCTAssertNil(other.project)
    }

    func testAGitCallerShowsItsProject() {
        let peer = AgentPeer(names: ["ssh-keygen", "git", "OriCode"], app: "/Applications/OriCode.app", project: "alpen")
        XCTAssertTrue(spoken(question(peer: peer)).contains("Project, alpen"))
    }

    func testThePurposeIsReadFromWhatIsToBeSigned() {
        let key = Data("key".utf8)
        var login = Data()
        login.appendCounted(Data("session".utf8))
        login.append(50)
        ["git", "ssh-connection", "publickey"].forEach { login.appendCounted(Data($0.utf8)) }
        login.append(1)
        login.appendCounted(Data("ssh-ed25519".utf8))
        login.appendCounted(key)
        XCTAssertEqual(AgentPurpose(signing: Self.sshsig("git"), key: key), .commit)
        XCTAssertEqual(AgentPurpose(signing: Self.sshsig("file"), key: key), .signature)
        XCTAssertEqual(AgentPurpose(signing: login, key: key), .login)
        XCTAssertEqual(AgentPurpose(signing: Data("anything".utf8), key: key), .signature)
    }

    func testASignatureRequestIsHeldToItsWholeShape() {
        XCTAssertEqual(SSHSigData(Self.sshsig("git"))?.isGit, true)
        XCTAssertEqual(SSHSigData(Self.sshsig("git", hash: "sha256", length: 32))?.isGit, true)
        XCTAssertEqual(SSHSigData(Self.sshsig("file"))?.isGit, false)
        XCTAssertNil(SSHSigData(Self.sshsig("")), "no namespace")
        XCTAssertNil(SSHSigData(Self.sshsig("git") + [0]), "a byte after the hash")
        XCTAssertNil(SSHSigData(Self.sshsig("git", reserved: "x")), "reserved has something in it")
        XCTAssertNil(SSHSigData(Self.sshsig("git", hash: "md5", length: 16)), "a hash OpenSSH does not sign with")
        XCTAssertNil(SSHSigData(Self.sshsig("git", length: 32)), "a hash of the wrong length")
        XCTAssertNil(SSHSigData(Data("SSHSIH".utf8) + Self.sshsig("git").dropFirst(6)), "another magic")
    }

    /// What `ssh-keygen -Y sign` hands the agent.
    static func sshsig(_ namespace: String, reserved: String = "", hash: String = "sha512", length: Int = 64) -> Data {
        var data = Data("SSHSIG".utf8)
        [namespace, reserved, hash].forEach { data.appendCounted(Data($0.utf8)) }
        data.appendCounted(Data(repeating: 7, count: length))
        return data
    }

    func testAHostKeyWithNoDestinationIsStillShown() {
        let peer = AgentPeer(names: ["git"], app: "/usr/bin/git")
        let words = spoken(question(peer: peer))
        XCTAssertTrue(words.contains(Self.host), words)
    }

    func testTheLineRunsDownTheWholeWait() {
        let asked = Date(timeIntervalSince1970: 1_800_000_000)
        let question = AgentQuestion(peer: Self.peer, key: nil, host: nil, isForwarded: false, hasFinger: true,
                                     approval: .eachUse, asked: asked, patience: 60) {}
        XCTAssertEqual(question.left(at: asked), 1)
        XCTAssertEqual(question.left(at: asked + 15), 0.75)
        XCTAssertEqual(question.left(at: asked + 90), 0)
    }

    // MARK: The destination

    func testTheDestinationIsReadAsSshReadsItAndNothingElseIsKept() {
        let lists: [([String], String?)] = [
            (["ssh", "alpen"], "alpen"),
            (["ssh", "-p", "22", "meric@host"], "host"),
            (["ssh", "-p22", "meric@host", "cat", "/etc/secret"], "host"),
            (["ssh", "-o", "SendEnv=GIT_PROTOCOL", "git@github.com", "git-upload-pack", "'meric/repo.git'"], "github.com"),
            (["ssh", "-oProxyCommand=nc %h %p", "-o", "IdentityAgent=/tmp/a b", "-i", "/keys/secret", "alpen", "true"], "alpen"),
            (["ssh", "-Tv", "-l", "meric", "alpen"], "alpen"),
            (["ssh", "-tp", "2222", "alpen"], "alpen"),
            (["ssh", "-x", "-oForwardAgent=no", "-l", "meric", "-s", "--", "alpen", "sftp"], "alpen"),
            (["ssh", "ssh://meric@alpen.example:2222/path"], "alpen.example"),
            (["ssh", "ssh://[fe80::1]:22"], "fe80::1"),
            (["ssh", "meric@[fe80::1]"], "fe80::1"),
            (["ssh", "10.0.0.2", "uptime"], "10.0.0.2"),
            (["ssh"], nil),
            (["ssh", "-V"], nil),
            (["ssh", "-p"], nil),
            (["ssh", "-o", "User=meric"], nil),
            (["ssh", "--"], nil),
            ([], nil),
            (["ssh", "a host; rm -rf /"], nil),
            (["ssh", "meric@"], nil),
            (["ssh", "-"], nil),
            (["ssh", "gïthub.example"], nil),
            (["ssh", String(repeating: "a", count: 254)], nil),
        ]
        for (arguments, wanted) in lists {
            XCTAssertEqual(SSHDestination.read(arguments), wanted, "\(arguments)")
        }
    }

    func testOnlyAnSshIsAskedWhereItIsGoing() {
        let paths: [pid_t: String] = [40: "/usr/bin/ssh", 30: "/bin/zsh", 20: "/Applications/Term.app/Contents/MacOS/Term"]
        let parents: [pid_t: pid_t] = [40: 30, 30: 20]
        let peer = AgentPeer.walk(from: 40, path: { paths[$0] }, parent: { parents[$0] }, arguments: { pid in
            pid == 40 ? ["ssh", "alpen"] : ["zsh", "not-this"]
        })
        XCTAssertEqual(peer.destination, "alpen")
        XCTAssertEqual(peer.appProcess, 20)

        let signer = AgentPeer.walk(from: 30, path: { paths[$0] }, parent: { parents[$0] }, arguments: { _ in
            XCTFail("the arguments of what is not ssh are not read")
            return ["zsh", "not-this"]
        })
        XCTAssertNil(signer.destination)
    }

    func testTheEnvironmentAfterTheArgumentsIsNotRead() {
        var bytes: [UInt8] = [2, 0, 0, 0]
        bytes += Array("/usr/bin/ssh".utf8) + [0, 0, 0, 0]
        bytes += Array("ssh".utf8) + [0]
        bytes += Array("alpen".utf8) + [0]
        bytes += Array("SECRET=invented".utf8) + [0]
        XCTAssertEqual(AgentPeer.words(ofProcessArguments: bytes[...]), ["ssh", "alpen"])
        XCTAssertEqual(AgentPeer.words(ofProcessArguments: [1, 0][...]), [])
        XCTAssertEqual(AgentPeer.words(ofProcessArguments: [1, 0, 0, 0, 65][...]), [])
    }

    // MARK: The span

    func testASpanChosenStandsForThatAnswerAndIsNotWrittenToTheSettings() async throws {
        let rig = await rig()
        rig.authoriser.holds = true
        let asking = Task { await self.signing(rig) }
        await until { rig.stage.showing != nil }
        try XCTUnwrap(rig.stage.showing).span = .untilLock
        rig.authoriser.release(true)
        let signature = await asking.value
        XCTAssertNotNil(signature)
        XCTAssertEqual(rig.door.preferences.settings.ssh.approval, .tenMinutes, "for this answer only")

        rig.authoriser.holds = false
        rig.clock.now.addTimeInterval(24 * 60 * 60)
        _ = await signing(rig)
        XCTAssertEqual(rig.authoriser.asked.count, 1, "until the lock outlasts the ten minutes the settings say")
    }

    func testAShorterSpanChosenIsAskedAgain() async throws {
        let rig = await rig()
        rig.authoriser.holds = true
        let asking = Task { await self.signing(rig) }
        await until { rig.stage.showing != nil }
        try XCTUnwrap(rig.stage.showing).span = .eachUse
        rig.authoriser.release(true)
        _ = await asking.value

        rig.authoriser.holds = false
        _ = await signing(rig)
        XCTAssertEqual(rig.authoriser.asked.count, 2)
    }

    func testTheSpanChosenOverAShutVaultStandsForTheFingerThatOpenedIt() async throws {
        let rig = await rig(isOpen: false)
        let stage = rig.stage
        stage.onShow = { $0.span = .eachUse }
        let caller = caller(of: rig.agent)
        _ = await caller.list()
        _ = await caller.sign(Self.data, with: AgentFixture.ed25519.blob)
        XCTAssertEqual(rig.authoriser.asked, [], "the finger answered for the first signature")
        _ = await signing(rig)
        XCTAssertEqual(rig.authoriser.asked, [.sign], "and with each use chosen it stood for no other")
    }

    func testAForwardedYesLeavesNoApprovalForAnyoneElse() async throws {
        let rig = await rig()
        let far = caller(of: rig.agent)
        _ = await far.bind(host: Data("nonsense".utf8), session: Data(), signature: Data(), forwarded: true)
        _ = await far.sign(Self.data, with: AgentFixture.ed25519.blob)
        _ = await signing(rig)
        XCTAssertEqual(rig.authoriser.asked.count, 2, "the plain caller from the same app is asked for itself")
    }

    // MARK: The context

    func testTheFingerIsAskedForOnTheCardsContext() async throws {
        let rig = await rig()
        let signature = await signing(rig)
        XCTAssertNotNil(signature)
        let question = try XCTUnwrap(rig.stage.shown.first)
        XCTAssertTrue(try XCTUnwrap(rig.authoriser.contexts.first ?? nil) === question.finger)
    }

    func testACardThatCouldNotComeUpLeavesTheSheetToAsk() async throws {
        let rig = await rig()
        rig.stage.comesUp = false
        let signature = await signing(rig)
        XCTAssertNotNil(signature)
        XCTAssertEqual(rig.authoriser.contexts.count, 1)
        XCTAssertNil(rig.authoriser.contexts[0])
    }

    func testOverAShutVaultTheSealOpensOnTheCardsContext() async throws {
        let rig = await rig(isOpen: false)
        _ = await caller(of: rig.agent).list()
        XCTAssertEqual(rig.store.state, .unlocked)
        let question = try XCTUnwrap(rig.stage.shown.first)
        XCTAssertEqual(rig.enclave.contexts.count, 1)
        XCTAssertTrue(try XCTUnwrap(rig.enclave.contexts[0]) === question.finger)
    }

    func testTheCheckHandsTheContextToTheSeal() async throws {
        let rig = await rig()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oripass-card-\(UUID().uuidString)")
        directories.append(directory)
        let enclave = FakeEnclave()
        let seal = PasswordSeal(directory: directory, enclave: enclave)
        try seal.seal(SecretBytes("demo"))
        let check = OwnerCheck(store: rig.store, seal: seal, stage: nil)
        XCTAssertTrue(check.hasFinger)
        let context = LAContext()
        let isHis = await check.authorise(.sign, for: "invented", on: context)
        XCTAssertTrue(isHis)
        XCTAssertTrue(try XCTUnwrap(enclave.contexts[0]) === context)
        _ = await check.authorise(.copy, for: "invented")
        XCTAssertNil(enclave.contexts[1], "a question of the app's own is the sheet")
    }

    func testWithTheLidShutTheCheckTurnsToThePassword() async throws {
        let rig = await rig()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oripass-card-\(UUID().uuidString)")
        directories.append(directory)
        let enclave = FakeEnclave()
        let seal = PasswordSeal(directory: directory, enclave: enclave)
        try seal.seal(SecretBytes("demo"))
        enclave.hasFinger = false
        let stage = RememberingQuestion()
        let check = OwnerCheck(store: rig.store, seal: seal, stage: stage)
        XCTAssertFalse(check.hasFinger)
        let asking = Task { await check.authorise(.sign, for: "invented") }
        await until { stage.showing != nil }
        XCTAssertEqual(enclave.asked, [], "no finger is asked for where there is none")
        try XCTUnwrap(stage.showing).cancel()
        let isHis = await asking.value
        XCTAssertFalse(isHis)
    }

    func testOverAShutVaultWithTheLidShutThereIsNoCardAndTheLockScreenSaysWhy() async {
        let rig = await rig(isOpen: false)
        rig.enclave.hasFinger = false
        _ = await caller(of: rig.agent).list()
        XCTAssertTrue(rig.stage.shown.isEmpty)
        XCTAssertEqual(rig.enclave.asked, [])
        XCTAssertEqual(rig.door.agentRefusal, Door.agentWaited)
    }

    // MARK: The password

    func testWithNoFingerThePasswordsCardWaitsForTheButton() async throws {
        let rig = await rig(password: true)
        let asking = Task { await self.signing(rig) }
        await until { rig.stage.showing != nil }
        let question = try XCTUnwrap(rig.stage.showing)
        XCTAssertFalse(question.hasFinger)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(rig.authoriser.asked, [], "the password's card takes the keys, so it never rises by itself")
        question.usePassword()
        let signature = await asking.value
        XCTAssertNotNil(signature)
        XCTAssertEqual(rig.authoriser.asked, [.sign])
        XCTAssertNil(rig.stage.showing)
    }

    func testDenyBeforeTheButtonIsANoWithNothingAsked() async throws {
        let rig = await rig(password: true)
        let asking = Task { await self.signing(rig) }
        await until { rig.stage.showing != nil }
        try XCTUnwrap(rig.stage.showing).deny()
        let signature = await asking.value
        XCTAssertNil(signature)
        XCTAssertEqual(rig.authoriser.asked, [])
    }

    func testTheSixtySecondsRunOutOnTheButtonToo() async {
        let rig = await rig(patience: 0.05, password: true)
        let signature = await signing(rig)
        XCTAssertNil(signature)
        XCTAssertEqual(rig.authoriser.asked, [])
        XCTAssertNil(rig.stage.showing)
    }

    func testTheLockTakesTheCardDownUnderTheButton() async throws {
        let rig = await rig(password: true)
        let asking = Task { await self.signing(rig) }
        await until { rig.stage.showing != nil }
        await rig.store.lock()
        let signature = await asking.value
        XCTAssertNil(signature)
        XCTAssertNil(rig.stage.showing)
        XCTAssertEqual(rig.authoriser.asked, [])
    }

    // MARK: The panel

    private static let screens: [(frame: NSRect, visible: NSRect)] = [
        (NSRect(x: 0, y: 0, width: 1440, height: 900), NSRect(x: 0, y: 0, width: 1440, height: 870)),
        (NSRect(x: 1440, y: 100, width: 2560, height: 1440), NSRect(x: 1440, y: 100, width: 2560, height: 1410)),
    ]

    func testThePanelStandsInTheMiddleOfTheScreenThePointerIsOn() {
        let size = CGSize(width: 460, height: 600)
        XCTAssertEqual(AgentPlace.frame(of: size, pointer: CGPoint(x: 2000, y: 700), screens: Self.screens),
                       NSRect(x: 2490, y: 505, width: 460, height: 600))
        XCTAssertEqual(AgentPlace.frame(of: size, pointer: CGPoint(x: 100, y: 100), screens: Self.screens),
                       NSRect(x: 490, y: 135, width: 460, height: 600))
        XCTAssertEqual(AgentPlace.frame(of: size, pointer: CGPoint(x: -500, y: -500), screens: Self.screens),
                       NSRect(x: 490, y: 135, width: 460, height: 600), "on no screen it is the first")
        XCTAssertEqual(AgentPlace.frame(of: size, pointer: .zero, screens: []).size, size)
    }

    private func panel(_ question: AgentQuestion) -> AgentPanel.Panel {
        let panel = AgentPanel.make(question, pointer: CGPoint(x: 2000, y: 700), screens: Self.screens)
        addTeardownBlock { @MainActor in panel.contentView = nil }
        return panel
    }

    private func key(_ code: UInt16, to panel: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: panel.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                         isARepeat: false, keyCode: code)!
    }

    private func click(on panel: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                           windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func testThePanelIsMadeWhereItStandsAndTakesTheKeysTheSensorNeeds() {
        let panel = panel(question())
        XCTAssertEqual(panel.frame.midX, 2720, accuracy: 1)
        XCTAssertEqual(panel.frame.midY, 805, accuracy: 1)
        XCTAssertTrue(panel.canBecomeKey, "the system pauses the sensor in a window without the keys")
        XCTAssertFalse(self.panel(question(hasFinger: false)).canBecomeKey, "with no finger it waits for its click")
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertEqual(panel.level, .modalPanel)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    }

    func testNoKeyAnswersItAndEscOnlyOnceItHasBeenClicked() {
        var denied = 0
        let question = AgentQuestion(peer: Self.peer, key: Self.key, host: nil, isForwarded: false, hasFinger: true,
                                     approval: .tenMinutes) { denied += 1 }
        let panel = panel(question)
        let (escape, enter, space): (UInt16, UInt16, UInt16) = (53, 36, 49)
        panel.sendEvent(key(escape, to: panel))
        panel.sendEvent(key(enter, to: panel))
        panel.sendEvent(key(space, to: panel))
        XCTAssertEqual(denied, 0)

        panel.sendEvent(click(on: panel))
        panel.sendEvent(key(enter, to: panel))
        panel.sendEvent(key(space, to: panel))
        XCTAssertEqual(denied, 0, "neither Return nor Space answers it")
        panel.sendEvent(key(escape, to: panel))
        XCTAssertEqual(denied, 1)
    }

    func testAKeyMeantForTheAppInFrontStopsAtThePanel() {
        let panel = panel(question())
        let (q, escape): (UInt16, UInt16) = (12, 53)
        XCTAssertTrue(panel.performKeyEquivalent(with: key(q, to: panel)), "or ⌘Q would quit this app")
        XCTAssertFalse(panel.performKeyEquivalent(with: key(escape, to: panel)))
    }

    private func sensors(in view: NSView) -> [LAAuthenticationView] {
        ((view as? LAAuthenticationView).map { [$0] } ?? []) + view.subviews.flatMap(sensors)
    }

    func testThePanelPairsTheSensorWithTheQuestionsContext() throws {
        let question = question()
        let panel = panel(question)
        panel.contentView?.layoutSubtreeIfNeeded()
        let sensor = try XCTUnwrap(sensors(in: try XCTUnwrap(panel.contentView)).first)
        XCTAssertTrue(sensor.context === question.finger, "paired before anyone is asked, or the sheet would come up")
    }

    func testWithNoFingerThereIsNoSensor() throws {
        let panel = panel(question(hasFinger: false))
        XCTAssertTrue(sensors(in: try XCTUnwrap(panel.contentView)).isEmpty)
    }

    func testThePanelIsNoLongerThanTheShortestScreenItHasToFitOn() {
        let panel = panel(question())
        XCTAssertLessThan(panel.frame.height, 700, "a 13-inch screen has about 870 points free")
    }

    private static let signed = AgentPeer(names: ["ssh", "OriCode"], app: "/Applications/OriCode.app", destination: "alpen",
                                          signer: AppSigner(bundleID: "dev.oricode", team: "ABCDE12345"))

    func testTheAwayRowOpensTheFourSpansAndSaysWhatAPassDoes() {
        let shut = question(peer: Self.signed)
        XCTAssertTrue(spoken(shut).contains(AgentQuestion.awayLabel))
        XCTAssertFalse(spoken(shut).contains("24 hours"))
        let open = question(peer: Self.signed)
        open.keepsAllowing = true
        let said = spoken(open)
        for span in PassSpan.allCases { XCTAssertTrue(said.contains(span.word), span.word) }
        XCTAssertTrue(said.contains(open.passSentence))
        XCTAssertNil(shut.passSpan)
        XCTAssertEqual(open.passSpan, .oneHour)
    }

    func testThePanelGrowsAroundItsMiddleAsTheRowOpensAndStillFits() throws {
        let opening = question(peer: Self.signed)
        let panel = panel(opening)
        let before = panel.frame
        opening.keepsAllowing = true
        panel.contentView?.layoutSubtreeIfNeeded()
        AgentPanel.fit(panel)
        XCTAssertGreaterThan(panel.frame.height, before.height)
        XCTAssertEqual(panel.frame.midY, before.midY, accuracy: 1)
        XCTAssertEqual(panel.frame.midX, before.midX, accuracy: 1)
        XCTAssertLessThan(panel.frame.height, 860, "a 13-inch screen has about 870 points free")
    }

    func testAnAppThatIsNoRunningAppStillHasItsIconAndNoAppHasNone() {
        XCTAssertNil(AgentPeer(names: ["ssh"], app: "/bin/sh").icon)
        XCTAssertNotNil(AgentPeer(names: ["ssh", "Finder"], app: "/System/Library/CoreServices/Finder.app",
                                  appProcess: 0).icon)
    }
}
