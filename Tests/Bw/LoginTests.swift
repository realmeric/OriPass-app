import XCTest
@testable import OriPass

/// Signing in, against a stand-in `bw` that says what the real one was
/// recorded saying (`Tests/Fixtures/login-recorded.json`, from
/// `scripts/spike-login.py`). Each sentence has to land the sheet on the
/// right step with the right words, and nothing typed may be in an argument.
@MainActor
final class LoginTests: XCTestCase {
    private static let password = "CANARY-login-password"
    private static let code = "271828"
    private static let secret = "CANARY-login-client-secret"

    private var kept: [StandIn] = []

    private func engine(_ options: [String: Any] = [:],
                        patience: TimeInterval = 20) throws -> (StandIn, BwSignIn) {
        let standIn = try StandIn(options.merging([
            "loggedOut": true, "password": Self.password, "code": Self.code, "clientSecret": Self.secret,
        ]) { asked, _ in asked })
        kept.append(standIn)
        return (standIn, BwSignIn(preferredPath: standIn.binary.path, runDirectory: standIn.run,
                                  dataDirectory: standIn.data, patience: patience))
    }

    private func request(_ who: String, password: String = LoginTests.password,
                         server: SignInServer = .com, method: SecondStep? = nil) -> SignInRequest {
        SignInRequest(server: server,
                      credentials: .password(email: "\(who)@example.invalid", password: SecretBytes(password)),
                      method: method)
    }

    /// The stand-ins still running a login out of this directory.
    private func logins(of standIn: StandIn) -> Int {
        let pgrep = Process()
        let found = Pipe()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "\(standIn.binary.path) login"]
        pgrep.standardOutput = found
        try? pgrep.run()
        pgrep.waitUntilExit()
        return String(decoding: found.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").count
    }

    private func assertNothingTypedIsAnArgument(_ standIn: StandIn, file: StaticString = #filePath,
                                                line: UInt = #line) {
        let words = standIn.arguments.joined()
        XCTAssertFalse(words.isEmpty, "the stand-in was never started", file: file, line: line)
        for typed in [Self.password, Self.code, Self.secret, "wrong-password", "000000"] {
            XCTAssertFalse(words.contains { $0.contains(typed) },
                           "\(typed) was an argument", file: file, line: line)
        }
    }

    // MARK: What the words mean

    private func recorded(_ name: String) throws -> String {
        try XCTUnwrap(Fixture.json("login-recorded")[name]?["message"]?.string)
    }

    func testEveryRecordedSentenceIsARefusalThisAppHasWordsFor() throws {
        let expected: [(String, Bool, SignInRefusal)] = [
            ("wrong-password", false, .credentials),
            ("email-invalid", false, .notAnEmail),
            ("no-providers", false, .noMethod),
            ("code-required", false, .code),
            ("bad-code", true, .code),
            ("bad-device-code", true, .code),
            ("client-id-required", false, .apiKey),
            ("apikey-wrong", false, .apiKey),
            ("apikey-organisation", false, .organisationKey),
            ("insecure", false, .insecureServer),
            ("unreachable", false, .unreachable),
        ]
        for (name, afterCode, refusal) in expected {
            XCTAssertEqual(LoginTranscript.refusal(for: try recorded(name), afterCode: afterCode),
                           refusal, name)
            XCTAssertFalse(SignIn.sentence(for: refusal, on: .eu).isEmpty)
        }
        // What nothing here knows is shown as the CLI said it.
        XCTAssertEqual(LoginTranscript.refusal(for: try recorded("no-provider-selected"), afterCode: false),
                       .other("Login failed. No provider selected."))
        XCTAssertTrue(LoginTranscript.meansSignedIn(try recorded("already")))
        XCTAssertTrue(LoginTranscript.meansSignedIn(try recorded("logout-required")))
        XCTAssertFalse(LoginTranscript.meansSignedIn(try recorded("wrong-password")))
    }

