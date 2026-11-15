import AppKit
import Combine
import SwiftUI
import XCTest
@testable import OriPass

/// Return, through the door, to the store and back to what the window shows.
@MainActor
final class UnlockTests: XCTestCase {
    private func demo() -> (FakeBackend, VaultStore) {
        let backend = DemoVault.backend()
        // Synced a minute ago, so no sync is running behind the unlock.
        backend.lastSync = Date().addingTimeInterval(-60)
        return (backend, VaultStore(backend: backend))
    }

    private func hosted(_ door: Door) -> NSWindow {
        let window = MainWindow.make()
        window.contentView = NSHostingView(rootView: DoorView(door: door))
        window.layoutIfNeeded()
        return window
    }

    private func turn(_ seconds: Double = 0.05) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func field(in view: NSView?) -> PasswordTextField? {
        guard let view else { return nil }
        if let found = view as? PasswordTextField { return found }
        return view.subviews.lazy.compactMap { self.field(in: $0) }.first
    }

    /// Types into the field and presses Return the way the keyboard does:
    /// the editor is told to insert a newline, and the field's delegate
    /// takes it from there.
    private func typeAndPressReturn(_ typed: String, in window: NSWindow) throws {
        let field = try XCTUnwrap(field(in: window.contentView))
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.string = typed
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    }

    // MARK: The password

    func testTheDemoPasswordOpensTheVaultAndIsWiped() async throws {
        let (backend, store) = demo()
        let door = Door(store: store)
        let password = SecretBytes(DemoVault.password)

        await door.unlock(with: password).value

        XCTAssertEqual(store.state, .unlocked)
        XCTAssertNil(store.refusal)
        XCTAssertNotNil(door.panes)
        XCTAssertTrue(backend.isOpen)
        XCTAssertFalse(store.shelves.all.isEmpty)
        XCTAssertTrue(password.isWiped, "the password was left in memory")
    }

    func testAnythingElseKeepsTheDoorShutWithTheSentenceAndIsWiped() async {
        let (backend, store) = demo()
        let door = Door(store: store)
        let wrong = SecretBytes("demo ")

        await door.unlock(with: wrong).value

        XCTAssertEqual(store.state, .locked)
        XCTAssertEqual(store.refusal, VaultStore.notThePassword)
        XCTAssertNil(door.panes)
        XCTAssertFalse(backend.isOpen)
        XCTAssertTrue(wrong.isWiped)
    }

    /// 2026.9.1 says of a wrong password that a decryption failed. Nobody
    /// at a lock screen should have to read that, so that sentence and the
    /// older one are drawn as this app's own, and whatever else the engine
    /// refuses an unlock with is still drawn as it gave it.
    func testAWrongPasswordIsSaidPlainlyAndAnyOtherRefusalInTheEnginesWords() async throws {
        XCTAssertEqual(FakeBackend.wrongPassword, "Cryptography error, The decryption operation failed")
        XCTAssertEqual(VaultStore.notThePassword, "That is not the master password.")
        let sentences = [
            (FakeBackend.wrongPassword, VaultStore.notThePassword),
            ("Invalid master password.", VaultStore.notThePassword),
            (FakeBackend.offline, FakeBackend.offline),
            ("Cryptography error, something else broke", "Cryptography error, something else broke"),
        ]
        for (engine, drawn) in sentences {
            let (backend, store) = demo()
            let door = Door(store: store)
            backend.refusal = .refused(engine)
            await door.unlock(with: SecretBytes(DemoVault.password)).value
            XCTAssertEqual(store.state, .locked)
            XCTAssertEqual(store.refusal, drawn)

            let window = hosted(door)
            try await turn()
            let words = said(in: window.contentView)
            XCTAssertTrue(words.contains(drawn), "the lock screen says \(words)")
            XCTAssertFalse(words.contains("Cryptography") && drawn == VaultStore.notThePassword)
            window.close()
        }
    }

    /// The shake is driven by the refusal changing, so a second wrong
    /// password with the same sentence has to publish again. The store
    /// clears the sentence when an attempt starts, and that is what does it.
    func testEveryRefusalPublishesSoEveryRefusalShakes() async {
        let (_, store) = demo()
        let door = Door(store: store)
        var sentences: [String?] = []
        let watching = store.$refusal.dropFirst().sink { sentences.append($0) }

        await door.unlock(with: SecretBytes("one")).value
        await door.unlock(with: SecretBytes("two")).value

        XCTAssertEqual(sentences, [nil, VaultStore.notThePassword, nil, VaultStore.notThePassword])
        watching.cancel()
    }

    func testAnotherReturnWhileOneIsRunningIsIgnoredAndWiped() async {
        let (backend, store) = demo()
        backend.delay = 0.1
        let door = Door(store: store)
        let first = door.unlock(with: SecretBytes(DemoVault.password))
        let second = SecretBytes("typed too soon")

        await door.unlock(with: second).value
        await first.value

        XCTAssertTrue(second.isWiped)
        XCTAssertEqual(backend.count(of: "unlock"), 1)
        XCTAssertEqual(store.state, .unlocked)
    }

    // MARK: Through the window

    func testReturnInTheFieldOpensTheVaultAndTheFieldIsLeftEmpty() async throws {
        let (_, store) = demo()
        let door = Door(store: store)
        let window = hosted(door)
        await store.refresh()
        try await turn()

        try typeAndPressReturn(DemoVault.password, in: window)
        // Past the door's fade, so the lock screen has left the tree.
        try await turn(Motion.door.duration * 3)

        XCTAssertEqual(store.state, .unlocked)
        XCTAssertNotNil(door.panes)
        XCTAssertNil(field(in: window.contentView), "the field is still behind the panes")
        window.close()
    }

    func testAWrongPasswordInTheFieldLeavesTheFieldEmptyAndTheSentenceUp() async throws {
        let (_, store) = demo()
        let door = Door(store: store)
        let window = hosted(door)
        await store.refresh()
        try await turn()

        try typeAndPressReturn("nope", in: window)
        try await turn(0.3)

        XCTAssertEqual(store.state, .locked)
        XCTAssertEqual(store.refusal, VaultStore.notThePassword)
        let field = try XCTUnwrap(field(in: window.contentView))
        XCTAssertEqual(field.stringValue, "")
        XCTAssertTrue(field.isEnabled, "the field stayed disabled after a refusal")
        window.close()
    }

    // MARK: Offline

    /// A sync that cannot reach the server is not a failure to unlock: the
    /// list `bw` already had is on screen, and the store says the sync failed.
    /// That `bw` itself opens its last sync with no network is *check* in the
    /// notes; this holds only what the store does when it does.
    func testAnUnlockWithNoNetworkStillOpensWhatWasLastSynced() async throws {
        let backend = DemoVault.backend()
        backend.isOffline = true
        backend.lastSync = Date().addingTimeInterval(-24 * 60 * 60)
        let store = VaultStore(backend: backend)
        let door = Door(store: store)

        await door.unlock(with: SecretBytes(DemoVault.password)).value
        await store.backgroundSync?.value

        XCTAssertEqual(store.state, .unlocked)
        XCTAssertNotNil(door.panes)
        XCTAssertFalse(store.shelves.all.isEmpty)
        XCTAssertTrue(store.lastSyncFailed)
        XCTAssertEqual(backend.count(of: "sync"), 1)
    }
}
