import Foundation
import XCTest
@testable import OriPass

/// OpenSSH's own tools against the agent, on a socket file in a temporary
/// directory and with `SSH_AUTH_SOCK` in those children's environments and
/// nobody else's. No network: `ssh-keygen -Y` signs a file, and `ssh` reaches
/// an `sshd` it started itself, over that child's standard input.
@MainActor
final class SSHAgentOpenSSHTests: XCTestCase {
    private var directory: URL!
    private var agent: SSHAgent?

    /// Short: `sun_path` holds 104 bytes and `$TMPDIR` has used about 50.
    private var socket: URL { directory.appendingPathComponent("agent.sock") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("op-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        agent?.end()
        agent = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private let stage = RememberingAgentStage()
    private let authoriser = FakeAuthoriser()

    private func open(items: [JSONValue] = AgentFixture.vault, patience: TimeInterval = 60) async -> (agent: SSHAgent, door: Door) {
        let backend = FakeBackend(items: items, folders: [], password: "demo")
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        let door = Door(store: store, isInFront: { false })
        door.passes.fingers = { Data("enrolled".utf8) }
        let agent = SSHAgent(door: door, authoriser: authoriser, stage: stage, path: socket, patience: patience)
        self.agent = agent
        await door.unlock(with: SecretBytes("demo")).value
        var choices = SSHChoices()
        choices.isOn = true
        agent.follow(choices)
        XCTAssertTrue(agent.isOpen)
        return (agent, door)
    }

    /// Off the main actor, which has to be free to answer it.
    @discardableResult
    private func run(_ tool: String, _ arguments: [String], input: Data? = nil) async throws -> (status: Int32, out: String) {
        let socket = self.socket.path
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.environment = ["SSH_AUTH_SOCK": socket, "HOME": "/nonexistent"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = out
            let stdin = Pipe()
            process.standardInput = stdin
            try process.run()
            if let input { stdin.fileHandleForWriting.write(input) }
            try stdin.fileHandleForWriting.close()
            let said = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: said, as: UTF8.self))
        }.value
    }

    func testTheFolderIsHisAloneAndTheFileToo() async throws {
        _ = await open()
        let files = FileManager.default
        let folder = try files.attributesOfItem(atPath: directory.path)
        XCTAssertEqual(folder[.posixPermissions] as? Int, 0o700)
        let file = try files.attributesOfItem(atPath: socket.path)
        XCTAssertEqual(file[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(file[.type] as? FileAttributeType, .typeSocket)
    }

    func testSshAddListsTheKeysUnderTheirItemsNames() async throws {
        _ = await open()
        let said = try await run("/usr/bin/ssh-add", ["-L"])
        XCTAssertEqual(said.status, 0, said.out)
        let lines = said.out.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, AgentFixture.all.count)
        for ((name, key), line) in zip(AgentFixture.all, lines) {
            let kept = key.publicLine.split(separator: " ").prefix(2).joined(separator: " ")
            XCTAssertEqual(line, "\(kept) \(name)")
        }
    }

    func testSshAddCannotAddOrRemoveOrLock() async throws {
        _ = await open()
        var said = try await run("/usr/bin/ssh-add", [AgentFixture.ed25519.file.path])
        XCTAssertNotEqual(said.status, 0, said.out)
        said = try await run("/usr/bin/ssh-add", ["-D"])
        XCTAssertNotEqual(said.status, 0, said.out)
        said = try await run("/usr/bin/ssh-add", ["-d", AgentFixture.ed25519.file.path])
        XCTAssertNotEqual(said.status, 0, said.out)
        let list = try await run("/usr/bin/ssh-add", ["-L"])
        XCTAssertEqual(list.out.split(separator: "\n").count, AgentFixture.all.count)
    }

    func testSshKeygenSignsThroughTheAgentAndVerifiesForEachKindOfKey() async throws {
        _ = await open()
        let message = Data("signed through the agent\n".utf8)
        for (name, key) in AgentFixture.all {
            // No private half beside it, so the only way to a signature is
            // the agent.
            let folder = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let publicKey = folder.appendingPathComponent("key.pub")
            try key.publicLine.write(to: publicKey, atomically: true, encoding: .utf8)
            let file = folder.appendingPathComponent("message")
            try message.write(to: file)

            let signed = try await run("/usr/bin/ssh-keygen", ["-Y", "sign", "-n", "file", "-f", publicKey.path, file.path])
            XCTAssertEqual(signed.status, 0, "\(name): \(signed.out)")
            let signature = file.appendingPathExtension("sig")
            XCTAssertTrue(FileManager.default.fileExists(atPath: signature.path), name)

            let allowed = folder.appendingPathComponent("allowed")
            try "invented@oripass \(key.publicLine)".write(to: allowed, atomically: true, encoding: .utf8)
            let checked = try await run("/usr/bin/ssh-keygen", ["-Y", "verify", "-n", "file", "-f", allowed.path,
                                                                "-I", "invented@oripass", "-s", signature.path],
                                        input: message)
            XCTAssertEqual(checked.status, 0, "\(name): \(checked.out)")

            let wrong = try await run("/usr/bin/ssh-keygen", ["-Y", "verify", "-n", "file", "-f", allowed.path,
                                                              "-I", "invented@oripass", "-s", signature.path],
                                      input: Data("something else\n".utf8))
            XCTAssertNotEqual(wrong.status, 0, name)
        }
    }

    /// The peer this test's children are, by the same walk and signature a
    /// connection gets: `ssh` here is this app's child.
    private func thisApp() throws -> AppSigner {
        let path = { (pid: pid_t) -> String? in
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
        }
        let peer = AgentPeer.walk(from: getpid(), path: path, parent: { pid in
            var information = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &information, size) == size ? pid_t(information.pbi_ppid) : nil
        })
        return try XCTUnwrap(peer.appProcess.flatMap(AppSigner.of), "the app above this test has no signature to match")
    }

