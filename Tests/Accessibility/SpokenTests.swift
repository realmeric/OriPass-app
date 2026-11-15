import AppKit
import SwiftUI
import XCTest
@testable import OriPass

/// What VoiceOver is given, read from the accessibility tree of views in
/// windows that are never shown. It is what the app says for itself and not
/// what VoiceOver does with it: that is heard, by hand.
@MainActor
final class SpokenTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var up: [QuickAccess] = []

    override func setUp() {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("oripass-test-\(UUID().uuidString)"))
    }

    override func tearDown() {
        up.forEach { $0.end() }
        up = []
        pasteboard.releaseGlobally()
        CodeRow.still = nil
    }

    private func demo() async -> VaultStore {
        let store = VaultStore(backend: DemoVault.backend(), breaches: DemoBreaches.checker(),
                               twoFactor: DemoTwoFactor.checker())
        await store.unlock(password: SecretBytes(DemoVault.password))
        await store.backgroundSync?.value
        await store.scoring?.value
        await store.indexing?.value
        await store.counting?.value
        return store
    }

    /// A surface in the window a shot draws it in.
    private func hosted(_ surface: Surface, over store: VaultStore) throws -> NSWindow {
        let view = try surface.build(store)
        let window = surface.frame?() ?? (surface.isBare
            ? NSWindow(contentRect: NSRect(origin: .zero, size: surface.size), styleMask: .borderless,
                       backing: .buffered, defer: false)
            : MainWindow.make())
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view.frame(width: surface.size.width, height: surface.size.height)
            .ignoresSafeArea())
        window.contentView = host
        window.setContentSize(surface.size)
        host.layoutSubtreeIfNeeded()
        return window
    }

    private func surface(_ name: String) throws -> Surface {
        try XCTUnwrap(Surface.all.first { $0.name == name }, "no surface called \(name)")
    }

    // MARK: Every surface

    /// Every button, field, switch, slider, link and picture the app draws,
    /// in every state it has a shot of, has something to be called by.
    func testNothingThatCanBePressedOrTypedIntoIsWithoutAName() async throws {
        let store = await demo()
        CodeRow.still = CodeRow.shotMoment
        var controls = 0
        var silent: [String] = []
        for surface in Surface.all {
            // A turn of the run loop, which is where AppKit finishes with
            // the window before.
            try? await Task.sleep(nanoseconds: 1)
            let window = try hosted(surface, over: store)
            let all = heard(in: window.contentView).filter(\.isControl)
            controls += all.count
            silent += all.filter(\.isSilent).map { "\(surface.name): \($0.role)" }
        }
        XCTAssertGreaterThan(controls, 4000, "read \(controls) controls on \(Surface.all.count) surfaces")
        XCTAssertEqual(silent, [])
    }

    // MARK: A hidden value

    func testAHiddenValueIsSaidAsConcealedAndItsRowsActionIsCopy() async throws {
        let store = await demo()
        let panes = Panes(store: store, clipboard: Clipboard(pasteboard: pasteboard))
        let bank = try XCTUnwrap(store.shelves.all.first { $0.item.name == "İş Bankası" })
        let password = try XCTUnwrap(bank.item.login?.password)
        panes.select(item: bank.id)
        let window = MainWindow.make()
        window.contentView = NSHostingView(rootView: PanesView(panes: panes))
        window.setContentSize(CGSize(width: Metrics.windowSize.width, height: Metrics.windowSize.height * 2))
        window.layoutIfNeeded()

        let all = heard(in: window.contentView)
        let row = try XCTUnwrap(all.first { $0.label == "password" })
        XCTAssertEqual(row.value, ItemDetail.concealed)
        XCTAssertEqual(row.actions, ["Copy"])
        XCTAssertEqual(row.role, NSAccessibility.Role.button.rawValue, "and pressing it is the click")
        XCTAssertFalse(all.contains { $0.words.contains(password) }, "the value is in nothing that is read out")

        // A hidden custom field the same, and a plain value says itself and
        // copies too.
        let pin = try XCTUnwrap(all.first { $0.label == "PIN" })
        XCTAssertEqual(pin.value, ItemDetail.concealed)
        XCTAssertEqual(pin.actions, ["Copy"])
        let username = try XCTUnwrap(all.first { $0.label == "email" })
        XCTAssertEqual(username.value, bank.item.login?.username)
        XCTAssertEqual(username.actions, ["Copy"])
        let code = try XCTUnwrap(all.first { $0.label == "one-time code" })
        XCTAssertEqual(code.actions, ["Copy"])
        // A tick copies nothing, and says so by offering nothing.
        let tick = try XCTUnwrap(all.first { $0.label == "Kurumsal" })
        XCTAssertEqual(tick.actions, [])

        // The action is the row's click.
        XCTAssertNil(pasteboard.string(forType: .string))
        try press("Copy", on: "password", in: window.contentView)
        XCTAssertEqual(pasteboard.string(forType: .string), password)
        XCTAssertTrue(pasteboard.types?.contains(Clipboard.concealed) == true)
    }

    /// Does what VoiceOver does when the action is chosen from its menu.
    private func press(_ action: String, on label: String, in view: NSView?) throws {
        func find(_ element: Any?, depth: Int = 0) -> NSAccessibilityCustomAction? {
            guard let object = element as? NSObject, depth < 40 else { return nil }
            let selector = NSSelectorFromString("accessibilityLabel")
            let own = object.responds(to: selector)
                ? object.perform(selector)?.takeUnretainedValue() as? String : nil
            if own == label,
               let actions = object.perform(NSSelectorFromString("accessibilityCustomActions"))?
                .takeUnretainedValue() as? [NSAccessibilityCustomAction],
               let found = actions.first(where: { $0.name == action }) {
                return found
            }
            let children = object.perform(NSSelectorFromString("accessibilityChildren"))?
                .takeUnretainedValue() as? [Any] ?? []
            return children.lazy.compactMap { find($0, depth: depth + 1) }.first
        }
        let found = try XCTUnwrap(find(view), "no \(action) on \(label)")
        XCTAssertEqual(found.handler?(), true)
    }

    func testARevealedValueIsSaidAndAFormsHiddenFieldIsNot() async throws {
        let store = await demo()
        let revealed = heard(in: try hosted(try surface("field-revealed"), over: store).contentView)
        let password = try XCTUnwrap(revealed.first { $0.label == "password" })
        XCTAssertNotEqual(password.value, ItemDetail.concealed)
        XCTAssertFalse(password.value.isEmpty)

        let form = heard(in: try hosted(try surface("editor-card"), over: store).contentView)
        XCTAssertTrue(form.contains { $0.value == ItemDetail.concealed }, "a card's number, until the caret is in it")
    }

    // MARK: The fields AppKit draws

    func testThePasswordFieldsAndTheSearchFieldsHaveNames() async throws {
        let store = await demo()
        let wanted = [
            "lock": "Master password", "sign-in": "Master password", "sign-in-api-key": "client_secret",
            "reprompt-password": "Master password", "quick-access": "Search", "quick-access-locked": "Master password",
            "window-empty": "Search",
        ]
        for (name, label) in wanted {
            let fields = heard(in: try hosted(try surface(name), over: store).contentView)
                .filter { $0.role == NSAccessibility.Role.textField.rawValue }
            XCTAssertTrue(fields.contains { $0.label == label }, "\(name): \(fields)")
        }
        let signIn = heard(in: try hosted(try surface("sign-in"), over: store).contentView)
        XCTAssertTrue(signIn.contains { $0.label == "Email" })
        let code = heard(in: try hosted(try surface("sign-in-code"), over: store).contentView)
        XCTAssertTrue(code.contains { $0.label == "Code" })
        let sidebar = heard(in: try hosted(try surface("window-empty"), over: store).contentView)
        XCTAssertTrue(sidebar.contains { $0.words == "Account, \(store.email ?? "nobody")" }, "the account's menu")
    }

    // MARK: Quick Access

    private func quickAccess(over store: VaultStore, voice: Voice?) -> QuickAccess {
        let quick = QuickAccess(door: Door(store: store, clipboard: Clipboard(pasteboard: pasteboard)),
                                voice: voice, present: { _ in }, pointer: { .zero },
                                screens: { [NSRect(x: 0, y: 0, width: 1512, height: 982)] })
        up.append(quick)
        return quick
    }

    func testQuickAccessSaysHowManyResultsThereAre() async throws {
        let store = await demo()
        let voice = RememberingVoice()
        let quick = quickAccess(over: store, voice: voice)
        XCTAssertNil(quick.counted)
        quick.query = "spotify"
        XCTAssertEqual(voice.said, [], "nothing while the panel is away")

        quick.show()
        XCTAssertEqual(quick.counted, "1 result")
        XCTAssertEqual(voice.said, ["1 result"])
        quick.panel.contentView?.layoutSubtreeIfNeeded()
        var tree = heard(in: quick.panel.contentView)
        XCTAssertTrue(tree.contains { $0.label == "1 result" }, "\(tree)")
        let row = try XCTUnwrap(tree.first { $0.label == "Spotify" })
        XCTAssertEqual(row.role, NSAccessibility.Role.button.rawValue)
        XCTAssertEqual(row.actions, ["Copy Password"], "what Return does to it")
        XCTAssertTrue(row.value.contains("spotify.com"))

        quick.query = "kanarya"
        let many = quick.rows.count
        XCTAssertGreaterThan(many, 1)
        XCTAssertEqual(voice.said.last, "\(many) results")
        quick.panel.contentView?.layoutSubtreeIfNeeded()
        tree = heard(in: quick.panel.contentView)
        XCTAssertTrue(tree.contains { $0.label == "\(many) results" })

        // The same count is not said twice, and no match is said as it is
        // written.
        let before = voice.said.count
        quick.query = "kanarya "
        XCTAssertEqual(quick.rows.count, many)
        XCTAssertEqual(voice.said.count, before)
        quick.query = "zzzzzz"
        XCTAssertEqual(voice.said.last, QuickAccess.nothing)
        quick.panel.contentView?.layoutSubtreeIfNeeded()
        tree = heard(in: quick.panel.contentView)
        XCTAssertTrue(tree.contains { $0.words == QuickAccess.nothing })

        // The panel put away and brought back says its count again.
        quick.query = "spotify"
        quick.close()
        let said = voice.said.count
        quick.show()
        XCTAssertEqual(voice.said.count, said, "nothing is listed until something is typed or was used")
        quick.query = "spotify"
        XCTAssertEqual(voice.said.last, "1 result")
    }

    func testTheArrowsSayTheRowTheyLandOnAndWhereItIs() async throws {
        let store = await demo()
        let voice = RememberingVoice()
        let quick = quickAccess(over: store, voice: voice)
        quick.show()
        quick.query = "kanarya"
        let many = quick.rows.count
        quick.move(by: 1)
        let second = quick.rows[1].item
        XCTAssertEqual(voice.said.last, quick.selectedSaid)
        XCTAssertTrue(try XCTUnwrap(voice.said.last).hasPrefix(second.name + ", "))
        XCTAssertTrue(try XCTUnwrap(voice.said.last).hasSuffix(", 2 of \(many)"))
        XCTAssertFalse(voice.said.contains { $0.contains("CANARY") }, "a title and a second line, and no value")

        // Inside an item it is the action the arrows are on.
        XCTAssertTrue(quick.openSelected())
        quick.move(by: 1)
        let opened = try XCTUnwrap(quick.opened)
        XCTAssertEqual(voice.said.last, "\(opened.actions[1].name), 2 of \(opened.actions.count)")
    }

    func testWithoutAVoiceNothingIsWorkedOutToSay() async throws {
        let store = await demo()
        let quick = quickAccess(over: store, voice: nil)
        quick.show()
        quick.query = "spotify"
        quick.move(by: 1)
        XCTAssertEqual(quick.counted, "1 result", "the list still has its name")
    }
}
