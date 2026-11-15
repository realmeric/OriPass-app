import os
import XCTest
@testable import OriPass

/// Answers from the range recorded on 2026-10-09 for `5BAA6`, the five that
/// "password" starts with, and with nothing but padding for any other five.
/// It counts what it was asked, and nothing here reaches a network.
private final class RecordedRange: BreachFetcher, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (asked: [String](), ended: 0))
    private let recorded = Fixture.bytes("pwned-range-5BAA6", "txt")
    var fails = false

    var asked: [String] { state.withLock { $0.asked } }
    var ended: Int { state.withLock { $0.ended } }

    func fetch(prefix: String) async -> BreachAnswer {
        state.withLock { $0.asked.append(prefix) }
        if fails { return .failed }
        return .body(prefix == "5BAA6" ? recorded : Data("7975BAB577D7C839EC2E3E1BDD1E9EA3602:0".utf8))
    }

    func end() {
        state.withLock { $0.ended += 1 }
    }
}

/// Never answers until the task asking is cancelled.
private struct Silent: BreachFetcher {
    let started: @Sendable () -> Void

    func fetch(prefix: String) async -> BreachAnswer {
        started()
        try? await Task.sleep(nanoseconds: 60_000_000_000)
        return .failed
    }
}

@MainActor
final class BreachTests: XCTestCase {
    /// Twenty characters nobody chose, and so in no range that was recorded.
    private let random = "v9#Kq2mT!x7RbW4pZs8L"
    private let passwordSuffix = "1E4C9B93F3F0682250B6CF8331B7EE68FD8"

    private func login(_ n: Int, _ name: String, password: String?) -> JSONValue {
        .object([
            "object": .string("item"), "id": .string("breach-\(n)"), "type": .int(1), "name": .string(name),
            "favorite": .bool(false), "reprompt": .int(0), "notes": .null, "fields": .array([]),
            "creationDate": .string("2025-01-05T09:30:00.000Z"), "revisionDate": .string("2025-03-12T16:41:03.000Z"),
            "deletedDate": .null, "archivedDate": .null,
            "login": .object(["username": .string("deniz"), "password": JSONValue(password), "totp": .null,
                              "uris": .array([])]),
        ])
    }

    /// Two logins on "password", one on a password nobody has seen, and one
    /// with none.
    private var four: [JSONValue] {
        [login(1, "Bir", password: "password"), login(2, "İki", password: random),
         login(3, "Üç", password: "password"), login(4, "Dört", password: nil)]
    }

    private func store(_ items: [JSONValue], fetcher: BreachFetcher, gap: TimeInterval = 0,
                       isOn: @escaping @Sendable () -> Bool = { true }) -> VaultStore {
        let backend = FakeBackend(items: items, folders: [], password: DemoVault.password)
        // Synced a minute ago, so no sync is running behind the count.
        backend.lastSync = Date().addingTimeInterval(-60)
        return VaultStore(backend: backend, breaches: Breaches(fetcher: fetcher, gap: gap, isOn: isOn))
    }

    private func open(_ store: VaultStore) async {
        await store.unlock(password: SecretBytes(DemoVault.password))
        await store.counting?.value
    }

    // MARK: The hash and the range

    func testAPasswordIsItsSha1CutAfterTheFifthCharacterAndSaysNeitherHalf() {
        let mark = BreachMark("password")
        XCTAssertEqual(mark.prefix, "5BAA6")
        XCTAssertEqual(mark.suffix, passwordSuffix)
        XCTAssertEqual("\(mark)", "BreachMark")
        XCTAssertEqual(String(reflecting: mark), "BreachMark")
        XCTAssertEqual(BreachMark("şifre").prefix.count, BreachMark.prefixLength)
        XCTAssertEqual(BreachMark("şifre").suffix.count, BreachRange.suffixLength)
    }

