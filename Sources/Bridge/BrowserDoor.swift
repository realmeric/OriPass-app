import Combine
import CryptoKit
import Foundation

/// The app's side of the door: open while the store is unlocked, and what
/// each request is answered with. A list holds ids, titles and usernames,
/// a fill is held to the page again and goes through `Reprompt`, and an
/// origin gets no further than `hello` until the card has let it in. A
/// passkey is the system's AutoFill's to ask for and a page's caller's for
/// that page's relying party (`PasskeyDoor`). A one-time code by itself and
/// what the sheet asks when the system named nothing, what is in front, a
/// word and a row found by it, are the provider's alone. What a page took is a
/// page's caller's alone to bring (`SaveDoor`), and so is the asking for what
/// a field with no login is offered (`OfferDoor`).
///
/// It reads the store and never the engine, and but for a login a toast was
/// pressed for it writes nothing but the socket and the answer to the card.
@MainActor
final class BrowserDoor {
    /// As many as Quick Access draws at a time.
    static let mostFound = 8

    private let store: VaultStore
    private let reprompt: Reprompt
    private let preferences: Preferences
    private let stage: BrowserStage?
    private let passkeys: PasskeyDoor
    private let saving: SaveDoor
    private let offers: OfferDoor
    private let front: () -> FrontApp?
    private let tabs: TabAsker?
    private var server: BridgeServer?
    /// The card, while it is up. One at a time.
    private(set) var question: BrowserQuestion?
    private var watching: Set<AnyCancellable> = []

    /// Without a path there is no socket, which is a test's over a
    /// socketpair. Without a stage nothing is ever let in. Without `front`
    /// nothing is ever in front, and without `tabs` no browser says its page.
    init(store: VaultStore, reprompt: Reprompt, preferences: Preferences, stage: BrowserStage? = nil,
         path: URL? = nil, peers: PeerCheck = PeerCheck(),
         newKey: @escaping () -> P256.Signing.PrivateKey = { P256.Signing.PrivateKey() },
         front: @escaping () -> FrontApp? = { nil }, tabs: TabAsker? = nil,
         icons: @escaping (String) async -> Data? = { _ in nil },
         generator: @escaping () -> GeneratorSettings = { GeneratorSettings() }) {
        self.store = store
        self.reprompt = reprompt
        self.preferences = preferences
        self.stage = stage
        self.front = front
        self.tabs = tabs
        passkeys = PasskeyDoor(store: store, reprompt: reprompt, newKey: newKey, icons: icons)
        saving = SaveDoor(store: store, reprompt: reprompt, preferences: preferences, icons: icons)
        offers = OfferDoor(store: store, settings: generator)
        if let path {
            server = BridgeServer(path: path, peers: peers) { [weak self] request, caller in
                await self?.answer(request, from: caller) ?? .locked
            }
        }
        store.$state.sink { [weak self] state in
            if state == .unlocked { self?.open() } else { self?.cut() }
        }.store(in: &watching)
        // Before the store is emptied: `didLock` is after it.
        NotificationCenter.default.publisher(for: VaultStore.willLock, object: store).sink { [weak self] _ in
            self?.cut()
        }.store(in: &watching)
    }

    var isOpen: Bool { server?.isOpen == true }
    var connected: Int { server?.connected ?? 0 }

    private func open() {
        do {
            try server?.open()
        } catch {
            Log.app.error("bridge: did not open: \((error as NSError).code)")
        }
    }

    private func cut() {
        server?.cut()
        question = nil
        stage?.close()
    }

