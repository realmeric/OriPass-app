import AuthenticationServices
import Foundation

/// What the keyboard may suggest before the vault is opened (I6): a
/// password identity for each login and each address it has, a one-time
/// code identity beside it when the login has a code, and a passkey
/// identity for each passkey. Usernames and sites only; nothing that opens
/// anything.
enum Identities {
    /// One service a login's address names: a site by its host, or on iOS
    /// 26.2 and later an app by its bundle id. A host and not the address:
    /// on the iOS 26.5 simulator Safari offered nothing for an address
    /// identity on http://localhost:8099 and offered the login for the same
    /// host as a domain (docs/notes-ios.md, "AutoFill").
    static func service(for uri: String) -> ASCredentialServiceIdentifier? {
        let written = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !written.isEmpty else { return nil }
        let lower = written.lowercased()
        if lower.hasPrefix("iosapp://") {
            let bundle = String(written.dropFirst("iosapp://".count))
            guard !bundle.isEmpty else { return nil }
            if #available(iOS 26.2, *) { return ASCredentialServiceIdentifier(identifier: bundle, type: .app) }
            return nil
        }
        if lower.hasPrefix("androidapp://") { return nil }
        let url = lower.contains("://") ? written : "https://" + written
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = parsed.host(), !host.isEmpty else { return nil }
        return ASCredentialServiceIdentifier(identifier: host.lowercased(), type: .domain)
    }

    static func make(from summaries: [Summary]) -> [any ASCredentialIdentity] {
        var identities: [any ASCredentialIdentity] = []
        var seen = Set<String>()
        for summary in summaries where summary.kind == .login {
            let rank = summary.favorite ? 1 : 0
            for uri in summary.uris {
                guard let service = service(for: uri.uri) else { continue }
                let mark = "\(service.type.rawValue) \(service.identifier) \(summary.id)"
                guard seen.insert(mark).inserted else { continue }
                if summary.username != nil || summary.hasPassword {
                    let password = ASPasswordCredentialIdentity(serviceIdentifier: service, user: summary.username ?? "",
                                                                recordIdentifier: summary.id)
                    password.rank = rank
                    identities.append(password)
                }
                if summary.hasTotp {
                    identities.append(ASOneTimeCodeCredentialIdentity(serviceIdentifier: service, label: summary.name,
                                                                      recordIdentifier: summary.id))
                }
            }
            for passkey in summary.passkeys {
                guard let credential = Passkeys.credentialID(passkey.credentialId), !passkey.rpId.isEmpty else { continue }
                identities.append(ASPasskeyCredentialIdentity(
                    relyingPartyIdentifier: passkey.rpId, userName: passkey.userName ?? "",
                    credentialID: credential, userHandle: Passkeys.userHandle(passkey.userHandle) ?? Data(),
                    recordIdentifier: summary.id))
            }
        }
        return identities
    }
}

/// How Bitwarden writes a passkey's two ids.
enum Passkeys {
    /// A credential id is a GUID's sixteen bytes, written as the GUID, or
    /// any bytes written as "b64." and base64url.
    static func credentialID(_ written: String) -> Data? {
        if written.hasPrefix("b64.") { return base64url(String(written.dropFirst(4))) }
        guard let uuid = UUID(uuidString: written) else { return nil }
        return withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }

    static func userHandle(_ written: String?) -> Data? {
        written.flatMap(base64url)
    }

    static func base64url(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The store iOS keeps the identities in. A write to a store that is off is
/// lost, so its state is asked first; one from the background throws, and
/// the next unlock in front writes again.
enum IdentityStore {
    static func replace(with summaries: [Summary]) async {
        let store = ASCredentialIdentityStore.shared
        guard await store.state().isEnabled else { return }
        let identities = Identities.make(from: summaries)
        do {
            try await store.replaceCredentialIdentities(identities)
            Log.fill.info("identity store holds \(identities.count) identities")
        } catch {
            Log.fill.error("identity store refused \(identities.count) identities: \((error as NSError).code)")
        }
    }

    static func empty() async {
        let store = ASCredentialIdentityStore.shared
        guard await store.state().isEnabled else { return }
        try? await store.removeAllCredentialIdentities()
    }

    static var isEnabled: Bool {
        get async { await ASCredentialIdentityStore.shared.state().isEnabled }
    }
}
