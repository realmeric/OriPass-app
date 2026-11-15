import AppKit
import XCTest
@testable import OriPass

/// A browser's tab for a test: it says what it was told to, after as long
/// as it was told to take, and counts how often it was asked.
private final class ToldTab: TabAsker {
    var written: String?
    var delay: UInt64
    private(set) var asked = 0

    init(_ written: String?, after delay: UInt64 = 0) {
        self.written = written
        self.delay = delay
    }

    func address(of app: FrontApp) async -> String? {
        asked += 1
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        return written
    }
}

@MainActor
final class FrontAppTests: XCTestCase {
    private let spotify = FrontApp(pid: 1, bundleID: "com.spotify.client", name: "Spotify")
    private let safari = FrontApp(pid: 2, bundleID: "com.apple.Safari", name: "Safari")

    private var up: [QuickAccess] = []
    private var pasteboards: [NSPasteboard] = []

    // MARK: What the sheet is up over

    func testAnAppWithAPlaceInTheDockIsWhatTheSheetIsUpOver() {
        XCTAssertTrue(FrontApp.isSomeonesApp(policy: .regular, path: URL(fileURLWithPath: "/Applications/Orion.app"),
                                             bundleID: "com.kagi.kagimacOS", pid: 1))
    }

    func testNeitherTheProviderNorTheSystemsServicesAre() {
        let appex = URL(fileURLWithPath: "/Applications/OriPass.app/Contents/PlugIns/OriPassAutoFill.appex")
        XCTAssertFalse(FrontApp.isSomeonesApp(policy: .prohibited, path: appex, bundleID: "com.meric.oripass.autofill", pid: 1))
        XCTAssertFalse(FrontApp.isSomeonesApp(policy: .regular, path: appex, bundleID: "com.apple.other", pid: 1),
                       "whatever an extension says of itself")
        XCTAssertFalse(FrontApp.isSomeonesApp(policy: .accessory, path: URL(fileURLWithPath: "/System/Library/Agent.app"),
                                              bundleID: "com.apple.agent", pid: 1))
    }

    /// Opened from its window with the sheet waiting, which is the hand-over
    /// over a shut vault, OriPass is in front and the sheet is not for it.
    func testOriPassIsNot() {
        let path = URL(fileURLWithPath: "/Applications/OriPass.app")
        XCTAssertFalse(FrontApp.isSomeonesApp(policy: .regular, path: path, bundleID: AppInfo.bundleID, pid: 1))
        XCTAssertFalse(FrontApp.isSomeonesApp(policy: .regular, path: path, bundleID: "other",
                                              pid: ProcessInfo.processInfo.processIdentifier))
    }

    func testTheSheetIsNeverUpOverThisProcess() {
        XCTAssertNotEqual(FrontApp.behindTheSheet()?.pid, ProcessInfo.processInfo.processIdentifier)
    }
    private var presented = 0

    override func tearDown() async throws {
        up.forEach { $0.end() }
        up = []
        pasteboards.forEach { $0.releaseGlobally() }
        pasteboards = []
    }