    func answer(_ request: BridgeRequest, from caller: BridgeCaller) async -> BridgeAnswer {
        defer { if case .save(let order) = request { order.password.wipe() } }
        guard store.state == .unlocked else { return .locked }
        switch request {
        case .hello(let origin, let browser):
            return standing(of: origin, in: browser, for: caller)
        case .logins(let url):
            return await logins(for: url)
        case .fill(let id, let url):
            return await fill(id, on: url)
        case .appLogins(let app):
            return caller == .autofill ? await logins(for: app) : .refused(.page)
        case .appFill(let id, let app):
            return caller == .autofill ? await fill(id, in: app) : .refused(.page)
        case .passkeys(let ask):
            return mayAsk(ask, as: caller) ? await passkeys.list(ask) : .refused(.page)
        case .assert(let id, let ask, let hash):
            return mayAsk(ask, as: caller) ? await passkeys.assert(id, ask, over: hash) : .refused(.page)
        case .passkeysNear(let url):
            return caller == .autofill ? .refused(.page) : passkeys.near(url)
        case .codes(let ask):
            return caller == .autofill ? await codes(for: ask) : .refused(.page)
        case .code(let id, let ask):
            return caller == .autofill ? await code(id, for: ask) : .refused(.page)
        case .homes(let relyingParty):
            return caller == .autofill ? await logins(for: "https://\(relyingParty)/") : .refused(.page)
        case .make(let order):
            return caller == .autofill ? await make(order) : .refused(.page)
        case .front:
            return caller == .autofill ? await inFront() : .refused(.page)
        case .find(let word):
            return caller == .autofill ? await find(word) : .refused(.page)
        case .pick(let id):
            return caller == .autofill ? await pick(id) : .refused(.page)
        case .known(let typed):
            return caller == .autofill ? .refused(.page) : await saving.known(typed)
        case .save(let order):
            return caller == .autofill ? .refused(.page) : await saving.save(order)
        case .never(let url):
            return caller == .autofill ? .refused(.page) : saving.never(url)
        case .usernames(let url, let addressesOnly):
            return caller == .autofill ? .refused(.page) : await offers.usernames(on: url, addressesOnly: addressesOnly)
        case .generate(let url, let most):
            return caller == .autofill ? .refused(.page) : await offers.generate(for: url, most: most)
        }
    }

    // MARK: Who

    /// The provider is the only caller the system vouches for, and it names
    /// no page. Anyone else says which page, from what the browser said of
    /// the sender, and asks for that page's relying party or hears `page`.
    private func mayAsk(_ ask: PasskeyAsk, as caller: BridgeCaller) -> Bool {
        guard let url = ask.page else { return caller == .autofill }
        return caller != .autofill && Address.page(url)?.mayName(ask.relyingParty) == true
    }

    /// Safari hands its messages only to the app's own extension, and the
    /// system only to the provider he switched on, so those callers are the
    /// answer. Under a host it is the origin that counts, and only with the
    /// switch on: off, no card is raised and nobody is let in, whatever was
    /// answered before and whatever file Orion still has.
    private func standing(of origin: String?, in browser: String?, for caller: BridgeCaller) -> BridgeAnswer {
        guard caller == .host else { return .ready }
        guard preferences.settings.browser.inOrion else { return .unknown }
        guard let origin, !origin.isEmpty, let browser = browser.flatMap(Browser.init(bundleID:)) else { return .unknown }
        switch preferences.settings.browser.answer(for: origin) {
        case true?: return .ready
        case false?: return .unknown
        case nil:
            ask(about: origin, in: browser)
            return .unknown
        }
    }

    private func ask(about origin: String, in browser: Browser) {
        guard question == nil, let stage else { return }
        let question = BrowserQuestion(browser: browser.name, origin: origin) { [weak self] allowed in
            self?.answered(origin, allowed)
        }
        self.question = question
        stage.show(question)
    }

    private func answered(_ origin: String, _ allowed: Bool) {
        preferences.settings.browser.answer(origin, allowed: allowed)
        question = nil
        stage?.close()
    }

    // MARK: What

    private func logins(for url: String) async -> BridgeAnswer {
        guard let page = Address.page(url) else { return .refused(.page) }
        if store.searchIndex == nil { await store.indexing?.value }
        guard store.state == .unlocked else { return .locked }
        let found = Suggestions.forPage(page, among: store.searchIndex?.logins ?? [])?.entries ?? []
        let listed = found.compactMap { entry -> BridgeLogin? in
            guard Self.refusal(of: entry.item, on: page) == nil else { return nil }
            return BridgeLogin(id: entry.id, title: entry.item.name, username: entry.item.login?.username)
        }
        return .logins(site: page.site, listed)
    }

