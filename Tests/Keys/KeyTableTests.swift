import AppKit
import SwiftUI
import XCTest
@testable import OriPass

@MainActor
final class KeyTableTests: XCTestCase {
    private func demo() async -> VaultStore {
        let backend = DemoVault.backend()
        // Synced a minute ago, so no sync is running behind the panes.
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes(DemoVault.password))
        return store
    }

    /// The menu bar as the app delegate fills it, in a menu of the test's.
    private func menuBar(for door: Door) -> (menu: NSMenu, holders: [AnyObject]) {
        let main = NSMenu()
        for title in ["App", "Edit", "Window", "Help"] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: title)
            main.addItem(item)
        }
        let window = main.items[2].submenu
        let view = WindowCommands(door: door)
        let item = ItemCommands(door: door)
        let lock = LockCommands(door: door)
        view.install(in: main, before: window)
        item.install(in: main, before: window)
        lock.install(in: main, before: window)
        return (main, [view, item, lock])
    }

    private func items(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(items(in:)) ?? []) }
    }

    private func key(_ characters: String, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                       windowNumber: 0, context: nil, characters: characters,
                                       charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0))
    }

    // MARK: The table

    func testEveryRowIsThereOnceAndNoTwoShareACombination() {
        XCTAssertEqual(KeyTable.all.map(\.id.rawValue).sorted(), KeyCommand.ID.allCases.map(\.rawValue).sorted())
        var owners: [Stroke: KeyCommand.ID] = [:]
        for command in KeyTable.all {
            XCTAssertFalse(command.strokes.isEmpty, "\(command.id) has no key")
            for stroke in command.strokes {
                XCTAssertNil(owners[stroke], "\(stroke.symbols) is \(command.id)'s and also another's")
                owners[stroke] = command.id
            }
        }
    }

    func testEveryCommandInTheSheetIsBound() async throws {
        let door = Door(store: await demo())
        let bar = menuBar(for: door)
        let all = items(in: bar.menu)
        let panes = try XCTUnwrap(door.panes)

        for command in KeyTable.working {
            for stroke in command.strokes {
                switch command.bound {
                case .menu:
                    let found = all.filter {
                        $0.keyEquivalent == stroke.key && $0.keyEquivalentModifierMask == stroke.modifiers
                    }
                    XCTAssertEqual(found.count, 1, "\(stroke.symbols) is on \(found.count) items of the menu bar")
                    let item = try XCTUnwrap(found.first, "\(command.id) is in no menu")
                    let action = try XCTUnwrap(item.action)
                    XCTAssertTrue((item.target as? NSObject)?.responds(to: action) == true,
                                  "nothing answers \(command.id)")
                case .editMenu:
                    // The Edit menu's own Copy, which ends at the delegate.
                    XCTAssertTrue(AppDelegate.instancesRespond(to: #selector(AppDelegate.copy(_:))))
                case .appMenu:
                    // The scene's own item, which the tour presses in the
                    // real menu bar (`scripts/canary.sh`).
                    XCTAssertTrue(AppDelegate.instancesRespond(to: #selector(AppDelegate.showSettings(_:))))
                case .keys:
                    let key = try XCTUnwrap(PaneKey(stroke), "\(stroke.symbols) is no key of the window's")
                    XCTAssertEqual(key.command, command.id)
                    panes.press(key)
                case .held:
                    XCTAssertTrue(OptionWatch.isHeld(stroke.modifiers))
                case .hotKey:
                    let action = try XCTUnwrap(HotKeyAction.allCases.first { $0.command == command.id },
                                               "\(command.id) is no hot key")
                    XCTAssertEqual(action.fallback?.words, stroke.symbols)
                }
            }
        }
        withExtendedLifetime(bar.holders) {}
    }

    func testAMenuKeyTheTableDoesNotHaveIsNotInTheMenus() async {
        let door = Door(store: await demo())
        let bar = menuBar(for: door)
        let known = Set(KeyTable.all.flatMap(\.strokes))
        for item in items(in: bar.menu) where !item.keyEquivalent.isEmpty {
            let stroke = Stroke(item.keyEquivalent, item.keyEquivalentModifierMask)
            XCTAssertTrue(known.contains(stroke), "\(stroke.symbols) is in a menu and not in the table")
        }
        withExtendedLifetime(bar.holders) {}
    }

    func testAKeyWaitingForItsCardIsNotInTheSheetAndDoesNothing() async throws {
        let door = Door(store: await demo())
        let bar = menuBar(for: door)
        let panes = try XCTUnwrap(door.panes)
        // None waits since the settings got their window. A row that is
        // given a card to wait for is held to this again.
        let waiting = KeyTable.all.filter { $0.waits != nil }
        for command in waiting {
            XCTAssertFalse(panes.keyCommands.contains { $0.id == command.id })
            for stroke in command.strokes {
                for item in items(in: bar.menu) where item.keyEquivalent == stroke.key
                    && item.keyEquivalentModifierMask == stroke.modifiers {
                    let validator = try XCTUnwrap(item.target as? NSMenuItemValidation)
                    XCTAssertFalse(validator.validateMenuItem(item), "\(command.id) waits for \(command.waits ?? "")")
                }
            }
        }
        withExtendedLifetime(bar.holders) {}
    }

    // MARK: The sheet

    func testTheSheetSaysTheRowsThatWorkAndNoOthers() async throws {
        let panes = Panes(store: await demo())
        let window = MainWindow.make()
        window.contentView = NSHostingView(rootView: PanesView(panes: panes))
        window.setContentSize(CGSize(width: Metrics.windowSize.width, height: Metrics.windowSize.height * 2))
        window.layoutIfNeeded()
        XCTAssertFalse(said(in: window.contentView).contains("Keyboard Shortcuts"))

        panes.toggleKeys()
        try await Task.sleep(nanoseconds: 400_000_000)
        window.layoutIfNeeded()
        let words = said(in: window.contentView)
        XCTAssertTrue(words.contains("Keyboard Shortcuts"))
        for command in KeyTable.all where command.id != .peek {
            XCTAssertEqual(words.contains(command.name), command.waits == nil, command.name)
        }
        XCTAssertTrue(words.contains("⇧⌘L"))
        XCTAssertTrue(words.contains("⌘2 to ⌘9"))
        XCTAssertTrue(words.contains("↑, ↓"))
        // ⌥ reveals only when its setting is on, and it is off.
        XCTAssertFalse(words.contains(KeyTable[.peek].name))

        XCTAssertTrue(panes.dismiss())
        try await Task.sleep(nanoseconds: 400_000_000)
        window.layoutIfNeeded()
        XCTAssertFalse(said(in: window.contentView).contains("Keyboard Shortcuts"))
    }

    func testTheSheetCallsTheUsernameWhatTheItemInTheDetailsHas() async throws {
        let panes = Panes(store: await demo())
        func copy() -> String? { panes.keyCommands.first { $0.id == .copy }?.name }
        XCTAssertEqual(copy(), "Copy the username or the first field", "no item, so the table's own words")
        XCTAssertEqual(copy(), KeyTable[.copy].name)
        panes.select(item: try XCTUnwrap(panes.list.entries.first { $0.item.name == "Spotify" }).id)
        XCTAssertEqual(copy(), "Copy the email or the first field")
        panes.select(item: try XCTUnwrap(panes.list.entries.first { $0.item.type == .card }).id)
        XCTAssertEqual(copy(), "Copy the username or the first field")
        panes.end()
    }

    func testTheSheetListsTheHeldKeyOnlyWhileItsSettingIsOn() async throws {
        let suite = "oripass-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = await demo()
        XCTAssertFalse(Panes(store: store, defaults: defaults).keyCommands.contains { $0.id == .peek })
        Preferences(defaults: defaults).settings.details.revealWithOption = true
        let panes = Panes(store: store, defaults: defaults)
        XCTAssertTrue(panes.keyCommands.contains { $0.id == .peek })
        panes.end()
    }

    func testEscPutsTheSheetAwayAndNoOtherKeyGetsPastIt() async throws {
        let panes = Panes(store: await demo())
        panes.toggleKeys()
        XCTAssertTrue(panes.showsKeys)
        XCTAssertTrue(panes.press(.down))
        XCTAssertNil(panes.selectedItem, "the list did not move under the sheet")
        XCTAssertTrue(panes.press(.escape))
        XCTAssertFalse(panes.showsKeys)
        panes.toggleKeys()
        panes.toggleKeys()
        XCTAssertFalse(panes.showsKeys, "⌘/ again puts it away")
    }

    func testTheSheetDrawsAKeyWhereTheMenuBarHasIt() async throws {
        let door = Door(store: await demo())
        let bar = menuBar(for: door)
        let back = try XCTUnwrap(KeyTable.item(.back, in: bar.menu))
        XCTAssertEqual(back.keyEquivalent, "[")
        XCTAssertEqual(KeyTable.asBound(KeyTable[.back], in: bar.menu).strokes, KeyTable[.back].strokes)

        // What AppKit does to ⌘[ in the menu bar under a Turkish keyboard.
        back.keyEquivalent = "ğ"
        XCTAssertEqual(KeyTable.asBound(KeyTable[.back], in: bar.menu).strokes.map(\.symbols), ["⌘Ğ"])
        XCTAssertEqual(KeyTable.asBound(KeyTable[.vaults], in: bar.menu).strokes.count, 8)
        // A key at the window is not a menu's to move, and with no menu
        // bar the table stands.
        XCTAssertEqual(KeyTable.asBound(KeyTable[.rows], in: bar.menu).strokes, KeyTable[.rows].strokes)
        XCTAssertEqual(KeyTable.asBound(KeyTable[.back], in: nil).strokes, KeyTable[.back].strokes)
        withExtendedLifetime(bar.holders) {}
    }

    // MARK: The page

    /// `docs/look.md` carries the table for a reader, and it is the one the
    /// card was written against. A row there that says the key works has to
    /// be a row here that is bound, and a row that names a card has to wait
    /// for that card here.
    func testThePageAndTheTableAgreeOnEveryKey() throws {
        let page = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/look.md")
        let text = try String(contentsOf: page, encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "## The keyboard"))
        let end = try XCTUnwrap(text.range(of: "In Quick Access:"))
        let rows: [(keys: Set<String>, here: String)] = text[start.upperBound..<end.lowerBound]
            .split(separator: "\n").filter { $0.hasPrefix("| ") }.dropFirst(2).map { line in
                let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                let keys = cells[0].split(separator: " ").map(String.init)
                    .filter { !["and", "to", "or", "held"].contains($0) }
                return (Set(keys), cells[2])
            }
        XCTAssertGreaterThan(rows.count, 25)

        var read = Set<Int>()
        for command in KeyTable.all {
            let symbols = try XCTUnwrap(command.strokes.first).symbols
            let place = try XCTUnwrap(rows.firstIndex { $0.keys.contains(symbols) }, "\(symbols) is not on the page")
            read.insert(place)
            if let card = command.waits {
                XCTAssertTrue(rows[place].here.hasPrefix(card), "the page does not say \(symbols) waits for \(card)")
            } else {
                XCTAssertFalse(rows[place].here.hasPrefix("OP-"), "the page says \(symbols) waits, and it works")
            }
        }
        for (place, row) in rows.enumerated() where !read.contains(place) {
            XCTAssertEqual(row.keys, ["unset"], "the page has a row the table does not: \(row.keys)")
        }
    }

    // MARK: A key event

    func testAKeyEventComesDownToTheStrokeAMenuWouldWrite() throws {
        XCTAssertEqual(Stroke(try key("\u{F700}", modifiers: [.numericPad, .function])), PaneKey.up.stroke)
        XCTAssertEqual(Stroke(try key("\u{7F}")), PaneKey.delete.stroke)
        XCTAssertEqual(Stroke(try key("\r")), PaneKey.enter.stroke)
        XCTAssertEqual(Stroke(try key(" ")), PaneKey.space.stroke)
        XCTAssertEqual(Stroke(try key("L", modifiers: [.command, .shift, .capsLock])), KeyTable[.lock].strokes[0])
        XCTAssertNil(PaneKey(try XCTUnwrap(Stroke(try key("\u{F700}", modifiers: .shift)))))
        XCTAssertEqual(KeyTable[.lock].strokes[0].symbols, "⇧⌘L")
        XCTAssertEqual(KeyTable[.filter].strokes[0].symbols, "⌥⌘F")
        XCTAssertEqual(KeyTable[.delete].strokes[0].symbols, "⌘Delete")
    }
}
