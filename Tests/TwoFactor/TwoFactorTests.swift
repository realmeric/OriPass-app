import os
import XCTest
@testable import OriPass

/// Answers with the slice recorded on 2026-10-09 from `v4/totp.json`, and
/// counts what it was asked. Nothing here reaches a network.
private final class RecordedList: TwoFactorSource, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (asked: 0, ended: 0))
    private let recorded = Fixture.data("2fa-totp-slice")
    var fails = false

    var asked: Int { state.withLock { $0.asked } }
    var ended: Int { state.withLock { $0.ended } }

    func fetch() async -> Data? {
        state.withLock { $0.asked += 1 }
        return fails ? nil : recorded
    }

    func end() {
        state.withLock { $0.ended += 1 }
    }
}

/// Never answers until the task asking is cancelled.
private struct Silent: TwoFactorSource {
    let started: @Sendable () -> Void

    func fetch() async -> Data? {
        started()
        try? await Task.sleep(nanoseconds: 60_000_000_000)
        return nil
    }
}

/// Answers with the recorded slice once it is let go, and with nothing if
/// the task asking is cancelled first, as a request over a network would.
private final class Held: TwoFactorSource, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (asked: 0, open: false))
    private let recorded = Fixture.data("2fa-totp-slice")
    let started: @Sendable () -> Void

    init(started: @escaping @Sendable () -> Void) {
        self.started = started
    }

    var asked: Int { state.withLock { $0.asked } }

    func letGo() {
        state.withLock { $0.open = true }
    }

    func fetch() async -> Data? {
        state.withLock { $0.asked += 1 }
        started()
        while !state.withLock({ $0.open }) {
            do { try await Task.sleep(nanoseconds: 2_000_000) } catch { return nil }
        }
        return recorded
    }
}

@MainActor
final class TwoFactorTests: XCTestCase {
    private let slice = ["github.com", "paypal.com", "zoom.us", "zoho.com", "amazon.co.uk",
                         "visualstudio.microsoft.com", "wiggle.co.uk", "digitalocean.com", "notion.so",
                         "cloudflare.com", "slack.com", "figma.com", "yahoo.com", "xbox.com"]

    private func login(_ n: Int, _ name: String, _ addresses: [String], totp: String? = nil) -> JSONValue {
        .object([
            "object": .string("item"), "id": .string("two-\(n)"), "type": .int(1), "name": .string(name),
            "favorite": .bool(false), "reprompt": .int(0), "notes": .null, "fields": .array([]),
            "creationDate": .string("2025-01-05T09:30:00.000Z"), "revisionDate": .string("2025-03-12T16:41:03.000Z"),
            "deletedDate": .null, "archivedDate": .null,
            "login": .object(["username": .string("deniz"), "password": .string("v\(n)#Kq2mT!x7RbW4pZs8L"),
                              "totp": JSONValue(totp),
                              "uris": .array(addresses.map { .object(["uri": .string($0), "match": .null]) })]),
        ])
    }

    /// Cloudflare and Slack's sign-in at sub-domains of listed sites, with no
    /// code; Notion with one; a site that is not listed; a login with no
    /// address; and a login at a listed site with a blank code.
    private var six: [JSONValue] {
        [login(1, "Cloudflare", ["https://dash.cloudflare.com/login"]),
         login(2, "Slack", ["http://slack.com/signin"]),
         login(3, "Notion", ["https://www.notion.so"], totp: "JBSWY3DPEHPK3PXP"),
         login(4, "Yerel", ["https://intranet.example.org"]),
         login(5, "Adressiz", []),
         login(6, "Figma", ["https://www.figma.com/login"], totp: "  ")]
    }

    private func clock(_ start: Date = Date()) -> (now: @Sendable () -> Date, move: (TimeInterval) -> Void) {
        let moment = OSAllocatedUnfairLock(initialState: start)
        return ({ moment.withLock { $0 } }, { seconds in moment.withLock { $0 = $0.addingTimeInterval(seconds) } })
    }

