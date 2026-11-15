import Foundation

/// What the CLI's words during a login mean. Every sentence here was said by
/// `bw` 2026.9.1 to `scripts/spike-login.py` and is in `docs/notes.md`; the
/// sheet's own words for each are `SignIn.sentence`.
enum LoginTranscript {
    enum Question: Equatable {
        /// Which second step, of the ones the account has.
        case method([SecondStep])
        case code
        case deviceCode
        /// Something this app has no answer for, as the CLI put it.
        case unknown(String)
    }

    private static let methodAsked = "Two-step login method:"
    private static let codeAsked = "Two-step login code:"
    private static let deviceAsked = "New device verification required"

    /// The question the child is sitting at, if it is sitting at one.
    /// `answered` are the ones it has had its answer to: the CLI writes a
    /// question again with the answer after it, and that is no new question.
    static func question(in heard: String, answered: Set<SignInCode.Kind>) -> Question? {
        let lines = heard.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if let asked = lines.firstIndex(where: { $0.contains(methodAsked) }) {
            // The list is one write, but nothing promises it arrives as one.
            guard let end = lines[asked...].firstIndex(where: { $0.hasSuffix("Cancel") }) else {
                return nil
            }
            let offered = lines[(asked + 1)..<end].compactMap(method(named:))
            return .method(offered.isEmpty ? SecondStep.allCases : offered)
        }
        if !answered.contains(.newDevice), heard.contains(deviceAsked) { return .deviceCode }
        if !answered.contains(.secondStep), heard.contains(codeAsked) { return .code }
        let known = [methodAsked, codeAsked, deviceAsked]
        if let other = lines.first(where: { line in
            line.hasPrefix("? ") && !known.contains(where: line.contains)
        }) {
            return .unknown(String(other.dropFirst(2)))
        }
        return nil
    }

    /// A row of the CLI's list, by the name the CLI gives it.
    private static func method(named row: String) -> SecondStep? {
        if row.contains("Authenticator") { return .authenticator }
        if row.contains("Email") { return .email }
        if row.contains("Yubi") { return .securityKey }
        return nil
    }

    /// `afterCode` is whether a code had been sent. The sentence for a code
    /// that was wrong is the server's and not the CLI's, and no server has
    /// been heard to say it here, so after a code anything that calls
    /// something invalid is taken to be about the code.
    static func refusal(for message: String, afterCode: Bool) -> SignInRefusal {
        if message.hasPrefix("Invalid master password.") { return .credentials }
        if message.hasPrefix("Email address is") { return .notAnEmail }
        if message.hasPrefix("No providers available") { return .noMethod }
        if message.hasPrefix("Invalid API Key; Organization") { return .organisationKey }
        if message.hasPrefix("client_id") || message.hasPrefix("client_secret") { return .apiKey }
        if message.contains("Insecure URL not allowed") { return .insecureServer }
        if message.hasPrefix("FetchError") { return .unreachable }
        if message == "Code is required." { return .code }
        if afterCode, message.localizedCaseInsensitiveContains("invalid") { return .code }
        return .other(message)
    }

    /// Both mean an account is already here, which is what was wanted.
    static func meansSignedIn(_ message: String) -> Bool {
        message.hasPrefix("You are already logged in") || message.hasPrefix("Logout required")
    }
}

extension SignInCode {
    enum Kind: Hashable {
        case secondStep, newDevice
    }

    var kind: Kind {
        switch self {
        case .secondStep: return .secondStep
        case .newDevice: return .newDevice
        }
    }
}

/// Signing in by `bw`: `config server` when the server is not the one last
/// set, and then one `LoginChild`. Never `serve`, which does not start
/// without an account.
@MainActor
final class BwSignIn: SignInEngine {
    /// The name the password travels under in the child's environment. The
    /// name is an argument and the password is not.
    static let passwordName = "OP_MASTER_PASSWORD"

    private let preferredPath: String?
    private let finder: BwBinary.Finder
    private let runDirectory: URL
    private let dataDirectory: URL
    /// How long the child may go without asking or ending. A good login
    /// ends with a whole sync, so this is generous.
    private let patience: TimeInterval

    private(set) var child: LoginChild?
    /// The server this process last told the CLI, so a second attempt does
    /// not pay for a second `bw` to say it again.
    private var configured: String?
    private var method: SecondStep?
    private var asked: SignInCode.Kind?
    private var answered: Set<SignInCode.Kind> = []