    private func demoStore(_ items: [JSONValue]? = nil) async -> VaultStore {
        let vault = DemoVault.objects()
        let backend = FakeBackend(items: items ?? vault.items, folders: vault.folders, password: DemoVault.password)
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes(DemoVault.password))
        await store.indexing?.value
        return store
    }

    /// The panel over the demo vault, ordered in nowhere and not yet shown.
    private func quickAccess(over store: VaultStore? = nil, in front: FrontApp?, tabs: TabAsker? = nil,
                             recents: Recents = Recents(file: nil)) async -> QuickAccess {
        let board = NSPasteboard(name: NSPasteboard.Name("oripass-test-\(UUID().uuidString)"))
        pasteboards.append(board)
        let opened: VaultStore
        if let store { opened = store } else { opened = await demoStore() }
        let quick = QuickAccess(door: Door(store: opened, clipboard: Clipboard(pasteboard: board)), recents: recents,
                                front: { front }, tabs: tabs, present: { [weak self] _ in self?.presented += 1 },
                                pointer: { .zero }, screens: { [NSRect(x: 0, y: 0, width: 1512, height: 982)] })
        up.append(quick)
        return quick
    }

    private func logins() async throws -> [Suggestions.Login] {
        let store = await demoStore()
        return try XCTUnwrap(store.searchIndex).logins
    }

    private func id(of title: String, in quick: QuickAccess) throws -> String {
        try XCTUnwrap(quick.door.store.shelves.all.first { $0.item.name == title }, "no \(title)").id
    }

    // MARK: An app

    func testSpotifysAppSuggestsTheSpotifyLogin() async throws {
        // The demo's login is on accounts.spotify.com, and the app is
        // com.spotify.client: client.spotify.com, whose site is spotify.com.
        let listed = try await logins()
        let found = try XCTUnwrap(Suggestions.forApp(spotify, among: listed))
        XCTAssertEqual(found.entries.map(\.item.name), ["Spotify"])
        XCTAssertEqual(found.entries.first?.item.iconHost, "accounts.spotify.com")
        XCTAssertEqual(found.heading, "Spotify")

        // The bundle id says who made the app. Under a name that is not the
        // site's, that is not enough.
        let unnamed = FrontApp(pid: 1, bundleID: "com.spotify.client", name: "Müzik")
        XCTAssertNil(Suggestions.forApp(unnamed, among: listed))
    }

    func testAnAppsNameIsTriedAsASiteAndThenAsATitle() async throws {
        let listed = try await logins()
        // Slack's bundle id read backwards is slackmacgap.tinyspeck.com.
        let slack = FrontApp(pid: 1, bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
        XCTAssertEqual(Suggestions.forApp(slack, among: listed)?.entries.map(\.item.name), ["Slack"])
        // No address at all, and a title that is the app's name.
        let wifi = FrontApp(pid: 1, bundleID: nil, name: "ev wi-fi")
        XCTAssertEqual(Suggestions.forApp(wifi, among: listed)?.entries.map(\.item.name), ["Ev Wi-Fi"])
        // "Digital Ocean" is digitalocean.com's first label once its space is gone.
        let ocean = FrontApp(pid: 1, bundleID: "invalid.example.app", name: "Digital Ocean")
        XCTAssertEqual(Suggestions.forApp(ocean, among: listed)?.entries.map(\.item.name), ["Digital Ocean"])

        let finder = FrontApp(pid: 1, bundleID: "com.apple.finder", name: "Finder")
        XCTAssertTrue(listed.contains { $0.entry.item.name == "Apple Account" })
        XCTAssertNil(Suggestions.forApp(finder, among: listed), "Finder is Apple's and is not Apple's site")
        XCTAssertNil(Suggestions.forApp(FrontApp(pid: 1, bundleID: nil, name: ""), among: listed))
        let note = FrontApp(pid: 1, bundleID: "invalid.example.app", name: "Yazılım lisansı")
        XCTAssertNil(Suggestions.forApp(note, among: listed), "a note is not a login, whatever it is called")
    }

    func testWithSpotifyInFrontThePanelComesUpLedByItsLogin() async throws {
        let quick = await quickAccess(in: spotify)
        quick.recents.use(try id(of: "GitHub", in: quick))
        quick.recents.use(try id(of: "Spotify", in: quick))
        quick.show()
        XCTAssertEqual(quick.inFront, spotify)
        XCTAssertEqual(quick.rows.map(\.item.name), ["Spotify", "GitHub"], "and it is not listed twice")
        XCTAssertEqual(quick.headings, [0: "Spotify", 1: "Recently Used"])
        XCTAssertEqual(quick.selected, 0)
        let tall: CGFloat = 58 + 2 * 36 + 2 * 24 + 8 + 40
        XCTAssertEqual(quick.panel.frame.height, tall, "two rows, each under a heading")

        quick.query = "git"
        XCTAssertTrue(quick.headings.isEmpty, "what is typed is looked for in the whole vault")
        XCTAssertEqual(quick.rows.map(\.item.name), ["GitHub", "Git imza anahtarı", "Digital Ocean"])
        quick.query = ""
        XCTAssertEqual(quick.rows.first?.item.name, "Spotify")

        quick.pressReturn()
        XCTAssertFalse(quick.isUp)
        XCTAssertEqual(pasteboards.last?.string(forType: .string),
                       quick.door.store.shelves.all.first { $0.item.name == "Spotify" }?.item.login?.password)
        XCTAssertTrue(quick.headings.isEmpty, "put away, it suggests nothing")
        XCTAssertEqual(quick.rows.map(\.item.name), ["Spotify", "GitHub"], "only the used are kept for the next time")
        XCTAssertEqual(quick.inFront, spotify, "where a login would be typed is kept")
    }

    func testWithNothingToSuggestThePanelIsAsItWas() async throws {
        let quick = await quickAccess(in: FrontApp(pid: 1, bundleID: "invalid.example.files", name: "Dosyalar"))
        quick.recents.use(try id(of: "GitHub", in: quick))
        quick.show()
        XCTAssertEqual(quick.rows.map(\.item.name), ["GitHub"])
        XCTAssertTrue(quick.headings.isEmpty)
        let tall: CGFloat = 58 + 36 + 8 + 40
        XCTAssertEqual(quick.panel.frame.height, tall)
    }

    func testThisAppInFrontIsNobody() {
        XCTAssertNotEqual(FrontApp.now()?.pid, ProcessInfo.processInfo.processIdentifier)
    }

    // MARK: A browser

    func testTheThreeBrowsersAreKnownByTheirIdsAndAskedInTheirOwnWords() {
        XCTAssertEqual(Browser(bundleID: "com.apple.Safari"), .safari)
        XCTAssertEqual(Browser(bundleID: "com.brave.Browser"), .brave)
        XCTAssertEqual(Browser(bundleID: "com.kagi.kagimacOS"), .orion)
        XCTAssertNil(Browser(bundleID: "com.spotify.client"))
        XCTAssertNil(spotify.browser)
        XCTAssertEqual(safari.browser, .safari)

        // As AppleScript's own events print: URL of document 1, URL of
        // active tab of window 1, URL of current tab of window 1.
        func words(_ browser: Browser) -> String {
            String(describing: browser.tabAddress).replacingOccurrences(of: " ", with: "")
        }
        XCTAssertTrue(words(.safari).contains("'obj'{'want':'prop','form':'prop','seld':'pURL','from':'obj'{"
                + "'want':'docu','form':'indx','seld':1,'from':null()}}"), words(.safari))
        XCTAssertTrue(words(.brave).contains("'seld':'URL','from':'obj'{'want':'prop','form':'prop','seld':'acTa',"
                + "'from':'obj'{'want':'cwin','form':'indx','seld':1,'from':null()}}"), words(.brave))
        XCTAssertTrue(words(.orion).contains("'seld':'pURL','from':'obj'{'want':'prop','form':'prop','seld':'cTab',"
                + "'from':'obj'{'want':'cwin','form':'indx','seld':1,'from':null()}}"), words(.orion))

        let event = AppleEventTabs.question(Browser.safari.tabAddress, to: 4242)
        XCTAssertEqual(event.eventClass, AEEventClass(kAECoreSuite))
        XCTAssertEqual(event.eventID, AEEventID(kAEGetData))
        XCTAssertEqual(event.attributeDescriptor(forKeyword: keyAddressAttr)?.descriptorType, typeKernelProcessID)
        XCTAssertEqual(event.paramDescriptor(forKeyword: keyDirectObject)?.descriptorType, typeObjectSpecifier)
    }

    func testOnAPageTheLoginForItIsTheFirstRowUnderTheSitesName() async throws {
        let tab = ToldTab("https://github.com/login?return_to=x")
        let quick = await quickAccess(in: safari, tabs: tab)
        quick.recents.use(try id(of: "Spotify", in: quick))
        quick.show()
        XCTAssertEqual(quick.rows.map(\.item.name), ["Spotify"], "nothing is suggested until the browser has said")
        XCTAssertTrue(quick.headings.isEmpty)
        await quick.askingTab?.value
        XCTAssertEqual(tab.asked, 1)
        XCTAssertEqual(quick.rows.map(\.item.name), ["GitHub", "Spotify"])
        XCTAssertEqual(quick.headings, [0: "github.com", 1: "Recently Used"])
        XCTAssertEqual(quick.selected, 0)
        XCTAssertEqual(quick.offer.enter, "Copy Password")

        quick.pressReturn()
        XCTAssertEqual(pasteboards.last?.string(forType: .string),
                       quick.door.store.shelves.all.first { $0.item.name == "GitHub" }?.item.login?.password)
    }

    func testASuggestionThatArrivesLateIsUnderReturnUnlessHeHasMoved() async throws {
        let quick = await quickAccess(in: safari, tabs: ToldTab("https://github.com", after: 30_000_000))
        quick.recents.use(try id(of: "Slack", in: quick))
        quick.recents.use(try id(of: "Spotify", in: quick))
        quick.show()
        XCTAssertEqual(quick.rows.map(\.item.name), ["Spotify", "Slack"])
        await quick.askingTab?.value
        XCTAssertEqual(quick.rows[quick.selected].item.name, "GitHub", "he had not moved")
        quick.close()

        quick.show()
        quick.move(by: 1)
        XCTAssertEqual(quick.rows[quick.selected].item.name, "Slack")
        await quick.askingTab?.value
        XCTAssertEqual(quick.rows.map(\.item.name), ["GitHub", "Spotify", "Slack"])
        XCTAssertEqual(quick.rows[quick.selected].item.name, "Slack", "the row he went to is still the one")
    }

    func testForABrowserThatWillNotSayNothingIsSuggested() async throws {
        // Automation refused is an asker that answers nothing. So is a
        // blank tab, and so is a page of the browser's own.
        for written in [nil, "", "about:blank", "favorites://"] {
            let brave = FrontApp(pid: 3, bundleID: "com.brave.Browser", name: "Brave Browser")
            let quick = await quickAccess(in: brave, tabs: ToldTab(written))
            quick.show()
            await quick.askingTab?.value
            XCTAssertTrue(quick.rows.isEmpty)
            quick.end()
        }
        // The demo has logins for apple.com and for google.com, and a
        // browser's maker is not the page it is on.
        let chrome = FrontApp(pid: 4, bundleID: "com.google.Chrome", name: "Google Chrome")
        for (browser, tab) in [(safari, ToldTab(nil) as TabAsker?), (chrome, nil)] {
            let quick = await quickAccess(in: browser, tabs: tab)
            quick.recents.use(try id(of: "Slack", in: quick))
            quick.show()
            await quick.askingTab?.value
            XCTAssertEqual(quick.rows.map(\.item.name), ["Slack"], browser.name)
            XCTAssertTrue(quick.headings.isEmpty, browser.name)
        }
    }

    /// The real asker, with nobody to ask: a browser that has quit since
    /// the key was pressed. No event reaches any app, so macOS asks
    /// nothing, and the error comes back as no answer.
    func testTheRealAskerSaysNothingWhenTheEventFails() async throws {
        let gone = Process()
        gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try gone.run()
        gone.waitUntilExit()
        let started = Date()
        let quit = FrontApp(pid: gone.processIdentifier, bundleID: "com.apple.Safari", name: "Safari")
        let written = await AppleEventTabs().address(of: quit)
        XCTAssertNil(written)
        XCTAssertLessThan(Date().timeIntervalSince(started), AppleEventTabs.patience + 1)
        let unasked = await AppleEventTabs().address(of: spotify)
        XCTAssertNil(unasked, "an app that is no browser is sent nothing")
    }

    func testAnAppThatIsNoBrowserIsAskedNothing() async {
        let tab = ToldTab("https://github.com")
        let quick = await quickAccess(in: spotify, tabs: tab)
        quick.show()
        XCTAssertNil(quick.askingTab)
        XCTAssertEqual(tab.asked, 0)
        XCTAssertEqual(quick.rows.map(\.item.name), ["Spotify"])
    }

    /// D18's hundred milliseconds are from the key to the panel. A browser
    /// that takes five seconds over its answer, which is longer than one
    /// that was refused takes to say so, holds none of it up: `show` has
    /// ordered the panel in before the browser is heard from.
    func testTheKeyDoesNotWaitForTheBrowser() async throws {
        let tab = ToldTab("https://github.com", after: 5_000_000_000)
        let quick = await quickAccess(over: await demoStore(ScrollTrace.items(2000)), in: safari, tabs: tab)
        _ = PublicSuffix.standard.count
        var took: [Double] = []
        for _ in 0..<9 {
            let started = DispatchTime.now().uptimeNanoseconds
            quick.show()
            took.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            XCTAssertNotNil(quick.askingTab, "still waiting")
            quick.close()
            XCTAssertNil(quick.askingTab, "and no longer, once the panel has gone")
        }
        XCTAssertEqual(presented, 9)
        print("FrontAppTests: show over a browser that has not answered:",
              took.map { String(format: "%.2f", $0) }.joined(separator: " "), "ms")
        XCTAssertLessThan(took.sorted()[took.count / 2], 10, "\(took)")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(quick.rows.isEmpty, "an answer to a panel that has gone is dropped")
    }

    /// The same key over an app, where the logins are looked through before
    /// the panel is ordered in: two thousand of them, whose addresses the
    /// index has read already.
    func testSuggestingByTheAppAloneAtTwoThousandLoginsIsWellInsideTheBudget() async throws {
        let scroll = FrontApp(pid: 1, bundleID: "invalid.example.app", name: "Ilgaz 72")
        let quick = await quickAccess(over: await demoStore(ScrollTrace.items(2000)), in: scroll)
        _ = PublicSuffix.standard.count
        var took: [Double] = []
        for _ in 0..<9 {
            let started = DispatchTime.now().uptimeNanoseconds
            quick.show()
            took.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            XCTAssertEqual(quick.rows.count, 1)
            XCTAssertEqual(quick.rows.first?.item.name, "Ilgaz 72")
            quick.close()
        }
        print("FrontAppTests: show with 2000 logins looked through:",
              took.map { String(format: "%.2f", $0) }.joined(separator: " "), "ms")
        XCTAssertLessThan(took.sorted()[took.count / 2], 10, "\(took)")
    }

    // MARK: The lock

    /// The first question to a browser raises macOS's own about
    /// Automation. It is not put while there is nothing to suggest.
    func testABrowserIsAskedOnlyOnceTheVaultIsOpen() async throws {
        let tab = ToldTab("https://github.com/login")
        let nobody = FakeBackend(items: [], folders: [], password: "right")
        nobody.isLoggedIn = false
        let signedOut = await quickAccess(over: VaultStore(backend: nobody), in: safari, tabs: tab)
        signedOut.show()
        XCTAssertNil(signedOut.askingTab)
        XCTAssertEqual(tab.asked, 0, "nobody is signed in")

        let store = await demoStore()
        await store.lock()
        let quick = await quickAccess(over: store, in: safari, tabs: tab)
        quick.show()
        XCTAssertTrue(quick.isUp)
        XCTAssertNil(quick.askingTab)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(tab.asked, 0, "the vault is shut")

        quick.unlock(with: SecretBytes("not-the-password"))
        await quick.unlocking?.value
        XCTAssertEqual(tab.asked, 0, "and still is")

        quick.unlock(with: SecretBytes(DemoVault.password))
        await quick.unlocking?.value
        await store.indexing?.value
        await quick.askingTab?.value
        XCTAssertEqual(tab.asked, 1, "opened through the panel, the browser behind it is asked")
        XCTAssertEqual(quick.rows.first?.item.name, "GitHub")
        XCTAssertEqual(quick.headings[0], "github.com")

        // Open already, the key asks as it did.
        quick.close()
        quick.show()
        await quick.askingTab?.value
        XCTAssertEqual(tab.asked, 2)
    }

    func testALockForgetsWhereALoginWouldBeTyped() async throws {
        let quick = await quickAccess(in: spotify)
        quick.show()
        quick.close()
        XCTAssertEqual(quick.inFront, spotify)
        await quick.door.store.lock()
        XCTAssertNil(quick.inFront)
    }

    func testALockLeavesNothingSuggested() async throws {
        let quick = await quickAccess(in: safari, tabs: ToldTab("https://github.com/login"))
        quick.show()
        await quick.askingTab?.value
        weak var suggested = quick.rows.first
        XCTAssertNotNil(suggested)
        await quick.door.store.lock()
        XCTAssertFalse(quick.isUp)
        XCTAssertTrue(quick.rows.isEmpty)
        XCTAssertTrue(quick.headings.isEmpty)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(suggested, "the login it listed went with the vault")

        // Raised again over the shut vault it is the lock, and the browser's
        // answer changes nothing of that.
        quick.show()
        await quick.askingTab?.value
        XCTAssertTrue(quick.rows.isEmpty)
        XCTAssertTrue(quick.headings.isEmpty)
        XCTAssertEqual(quick.panel.frame.height, 58 + 56)
    }
}