    func testTheRecordedRangeHoldsAHitAndNotAMissAndNotAPaddedLine() {
        let body = Fixture.bytes("pwned-range-5BAA6", "txt")
        let lines = String(decoding: body, as: UTF8.self).components(separatedBy: "\r\n")
        XCTAssertEqual(lines.count, 19)
        let padded = lines.filter { $0.hasSuffix(":0") }.map { String($0.dropLast(2)) }
        XCTAssertEqual(padded.count, 8)

        let range = BreachRange(body)
        XCTAssertTrue(range.holds(BreachMark("password")))
        XCTAssertFalse(range.holds(BreachMark(random)))
        XCTAssertEqual(range.suffixes.count, 11)
        for suffix in padded {
            XCTAssertEqual(suffix.count, BreachRange.suffixLength)
            XCTAssertFalse(range.suffixes.contains(suffix), "a padded line was taken for a sighting")
        }
        // The same lines with a Unix ending and in small letters, and
        // lines that are not the server's.
        XCTAssertEqual(BreachRange(Data(lines.joined(separator: "\n").lowercased().utf8)), range)
        XCTAssertTrue(BreachRange(Data("<html>\r\n\(passwordSuffix)\r\n\(passwordSuffix):many\r\nABC:4".utf8)).suffixes.isEmpty)
    }

    // MARK: The request

    private func pwned() -> PwnedRange {
        StubProtocol.seen = []
        return PwnedRange {
            let configuration = PwnedRange.configuration
            configuration.protocolClasses = [StubProtocol.self]
            return URLSession(configuration: configuration)
        }
    }

    func testTheRequestsPathEndsInFiveCharactersAndItAsksForPadding() async throws {
        let body = Fixture.bytes("pwned-range-5BAA6", "txt")
        StubProtocol.answer = { _ in (200, body) }
        let fetcher = pwned()
        let answer = await fetcher.fetch(prefix: BreachMark("password").prefix)
        XCTAssertEqual(answer, .body(body))

        XCTAssertEqual(StubProtocol.seen.count, 1)
        let request = try XCTUnwrap(StubProtocol.seen.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.pwnedpasswords.com/range/5BAA6")
        XCTAssertEqual(request.url?.lastPathComponent.count, 5)
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.httpBodyStream)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Add-Padding"), "true")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(PwnedRange.configuration.httpCookieStorage)
        XCTAssertNil(PwnedRange.configuration.urlCache)
        fetcher.end()
    }

    func testNothingButFiveHexCharactersIsEverSent() async {
        StubProtocol.answer = { _ in (200, Data()) }
        let fetcher = pwned()
        let whole = BreachMark("password")
        for path in [whole.prefix + whole.suffix, String(whole.prefix.dropLast()), "5baa6", "5BAA6/", "password", ""] {
            let answer = await fetcher.fetch(prefix: path)
            XCTAssertEqual(answer, .failed, path)
        }
        XCTAssertTrue(StubProtocol.seen.isEmpty)
    }

    func testAnythingButA200IsNoAnswerAndARedirectIsNotFollowed() async {
        let fetcher = pwned()
        for status in [301, 302, 400, 403, 429, 500, 503] {
            StubProtocol.seen = []
            StubProtocol.answer = { request in
                request.url?.host == PwnedRange.host ? (status, Data("\(self.passwordSuffix):9".utf8)) : (200, Data())
            }
            let answer = await fetcher.fetch(prefix: "5BAA6")
            XCTAssertEqual(answer, .failed, "\(status)")
            XCTAssertEqual(StubProtocol.seen.compactMap(\.url?.host), [PwnedRange.host], "\(status)")
        }
        fetcher.end()
    }

    func testTheSessionEndsAtTheLockAndTheNextUnlockHasItsOwn() async {
        StubProtocol.answer = { _ in (200, Data("\(self.passwordSuffix):9".utf8)) }
        StubProtocol.seen = []
        let made = OSAllocatedUnfairLock(initialState: [URLSession]())
        let fetcher = PwnedRange {
            let configuration = PwnedRange.configuration
            configuration.protocolClasses = [StubProtocol.self]
            let session = URLSession(configuration: configuration)
            made.withLock { $0.append(session) }
            return session
        }
        _ = await fetcher.fetch(prefix: "5BAA6")
        _ = await fetcher.fetch(prefix: "5BAA7")
        XCTAssertEqual(made.withLock { $0.count }, 1)
        fetcher.end()
        fetcher.end()
        let again = await fetcher.fetch(prefix: "5BAA6")
        XCTAssertEqual(again, .body(Data("\(passwordSuffix):9".utf8)))
        XCTAssertEqual(made.withLock { $0.count }, 2)
        fetcher.end()
    }