    private func fill(_ id: String, on url: String) async -> BridgeAnswer {
        guard let page = Address.page(url) else { return .refused(.page) }
        guard let item = store.entry(id: id)?.item else { return .refused(.gone) }
        if let refusal = Self.refusal(of: item, on: page) { return .refused(refusal) }
        guard await reprompt.answer(.fill, on: item) else { return .refused(.declined) }
        // He took a while, and the vault may have moved under the question.
        guard store.state == .unlocked else { return .locked }
        guard let item = store.entry(id: id)?.item, let login = item.login else { return .refused(.gone) }
        if let refusal = Self.refusal(of: item, on: page) { return .refused(refusal) }
        let code = login.totp.flatMap { Totp($0) }?.code(at: store.now())
        return .filled(BridgeFill(username: login.username, password: login.password, code: code))
    }

    /// A login chosen to hold a new passkey is held to the site as a fill
    /// would be. The sheet listed it from `homes`, and a sheet is a caller.
    private func make(_ order: PasskeyOrder) async -> BridgeAnswer {
        guard let page = Address.page("https://\(order.relyingParty)/") else { return .refused(.page) }
        if let id = order.login {
            guard let item = store.entry(id: id)?.item else { return .refused(.gone) }
            if let refusal = Self.refusal(of: item, on: page) { return .refused(refusal) }
        }
        return await passkeys.make(order)
    }

    /// What Quick Access would suggest with this app in front. The system
    /// names the app, so its name and its bundle id are read as the hot key
    /// reads them, and what a name offers still takes a row chosen on the
    /// sheet, which says the name.
    private func suggestions(for app: BridgeApp) async -> [Entry] {
        if store.searchIndex == nil { await store.indexing?.value }
        guard store.state == .unlocked else { return [] }
        let front = FrontApp(pid: 0, bundleID: app.bundleID, name: app.name)
        return Suggestions.forApp(front, among: store.searchIndex?.logins ?? [])?.entries ?? []
    }

    private func logins(for app: BridgeApp) async -> BridgeAnswer {
        let found = await suggestions(for: app)
        guard store.state == .unlocked else { return .locked }
        let listed = found.filter(\.item.isOutstanding).map {
            BridgeLogin(id: $0.id, title: $0.item.name, username: $0.item.login?.username)
        }
        return .logins(site: nil, listed)
    }

    private func fill(_ id: String, in app: BridgeApp) async -> BridgeAnswer {
        guard let item = store.entry(id: id)?.item else { return .refused(.gone) }
        guard item.isOutstanding else { return .refused(.gone) }
        guard await suggestions(for: app).contains(where: { $0.id == id }) else {
            return store.state == .unlocked ? .refused(.page) : .locked
        }
        guard await reprompt.answer(.fill, on: item) else { return .refused(.declined) }
        guard store.state == .unlocked else { return .locked }
        guard let item = store.entry(id: id)?.item, item.isOutstanding, let login = item.login else { return .refused(.gone) }
        return .filled(BridgeFill(username: login.username, password: login.password, code: nil))
    }

    /// The logins listed for what was named that can make a code.
    private func codes(for ask: CodeAsk) async -> BridgeAnswer {
        let listed: BridgeAnswer
        switch ask {
        case .page(let url): listed = await logins(for: url)
        case .app(let app): listed = await logins(for: app)
        }
        guard case .logins(let site, let logins) = listed else { return listed }
        return .logins(site: site, logins.filter { store.entry(id: $0.id)?.item.oneTimeCode != nil })
    }

