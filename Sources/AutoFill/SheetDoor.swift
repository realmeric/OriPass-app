import AppKit
import AuthenticationServices

/// What the system says it wants a login for: a page, by its address or its
/// domain, or an app by its id, with the name the sheet calls it. Or a
/// passkey, for a relying party, with the ids its page will take and the
/// hash of the client data the assertion is to be over.
enum AutoFillService: Equatable {
    case page(url: String, name: String)
    case app(bundleID: String, name: String)
    case passkey(relyingParty: String, allowed: [Data], clientDataHash: Data)

    /// Nil for one with nothing in it. An app's identifier is an App ID, and
    /// may start with its team.
    init?(_ service: ASCredentialServiceIdentifier) {
        let written = service.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !written.isEmpty else { return nil }
        switch service.type {
        case .domain:
            self = .page(url: "https://\(written)/", name: service.displayName ?? written)
        case .URL:
            let url = written.contains("://") ? written : "https://\(written)"
            self = .page(url: url, name: URLComponents(string: url)?.host ?? service.displayName ?? written)
        case .app:
            let id = written.replacing(/^[A-Z0-9]{10}\./, with: "")
            self = .app(bundleID: id, name: service.displayName ?? id)
        @unknown default:
            return nil
        }
    }

    var name: String {
        switch self {
        case .page(_, let name), .app(_, let name): return name
        case .passkey(let relyingParty, _, _): return relyingParty
        }
    }

    var isPasskey: Bool {
        if case .passkey = self { return true }
        return false
    }

    /// What is asked of the door for this service's list, and for a row.
    var listing: SheetRequest { isPasskey ? .passkeys(self) : .logins(self) }

    func taking(_ id: String) -> SheetRequest {
        isPasskey ? .assert(id: id, self) : .fill(id: id, self)
    }
}

/// A row of the sheet: a login's id and the two words the door lists it by,
/// and the service it was found for, which its fill is held to again. A row
/// a word found has none, and is a `pick`.
struct SheetRow: Equatable, Identifiable, Redacted {
    let id: String
    let title: String
    let username: String?
    let service: AutoFillService?

    var redactedLabel: String { "SheetRow(\(id))" }
}

/// What the door handed over, on its way to the system.
struct SheetCredential: Equatable, Redacted {
    let username: String
    let password: String

    var redactedLabel: String { "SheetCredential" }
}

/// A one-time code on its way to the system. The door made it, and no secret
/// has been here.
struct SheetCode: Equatable, Redacted {
    let code: String

    var redactedLabel: String { "SheetCode" }
}

/// A passkey's signature on its way to the system. The door signed it, and
/// no key has been here.
struct SheetAssertion: Equatable, Decodable, Redacted {
    let credential: Data
    let userHandle: Data
    let authenticatorData: Data
    let signature: Data

    var redactedLabel: String { "SheetAssertion" }
}

enum SheetRequest: Redacted {
    case logins(AutoFillService)
    case fill(id: String, AutoFillService)
    case passkeys(AutoFillService)
    case assert(id: String, AutoFillService)
    case codes(AutoFillService)
    case code(id: String, AutoFillService)
    case front
    case find(String)
    case pick(id: String)

    var redactedLabel: String { "SheetRequest" }
}

enum SheetAnswer: Equatable, Redacted {
    case logins(site: String?, [DoorLogin])
    /// What the app found the sheet up over, nil when it can name nothing,
    /// and that thing's logins.
    case front(AutoFillService?, [DoorLogin])
    case filled(SheetCredential)
    case asserted(SheetAssertion)
    case code(SheetCode)
    case refused(String)
    /// The door is shut, with the app up behind a lock or with no app up.
    case shut(isRunning: Bool)

    var redactedLabel: String { "SheetAnswer" }
}

struct DoorLogin: Equatable, Decodable {
    let id: String
    let title: String
    let username: String?
}

/// Who the sheet asks. The extension holds nothing of the vault, so every
/// list and every fill is one of these.
protocol SheetDoor: Sendable {
    func ask(_ request: SheetRequest) async -> SheetAnswer
}

