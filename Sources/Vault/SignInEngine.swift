import Foundation

/// Where the account lives: one of Bitwarden's two servers, or his own.
enum SignInServer: Equatable {
    case com, eu
    /// An address as he typed it.
    case own(String)

    /// What the engine is told. `https://bitwarden.com` is the name the CLI
    /// takes for "the default again", which is how a server set by an earlier
    /// attempt is unset.
    var address: String {
        switch self {
        case .com: return "https://bitwarden.com"
        case .eu: return "https://vault.bitwarden.eu"
        case .own(let typed):
            // A bare name is taken to be `https`. One that says `http` is
            // left as it is, to be refused in so many words.
            let address = typed.trimmingCharacters(in: .whitespaces)
            return address.contains("://") || address.isEmpty ? address : "https://\(address)"
        }
    }

    /// The server as a sentence names it.
    var host: String {
        switch self {
        case .com: return "bitwarden.com"
        case .eu: return "bitwarden.eu"
        case .own: return URL(string: address)?.host ?? address
        }
    }
}

/// The ways of a second step the CLI can do, by Bitwarden's own numbers for
/// them. A passkey and Duo are not among them (`docs/notes.md`).
enum SecondStep: Int, CaseIterable, Equatable {
    case authenticator = 0
    case email = 1
    case securityKey = 3
}

enum SignInCredentials {
    case password(email: String, password: SecretBytes)
    /// The personal API key from the web vault. It signs in and opens
    /// nothing: the master password is still what unlocks.
    case apiKey(id: String, secret: SecretBytes)
}

struct SignInRequest {
    var server: SignInServer
    var credentials: SignInCredentials
    /// Named only after the engine has asked which.
    var method: SecondStep?
}

/// What a code is for.
enum SignInCode: Equatable {
    /// Two-step login. The method is nil when the account has one and the
    /// engine did not say which.
    case secondStep(SecondStep?)
    /// The code Bitwarden emails the first time a device signs in to an
    /// account that has no two-step login.
    case newDevice
}

enum SignInRefusal: Equatable {
    /// The email and the password do not open an account on this server.
    case credentials
    case notAnEmail
    case code
    /// The account's second step is one the CLI cannot do.
    case noMethod
    case apiKey
    /// An organisation's API key, which the CLI does not take.
    case organisationKey
    /// The address is not `https`.
    case insecureServer
    case unreachable
    case noCLI
    case timeout
    /// The engine's own sentence, for what this app has no words for.
    case other(String)
}

enum SignInAnswer: Equatable {
    case signedIn
    /// The account has more than one way of a second step. Nothing is
    /// running: `begin` is called again with one of them named.
    case needsMethod([SecondStep])
    /// The engine is waiting for `answer(code:)`.
    case needsCode(SignInCode)
    case refused(SignInRefusal)
}

/// Whoever signs an account in. `bw` stands behind it (`BwSignIn`), and a
/// fake in the shots. It is beside `VaultBackend` and not in it because a
/// sign-in is a conversation, with a question in the middle that only some
/// accounts are asked, and everything in `VaultBackend` is one call.
///
/// The password and the API key's secret belong to the caller, who may need
/// them for a second `begin` and wipes them when the sheet is done. A code is
/// wiped by `answer` before it returns.
@MainActor
protocol SignInEngine: AnyObject {
    func begin(_ request: SignInRequest) async -> SignInAnswer
    func answer(code: SecretBytes) async -> SignInAnswer
    /// Stops whatever is running or waiting.
    func cancel() async
}

/// An engine that answers from a list, for the shots and for the tests of
/// the sheet's own model.
@MainActor
final class FakeSignIn: SignInEngine {
    /// Handed out in order, one for each `begin` and each `answer`.
    var answers: [SignInAnswer]
    private(set) var requests: [SignInRequest] = []
    private(set) var codes = 0
    private(set) var cancels = 0

    init(_ answers: [SignInAnswer] = []) {
        self.answers = answers
    }

    private func next() -> SignInAnswer {
        answers.isEmpty ? .refused(.timeout) : answers.removeFirst()
    }

    func begin(_ request: SignInRequest) async -> SignInAnswer {
        requests.append(request)
        return next()
    }

    func answer(code: SecretBytes) async -> SignInAnswer {
        code.wipe()
        codes += 1
        return next()
    }

    func cancel() async {
        cancels += 1
    }
}