    // MARK: The switch

    func testWithTheSwitchOffTheFetcherIsNeverCalled() async throws {
        let fetcher = RecordedRange()
        let isOn = OSAllocatedUnfairLock(initialState: false)
        let store = store(four, fetcher: fetcher) { isOn.withLock { $0 } }
        await open(store)
        store.recount()
        await store.counting?.value
        await store.sync()
        await store.counting?.value

        XCTAssertEqual(fetcher.asked.count, 0)
        let requests = await store.breaches?.requests
        XCTAssertEqual(requests, 0)
        let held = await store.breaches?.held
        XCTAssertEqual(held, 0)
        let watch = try XCTUnwrap(store.watch)
        XCTAssertNil(watch.vulnerable)
        XCTAssertEqual(watch.reused.count, 2)
        XCTAssertEqual(store.cards, WatchCard.counted)
        XCTAssertEqual(Dashboard(watch, cards: store.cards).cards.map(\.kind), WatchCard.counted)

        // Switched on, the next count asks.
        isOn.withLock { $0 = true }
        store.recount()
        await store.counting?.value
        XCTAssertEqual(fetcher.asked.count, 2)
        XCTAssertEqual(store.watch?.vulnerable?.map(\.item.name), ["Bir", "Üç"])
        XCTAssertEqual(store.cards, WatchCard.allCases.filter { $0 != .twoFactor })

        // And off again, the card and the banner go at once, and nobody is
        // asked about a password that is new.
        isOn.withLock { $0 = false }
        XCTAssertEqual(store.cards, WatchCard.counted)
        let panes = Panes(store: store)
        panes.select(item: "breach-1")
        XCTAssertEqual(panes.banners.map(\.card), [.reused, .weak])
        store.recount()
        await store.counting?.value
        XCTAssertNil(store.watch?.vulnerable)
        XCTAssertEqual(fetcher.asked.count, 2)
    }

    func testTheSwitchSaysWhatLeavesTheMacAndIsOffUntilItIsSet() {
        XCTAssertTrue(Breaches.sentence.contains("first five characters of a hash"))
        XCTAssertTrue(Breaches.sentence.contains(PwnedRange.host))
        XCTAssertTrue(Breaches.sentence.contains("Have I Been Pwned"))
        XCTAssertFalse(Settings().privacy.breachCheck)
    }

    // MARK: Through the store

    func testAHitIsOnTheCardAndToldToItsItemAndAMissIsNot() async throws {
        let fetcher = RecordedRange()
        let store = store(four, fetcher: fetcher)
        await open(store)
        let watch = try XCTUnwrap(store.watch)
        XCTAssertEqual(watch.vulnerable?.map(\.item.name), ["Bir", "Üç"])
        XCTAssertEqual(watch.entries(of: .vulnerable).map(\.id), ["breach-1", "breach-3"])
        XCTAssertFalse("\(watch)".contains("password"))

        let page = Dashboard(watch, cards: store.cards)
        XCTAssertEqual(page.cards.map(\.kind), WatchCard.allCases.filter { $0 != .twoFactor })
        XCTAssertEqual(page.cards.first, Dashboard.Card(kind: .vulnerable, count: 2))

        let panes = Panes(store: store)
        panes.select(item: "breach-1")
        XCTAssertEqual(panes.banners.first, Banner(card: .vulnerable, sentence: Banner.vulnerable, act: .edit))
        XCTAssertEqual(panes.banners.map(\.card), [.vulnerable, .reused, .weak])
        panes.select(item: "breach-2")
        XCTAssertEqual(panes.banners, [])
        panes.select(.passwordHealth)
        panes.show(.vulnerable)
        XCTAssertEqual(panes.list.entries.map(\.item.name), ["Bir", "Üç"])
    }

