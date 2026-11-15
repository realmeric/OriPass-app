import AppKit
import SwiftUI
import XCTest
@testable import OriPass

@MainActor
final class StrengthTests: XCTestCase {
    /// Dates are counted from a year, so the tests name theirs.
    private let year = 2026

    /// Twenty characters nobody chose.
    private let random = "v9#Kq2mT!x7RbW4pZs8L"

    private func level(_ password: String) -> Strength {
        Strength.of(password, year: year)
    }

    private func login(_ n: Int, _ name: String, password: String?) -> JSONValue {
        .object([
            "object": .string("item"), "id": .string("strength-\(n)"), "type": .int(1), "name": .string(name),
            "favorite": .bool(false), "reprompt": .int(0), "notes": .null, "fields": .array([]),
            "creationDate": .string("2025-01-05T09:30:00.000Z"), "revisionDate": .string("2025-03-12T16:41:03.000Z"),
            "login": .object(["username": .string("deniz"), "password": JSONValue(password), "totp": .null,
                              "uris": .array([])]),
        ])
    }

    private func backend(_ items: [JSONValue]) -> FakeBackend {
        let backend = FakeBackend(items: items, folders: [], password: DemoVault.password)
        // Synced a minute ago, so no sync is running behind the scoring.
        backend.lastSync = Date().addingTimeInterval(-60)
        return backend
    }

