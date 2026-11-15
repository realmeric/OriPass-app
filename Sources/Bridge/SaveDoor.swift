import CryptoKit
import Foundation

/// What a page took, once a toast has to say something about it. `known`
/// reads the logins for the page and compares a mark, so no password crosses
/// to ask, and `save` is sent only after a trusted click on the toast. The
/// site is always the address the browser gave: a page cannot name another,
/// and a login is held to it as a fill is.
@MainActor
final class SaveDoor {
    /// An icon past this is left for a tile: a toast is no reason to send a
    /// big file down the door.
    static let mostIcon = 48 * 1024

    private let store: VaultStore
    private let reprompt: Reprompt
    private let preferences: Preferences
    private let icons: (String) async -> Data?

    init(store: VaultStore, reprompt: Reprompt, preferences: Preferences, icons: @escaping (String) async -> Data?) {
        self.store = store
        self.reprompt = reprompt
        self.preferences = preferences
        self.icons = icons
    }

    /// A password a login for the site already has says nothing, whichever
    /// username went with it: sites take an email or a name for one account,
    /// and a toast at every sign-in would be worse than a second account
    /// that shares a password going unoffered.
    func known(_ typed: BridgeTyped) async -> BridgeAnswer {
        guard let page = Address.page(typed.url), let host = page.host else { return .refused(.page) }
        if preferences.settings.browser.neverSave.contains(host) { return .known(BridgeKnown(standing: .never)) }
        // Unconditionally: a login just saved has to be found by the next
        // question, and the index that holds it may still be being made.
        await store.indexing?.value
        guard store.state == .unlocked else { return .locked }
        let entries = (Suggestions.forPage(page, among: store.searchIndex?.logins ?? [])?.entries ?? [])
            .filter { BrowserDoor.refusal(of: $0.item, on: page) == nil }
        let isSame = entries.contains { $0.item.login?.password.map { Self.holds(typed, password: $0) } == true }
        if isSame { return .known(BridgeKnown(standing: .same)) }

        let (standing, named) = Self.standing(of: typed.username, among: entries)
        let icon = await icons(host).flatMap { $0.count <= Self.mostIcon ? $0 : nil }
        guard store.state == .unlocked else { return .locked }
        let logins = named.map { BridgeLogin(id: $0.id, title: $0.item.name, username: $0.item.login?.username) }
        return .known(BridgeKnown(standing: standing, site: page.site, logins: logins, icon: icon))
    }

    /// Whether `typed`'s mark is the one this password makes under its key.
    static func holds(_ typed: BridgeTyped, password: String) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(typed.mark, authenticating: Data(password.utf8),
                                               using: SymmetricKey(data: typed.key))
    }

    /// What a username makes of the site's logins. None typed, which is a
    /// form that changes a password, could be for any of them, and so could
    /// one the logins have no username for.
    private static func standing(of username: String?, among entries: [Entry]) -> (BridgeStanding, [Entry]) {
        guard !entries.isEmpty else { return (.new, []) }
        let typed = username.map(folded) ?? ""
        let holders = typed.isEmpty ? entries : entries.filter { folded($0.item.login?.username ?? "") == typed }
        let unnamed = entries.filter { ($0.item.login?.username ?? "").isEmpty }
        let found = holders.isEmpty ? unnamed : holders
        switch found.count {
        case 0: return (.another, entries)
        case 1: return (.update, found)
        default: return (.choose, found)
        }
    }

    private static func folded(_ username: String) -> String {
        username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func save(_ order: BridgeSave) async -> BridgeAnswer {
        guard let page = Address.page(order.url) else { return .refused(.page) }
        let password = order.password.withBytes { String(decoding: $0, as: UTF8.self) }
        if let id = order.id { return await update(id, with: password, of: order, on: page) }
        return await make(password, of: order, on: page)
    }

    /// A new login in Personal, called what the site is, at the page's origin
    /// and not its whole address, which can hold a token of its own.
    private func make(_ password: String, of order: BridgeSave, on page: Address) async -> BridgeAnswer {
        do {
            let blank = try await store.blank(.login)
            guard case .login(var login) = blank.payload else { return .refused(.unsaved) }
            login.username = order.username.flatMap { $0.isEmpty ? nil : $0 }
            login.password = password
            login.uris = [LoginURI(uri: Self.origin(of: page))]
            var edited = blank
            edited.name = page.site ?? page.host ?? page.written
            edited.payload = .login(login)
            guard let made = try await store.create(edited, from: blank) else { return .locked }
            return .saved(id: made.id, title: made.name)
        } catch VaultError.locked {
            return .locked
        } catch {
            return .refused(.unsaved)
        }
    }

    /// An update overwrites, so it takes a finger every time, and the old
    /// password goes into the history through `VaultStore.apply`.
    private func update(_ id: String, with password: String, of order: BridgeSave, on page: Address) async -> BridgeAnswer {
        guard let item = store.entry(id: id)?.item else { return .refused(.gone) }
        if let refusal = BrowserDoor.refusal(of: item, on: page) { return .refused(refusal) }
        guard await reprompt.confirm(.overwrite, on: item) else { return .refused(.declined) }
        // He took a while, and the vault may have moved under the question.
        guard store.state == .unlocked else { return .locked }
        guard var edited = store.entry(id: id)?.item, case .login(var login) = edited.payload else {
            return .refused(.gone)
        }
        if let refusal = BrowserDoor.refusal(of: edited, on: page) { return .refused(refusal) }
        login.password = password
        if (login.username ?? "").isEmpty, let typed = order.username, !typed.isEmpty { login.username = typed }
        edited.payload = .login(login)
        do {
            guard let saved = try await store.apply(.edit(edited), to: id) else { return .locked }
            return .saved(id: saved.id, title: saved.name)
        } catch VaultError.locked {
            return .locked
        } catch {
            return .refused(.unsaved)
        }
    }

    /// The host of the page that was told, and nothing more of it.
    func never(_ url: String) -> BridgeAnswer {
        guard let host = Address.page(url)?.host else { return .refused(.page) }
        if !preferences.settings.browser.neverSave.contains(host) {
            preferences.settings.browser.neverSave.append(host)
        }
        return .known(BridgeKnown(standing: .never))
    }

    private static func origin(of page: Address) -> String {
        var parts = URLComponents()
        parts.scheme = URLComponents(string: page.written)?.scheme?.lowercased()
        parts.host = page.host
        parts.port = page.port
        return parts.string ?? page.written
    }
}
