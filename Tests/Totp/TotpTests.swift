import AppKit
import SwiftUI
import XCTest
@testable import OriPass

/// A window that says it can be seen, or cannot, whatever the screen is
/// doing: the Mac the tests run on may be at its login window.
private final class SeenWindow: NSWindow {
    var isSeen = true {
        didSet { NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: self) }
    }

    override var occlusionState: NSWindow.OcclusionState { isSeen ? .visible : [] }
}

@MainActor
final class TotpTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("oripass-test-\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
    }

    private var copied: String? { pasteboard.string(forType: .string) }

    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    /// RFC 4648, written out here so the test does not lean on the code it
    /// is testing.
    private func base32(_ text: String) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var held = 0, bits = 0, written = ""
        for byte in Array(text.utf8) {
            held = held << 8 | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                written.append(alphabet[held >> bits & 31])
            }
        }
        if bits > 0 { written.append(alphabet[held << (5 - bits) & 31]) }
        return written
    }

    /// RFC 6238, appendix B. Its three secrets are the ASCII of the digits
    /// one to nought, over and over, as long as each hash's output.
    private static let seed = "1234567890"
    private static let vectors: [(time: TimeInterval, sha1: String, sha256: String, sha512: String)] = [
        (59, "94287082", "46119246", "90693936"),
        (1_111_111_109, "07081804", "68084774", "25091201"),
        (1_111_111_111, "14050471", "67062674", "99943326"),
        (1_234_567_890, "89005924", "91819424", "93441116"),
        (2_000_000_000, "69279037", "90698825", "38618901"),
        (20_000_000_000, "65353130", "77737706", "47863826"),
    ]

    private func rfc(_ hash: String, bytes: Int) throws -> Totp {
        let secret = base32(String(String(repeating: Self.seed, count: 7).prefix(bytes)))
        return try XCTUnwrap(Totp("otpauth://totp/RFC:6238?secret=\(secret)&digits=8&algorithm=\(hash)"))
    }

    // MARK: The arithmetic

    func testTheRFCsVectorsForSHA1() throws {
        let totp = try rfc("SHA1", bytes: 20)
        XCTAssertEqual(totp.hash, .sha1)
        for vector in Self.vectors { XCTAssertEqual(totp.code(at: at(vector.time)), vector.sha1, "at \(vector.time)") }
    }

    func testTheRFCsVectorsForSHA256() throws {
        let totp = try rfc("SHA256", bytes: 32)
        XCTAssertEqual(totp.hash, .sha256)
        for vector in Self.vectors { XCTAssertEqual(totp.code(at: at(vector.time)), vector.sha256, "at \(vector.time)") }
    }

    func testTheRFCsVectorsForSHA512() throws {
        let totp = try rfc("SHA512", bytes: 64)
        XCTAssertEqual(totp.hash, .sha512)
        for vector in Self.vectors { XCTAssertEqual(totp.code(at: at(vector.time)), vector.sha512, "at \(vector.time)") }
    }

    // MARK: The three forms

    func testABareSecretIsThirtySecondsSixDigitsAndSHA1() throws {
        let secret = base32(String(repeating: Self.seed, count: 2))
        XCTAssertEqual(secret, "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        let totp = try XCTUnwrap(Totp(secret))
        XCTAssertEqual(totp.period, 30)
        XCTAssertEqual(totp.digits, 6)
        XCTAssertEqual(totp.hash, .sha1)
        XCTAssertFalse(totp.isSteam)
        // The RFC's eight digits with the first two off.
        XCTAssertEqual(totp.code(at: at(59)), "287082")
        XCTAssertEqual(totp.code(at: at(1_111_111_109)), "081804", "a code keeps the noughts it starts with")
        XCTAssertEqual(totp.code(at: at(30)), totp.code(at: at(59)), "one code for the whole half minute")
        XCTAssertNotEqual(totp.code(at: at(60)), totp.code(at: at(59)))

        // As a site prints it and as a hand types it.
        for written in ["gezdgnbvgy3tqojqgezdgnbvgy3tqojq", "GEZD GNBV GY3T QOJQ GEZD GNBV GY3T QOJQ",
                        "  GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ\n", "GEZD-GNBV-GY3T-QOJQ-GEZD-GNBV-GY3T-QOJQ",
                        "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ===="] {
            XCTAssertEqual(Totp(written)?.code(at: at(59)), "287082", written)
        }
        // Worked out apart from this app, in Python's hmac.
        XCTAssertEqual(Totp("JBSWY3DPEHPK3PXP")?.code(at: at(0)), "282760")
        XCTAssertEqual(Totp("JBSWY3DPEHPK3PXP")?.code(at: at(30)), "996554")
    }

    func testAnAddressWithASixtySecondPeriodAndEightDigits() throws {
        let secret = base32(String(repeating: Self.seed, count: 2))
        let totp = try XCTUnwrap(Totp("otpauth://totp/Banka:deniz?secret=\(secret)&issuer=Banka&period=60&digits=8"))
        XCTAssertEqual(totp.period, 60)
        XCTAssertEqual(totp.digits, 8)
        XCTAssertEqual(totp.hash, .sha1, "an address that names no hash")
        // The counter is the minute, so the first minute's code is the
        // RFC's first, which is the counter at nought.
        XCTAssertEqual(totp.code(at: at(0)), totp.code(at: at(59)))
        XCTAssertNotEqual(totp.code(at: at(60)), totp.code(at: at(59)))
        XCTAssertEqual(totp.code(at: at(60)), "94287082", "counter one, which thirty seconds reach at 59")
        XCTAssertEqual(totp.secondsLeft(at: at(0)), 60)
        XCTAssertEqual(totp.secondsLeft(at: at(59)), 1)

        // The names of the parts in any case, and the hash's too.
        let shouted = try XCTUnwrap(Totp("OTPAUTH://totp/x?SECRET=\(secret)&Digits=8&Algorithm=sha256&Period=15"))
        XCTAssertEqual(shouted.hash, .sha256)
        XCTAssertEqual(shouted.period, 15)

        // What makes no sense is left at what a bare secret gets.
        let odd = try XCTUnwrap(Totp("otpauth://totp/x?secret=\(secret)&digits=0&period=-3&algorithm=MD5"))
        XCTAssertEqual([odd.digits, odd.period], [6, 30])
        XCTAssertEqual(odd.hash, .sha1)
        let long = try XCTUnwrap(Totp("otpauth://totp/x?secret=\(secret)&digits=99"))
        XCTAssertEqual(long.digits, 10)
        XCTAssertEqual(long.code(at: at(59)).count, 10)
    }

    func testASteamSecretMakesFiveOfSteamsLetters() throws {
        let secret = base32(String(repeating: Self.seed, count: 2))
        let totp = try XCTUnwrap(Totp("steam://\(secret)"))
        XCTAssertTrue(totp.isSteam)
        XCTAssertEqual(totp.period, 30)
        // Worked out apart from this app, in Python's hmac.
        XCTAssertEqual(totp.code(at: at(59)), "PV9M4")
        XCTAssertEqual(totp.code(at: at(1_111_111_109)), "PY4YB")
        XCTAssertEqual(Totp.grouped("PV9M4"), ["PV9M4"])
    }

    func testASecretThatIsNotBase32IsNoCodeAndNeverATrap() {
        let secret = base32(String(repeating: Self.seed, count: 2))
        for written in ["", "   ", "not base32!", "1890", "GEZD1", "şifre", "otpauth://totp/x", "otpauth://",
                        "otpauth://totp/x?secret=", "otpauth://totp/x?secret=!!!", "steam://", "steam://1",
                        "====", "🔑", "otpauth://totp/x?issuer=only"] {
            XCTAssertNil(Totp(written), written)
        }
        // And what can be read is read at any moment, with any numbers.
        let strange = [
            "A", "AA", "otpauth://totp/x?secret=\(secret)&period=999999999999&digits=10",
            "otpauth://totp/x?secret=\(secret)&period=1&digits=1", String(repeating: "A", count: 100_000),
            "otpauth://hotp/x?secret=\(secret)&counter=3",
        ]
        let moments = [-1_000_000, 0, 0.5, 59, 4_102_444_800, 1e15].map(at)
        for written in strange {
            guard let totp = Totp(written) else { continue }
            for moment in moments {
                XCTAssertEqual(totp.code(at: moment).count, totp.digits, written)
                XCTAssertTrue((1...totp.period).contains(totp.secondsLeft(at: moment)))
            }
        }
        XCTAssertEqual(Totp.invalid, "invalid secret")
    }

    func testTheSecondsLeftAndTheGroups() throws {
        let totp = try XCTUnwrap(Totp("JBSWY3DPEHPK3PXP"))
        XCTAssertEqual(totp.secondsLeft(at: at(0)), 30)
        XCTAssertEqual(totp.secondsLeft(at: at(14.9)), 16)
        XCTAssertEqual(totp.secondsLeft(at: at(29.9)), 1)
        XCTAssertEqual(totp.secondsLeft(at: at(30)), 30)
        XCTAssertEqual(totp.share(at: at(15)), 0.5)
        XCTAssertEqual(totp.secondsLeft(at: CodeRow.shotMoment), 16, "the shots' moment is the still's")

        XCTAssertEqual(Totp.grouped("867082"), ["867", "082"])
        XCTAssertEqual(Totp.grouped("94287082"), ["9428", "7082"])
        XCTAssertEqual(Totp.grouped("1234567"), ["1234567"])
        XCTAssertEqual(Totp.grouped("7"), ["7"])
    }

    func testASecretIsSaidByNoPrintAndNoDump() throws {
        let secret = DemoVault.totpSecrets[0]
        let totp = try XCTUnwrap(Totp(secret))
        var dumped = ""
        dump(totp, to: &dumped)
        dump(ItemDetail.Row(id: ItemDetail.codeRow, label: "one-time code", value: .code(totp)), to: &dumped)
        let said = "\(totp) \(String(describing: totp)) \(String(reflecting: totp)) \(dumped)"
        XCTAssertFalse(said.contains(secret))
        XCTAssertFalse(said.contains("key"))
        XCTAssertTrue(said.contains("Totp"))
    }

    // MARK: In the details

    private func login(_ name: String, totp: String?) -> JSONValue {
        .object([
            "object": .string("item"), "id": .string("totp-\(name)"), "type": .int(1), "name": .string(name),
            "favorite": .bool(false), "reprompt": .int(0), "notes": .null, "fields": .array([]),
            "creationDate": .string("2025-01-05T09:30:00.000Z"), "revisionDate": .string("2025-03-12T16:41:03.000Z"),
            "login": .object(["username": .string("deniz"), "password": .string("a password"),
                              "totp": JSONValue(totp), "uris": .array([])]),
        ])
    }

    /// An open vault whose clock is the test's.
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_014)
    }

    private func store(_ items: [JSONValue], folders: [JSONValue] = [], clock: Clock) async -> VaultStore {
        let backend = FakeBackend(items: items, folders: folders, password: DemoVault.password)
        // Synced a minute ago, so no sync is running behind the panes.
        backend.lastSync = clock.now.addingTimeInterval(-60)
        let store = VaultStore(backend: backend, now: { clock.now })
        await store.unlock(password: SecretBytes(DemoVault.password))
        return store
    }

    private func demo(clock: Clock) async -> VaultStore {
        let vault = DemoVault.objects()
        return await store(vault.items, folders: vault.folders, clock: clock)
    }

    @discardableResult
    private func choose(_ title: String, in panes: Panes) throws -> ItemDetail {
        let entry = try XCTUnwrap(panes.list.entries.first { $0.item.name == title }, "no \(title)")
        panes.select(item: entry.id)
        return try XCTUnwrap(panes.detail)
    }

    private func hosted(_ panes: Panes) -> SeenWindow {
        let window = SeenWindow(contentRect: NSRect(origin: .zero, size: Metrics.windowSize),
                                styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PanesView(panes: panes).ignoresSafeArea())
        window.layoutIfNeeded()
        return window
    }

    private func turn(_ seconds: Double = 0.1) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func testTheRowIsUnderThePasswordAndAnItemWithNoSecretHasNone() async throws {
        let clock = Clock()
        let panes = Panes(store: await demo(clock: clock))
        let bank = try choose("İş Bankası", in: panes)
        XCTAssertEqual(bank.main.map(\.id), ["username", ItemDetail.passwordRow, ItemDetail.codeRow])
        XCTAssertEqual(bank.main.last?.label, "one-time code")
        XCTAssertEqual(bank.codeRowID, ItemDetail.codeRow)
        XCTAssertEqual(bank.value(of: ItemDetail.codeRow, at: clock.now), "475947", "worked out in Python's hmac")
        XCTAssertFalse(bank.isHidden(ItemDetail.codeRow), "the code is drawn, and the secret never is")
        XCTAssertFalse(bank.hiddenRows.contains(ItemDetail.codeRow))
        XCTAssertTrue(bank.stops.contains(ItemDetail.codeRow), "the arrows stop on it")
        XCTAssertEqual(panes.actions(for: ItemDetail.codeRow), [.largeType])
        // Not the secret, under any moment.
        for moment in [0, 59, 1_800_000_014].map(at) {
            XCTAssertNotEqual(bank.value(of: ItemDetail.codeRow, at: moment), DemoVault.totpSecrets[0])
        }

        // An address, and after a passkey's row.
        let hub = try choose("GitHub", in: panes)
        XCTAssertEqual(hub.main.last?.id, ItemDetail.codeRow)
        XCTAssertEqual(hub.value(of: ItemDetail.codeRow, at: clock.now)?.count, 6)

        let plain = try choose("Spotify", in: panes)
        XCTAssertNil(plain.codeRowID)
        XCTAssertFalse(plain.main.contains { $0.id == ItemDetail.codeRow })
        XCTAssertFalse(panes.copyCode())
    }

    func testTheKeyCopiesTheCodeThatStandsAtThatInstant() async throws {
        let clock = Clock()
        let store = await demo(clock: clock)
        let panes = Panes(store: store, clipboard: Clipboard(pasteboard: pasteboard))
        try choose("İş Bankası", in: panes)
        let totp = try XCTUnwrap(Totp(DemoVault.totpSecrets[0]))

        XCTAssertTrue(panes.copyCode())
        XCTAssertEqual(copied, "475947")
        XCTAssertEqual(panes.reading.copied, ItemDetail.codeRow, "the row says Copied")
        XCTAssertTrue(pasteboard.types?.contains(Clipboard.concealed) == true, "through the one way out (D15)")

        // The details were worked out once, half a minute ago. The copy is
        // of the code now.
        clock.now = clock.now.addingTimeInterval(30)
        let later = totp.code(at: clock.now)
        XCTAssertNotEqual(later, "475947")
        XCTAssertTrue(panes.copyCode())
        XCTAssertEqual(copied, later)

        // A click on the row is the same copy.
        clock.now = clock.now.addingTimeInterval(30)
        XCTAssertTrue(panes.copy(ItemDetail.codeRow))
        XCTAssertEqual(copied, totp.code(at: clock.now))
    }

    func testTheItemMenusKeyIsLitOnlyForAnItemWithACode() async throws {
        let clock = Clock()
        let door = Door(store: await demo(clock: clock), clipboard: Clipboard(pasteboard: pasteboard))
        let panes = try XCTUnwrap(door.panes)
        let commands = ItemCommands(door: door)
        let item = try XCTUnwrap(KeyTable.item(.copyCode, in: commands.menu()))
        XCTAssertEqual(item.keyEquivalent, "c")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .option])
        XCTAssertNil(KeyTable[.copyCode].waits)
        XCTAssertTrue(panes.keyCommands.contains { $0.id == .copyCode }, "the sheet of keys lists it")

        try choose("Spotify", in: panes)
        XCTAssertFalse(commands.validateMenuItem(item))
        try choose("İş Bankası", in: panes)
        XCTAssertTrue(commands.validateMenuItem(item))
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
        XCTAssertEqual(copied, "475947")
    }

    func testASecretThatCannotBeReadDrawsInvalidSecretAndCopiesNothing() async throws {
        let clock = Clock()
        let store = await store([login("Bozuk", totp: "not base32!"), login("Boş", totp: "  ")], clock: clock)
        let panes = Panes(store: store, clipboard: Clipboard(pasteboard: pasteboard))
        let window = hosted(panes)

        let broken = try choose("Bozuk", in: panes)
        XCTAssertEqual(broken.main.map(\.id), ["username", ItemDetail.passwordRow, ItemDetail.codeRow])
        XCTAssertNil(broken.codeRowID)
        XCTAssertNil(broken.value(of: ItemDetail.codeRow))
        XCTAssertFalse(broken.stops.contains(ItemDetail.codeRow))
        XCTAssertFalse(panes.copyCode())
        XCTAssertFalse(panes.copy(ItemDetail.codeRow))
        XCTAssertNil(copied)
        XCTAssertEqual(panes.actions(for: ItemDetail.codeRow), [])
        try await turn()
        let words = said(in: window.contentView)
        XCTAssertTrue(words.contains("one-time code"))
        XCTAssertTrue(words.contains(Totp.invalid))
        XCTAssertFalse(words.contains { $0.contains("not base32!") }, "what was typed as a secret is not drawn")

        let blank = try choose("Boş", in: panes)
        XCTAssertFalse(blank.main.contains { $0.id == ItemDetail.codeRow }, "nothing typed is no row")
        window.close()
    }

    // MARK: What ticks

    private var ticking: Int {
        Instruments.live.filter { $0.owner == CodeRow.ticking.owner && $0.name == CodeRow.ticking.name }.count
    }

    private var watching: Int {
        Instruments.live.filter { $0.owner == CodeRow.watching.owner }.count
    }

    /// Until `isSo`, for a second at most.
    private func until(_ isSo: @autoclosure () -> Bool) async throws {
        for _ in 0..<40 where !isSo() { try await turn(0.025) }
    }

    func testTheRowSaysItsCodeAndTicksOnlyWhileItCanBeSeen() async throws {
        let clock = Clock()
        let store = await demo(clock: clock)
        await store.scoring?.value
        await store.indexing?.value
        let panes = Panes(store: store)
        XCTAssertEqual(ticking, 0)

        let window = hosted(panes)
        try await turn()
        XCTAssertEqual(ticking, 0, "no item is chosen")

        try choose("İş Bankası", in: panes)
        try await until(self.ticking == 1)
        XCTAssertEqual(ticking, 1, "one timeline, for the one code on the screen")
        XCTAssertTrue(Instruments.live.contains { $0.owner == "Totp" && $0.kind == .timer })
        let totp = try XCTUnwrap(Totp(DemoVault.totpSecrets[0]))
        let now = Date()
        let codes = [now.addingTimeInterval(-2), now, now.addingTimeInterval(2)]
            .map { Totp.grouped(totp.code(at: $0)).joined(separator: " ") }
        var words = said(in: window.contentView)
        XCTAssertTrue(words.contains("one-time code"))
        XCTAssertTrue(words.contains(where: codes.contains), "the row says the code of this half minute")
        XCTAssertFalse(words.contains { $0.contains(DemoVault.totpSecrets[0]) })

        // Behind another window, in the Dock, or with the screen asleep.
        window.isSeen = false
        try await until(self.ticking == 0)
        XCTAssertEqual(ticking, 0, "a window nobody can see draws no code again")
        words = said(in: window.contentView)
        XCTAssertTrue(words.contains(where: codes.contains), "and still has the one it drew last")
        window.isSeen = true
        try await until(self.ticking == 1)
        XCTAssertEqual(ticking, 1)

        // An item with no code.
        try choose("Spotify", in: panes)
        try await until(self.ticking == 0)
        XCTAssertEqual(ticking, 0)
        XCTAssertEqual(watching, 0, "and nothing is left listening for the window")

        try choose("GitHub", in: panes)
        try await until(self.ticking == 1)
        XCTAssertEqual(ticking, 1)

        // The details folded away with the item still chosen.
        panes.select(item: nil)
        try await until(self.ticking == 0)
        XCTAssertEqual(ticking, 0)
        window.close()
    }

    private func scrollViews(in view: NSView?) -> [NSScrollView] {
        guard let view else { return [] }
        return (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }

    func testACodeScrolledOutOfViewStopsTickingAndStartsAgainWhenItIsBack() async throws {
        let clock = Clock()
        let store = await demo(clock: clock)
        await store.scoring?.value
        await store.indexing?.value
        let panes = Panes(store: store)
        let window = hosted(panes)
        // So short that the details show less than the rows over the code:
        // the row starts below what can be seen, and GitHub's long note
        // takes it out again above.
        window.setContentSize(CGSize(width: Metrics.windowSize.width, height: Metrics.windowMinimum.height / 2))
        window.layoutIfNeeded()
        try choose("GitHub", in: panes)
        try await turn()

        let details = try XCTUnwrap(scrollViews(in: window.contentView).max {
            $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
        })
        let document = try XCTUnwrap(details.documentView)
        XCTAssertTrue(document.isFlipped)
        let clip = details.contentView
        let far = document.frame.height - clip.bounds.height
        XCTAssertGreaterThan(far, clip.bounds.height * 2)
        func scroll(to place: CGFloat) {
            clip.scroll(to: NSPoint(x: 0, y: place))
            details.reflectScrolledClipView(clip)
            window.layoutIfNeeded()
            window.displayIfNeeded()
        }

        try await until(self.ticking == 0)
        XCTAssertEqual(ticking, 0, "the row is in the tree and under the fold")
        XCTAssertEqual(watching, 1, "listening for the window, and that is all")

        // Down a quarter of the window at a time until the code is drawn.
        var place: CGFloat = 0
        while ticking == 0, place < far {
            place = min(far, place + clip.bounds.height / 4)
            scroll(to: place)
            try await until(self.ticking == 1)
        }
        XCTAssertEqual(ticking, 1, "scrolled into view, it ticks")
        XCTAssertLessThan(place, far)

        scroll(to: far)
        try await until(self.ticking == 0)
        XCTAssertEqual(ticking, 0, "a row scrolled out of the details draws no code again")
        XCTAssertEqual(watching, 1)

        scroll(to: place)
        try await until(self.ticking == 1)
        XCTAssertEqual(ticking, 1, "and does when it is scrolled back")
        window.close()
    }

    func testTheLockLeavesNoTimelineBehind() async throws {
        let clock = Clock()
        let store = await demo(clock: clock)
        let door = Door(store: store)
        let window = SeenWindow(contentRect: NSRect(origin: .zero, size: Metrics.windowSize),
                                styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DoorView(door: door).ignoresSafeArea())
        window.layoutIfNeeded()
        let panes = try XCTUnwrap(door.panes)
        try choose("İş Bankası", in: panes)
        try await until(self.ticking == 1)
        XCTAssertEqual(ticking, 1)

        await store.lock()
        try await until(self.ticking == 0 && self.watching == 0)
        XCTAssertEqual(ticking, 0)
        XCTAssertEqual(watching, 0)
        XCTAssertFalse(Instruments.live.contains { $0.owner == "Totp" })
        window.close()
    }

    func testAnItemThatAsksShowsNoCodeUntilItIsAnsweredFor() async throws {
        let clock = Clock()
        let store = await demo(clock: clock)
        let authoriser = FakeAuthoriser()
        let reprompt = Reprompt(store: store, authoriser: authoriser)
        let panes = Panes(store: store, clipboard: Clipboard(pasteboard: pasteboard), reprompt: reprompt)
        let window = hosted(panes)
        let hub = try choose("GitHub", in: panes)
        let code = try XCTUnwrap(hub.value(of: ItemDetail.codeRow, at: clock.now))
        let drawn = try XCTUnwrap(Totp(try XCTUnwrap(hub.item.login?.totp)))
        func isSaid() -> Bool {
            let now = Date()
            let codes = [now.addingTimeInterval(-2), now].map { Totp.grouped(drawn.code(at: $0)).joined(separator: " ") }
            return said(in: window.contentView).contains(where: codes.contains)
        }
        try await turn()
        XCTAssertTrue(panes.isHeldBack)
        XCTAssertFalse(isSaid(), "the code of an item that asks is drawn before anyone was asked")
        XCTAssertEqual(ticking, 0)

        XCTAssertTrue(panes.copyCode())
        XCTAssertNil(copied, "nothing is copied until the answer")
        await reprompt.asking?.value
        XCTAssertEqual(authoriser.asked, [.copy])
        XCTAssertEqual(copied, code)
        try await until(self.ticking == 1)
        XCTAssertTrue(isSaid(), "answered for, the row shows its code")
        window.close()
    }

    func testAShotDrawsEveryCodeAtOneMoment() async throws {
        let clock = Clock()
        let panes = Panes(store: await demo(clock: clock))
        CodeRow.still = CodeRow.shotMoment
        defer { CodeRow.still = nil }
        let window = hosted(panes)
        try choose("İş Bankası", in: panes)
        try await turn()
        XCTAssertEqual(ticking, 0, "a shot has no clock under it")
        XCTAssertTrue(said(in: window.contentView).contains("475 947"))
        window.close()
    }
}