    func testAQuestionIsReadOffStandardErrorAndItsEchoIsNotASecondQuestion() {
        let noise = "Unable to fetch ServerConfig from https://x/api ErrorResponse {\n  statusCode: 404\n}\n"
        XCTAssertNil(LoginTranscript.question(in: noise, answered: []))
        XCTAssertEqual(LoginTranscript.question(in: noise + "? Two-step login code: ", answered: []), .code)
        XCTAssertNil(LoginTranscript.question(in: "? Two-step login code: \n? Two-step login code: 271828\n",
                                              answered: [.secondStep]))
        XCTAssertEqual(LoginTranscript.question(
            in: "? New device verification required. Enter OTP sent to login email: ", answered: []
        ), .deviceCode)
        let list = "? Two-step login method: (Use arrow keys)\n❯ Authenticator App \n  Yubico OTP Security Key \n  Email \n  ──────────────\n  Cancel "
        XCTAssertEqual(LoginTranscript.question(in: list, answered: []),
                       .method([.authenticator, .securityKey, .email]))
        // Half a list is not a list yet.
        XCTAssertNil(LoginTranscript.question(in: "? Two-step login method: (Use arrow keys)\n❯ Authen",
                                              answered: []))
        XCTAssertEqual(LoginTranscript.question(in: "? Email address: ", answered: []),
                       .unknown("Email address:"))
    }

    // MARK: The engine, against the stand-in

    func testTheRightPasswordSignsInAndIsNobodysArgument() async throws {
        let (standIn, engine) = try engine()
        let answer = await engine.begin(request("plain", server: .eu))
        XCTAssertEqual(answer, .signedIn)
        XCTAssertEqual(standIn.arguments, [
            ["config", "server", "https://vault.bitwarden.eu", "--response"],
            ["login", "plain@example.invalid", "--passwordenv", BwSignIn.passwordName, "--response"],
        ])
        assertNothingTypedIsAnArgument(standIn)
        XCTAssertNil(engine.child)
        XCTAssertEqual(logins(of: standIn), 0)

        // There is an account now, and the vault is shut.
        let backend = ServeBackend(preferredPath: standIn.binary.path, runDirectory: standIn.run,
                                   dataDirectory: standIn.data)
        let status = try await backend.status()
        XCTAssertEqual(status.state, .locked)
    }

    func testAWrongPasswordIsRefusedInWordsThatNameTheServer() async throws {
        let (standIn, engine) = try engine()
        let answer = await engine.begin(request("plain", password: "wrong-password", server: .eu))
        XCTAssertEqual(answer, .refused(.credentials))
        XCTAssertEqual(SignIn.sentence(for: .credentials, on: .eu),
                       "That email and master password do not open an account on bitwarden.eu.")
        assertNothingTypedIsAnArgument(standIn)
    }

    func testTheServerIsSaidOnceAndTheDefaultIsSaidByItsName() async throws {
        let (standIn, engine) = try engine()
        _ = await engine.begin(request("plain", password: "wrong-password"))
        _ = await engine.begin(request("plain", password: "wrong-password"))
        _ = await engine.begin(request("plain", password: "wrong-password", server: .own("vault.example.invalid")))
        XCTAssertEqual(standIn.arguments.filter { $0.first == "config" }, [
            ["config", "server", "https://bitwarden.com", "--response"],
            ["config", "server", "https://vault.example.invalid", "--response"],
        ])
        XCTAssertEqual(standIn.arguments.filter { $0.first == "login" }.count, 3)
    }

    func testAnAddressThatIsNotHTTPSIsRefusedBeforeAnythingStarts() async throws {
        let (standIn, engine) = try engine()
        let answer = await engine.begin(request("plain", server: .own("http://vault.example.invalid")))
        XCTAssertEqual(answer, .refused(.insecureServer))
        XCTAssertTrue(standIn.arguments.isEmpty)
    }

    func testAnEmailThatWouldReadAsAnOptionNeverReachesTheArguments() async throws {
        let (standIn, engine) = try engine()
        let answer = await engine.begin(SignInRequest(
            server: .com, credentials: .password(email: "--apikey@x", password: SecretBytes(Self.password))
        ))
        XCTAssertEqual(answer, .refused(.notAnEmail))
        XCTAssertTrue(standIn.arguments.isEmpty)
    }