    private func givePass(to agent: SSHAgent, over door: Door, knowing hosts: Set<Data> = []) throws {
        door.passes.knownHosts = { hosts }
        let held = try agent.passKeys.map { key -> AgentPass.Held in
            let fixture = try XCTUnwrap(AgentFixture.all.first { $0.key.blob == key.blob })
            return (key, try XCTUnwrap(PrivateHalf(fixture.key.text)))
        }
        XCTAssertNotNil(door.passes.give(held, appName: AppInfo.name, signer: try thisApp(), for: .oneHour))
    }

    /// A folder with the key's public half and the bytes to sign, so the
    /// only way to a signature is the agent.
    private func signing(_ name: String, _ key: AgentFixture.Key) throws -> (publicKey: URL, message: URL, allowed: URL) {
        let folder = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let publicKey = folder.appendingPathComponent("key.pub")
        try key.publicLine.write(to: publicKey, atomically: true, encoding: .utf8)
        let message = folder.appendingPathComponent("message")
        try Data("signed through the agent\n".utf8).write(to: message)
        let allowed = folder.appendingPathComponent("allowed")
        try "invented@oripass \(key.publicLine)".write(to: allowed, atomically: true, encoding: .utf8)
        return (publicKey, message, allowed)
    }

    /// A commit's signature, for every kind of key: `-n git` with the store
    /// locked, nobody asked and no private half on disk, and the real
    /// `ssh-keygen -Y verify` takes it.
    func testSshKeygenSignsUnderGitThroughAPassOverAShutVaultAndVerifies() async throws {
        let (agent, door) = await open()
        try givePass(to: agent, over: door)
        await door.store.lock()
        XCTAssertEqual(door.store.state, .locked)
        for (name, key) in AgentFixture.all {
            let files = try signing(name, key)
            let signed = try await run("/usr/bin/ssh-keygen", ["-Y", "sign", "-n", "git", "-f", files.publicKey.path, files.message.path])
            XCTAssertEqual(signed.status, 0, "\(name): \(signed.out)")
            let checked = try await run("/usr/bin/ssh-keygen", ["-Y", "verify", "-n", "git", "-f", files.allowed.path,
                                                                "-I", "invented@oripass",
                                                                "-s", files.message.appendingPathExtension("sig").path],
                                        input: Data("signed through the agent\n".utf8))
            XCTAssertEqual(checked.status, 0, "\(name): \(checked.out)")
        }
        XCTAssertEqual(door.store.state, .locked, "nothing opened the vault")
        XCTAssertTrue(authoriser.asked.isEmpty)
        XCTAssertTrue(stage.shown.isEmpty)
        XCTAssertEqual(door.passes.standing.first?.commits, AgentFixture.all.count)
        XCTAssertEqual(door.passes.standing.first?.logins, 0)
    }

