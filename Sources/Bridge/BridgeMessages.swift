import Foundation

/// An app the system's AutoFill is asking for, in place of a page: the
/// bundle id it was given and the name to try that against.
struct BridgeApp: Equatable {
    let bundleID: String
    let name: String
}

/// What a one-time code is asked for: a page or an app, each held as a
/// `fill` for it is.
enum CodeAsk: Equatable {
    case page(url: String)
    case app(BridgeApp)
}

/// What the app found the system's sheet up over: the two ways a `fill` names
/// what it is for.
enum BridgeFront: Equatable {
    case page(url: String, site: String?)
    case app(BridgeApp)
}

/// What was typed into a page, as far as the door is told before anyone has
/// said to keep it: the username, and a mark of the password under a key made
/// for this one question, which `SaveDoor` can make of a login's password and
/// compare and nobody can read back.
struct BridgeTyped: Redacted {
    let url: String
    let username: String?
    let key: Data
    let mark: Data

    var redactedLabel: String { "BridgeTyped" }
}

/// A login to keep, on its way from a click on the toast to the store. Whoever
/// answers wipes the password. With an id it goes over that login's.
struct BridgeSave: Redacted {
    let url: String
    let id: String?
    let username: String?
    let password: SecretBytes

    var redactedLabel: String { "BridgeSave(\(id ?? "new"))" }
}

/// What a caller asks. A page's address can hold a token of its own, so
/// this says what kind of request it is and no more.
enum BridgeRequest: Redacted {
    case hello(origin: String?, browser: String?)
    case logins(url: String)
    case fill(id: String, url: String)
    case appLogins(BridgeApp)
    case appFill(id: String, BridgeApp)
    case passkeys(PasskeyAsk)
    /// Whatever passkeys a page could ask for. A page's callers alone ask
    /// this, for a mark in a field.
    case passkeysNear(url: String)
    /// `id` is the bytes a `passkeys` row named, and the hash is the page's
    /// client data's, thirty-two bytes.
    case assert(id: Data, PasskeyAsk, hash: Data)
    case codes(CodeAsk)
    case code(id: String, CodeAsk)
    /// The logins that could hold a new passkey for a relying party.
    case homes(relyingParty: String)
    case make(PasskeyOrder)
    /// What the system's sheet is up over, when the system named nothing.
    case front
    /// The logins a word finds, and one of them with no address to hold it
    /// to.
    case find(word: String)
    case pick(id: String)
    /// What the toast is to say about what a page was just given. A page's
    /// callers alone may ask this and the next two.
    case known(BridgeTyped)
    case save(BridgeSave)
    /// Not to ask again on this page's host.
    case never(url: String)
    /// What the vault's logins already use, and identities' emails, for a
    /// field with no login. A page's callers alone ask this and the next.
    case usernames(url: String, addressesOnly: Bool)
    /// A new password for a page's field, no longer than `most` if it says.
    case generate(url: String, most: Int?)

    private struct Written: Decodable {
        let v: Int
        let type: String
        let origin: String?
        let browser: String?
        let url: String?
        let id: String?
        let app: String?
        let name: String?
        let word: String?
        let rp: String?
        let allowed: [Data]?
        let hash: Data?
        let user: String?
        let handle: Data?
        let algorithms: [Int]?
        let excluded: [Data]?
        let login: String?
        let username: String?
        let key: Data?
        let mark: Data?
        var password: Data?
        let address: Bool?
        let most: Int?
    }

    /// Nil for anything the wire does not have, which closes the connection.
    init?(_ body: Data) {
        guard var written = try? JSONDecoder().decode(Written.self, from: body),
              written.v == BridgeWire.version
        else { return nil }
        if let rp = written.rp {
            self.init(passkey: written, for: rp)
            return
        }
        let app = written.app.map { BridgeApp(bundleID: $0, name: written.name ?? "") }
        switch (written.type, written.url, written.id, app) {
        case ("hello", _, _, _): self = .hello(origin: written.origin, browser: written.browser)
        case ("logins", let url?, _, nil): self = .logins(url: url)
        case ("fill", let url?, let id?, nil): self = .fill(id: id, url: url)
        case ("logins", nil, _, let app?): self = .appLogins(app)
        case ("fill", nil, let id?, let app?): self = .appFill(id: id, app)
        case ("passkeys", let url?, nil, nil): self = .passkeysNear(url: url)
        case ("codes", let url?, _, nil): self = .codes(.page(url: url))
        case ("codes", nil, _, let app?): self = .codes(.app(app))
        case ("code", let url?, let id?, nil): self = .code(id: id, .page(url: url))
        case ("code", nil, let id?, let app?): self = .code(id: id, .app(app))
        case ("front", nil, nil, nil): self = .front
        case ("find", nil, nil, nil):
            guard let word = written.word else { return nil }
            self = .find(word: word)
        case ("pick", nil, let id?, nil): self = .pick(id: id)
        case ("known", let url?, nil, nil):
            guard let key = written.key, let mark = written.mark, !key.isEmpty, !mark.isEmpty else { return nil }
            self = .known(BridgeTyped(url: url, username: written.username, key: key, mark: mark))
        case ("save", let url?, let id, nil):
            guard let password = Self.password(out: &written) else { return nil }
            self = .save(BridgeSave(url: url, id: id, username: written.username, password: password))
        case ("never", let url?, nil, nil): self = .never(url: url)
        case ("usernames", let url?, nil, nil): self = .usernames(url: url, addressesOnly: written.address == true)
        case ("generate", let url?, nil, nil): self = .generate(url: url, most: written.most)
        default: return nil
        }
    }

