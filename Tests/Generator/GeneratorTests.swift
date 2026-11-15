import AppKit
import SwiftUI
import XCTest
@testable import OriPass

/// The generator: what each control asks the engine for, over the stand-in,
/// and over the fake what is remembered of it, where a password it made
/// goes, and what the lock leaves of it.
@MainActor
final class GeneratorTests: XCTestCase {
    private var backend: FakeBackend!
    private var kept: [StandIn] = []
    private var defaults: UserDefaults!
    private var pasteboard: NSPasteboard!
    private let suite = "oripass-generator-\(UUID().uuidString)"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("oripass-test-\(UUID().uuidString)"))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        pasteboard.releaseGlobally()
        pasteboard = nil
        backend = nil
        kept = []
    }

    private func demo() async -> VaultStore {
        let vault = DemoVault.objects()
        backend = FakeBackend(items: vault.items, folders: vault.folders, password: DemoVault.password)
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes(DemoVault.password))
        return store
    }

    /// Panes with the form open on GitHub and the generator up under its
    /// wand, the first password already made.
    private func generating(in store: VaultStore) async throws -> (panes: Panes, editor: Editor, generator: Generator) {
        let panes = Panes(store: store, defaults: defaults, clipboard: Clipboard(pasteboard: pasteboard))
        panes.select(item: try XCTUnwrap(panes.list.entries.first { $0.item.name == "GitHub" }).id)
        XCTAssertTrue(panes.beginEdit())
        panes.toggleFieldGenerator()
        let generator = try XCTUnwrap(panes.generator)
        await generator.asking?.value
        return (panes, try XCTUnwrap(panes.editor), generator)
    }

    private func hosted(_ panes: Panes) -> NSWindow {
        let window = MainWindow.make()
        window.contentView = NSHostingView(rootView: PanesView(panes: panes))
        window.setContentSize(Metrics.windowSize)
        window.layoutIfNeeded()
        return window
    }

    // MARK: Over a socket

    func testEachControlAsksTheEngineByTheNameTheNotesGive() async throws {
        let standIn = try StandIn(["password": "demo"])
        kept.append(standIn)
        let serve = ServeBackend(preferredPath: standIn.binary.path, runDirectory: standIn.run,
                                 dataDirectory: standIn.data)
        let store = VaultStore(backend: serve)
        await store.unlock(password: SecretBytes("demo"))
        XCTAssertEqual(store.state, .unlocked)
        let panes = Panes(store: store)
        XCTAssertTrue(panes.beginGenerating(for: .alone))
        let generator = try XCTUnwrap(panes.generator)
        await generator.asking?.value

        // The sync an unlock starts is still asking for its lists.
        func asked() -> [String] { standIn.requests.filter { $0.hasPrefix("GET /generate") } }
        XCTAssertEqual(asked(), ["GET /generate?length=20&uppercase=true&lowercase=true&number=true&special=true "],
                       "as it first comes up")
        XCTAssertEqual(generator.password, "CANARY-GEN-x7Kq2mVb9", "the engine's, as it sent it")

        let moves: [(String, (inout GeneratorSettings) -> Void, String)] = [
            ("the length", { $0.length = 32 }, "length=32&uppercase=true&lowercase=true&number=true&special=true"),
            ("numbers off", { $0.digits = false }, "length=32&uppercase=true&lowercase=true&special=true"),
            ("symbols off", { $0.symbols = false }, "length=32&uppercase=true&lowercase=true"),
            ("numbers on", { $0.digits = true }, "length=32&uppercase=true&lowercase=true&number=true"),
            ("memorable", { $0.kind = .memorable }, "passphrase=true&words=4&separator=-"),
            ("the words", { $0.words = 6 }, "passphrase=true&words=6&separator=-"),
            ("spaces", { $0.separator = .spaces }, "passphrase=true&words=6&separator=%20"),
            ("periods", { $0.separator = .periods }, "passphrase=true&words=6&separator=."),
            ("commas", { $0.separator = .commas }, "passphrase=true&words=6&separator=%2C"),
            ("underscores", { $0.separator = .underscores }, "passphrase=true&words=6&separator=_"),
            ("capitals", { $0.capitals = true }, "passphrase=true&words=6&separator=_&capitalize=true"),
            ("a number", { $0.number = true },
             "passphrase=true&words=6&separator=_&capitalize=true&includeNumber=true"),
            ("a PIN", { $0.kind = .pin }, "length=6&number=true"),
            ("its digits", { $0.pinDigits = 9 }, "length=9&number=true"),
        ]
        for (place, (name, move, query)) in moves.enumerated() {
            move(&generator.settings)
            await generator.asking?.value
            let lines = asked()
            XCTAssertEqual(lines.count, place + 2, "\(name) asked once")
            XCTAssertEqual(lines.last, "GET /generate?\(query) ", name)
        }

        // The engine makes nothing under five, so four digits are the front
        // of five.
        generator.settings.pinDigits = 4
        await generator.asking?.value
        XCTAssertEqual(asked().last, "GET /generate?length=5&number=true ")
        XCTAssertEqual(generator.password, "CANA")

        // The same controls again, by the refresh glyph.
        generator.ask()
        await generator.asking?.value
        XCTAssertEqual(asked().count, moves.count + 3)
        XCTAssertEqual(asked().last, "GET /generate?length=5&number=true ")
        await store.lock()
    }

    // MARK: What it holds

    func testThePasswordIsTheEnginesAndIsScoredAsAnyOther() async throws {
        let store = await demo()
        let (_, _, generator) = try await generating(in: store)
        let made = DemoVault.generated(GeneratorSettings().recipe)
        XCTAssertEqual(generator.password, made)
        XCTAssertEqual(generator.strength, Strength.of(made))

        generator.settings.kind = .pin
        generator.settings.pinDigits = 4
        await generator.asking?.value
        XCTAssertEqual(generator.password, String(DemoVault.generatedPIN.prefix(4)))
        XCTAssertEqual(generator.strength, Strength.of(generator.password))
        XCTAssertLessThan(try XCTUnwrap(generator.strength), .good, "four digits are not said to be strong")
        XCTAssertEqual(backend.count(of: "generate"), 3, "once as it came up, and once for each control")
    }

    func testOnlyTheLastOneAskedForIsShown() async throws {
        let store = await demo()
        let (_, _, generator) = try await generating(in: store)
        backend.generated = "the slow one"
        backend.delay = 0.05
        generator.ask()
        let slow = generator.asking
        // Long enough for the engine to have been asked.
        try await Task.sleep(nanoseconds: 10_000_000)
        backend.generated = "the last one"
        backend.delay = 0
        generator.settings.length = 30
        await generator.asking?.value
        await slow?.value
        XCTAssertEqual(generator.password, "the last one")
    }

    func testARefusalIsSaidInTheEnginesSentenceAndTheNextAnswerTakesItAway() async throws {
        let store = await demo()
        let (panes, _, generator) = try await generating(in: store)
        let before = generator.password
        backend.refusal = .refused("Premium status is required to use this feature.")
        generator.ask()
        await generator.asking?.value
        XCTAssertEqual(generator.refused, "Premium status is required to use this feature.")
        XCTAssertEqual(generator.password, before)
        let window = hosted(panes)
        XCTAssertTrue(said(in: window.contentView).contains("Premium status is required to use this feature."))

        backend.refusal = nil
        generator.ask()
        await generator.asking?.value
        XCTAssertNil(generator.refused)
    }

    // MARK: What is remembered

    func testTheControlsAreRememberedAndNoPasswordIs() async throws {
        let store = await demo()
        var (panes, _, generator) = try await generating(in: store)
        generator.settings.kind = .memorable
        generator.settings.words = 7
        generator.settings.separator = .periods
        generator.settings.capitals = true
        generator.settings.number = true
        await generator.asking?.value
        let left = generator.settings
        let made = generator.password
        XCTAssertTrue(made.hasPrefix("Canarygn.Limon."))
        panes.endGenerating()
        panes.discardEdit()

        (panes, _, generator) = try await generating(in: store)
        XCTAssertEqual(generator.settings, left)
        XCTAssertEqual(generator.password, made, "the fake makes the same one for the same controls")

        // A window of one item has the main window's.
        let pinned = panes.pinned(to: try XCTUnwrap(panes.selectedItem).id)
        XCTAssertTrue(pinned.beginEdit())
        pinned.toggleFieldGenerator()
        XCTAssertEqual(pinned.generator?.settings, left)
        pinned.end()

        let written = try XCTUnwrap(defaults.persistentDomain(forName: suite))
        XCTAssertEqual(Array(written.keys), [GeneratorSettings.key])
        let text = String(describing: written)
        for canary in DemoVault.canaries { XCTAssertFalse(text.contains(canary), canary) }
        XCTAssertFalse(text.localizedCaseInsensitiveContains("limon"))
        XCTAssertEqual(String(describing: generator), "Generator(memorable)")
        XCTAssertEqual(String(reflecting: generator), "Generator(memorable)")
    }

    func testANumberOutOfASlidersReachIsBroughtToItsNearerEnd() {
        defaults.set(["kind": "passphrase", "length": 4096, "words": 1, "pinDigits": -3, "separator": "tabs",
                      "symbols": false] as [String: Any], forKey: GeneratorSettings.key)
        let read = GeneratorSettings(defaults)
        XCTAssertEqual(read.kind, .random, "a kind this app does not have")
        XCTAssertEqual(read.length, 100)
        XCTAssertEqual(read.words, 3)
        XCTAssertEqual(read.pinDigits, 4)
        XCTAssertEqual(read.separator, .hyphens)
        XCTAssertFalse(read.symbols)
        XCTAssertTrue(read.digits, "what was not written is as it first comes")
        XCTAssertEqual(GeneratorSettings(nil), GeneratorSettings())
    }

    // MARK: Where a password goes

    func testUsePutsItInTheFormAndNowhereElse() async throws {
        let store = await demo()
        let (panes, editor, generator) = try await generating(in: store)
        let made = generator.password
        XCTAssertFalse(editor.isDirty)
        XCTAssertTrue(panes.useGenerated())
        XCTAssertNil(panes.generator)
        XCTAssertEqual(generator.password, "", "the generator let go of it")
        XCTAssertEqual(editor.form.password, made)
        XCTAssertEqual(editor.strength, Strength.of(made))
        XCTAssertTrue(editor.isDirty)
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertEqual(backend.count(of: "save"), 0, "nothing is sent until Save")

        await panes.saveEdit()?.value
        XCTAssertEqual(panes.selectedItem?.item.login?.password, made)
    }

    func testOneNeverUsedIsInNoFormAndIsGoneWhenTheCardIs() async throws {
        let store = await demo()
        let (panes, editor, generator) = try await generating(in: store)
        XCTAssertFalse(generator.password.isEmpty)
        // The wand again, Esc, and a click beside the card all end here.
        panes.toggleFieldGenerator()
        XCTAssertNil(panes.generator)
        XCTAssertEqual(generator.password, "")
        XCTAssertNil(generator.strength)
        XCTAssertFalse(editor.isDirty)
        XCTAssertTrue(panes.editor === editor)

        panes.toggleFieldGenerator()
        XCTAssertNotNil(panes.generator)
        XCTAssertTrue(panes.dismiss(), "Esc takes the card first")
        XCTAssertNil(panes.generator)
        XCTAssertTrue(panes.editor === editor, "and leaves the form")
        XCTAssertFalse(panes.useGenerated())
    }

    func testCopyGoesThroughTheClipboardMarkedConcealed() async throws {
        let store = await demo()
        let (panes, _, generator) = try await generating(in: store)
        XCTAssertFalse(generator.isCopied)
        XCTAssertTrue(panes.copyGenerated())
        XCTAssertTrue(generator.isCopied)
        XCTAssertEqual(pasteboard.string(forType: .string), generator.password)
        XCTAssertTrue(pasteboard.types?.contains(Clipboard.concealed) == true)
        XCTAssertNotNil(panes.generator, "the glyph leaves the card up")

        // Another password has not been copied.
        generator.ask()
        await generator.asking?.value
        XCTAssertFalse(generator.isCopied)
        XCTAssertTrue(panes.clipboard.clear())
    }

    func testTheFormGoingTakesItsGeneratorAndNotTheOneThatStandsAlone() async throws {
        let store = await demo()
        let (panes, _, generator) = try await generating(in: store)
        panes.discardEdit()
        XCTAssertNil(panes.generator)
        XCTAssertEqual(generator.password, "")

        XCTAssertTrue(panes.beginEdit())
        XCTAssertTrue(panes.beginGenerating(for: .alone))
        let alone = try XCTUnwrap(panes.generator)
        await alone.asking?.value
        panes.discardEdit()
        XCTAssertTrue(panes.generator === alone)
        XCTAssertFalse(panes.useGenerated(), "it has no field")
        // Every key but Esc is swallowed while it is over the window.
        let before = panes.selectedItem?.id
        XCTAssertTrue(panes.press(.down))
        XCTAssertEqual(panes.selectedItem?.id, before)
        XCTAssertTrue(panes.press(.escape))
        XCTAssertNil(panes.generator)
    }

    func testOnlyALoginsFormHasAFieldToGenerateFor() async throws {
        let store = await demo()
        let panes = Panes(store: store)
        XCTAssertFalse(panes.beginGenerating(for: .field), "no form")
        panes.select(item: try XCTUnwrap(panes.list.entries.first { $0.item.type == .card }).id)
        XCTAssertTrue(panes.beginEdit())
        XCTAssertFalse(panes.beginGenerating(for: .field), "a card has no password")
        XCTAssertNil(panes.generator)
        XCTAssertEqual(backend.count(of: "generate"), 0)
    }

    // MARK: The lock

    func testTheLockTakesTheGeneratorAndWhatItWasWaitingFor() async throws {
        let store = await demo()
        let door = Door(store: store, defaults: defaults)
        let panes = try XCTUnwrap(door.panes)
        let commands = ItemCommands(door: door)
        let item = try XCTUnwrap(commands.menu().items.first { $0.title == "Password Generator…" })
        XCTAssertTrue(commands.validateMenuItem(item))
        XCTAssertTrue(commands.generate())
        var generator = panes.generator
        XCTAssertEqual(generator?.purpose, .alone)
        await generator?.asking?.value
        XCTAssertFalse(try XCTUnwrap(generator).password.isEmpty)

        // One more asked for, which the engine has not answered at the lock.
        backend.delay = 0.05
        generator?.ask()
        let waiting = generator?.asking
        weak var held = generator
        generator = nil
        try await Task.sleep(nanoseconds: 10_000_000)
        await store.lock()
        XCTAssertNil(door.panes)
        XCTAssertNil(panes.generator)
        XCTAssertEqual(held?.password ?? "", "")
        await waiting?.value
        XCTAssertNil(held, "nothing holds the generator once its last question has come back")
        XCTAssertFalse(commands.validateMenuItem(item), "there is no engine to ask")
        XCTAssertFalse(commands.generate())
    }

    // MARK: What is drawn

    func testTheCardSaysItsControlsAndThePasswordItShows() async throws {
        let store = await demo()
        let (panes, _, generator) = try await generating(in: store)
        let window = hosted(panes)
        // A slider's number is a description of its value.
        let keys = ["accessibilityLabel", "accessibilityValue", "accessibilityTitle", "accessibilityValueDescription"]
        var words = said(in: window.contentView, keys: keys)
        for word in ["Password Generator", "generated password", generator.password, "strength", "Strong",
                     "Generate Another", "Copy", "Kind: Random", "Kind: Memorable", "Kind: PIN", "Characters", "20",
                     "Numbers", "Symbols", "on", "Use Password"] {
            XCTAssertTrue(words.contains(word), "the card does not say \(word)")
        }
        XCTAssertFalse(words.contains("Words"))

        generator.settings.kind = .memorable
        await generator.asking?.value
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        words = said(in: window.contentView, keys: keys)
        for word in ["Words", "4", "Separator: Hyphens", "Separator: Spaces", "Separator: Underscores", "Capitals",
                     "A number", "off", generator.password] {
            XCTAssertTrue(words.contains(word), "the card does not say \(word)")
        }
        XCTAssertFalse(words.contains("Characters"))
    }
}