    func testEachFiveCharactersAreAskedAboutOnceAndNotAgainWhileTheVaultIsOpen() async throws {
        let fetcher = RecordedRange()
        let store = store(four, fetcher: fetcher)
        await open(store)
        // Two logins share a password: one request for the two, and one
        // for the other password. The login with none is not asked about.
        XCTAssertEqual(fetcher.asked.sorted(), [BreachMark("password").prefix, BreachMark(random).prefix].sorted())
        XCTAssertTrue(fetcher.asked.allSatisfy { $0.count == 5 })
        let held = await store.breaches?.held
        XCTAssertEqual(held, 2)

        let counted = store.countings
        await store.sync()
        await store.counting?.value
        store.recount()
        await store.counting?.value
        XCTAssertEqual(fetcher.asked.count, 2)
        XCTAssertGreaterThan(store.countings, counted)
        XCTAssertEqual(store.watch?.vulnerable?.count, 2)
    }

    func testRequestsAreSpacedOut() async {
        let fetcher = RecordedRange()
        let items = (1...4).map { login($0, "Giriş \($0)", password: "\(random)\($0)") }
        let store = store(items, fetcher: fetcher, gap: 0.05)
        let began = Date()
        await open(store)
        XCTAssertEqual(fetcher.asked.count, 4)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(began), 0.15)
        XCTAssertEqual(Breaches.gap, 0.25)
    }

    func testAnAnswerThatDoesNotComeLeavesTheCardWithoutANumberAndIsAskedForAgain() async throws {
        let fetcher = RecordedRange()
        fetcher.fails = true
        let store = store(four, fetcher: fetcher)
        await open(store)
        // The first failure ends the pass: the other five were not sent.
        XCTAssertEqual(fetcher.asked.count, 1)
        let watch = try XCTUnwrap(store.watch)
        XCTAssertNil(watch.vulnerable)
        XCTAssertEqual(watch.reused.count, 2)
        let card = Dashboard(watch, cards: store.cards).cards.first
        XCTAssertEqual(card, Dashboard.Card(kind: .vulnerable, count: nil))

        fetcher.fails = false
        store.recount()
        await store.counting?.value
        XCTAssertEqual(fetcher.asked.count, 3)
        XCTAssertEqual(store.watch?.vulnerable?.count, 2)
    }

    // MARK: The lock

    func testTheLockDropsEveryAnswerAndShutsTheFetcherAndTheNextUnlockAsksAgain() async throws {
        let fetcher = RecordedRange()
        let store = store(four, fetcher: fetcher)
        await open(store)
        XCTAssertEqual(fetcher.ended, 0)
        await store.lock()
        XCTAssertNil(store.watch)
        XCTAssertEqual(fetcher.ended, 1)
        let held = await store.breaches?.held
        XCTAssertEqual(held, 0)

        await open(store)
        XCTAssertEqual(fetcher.asked.count, 4)
        XCTAssertEqual(store.watch?.vulnerable?.count, 2)
    }

    func testALockWhileTheServerIsThinkingEndsTheAskingAndKeepsNothing() async throws {
        let started = expectation(description: "a request was made")
        started.assertForOverFulfill = false
        let store = store(four, fetcher: Silent { started.fulfill() })
        await store.unlock(password: SecretBytes(DemoVault.password))
        await fulfillment(of: [started], timeout: 5)
        // The four lists are in and the fifth is still being asked about.
        XCTAssertEqual(store.watch?.reused.count, 2)
        XCTAssertNil(store.watch?.vulnerable)

        let began = Date()
        await store.lock()
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
        XCTAssertNil(store.watch)
        let held = await store.breaches?.held
        XCTAssertEqual(held, 0)
    }

    // MARK: The demo

    func testTheDemosCheckAsksNobodyAndHasSeenItsThreeWeakPasswords() async throws {
        let vault = DemoVault.objects()
        let backend = FakeBackend(items: vault.items, folders: vault.folders, password: DemoVault.password)
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend, breaches: DemoBreaches.checker())
        await open(store)
        XCTAssertEqual(store.watch?.vulnerable?.map(\.item.name), ["Eski forum", "Çiçeksepeti", "Yemeksepeti"])
        let page = Dashboard(store.watch, cards: store.cards)
        XCTAssertEqual(page.cards.map(\.count), [3, 2, 3, 1, 1])
    }
}