    /// The password in the one form that can be wiped, with what it came in
    /// overwritten. It is taken out of `written` first: a second reference
    /// would have the zeros land in a copy.
    private static func password(out written: inout Written) -> SecretBytes? {
        guard var bytes = written.password else { return nil }
        written.password = nil
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        return bytes.isEmpty ? nil : SecretBytes(bytes)
    }

    private init?(passkey written: Written, for rp: String) {
        guard !rp.isEmpty else { return nil }
        let ask = PasskeyAsk(relyingParty: rp, allowed: written.allowed ?? [], page: written.url)
        switch (written.type, written.id.flatMap { Data(base64Encoded: $0) }, written.hash) {
        case ("passkeys", _, nil): self = .passkeys(ask)
        case ("assert", let id?, let hash?) where hash.count == 32: self = .assert(id: id, ask, hash: hash)
        case ("homes", _, nil): self = .homes(relyingParty: rp)
        case ("make", _, let hash?) where hash.count == 32:
            guard let handle = written.handle, (1...64).contains(handle.count) else { return nil }
            self = .make(PasskeyOrder(relyingParty: rp, userName: written.user ?? "", userHandle: handle,
                                      clientDataHash: hash, algorithms: written.algorithms ?? [],
                                      excluded: written.excluded ?? [], login: written.login))
        default: return nil
        }
    }

    var redactedLabel: String {
        switch self {
        case .hello: return "BridgeRequest(hello)"
        case .logins, .appLogins: return "BridgeRequest(logins)"
        case .fill(let id, _), .appFill(let id, _): return "BridgeRequest(fill \(id))"
        case .passkeys, .passkeysNear: return "BridgeRequest(passkeys)"
        case .assert: return "BridgeRequest(assert)"
        case .codes: return "BridgeRequest(codes)"
        case .code(let id, _): return "BridgeRequest(code \(id))"
        case .homes: return "BridgeRequest(homes)"
        case .make: return "BridgeRequest(make)"
        case .front: return "BridgeRequest(front)"
        case .find: return "BridgeRequest(find)"
        case .pick(let id): return "BridgeRequest(pick \(id))"
        case .known: return "BridgeRequest(known)"
        case .save(let order): return "BridgeRequest(save \(order.id ?? "new"))"
        case .never: return "BridgeRequest(never)"
        case .usernames: return "BridgeRequest(usernames)"
        case .generate: return "BridgeRequest(generate)"
        }
    }
}

/// A row of the list for a page: nothing in it is hidden anywhere in the
/// app, and it is still not for a log.
struct BridgeLogin: Encodable, Redacted {
    let id: String
    let title: String
    let username: String?

    var redactedLabel: String { "BridgeLogin(\(id))" }
}

/// A passkey's signature on its way to whoever asked. It holds no key.
struct BridgeAssertion: Encodable, Redacted {
    let credential: Data
    let userHandle: Data
    let authenticatorData: Data
    let signature: Data

    var redactedLabel: String { "BridgeAssertion" }
}

/// A new passkey on its way to the provider: its id, and the attestation,
/// which says its public half. It holds no key.
struct BridgeRegistration: Encodable, Redacted {
    let credential: Data
    let attestation: Data

    var redactedLabel: String { "BridgeRegistration" }
}

/// What the toast is to do with what was typed. `same` and `never` show
/// nothing. `new` is a site with no login, `update` the one login this was
/// typed for, `choose` several it could be for, and `another` a site whose
/// logins all have some other username.
enum BridgeStanding: String {
    case same, never, new, update, choose, another
}