    private func unlocked(_ backend: FakeBackend) async -> VaultStore {
        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes(DemoVault.password))
        return store
    }

    // MARK: The levels

    func testFourPasswordsLandInRisingLevelsAndTheSameOnesTwice() {
        let passwords = ["password", "qwerty123", "Meric2026!", random]
        let levels = passwords.map(level)
        XCTAssertEqual(levels, [.guessable, .weak, .fair, .strong])
        XCTAssertTrue(zip(levels, levels.dropFirst()).allSatisfy { $0 < $1 }, "\(levels)")
        XCTAssertEqual(passwords.map(level), levels)
    }

    func testTheLevelsAreCutWhereTheNotesSay() {
        XCTAssertEqual(Strength(guesses: 999), .guessable)
        XCTAssertEqual(Strength(guesses: 1e3), .weak)
        XCTAssertEqual(Strength(guesses: 1e6), .fair)
        XCTAssertEqual(Strength(guesses: 1e8), .good)
        XCTAssertEqual(Strength(guesses: 1e10), .strong)
        XCTAssertEqual(Strength(guesses: .infinity), .strong)
    }

    func testFiveLevelsEachWithAWordAndAFifthMoreOfTheRing() {
        XCTAssertEqual(Strength.allCases.count, 5)
        XCTAssertEqual(Strength.allCases.count, Palette.strength.count)
        XCTAssertEqual(Set(Strength.allCases.map(\.word)).count, 5)
        XCTAssertEqual(Strength.allCases.map(\.share), [0.2, 0.4, 0.6, 0.8, 1])
        XCTAssertEqual(Strength.allCases.sorted(), Strength.allCases)
    }

    // MARK: What a guesser tries first

    func testAWordHoweverItIsDressedIsFoundUnderIt() {
        for dressed in ["Password", "PASSWORD", "p@ssw0rd", "drowssap", "şifre", "İstanbul", "Dragon1"] {
            XCTAssertLessThanOrEqual(level(dressed), .weak, dressed)
        }
        // The capitals somewhere nobody puts them cost more than at the front.
        let guesswork = Guesswork(year: year)
        XCTAssertGreaterThan(guesswork.guesses(for: "paSSword"), guesswork.guesses(for: "Password"))
        XCTAssertGreaterThan(guesswork.guesses(for: "Password"), guesswork.guesses(for: "password"))
    }

    func testRunsAlongTheKeyboardRepeatsSequencesAndDatesAreCheap() {
        let cheap = [
            "qazwsxedc", "asdfghjkl", "1qaz2wsx", "zxcvbnm,./", "şlkjhgfdsa",
            "aaaaaaaaaa", "abcabcabcabc", "xyxyxyxyxy",
            "abcdefghij", "987654321", "13579",
            "15081990", "150890", "15.08.1990", "1990-08-15", "8/15/90",
        ]
        for password in cheap {
            XCTAssertLessThanOrEqual(level(password), .weak, password)
        }
        // The same lengths with nothing in them a guesser would try early.
        XCTAssertGreaterThanOrEqual(level("q7#vR2!kZp"), .good)
    }

    func testAYearNearThisOneIsALikelierGuessThanOneFarAway() {
        let guesswork = Guesswork(year: year)
        XCTAssertLessThan(guesswork.guesses(for: "2024"), guesswork.guesses(for: "1907"))
        XCTAssertEqual(Guesswork(year: 2026).guesses(for: "Meric2026!"), guesswork.guesses(for: "Meric2026!"))
    }

    func testWordsNobodyPutsTogetherAreStrongTogether() {
        XCTAssertGreaterThanOrEqual(level("correct horse battery staple"), .good)
        XCTAssertLessThan(level("horse"), level("correct horse battery staple"))
    }

    func testAnythingAtAllGetsALevelAndALongOneGetsItSoon() {
        for odd in ["", " ", "a", "🙂", "🙂🙂🙂🙂", "e\u{301}e\u{301}", "\u{0}\u{0}", "İİİ", "ǅǅ"] {
            _ = level(odd)
        }
        XCTAssertEqual(level("a"), .guessable)
        let started = Date()
        XCTAssertEqual(level(String(repeating: random, count: 500)), .strong)
        XCTAssertEqual(level(String(repeating: "a", count: 10_000)), .guessable)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    // MARK: Beside the item

    func testEveryPasswordIsScoredOncePerUnlockAndAnItemWithNoneHasNoLevel() async throws {
        let items = [login(1, "Old forum", password: "password"), login(2, "Bank", password: random),
                     login(3, "No password", password: nil), login(4, "Empty", password: "")]
        let backend = backend(items)
        let store = await unlocked(backend)
        await store.scoring?.value
        XCTAssertEqual(store.scorings, 2)
        XCTAssertEqual(store.entry(id: "strength-1")?.strength, .guessable)
        XCTAssertEqual(store.entry(id: "strength-2")?.strength, .strong)
        XCTAssertNil(store.entry(id: "strength-3")?.strength)
        XCTAssertNil(store.entry(id: "strength-4")?.strength)

        // A sync that changes nothing, then one that renames an item: no
        // password is read again.
        await store.sync()
        await store.scoring?.value
        XCTAssertEqual(store.scorings, 2)
        var changed = items
        changed[1] = changed[1].setting(["name"], to: .string("Bank, renamed"))
        backend.incoming = (changed, [])
        await store.sync()
        XCTAssertEqual(store.entry(id: "strength-2")?.item.name, "Bank, renamed")
        XCTAssertEqual(store.entry(id: "strength-2")?.strength, .strong, "the level went with the password")
        await store.scoring?.value
        XCTAssertEqual(store.scorings, 2)

        // A password that changed is the only one read.
        changed[0] = changed[0].setting(["login", "password"], to: .string(random + "x"))
        backend.incoming = (changed, [])
        var published = 0
        let watching = store.$scored.dropFirst().sink { _ in published += 1 }
        await store.sync()
        XCTAssertNil(store.entry(id: "strength-1")?.strength, "the old level is not the new password's")
        await store.scoring?.value
        watching.cancel()
        XCTAssertEqual(store.entry(id: "strength-1")?.strength, .strong)
        XCTAssertEqual(store.scorings, 3)
        XCTAssertEqual(published, 1)

        // Per unlock: a lock drops the levels with the items.
        await store.lock()
        XCTAssertNil(store.scoring)
        await store.unlock(password: SecretBytes(DemoVault.password))
        await store.scoring?.value
        XCTAssertEqual(store.scorings, 5)
    }

    func testALockWhileScoringLeavesNoItemBehind() async throws {
        let items = (0..<2000).map { login($0, "Row \($0)", password: DemoVault.strong($0)) }
        let store = await unlocked(backend(items))
        weak let held = store.shelves.all.first
        XCTAssertNotNil(held)
        await store.lock()
        XCTAssertNil(held, "the scoring kept an item past the lock")
        XCTAssertNil(store.scoring)
        XCTAssertLessThan(store.scorings, 2000)
    }

    // MARK: Two thousand

    /// The main thread is kept turning while the store scores, and the most
    /// it ever did in one turn is what a frame would have waited for. That
    /// is counted in the thread's own processor time, which another
    /// program's build cannot lengthen; the longest gap on the clock is
    /// printed beside it.
    func testTwoThousandPasswordsAreScoredWithoutHoldingUpAFrame() async throws {
        let dressed = ["password", "qwerty123", "Meric2026!", "15.08.1990", "correct horse battery staple"]
        let items = (0..<2000).map { n in
            login(n, "Row \(n)", password: n % 4 == 0 ? dressed[(n / 4) % dressed.count] + "\(n)" : DemoVault.strong(n))
        }
        let store = VaultStore(backend: backend(items))
        await store.unlock(password: SecretBytes(DemoVault.password))
        let opened = Date()

        func worked() -> TimeInterval { TimeInterval(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9 }
        var busiest: TimeInterval = 0
        var longest: TimeInterval = 0
        var turns = 0
        var last = (clock: Date(), worked: worked())
        while store.scorings < 2000, Date().timeIntervalSince(opened) < 60 {
            await Task.yield()
            XCTAssertTrue(Thread.isMainThread)
            let now = (clock: Date(), worked: worked())
            longest = max(longest, now.clock.timeIntervalSince(last.clock))
            busiest = max(busiest, now.worked - last.worked)
            last = now
            turns += 1
        }
        print("StrengthTests: 2000 passwords scored in \(Int(Date().timeIntervalSince(opened) * 1000)) ms;",
              "the main thread turned \(turns) times, worked at most",
              "\(String(format: "%.2f", busiest * 1000)) ms in one turn",
              "and was longest away \(String(format: "%.2f", longest * 1000)) ms by the clock")
        XCTAssertEqual(store.scorings, 2000)
        XCTAssertGreaterThan(turns, 100, "the scoring was over before the main thread was watched")
        XCTAssertLessThan(busiest, 1.0 / 120, "half a frame at 60 Hz")
        XCTAssertEqual(store.shelves.all.filter { $0.strength == nil }.count, 0)
        XCTAssertEqual(Set(store.shelves.all.compactMap(\.strength)).count, 4)
    }

    // MARK: On the row

    private func hosted(_ panes: Panes) -> NSWindow {
        let window = MainWindow.make()
        window.contentView = NSHostingView(rootView: PanesView(panes: panes))
        window.setContentSize(Metrics.windowSize)
        window.layoutIfNeeded()
        return window
    }

    func testThePasswordRowSaysTheLevelWhenItArrivesAndNoOtherRowDoes() async throws {
        let items = [login(1, "Old forum", password: "password"), login(2, "Bank", password: random),
                     login(3, "No password", password: nil)]
        let store = await unlocked(backend(items))
        let panes = Panes(store: store)
        let window = hosted(panes)
        await store.scoring?.value

        var heard: [String] = []
        for id in ["strength-1", "strength-2", "strength-3"] {
            panes.select(item: id)
            try await Task.sleep(nanoseconds: 50_000_000)
            let words = said(in: window.contentView)
            heard.append(Strength.allCases.map(\.word).filter(words.contains).joined(separator: " "))
            XCTAssertEqual(words.filter { $0 == "strength" }.count, id == "strength-3" ? 0 : 1, id)
            XCTAssertEqual(words.contains(ItemDetail.concealed), id != "strength-3")
        }
        XCTAssertEqual(heard, ["Guessable", "Strong", ""])
        XCTAssertEqual(panes.strength, nil)
        panes.select(item: "strength-1")
        XCTAssertEqual(panes.strength, .guessable)
    }
}
