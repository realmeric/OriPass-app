import AppKit
import SwiftUI
import XCTest
@testable import OriPass

/// A fetcher that answers from a table and counts what it was asked. It
/// suspends once before answering so that forty callers overlap in it.
final class CountingFetcher: IconFetcher {
    private let lock = NSLock()
    private var asked: [String] = []
    var answer: (String) -> IconAnswer

    init(_ answer: @escaping (String) -> IconAnswer) {
        self.answer = answer
    }

    var hosts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return asked
    }

    func fetch(host: String) async -> IconAnswer {
        lock.lock()
        asked.append(host)
        lock.unlock()
        try? await Task.sleep(nanoseconds: 20_000_000)
        return answer(host)
    }
}

/// A fetcher that takes five seconds, or as long as it is left alone. It
/// hands a picture back even when it was cancelled, so it is the store that
/// has to keep nothing.
final class SlowFetcher: IconFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var counts = (asked: 0, cancelled: 0, ended: 0)

    var asked: Int { read(\.asked) }
    var cancelled: Int { read(\.cancelled) }
    var ended: Int { read(\.ended) }

    private func read(_ count: KeyPath<(asked: Int, cancelled: Int, ended: Int), Int>) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[keyPath: count]
    }

    private func add(_ count: WritableKeyPath<(asked: Int, cancelled: Int, ended: Int), Int>) {
        lock.lock()
        counts[keyPath: count] += 1
        lock.unlock()
    }

    func fetch(host: String) async -> IconAnswer {
        add(\.asked)
        do {
            try await Task.sleep(nanoseconds: 5_000_000_000)
        } catch {
            add(\.cancelled)
        }
        return .image(tinyPNG())
    }

    func end() { add(\.ended) }
}

/// A valid picture a few pixels across, one colour in sRGB.
func tinyPNG(_ shade: CGFloat = 0.4) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let bytes = rep.bitmapData!
    for pixel in 0..<16 {
        bytes[pixel * 4] = UInt8((shade * 255).rounded())
        bytes[pixel * 4 + 1] = 128
        bytes[pixel * 4 + 2] = 179
        bytes[pixel * 4 + 3] = 255
    }
    return rep.retagging(with: .sRGB)!.representation(using: .png, properties: [:])!
}

