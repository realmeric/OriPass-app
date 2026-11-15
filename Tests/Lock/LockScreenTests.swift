import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest
@testable import OriPass

@MainActor
final class LockScreenTests: XCTestCase {
    private func demo() -> (FakeBackend, VaultStore) {
        let backend = DemoVault.backend()
        // Synced a minute ago, so no sync is running behind the lock.
        backend.lastSync = Date().addingTimeInterval(-60)
        return (backend, VaultStore(backend: backend))
    }

    /// The door in a window that is never shown, as the delegate hosts it.
    private func hosted(_ door: Door) -> NSWindow {
        let window = MainWindow.make()
        window.contentView = NSHostingView(rootView: DoorView(door: door))
        window.layoutIfNeeded()
        return window
    }

    /// Long enough for SwiftUI to draw what changed and drop what it held.
    private func turn(_ seconds: Double = 0.05) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func views<Wanted: NSView>(_ type: Wanted.Type, in view: NSView?) -> [Wanted] {
        guard let view else { return [] }
        return (view as? Wanted).map { [$0] } ?? [] + view.subviews.flatMap { views(type, in: $0) }
    }

    // MARK: Nothing behind the door

    func testWhileLockedTheModelsOfTheUnlockedWindowDoNotExist() async throws {
        let (_, store) = demo()
        let door = Door(store: store)
        let window = hosted(door)
        await store.refresh()
        try await turn()
        XCTAssertNil(door.panes)
        XCTAssertEqual(views(PasswordTextField.self, in: window.contentView).count, 1)

        await store.unlock(password: SecretBytes(DemoVault.password))
        // Past the door's fade, so the lock screen has left the tree.
        try await turn(Motion.door.duration * 3)
        weak let panes = door.panes
        weak let entry = store.shelves.all.first
        XCTAssertNotNil(panes)
        XCTAssertNotNil(entry)
        XCTAssertEqual(views(PasswordTextField.self, in: window.contentView).count, 0,
                       "the field is still in the window behind the panes")

        await store.lock()
        try await turn()
        XCTAssertNil(door.panes)
        XCTAssertNil(panes, "the unlocked window's model outlived the lock")
        XCTAssertNil(entry, "an item outlived the lock")
        XCTAssertEqual(views(PasswordTextField.self, in: window.contentView).count, 1)
    }

    func testARefusedPasswordBuildsNothing() async {
        let (_, store) = demo()
        let door = Door(store: store)
        await store.unlock(password: SecretBytes("nope"))
        XCTAssertNil(door.panes)
        XCTAssertEqual(store.refusal, VaultStore.notThePassword)
    }

    func testAnEngineThatDiesShutsTheDoor() async {
        let (backend, store) = demo()
        let door = Door(store: store)
        await store.unlock(password: SecretBytes(DemoVault.password))
        weak let panes = door.panes
        XCTAssertNotNil(panes)

        let locked = expectation(forNotification: VaultStore.didLock, object: store)
        backend.die()
        await fulfillment(of: [locked], timeout: 1)
        XCTAssertNil(panes)
    }

    // MARK: The field

    /// A window that says it is key. Under `xcodebuild test` the host app is
    /// not always in front, and then no window of its is key whatever it is
    /// told.
    private final class KeyWindow: NSWindow {
        var saysItIsKey = true
        override var isKeyWindow: Bool { saysItIsKey }
        override var canBecomeKey: Bool { true }
    }

