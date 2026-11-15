import Foundation

/// The conversation that signs an account in: prelogin, the master key, the
/// token, and a code when the server asks for one. It holds the master key
/// and the hash between a request and the code that answers it, and drops
/// them when it is done.
actor SignIn {
    enum Step: Equatable {
        /// An authenticator app's code, or one that was emailed.
        case code(TwoFactor)
        /// The code Bitwarden emails to an account signing in from a new
        /// device with no second step set up.
        case deviceCode
        case done
    }

    enum TwoFactor: Int, Equatable, Sendable {
        case authenticator = 0
        case email = 1
    }

    enum Failure: Error, Equatable {
        /// The server's sentence, as it said it.
        case refused(String)
        /// A second step this app cannot answer: Duo, a YubiKey, a security key.
        case unsupportedSecondStep
        /// An account whose key is not under a master password: SSO, a key
        /// connector.
        case noMasterPassword
        case unreachable
    }

    struct Opened: Sendable {
        let account: Account
        let tokens: Tokens
        let userKey: VaultKey
    }

    nonisolated let client: Client
    nonisolated let email: String
    private let password: SecretBytes
    private let keychain: Keychain
    private var kdf: Kdf?
    private var masterKey: Data?
    private var hash: String?
    private var pendingTwoFactor: TwoFactor?
    private var deviceCodeAsked = false
    private(set) var opened: Opened?

    /// The password is copied; the caller wipes its own.
    init(client: Client, email: String, password: SecretBytes, keychain: Keychain = .app) {
        self.client = client
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.password = password.copy()
        self.keychain = keychain
    }

    deinit { password.wipe() }

    func start() async throws -> Step {
        let prelogin = try await call(client.server.identity.appending(path: "accounts/prelogin/password"),
                                      json: ["email": email])
        guard prelogin.ok, let json = prelogin.json, let kdf = SignIn.kdf(in: json) else {
            throw Failure.refused(Client.sentence(in: prelogin.json) ?? "The server did not answer the prelogin.")
        }
        self.kdf = kdf
        let password = password
        let email = email
        let master = try await Task.detached(priority: .userInitiated) {
            try kdf.masterKey(password: password, email: email)
        }.value
        masterKey = master
        hash = try Kdf.serverHash(masterKey: master, password: password)
        return try await requestToken()
    }

    func submit(code: String, remember: Bool = true) async throws -> Step {
        let code = code.filter { !$0.isWhitespace }
        if let pendingTwoFactor {
            return try await requestToken(extra: ["twoFactorToken": code, "twoFactorProvider": String(pendingTwoFactor.rawValue),
                                                  "twoFactorRemember": remember ? "1" : "0"])
        }
        return try await requestToken(extra: ["newdeviceotp": code])
    }

    /// Another emailed code, for whichever of the two was asked.
    func sendCodeAgain() async throws {
        guard let hash else { return }
        if pendingTwoFactor == .email {
            _ = try await call(client.server.api.appending(path: "two-factor/send-email-login"),
                               json: ["email": email, "masterPasswordHash": hash])
        } else if deviceCodeAsked {
            _ = try await call(client.server.api.appending(path: "accounts/resend-new-device-otp"),
                               json: ["email": email, "masterPasswordHash": hash])
        }
    }

    private func requestToken(extra: [String: String] = [:]) async throws -> Step {
        guard let hash, let kdf, let masterKey else { throw Failure.unreachable }
        var form = ["scope": "api offline_access", "client_id": "mobile", "grant_type": "password",
                    "username": email, "password": hash, "deviceIdentifier": Device.identifier(in: keychain),
                    "deviceName": Device.name, "deviceType": Device.type]
        form.merge(extra) { $1 }
        let answer = try await call(client.server.identity.appending(path: "connect/token"), form: form)
        let json = answer.json ?? [:]
        if answer.status == 400 {
            if let providers = (json["TwoFactorProviders2"] ?? json["twoFactorProviders2"]) as? [String: Any] {
                let offered = Set(providers.keys.compactMap(Int.init))
                if offered.contains(TwoFactor.authenticator.rawValue) {
                    pendingTwoFactor = .authenticator
                } else if offered.contains(TwoFactor.email.rawValue) {
                    pendingTwoFactor = .email
                    if extra["twoFactorToken"] == nil { try await sendCodeAgain() }
                } else {
                    throw Failure.unsupportedSecondStep
                }
                if extra["twoFactorToken"] != nil {
                    throw Failure.refused(Client.sentence(in: json) ?? "That code was not taken.")
                }
                return .code(pendingTwoFactor!)
            }
            if (json["error"] as? String) == "device_error" {
                if extra["newdeviceotp"] != nil, deviceCodeAsked {
                    throw Failure.refused(Client.sentence(in: json) ?? "That code was not taken.")
                }
                deviceCodeAsked = true
                return .deviceCode
            }
        }
        guard answer.ok, let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String else {
            throw Failure.refused(Client.sentence(in: json) ?? "The server said no (\(answer.status)).")
        }
        guard let protected = SignIn.protectedUserKey(in: json) else { throw Failure.noMasterPassword }
        let userKey = try VaultKey(EncString(protected).decrypt(with: Kdf.stretch(masterKey)))
        let expiresIn = json["expires_in"] as? Double ?? 3600
        opened = Opened(account: Account(email: email, server: client.server, kdf: kdf, protectedUserKey: protected),
                        tokens: Tokens(access: access, refresh: refresh, expires: Date(timeIntervalSinceNow: expiresIn)),
                        userKey: userKey)
        self.masterKey = nil
        self.hash = nil
        password.wipe()
        return .done
    }

    private func call(_ url: URL, json: [String: String]? = nil, form: [String: String]? = nil) async throws -> Client.Answer {
        let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
        do {
            return try await client.send(url, method: "POST", json: body, form: form)
        } catch {
            throw Failure.unreachable
        }
    }

    // MARK: Reading the answers

    static func kdf(in json: [String: Any]) -> Kdf? {
        let settings = json["kdfSettings"] as? [String: Any]
        let type = (settings?["kdfType"] ?? json["kdf"] ?? json["Kdf"]) as? Int
        let iterations = (settings?["iterations"] ?? json["kdfIterations"] ?? json["KdfIterations"]) as? Int
        let memory = (settings?["memory"] ?? json["kdfMemory"]) as? Int
        let parallelism = (settings?["parallelism"] ?? json["kdfParallelism"]) as? Int
        switch (type, iterations) {
        case (0, let iterations?): return .pbkdf2(iterations: iterations)
        case (1, let iterations?):
            guard let memory, let parallelism else { return nil }
            return .argon2id(iterations: iterations, memory: memory, parallelism: parallelism)
        default: return nil
        }
    }

    /// The user key under the master key: in `UserDecryptionOptions` on a
    /// newer server, and as `Key` on every one so far.
    static func protectedUserKey(in json: [String: Any]) -> String? {
        let options = (json["UserDecryptionOptions"] ?? json["userDecryptionOptions"]) as? [String: Any]
        let unlock = (options?["MasterPasswordUnlock"] ?? options?["masterPasswordUnlock"]) as? [String: Any]
        return (unlock?["MasterKeyEncryptedUserKey"] ?? unlock?["masterKeyEncryptedUserKey"] ?? json["Key"] ?? json["key"]) as? String
    }
}