    /// The whole of it: `git commit -S` as this Mac is set up to run it, and
    /// `git verify-commit` agrees.
    func testGitCommitsThroughAPassOverAShutVault() async throws {
        let (agent, door) = await open()
        try givePass(to: agent, over: door)
        await door.store.lock()
        let files = try signing("git", AgentFixture.ed25519)
        let repository = directory.appendingPathComponent("repository").path
        let settings = ["-C", repository, "-c", "gpg.format=ssh", "-c", "gpg.ssh.program=/usr/bin/ssh-keygen",
                        "-c", "user.signingkey=\(files.publicKey.path)", "-c", "user.name=invented",
                        "-c", "user.email=invented@oripass", "-c", "gpg.ssh.allowedSignersFile=\(files.allowed.path)"]
        let made = try await run("/usr/bin/git", ["init", "-q", repository])
        XCTAssertEqual(made.status, 0, made.out)
        let commit = try await run("/usr/bin/git", settings + ["commit", "-q", "-S", "--allow-empty", "-m", "a commit"])
        XCTAssertEqual(commit.status, 0, commit.out)
        let tag = try await run("/usr/bin/git", settings + ["tag", "-s", "-m", "a tag", "v1"])
        XCTAssertEqual(tag.status, 0, tag.out)
        let verified = try await run("/usr/bin/git", settings + ["verify-commit", "HEAD"])
        XCTAssertEqual(verified.status, 0, verified.out)
        XCTAssertTrue(verified.out.contains("Good \"git\" signature"), verified.out)
        let verifiedTag = try await run("/usr/bin/git", settings + ["verify-tag", "v1"])
        XCTAssertEqual(verifiedTag.status, 0, verifiedTag.out)
        XCTAssertEqual(door.store.state, .locked)
        XCTAssertTrue(authoriser.asked.isEmpty)
        XCTAssertEqual(door.passes.standing.first?.commits, 2)
    }

