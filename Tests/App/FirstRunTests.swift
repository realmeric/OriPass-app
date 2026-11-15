import AppKit
import SwiftUI
import XCTest
@testable import OriPass

private final class CountingTab: TabAsker {
    private(set) var asked = 0
    func address(of app: FrontApp) async -> String? {
        asked += 1
        return nil
    }
}

/// An install that has never run: no defaults, no seal, nobody signed in.
/// Everything that would put a question of the system's on the screen is a
/// fake that counts, so this shows when each is reached and never raises
/// one. Whether macOS then shows its own dialog is not something a test
/// can see.
@MainActor
final class FirstRunTests: XCTestCase {
    private let slack = FrontApp(pid: 4711, bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
    private let safari = FrontApp(pid: 4713, bundleID: "com.apple.Safari", name: "Safari")

    private var suite: String!
    private var defaults: UserDefaults!
    private var directory: URL!
    private var pasteboard: NSPasteboard!
    private var up: [QuickAccess] = []

    override func setUp() {
        suite = "oripass-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("oripass-first-\(UUID().uuidString)")
        pasteboard = NSPasteboard(name: NSPasteboard.Name("oripass-test-\(UUID().uuidString)"))
    }

    override func tearDown() {
        up.forEach { $0.end() }
        up = []
        pasteboard.releaseGlobally()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    private func returnKey() throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, characters: "\r",
                                       charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    }

    func testAFirstRunIsTheLockScreenAndAsksTheSystemForNothingUntilHeFills() async throws {
        let backend = DemoVault.backend()
        backend.isLoggedIn = false
        let store = VaultStore(backend: backend)
        let enclave = FakeEnclave()
        let access = FakeAccessibility(isTrusted: false)
        let loginItem = FakeLoginItem()
        let automation = FakeAutomation()
        let tabs = CountingTab()
        let sink = FakeSink()
        var front = slack
        let door = Door(store: store, seal: PasswordSeal(directory: directory, enclave: enclave),
                        defaults: defaults, clipboard: Clipboard(pasteboard: pasteboard), isInFront: { true })
        let quick = QuickAccess(door: door, front: { front }, tabs: tabs,
                                typist: Typist(access: access, ground: FakeForeground(frontPID: slack.pid), sink: sink),
                                settings: defaults, present: { _ in }, pointer: { .zero },
                                screens: { [NSRect(x: 0, y: 0, width: 1512, height: 982)] })
        up.append(quick)
        let rooms = Rooms(door: door, hands: .init(loginItem: loginItem, access: access, automation: automation))

        func nothingWasAsked(_ when: String, line: UInt = #line) {
            XCTAssertEqual(access.asked, 0, "Accessibility, \(when)", line: line)
            XCTAssertEqual(access.opened, 0, "System Settings, \(when)", line: line)
            XCTAssertEqual(automation.opened, 0, "System Settings, \(when)", line: line)
            XCTAssertEqual(loginItem.asked, [], "the login item, \(when)", line: line)
            XCTAssertEqual(enclave.asked, [], "a finger, \(when)", line: line)
            XCTAssertEqual(sink.keys, [], "a key, \(when)", line: line)
            XCTAssertFalse(defaults.bool(forKey: QuickAccess.askedKey), when, line: line)
        }

        // What the delegate does as the app comes up.
        await store.refresh()
        door.lockScreenAppeared()
        await Task.yield()
        XCTAssertEqual(store.state, .loggedOut)
        XCTAssertNil(door.panes)
        XCTAssertNil(door.signIn, "the sheet waits for its button")
        XCTAssertFalse(door.isOfferingFinger)
        XCTAssertFalse(door.hasSeal)
        let window = MainWindow.make()
        window.contentView = NSHostingView(rootView: DoorView(door: door))
        window.layoutIfNeeded()
        let drawn = heard(in: window.contentView).filter { !$0.isSilent }.map(\.words)
        XCTAssertEqual(drawn.count, 3, "the heading, the sentence and the one button: \(drawn)")
        XCTAssertTrue(drawn.contains("Sign In…"), "\(drawn)")
        nothingWasAsked("at launch")
        XCTAssertEqual(tabs.asked, 0)

        // Signed in, in a terminal or in the sheet, the same window is the
        // field for the master password.
        backend.isLoggedIn = true
        await store.refresh()
        XCTAssertEqual(store.state, .locked)
        nothingWasAsked("locked")

        // The hot key over a browser, with the vault shut: the lock, and the
        // browser is not asked for its page.
        front = safari
        quick.show()
        await quick.askingTab?.value
        XCTAssertFalse(quick.isOpen)
        XCTAssertEqual(tabs.asked, 0, "the first Apple Event raises Automation's question")
        quick.close()
        nothingWasAsked("with the panel over a shut vault")

        // Every room of the settings, looked into.
        for room in Room.allCases {
            rooms.room = room
            await rooms.look().value
        }
        nothingWasAsked("with every room of the settings opened")
        XCTAssertEqual(tabs.asked, 0)

        // The password opens it. The one question here is the app's own,
        // whether a finger should open it next time, and no sheet of the
        // system's comes with it.
        await door.unlock(with: SecretBytes(DemoVault.password)).value
        await store.indexing?.value
        XCTAssertEqual(store.state, .unlocked)
        XCTAssertTrue(door.isOfferingFinger)
        door.answerFingerOffer(false)
        nothingWasAsked("unlocked")

        // The panel over an app that is no browser, and a password copied.
        front = slack
        quick.show()
        quick.query = "spotify"
        XCTAssertEqual(quick.rows.first?.item.name, "Spotify")
        quick.pressReturn()
        XCTAssertFalse(quick.isUp)
        XCTAssertNotNil(pasteboard.string(forType: .string))
        XCTAssertEqual(tabs.asked, 0, "an app that is not a browser has no tab")
        nothingWasAsked("after a copy")

        // The first fill: copied, with the panel saying why, and the
        // system's question behind the notice's button.
        quick.show()
        quick.query = "spotify"
        XCTAssertTrue(quick.fill())
        XCTAssertNotNil(quick.notice)
        nothingWasAsked("before he says to ask")
        XCTAssertTrue(quick.press(try returnKey()))
        XCTAssertEqual(access.asked, 1, "here and nowhere before it")
        XCTAssertTrue(defaults.bool(forKey: QuickAccess.askedKey))
        XCTAssertEqual(access.opened, 0)
        XCTAssertEqual(sink.keys, [])

        // And the browser is asked for its page the first time the panel
        // comes up over it with the vault open.
        front = safari
        quick.show()
        await quick.askingTab?.value
        XCTAssertEqual(tabs.asked, 1)
        XCTAssertEqual(automation.opened, 0)
        XCTAssertEqual(loginItem.asked, [])
        XCTAssertEqual(enclave.asked, [])
    }

    /// The calls that raise a question of the system's, each in the one file
    /// that stands behind a protocol a test replaces, and none in the
    /// delegate, which is what runs at launch.
    func testEachOfTheSystemsQuestionsIsInOneFileAndNoneIsInTheDelegate() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let walk = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var files: [String: String] = [:]
        for case let file as URL in walk where file.pathExtension == "swift" {
            files[file.lastPathComponent] = try String(contentsOf: file, encoding: .utf8)
        }
        XCTAssertGreaterThan(files.count, 100)

        let homes: [(call: String, file: String)] = [
            ("AXIsProcessTrustedWithOptions", "SystemKeys.swift"),
            ("kAXTrustedCheckOptionPrompt", "SystemKeys.swift"),
            ("AEDeterminePermissionToAutomateTarget", "Automation.swift"),
            ("sendEvent(options:", "FrontApp.swift"),
            ("SMAppService", "LoginItem.swift"),
            ("LAContext()", "Enclave.swift EnclaveSeal.swift"),
        ]
        for (call, file) in homes {
            let found = files.filter { $0.value.contains(call) }.keys.sorted()
            XCTAssertEqual(found, file.components(separatedBy: " ").sorted(), call)
        }
        // With `askUserIfNeeded` false, which is how a grant is read
        // without its question being put.
        let automation = try XCTUnwrap(files["Automation.swift"])
        XCTAssertTrue(automation.contains("AEEventID(kAEGetData), false)"))

        // And what the app has no business asking for at all.
        let never = ["UNUserNotificationCenter", "CGRequestScreenCaptureAccess", "CGRequestPostEventAccess",
                     "CGRequestListenEventAccess", "IOHIDRequestAccess", "CNContactStore", "CLLocationManager",
                     "AVCaptureDevice", "EKEventStore", "PHPhotoLibrary", "NSAppleScript", "requestAuthorization"]
        for call in never {
            XCTAssertEqual(files.filter { $0.value.contains(call) }.keys.sorted(), [], call)
        }

        let delegate = try XCTUnwrap(files["AppDelegate.swift"])
        for call in [".ask()", ".openSettings()", "askForFinger", ".register()", "allowTyping", ".set(true"] {
            XCTAssertFalse(delegate.contains(call), "the delegate calls \(call)")
        }
    }
}
