import Combine
import Foundation

/// The sign-in sheet's model: which step it is on, what it is waiting for,
/// and the sentence under the form. It exists only while the sheet is up,
/// and it is the one thing that holds the master password between the form
/// and the vault opening, as `SecretBytes`, wiped when it is done with.
@MainActor
final class SignIn: ObservableObject {
    enum Step: Equatable {
        case form
        case method([SecondStep])
        case code(SignInCode)
    }

    @Published private(set) var step: Step = .form
    @Published private(set) var isWorking = false
    /// Why the last attempt went nowhere, in this app's words.
    @Published private(set) var refusal: String?
    /// The form asks for an API key and not for an email and a password.
    @Published var usesAPIKey = false
    /// The address a code was emailed to, for the sentence that says so.
    private(set) var email = ""

    private let engine: SignInEngine
    /// Called once, when an account is signed in, with the master password
    /// if this sheet was given one. Whoever takes it wipes it.
    private let finished: (SecretBytes?) -> Void
    private var request: SignInRequest?
    private var isOver = false
    /// Counts the attempts, so an answer that arrives after Back or Cancel
    /// is known to be about something nobody is waiting for.
    private var attempt = 0

    init(engine: SignInEngine, finished: @escaping (SecretBytes?) -> Void = { $0?.wipe() }) {
        self.engine = engine
        self.finished = finished
    }

    /// A sheet already on a step, for a shot.
    convenience init(drawn step: Step, refusal: String? = nil, isWorking: Bool = false,
                     usesAPIKey: Bool = false, email: String = "") {
        self.init(engine: FakeSignIn())
        self.step = step
        self.refusal = refusal
        self.isWorking = isWorking
        self.usesAPIKey = usesAPIKey
        self.email = email
    }

    // MARK: What the sheet does

    /// The form, with an email and the master password. `password` is nil
    /// when the field was empty.
    @discardableResult
    func signIn(server: SignInServer, email: String, password: SecretBytes?) -> Task<Void, Never>? {
        let email = email.trimmingCharacters(in: .whitespaces)
        guard !isWorking else {
            password?.wipe()
            return nil
        }
        guard let password, Self.looksLikeEmail(email) else {
            password?.wipe()
            refusal = Self.looksLikeEmail(email) ? "The master password is missing."
                : Self.sentence(for: .notAnEmail, on: server)
            return nil
        }
        self.email = email
        return start(SignInRequest(server: server, credentials: .password(email: email, password: password)))
    }

    /// The form, with an API key.
    @discardableResult
    func signIn(server: SignInServer, clientID: String, secret: SecretBytes?) -> Task<Void, Never>? {
        let id = clientID.trimmingCharacters(in: .whitespaces)
        guard !isWorking else {
            secret?.wipe()
            return nil
        }
        guard let secret, !id.isEmpty else {
            secret?.wipe()
            refusal = "The API key has two parts, and one is missing."
            return nil
        }
        return start(SignInRequest(server: server, credentials: .apiKey(id: id, secret: secret)))
    }

    @discardableResult
    func choose(_ method: SecondStep) -> Task<Void, Never>? {
        guard !isWorking, case .method = step, var request else { return nil }
        request.method = method
        self.request = request
        return run { await self.engine.begin(request) }
    }

    @discardableResult
    func enter(code: String) -> Task<Void, Never>? {
        let typed = code.filter { !$0.isWhitespace }
        guard !isWorking, case .code = step, !typed.isEmpty else { return nil }
        let code = SecretBytes(typed)
        return run { await self.engine.answer(code: code) }
    }

    /// Back to the form from a later step. The password goes: it is typed
    /// again, as it would be after any other way of not getting in.
    func startOver() {
        guard !isOver else { return }
        attempt += 1
        Task { [engine] in await engine.cancel() }
        forget()
        isWorking = false
        refusal = nil
        step = .form
    }

    /// Cancel, and the sheet going away for any other reason.
    func close() {
        guard !isOver else { return }
        isOver = true
        attempt += 1
        isWorking = false
        Task { [engine] in await engine.cancel() }
        forget()
    }

    // MARK: -

    private func start(_ request: SignInRequest) -> Task<Void, Never> {
        forget()
        self.request = request
        return run { await self.engine.begin(request) }
    }