    /// Any other namespace is no commit. A pass with the app and the key
    /// right and nobody at the Mac: the card comes up, and nobody answers.
    func testAnotherNamespaceIsAskedThroughAPass() async throws {
        let (agent, door) = await open(patience: 1)
        try givePass(to: agent, over: door)
        authoriser.answer = false
        let files = try signing("file", AgentFixture.ed25519)
        let signed = try await run("/usr/bin/ssh-keygen", ["-Y", "sign", "-n", "file", "-f", files.publicKey.path, files.message.path])
        XCTAssertNotEqual(signed.status, 0, signed.out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.message.appendingPathExtension("sig").path))
        XCTAssertEqual(authoriser.asked, [.sign], "it went to the question")
        XCTAssertEqual(door.passes.standing.first?.signatures, 0)
    }

    /// `known_hosts` as `ssh-keygen -H` leaves it, names hashed, for a host
    /// the pass may log in to.
    private func hashedKnownHosts(of hostKey: URL) async throws -> Set<Data> {
        let line = try String(contentsOf: hostKey.appendingPathExtension("pub"))
        let file = directory.appendingPathComponent("known_hosts")
        try "alpen \(line)".write(to: file, atomically: true, encoding: .utf8)
        let hashed = try await run("/usr/bin/ssh-keygen", ["-q", "-H", "-f", file.path])
        XCTAssertEqual(hashed.status, 0, hashed.out)
        let written = try String(contentsOf: file)
        XCTAssertTrue(written.hasPrefix("|1|"), written)
        XCTAssertFalse(written.contains("alpen"), written)
        return KnownHosts.read(file)
    }

    /// A real login, with the store locked and nobody asked: the session is
    /// a real one, bound by a real `ssh`, for a host whose key stands in a
    /// hashed `known_hosts`.
    func testSshAuthenticatesToAKnownServerThroughAPassOverAShutVault() async throws {
        let (agent, door) = await open()
        let (hostKey, _, configuration) = try await server(authorising: AgentFixture.ed25519)
        try givePass(to: agent, over: door, knowing: try await hashedKnownHosts(of: hostKey))
        await door.store.lock()
        XCTAssertEqual(door.store.state, .locked)

        let said = try await login(with: configuration)
        XCTAssertTrue(said.out.contains("Accepted publickey"), said.out)
        XCTAssertTrue(said.out.contains(SSHFingerprint(of: AgentFixture.ed25519.blob)), said.out)
        XCTAssertEqual(door.store.state, .locked, "nothing opened the vault")
        XCTAssertTrue(authoriser.asked.isEmpty)
        XCTAssertTrue(stage.shown.isEmpty)
        XCTAssertEqual(door.passes.standing.first?.logins, 1)
    }

    /// A server never seen: over a shut vault nothing is at the socket to
    /// open it, so the login fails.
    func testAServerNeverSeenDoesNotLogInOverAShutVault() async throws {
        let (agent, door) = await open(patience: 1)
        let (_, _, configuration) = try await server(authorising: AgentFixture.ed25519)
        var other = Data()
        other.appendCounted(Data("ssh-ed25519".utf8))
        other.appendCounted(Data(repeating: 9, count: 32))
        try givePass(to: agent, over: door, knowing: [other])
        await door.store.lock()

        let said = try await login(with: configuration)
        XCTAssertFalse(said.out.contains("Accepted publickey"), said.out)
        XCTAssertEqual(door.passes.standing.first?.signatures, 0)
    }

    /// Why the file is read once, as the pass is given: this `ssh` has
    /// written the stranger to it by the time it asks to sign.
    func testAcceptNewWritesTheFileBeforeTheSignatureAndIsStillAStranger() async throws {
        let (agent, door) = await open(patience: 1)
        let (_, _, configuration) = try await server(authorising: AgentFixture.ed25519)
        let file = directory.appendingPathComponent("accepted")
        try Data().write(to: file)
        try givePass(to: agent, over: door)
        door.passes.knownHosts = { KnownHosts.read(file) }
        await door.store.lock()

        let said = try await login(with: configuration, hosts: file)
        XCTAssertFalse(said.out.contains("Accepted publickey"), said.out)
        XCTAssertFalse(KnownHosts.read(file).isEmpty, "ssh wrote it, and the pass did not take it")
        XCTAssertEqual(door.passes.standing.first?.signatures, 0)
    }

    /// A server never seen is the card's, and a yes makes it known: the
    /// second login is the pass's, over a shut vault.
    func testAFingerMakesAServerKnownToThePass() async throws {
        let (agent, door) = await open()
        let (_, hostBlob, configuration) = try await server(authorising: AgentFixture.ed25519)
        try givePass(to: agent, over: door)
        let first = try await login(with: configuration)
        XCTAssertTrue(first.out.contains("Accepted publickey"), first.out)
        XCTAssertEqual(authoriser.asked, [.sign])
        XCTAssertEqual(stage.shown.last?.host, SSHFingerprint(of: hostBlob))
        XCTAssertEqual(door.passes.standing.first?.logins, 0)

        await door.store.lock()
        let second = try await login(with: configuration)
        XCTAssertTrue(second.out.contains("Accepted publickey"), second.out)
        XCTAssertEqual(authoriser.asked, [.sign])
        XCTAssertEqual(door.passes.standing.first?.logins, 1)
    }

    /// A throwaway server: its host key, a file naming `key` and the
    /// configuration for `sshd -i`.
    private func server(authorising key: AgentFixture.Key) async throws -> (hostKey: URL, hostBlob: Data, configuration: URL) {
        let hostKey = directory.appendingPathComponent("host")
        let made = try await run("/usr/bin/ssh-keygen", ["-q", "-N", "", "-t", "ed25519", "-f", hostKey.path])
        XCTAssertEqual(made.status, 0, made.out)
        let hostLine = try String(contentsOf: hostKey.appendingPathExtension("pub"))
        let hostBlob = try XCTUnwrap(Data(base64Encoded: String(hostLine.split(separator: " ")[1])))
        let authorised = directory.appendingPathComponent("authorised")
        try key.publicLine.write(to: authorised, atomically: true, encoding: .utf8)
        let configuration = directory.appendingPathComponent("sshd")
        try """
        HostKey \(hostKey.path)
        PidFile \(directory.appendingPathComponent("pid").path)
        AuthorizedKeysFile \(authorised.path)
        StrictModes no
        UsePAM no
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        PermitUserRC no

        """.write(to: configuration, atomically: true, encoding: .utf8)
        return (hostKey, hostBlob, configuration)
    }

    /// With `hosts`, as a careless `ssh` does it: what it has not seen goes
    /// into that file, and it carries on.
    private func login(with configuration: URL, hosts: URL? = nil) async throws -> (status: Int32, out: String) {
        try await run("/usr/bin/ssh", [
            // `ssh` finds the home directory from the system and not from
            // `HOME`, so its own identities are named away here, or it
            // would go looking in `~/.ssh`.
            "-F", "/dev/null", "-o", "IdentityFile=none", "-o", "IdentityAgent=\(socket.path)", "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=\(hosts == nil ? "no" : "accept-new")",
            "-o", "UserKnownHostsFile=\(hosts?.path ?? "/dev/null")",
            "-o", "GlobalKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
            "-o", "ProxyCommand=/usr/sbin/sshd -i -e -f \(configuration.path)", "localhost", "true",
        ])
    }

    /// What `ssh` really sends: `session-bind` over a real key exchange,
    /// a signature over a real session, and a server that takes it. macOS's
    /// `sshd` will not open an audit session for a peer with no address, so
    /// it hangs up straight after it has logged the login, and that line is
    /// what is read.
    func testSshAuthenticatesToARealServerThroughTheAgent() async throws {
        _ = await open()
        let (_, hostBlob, configuration) = try await server(authorising: AgentFixture.p384)
        let said = try await login(with: configuration)
        XCTAssertTrue(said.out.contains("Accepted publickey"), said.out)
        XCTAssertTrue(said.out.contains(SSHFingerprint(of: AgentFixture.p384.blob)), said.out)
        XCTAssertEqual(authoriser.asked, [.sign])
        let question = try XCTUnwrap(stage.shown.last)
        XCTAssertEqual(question.host, SSHFingerprint(of: hostBlob), "session-bind named the server")
        XCTAssertEqual(question.destination, "localhost", "read from the real ssh, past its nine options")
        XCTAssertFalse(question.isForwarded)
        XCTAssertEqual(question.peer.names.first, "ssh")
    }

    func testTheSwitchOffTakesTheFileAndOnBringsItBack() async throws {
        let (agent, _) = await open()
        var choices = SSHChoices()
        agent.follow(choices)
        XCTAssertFalse(agent.isOpen)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket.path))
        XCTAssertFalse(Instruments.live.contains { $0.owner == "SSHAgent" })
        choices.isOn = true
        agent.follow(choices)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket.path))
        XCTAssertEqual(Instruments.live.filter { $0.owner == "SSHAgent" }.map(\.name), ["listener"])
    }

    func testASocketThatCannotBeMadeIsSaidSo() async {
        let store = VaultStore(backend: DemoVault.backend())
        let long = directory.appendingPathComponent(String(repeating: "x", count: 120))
        let agent = SSHAgent(door: Door(store: store, isInFront: { false }), authoriser: nil, path: long)
        var choices = SSHChoices()
        choices.isOn = true
        agent.follow(choices)
        XCTAssertFalse(agent.isOpen)
        XCTAssertEqual(agent.problem, SSHAgent.unopened)
        choices.isOn = false
        agent.follow(choices)
        XCTAssertNil(agent.problem)
    }

    func testALockLeavesTheSocketStandingAndCounted() async throws {
        let (agent, door) = await open()
        await door.store.lock()
        XCTAssertTrue(agent.isOpen)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket.path))
        XCTAssertEqual(Instruments.live.filter { $0.owner == "SSHAgent" }.map(\.name), ["listener"])
        // With no seal the list fails, the way OpenSSH hears it.
        let said = try await run("/usr/bin/ssh-add", ["-L"])
        XCTAssertNotEqual(said.status, 0, said.out)
    }

    /// What an install, `make run` and the canary ask before they quit the
    /// app, since a pass is in its memory alone.
    func testTheScriptThatQuitsTheAppStopsWhileAPassStands() async throws {
        let (agent, door) = await open()
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/passes.sh").path
        let before = try await run(script, [socket.path])
        XCTAssertEqual(before.status, 0, before.out)
        try givePass(to: agent, over: door)
        await door.store.lock()
        let standing = try await run(script, [socket.path])
        XCTAssertEqual(standing.status, 1)
        XCTAssertTrue(standing.out.contains("holding an SSH pass"), standing.out)
        XCTAssertEqual(door.store.state, .locked, "the question opened nothing")
        XCTAssertTrue(authoriser.asked.isEmpty)
        XCTAssertTrue(stage.shown.isEmpty)
        door.passes.endAll()
        let after = try await run(script, [socket.path])
        XCTAssertEqual(after.status, 0, after.out)
    }

    func testAPeerIsNamedFromTheSystem() async throws {
        _ = await open()
        let end = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(end) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let written = Array(socket.path.utf8CString).map { UInt8(bitPattern: $0) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: written) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(end, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        // The test's host is both ends, and an app, so the chain is one long.
        let peer = AgentPeer.of(end)
        XCTAssertEqual(peer.names, [AppInfo.name])
        XCTAssertTrue(peer.app.hasSuffix("\(AppInfo.name).app"), peer.app)
    }
}