    private func fieldInAWindow() -> (KeyWindow, PasswordTextField) {
        let window = KeyWindow(contentRect: NSRect(origin: .zero, size: Metrics.lockField),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = PasswordTextField(frame: NSRect(origin: .zero, size: Metrics.lockField))
        window.contentView?.addSubview(field)
        return (window, field)
    }

    func testSecureInputGoesOnWithFocusAndOffWithBlurAndWithTheWindowClosing() throws {
        // The answer is the whole Mac's: another app holding secure input
        // would make every "off" below read as on. Behind a locked screen
        // that app is the login window.
        try Screen.skipIfLocked("that secure input follows the password field's focus")
        try XCTSkipIf(IsSecureEventInputEnabled(), "another process has secure input on")
        let (window, field) = fieldInAWindow()
        XCTAssertFalse(IsSecureEventInputEnabled())

        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertTrue(IsSecureEventInputEnabled(), "focus did not turn it on")
        XCTAssertTrue(field.secureInput.isOn)

        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertFalse(IsSecureEventInputEnabled(), "blur left it on")

        // The window goes to the back with the caret still in the field.
        XCTAssertTrue(window.makeFirstResponder(field))
        window.saysItIsKey = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertFalse(IsSecureEventInputEnabled(), "a window that is not key kept it on")
        window.saysItIsKey = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertTrue(IsSecureEventInputEnabled())

        window.close()
        XCTAssertFalse(IsSecureEventInputEnabled(), "the window closed and left it on")
        XCTAssertFalse(field.secureInput.isOn)
    }

    func testAFieldThatIsDisabledGivesUpTheKeys() throws {
        try Screen.skipIfLocked("that a disabled password field lets secure input go")
        try XCTSkipIf(IsSecureEventInputEnabled(), "another process has secure input on")
        let (window, field) = fieldInAWindow()
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertTrue(IsSecureEventInputEnabled())
        field.letGo()
        field.isEnabled = false
        XCTAssertFalse(IsSecureEventInputEnabled())
        window.close()
    }

    func testReturnHandsOverWhatWasTypedAndEmptiesTheField() throws {
        var handed: SecretBytes?
        let field = PasswordField(placeholder: "", isEnabled: true, isFocused: .constant(true)) {
            handed = $0
        }
        let coordinator = PasswordField.Coordinator(field)
        let (window, view) = fieldInAWindow()
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(view))
        let editor = try XCTUnwrap(view.currentEditor() as? NSTextView)
        view.stringValue = "typed-by-hand"

        // Anything but Return is the field's own business.
        XCTAssertFalse(coordinator.control(view, textView: editor,
                                           doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertNil(handed)

        XCTAssertTrue(coordinator.control(view, textView: editor,
                                          doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertTrue(try XCTUnwrap(handed).matches(SecretBytes("typed-by-hand")))
        XCTAssertEqual(view.stringValue, "")
        XCTAssertEqual(editor.string, "")
        XCTAssertTrue(view.isEditing, "Return took the caret out of the field")

        // Return on an empty field asks the engine nothing.
        handed = nil
        XCTAssertTrue(coordinator.control(view, textView: editor,
                                          doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertNil(handed)
    }

    // MARK: Shots

    func testEveryStateOfTheLockScreenIsShotAndTheFingerprintIsOnlyWhereASealIs() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oripass-lock-shots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = await Shots.write(Surface.lockScreens, from: DemoVault.backend(), into: directory)
        XCTAssertEqual(report.problems, [])
        XCTAssertEqual(report.requests, 0)
        for name in ["lock", "lock-finger", "lock-unlocking", "lock-refused", "lock-kept-refused", "lock-no-cli",
                     "lock-logged-out", "lock-failed"] {
            XCTAssertTrue(report.written.contains("\(name)-light.png"), "\(name) was not shot")
            XCTAssertTrue(report.written.contains("\(name)-dark.png"), "\(name) was not shot")
        }

        func shot(_ file: String) throws -> NSBitmapImageRep {
            try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: directory.appendingPathComponent(file))))
        }
        /// Whether anything in the field's right end is nearer the accent
        /// than the field's own ground: the fingerprint and nothing else.
        func hasAccentInTheFieldsEnd(_ bitmap: NSBitmapImageRep) -> Bool {
            let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
            let middleX = bitmap.size.width / 2, middleY = bitmap.size.height / 2
            let accent = Palette.nsColor(0x1A66E0)
            let from = Int((middleX + Metrics.lockField.width / 2 - Metrics.lockFinger - Metrics.close) * scale)
            let to = Int((middleX + Metrics.lockField.width / 2 - Metrics.close) * scale)
            for x in from..<to {
                for y in Int((middleY - Metrics.lockFinger / 2) * scale)..<Int((middleY + Metrics.lockFinger / 2) * scale) {
                    guard let pixel = bitmap.colorAt(x: x, y: y) else { continue }
                    let far = max(abs(pixel.redComponent - accent.redComponent),
                                  abs(pixel.greenComponent - accent.greenComponent),
                                  abs(pixel.blueComponent - accent.blueComponent))
                    if far < 0.1 { return true }
                }
            }
            return false
        }
        XCTAssertFalse(hasAccentInTheFieldsEnd(try shot("lock-light.png")))
        XCTAssertTrue(hasAccentInTheFieldsEnd(try shot("lock-finger-light.png")))
    }
}
