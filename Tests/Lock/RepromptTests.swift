import AppKit
import SwiftUI
import XCTest
@testable import OriPass

/// The demo's GitHub is the one item with `reprompt` set.
@MainActor
final class RepromptTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var defaults: UserDefaults!
    private var suite = ""
    private var directory: URL!
    private var backend: FakeBackend!
    private var up: [QuickAccess] = []

    override func setUp() {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("oripass-test-\(UUID().uuidString)"))
        suite = "oripass-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("oripass-reprompt-\(UUID().uuidString)")
    }

    override func tearDown() {
        up.forEach { $0.end() }
        up = []
        pasteboard.releaseGlobally()
        pasteboard = nil
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        try? FileManager.default.removeItem(at: directory)
        backend = nil
    }

    private var copied: String? { pasteboard.string(forType: .string) }

    /// A question is asked on a task of its own. This waits for it to have
    /// been put, and gives up after a second.
    private func until(_ isSo: () -> Bool) async {
        for _ in 0..<200 where !isSo() {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func shut(_ change: (JSONValue) -> JSONValue = { $0 }) -> VaultStore {
        let vault = DemoVault.objects()
        backend = FakeBackend(items: vault.items.map(change), folders: vault.folders, password: DemoVault.password)
        // Synced a minute ago, so no sync is running behind the panes.
        backend.lastSync = Date().addingTimeInterval(-60)
        return VaultStore(backend: backend)
    }

    private func demo(_ change: (JSONValue) -> JSONValue = { $0 }) async -> VaultStore {
        let store = shut(change)
        await store.unlock(password: SecretBytes(DemoVault.password))
        await store.indexing?.value
        return store
    }

    /// Panes over the open demo vault that ask `authoriser`.
    private func panes(_ authoriser: FakeAuthoriser, stage: LargeTypeStage? = nil) async -> (Panes, Reprompt) {
        let store = await demo()
        let reprompt = Reprompt(store: store, authoriser: authoriser)
        return (Panes(store: store, clipboard: Clipboard(pasteboard: pasteboard), stage: stage, reprompt: reprompt),
                reprompt)
    }

    @discardableResult
    private func choose(_ title: String, in panes: Panes) throws -> ItemDetail {
        let entry = try XCTUnwrap(panes.list.entries.first { $0.item.name == title }, "no \(title)")
        panes.select(item: entry.id)
        return try XCTUnwrap(panes.detail)
    }

    // MARK: The five acts

    func testACopyAsksAndIsMadeWhenTheAnswerIsYes() async throws {
        let authoriser = FakeAuthoriser()
        let (panes, reprompt) = await panes(authoriser)
        let github = try choose("GitHub", in: panes)

        XCTAssertTrue(panes.copyPassword())
        XCTAssertNil(copied, "nothing leaves before the answer")
        XCTAssertNil(panes.reading.copied)
        await reprompt.asking?.value
        XCTAssertEqual(authoriser.asked, [.copy])
        XCTAssertEqual(copied, github.value(of: ItemDetail.passwordRow))
        XCTAssertEqual(panes.reading.copied, ItemDetail.passwordRow)
    }

    func testARevealAsksByTheKeyAndByTheRowsMenu() async throws {
        let authoriser = FakeAuthoriser()
        let (panes, reprompt) = await panes(authoriser)
        let github = try choose("GitHub", in: panes)
        XCTAssertFalse(github.hiddenRows.isEmpty)

        panes.toggleRevealed()
        XCTAssertTrue(panes.reading.revealed.isEmpty)
        await reprompt.asking?.value
        XCTAssertEqual(authoriser.asked, [.reveal])
        XCTAssertEqual(panes.reading.revealed, Set(github.hiddenRows))

        let (others, second) = await self.panes(authoriser)
        try choose("GitHub", in: others)
        others.perform(.reveal, on: ItemDetail.passwordRow)
        XCTAssertTrue(others.reading.revealed.isEmpty)
        await second.asking?.value
        XCTAssertEqual(authoriser.asked, [.reveal, .reveal])
        XCTAssertEqual(others.reading.revealed, [ItemDetail.passwordRow])
    }

    func testAnEditAsksBeforeTheFormOpens() async throws {
        let authoriser = FakeAuthoriser()
        let (panes, reprompt) = await panes(authoriser)
        try choose("GitHub", in: panes)

        XCTAssertTrue(panes.beginEdit())
        XCTAssertNil(panes.editor)
        await reprompt.asking?.value
        XCTAssertEqual(authoriser.asked, [.edit])
        XCTAssertEqual(panes.editor?.form.title, "GitHub")
    }

    func testLargeTypeAsksBeforeItGoesUp() async throws {
        let authoriser = FakeAuthoriser()
        let stage = RememberingStage()
        let (panes, reprompt) = await panes(authoriser, stage: stage)
        try choose("GitHub", in: panes)

        panes.showLargeType(of: ItemDetail.passwordRow)
        XCTAssertNil(stage.showing)
        XCTAssertNil(panes.reading.largeType)
        await reprompt.asking?.value
        XCTAssertEqual(authoriser.asked, [.largeType])
        XCTAssertEqual(stage.shows, 1)
        XCTAssertNotNil(panes.reading.largeType)
    }

    /// Nothing types into another app yet (OP-47). This is the gate it
    /// will go through, asked as a fill.
    func testAFillAsksAtTheGateItWillGoThrough() async throws {
        let authoriser = FakeAuthoriser()
        let store = await demo()
        let reprompt = Reprompt(store: store, authoriser: authoriser)
        let github = try XCTUnwrap(store.shelves.all.first { $0.item.name == "GitHub" }).item
        var filled = 0

        XCTAssertFalse(reprompt.allow(.fill, on: github) { filled += 1 })
        XCTAssertEqual(filled, 0)
        await reprompt.asking?.value
        XCTAssertEqual(authoriser.asked, [.fill])
        XCTAssertEqual(filled, 1)
        XCTAssertEqual(Set(GuardedAct.allCases), [.reveal, .copy, .edit, .fill, .largeType, .sign, .passkey, .makePasskey, .pass, .phone, .pick, .overwrite])
    }

    func testTheEarlierPasswordsAndAFileAskAndAHeldOptionShowsNothing() async throws {
        let authoriser = FakeAuthoriser()
        // The demo's GitHub has neither an earlier password nor a file.
        let store = await demo { object in
            guard object["name"]?.string == "GitHub" else { return object }
            return object
                .setting(["passwordHistory"],
                         to: .array([.object(["lastUsedDate": .null, "password": .string("earlier")])]))
                .setting(["attachments"],
                         to: .array([.object(["id": .string("a1"), "fileName": .string("kod.txt"),
                                              "size": .string("4"), "sizeName": .string("4 B")])]))
        }
        let reprompt = Reprompt(store: store, authoriser: authoriser)
        let desk = AttachmentDesk(copies: OpenCopies(directory: directory), stage: RememberingPreview())
        let panes = Panes(store: store, desk: desk, reprompt: reprompt)
        let detail = try choose("GitHub", in: panes)

        panes.peek(true)
        XCTAssertFalse(panes.reading.isPeeking, "⌥ shows nothing of an item that has not been answered for")
        XCTAssertTrue(authoriser.asked.isEmpty, "and asks nothing")

        let row = try XCTUnwrap(detail.attachments.first).id
        XCTAssertNil(panes.openAttachment(row))
        XCTAssertEqual(backend.count(of: "fetch"), 0)
        authoriser.answer = false
        await reprompt.asking?.value
        XCTAssertEqual(authoriser.asked, [.reveal])
        XCTAssertEqual(backend.count(of: "fetch"), 0, "a no fetches nothing")

        authoriser.answer = true
        panes.showHistory()
        XCTAssertNil(panes.reading.history)
        await reprompt.asking?.value
        XCTAssertEqual(panes.reading.history?.entries.count, 1)
        XCTAssertEqual(authoriser.asked, [.reveal, .reveal])

        panes.peek(true)
        XCTAssertTrue(panes.reading.isPeeking, "answered for, ⌥ is what it was")
    }

    // MARK: Once for each item in each unlock

    func testASecondActOnTheSameItemDoesNotAsk() async throws {
        let authoriser = FakeAuthoriser()
        let stage = RememberingStage()
        let (panes, reprompt) = await panes(authoriser, stage: stage)
        let github = try choose("GitHub", in: panes)
        panes.copyPassword()
        await reprompt.asking?.value
        XCTAssertEqual(authoriser.asked, [.copy])

        pasteboard.clearContents()
        XCTAssertTrue(panes.copyPrimary())
        XCTAssertEqual(copied, github.value(of: try XCTUnwrap(github.primaryRow)), "at once, as any item's")
        panes.toggleRevealed()
        XCTAssertEqual(panes.reading.revealed, Set(github.hiddenRows))
        panes.showLargeType(of: ItemDetail.passwordRow)
        XCTAssertEqual(stage.shows, 1)
        // Another item and back: the answer is the unlock's, not the visit's.
        try choose("Spotify", in: panes)
        try choose("GitHub", in: panes)
        XCTAssertTrue(panes.beginEdit())
        XCTAssertNotNil(panes.editor)
        XCTAssertEqual(authoriser.asked, [.copy], "four acts later")
        XCTAssertNil(reprompt.asking)
    }

    func testAnItemThatDoesNotAskIsNeverAskedAbout() async throws {
        let authoriser = FakeAuthoriser()
        let (panes, reprompt) = await panes(authoriser)
        let spotify = try choose("Spotify", in: panes)
        XCTAssertFalse(spotify.item.reprompt)

        panes.copyPassword()
        XCTAssertEqual(copied, spotify.value(of: ItemDetail.passwordRow))
        panes.toggleRevealed()
        XCTAssertFalse(panes.reading.revealed.isEmpty)
        XCTAssertTrue(panes.beginEdit())
        XCTAssertNotNil(panes.editor)
        XCTAssertTrue(authoriser.asked.isEmpty)
        XCTAssertNil(reprompt.asking)
    }

    func testANoDoesNothingAndTheNextActAsksAgain() async throws {
        let authoriser = FakeAuthoriser()
        authoriser.answer = false
        let (panes, reprompt) = await panes(authoriser)
        try choose("GitHub", in: panes)

        panes.copyPassword()
        await reprompt.asking?.value
        XCTAssertNil(copied)
        XCTAssertNil(panes.reading.copied)
        panes.toggleRevealed()
        await reprompt.asking?.value
        XCTAssertTrue(panes.reading.revealed.isEmpty)
        XCTAssertEqual(authoriser.asked, [.copy, .reveal])
        XCTAssertEqual(reprompt.count, 0)
    }

    func testAnAnswerThatComesAfterAnotherItemWasChosenDoesNothingToEither() async throws {
        let authoriser = FakeAuthoriser()
        authoriser.holds = true
        let (panes, reprompt) = await panes(authoriser)
        try choose("GitHub", in: panes)
        panes.copyPassword()
        let asking = try XCTUnwrap(reprompt.asking)
        // A second act under the same question is dropped, not queued.
        panes.toggleRevealed()

        try choose("Spotify", in: panes)
        await until { authoriser.asked.count == 1 }
        authoriser.release(true)
        await asking.value
        XCTAssertEqual(authoriser.asked, [.copy])
        XCTAssertNil(copied, "the answer was for GitHub, and Spotify is what the details hold")
        XCTAssertTrue(panes.reading.revealed.isEmpty)
    }

    // MARK: The lock

    func testALockForgetsEveryAnswer() async throws {
        let authoriser = FakeAuthoriser()
        let store = shut()
        let reprompt = Reprompt(store: store, authoriser: authoriser)
        let door = Door(store: store, clipboard: Clipboard(pasteboard: pasteboard), reprompt: reprompt)
        await door.unlock(with: SecretBytes(DemoVault.password)).value
        var panes = try XCTUnwrap(door.panes)
        try choose("GitHub", in: panes)
        panes.copyPassword()
        await reprompt.asking?.value
        XCTAssertEqual(reprompt.count, 1)
        XCTAssertNotNil(copied)

        await store.lock()
        XCTAssertEqual(reprompt.count, 0)
        await door.unlock(with: SecretBytes(DemoVault.password)).value
        panes = try XCTUnwrap(door.panes)
        try choose("GitHub", in: panes)
        panes.toggleRevealed()
        XCTAssertTrue(panes.reading.revealed.isEmpty, "the answer was the last unlock's")
        await reprompt.asking?.value
        XCTAssertEqual(authoriser.asked, [.copy, .reveal])
        XCTAssertFalse(panes.reading.revealed.isEmpty)
    }

    func testALockUnderAQuestionWithdrawsItAndTheActIsNeverDone() async throws {
        let authoriser = FakeAuthoriser()
        authoriser.holds = true
        let store = shut()
        let reprompt = Reprompt(store: store, authoriser: authoriser)
        let door = Door(store: store, clipboard: Clipboard(pasteboard: pasteboard), reprompt: reprompt)
        await door.unlock(with: SecretBytes(DemoVault.password)).value
        try choose("GitHub", in: try XCTUnwrap(door.panes))
        door.panes?.copyPassword()
        let asking = try XCTUnwrap(reprompt.asking)
        await until { authoriser.asked.count == 1 }

        await store.lock()
        await asking.value
        XCTAssertEqual(authoriser.withdrawn, 1)
        XCTAssertNil(reprompt.asking)
        XCTAssertNil(copied)
        XCTAssertEqual(reprompt.count, 0)
    }

    // MARK: Quick Access

    private func quick(over door: Door) -> QuickAccess {
        let quick = QuickAccess(door: door, recents: Recents(file: nil), present: { _ in },
                                pointer: { .zero }, screens: { [NSRect(x: 0, y: 0, width: 1512, height: 982)] })
        up.append(quick)
        quick.show()
        return quick
    }

    func testQuickAccessAsksBeforeItCopiesAndOnlyOnce() async throws {
        let authoriser = FakeAuthoriser()
        let store = await demo()
        let reprompt = Reprompt(store: store, authoriser: authoriser)
        let quick = quick(over: Door(store: store, clipboard: Clipboard(pasteboard: pasteboard), reprompt: reprompt))
        quick.query = "github"
        let github = try XCTUnwrap(quick.rows.first?.item)
        XCTAssertEqual(github.name, "GitHub")

        quick.pressReturn()
        XCTAssertNil(copied, "Return copies nothing of an item that asks until it is answered for")
        XCTAssertFalse(quick.isUp, "the panel goes before the question comes")
        XCTAssertTrue(quick.recents.ids.isEmpty)
        await reprompt.asking?.value
        XCTAssertEqual(authoriser.asked, [.copy])
        XCTAssertEqual(copied, github.login?.password)
        XCTAssertTrue(pasteboard.types?.contains(Clipboard.concealed) == true)
        XCTAssertEqual(quick.recents.ids, [github.id])

        // The same unlock, the other key and an opened item's row.
        pasteboard.clearContents()
        quick.show()
        quick.query = "github"
        XCTAssertTrue(quick.copyPrimary())
        XCTAssertEqual(copied, github.login?.username)
        quick.show()
        quick.query = "github"
        XCTAssertTrue(quick.openSelected())
        quick.pressReturn()
        XCTAssertEqual(authoriser.asked, [.copy])

        // And the window on the same vault has been answered for too.
        let panes = try XCTUnwrap(quick.door.panes)
        try choose("GitHub", in: panes)
        panes.toggleRevealed()
        XCTAssertFalse(panes.reading.revealed.isEmpty)
        XCTAssertEqual(authoriser.asked, [.copy])
    }

    func testQuickAccessCopiesNothingAfterANoOrALock() async throws {
        let authoriser = FakeAuthoriser()
        authoriser.answer = false
        let store = await demo()
        let reprompt = Reprompt(store: store, authoriser: authoriser)
        let quick = quick(over: Door(store: store, clipboard: Clipboard(pasteboard: pasteboard), reprompt: reprompt))
        quick.query = "github"
        XCTAssertTrue(quick.copyPassword())
        await reprompt.asking?.value
        XCTAssertNil(copied)
        XCTAssertTrue(quick.recents.ids.isEmpty)

        authoriser.holds = true
        quick.show()
        quick.query = "github"
        quick.pressReturn()
        let asking = try XCTUnwrap(reprompt.asking)
        await until { authoriser.asked.count == 2 }
        await store.lock()
        await asking.value
        XCTAssertNil(copied)
        XCTAssertEqual(authoriser.asked, [.copy, .copy])
    }

    // MARK: The finger, and the password

    private func seal(over enclave: Enclave) -> PasswordSeal {
        PasswordSeal(directory: directory, enclave: enclave)
    }

    func testWithASealItIsTheFingerUnderTheActsOwnReason() async throws {
        let enclave = FakeEnclave()
        let seal = seal(over: enclave)
        let store = await demo()
        try seal.seal(SecretBytes(DemoVault.password))
        let stage = RememberingQuestion()
        let check = OwnerCheck(store: store, seal: seal, stage: stage)
        let sent = backend.calls.count

        let isHis = await check.authorise(.largeType, for: "GitHub")
        XCTAssertTrue(isHis)
        XCTAssertEqual(enclave.asked, [GuardedAct.largeType.reason])
        XCTAssertEqual(backend.calls.count, sent, "the password that came out of the seal went nowhere")
        XCTAssertFalse(enclave.asked[0].contains("GitHub"), "the system's sheet names no item")
        XCTAssertEqual(stage.shows, 0)
        XCTAssertEqual(backend.count(of: "confirm"), 0)

        enclave.cancels = true
        let cancelled = await check.authorise(.copy, for: "GitHub")
        XCTAssertFalse(cancelled)
        XCTAssertEqual(stage.shows, 0, "a cancelled finger is a no, and the password is not offered in its place")
        XCTAssertEqual(seal.standing, .ready)
        XCTAssertEqual(Set(GuardedAct.allCases.map(\.reason)).count, GuardedAct.allCases.count)
    }

    /// A finger enrolled since the seal was made opens it for nobody, so
    /// the item is answered for with the password and not left unanswerable.
    func testWithASealNoFingerOpensItIsThePassword() async throws {
        let enclave = FakeEnclave()
        let seal = seal(over: enclave)
        let store = await demo()
        try seal.seal(SecretBytes(DemoVault.password))
        enclave.enrolAnotherFinger()
        let stage = RememberingQuestion()
        let check = OwnerCheck(store: store, seal: seal, stage: stage)

        let asking = Task { await check.authorise(.copy, for: "GitHub") }
        await until { stage.showing != nil }
        XCTAssertTrue(enclave.asked.isEmpty)
        try XCTUnwrap(stage.showing).submit(SecretBytes(DemoVault.password))
        let isHis = await asking.value
        XCTAssertTrue(isHis)
    }

    func testWithoutASealItIsThePasswordAndAWrongOneLeavesTheCardUpAndTheVaultOpen() async throws {
        let store = await demo()
        let stage = RememberingQuestion()
        let check = OwnerCheck(store: store, seal: seal(over: FakeEnclave()), stage: stage)
        var answer: Bool?
        let asking = Task { answer = await check.authorise(.copy, for: "GitHub") }
        await until { stage.showing != nil }
        let question = try XCTUnwrap(stage.showing)
        XCTAssertTrue(question.statement.contains("GitHub"))
        XCTAssertTrue(question.sentence.contains(GuardedAct.copy.wanted))

        let wrong = SecretBytes("not-the-password")
        question.submit(wrong)
        XCTAssertTrue(question.isChecking)
        await question.checking?.value
        XCTAssertEqual(question.refusal, VaultStore.notThePassword)
        XCTAssertFalse(question.isChecking)
        XCTAssertNil(answer)
        XCTAssertNotNil(stage.showing)
        XCTAssertTrue(wrong.matches(SecretBytes(String(repeating: "\0", count: wrong.count))), "wiped")
        XCTAssertEqual(store.state, .unlocked)
        XCTAssertTrue(backend.isOpen, "a wrong password asked again shuts nothing")

        let right = SecretBytes(DemoVault.password)
        question.submit(right)
        await question.checking?.value
        await asking.value
        XCTAssertEqual(answer, true)
        XCTAssertNil(stage.showing)
        XCTAssertNil(check.question)
        XCTAssertTrue(right.matches(SecretBytes(String(repeating: "\0", count: right.count))))
        XCTAssertEqual(backend.calls.filter { $0 == "confirm" }.count, 2)
        XCTAssertEqual(backend.count(of: "unlock"), 1, "the vault was not opened a second time")
    }

    /// The card says a wrong password plainly, as the lock screen does, and
    /// anything else the engine refuses with in the engine's words.
    func testTheCardSaysAWrongPasswordPlainlyAndAnyOtherRefusalAsItCame() async throws {
        let store = await demo()
        let stage = RememberingQuestion()
        let check = OwnerCheck(store: store, seal: nil, stage: stage)
        let asking = Task { _ = await check.authorise(.reveal, for: "GitHub") }
        await until { stage.showing != nil }
        let question = try XCTUnwrap(stage.showing)
        for (engine, drawn) in [(FakeBackend.wrongPassword, VaultStore.notThePassword),
                                ("Invalid master password.", VaultStore.notThePassword),
                                (FakeBackend.offline, FakeBackend.offline)] {
            backend.refusal = .refused(engine)
            question.submit(SecretBytes(DemoVault.password))
            await question.checking?.value
            XCTAssertEqual(question.refusal, drawn)
        }
        backend.refusal = nil
        question.cancel()
        await asking.value
    }

    func testCancelAndTheLockAreEachANoAndNoPanelIsAnAnswerOfNo() async throws {
        let store = await demo()
        let stage = RememberingQuestion()
        let check = OwnerCheck(store: store, seal: nil, stage: stage)
        var answer: Bool?
        var asking = Task { answer = await check.authorise(.reveal, for: "GitHub") }
        await until { stage.showing != nil }
        try XCTUnwrap(stage.showing).cancel()
        await asking.value
        XCTAssertEqual(answer, false)
        XCTAssertNil(stage.showing)

        answer = nil
        let reprompt = Reprompt(store: store, authoriser: check)
        let github = try XCTUnwrap(store.shelves.all.first { $0.item.name == "GitHub" }).item
        var done = 0
        reprompt.allow(.reveal, on: github) { done += 1 }
        asking = try XCTUnwrap(reprompt.asking)
        await until { stage.showing != nil }
        XCTAssertNotNil(stage.showing)
        await store.lock()
        await asking.value
        XCTAssertNil(stage.showing, "the card goes with the vault")
        XCTAssertNil(check.question)
        XCTAssertEqual(done, 0)

        let nowhere = OwnerCheck(store: await demo(), seal: nil, stage: nil)
        let refused = await nowhere.authorise(.copy, for: "GitHub")
        XCTAssertFalse(refused)
    }

    /// The card says the password is checked and not kept, and it is not:
    /// one asked for again is never the one that is sealed, even with
    /// Touch ID wanted and nothing sealed yet.
    func testAPasswordAskedAgainIsNotSealed() async throws {
        let enclave = FakeEnclave()
        enclave.hasFinger = false
        let seal = seal(over: enclave)
        let store = shut()
        let stage = RememberingQuestion()
        let check = OwnerCheck(store: store, seal: seal, stage: stage)
        let door = Door(store: store, seal: seal, defaults: defaults,
                        reprompt: Reprompt(store: store, authoriser: check), isInFront: { false })
        door.preferences.settings.lock.unlockWithFinger = true
        // The lid was shut over the sensor at the unlock, so nothing was
        // sealed, and it is open now.
        await door.unlock(with: SecretBytes(DemoVault.password)).value
        XCTAssertFalse(door.hasSeal)
        enclave.hasFinger = true

        let asking = Task { await check.authorise(.copy, for: "GitHub") }
        await until { stage.showing != nil }
        let question = try XCTUnwrap(stage.showing)
        question.submit(SecretBytes(DemoVault.password))
        await question.checking?.value
        let isHis = await asking.value
        XCTAssertTrue(isHis)
        XCTAssertFalse(door.hasSeal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("password").path))

        // The next one typed at the lock screen is.
        await store.lock()
        await door.unlock(with: SecretBytes(DemoVault.password)).value
        XCTAssertTrue(door.hasSeal)
    }

    func testThePanelHoldsTheCardAndEscIsANo() async throws {
        var answer: Bool?
        let question = PasswordQuestion(act: .edit, name: "GitHub", check: { $0.wipe(); return nil },
                                        answer: { answer = $0 })
        let panel = PasswordPanel.make(question, within: NSRect(x: 0, y: 0, width: 1512, height: 982))
        defer { panel.contentView = nil }
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertEqual(panel.frame.midX, 756, accuracy: 1)
        XCTAssertEqual(panel.frame.midY, 491, accuracy: 1)
        XCTAssertGreaterThan(panel.frame.height, Metrics.lockField.height * 4)
        let words = said(in: panel.contentView)
        XCTAssertTrue(words.contains(question.statement), "\(words)")
        XCTAssertTrue(words.contains("Continue"))

        panel.cancelOperation(nil)
        XCTAssertEqual(answer, false)
        answer = nil
        panel.cancelOperation(nil)
        XCTAssertNil(answer, "answered once")
    }

    // MARK: The switch

    func testTheFormsSwitchSetsItAndSavesNothingElse() async throws {
        let store = await demo()
        let panes = Panes(store: store)
        let spotify = try choose("Spotify", in: panes).item
        XCTAssertTrue(panes.beginEdit())
        let editor = try XCTUnwrap(panes.editor)
        XCTAssertFalse(editor.form.asksAgain)

        let window = MainWindow.make()
        window.contentView = NSHostingView(rootView: PanesView(panes: panes))
        window.setContentSize(CGSize(width: Metrics.windowSize.width, height: Metrics.windowSize.height * 2))
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(said(in: window.contentView).contains(EditorView.asksAgain))
        window.contentView = nil

        editor.form.asksAgain = true
        XCTAssertTrue(editor.isDirty)
        await panes.saveEdit()?.value
        XCTAssertEqual(backend.lastSaved, spotify.raw.setting(["reprompt"], to: .int(1)))
        XCTAssertEqual(store.entry(id: spotify.id)?.item.reprompt, true)

        // And off again, on the item that came with it on.
        let github = try choose("GitHub", in: panes).item
        XCTAssertTrue(panes.beginEdit())
        XCTAssertEqual(panes.editor?.form.asksAgain, true)
        panes.editor?.form.asksAgain = false
        await panes.saveEdit()?.value
        XCTAssertEqual(backend.lastSaved, github.raw.setting(["reprompt"], to: .int(0)))
    }
}
