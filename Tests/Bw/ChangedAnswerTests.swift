import XCTest
@testable import OriPass

/// `bw` answers with something else than the fixtures hold. A key it
/// added changes nothing; a key the app needs that is gone locks the store
/// with a sentence that names the route, and nothing traps (OP-59).
@MainActor
final class ChangedAnswerTests: XCTestCase {
    private var kept: [StandIn] = []

    private func store(changing changed: [String: Data]) throws -> (StandIn, VaultStore) {
        let standIn = try StandIn(["password": "demo"], changed: changed)
        kept.append(standIn)
        let backend = ServeBackend(preferredPath: standIn.binary.path, runDirectory: standIn.run,
                                   dataDirectory: standIn.data)
        return (standIn, VaultStore(backend: backend))
    }

    private func withoutAKey(of list: String, _ key: String) throws -> Data {
        try Fixture.changed(list) { object in
            var envelope = object["data"] as? [String: Any] ?? [:]
            var rows = envelope["data"] as? [[String: Any]] ?? []
            rows[0][key] = nil
            envelope["data"] = rows
            object["data"] = envelope
        }
    }

    private func isShut(_ standIn: StandIn) -> Bool {
        standIn.left.isEmpty
    }

    func testAnItemWithoutANameLocksTheStoreAndNamesTheRoute() async throws {
        let (standIn, store) = try store(changing: ["list-items": try withoutAKey(of: "list-items", "name")])
        let opened = await store.unlock(password: SecretBytes("demo"))
        XCTAssertFalse(opened)
        XCTAssertEqual(store.state, .failed("The engine's answer to /list/object/items had no name."))
        XCTAssertTrue(store.shelves.all.isEmpty, "nothing half read is kept")
        XCTAssertTrue(isShut(standIn), "the child is gone with it")
    }

    /// A `bw` that answers this app's Host with 403 and a word, as the
    /// real one did until the port was named: the lock screen says the
    /// status, soon, and not that the engine went quiet.
    func testABwThatTurnsEveryRequestAwaySaysSoOnTheLockScreen() async throws {
        let standIn = try StandIn(["password": "demo", "host": "elsewhere:1"])
        kept.append(standIn)
        let store = VaultStore(backend: ServeBackend(preferredPath: standIn.binary.path,
                                                     runDirectory: standIn.run, dataDirectory: standIn.data))
        let started = Date()
        let opened = await store.unlock(password: SecretBytes("demo"))
        XCTAssertFalse(opened)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(store.state, .failed(
            "The engine turned the request away with HTTP 403 and no reason. This bw may not be one OriPass was written for."
        ))
        XCTAssertTrue(isShut(standIn), "the child is gone with it")
    }

    func testAnItemWithoutATypeInTheTrashNamesTheTrashRoute() async throws {
        let (_, store) = try store(changing: ["list-trash": try withoutAKey(of: "list-trash", "type")])
        await store.unlock(password: SecretBytes("demo"))
        XCTAssertEqual(store.state, .failed("The engine's answer to /list/object/items had no type."))
    }

    func testAListWithoutItsDataNamesTheRoute() async throws {
        let moved = try Fixture.changed("list-folders") { object in
            var envelope = object["data"] as? [String: Any] ?? [:]
            envelope["data"] = nil
            object["data"] = envelope
        }
        let (_, store) = try store(changing: ["list-folders": moved])
        await store.unlock(password: SecretBytes("demo"))
        XCTAssertEqual(store.state, .failed("The engine's answer to /list/object/folders had no data."))
    }

    func testAStatusWithoutItsStatusIsNotTakenForALoggedOutAccount() async throws {
        let bare = try Fixture.changed("status-locked") { object in
            var envelope = object["data"] as? [String: Any] ?? [:]
            var template = envelope["template"] as? [String: Any] ?? [:]
            template["status"] = nil
            envelope["template"] = template
            object["data"] = envelope
        }
        let (_, store) = try store(changing: ["status-locked": bare])
        await store.refresh()
        XCTAssertEqual(store.state, .failed("The engine's answer to bw status had no status."))
    }

    func testEachWriteAndTheGeneratorNameTheirOwnRoute() async throws {
        let (standIn, _) = try store(changing: [
            "generate": try Fixture.changed("generate") { object in object["data"] = ["object": "string"] },
            "item": try Fixture.changed("item") { object in
                var item = object["data"] as? [String: Any] ?? [:]
                item["name"] = nil
                object["data"] = item
            },
        ])
        let backend = ServeBackend(preferredPath: standIn.binary.path, runDirectory: standIn.run,
                                   dataDirectory: standIn.data)
        try await backend.unlock(password: SecretBytes("demo"))
        do {
            _ = try await backend.generate(.random(length: 24, digits: true, symbols: false))
            XCTFail("generated")
        } catch {
            XCTAssertEqual(error as? ShapeError, ShapeError(missing: "data", route: "/generate"))
        }
        do {
            _ = try await backend.create(.object(["name": .string("Yeni"), "type": .int(2)]))
            XCTFail("created")
        } catch {
            XCTAssertEqual(error as? ShapeError, ShapeError(missing: "name", route: "/object/item"))
        }
        await backend.close()
    }

    func testAKeyBwHasAddedChangesNothing() async throws {
        let added = try Fixture.changed("list-items") { object in
            var envelope = object["data"] as? [String: Any] ?? [:]
            var rows = envelope["data"] as? [[String: Any]] ?? []
            for index in rows.indices {
                rows[index]["somethingNew"] = ["nested": [1, 2, 3]]
                var login = rows[index]["login"] as? [String: Any]
                login?["anotherNewOne"] = true
                if let login { rows[index]["login"] = login }
            }
            envelope["data"] = rows
            envelope["alsoNew"] = "x"
            object["data"] = envelope
            object["extra"] = 1
        }
        let (_, store) = try store(changing: ["list-items": added])
        let opened = await store.unlock(password: SecretBytes("demo"))
        XCTAssertTrue(opened)
        XCTAssertEqual(store.state, .unlocked)
        let (_, plain) = try self.store(changing: [:])
        await plain.unlock(password: SecretBytes("demo"))
        XCTAssertFalse(store.shelves.all.isEmpty)
        XCTAssertEqual(store.shelves.all.map(\.item.name), plain.shelves.all.map(\.item.name))
        await store.lock()
        await plain.lock()
    }
}