    func testOneWayOfASecondStepAsksForItsCodeAndTheCodeGoesDownThePipe() async throws {
        let (standIn, engine) = try engine()
        let asked = await engine.begin(request("authenticator"))
        XCTAssertEqual(asked, .needsCode(.secondStep(nil)))
        // It is sitting at its question, and `ps` shows nothing typed.
        let pid = try XCTUnwrap(engine.child?.pid)
        let seen = try XCTUnwrap(ProcessArguments.of(pid))
        XCTAssertFalse(seen.contains { $0.contains(Self.password) })

        let code = SecretBytes(Self.code)
        let answer = await engine.answer(code: code)
        XCTAssertEqual(answer, .signedIn)
        XCTAssertTrue(code.isWiped)
        assertNothingTypedIsAnArgument(standIn)
        XCTAssertFalse(standIn.arguments.joined().contains("--code"))
        XCTAssertEqual(logins(of: standIn), 0)
    }

    func testAWrongCodeIsRefusedAsACode() async throws {
        let (standIn, engine) = try engine()
        _ = await engine.begin(request("authenticator"))
        let answer = await engine.answer(code: SecretBytes("000000"))
        XCTAssertEqual(answer, .refused(.code))
        assertNothingTypedIsAnArgument(standIn)
        XCTAssertNil(engine.child)
    }

    func testTwoWaysOfASecondStepAreOfferedAndTheChildAtItsListIsKilled() async throws {
        let (standIn, engine) = try engine()
        let asked = await engine.begin(request("both"))
        XCTAssertEqual(asked, .needsMethod([.authenticator, .email]))
        XCTAssertNil(engine.child)
        let gone = await eventually(within: 3) { self.logins(of: standIn) == 0 }
        XCTAssertTrue(gone, "the child was left at its list")

        let again = await engine.begin(request("both", method: .email))
        XCTAssertEqual(again, .needsCode(.secondStep(.email)))
        XCTAssertEqual(standIn.arguments.last, [
            "login", "both@example.invalid", "--passwordenv", BwSignIn.passwordName,
            "--response", "--method", "1",
        ])
        let answer = await engine.answer(code: SecretBytes(Self.code))
        XCTAssertEqual(answer, .signedIn)
        assertNothingTypedIsAnArgument(standIn)
    }

    func testANewDeviceIsAskedForTheEmailedCode() async throws {
        let (standIn, engine) = try engine()
        let asked = await engine.begin(request("device"))
        XCTAssertEqual(asked, .needsCode(.newDevice))
        let answer = await engine.answer(code: SecretBytes(Self.code))
        XCTAssertEqual(answer, .signedIn)
        assertNothingTypedIsAnArgument(standIn)

        let (_, second) = try self.engine()
        _ = await second.begin(request("device"))
        let refused = await second.answer(code: SecretBytes("000000"))
        XCTAssertEqual(refused, .refused(.code))
    }

    func testASecondStepTheCLICannotDoPointsAtTheAPIKey() async throws {
        let (_, engine) = try engine()
        let answer = await engine.begin(request("keyonly"))
        XCTAssertEqual(answer, .refused(.noMethod))
    }

    func testAnAPIKeySignsInFromTheEnvironment() async throws {
        let (standIn, engine) = try engine()
        let wrong = await engine.begin(SignInRequest(
            server: .com, credentials: .apiKey(id: "user.1f0e", secret: SecretBytes("wrong-password"))
        ))
        XCTAssertEqual(wrong, .refused(.apiKey))
        let organisation = await engine.begin(SignInRequest(
            server: .com, credentials: .apiKey(id: "organization.1f0e", secret: SecretBytes(Self.secret))
        ))
        XCTAssertEqual(organisation, .refused(.organisationKey))
        let right = await engine.begin(SignInRequest(
            server: .com, credentials: .apiKey(id: "user.1f0e", secret: SecretBytes(Self.secret))
        ))
        XCTAssertEqual(right, .signedIn)
        XCTAssertEqual(standIn.arguments.last, ["login", "--apikey", "--response"])
        XCTAssertFalse(standIn.arguments.joined().contains { $0.contains("1f0e") })
        assertNothingTypedIsAnArgument(standIn)
    }

    func testAServerThatDoesNotAnswerIsSaidToBeUnreachable() async throws {
        let (_, engine) = try engine(["unreachable": true])
        let answer = await engine.begin(request("plain"))
        XCTAssertEqual(answer, .refused(.unreachable))
        XCTAssertEqual(SignIn.sentence(for: .unreachable, on: .own("vault.example.invalid")),
                       "vault.example.invalid did not answer. Check the address and the connection.")
    }

    func testAnAccountAlreadyHereCountsAsSignedIn() async throws {
        let (_, engine) = try engine(["loggedOut": false])
        let answer = await engine.begin(request("plain"))
        XCTAssertEqual(answer, .signedIn)
    }