/// The door for the browser, from the provider's sandbox: one message on a
/// connection of its own behind a `hello` of its own, as Safari's handler
/// does, and the bytes of the answer overwritten behind it.
struct BridgeSheetDoor: SheetDoor {
    private static let hello = Data(#"{"v":\#(BridgeWire.version),"type":"hello"}"#.utf8)

    var door = BridgeWire.doorInTheGroup
    var app = "com.meric.oripass"

    func ask(_ request: SheetRequest) async -> SheetAnswer {
        let door = self.door, app = self.app
        // Off the sheet's thread, since an answer can take as long as a finger.
        return await Task.detached {
            guard let door, let message = Self.message(request),
                  var bytes = BridgeWire.pass(message, saying: Self.hello, to: door)
            else { return Self.shut(app) }
            defer { bytes.resetBytes(in: 0..<bytes.count) }
            return Self.answer(bytes) ?? Self.shut(app)
        }.value
    }

    private static func shut(_ app: String) -> SheetAnswer {
        .shut(isRunning: !NSRunningApplication.runningApplications(withBundleIdentifier: app).isEmpty)
    }

    private static func message(_ request: SheetRequest) -> Data? {
        var written: [String: Any] = ["v": BridgeWire.version]
        var service: AutoFillService?
        switch request {
        case .logins(let asked):
            written["type"] = "logins"
            service = asked
        case .fill(let id, let asked):
            written["type"] = "fill"
            written["id"] = id
            service = asked
        case .passkeys(let asked):
            written["type"] = "passkeys"
            service = asked
        case .assert(let id, let asked):
            written["type"] = "assert"
            written["id"] = id
            service = asked
        case .codes(let asked):
            written["type"] = "codes"
            service = asked
        case .code(let id, let asked):
            written["type"] = "code"
            written["id"] = id
            service = asked
        case .front:
            written["type"] = "front"
        case .find(let word):
            written["type"] = "find"
            written["word"] = word
        case .pick(let id):
            written["type"] = "pick"
            written["id"] = id
        }
        switch (service, request) {
        case (.page(let url, _)?, _):
            written["url"] = url
        case (.app(let id, let name)?, _):
            written["app"] = id
            written["name"] = name
        case (.passkey(let relyingParty, let allowed, _)?, .passkeys):
            written["rp"] = relyingParty
            written["allowed"] = allowed.map { $0.base64EncodedString() }
        case (.passkey(let relyingParty, let allowed, let hash)?, _):
            written["rp"] = relyingParty
            written["allowed"] = allowed.map { $0.base64EncodedString() }
            written["hash"] = hash.base64EncodedString()
        case (nil, _):
            break
        }
        return try? JSONSerialization.data(withJSONObject: written)
    }

    private struct Said: Decodable {
        let type: String
        let site: String?
        let url: String?
        let app: String?
        let name: String?
        let logins: [DoorLogin]?
        let username: String?
        let password: String?
        let assertion: SheetAssertion?
        let code: String?
        let reason: String?
    }

    /// Nil for whatever is no answer to a request, which reads as a door
    /// that said nothing. `locked` is the door's own, for a caller it took
    /// as the vault shut.
    private static func answer(_ bytes: Data) -> SheetAnswer? {
        guard let said = try? JSONDecoder().decode(Said.self, from: bytes) else { return nil }
        switch said.type {
        case "logins": return .logins(site: said.site, said.logins ?? [])
        case "front": return .front(service(said), said.logins ?? [])
        case "filled": return .filled(SheetCredential(username: said.username ?? "", password: said.password ?? ""))
        case "asserted": return said.assertion.map { .asserted($0) }
        case "code": return said.code.map { .code(SheetCode(code: $0)) }
        case "refused": return .refused(said.reason ?? "")
        default: return nil
        }
    }

    /// What a `front` named, as the system would have named it.
    private static func service(_ said: Said) -> AutoFillService? {
        if let url = said.url {
            return .page(url: url, name: said.site ?? URLComponents(string: url)?.host ?? url)
        }
        return said.app.map { .app(bundleID: $0, name: said.name ?? $0) }
    }
}