/// `known`'s answer, which holds no password and nothing made from one: the
/// logins to name, and the site's icon when the app has one already.
struct BridgeKnown: Redacted {
    var standing: BridgeStanding
    var site: String?
    var logins: [BridgeLogin] = []
    var icon: Data?

    var redactedLabel: String { "BridgeKnown(\(standing.rawValue))" }
}

/// What a `fill` was asked for, on its way to one page.
struct BridgeFill: Redacted {
    let username: String?
    let password: String?
    let code: String?

    var redactedLabel: String { "BridgeFill" }
}

enum BridgeRefusal: String {
    /// An address that is no web page, or one no address of the login's
    /// holds for. Also an app that is not one of the login's, and an app
    /// asked for by anyone but the system's AutoFill. For a passkey, another
    /// relying party's, one the page did not allow, and a caller that says no
    /// page and is not the provider's, or a page and is.
    case page
    /// An id the store does not have, an item that is no login, or one in
    /// the trash or the archive. For a code, also a login with no secret
    /// that reads.
    case gone
    /// An `http:` page for a login saved under `https:`.
    case insecure
    /// An item that asks, and was not answered yes.
    case declined
    /// A passkey the page said it already has.
    case excluded
    /// A new passkey or a login the engine did not take, or did not hand
    /// back.
    case unsaved
    /// A password the engine did not make.
    case unmade
}

/// What the door says back. `.filled` and `.generated` hold a secret,
/// `.asserted` a signature and `.code` a code, and the bytes any of them makes are
/// overwritten once they are written (`BridgeConnection`), as every answer's
/// are.
enum BridgeAnswer: Redacted {
    case ready, locked, unknown
    case logins(site: String?, [BridgeLogin])
    /// A list for a toast to draw, which is a `logins` with the site's icon
    /// when the app has one already.
    case listed(site: String?, [BridgeLogin], icon: Data?)
    /// A list with the address it is for, nil for an app in front nobody can
    /// name.
    case front(BridgeFront?, [BridgeLogin])
    case filled(BridgeFill)
    case asserted(BridgeAssertion)
    case code(String)
    case made(BridgeRegistration)
    case known(BridgeKnown)
    case saved(id: String, title: String)
    case usernames([String])
    case generated(String)
    case refused(BridgeRefusal)

    private struct Written: Encodable {
        var v = BridgeWire.version
        let type: String
        var site: String?
        var url: String?
        var app: String?
        var name: String?
        var logins: [BridgeLogin]?
        var username: String?
        var password: String?
        var code: String?
        var assertion: BridgeAssertion?
        var registration: BridgeRegistration?
        var state: String?
        var icon: Data?
        var id: String?
        var title: String?
        var usernames: [String]?
        var reason: String?
    }

    /// Whether the caller may ask anything more on this connection.
    var keepsConnection: Bool {
        switch self {
        case .locked, .unknown: return false
        default: return true
        }
    }

    var type: String {
        switch self {
        case .ready: return "ready"
        case .locked: return "locked"
        case .unknown: return "unknown"
        case .logins, .listed: return "logins"
        case .front: return "front"
        case .filled: return "filled"
        case .asserted: return "asserted"
        case .code: return "code"
        case .made: return "made"
        case .known: return "known"
        case .saved: return "saved"
        case .usernames: return "usernames"
        case .generated: return "generated"
        case .refused: return "refused"
        }
    }

    var body: Data {
        var written = Written(type: type)
        switch self {
        case .ready, .locked, .unknown:
            break
        case .logins(let site, let logins):
            written.site = site
            written.logins = logins
        case .listed(let site, let logins, let icon):
            written.site = site
            written.logins = logins
            written.icon = icon
        case .front(let front, let logins):
            written.logins = logins
            switch front {
            case .page(let url, let site):
                written.url = url
                written.site = site
            case .app(let app):
                written.app = app.bundleID
                written.name = app.name
            case nil:
                break
            }
        case .filled(let fill):
            written.username = fill.username
            written.password = fill.password
            written.code = fill.code
        case .asserted(let assertion):
            written.assertion = assertion
        case .code(let code):
            written.code = code
        case .made(let registration):
            written.registration = registration
        case .known(let known):
            written.state = known.standing.rawValue
            written.site = known.site
            written.logins = known.logins
            written.icon = known.icon
        case .saved(let id, let title):
            written.id = id
            written.title = title
        case .usernames(let usernames):
            written.usernames = usernames
        case .generated(let password):
            written.password = password
        case .refused(let reason):
            written.reason = reason.rawValue
        }
        return (try? JSONEncoder().encode(written)) ?? Data()
    }

    var redactedLabel: String { "BridgeAnswer(\(type))" }
}
