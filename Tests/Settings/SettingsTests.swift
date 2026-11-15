import AppKit
import Carbon.HIToolbox
import XCTest
@testable import OriPass

/// The one value every choice is in: what it is before anything is chosen,
/// what a file that is partly wrong costs, and what follows a change. In a
/// suite of the test's own, which is removed when the test is over.
@MainActor
final class SettingsTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "com.meric.oripass.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
    }

    private func read(_ json: String) throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    }

    // MARK: The defaults

    func testTheFiguresEarlierCardsWroteAreTheDefaults() {
        let settings = Settings()

        for condition in LockPolicy.Condition.allCases {
            XCTAssertTrue(settings.lock.locks(condition), "\(condition)")
        }
        XCTAssertEqual(settings.lock.idleMinutes, 10)
        XCTAssertEqual(settings.lock.fingerDays, 14)
        XCTAssertEqual(settings.lock.fingerLifetime, 14 * 24 * 60 * 60)
        XCTAssertNil(settings.lock.unlockWithFinger, "nobody has been asked")
        XCTAssertEqual(settings.clipboard.clearSeconds, 90)
        XCTAssertTrue(settings.clipboard.staysOnThisMac)
        XCTAssertFalse(settings.details.revealWithOption)
        XCTAssertTrue(settings.privacy.siteIcons)
        XCTAssertFalse(settings.privacy.breachCheck, "a request he did not make by clicking (D13)")
        XCTAssertFalse(settings.privacy.twoFactorCheck)
        XCTAssertFalse(settings.fill.pressesReturn)
        XCTAssertEqual(settings.menuBar, MenuBarChoices(showsMark: true, keepsDock: true))
        XCTAssertEqual(settings.shortcuts.all.mapValues(\.words),
                       [.quickAccess: "⌥⌘\\", .lock: "⇧⌘L", .fill: "⌘\\"])
        XCTAssertEqual(settings.list.sort, .title)
        XCTAssertFalse(settings.list.isReversed)
        XCTAssertEqual(settings.list.category, .all)
        XCTAssertEqual(settings.look.theme, .system)
        XCTAssertEqual(settings.look.density, .comfortable)
        XCTAssertEqual(settings.look.zoom, .actual)
        XCTAssertEqual(settings.engine.bwPath, "")
    }

    /// Every part and every field of it, by the names the file has.
    static func fields(of settings: Settings = Settings()) -> [String] {
        Mirror(reflecting: settings).children.flatMap { part -> [String] in
            let name = part.label ?? ""
            let inside = Mirror(reflecting: part.value).children.compactMap(\.label)
            return inside.isEmpty ? [name] : inside.map { "\(name).\($0)" }
        }
    }

    func testNoFieldIsNamedAfterASecret() {
        let fields = Self.fields()
        XCTAssertEqual(fields.count, 34, "\(fields)")
        for field in fields {
            for word in ["password", "session", "secret"] {
                XCTAssertFalse(field.localizedCaseInsensitiveContains(word), field)
            }
        }
    }

    // MARK: A file that is partly wrong

    func testAnEmptyObjectIsTheDefaults() throws {
        XCTAssertEqual(try read("{}"), Settings())
    }

    func testAMissingFieldTakesItsDefaultAndTheOnesBesideItAreKept() throws {
        let settings = try read(#"{"lock": {"idleMinutes": 3}, "fill": {"pressesReturn": true}}"#)

        XCTAssertEqual(settings.lock.idleMinutes, 3)
        XCTAssertEqual(settings.lock.fingerDays, 14)
        XCTAssertTrue(settings.lock.onSleep)
        XCTAssertTrue(settings.fill.pressesReturn)
        XCTAssertEqual(settings.clipboard, ClipboardChoices())
    }

    func testAnUnknownFieldAndAnUnknownPartAreReadPast() throws {
        let settings = try read("""
            {"lock": {"idleMinutes": 3, "onEclipse": true}, "weather": {"city": "Ankara"},
             "menuBar": {"keepsDock": false}}
            """)

        XCTAssertEqual(settings.lock.idleMinutes, 3)
        XCTAssertFalse(settings.menuBar.keepsDock)
        XCTAssertTrue(settings.menuBar.showsMark)
    }

    func testAFieldOfAnotherTypeTakesItsDefaultAndCostsNothingElse() throws {
        let settings = try read("""
            {"lock": {"idleMinutes": "soon", "onSleep": false, "unlockWithFinger": "yes"},
             "clipboard": {"clearSeconds": true, "staysOnThisMac": false},
             "look": {"theme": "sepia", "density": "compact", "zoom": 7},
             "list": {"sort": "colour", "category": "login", "isReversed": true},
             "shortcuts": {"bound": 4},
             "privacy": "none", "engine": {"bwPath": "/usr/local/bin/bw"}}
            """)

        XCTAssertEqual(settings.lock.idleMinutes, 10)
        XCTAssertFalse(settings.lock.onSleep)
        XCTAssertNil(settings.lock.unlockWithFinger)
        XCTAssertEqual(settings.clipboard.clearSeconds, 90)
        XCTAssertFalse(settings.clipboard.staysOnThisMac)
        XCTAssertEqual(settings.look.theme, .system)
        XCTAssertEqual(settings.look.density, .compact)
        XCTAssertEqual(settings.look.zoom, .actual)
        XCTAssertEqual(settings.list.sort, .title)
        XCTAssertEqual(settings.list.category, .login)
        XCTAssertTrue(settings.list.isReversed)
        XCTAssertEqual(settings.shortcuts, ShortcutChoices())
        XCTAssertEqual(settings.privacy, PrivacyChoices())
        XCTAssertEqual(settings.engine.bwPath, "/usr/local/bin/bw")
    }

    func testWhatWillNotReadAtAllIsTheDefaultsAndTheNextChangeWritesOverIt() {
        defaults.set(Data("not json".utf8), forKey: SettingsStore.key)
        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.settings, Settings())

        preferences.settings.fill.pressesReturn = true
        XCTAssertTrue(Preferences(defaults: defaults).settings.fill.pressesReturn)
    }

    // MARK: Kept

    func testEveryChoiceIsOneValueUnderOneKeyAndComesBackAsItWas() {
        let preferences = Preferences(defaults: defaults)
        XCTAssertNil(defaults.persistentDomain(forName: suite), "nothing is written until something is chosen")

        var chosen = Settings()
        chosen.lock.set(.screenSaver, to: false)
        chosen.lock.idleMinutes = 4
        chosen.lock.fingerDays = 30
        chosen.lock.unlockWithFinger = false
        chosen.clipboard = { var choices = ClipboardChoices(); choices.clearSeconds = 30; return choices }()
        chosen.details.revealWithOption = true
        chosen.privacy.siteIcons = false
        chosen.privacy.breachCheck = true
        chosen.menuBar.showsMark = false
        chosen.shortcuts.set(.showApp, to: HotKey(key: UInt32(kVK_ANSI_O), carbon: UInt32(cmdKey | optionKey)))
        chosen.shortcuts.set(.lock, to: nil)
        chosen.list.sort = .created
        chosen.look.theme = .dark
        chosen.look.zoom = .large
        chosen.engine.bwPath = "/usr/local/bin/bw"
        preferences.settings = chosen

        XCTAssertEqual(defaults.persistentDomain(forName: suite)?.keys.sorted(), [SettingsStore.key])
        XCTAssertEqual(Preferences(defaults: defaults).settings, chosen)
        XCTAssertEqual(preferences.now, chosen, "and whoever is off the main thread reads the same")
    }

    func testWithoutDefaultsNothingIsReadAndNothingIsKept() {
        let preferences = Preferences()
        preferences.settings.fill.pressesReturn = true

        XCTAssertTrue(preferences.now.fill.pressesReturn)
        XCTAssertFalse(Preferences().settings.fill.pressesReturn)
    }

    // MARK: The keys

    func testAKeyTakenAwayStaysAwayAndOneForgottenIsItsDefaultAgain() {
        var shortcuts = ShortcutChoices()
        XCTAssertNil(shortcuts.key(for: .showApp))

        shortcuts.set(.quickAccess, to: nil)
        XCTAssertNil(shortcuts.key(for: .quickAccess))
        XCTAssertEqual(Set(shortcuts.all.keys), [.lock, .fill])

        shortcuts.forget(.quickAccess)
        XCTAssertEqual(shortcuts.key(for: .quickAccess), HotKeyAction.quickAccess.fallback)
    }

    // MARK: What follows a change

    private final class Hands {
        var marks: [Bool] = []
        var presences = 0
        var keys: [[HotKeyAction: HotKey]] = []
        var appearances: [NSAppearance.Name?] = []
        var recounts = 0
        var hosts: [BrowserChoices] = []
        var agents: [SSHChoices] = []

        var hands: Following.Hands {
            Following.Hands(showMark: { self.marks.append($0) },
                            updatePresence: { self.presences += 1 },
                            applyKeys: { self.keys.append($0) },
                            setAppearance: { self.appearances.append($0?.name) },
                            recount: { self.recounts += 1 },
                            followHost: { self.hosts.append($0) },
                            followAgent: { self.agents.append($0) })
        }
    }

    private func turn() async {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }

    func testTheMarkAndTheAppearanceAreSetAtTheStartAndTheKeysAreLeftToTheLaunch() async {
        let preferences = Preferences()
        preferences.settings.look.theme = .dark
        let hands = Hands()
        let following = Following(preferences, hands: hands.hands)
        await turn()

        XCTAssertEqual(hands.marks, [true])
        XCTAssertEqual(hands.appearances, [.darkAqua])
        XCTAssertEqual(hands.keys.count, 0)
        XCTAssertEqual(hands.recounts, 0)
        _ = following
    }

    func testOrionsFileFollowsFromTheStartAndAtEachChange() async {
        let preferences = Preferences()
        let hands = Hands()
        let following = Following(preferences, hands: hands.hands)
        await turn()
        XCTAssertEqual(hands.hosts, [BrowserChoices()])

        preferences.settings.browser.inOrion = true
        preferences.settings.browser.answer("chrome-extension://abc/", allowed: true)
        await turn()
        XCTAssertEqual(hands.hosts.count, 3)
        XCTAssertEqual(hands.hosts.last?.inOrion, true)
        XCTAssertEqual(hands.hosts.last?.allowed, ["chrome-extension://abc/"])

        preferences.settings.lock.idleMinutes = 5
        await turn()
        XCTAssertEqual(hands.hosts.count, 3)
        _ = following
    }

    func testTheAgentHearsItsChoicesAtTheStartAndWhenTheyMove() async {
        let preferences = Preferences()
        let hands = Hands()
        let following = Following(preferences, hands: hands.hands)
        preferences.settings.lock.idleMinutes = 5
        XCTAssertEqual(hands.agents, [SSHChoices()])
        preferences.settings.ssh.isOn = true
        preferences.settings.ssh.approval = .eachUse
        XCTAssertEqual(hands.agents.map(\.isOn), [false, true, true])
        XCTAssertEqual(hands.agents.last?.approval, .eachUse)
        _ = following
    }

    func testEachStandingThingFollowsItsOwnChoiceAndNoOther() async {
        let preferences = Preferences()
        let hands = Hands()
        let following = Following(preferences, hands: hands.hands)
        await turn()
        let presences = hands.presences

        preferences.settings.fill.pressesReturn = true
        preferences.settings.lock.idleMinutes = 5
        await turn()
        XCTAssertEqual(hands.marks, [true])
        XCTAssertEqual(hands.presences, presences)
        XCTAssertEqual(hands.appearances, [nil])
        XCTAssertEqual(hands.keys.count, 0)
        XCTAssertEqual(hands.recounts, 0)

        preferences.settings.menuBar.showsMark = false
        preferences.settings.menuBar.keepsDock = false
        await turn()
        XCTAssertEqual(hands.marks, [true, false, false])
        XCTAssertEqual(hands.presences, presences + 2)

        preferences.settings.look.theme = .light
        preferences.settings.look.theme = .system
        XCTAssertEqual(hands.appearances, [nil, .aqua, nil])

        preferences.settings.shortcuts.set(.lock, to: nil)
        XCTAssertEqual(hands.keys.map { Set($0.keys) }, [[.quickAccess, .fill]])

        preferences.settings.privacy.siteIcons = false
        await turn()
        XCTAssertEqual(hands.recounts, 0, "the icons are read as a row is drawn")
        preferences.settings.privacy.breachCheck = true
        preferences.settings.privacy.twoFactorCheck = true
        await turn()
        XCTAssertEqual(hands.recounts, 2)
        _ = following
    }

    func testAPasswordHealthSwitchTurnedOnWhileUnlockedIsAskedAboutAtOnce() async {
        let preferences = Preferences()
        let fetcher = AskedRanges()
        let store = VaultStore(backend: DemoVault.backend(),
                               breaches: Breaches(fetcher: fetcher, gap: 0) { preferences.now.privacy.breachCheck })
        let following = Following(preferences, hands: .init(recount: { [weak store] in store?.recount() }))
        await store.unlock(password: SecretBytes(DemoVault.password))
        await store.counting?.value
        let before = await fetcher.count
        XCTAssertEqual(before, 0, "off, nobody is asked")
        XCTAssertFalse(store.cards.contains(.vulnerable))

        preferences.settings.privacy.breachCheck = true
        await turn()
        await store.counting?.value

        let after = await fetcher.count
        XCTAssertGreaterThan(after, 0)
        XCTAssertTrue(store.cards.contains(.vulnerable))
        await store.lock()
        _ = following
    }

    // MARK: Read where they are used

    func testTheSealsDaysAreTheSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("op-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = Preferences()
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let seal = PasswordSeal(directory: directory, enclave: FakeEnclave(), now: { clock },
                               lifetime: { preferences.now.lock.fingerLifetime })
        try seal.seal(SecretBytes("KNOWN-PASSWORD"))

        clock.addTimeInterval(3 * 24 * 60 * 60)
        XCTAssertEqual(seal.standing, .ready)
        preferences.settings.lock.fingerDays = 2
        XCTAssertEqual(seal.standing, .expired)
        preferences.settings.lock.fingerDays = 14
        XCTAssertEqual(seal.standing, .ready)
    }

    func testACopyWaitsTheSettingsSecondsAndStaysOnThisMacUnlessHeSaysOtherwise() async {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("oripass-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let preferences = Preferences()
        preferences.settings.clipboard.clearSeconds = 0.05
        let clipboard = Clipboard(pasteboard: pasteboard, choices: { preferences.settings.clipboard })

        clipboard.copy("CANARY-1")
        await clipboard.clearing?.value
        XCTAssertNil(pasteboard.string(forType: .string))

        XCTAssertEqual(Clipboard.options(for: ClipboardChoices()), .currentHostOnly)
        preferences.settings.clipboard.staysOnThisMac = false
        XCTAssertEqual(Clipboard.options(for: preferences.settings.clipboard), [])
    }

    func testThePathToTheEngineIsLookedAtBeforeHomebrews() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("op-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("bw")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let preferences = Preferences()

        preferences.settings.engine.bwPath = binary.path
        XCTAssertEqual(preferences.bwFinder(nil)?.path, binary.path)
    }

    func testTheThemeIsAnAppearanceOrTheSystems() {
        XCTAssertNil(Theme.system.appearance)
        XCTAssertEqual(Theme.light.appearance?.name, .aqua)
        XCTAssertEqual(Theme.dark.appearance?.name, .darkAqua)
    }
}

private actor AskedRanges: BreachFetcher {
    private(set) var count = 0

    func fetch(prefix: String) async -> BreachAnswer {
        count += 1
        return .body(Data())
    }
}