    private func store(_ items: [JSONValue], source: TwoFactorSource, cache: TwoFactorCache? = nil,
                       now: @escaping @Sendable () -> Date = Date.init,
                       isOn: @escaping @Sendable () -> Bool = { true }) -> VaultStore {
        let backend = FakeBackend(items: items, folders: [], password: DemoVault.password)
        // Synced a minute ago, so no sync is running behind the count.
        backend.lastSync = Date().addingTimeInterval(-60)
        return VaultStore(backend: backend, twoFactor: TwoFactorCheck(source: source, cache: cache, now: now, isOn: isOn))
    }

    private func open(_ store: VaultStore) async {
        await store.unlock(password: SecretBytes(DemoVault.password))
        await store.counting?.value
    }

    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("op54-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: The list

    func testTheRecordedSliceIsTheSitesThatOfferACodeAndNothingElse() throws {
        let list = try XCTUnwrap(TwoFactorList(Fixture.data("2fa-totp-slice")))
        XCTAssertEqual(list.domains, Set(slice))

        // A site with no method, one with only a text message, and one
        // whose key is not a name are not on it.
        let body = #"{"a.example":{},"b.example":{"methods":["sms"]},"c.example":{"methods":["totp"]},"../d":{"methods":["totp"]},"E.Example":{"methods":["email","totp"]}}"#
        XCTAssertEqual(TwoFactorList(Data(body.utf8))?.domains, ["c.example", "e.example"])
    }

    func testAnythingButTheListIsNotTheList() {
        for body in ["", "<html>sign in to the wifi</html>", "[]", "{}", #"{"a.example":{}}"#, #"{"a.example":"totp"}"#] {
            XCTAssertNil(TwoFactorList(Data(body.utf8)), body)
        }
    }

    func testAHostIsOfferedByAListedDomainOrByOneAboveItAndByNoOtherName() throws {
        let list = try XCTUnwrap(TwoFactorList(Fixture.data("2fa-totp-slice")))
        for host in ["github.com", "GitHub.com", "gist.github.com", "a.b.c.github.com", "accounts.visualstudio.microsoft.com",
                     "www.wiggle.co.uk"] {
            XCTAssertTrue(list.offers(host: host), host)
        }
        // Another name that ends in the same letters, the parent of a
        // listed sub-domain, a bare top level and a suffix.
        for host in ["notgithub.com", "github.com.example.org", "microsoft.com", "uk", "co.uk", "com", "", "."] {
            XCTAssertFalse(list.offers(host: host), host)
        }
    }

    func testALoginWantsACodeWhenOneOfItsAddressesIsListedAndItHasNone() throws {
        let list = try XCTUnwrap(TwoFactorList(Fixture.data("2fa-totp-slice")))
        func wants(_ json: JSONValue) throws -> Bool { list.wants(try Item(json: json)) }
        XCTAssertTrue(try wants(login(1, "A", ["https://www.zoom.us/signin"])))
        XCTAssertTrue(try wants(login(2, "B", ["https://intranet.example.org", "androidapp://com.zoho.mail", "zoho.com/login"])))
        XCTAssertTrue(try wants(login(3, "C", ["https://xbox.com"], totp: "")))
        XCTAssertTrue(try wants(login(4, "D", ["https://xbox.com"], totp: " \n")))
        XCTAssertFalse(try wants(login(5, "E", ["https://xbox.com"], totp: "otpauth://totp/x?secret=ABC")))
        XCTAssertFalse(try wants(login(6, "F", ["https://intranet.example.org"])))
        XCTAssertFalse(try wants(login(7, "G", [])))
        XCTAssertFalse(try wants(login(8, "H", ["androidapp://com.zoho.mail", "10.0.0.1", "zoho"])))
        let note = JSONValue.object(["object": .string("item"), "id": .string("n"), "type": .int(2),
                                     "name": .string("Not"), "notes": .string("github.com")])
        XCTAssertFalse(try wants(note))
    }

    // MARK: The request

    private func directoryOverStub() -> TwoFactorDirectory {
        StubProtocol.seen = []
        // A redirect that is refused is a response the stub never finishes,
        // so a short patience is what ends it.
        return TwoFactorDirectory(patience: 1) {
            let configuration = TwoFactorDirectory.configuration
            configuration.protocolClasses = [StubProtocol.self]
            return URLSession(configuration: configuration)
        }
    }

    func testTheRequestIsOneGetOfTheFileAndCarriesNothingOfHis() async throws {
        let body = Fixture.data("2fa-totp-slice")
        StubProtocol.answer = { _ in (200, body) }
        let source = directoryOverStub()
        let answer = await source.fetch()
        XCTAssertEqual(answer, body)

        XCTAssertEqual(StubProtocol.seen.count, 1)
        let request = try XCTUnwrap(StubProtocol.seen.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.2fa.directory/v4/totp.json")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.url?.query)
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.httpBodyStream)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(TwoFactorDirectory.configuration.httpCookieStorage)
        XCTAssertNil(TwoFactorDirectory.configuration.urlCache)
        source.end()
    }

    func testAnythingButA200IsNoAnswerAndARedirectIsNotFollowed() async {
        let source = directoryOverStub()
        for status in [301, 302, 403, 429, 500, 503] {
            StubProtocol.seen = []
            StubProtocol.answer = { request in
                request.url?.host == TwoFactorDirectory.host ? (status, Data("{}".utf8)) : (200, Data())
            }
            let answer = await source.fetch()
            XCTAssertNil(answer, "\(status)")
            XCTAssertEqual(StubProtocol.seen.compactMap(\.url?.host), [TwoFactorDirectory.host], "\(status)")
        }
        StubProtocol.answer = { _ in nil }
        let none = await source.fetch()
        XCTAssertNil(none)
        source.end()
    }

    func testTheSessionEndsAtTheLockAndTheNextUnlockHasItsOwn() async {
        StubProtocol.answer = { _ in (200, Data("{}".utf8)) }
        StubProtocol.seen = []
        let made = OSAllocatedUnfairLock(initialState: 0)
        let source = TwoFactorDirectory {
            made.withLock { $0 += 1 }
            let configuration = TwoFactorDirectory.configuration
            configuration.protocolClasses = [StubProtocol.self]
            return URLSession(configuration: configuration)
        }
        _ = await source.fetch()
        _ = await source.fetch()
        XCTAssertEqual(made.withLock { $0 }, 1)
        source.end()
        source.end()
        let again = await source.fetch()
        XCTAssertNotNil(again)
        XCTAssertEqual(made.withLock { $0 }, 2)
        source.end()
    }

    // MARK: The switch

    func testWithTheSwitchOffNobodyIsAskedAndTheCardIsNotDrawn() async throws {
        let source = RecordedList()
        let isOn = OSAllocatedUnfairLock(initialState: false)
        let store = store(six, source: source) { isOn.withLock { $0 } }
        await open(store)
        store.recount()
        await store.counting?.value

        XCTAssertEqual(source.asked, 0)
        let watch = try XCTUnwrap(store.watch)
        XCTAssertNil(watch.twoFactor)
        XCTAssertEqual(store.cards, WatchCard.counted)
        XCTAssertEqual(Dashboard(watch, cards: store.cards).cards.map(\.kind), WatchCard.counted)

        // Switched on, the next count asks, and off again takes the card and
        // its banners at once.
        isOn.withLock { $0 = true }
        XCTAssertEqual(store.cards, WatchCard.allCases.filter { $0 != .vulnerable })
        store.recount()
        await store.counting?.value
        XCTAssertEqual(source.asked, 1)
        XCTAssertEqual(store.watch?.twoFactor?.map(\.item.name), ["Cloudflare", "Slack", "Figma"])
        isOn.withLock { $0 = false }
        XCTAssertEqual(store.cards, WatchCard.counted)
        let panes = Panes(store: store)
        panes.select(item: "two-1")
        XCTAssertEqual(panes.banners.map(\.card), [])
    }

    func testTheSwitchSaysWhatLeavesTheMacAndCreditsTheListAndIsOffUntilItIsSet() {
        XCTAssertTrue(TwoFactorCheck.sentence.contains(TwoFactorDirectory.host))
        XCTAssertTrue(TwoFactorCheck.sentence.contains("once a week"))
        XCTAssertTrue(TwoFactorCheck.sentence.contains("Nothing of your vault is sent"))
        XCTAssertTrue(TwoFactorCheck.sentence.contains("Data sourced from 2FA Directory by 2factorauth"))
        XCTAssertFalse(Settings().privacy.twoFactorCheck)
    }

    // MARK: Through the store

    func testALoginAtAListedSiteWithNoCodeIsOnTheCardAndToldToItsItem() async throws {
        let source = RecordedList()
        let store = store(six, source: source)
        await open(store)
        let watch = try XCTUnwrap(store.watch)
        // Notion has a code, Figma's is blank and so has none, and the
        // login with no address and the one at an unlisted site are left out.
        XCTAssertEqual(watch.twoFactor?.map(\.item.name), ["Cloudflare", "Slack", "Figma"])
        XCTAssertEqual(watch.entries(of: .twoFactor).map(\.id), ["two-1", "two-2", "two-6"])
        XCTAssertEqual(Dashboard(watch, cards: store.cards).cards.first { $0.kind == .twoFactor },
                       Dashboard.Card(kind: .twoFactor, count: 3))
        XCTAssertFalse("\(watch)".contains("JBSWY3"))

        let panes = Panes(store: store)
        panes.select(item: "two-1")
        XCTAssertEqual(panes.banners, [Banner(card: .twoFactor, sentence: Banner.twoFactor, act: .edit)])
        // Slack is also in the clear, which is told first.
        panes.select(item: "two-2")
        XCTAssertEqual(panes.banners.map(\.card), [.unsecured, .twoFactor])
        panes.select(item: "two-3")
        XCTAssertEqual(panes.banners, [])
        panes.select(.passwordHealth)
        panes.show(.twoFactor)
        XCTAssertEqual(panes.list.entries.map(\.item.name), ["Cloudflare", "Figma", "Slack"])
    }

    func testTheListIsFetchedOnceForAnUnlockAndNotAgainAfterASyncOrACount() async throws {
        let source = RecordedList()
        let store = store(six, source: source)
        await open(store)
        let counted = store.countings
        await store.sync()
        await store.counting?.value
        store.recount()
        await store.counting?.value
        XCTAssertEqual(source.asked, 1)
        XCTAssertGreaterThan(store.countings, counted)
        XCTAssertEqual(store.watch?.twoFactor?.count, 3)
        let requests = await store.twoFactor?.requests
        XCTAssertEqual(requests, 1)
    }

    func testTheCardHasNoNumberUntilTheListIsInAndTheOtherFourAreNotHeldBackForIt() async throws {
        let source = RecordedList()
        source.fails = true
        let store = store(six, source: source)
        await open(store)
        let watch = try XCTUnwrap(store.watch)
        XCTAssertNil(watch.twoFactor)
        XCTAssertEqual(watch.unsecured.count, 1)
        XCTAssertEqual(Dashboard(watch, cards: store.cards).cards.first { $0.kind == .twoFactor },
                       Dashboard.Card(kind: .twoFactor, count: nil))
        let panes = Panes(store: store)
        panes.select(item: "two-1")
        XCTAssertEqual(panes.banners, [])
    }

    func testTwoCardsThatAreAskedForNeedAPlaceInTheOrderAndTheSentencesAreTheirOwn() {
        XCTAssertTrue(WatchCard.vulnerable.isAnswered)
        XCTAssertTrue(WatchCard.twoFactor.isAnswered)
        XCTAssertEqual(WatchCard.allCases.filter(\.isAnswered).count, 2)
        XCTAssertEqual(WatchCard.twoFactor.title, "Inactive two-factor authentication")
        XCTAssertEqual(WatchCard.allCases.map(\.title).count, 6)
        // The still's order: this card sits between Unsecured and Expiring.
        let order = WatchCard.allCases
        XCTAssertEqual(order.firstIndex(of: .twoFactor), order.firstIndex(of: .unsecured)! + 1)
        XCTAssertEqual(order.firstIndex(of: .expiring), order.firstIndex(of: .twoFactor)! + 1)
    }

    // MARK: The file under Caches

    func testAFileUnderAWeekOldIsReadAndNobodyIsAsked() async throws {
        let cache = TwoFactorCache(directory: directory())
        let (now, move) = clock()
        cache.write(Fixture.data("2fa-totp-slice"), at: now())
        move(6 * 24 * 60 * 60)
        let source = RecordedList()
        let check = TwoFactorCheck(source: source, cache: cache, now: now) { true }
        let list = await check.load()
        XCTAssertEqual(list?.domains, Set(slice))
        XCTAssertEqual(source.asked, 0)
    }

    func testAnOlderFileIsAskedAboutAgainAndWrittenOverAndNothingIsWrittenForAFailure() async throws {
        let cache = TwoFactorCache(directory: directory())
        let (now, move) = clock()
        let old = Data(#"{"old.example":{"methods":["totp"]}}"#.utf8)
        cache.write(old, at: now())
        move(8 * 24 * 60 * 60)

        // The server does not answer: the old file is used, and left as it is.
        let source = RecordedList()
        source.fails = true
        let failing = TwoFactorCheck(source: source, cache: cache, now: now) { true }
        let stale = await failing.load()
        XCTAssertEqual(stale?.domains, ["old.example"])
        XCTAssertEqual(source.asked, 1)
        XCTAssertEqual(cache.read()?.data, old)

        // It does: the new one is held, and is the file.
        source.fails = false
        let check = TwoFactorCheck(source: source, cache: cache, now: now) { true }
        let list = await check.load()
        XCTAssertEqual(list?.domains, Set(slice))
        XCTAssertEqual(cache.read()?.data, Fixture.data("2fa-totp-slice"))
        XCTAssertEqual(cache.read()?.written, now())
        let mode = try FileManager.default.attributesOfItem(atPath: cache.directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)

        // An answer that is not the list is not written.
        let other = TwoFactorCache(directory: directory())
        struct Portal: TwoFactorSource {
            func fetch() async -> Data? { Data("<html>sign in</html>".utf8) }
        }
        let none = await TwoFactorCheck(source: Portal(), cache: other, now: now) { true }.load()
        XCTAssertNil(none)
        XCTAssertNil(other.read())
    }

    func testAFailureIsRememberedForAMinuteSoAMacWithNoNetworkAsksOnceAMinute() async {
        let source = RecordedList()
        source.fails = true
        let (now, move) = clock()
        let check = TwoFactorCheck(source: source, now: now) { true }
        for _ in 1...3 {
            let list = await check.load()
            XCTAssertNil(list)
        }
        XCTAssertEqual(source.asked, 1)
        move(TwoFactorCheck.pause + 1)
        source.fails = false
        let list = await check.load()
        XCTAssertNotNil(list)
        XCTAssertEqual(source.asked, 2)
    }

    func testACountThatGivesWayToAnotherLeavesTheRequestForTheOneThatFollows() async throws {
        let started = expectation(description: "a request was made")
        started.assertForOverFulfill = false
        let source = Held { started.fulfill() }
        let store = store(six, source: source)
        await store.unlock(password: SecretBytes(DemoVault.password))
        await fulfillment(of: [started], timeout: 5)
        let first = try XCTUnwrap(store.counting)

        // Something moves while the list is on its way: the count before is
        // cancelled, and stops waiting without the request being answered.
        store.recount()
        await first.value
        XCTAssertNil(store.watch?.twoFactor)
        XCTAssertEqual(source.asked, 1)

        source.letGo()
        await store.counting?.value
        XCTAssertEqual(source.asked, 1)
        XCTAssertEqual(store.watch?.twoFactor?.count, 3)
        let requests = await store.twoFactor?.requests
        XCTAssertEqual(requests, 1)
    }

    func testAnAskerWhoIsCancelledHasNotFailedAndAnOldFileDoesNotStandInForTheAnswer() async throws {
        let cache = TwoFactorCache(directory: directory())
        let (now, move) = clock()
        cache.write(Data(#"{"old.example":{"methods":["totp"]}}"#.utf8), at: now())
        move(8 * 24 * 60 * 60)
        let started = expectation(description: "a request was made")
        started.assertForOverFulfill = false
        let source = Held { started.fulfill() }
        let check = TwoFactorCheck(source: source, cache: cache, now: now) { true }

        let first = Task { await check.load() }
        await fulfillment(of: [started], timeout: 5)
        first.cancel()
        let nothing = await first.value
        XCTAssertNil(nothing)
        let held = await check.held
        XCTAssertNil(held)

        // The one who asks next is waiting for the same request, not for a
        // minute to pass, and gets the server's list and not the old file.
        let second = Task { await check.load() }
        source.letGo()
        let list = await second.value
        XCTAssertEqual(list?.domains, Set(slice))
        XCTAssertEqual(source.asked, 1)
        XCTAssertEqual(cache.read()?.data, Fixture.data("2fa-totp-slice"))
    }

    func testTheFileIsThePublicListAsItCameAndHoldsNoLogin() async throws {
        let cache = TwoFactorCache(directory: directory())
        let source = RecordedList()
        let store = store(six, source: source, cache: cache)
        await open(store)
        let written = try XCTUnwrap(cache.read()?.data)
        let text = String(decoding: written, as: UTF8.self)
        XCTAssertEqual(written, Fixture.data("2fa-totp-slice"))
        for private_ in ["deniz", "Cloudflare", "Yerel", "intranet.example.org", "JBSWY3"] {
            XCTAssertFalse(text.contains(private_), private_)
        }
    }

    // MARK: The lock

    func testTheLockDropsTheListAndShutsTheSourceAndTheNextUnlockAsksAgain() async throws {
        let source = RecordedList()
        let store = store(six, source: source)
        await open(store)
        var held = await store.twoFactor?.held
        XCTAssertNotNil(held)
        XCTAssertEqual(source.ended, 0)
        await store.lock()
        XCTAssertNil(store.watch)
        XCTAssertEqual(source.ended, 1)
        held = await store.twoFactor?.held
        XCTAssertNil(held)

        await open(store)
        XCTAssertEqual(source.asked, 2)
        XCTAssertEqual(store.watch?.twoFactor?.count, 3)
    }

    func testALockWhileTheServerIsThinkingEndsTheAskingAndKeepsNothing() async throws {
        let started = expectation(description: "a request was made")
        started.assertForOverFulfill = false
        let store = store(six, source: Silent { started.fulfill() })
        await store.unlock(password: SecretBytes(DemoVault.password))
        await fulfillment(of: [started], timeout: 5)
        // The four lists are in and the fifth is still being waited for.
        XCTAssertEqual(store.watch?.unsecured.count, 1)
        XCTAssertNil(store.watch?.twoFactor)

        let began = Date()
        await store.lock()
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
        XCTAssertNil(store.watch)
        let held = await store.twoFactor?.held
        XCTAssertNil(held)
    }

    // MARK: The demo

    func testTheDemosListAsksNobodyAndLeavesGitHubWhoseLoginHasACode() async throws {
        let vault = DemoVault.objects()
        let backend = FakeBackend(items: vault.items, folders: vault.folders, password: DemoVault.password)
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend, breaches: DemoBreaches.checker(), twoFactor: DemoTwoFactor.checker())
        await open(store)
        let names = try XCTUnwrap(store.watch?.twoFactor).map(\.item.name)
        XCTAssertFalse(names.contains("GitHub"))
        XCTAssertTrue(names.contains("Google"))
        XCTAssertEqual(names.count, 9)
        XCTAssertEqual(Dashboard(store.watch, cards: store.cards).cards.map(\.count), [3, 2, 3, 1, 9, 1])
    }
}
