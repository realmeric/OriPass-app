import XCTest
@testable import OriPass

/// An unlock over two thousand items, timed. `VaultStore.load` asks for the
/// items, the trash, the folders and the collections at once, and over one
/// connection they are answered one after another (`docs/notes.md`,
/// "Timing").
@MainActor
final class TwoThousandTests: XCTestCase {
    private var kept: [StandIn] = []

    /// The eight items of the fixture two hundred and fifty times over,
    /// each under an id of its own.
    private func twoThousand() throws -> Data {
        try Fixture.changed("list-items") { object in
            var envelope = object["data"] as? [String: Any] ?? [:]
            let rows = envelope["data"] as? [[String: Any]] ?? []
            envelope["data"] = (0..<250).flatMap { round in
                rows.map { row -> [String: Any] in
                    var row = row
                    row["id"] = UUID().uuidString.lowercased()
                    row["name"] = "\(row["name"] ?? "") \(round)"
                    return row
                }
            }
            object["data"] = envelope
        }
    }

    func testAnUnlockOverTwoThousandItemsIsTimed() async throws {
        let standIn = try StandIn(["password": "demo"], changed: ["list-items": try twoThousand()])
        kept.append(standIn)
        var unlocks: [TimeInterval] = []
        for _ in 0..<5 {
            let store = VaultStore(backend: ServeBackend(preferredPath: standIn.binary.path,
                                                         runDirectory: standIn.run, dataDirectory: standIn.data))
            let started = Date()
            let opened = await store.unlock(password: SecretBytes("demo"))
            unlocks.append(Date().timeIntervalSince(started))
            XCTAssertTrue(opened)
            XCTAssertGreaterThan(store.shelves.all.count, 1500)
            await store.lock()
        }

        // The four lists by themselves, as `load` asks for them, with no
        // store scoring and indexing what came beside them.
        let backend = ServeBackend(preferredPath: standIn.binary.path, runDirectory: standIn.run,
                                   dataDirectory: standIn.data)
        try await backend.unlock(password: SecretBytes("demo"))
        var lists: [TimeInterval] = []
        for _ in 0..<5 {
            let started = Date()
            async let items = backend.items()
            async let trash = backend.trash()
            async let folders = backend.folders()
            async let collections = backend.collections()
            let read = try await (items, trash, folders, collections)
            lists.append(Date().timeIntervalSince(started))
            XCTAssertEqual(read.0.count, 2000)
        }
        await backend.close()
        let unlock = unlocks.sorted()[2], list = lists.sorted()[2]
        print(String(format: "two thousand: unlock median %.3f s, the four lists median %.3f s", unlock, list))
        XCTAssertLessThan(unlock, 3, "an unlock over two thousand items")
    }
}
