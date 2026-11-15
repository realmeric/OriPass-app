import AuthenticationServices

/// What the extension hands back: a login, a code, a passkey's assertion, a
/// new passkey, or why it will not make one.
enum Answer {
    case password(ASPasswordCredential)
    case code(String)
    case passkey(ASPasskeyAssertionCredential)
    case registered(ASPasskeyRegistrationCredential)
    case refused(ASExtensionError.Code)

    /// A login's username and password, with its code put on the pasteboard
    /// for the field that asks for it next.
    static func login(_ item: Item) -> Answer? {
        guard let login = item.login else { return nil }
        if let secret = login.totp, let totp = Totp(secret) { Pasteboard.copy(totp.code(at: .now)) }
        return .password(ASPasswordCredential(user: login.username ?? "", password: login.password ?? ""))
    }

    static func code(_ item: Item) -> Answer? {
        guard let secret = item.login?.totp, let totp = Totp(secret) else { return nil }
        return .code(totp.code(at: .now))
    }

    /// The passkey of `item` whose id is `credentialID`, or its only one.
    static func passkey(_ item: Item, credentialID: Data?, clientDataHash: Data) -> Answer? {
        let passkeys = item.login?.passkeys ?? []
        guard let passkey = passkeys.first(where: { Passkeys.credentialID($0.credentialId) == credentialID }) ?? passkeys.first,
              let assertion = try? PasskeyAssertion(passkey: passkey, clientDataHash: clientDataHash) else { return nil }
        return .passkey(ASPasskeyAssertionCredential(
            userHandle: assertion.userHandle, relyingParty: passkey.rpId, signature: assertion.signature,
            clientDataHash: clientDataHash, authenticatorData: assertion.authenticatorData,
            credentialID: assertion.credentialID))
    }
}
