import CryptoKit
import Foundation

/// What a passkey is asked for: the relying party, and the ids the page will
/// take, none of them meaning any. From the provider the system says who the
/// relying party is and has checked the page against it, and `page` is nil.
/// From a page's caller `page` is the sender's address, and the relying party
/// is held to it (`Address.mayName`) before anything else is read
/// (`BrowserDoor`).
struct PasskeyAsk: Equatable {
    let relyingParty: String
    let allowed: [Data]
    var page: String?

    func allows(_ passkey: Passkey) -> Bool {
        passkey.relyingParty.caseInsensitiveCompare(relyingParty) == .orderedSame
            && (allowed.isEmpty || allowed.contains(passkey.credentialID))
    }
}

extension Address {
    /// Whether this page may name this relying party, by WebAuthn's rule: a
    /// page under `https:`, or on `localhost`, names its own host or a parent
    /// of it no shorter than its site. An address has no domain to name, and
    /// a parent that is a public suffix is everybody's.
    func mayName(_ relyingParty: String) -> Bool {
        guard let host, let site, written.lowercased().hasPrefix("https:") || host == "localhost",
              !host.contains(":"), !host.allSatisfy({ $0.isNumber || $0 == "." }),
              !relyingParty.contains(where: { "/:@?#\\".contains($0) }),
              let named = Address.page("https://\(relyingParty)/")?.host
        else { return false }
        if named == host { return true }
        return host.hasSuffix(".\(named)") && (named == site || named.hasSuffix(".\(site)"))
    }
}

/// The door's passkey requests. A list holds an id, a title and a username,
/// and for a page the site and its icon, for a toast to draw. An assertion is
/// held to the ask again and made only after a finger, for every signature and
/// every item: the flags say a person was verified, and an item that does not
/// ask is no reason for that to be false. It reads the store, and only
/// `Passkey` reads the key. Making one is `make`, beside `MadePasskey`.
@MainActor
struct PasskeyDoor {
    let store: VaultStore
    let reprompt: Reprompt
    /// Where a new passkey's key comes from: CryptoKit's generator, and an
    /// invented scalar for the tour, so the search knows what to look for.
    let newKey: () -> P256.Signing.PrivateKey
    /// The app's own file for a host, as `SaveDoor` has it.
    let icons: (String) async -> Data?

    /// Every passkey the store's open logins hold, with its item.
    var held: [(item: Item, passkey: Passkey)] {
        store.shelves.all.flatMap { entry -> [(item: Item, passkey: Passkey)] in
            guard entry.item.isOutstanding, entry.item.login?.passkeysCreated.isEmpty == false else { return [] }
            return Passkey.all(in: entry.item).map { (entry.item, $0) }
        }
    }

    /// Those the ask allows and the door could answer, by an id that goes
    /// back as it came. The username is the one the passkey was made for.
    func list(_ ask: PasskeyAsk) async -> BridgeAnswer {
        let listed = rows { ask.allows($0) }
        guard let page = ask.page.flatMap({ Address.page($0) }) else { return .logins(site: nil, listed) }
        guard let host = page.host, !listed.isEmpty else { return .listed(site: page.site, listed, icon: nil) }
        let icon = await icons(host)
        guard store.state == .unlocked else { return .locked }
        return .listed(site: page.site, listed, icon: icon.flatMap { $0.count <= SaveDoor.mostIcon ? $0 : nil })
    }

    /// Whatever passkeys this page could ask for, which a mark in a field
    /// draws before the page has asked for any.
    func near(_ url: String) -> BridgeAnswer {
        guard let page = Address.page(url) else { return .refused(.page) }
        return .logins(site: page.site, rows { page.mayName($0.relyingParty) })
    }

    private func rows(where wanted: (Passkey) -> Bool) -> [BridgeLogin] {
        held.filter { wanted($0.passkey) && $0.passkey.isES256 }.map {
            BridgeLogin(id: $0.passkey.credentialID.base64EncodedString(), title: $0.item.name,
                        username: $0.passkey.userName ?? $0.item.login?.username)
        }
    }

    func assert(_ id: Data, _ ask: PasskeyAsk, over clientDataHash: Data) async -> BridgeAnswer {
        let found = held.filter { $0.passkey.credentialID == id }
        guard !found.isEmpty else { return .refused(.gone) }
        guard let chosen = found.first(where: { ask.allows($0.passkey) }) else { return .refused(.page) }
        guard chosen.passkey.isES256 else { return .refused(.gone) }
        guard await reprompt.confirm(.passkey, on: chosen.item) else { return .refused(.declined) }
        // He took a while, and the vault may have moved under the question.
        guard store.state == .unlocked else { return .locked }
        guard let passkey = held.first(where: { $0.passkey.credentialID == id && ask.allows($0.passkey) })?.passkey,
              let assertion = passkey.assertion(over: clientDataHash)
        else { return .refused(.gone) }
        return .asserted(assertion)
    }
}