    private func run(_ ask: @escaping () async -> SignInAnswer) -> Task<Void, Never> {
        isWorking = true
        refusal = nil
        attempt += 1
        let mine = attempt
        return Task {
            let answer = await ask()
            guard attempt == mine else { return }
            await take(answer, of: mine)
            if attempt == mine { isWorking = false }
        }
    }

    private func take(_ answer: SignInAnswer, of mine: Int) async {
        switch answer {
        case .signedIn:
            isOver = true
            let password: SecretBytes?
            if case .password(_, let typed)? = request?.credentials { password = typed } else { password = nil }
            if password == nil { forget() }
            request = nil
            finished(password)
        case .needsMethod(let offered):
            step = .method(offered)
        case .needsCode(let code):
            step = .code(code)
        case .refused(.code):
            guard case .code(let code) = step, let request else {
                fail(.code)
                return
            }
            // The child that refused the code is gone, and the next code
            // needs one sitting at its question, so it is started now. For a
            // code that comes by email this is also what sends another.
            let again = await engine.begin(request)
            guard attempt == mine else { return }
            if case .needsCode(let next) = again {
                step = .code(next)
                refusal = Self.sentence(forRefused: code)
            } else {
                await take(again, of: mine)
            }
        case .refused(let why):
            fail(why)
        }
    }

    private func fail(_ why: SignInRefusal) {
        let server = request?.server ?? .com
        forget()
        step = .form
        refusal = Self.sentence(for: why, on: server)
        // The one refusal whose way out is the other form.
        if why == .noMethod { usesAPIKey = true }
    }

    private func forget() {
        switch request?.credentials {
        case .password(_, let password)?: password.wipe()
        case .apiKey(_, let secret)?: secret.wipe()
        case nil: break
        }
        request = nil
    }

    static func looksLikeEmail(_ typed: String) -> Bool {
        typed.contains("@") && !typed.hasPrefix("-") && !typed.contains(" ")
    }

    // MARK: The sheet's own words

    static func sentence(for refusal: SignInRefusal, on server: SignInServer) -> String {
        switch refusal {
        case .credentials:
            return "That email and master password do not open an account on \(server.host)."
        case .notAnEmail:
            return "That is not an email address."
        case .code:
            return "That code was not accepted."
        case .noMethod:
            return "This account's two-step login is a passkey or Duo, which the command line tool cannot do. An API key signs in without it."
        case .apiKey:
            return "That API key was not accepted."
        case .organisationKey:
            return "That is an organisation's key. The personal one begins with the word user."
        case .insecureServer:
            return "The server's address has to start with https://."
        case .unreachable:
            return "\(server.host) did not answer. Check the address and the connection."
        case .noCLI:
            return "Bitwarden's command line tool is not where it was."
        case .timeout:
            return "Signing in took too long and was stopped."
        case .other(let said):
            return said.isEmpty ? "The command line tool stopped without saying why." : said
        }
    }

    /// Under the code field, after a code that was not taken.
    static func sentence(forRefused code: SignInCode) -> String {
        switch code {
        case .secondStep(.authenticator?), .secondStep(.securityKey?):
            return "That code was not accepted."
        case .secondStep(.email?), .secondStep(nil), .newDevice:
            return "That code was not accepted. If it came by email, another is on its way."
        }
    }

    static func title(for method: SecondStep) -> String {
        switch method {
        case .authenticator: return "Authenticator app"
        case .email: return "Email"
        case .securityKey: return "YubiKey"
        }
    }

    /// What the code step says above its field.
    func ask(for code: SignInCode) -> (title: String, more: String) {
        switch code {
        case .secondStep(.authenticator?):
            return ("Two-step login", "Enter the six digits your authenticator app shows for this account.")
        case .secondStep(.email?):
            return ("Two-step login", "Bitwarden has emailed a code to the account's address.")
        case .secondStep(.securityKey?):
            return ("Two-step login", "Click in the field and touch your YubiKey.")
        case .secondStep(nil):
            return ("Two-step login", "Enter the code from your authenticator app, or the one Bitwarden has just emailed.")
        case .newDevice:
            return ("A new device",
                    "Bitwarden has emailed a code to \(email.isEmpty ? "the account's address" : email), as it does the first time a device signs in.")
        }
    }

    deinit {
        // Not `forget()`, which is the main actor's: the bytes are wiped by
        // whoever holds the last reference, and that is here.
        switch request?.credentials {
        case .password(_, let password)?: password.wipe()
        case .apiKey(_, let secret)?: secret.wipe()
        case nil: break
        }
    }
}