@MainActor
final class IconStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oripass-icons-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store(_ fetcher: IconFetcher?, isOn: @escaping () -> Bool = { true },
                       settle: TimeInterval = 0.01, now: @escaping () -> Date = Date.init) -> IconStore {
        IconStore(fetcher: fetcher, directory: directory, isOn: isOn, settle: settle, now: now)
    }

    private var files: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    // MARK: Which host

    func testTheHostIsTheFirstAddressesAndNothingElse() throws {
        XCTAssertEqual(SiteHost.of("https://www.isbank.com.tr/giris"), "www.isbank.com.tr")
        XCTAssertEqual(SiteHost.of("HTTP://GitHub.com:8443/login?x=1"), "github.com")
        XCTAssertEqual(SiteHost.of("example.com/login"), "example.com")
        XCTAssertEqual(SiteHost.of("https://example.com./"), "example.com")
        for none in ["", "   ", "androidapp://com.spotify.music", "iosapp://x.y", "https://localhost/",
                     "http://192.168.0.1/admin", "https://münchen.de", "https://-a.com", "https://a..com",
                     "javascript:alert(1)", "ftp://files.example.com"] {
            XCTAssertNil(SiteHost.of(none), none)
        }

        func login(_ uris: [String], type: Int = 1) throws -> Item {
            try Item(json: .object([
                "id": .string("x"), "type": .int(Int64(type)), "name": .string("x"),
                "login": .object(["uris": .array(uris.map { .object(["uri": .string($0), "match": .null]) })]),
            ]))
        }
        XCTAssertEqual(try login(["https://a.example.com", "https://b.example.com"]).iconHost, "a.example.com")
        // The first address is the one: a second that would do is not tried.
        XCTAssertNil(try login(["androidapp://com.x", "https://b.example.com"]).iconHost)
        XCTAssertNil(try login([]).iconHost)
        XCTAssertNil(try login(["https://a.example.com"], type: 2).iconHost)
    }

    func testAHostThatIsNotAFileNameIsNeverAsked() async {
        let fetcher = CountingFetcher { _ in .image(tinyPNG()) }
        let icons = store(fetcher)
        for host in ["../etc/passwd", "a/b.com", "a b.com", "A.COM", "..", "", "x"] {
            let image = await icons.image(for: host)
            XCTAssertNil(image, host)
        }
        XCTAssertEqual(fetcher.hosts, [])
        XCTAssertEqual(files, [])
    }

    // MARK: One request

    func testFortyRowsOfOneHostMakeOneRequest() async {
        let fetcher = CountingFetcher { _ in .image(tinyPNG()) }
        let icons = store(fetcher)
        let images = await withTaskGroup(of: NSImage?.self) { group in
            for _ in 0..<40 { group.addTask { await icons.image(for: "github.com") } }
            var all: [NSImage?] = []
            for await image in group { all.append(image) }
            return all
        }
        XCTAssertEqual(images.count, 40)
        XCTAssertTrue(images.allSatisfy { $0 != nil })
        XCTAssertEqual(fetcher.hosts, ["github.com"])

        // And forty more, a moment later, from memory.
        for _ in 0..<40 {
            let image = await icons.image(for: "github.com")
            XCTAssertNotNil(image)
        }
        XCTAssertNotNil(icons.cached("github.com"))
        XCTAssertEqual(fetcher.hosts.count, 1)
    }

    func testTwoHostsAreTwoRequestsAndEachIsItsOwn() async {
        let fetcher = CountingFetcher { $0 == "a.example.com" ? .image(tinyPNG()) : .none }
        let icons = store(fetcher)
        let one = await icons.image(for: "a.example.com")
        let other = await icons.image(for: "b.example.com")
        XCTAssertNotNil(one)
        XCTAssertNil(other)
        XCTAssertEqual(fetcher.hosts.sorted(), ["a.example.com", "b.example.com"])
    }

    // MARK: The second launch

    func testTheSecondLaunchAsksNobody() async {
        let first = CountingFetcher { _ in .image(tinyPNG()) }
        let one = await store(first).image(for: "linear.app")
        XCTAssertNotNil(one)
        XCTAssertEqual(first.hosts, ["linear.app"])
        XCTAssertEqual(files, ["linear.app.png"])

        // A new store has an empty memory and the same folder.
        let second = CountingFetcher { _ in .failed }
        let again = store(second)
        XCTAssertNil(again.cached("linear.app"))
        let image = await again.image(for: "linear.app")
        XCTAssertNotNil(image)
        XCTAssertEqual(second.hosts, [])
    }

    func testAMissIsRememberedForAWeekAndAskedAgainAfterIt() async {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let first = CountingFetcher { _ in .none }
        let one = await store(first, now: { clock }).image(for: "nothing.example.com")
        XCTAssertNil(one)
        XCTAssertEqual(files, ["nothing.example.com.miss"])

        clock.addTimeInterval(6 * 24 * 60 * 60)
        let second = CountingFetcher { _ in .none }
        let sixDays = await store(second, now: { clock }).image(for: "nothing.example.com")
        XCTAssertNil(sixDays)
        XCTAssertEqual(second.hosts, [])

        clock.addTimeInterval(2 * 24 * 60 * 60)
        let third = CountingFetcher { _ in .image(tinyPNG()) }
        let eightDays = await store(third, now: { clock }).image(for: "nothing.example.com")
        XCTAssertNotNil(eightDays)
        XCTAssertEqual(third.hosts, ["nothing.example.com"])
        XCTAssertEqual(files, ["nothing.example.com.png"])
    }

    func testAFailureIsNotWrittenDownAndIsTriedAgainAfterAMinute() async {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let fetcher = CountingFetcher { _ in .failed }
        let icons = store(fetcher, now: { clock })
        let first = await icons.image(for: "down.example.com")
        let soon = await icons.image(for: "down.example.com")
        XCTAssertNil(first)
        XCTAssertNil(soon)
        XCTAssertEqual(fetcher.hosts.count, 1)
        XCTAssertEqual(files, [])

        clock.addTimeInterval(IconStore.retryAfter + 1)
        fetcher.answer = { _ in .image(tinyPNG()) }
        let later = await icons.image(for: "down.example.com")
        XCTAssertNotNil(later)
        XCTAssertEqual(fetcher.hosts.count, 2)
    }

    func testBytesThatAreNotAPictureAreNotKept() async {
        let fetcher = CountingFetcher { _ in .image(Data("<html>nope</html>".utf8)) }
        let icons = store(fetcher)
        let image = await icons.image(for: "html.example.com")
        XCTAssertNil(image)
        XCTAssertEqual(files, [])
    }

    func testTheFolderIsOnlyForHim() async throws {
        _ = await store(CountingFetcher { _ in .image(tinyPNG()) }).image(for: "linear.app")
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? Int ?? 0) & 0o077, 0)
    }

    // MARK: The switch

    func testWithTheSwitchOffNothingIsAskedReadOrWritten() async {
        // An icon already on disk, which the switch must also keep off the screen.
        _ = await store(CountingFetcher { _ in .image(tinyPNG()) }).image(for: "linear.app")
        let before = files

        var isOn = false
        let fetcher = CountingFetcher { _ in .image(tinyPNG()) }
        let icons = store(fetcher, isOn: { isOn })
        let cached = await icons.image(for: "linear.app")
        let fresh = await icons.image(for: "github.com")
        XCTAssertNil(cached)
        XCTAssertNil(fresh)
        XCTAssertNil(icons.cached("linear.app"))
        XCTAssertEqual(fetcher.hosts, [])
        XCTAssertEqual(files, before)

        isOn = true
        let back = await icons.image(for: "github.com")
        XCTAssertNotNil(back)
        XCTAssertEqual(fetcher.hosts, ["github.com"])
    }

    func testTheSwitchIsOnUntilItIsSetOff() {
        XCTAssertTrue(Settings().privacy.siteIcons)
        XCTAssertNil(IconStore.off.cached("linear.app"))
    }

    // MARK: A lock

    func testALockCancelsTheRequestInFlightAndNothingIsWritten() async throws {
        let backend = DemoVault.backend()
        backend.lastSync = Date().addingTimeInterval(-60)
        let vault = VaultStore(backend: backend)
        let suite = "oripass-icons-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fetcher = SlowFetcher()
        let directory = try XCTUnwrap(self.directory)
        let door = Door(store: vault, defaults: defaults,
                        icons: { IconStore(fetcher: fetcher, directory: directory, settle: 0) })
        await door.unlock(with: SecretBytes(DemoVault.password)).value
        let icons = try XCTUnwrap(door.panes?.icons)

        let row = Task { await icons.image(for: "slow.example.com") }
        for _ in 0..<200 where fetcher.asked == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(fetcher.asked, 1)
        XCTAssertEqual(fetcher.cancelled, 0)

        let locked = Date()
        await vault.lock()
        XCTAssertNil(door.panes)
        XCTAssertTrue(icons.hasEnded)
        let drawn = await row.value
        XCTAssertLessThan(Date().timeIntervalSince(locked), 2, "the request ran on behind the lock")
        XCTAssertNil(drawn)
        XCTAssertEqual(fetcher.cancelled, 1, "the fetcher's task was not cancelled")
        XCTAssertEqual(fetcher.ended, 1, "the fetcher was not told to shut what it had open")

        // The fetcher answered with a picture all the same.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(files, [])
        XCTAssertNil(icons.cached("slow.example.com"))

        // And the store the lock left behind asks nobody.
        let later = await icons.image(for: "later.example.com")
        XCTAssertNil(later)
        XCTAssertEqual(fetcher.asked, 1)
    }

    func testAnAnswerThatComesAfterTheStoreEndedIsNotKept() async throws {
        // This one does not notice it was cancelled.
        let fetcher = CountingFetcher { _ in .image(tinyPNG()) }
        let icons = store(fetcher, settle: 0)
        let known = await icons.image(for: "known.example.com")
        XCTAssertNotNil(known)
        XCTAssertEqual(files, ["known.example.com.png"])

        let row = Task { await icons.image(for: "late.example.com") }
        for _ in 0..<200 where fetcher.hosts.count < 2 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(fetcher.hosts.count, 2)
        icons.end()
        let late = await row.value
        XCTAssertNil(late)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(files, ["known.example.com.png"], "the files stay, and no new one is written")
        XCTAssertNil(icons.cached("known.example.com"), "the memory half goes with the lock")
        XCTAssertNil(icons.cached("late.example.com"))
    }

    // MARK: A row that leaves

    func testARowThatLeavesBeforeTheSettleStartsNoRequest() async throws {
        let fetcher = CountingFetcher { _ in .image(tinyPNG()) }
        let icons = store(fetcher, settle: 0.3)
        let gone = Task { await icons.image(for: "gone.example.com") }
        let stays = Task { await icons.image(for: "stays.example.com") }
        try await Task.sleep(nanoseconds: 60_000_000)
        gone.cancel()
        let left = await gone.value
        let stayed = await stays.value
        XCTAssertNil(left)
        XCTAssertNotNil(stayed)
        XCTAssertEqual(fetcher.hosts, ["stays.example.com"])
    }

    func testARowThatLeavesAfterTheRequestLeavesTheOthersTheirIcon() async throws {
        let fetcher = CountingFetcher { _ in .image(tinyPNG()) }
        let icons = store(fetcher, settle: 0)
        let first = Task { await icons.image(for: "shared.example.com") }
        let second = Task { await icons.image(for: "shared.example.com") }
        try await Task.sleep(nanoseconds: 5_000_000)
        first.cancel()
        let kept = await second.value
        XCTAssertNotNil(kept)
        XCTAssertEqual(fetcher.hosts, ["shared.example.com"])
    }
}
