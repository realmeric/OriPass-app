import AppKit

/// Hands an address to the default browser, and says which app took it.
/// The real one is `SystemSites`; a test, a shot and the canary's tour stand
/// `FakeSites` behind it, since opening an address is a thing only a person
/// may cause.
@MainActor
protocol SiteOpener: AnyObject {
    /// The bundle id of the browser the address was handed to, or nil when
    /// nothing opens it and nothing was done.
    func open(_ url: URL) -> String?
}

/// The default browser, as the system names it for an `https` address.
@MainActor
final class SystemSites: SiteOpener {
    func open(_ url: URL) -> String? {
        let workspace = NSWorkspace.shared
        guard let app = workspace.urlForApplication(toOpen: url),
              let browser = Bundle(url: app)?.bundleIdentifier else { return nil }
        workspace.open(url)
        return browser
    }
}

/// Open & Fill (`docs/look.md`, "The keyboard"). 1Password hands the page
/// to its extension; this app has none, so it opens the login's first
/// address in the default browser and arms one thing: for two minutes, ⌘\
/// in that browser, on a page that is this login's by its own addresses,
/// fills this item and does not ask which. Used once, or two minutes on,
/// or at the lock, it is gone and ⌘\ is the ordinary fill's again
/// (`QuickAccess.autofill`). The browser is asked which page it is on
/// first. On another page nothing of this is typed and the arming stands;
/// in a browser that will not say or cannot be asked, the login leads the
/// panel and waits for ⇧Return.
///
/// It holds an id and a bundle id and a time, and no timer: whether it has
/// lapsed is read from the clock when the key is pressed, so a locked app
/// and an idle one keep nothing awake for it (D18). One for the app, as
/// `Reprompt` is, so the window and Quick Access arm the same thing.
@MainActor
final class ArmedFill {
    /// How long the arming stands.
    static let lasts: TimeInterval = 120

    struct Armed: Equatable {
        let item: String
        /// The browser it was handed to, in lower case.
        let browser: String
        let until: Date
    }

    /// For a test to read. Nil once it has been used, has lapsed and been
    /// noticed, or the vault has locked.
    private(set) var armed: Armed?
    private let sites: SiteOpener

    init(sites: SiteOpener) {
        self.sites = sites
    }

    /// The login's first address, when a browser opens it. Nothing for a
    /// login with no password, since there would be nothing to fill, nor
    /// for an item in Recently Deleted.
    static func address(of item: Item) -> URL? {
        guard !item.isInTrash, let login = item.login, login.password?.isEmpty == false else { return nil }
        let first = login.uris.first { !$0.uri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return first.flatMap { ItemDetail.Website(id: 0, address: $0.uri).link }
    }

    static func canOpen(_ item: Item) -> Bool { address(of: item) != nil }

    /// Opens the address and arms the item for the browser that took it.
    /// An earlier arming is gone either way: it was for another page.
    @discardableResult
    func open(_ item: Item, at now: Date) -> Bool {
        armed = nil
        guard let url = Self.address(of: item), let browser = sites.open(url) else { return false }
        armed = Armed(item: item.id, browser: browser.lowercased(), until: now.addingTimeInterval(Self.lasts))
        return true
    }

    /// The id of the item armed for the app in front, which is left armed:
    /// whether it is used depends on the page, and that is asked after
    /// this. A lapsed arming is dropped; one for another browser is left
    /// as it is, since the page it opened is still waiting.
    func item(for app: FrontApp, at now: Date) -> String? {
        guard let armed else { return nil }
        guard now < armed.until else {
            self.armed = nil
            return nil
        }
        return app.bundleID?.lowercased() == armed.browser ? armed.item : nil
    }

    /// The same, and used: it is armed no longer.
    func take(for app: FrontApp, at now: Date) -> String? {
        guard let item = item(for: app, at: now) else { return nil }
        armed = nil
        return item
    }

    func clear() {
        armed = nil
    }
}