    func testAChildThatSaysNothingIsStoppedAndGone() async throws {
        let (standIn, engine) = try engine(["silent": true], patience: 0.6)
        let answer = await engine.begin(request("plain"))
        XCTAssertEqual(answer, .refused(.timeout))
        let gone = await eventually(within: 3) { self.logins(of: standIn) == 0 }
        XCTAssertTrue(gone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: standIn.run.appendingPathComponent("login.pid").path))
    }

    func testCancelKillsAChildWaitingForItsCode() async throws {
        let (standIn, engine) = try engine()
        _ = await engine.begin(request("authenticator"))
        XCTAssertEqual(logins(of: standIn), 1)
        await engine.cancel()
        let gone = await eventually(within: 3) { self.logins(of: standIn) == 0 }
        XCTAssertTrue(gone, "cancel left the child at its question")
        let late = await engine.answer(code: SecretBytes(Self.code))
        XCTAssertEqual(late, .refused(.other("")))
    }

    func testNoBinaryIsSaidSo() async {
        // No fallback and an empty PATH: there is no `bw` here whatever this
        // Mac has, and nothing is started.
        let engine = BwSignIn(preferredPath: "/nowhere/bw",
                              finder: { BwBinary.find(preferred: $0, fallback: nil, path: "") },
                              runDirectory: URL(fileURLWithPath: "/tmp/op-none"),
                              dataDirectory: URL(fileURLWithPath: "/tmp/op-none"))
        let answer = await engine.begin(request("plain"))
        XCTAssertEqual(answer, .refused(.noCLI))
    }

    // MARK: The sheet, over the engine and the stand-in

    /// Every recorded way a login can go, through the model the sheet draws
    /// from: the step it lands on and the sentence under it.
    func testEveryWayALoginGoesLandsOnTheRightStepWithTheRightWords() async throws {
        struct Way {
            let who: String
            var password = LoginTests.password
            var server = SignInServer.com
            var options: [String: Any] = [:]
            let step: SignIn.Step
            let words: String?
        }
        let ways = [
            Way(who: "plain", password: "wrong-password", step: .form,
                words: "That email and master password do not open an account on bitwarden.com."),
            Way(who: "authenticator", step: .code(.secondStep(nil)), words: nil),
            Way(who: "emailed", step: .code(.secondStep(nil)), words: nil),
            Way(who: "both", step: .method([.authenticator, .email]), words: nil),
            Way(who: "device", step: .code(.newDevice), words: nil),
            Way(who: "keyonly", step: .form,
                words: "This account's two-step login is a passkey or Duo, which the command line tool cannot do. An API key signs in without it."),
            Way(who: "plain", server: .own("http://vault.example.invalid"), step: .form,
                words: "The server's address has to start with https://."),
            Way(who: "plain", options: ["unreachable": true], step: .form,
                words: "bitwarden.com did not answer. Check the address and the connection."),
        ]
        for way in ways {
            let (standIn, engine) = try engine(way.options)
            let sheet = SignIn(engine: engine)
            await sheet.signIn(server: way.server, email: "\(way.who)@example.invalid",
                               password: SecretBytes(way.password))?.value
            XCTAssertEqual(sheet.step, way.step, way.who)
            XCTAssertEqual(sheet.refusal, way.words, way.who)
            XCTAssertFalse(sheet.isWorking)
            if way.who == "keyonly" { XCTAssertTrue(sheet.usesAPIKey) }
            sheet.close()
            await engine.cancel()
            XCTAssertEqual(logins(of: standIn), 0, way.who)
        }
    }

    func testARefusedCodeStaysOnTheCodeWithAChildReadyForTheNextOne() async throws {
        let (standIn, engine) = try engine()
        var handed: SecretBytes?
        let sheet = SignIn(engine: engine) { handed = $0 }
        await sheet.signIn(server: .com, email: "both@example.invalid",
                           password: SecretBytes(Self.password))?.value
        await sheet.choose(.authenticator)?.value
        XCTAssertEqual(sheet.step, .code(.secondStep(.authenticator)))

        await sheet.enter(code: "000 000")?.value
        XCTAssertEqual(sheet.step, .code(.secondStep(.authenticator)))
        XCTAssertEqual(sheet.refusal, "That code was not accepted.")
        XCTAssertEqual(logins(of: standIn), 1, "no child is waiting for the next code")

        await sheet.enter(code: Self.code)?.value
        let password = try XCTUnwrap(handed, "the password was not handed on")
        XCTAssertTrue(password.matches(SecretBytes(Self.password)))
        assertNothingTypedIsAnArgument(standIn)
        XCTAssertEqual(logins(of: standIn), 0)
    }

    // MARK: The sheet's model, by itself

    func testCancelWipesThePasswordAndALateAnswerChangesNothing() async {
        let engine = FakeSignIn([.needsCode(.newDevice), .signedIn])
        var finished = false
        let sheet = SignIn(engine: engine) { _ in finished = true }
        let password = SecretBytes(Self.password)
        await sheet.signIn(server: .com, email: "deniz@example.invalid", password: password)?.value
        XCTAssertFalse(password.isWiped, "the password is needed until the sheet is done")

        let entering = sheet.enter(code: Self.code)
        sheet.close()
        await entering?.value
        XCTAssertTrue(password.isWiped)
        XCTAssertFalse(finished)
        XCTAssertFalse(sheet.isWorking)
    }

    func testAFormWithAPieceMissingSaysSoAndAsksNobody() {
        let engine = FakeSignIn()
        let sheet = SignIn(engine: engine)
        XCTAssertNil(sheet.signIn(server: .com, email: "deniz@example.invalid", password: nil))
        XCTAssertEqual(sheet.refusal, "The master password is missing.")
        let password = SecretBytes(Self.password)
        XCTAssertNil(sheet.signIn(server: .com, email: "deniz", password: password))
        XCTAssertEqual(sheet.refusal, "That is not an email address.")
        XCTAssertTrue(password.isWiped)
        XCTAssertNil(sheet.signIn(server: .com, clientID: " ", secret: SecretBytes(Self.secret)))
        XCTAssertEqual(sheet.refusal, "The API key has two parts, and one is missing.")
        XCTAssertTrue(engine.requests.isEmpty)
    }

    func testAnAPIKeyHandsNoPasswordOnAndItsSecretIsWiped() async {
        let engine = FakeSignIn([.signedIn])
        var handed: SecretBytes?? = .none
        let sheet = SignIn(engine: engine) { handed = .some($0) }
        let secret = SecretBytes(Self.secret)
        await sheet.signIn(server: .com, clientID: "user.1f0e", secret: secret)?.value
        XCTAssertEqual(handed.map { $0 == nil }, true)
        XCTAssertTrue(secret.isWiped)
    }

    // MARK: The door

    func testSigningInWithAPasswordOpensTheVaultWithIt() async throws {
        let backend = DemoVault.backend()
        backend.lastSync = Date().addingTimeInterval(-60)
        backend.isLoggedIn = false
        let store = VaultStore(backend: backend)
        await store.refresh()
        XCTAssertEqual(store.state, .loggedOut)

        let door = Door(store: store, signIn: FakeSignIn([.signedIn]))
        door.beginSignIn()
        let sheet = try XCTUnwrap(door.signIn)
        let password = SecretBytes(DemoVault.password)
        // The account exists from the moment the engine says so.
        backend.isLoggedIn = true
        await sheet.signIn(server: .com, email: backend.email, password: password)?.value

        XCTAssertNil(door.signIn, "the sheet outlived the sign-in")
        let opened = await eventually(within: 3) { store.state == .unlocked }
        XCTAssertTrue(opened)
        XCTAssertEqual(store.email, backend.email)
        XCTAssertTrue(password.isWiped)
    }

    func testTheSheetIsRaisedOnlyWhenNobodyIsSignedInAndCancelDropsIt() async throws {
        let backend = DemoVault.backend()
        let store = VaultStore(backend: backend)
        await store.refresh()
        let door = Door(store: store, signIn: FakeSignIn())
        door.beginSignIn()
        XCTAssertNil(door.signIn, "a sheet over a vault that has an account")

        backend.isLoggedIn = false
        await store.refresh()
        door.beginSignIn()
        weak var sheet = door.signIn
        XCTAssertNotNil(sheet)
        door.cancelSignIn()
        XCTAssertNil(door.signIn)
        // The engine is told to stop on the next turn.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(sheet, "the sheet's model outlived the sheet")
    }
}
