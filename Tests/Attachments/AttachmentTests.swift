import AppKit
import SwiftUI
import XCTest
@testable import OriPass

@MainActor
final class AttachmentTests: XCTestCase {
    private var directory: URL!
    private var outside: URL!
    private var backend: FakeBackend!
    private var preview: RememberingPreview!
    private var panels: AnsweringPanels!
    private var desk: AttachmentDesk!

    override func setUp() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oripass-test-\(UUID().uuidString)")
        directory = root.appendingPathComponent("attachments")
        outside = root.appendingPathComponent("outside")
        try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        backend = DemoVault.backend()
        preview = RememberingPreview()
        panels = AnsweringPanels()
        desk = AttachmentDesk(copies: OpenCopies(directory: directory), stage: preview, panels: panels)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
        desk = nil
        backend = nil
    }

    private func store() async -> VaultStore {
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes(DemoVault.password))
        return store
    }

    /// Panes on the note with two files, and the rows of the two.
    private func panes(over store: VaultStore? = nil) async throws -> (panes: Panes, rows: [String]) {
        let held: VaultStore
        if let store { held = store } else { held = await self.store() }
        let panes = Panes(store: held, desk: desk)
        let rows = try choose("Yazılım lisansı", in: panes).attachments.map(\.id)
        XCTAssertEqual(rows.count, 2)
        return (panes, rows)
    }

    @discardableResult
    private func choose(_ title: String, in panes: Panes) throws -> ItemDetail {
        let entry = try XCTUnwrap(panes.list.entries.first { $0.item.name == title }, "no \(title)")
        panes.select(item: entry.id)
        return try XCTUnwrap(panes.detail)
    }

    private func hosted(_ panes: Panes) -> NSWindow {
        let window = MainWindow.make()
        window.contentView = NSHostingView(rootView: PanesView(panes: panes))
        window.setContentSize(CGSize(width: Metrics.windowSize.width, height: Metrics.windowSize.height))
        window.layoutIfNeeded()
        return window
    }

    private func turn(_ seconds: Double = 0.05) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private var held: [URL] { desk.copies.held }

    /// Whether anything at all is where the copies go: a file, a folder, or
    /// the directory itself.
    private var isThere: Bool { FileManager.default.fileExists(atPath: directory.path) }

    // MARK: The rows

    func testAnItemsAttachmentsAreRowsWithANameAndASize() async throws {
        let (panes, rows) = try await panes()
        let files = try XCTUnwrap(panes.detail?.attachments)
        XCTAssertEqual(files.map(\.name), ["lisans.txt", "fatura-2026.pdf"])
        let sizes = DemoVault.attachments.map {
            ByteCountFormatter.string(fromByteCount: Int64($0.body.count), countStyle: .file)
        }
        XCTAssertEqual(files.map(\.size), sizes)
        XCTAssertEqual(rows, ["attachment-0", "attachment-1"])

        let window = hosted(panes)
        try await turn()
        let words = said(in: window.contentView)
        for (file, size) in zip(files, sizes) {
            let place = try XCTUnwrap(words.firstIndex(of: "attachment, \(file.name)"), "\(file.name) in \(words)")
            XCTAssertEqual(words[place + 1], size)
        }
        XCTAssertFalse(words.contains { $0.contains(DemoVault.attached) }, "a row says nothing of what the file holds")

        try choose("Spotify", in: panes)
        XCTAssertEqual(panes.detail?.attachments, [])
        try await turn()
        XCTAssertFalse(said(in: window.contentView).contains { $0.hasPrefix("attachment, ") })
    }

    func testASizeTheItemGivesOnlyInWordsIsSaidInItsWords() throws {
        let object = JSONValue.object(["id": .string("a"), "fileName": .string(""), "sizeName": .string("1.5 MB")])
        let file = ItemDetail.File(place: 3, attachment: Attachment(json: object))
        XCTAssertEqual(file.size, "1.5 MB")
        XCTAssertEqual(file.name, "attachment", "a file with no name still has a row to click")
        XCTAssertEqual(file.id, "attachment-3")
        let bare = ItemDetail.File(place: 0, attachment: Attachment(json: .object(["id": .string("b")])))
        XCTAssertNil(bare.size)
    }

    func testARowsMenuIsQuickLookAndSaveAs() async throws {
        let (panes, rows) = try await panes()
        XCTAssertEqual(panes.actions(for: rows[0]), [.quickLook, .saveAs])
        XCTAssertEqual([FieldAction.quickLook.name, FieldAction.saveAs.name], ["Quick Look", "Save As…"])
        panes.toggleMenu(for: rows[1])
        XCTAssertEqual(panes.reading.menu?.row, rows[1])
        panes.perform(.quickLook, on: rows[1])
        XCTAssertNil(panes.reading.menu)
        await panes.fetch?.value
        XCTAssertEqual(preview.title, "fatura-2026.pdf")
        XCTAssertEqual(panes.actions(for: "attachment-9"), [])
    }

    // MARK: Fetch and preview

    func testAClickFetchesTheFileIntoAPrivateDirectoryAndOpensQuickLookOnIt() async throws {
        let (panes, rows) = try await panes()
        XCTAssertFalse(isThere, "nothing is written until a file is asked for")
        let task = try XCTUnwrap(panes.openAttachment(rows[0]))
        XCTAssertEqual(panes.reading.fetching, [rows[0]])
        XCTAssertNil(preview.showing)
        await task.value

        XCTAssertEqual(backend.count(of: "fetch"), 1)
        XCTAssertEqual(panes.reading.fetching, [])
        let copy = try XCTUnwrap(preview.showing)
        XCTAssertEqual(preview.title, "lisans.txt")
        XCTAssertEqual(copy.lastPathComponent, "lisans.txt")
        XCTAssertEqual(preview.read, DemoVault.attachments[0].body)
        XCTAssertEqual(held.map(\.standardizedFileURL), [copy.standardizedFileURL], "one copy, and it is the one shown")
        XCTAssertTrue(String(decoding: try Data(contentsOf: copy), as: UTF8.self).contains(DemoVault.attached))

        // Nobody else on the Mac reads the directory or the folder in it.
        for path in [directory.path, copy.deletingLastPathComponent().path] {
            let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
            XCTAssertEqual(mode, 0o700, path)
        }
        XCTAssertEqual(copy.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL,
                       directory.standardizedFileURL)
    }

    func testTheCopyIsDeletedWhenThePreviewCloses() async throws {
        let (panes, rows) = try await panes()
        await panes.openAttachment(rows[0])?.value
        let copy = try XCTUnwrap(preview.showing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))

        preview.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.deletingLastPathComponent().path),
                       "and the folder made for it")
        XCTAssertEqual(held, [])
    }

    func testTheCopyIsDeletedOnLock() async throws {
        let store = await store()
        let door = Door(store: store, desk: desk)
        let panes = try XCTUnwrap(door.panes)
        let row = try XCTUnwrap(try choose("Yazılım lisansı", in: panes).attachments.first?.id)
        await panes.openAttachment(row)?.value
        let copy = try XCTUnwrap(preview.showing)
        XCTAssertEqual(held.count, 1)

        await store.lock()
        XCTAssertNil(door.panes)
        XCTAssertNil(preview.showing, "the preview goes with the vault")
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertFalse(isThere, "and the directory with everything in it")
    }

    func testALockThatOvertakesAFetchLeavesNoFileAndNoPreview() async throws {
        let store = await store()
        let door = Door(store: store, desk: desk)
        let panes = try XCTUnwrap(door.panes)
        let row = try XCTUnwrap(try choose("Yazılım lisansı", in: panes).attachments.first?.id)
        backend.delay = 0.2
        let task = try XCTUnwrap(panes.openAttachment(row))
        try await turn()
        backend.delay = 0
        await store.lock()
        await task.value
        XCTAssertEqual(preview.shows, 0)
        XCTAssertFalse(isThere)
    }

    func testAFileWrittenAsTheVaultLocksIsGoneAndNeverShown() async throws {
        let store = await store()
        let door = Door(store: store, desk: desk)
        let panes = try XCTUnwrap(door.panes)
        let row = try XCTUnwrap(try choose("Yazılım lisansı", in: panes).attachments.first?.id)
        var written = 0
        // The engine has written the file and has not answered yet.
        backend.onFetched = { [unowned self] in
            written = self.held.count
            await store.lock()
        }
        await panes.openAttachment(row)?.value
        XCTAssertEqual(written, 1, "the file was on disk when the lock came")
        XCTAssertEqual(store.state, .locked)
        XCTAssertEqual(preview.shows, 0)
        XCTAssertFalse(isThere)
    }

    func testAnotherItemPutsThePreviewAwayAndDeletesItsCopy() async throws {
        let (panes, rows) = try await panes()
        await panes.openAttachment(rows[0])?.value
        XCTAssertEqual(held.count, 1)
        try choose("Spotify", in: panes)
        XCTAssertNil(preview.showing)
        XCTAssertEqual(held, [])

        // And a fetch that had not come back is not shown when it does.
        try choose("Yazılım lisansı", in: panes)
        backend.delay = 0.1
        let task = try XCTUnwrap(panes.openAttachment(rows[1]))
        try choose("Spotify", in: panes)
        backend.delay = 0
        await task.value
        XCTAssertEqual(preview.shows, 1)
        XCTAssertEqual(held, [])
        XCTAssertEqual(panes.reading.fetching, [])
    }

    func testASecondFileTakesTheFirstOnesPlace() async throws {
        let (panes, rows) = try await panes()
        await panes.openAttachment(rows[0])?.value
        let first = try XCTUnwrap(preview.showing)
        await panes.openAttachment(rows[1])?.value
        let second = try XCTUnwrap(preview.showing)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(held.map(\.lastPathComponent), ["fatura-2026.pdf"], "one copy at a time")
        XCTAssertEqual(preview.read, DemoVault.attachments[1].body)
    }

    func testAWindowOfOneItemOpensThroughTheSameDeskAndItsCloseDeletesTheCopy() async throws {
        let (panes, rows) = try await panes()
        let id = try XCTUnwrap(panes.selectedItem?.id)
        XCTAssertNotNil(panes.windows?.open(id, from: panes))
        let own = try XCTUnwrap(panes.windows?.panes(showing: id))
        await own.openAttachment(rows[0])?.value
        XCTAssertEqual(held.count, 1)
        panes.end()
        XCTAssertNil(preview.showing)
        XCTAssertEqual(held, [])
    }

    func testWhatACrashLeftIsGoneWhenTheDirectoryIsEmptiedAtLaunch() throws {
        let copies = OpenCopies(directory: directory)
        let left = try copies.place(for: "left.txt")
        try Data(DemoVault.attached.utf8).write(to: left)
        try Data("stray".utf8).write(to: directory.appendingPathComponent("stray"))
        XCTAssertEqual(OpenCopies(directory: directory).held.count, 2)

        // What the app's delegate does before it does anything else.
        OpenCopies(directory: directory).removeAll()
        XCTAssertFalse(isThere)
        XCTAssertEqual(copies.held, [])
        // And the directory is made again by the next file.
        XCTAssertNoThrow(try copies.place(for: "next.txt"))
    }

    func testANameFromTheVaultCannotLeaveTheDirectory() throws {
        let copies = OpenCopies(directory: directory)
        for name in ["../../escape.txt", "/etc/passwd", "..", ".", "", "  ", "a:b/c", "nul\0l"] {
            let place = try copies.place(for: name)
            XCTAssertEqual(place.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL,
                           directory.standardizedFileURL, name)
            XCTAssertEqual(place.standardizedFileURL.path, place.path, name)
            XCTAssertFalse(place.lastPathComponent.isEmpty)
        }
        XCTAssertEqual(OpenCopies.safe("../../escape.txt"), ".._.._escape.txt")
        XCTAssertEqual(OpenCopies.safe(".."), "attachment")
        XCTAssertEqual(OpenCopies.safe("fatura 2026.pdf"), "fatura 2026.pdf")

        // Only a copy of its own is anything it removes.
        let stranger = outside.appendingPathComponent("kept.txt")
        try Data("kept".utf8).write(to: stranger)
        copies.remove(stranger)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stranger.path))
    }

    // MARK: Refused

    func testAFetchTheEngineRefusesIsItsSentenceOnTheRowAndNothingOnDisk() async throws {
        let (panes, rows) = try await panes()
        backend.attachmentRefusal = .refused(FakeBackend.needsPremium)
        await panes.openAttachment(rows[0])?.value
        XCTAssertEqual(panes.reading.unfetched, [rows[0]: FakeBackend.needsPremium])
        XCTAssertEqual(panes.reading.fetching, [])
        XCTAssertNil(panes.refused, "the row says it, and not the banner")
        XCTAssertEqual(preview.shows, 0)
        XCTAssertEqual(held, [])

        let window = hosted(panes)
        try await turn()
        let words = said(in: window.contentView)
        let place = try XCTUnwrap(words.firstIndex(of: "attachment, lisans.txt"))
        XCTAssertEqual(words[place + 1], FakeBackend.needsPremium)

        // Asked again, the sentence goes while the engine is asked.
        backend.attachmentRefusal = nil
        await panes.openAttachment(rows[0])?.value
        XCTAssertEqual(panes.reading.unfetched, [:])
        XCTAssertNotNil(preview.showing)
        panes.reading.unfetched[rows[1]] = "x"
        try choose("Spotify", in: panes)
        XCTAssertEqual(panes.reading.unfetched, [:], "and another item takes it away")
    }

    // MARK: Save As

    func testSaveAsWritesWhereHeSaysAndNowhereElseAndThatFileIsHis() async throws {
        let store = await store()
        let door = Door(store: store, desk: desk)
        let panes = try XCTUnwrap(door.panes)
        let rows = try choose("Yazılım lisansı", in: panes).attachments.map(\.id)
        let destination = outside.appendingPathComponent("saved.txt")
        panels.saveTo = destination
        panes.perform(.saveAs, on: rows[0])
        await panes.writing?.value

        XCTAssertEqual(panels.asked, ["save lisans.txt"])
        XCTAssertEqual(try Data(contentsOf: destination), DemoVault.attachments[0].body)
        XCTAssertEqual(backend.count(of: "fetch"), 1)
        XCTAssertFalse(isThere, "no copy was made on the way")
        XCTAssertEqual(preview.shows, 0)
        XCTAssertEqual(panes.reading.fetching, [])

        await store.lock()
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path), "the lock leaves it")
    }

    func testSaveAsThoughtBetterOfAsksTheEngineNothing() async throws {
        let (panes, rows) = try await panes()
        panels.saveTo = nil
        await panes.saveAttachment(rows[0])?.value
        XCTAssertEqual(panels.asked, ["save lisans.txt"])
        XCTAssertEqual(backend.count(of: "fetch"), 0)

        backend.attachmentRefusal = .refused(FakeBackend.needsPremium)
        panels.saveTo = outside.appendingPathComponent("refused.txt")
        await panes.saveAttachment(rows[1])?.value
        XCTAssertEqual(panes.reading.unfetched, [rows[1]: FakeBackend.needsPremium])
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("refused.txt").path))
    }

    // MARK: Adding

    private func fileToAdd(_ name: String = "sozlesme.txt") throws -> URL {
        let file = outside.appendingPathComponent(name)
        try Data("sözleşme".utf8).write(to: file)
        return file
    }

    func testAttachAFileIsInTheMenuOfAnItemThatCanBeWritten() async throws {
        let (panes, _) = try await panes()
        XCTAssertEqual(panes.itemActs, [[.openWindow], [.favourite, .move, .duplicate, .attach], [.archive, .delete]])
        XCTAssertEqual(ItemAct.attach.name, "Attach a File…")
        try choose("Ehliyet", in: panes)
        XCTAssertFalse(panes.itemActs.joined().contains(.attach), "a type this app cannot write")
        panes.select(.trash)
        try choose("Kapanan hesap", in: panes)
        XCTAssertFalse(panes.itemActs.joined().contains(.attach))
        XCTAssertNil(panes.attachFile())
    }

    func testAFileHeChoosesIsSentToTheEngineAndTheItemHasOneRowMore() async throws {
        let (panes, _) = try await panes()
        let id = try XCTUnwrap(panes.selectedItem?.id)
        panels.attach = try fileToAdd()
        panes.toggle(.item)
        panes.perform(.attach)
        XCTAssertNil(panes.detailMenu)
        await panes.writing?.value

        XCTAssertEqual(panels.asked, ["attach"])
        XCTAssertEqual(backend.count(of: "attach"), 1)
        XCTAssertEqual(panes.detail?.id, id)
        XCTAssertEqual(panes.detail?.attachments.map(\.name), ["lisans.txt", "fatura-2026.pdf", "sozlesme.txt"])
        XCTAssertNil(panes.reading.adding)
        XCTAssertNil(panes.refused)
        XCTAssertFalse(isThere, "adding a file writes nothing here")

        // And it opens like the others.
        await panes.openAttachment("attachment-2")?.value
        XCTAssertEqual(preview.read, Data("sözleşme".utf8))
    }

    func testAFileTheEngineWillNotTakeIsARowWithItsNameAndTheSentence() async throws {
        let (panes, _) = try await panes()
        panels.attach = try fileToAdd()
        backend.attachmentRefusal = .refused(FakeBackend.needsPremium)
        await panes.attachFile()?.value
        XCTAssertEqual(panes.reading.adding, Adding(name: "sozlesme.txt", sentence: FakeBackend.needsPremium))
        XCTAssertEqual(panes.detail?.attachments.count, 2)
        XCTAssertNil(panes.refused)

        let window = hosted(panes)
        try await turn()
        let words = said(in: window.contentView)
        let place = try XCTUnwrap(words.firstIndex(of: "attachment, sozlesme.txt"), "\(words)")
        XCTAssertEqual(words[place + 1], FakeBackend.needsPremium)

        try choose("Spotify", in: panes)
        XCTAssertNil(panes.reading.adding)
    }

    func testChoosingNoFileAsksTheEngineNothing() async throws {
        let (panes, _) = try await panes()
        panels.attach = nil
        await panes.attachFile()?.value
        XCTAssertEqual(panels.asked, ["attach"])
        XCTAssertEqual(backend.count(of: "attach"), 0)
        XCTAssertNil(panes.reading.adding)
    }

    func testAnItemWithoutFilesShowsTheOneBeingAddedAndThenHasIt() async throws {
        let (panes, _) = try await panes()
        try choose("Spotify", in: panes)
        panels.attach = try fileToAdd()
        backend.delay = 0.1
        let task = try XCTUnwrap(panes.attachFile())
        try await turn(0.03)
        XCTAssertEqual(panes.reading.adding, Adding(name: "sozlesme.txt"))
        await task.value
        XCTAssertNil(panes.reading.adding)
        XCTAssertEqual(panes.detail?.attachments.map(\.name), ["sozlesme.txt"])
    }

    func testALockStopsAFileThatWasOnItsWayIn() async throws {
        let store = await store()
        let door = Door(store: store, desk: desk)
        let panes = try XCTUnwrap(door.panes)
        try choose("Spotify", in: panes)
        panels.attach = try fileToAdd()
        backend.delay = 0.2
        let task = try XCTUnwrap(panes.attachFile())
        try await turn()
        backend.delay = 0
        weak var reading = panes.reading
        await store.lock()
        await task.value
        XCTAssertNil(reading?.adding)
        XCTAssertNil(door.panes)
    }

    func testALockTakesDownTheFindersQuestionAndNothingIsSavedOrAdded() async throws {
        let store = await store()
        let door = Door(store: store, desk: desk)
        let panes = try XCTUnwrap(door.panes)
        let rows = try choose("Yazılım lisansı", in: panes).attachments.map(\.id)
        panels.waits = true
        let saving = try XCTUnwrap(panes.saveAttachment(rows[0]))
        try await turn()
        XCTAssertEqual(panels.asked, ["save lisans.txt"])
        XCTAssertTrue(panels.isUp, "the question is on the screen, with the file's name in it")

        await store.lock()
        XCTAssertFalse(panels.isUp, "the lock took it down")
        XCTAssertEqual(panels.dismissals, 1)
        await saving.value
        XCTAssertEqual(backend.count(of: "fetch"), 0)

        await store.unlock(password: SecretBytes(DemoVault.password))
        let again = try XCTUnwrap(door.panes)
        try choose("Spotify", in: again)
        let adding = try XCTUnwrap(again.attachFile())
        try await turn()
        XCTAssertTrue(panels.isUp)
        await store.lock()
        XCTAssertEqual(panels.dismissals, 2)
        await adding.value
        XCTAssertEqual(backend.count(of: "attach"), 0)
    }

    func testTheFindersOwnPanelIsTakenDownAndAnswersAsIfHeHadThoughtBetterOfIt() async throws {
        try Screen.skipIfLocked("that a real save panel goes when the desk ends")
        let system = SystemFilePanels()
        let desk = AttachmentDesk(copies: OpenCopies(directory: directory), stage: preview, panels: system)
        let asked = Task { await system.destination(named: "lisans.txt") }
        try await turn(0.3)
        let up = NSApp.windows.compactMap { $0 as? NSSavePanel }.filter(\.isVisible)
        XCTAssertEqual(up.map(\.nameFieldStringValue), ["lisans.txt"])

        desk.end()
        let answer = await asked.value
        XCTAssertNil(answer)
        XCTAssertEqual(NSApp.windows.compactMap { $0 as? NSSavePanel }.filter(\.isVisible), [])
    }

    // MARK: Without a desk

    func testWithoutADeskARowIsDrawnAndOpensNothing() async throws {
        let panes = Panes(store: await store())
        let rows = try choose("Yazılım lisansı", in: panes).attachments.map(\.id)
        XCTAssertNil(panes.openAttachment(rows[0]))
        XCTAssertNil(panes.saveAttachment(rows[0]))
        XCTAssertNil(panes.attachFile())
        XCTAssertEqual(backend.count(of: "fetch"), 0)
    }
}