    init(preferredPath: String? = nil, finder: @escaping BwBinary.Finder = BwBinary.standardFinder,
         runDirectory: URL = AppPaths.run,
         dataDirectory: URL = AppPaths.bwData, patience: TimeInterval = 120) {
        self.preferredPath = preferredPath
        self.finder = finder
        self.runDirectory = runDirectory
        self.dataDirectory = dataDirectory
        self.patience = patience
    }

    func begin(_ request: SignInRequest) async -> SignInAnswer {
        await cancel()
        guard let binary = finder(preferredPath) else { return .refused(.noCLI) }
        let address = request.server.address
        // The CLI saves any address and refuses the login afterwards. This
        // is the same refusal, a whole `bw` sooner.
        guard address.lowercased().hasPrefix("https://"), URL(string: address)?.host != nil else {
            return .refused(.insecureServer)
        }

        var arguments = ["login"]
        var environment: [String: String] = [:]
        var secrets: [String: SecretBytes] = [:]
        switch request.credentials {
        case .password(let email, let password):
            // A word that starts with a dash would be read as an option.
            guard email.contains("@"), !email.hasPrefix("-") else { return .refused(.notAnEmail) }
            arguments += [email, "--passwordenv", Self.passwordName]
            secrets[Self.passwordName] = password
        case .apiKey(let id, let secret):
            arguments.append("--apikey")
            environment["BW_CLIENTID"] = id
            secrets["BW_CLIENTSECRET"] = secret
        }
        arguments.append("--response")
        if let method = request.method { arguments += ["--method", String(method.rawValue)] }

        if configured != address {
            let said = await BwBinary.run(binary, ["config", "server", address, "--response"],
                                          dataDirectory: dataDirectory)
            guard said.status != -1 else { return .refused(.noCLI) }
            let verdict = try? JSONDecoder().decode(LoginChild.Verdict.self, from: Data(said.output.utf8))
            if verdict?.success != true {
                let message = verdict?.message ?? ""
                if LoginTranscript.meansSignedIn(message) { return .signedIn }
                return .refused(LoginTranscript.refusal(for: message, afterCode: false))
            }
            configured = address
        }

        let child = LoginChild(binary: binary, runDirectory: runDirectory, dataDirectory: dataDirectory)
        do {
            try child.start(arguments: arguments, environment: environment, secrets: secrets)
        } catch {
            return .refused(.noCLI)
        }
        self.child = child
        method = request.method
        Log.app.info("a sign-in started")
        return await settle(child)
    }

    func answer(code: SecretBytes) async -> SignInAnswer {
        defer { code.wipe() }
        guard let child, child.isRunning, let asked else { return .refused(.other("")) }
        answered.insert(asked)
        self.asked = nil
        child.send(code)
        return await settle(child)
    }

    func cancel() async {
        let child = self.child
        self.child = nil
        asked = nil
        answered = []
        await child?.stop()
    }

    /// Waits for the child to ask or to end. It is left running only when
    /// it is asking for a code.
    private func settle(_ child: LoginChild) async -> SignInAnswer {
        let deadline = Date().addingTimeInterval(patience)
        while Date() < deadline {
            // Cancelled from the sheet while this was waiting.
            guard self.child === child else { return .refused(.other("")) }
            if !child.isRunning {
                let verdict = child.verdict()
                let afterCode = !answered.isEmpty
                await cancel()
                guard let verdict else { return .refused(.other("")) }
                let message = verdict.message ?? ""
                if verdict.success || LoginTranscript.meansSignedIn(message) {
                    Log.app.info("a sign-in ended with an account")
                    return .signedIn
                }
                return .refused(LoginTranscript.refusal(for: message, afterCode: afterCode))
            }
            switch LoginTranscript.question(in: child.heard, answered: answered) {
            case .method(let offered)?:
                await cancel()
                return .needsMethod(offered)
            case .code?:
                asked = .secondStep
                return .needsCode(.secondStep(method))
            case .deviceCode?:
                asked = .newDevice
                return .needsCode(.newDevice)
            case .unknown(let question)?:
                await cancel()
                return .refused(.other(question))
            case nil:
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        await cancel()
        return .refused(.timeout)
    }
}