    /// A fill that hands over one thing. The match, the question and the
    /// second look are `fill`'s, and the code is made after them, so that a
    /// slow finger does not send one that has run out. A login with no code
    /// is refused before anyone is asked.
    private func code(_ id: String, for ask: CodeAsk) async -> BridgeAnswer {
        guard store.entry(id: id)?.item.oneTimeCode != nil else { return .refused(.gone) }
        let filled: BridgeAnswer
        switch ask {
        case .page(let url): filled = await fill(id, on: url)
        case .app(let app): filled = await fill(id, in: app)
        }
        guard case .filled = filled else { return filled }
        guard let totp = store.entry(id: id)?.item.oneTimeCode else { return .refused(.gone) }
        return .code(totp.code(at: store.now()))
    }

    /// What Quick Access would suggest for what the sheet is up over, with
    /// the address it used. The address is the app's and the provider only
    /// hands it back, so a `fill` for a row is held to it as any other is.
    /// A browser that may not be asked, or cannot be, names nothing.
    private func inFront() async -> BridgeAnswer {
        guard let app = front() else { return .front(nil, []) }
        guard app.isBrowser else {
            guard let id = app.bundleID else { return .front(nil, []) }
            let named = BridgeApp(bundleID: id, name: app.name)
            let listed = await logins(for: named)
            guard case .logins(_, let logins) = listed else { return listed }
            return .front(.app(named), logins)
        }
        guard app.browser != nil, let written = await tabs?.address(of: app), Address.page(written) != nil else {
            return .front(nil, [])
        }
        let listed = await logins(for: written)
        guard case .logins(let site, let logins) = listed else { return listed }
        return .front(.page(url: written, site: site), logins)
    }

    /// What a word finds, by the search Quick Access makes: an id, a title
    /// and a username, of a login that has a password to hand over. An empty
    /// word finds nothing, so that no message lists the vault.
    private func find(_ word: String) async -> BridgeAnswer {
        if store.searchIndex == nil { await store.indexing?.value }
        guard store.state == .unlocked else { return .locked }
        let found = store.searchIndex?.search(word) ?? []
        let listed = found.lazy.filter { $0.item.isOutstanding && $0.item.login?.password?.isEmpty == false }
            .prefix(Self.mostFound)
            .map { BridgeLogin(id: $0.id, title: $0.item.name, username: $0.item.login?.username) }
        return .logins(site: nil, Array(listed))
    }

    /// No address holds this to anything, since none is known, so a finger
    /// stands in for it, every time and whatever the item says.
    private func pick(_ id: String) async -> BridgeAnswer {
        guard let item = store.entry(id: id)?.item, item.isOutstanding else { return .refused(.gone) }
        guard await reprompt.confirm(.pick, on: item) else { return .refused(.declined) }
        guard store.state == .unlocked else { return .locked }
        guard let item = store.entry(id: id)?.item, item.isOutstanding, let login = item.login else { return .refused(.gone) }
        return .filled(BridgeFill(username: login.username, password: login.password, code: nil))
    }

    /// Why this item's login is not this page's, and nil when it is. An
    /// address with no scheme is saved under neither, so a page in `http:`
    /// takes it, which is a router at `192.168.1.1` as it was typed.
    static func refusal(of item: Item, on page: Address) -> BridgeRefusal? {
        guard let login = item.login, !item.isInTrash, !item.isArchived else { return .gone }
        let own = login.uris.filter { $0.belongs(to: page) }
        guard !own.isEmpty else { return .page }
        let isPlain = page.written.lowercased().hasPrefix("http:")
        return isPlain && own.allSatisfy(\.isUnderHTTPS) ? .insecure : nil
    }
}

extension Item {
    /// A login that may be handed to anyone: one, and in neither the trash
    /// nor the archive.
    var isOutstanding: Bool { login != nil && !isInTrash && !isArchived }

    /// What makes this login's code, when it has a secret that reads.
    var oneTimeCode: Totp? { login?.totp.flatMap { Totp($0) } }
}

private extension LoginURI {
    var isUnderHTTPS: Bool {
        uri.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("https:")
    }
}
