import XCTest
@testable import OriPass

@MainActor
final class FakeBackendTests: XCTestCase {
    private func fake() throws -> FakeBackend {
        FakeBackend(items: try Fixture.json("list-items")["data"]?["data"]?.array ?? [],
                    folders: try Fixture.json("list-folders")["data"]?["data"]?.array ?? [],
                    password: "demo")
    }

    private func demo() -> SecretBytes { SecretBytes("demo") }

    func testEveryCallIsCounted() async throws {
        let backend = try fake()
        _ = try await backend.status()
        try await backend.unlock(password: demo())
        let items = try await backend.items()
        _ = try await backend.items()
        _ = try await backend.trash()
        _ = try await backend.folders()
        try await backend.sync()
        let bank = try XCTUnwrap(items.first { $0.name == "İş Bankası" })
        _ = try await backend.save(bank, as: try XCTUnwrap(bank.patched(bank)))
        try await backend.archive(bank)
        try await backend.unarchive(bank)
        try await backend.delete(bank, permanently: false)
        try await backend.restore(bank)
        let folder = try await backend.createFolder(named: "Yeni")
        let renamed = try await backend.rename(folder, to: "Yeni 2")
        try await backend.delete(renamed)
        _ = try await backend.generate(.pin(digits: 6))
        await backend.close()

        XCTAssertEqual(backend.calls, [
            "status", "unlock", "items", "items", "trash", "folders", "sync", "save", "archive",
            "unarchive", "delete", "restore", "createFolder", "renameFolder", "deleteFolder",
            "generate", "close",
        ])
        XCTAssertEqual(backend.count(of: "items"), 2)
    }

    func testAWrongPasswordIsRefusedInTheEnginesOwnSentence() async throws {
        let backend = try fake()
        do {
            try await backend.unlock(password: SecretBytes("nope"))
            XCTFail("unlocked with the wrong password")
        } catch {
            XCTAssertEqual(error as? VaultError,
                           .refused("Cryptography error, The decryption operation failed"))
            XCTAssertEqual((try Fixture.json("refused-password"))["message"]?.string,
                           FakeBackend.wrongPassword)
        }
        XCTAssertFalse(backend.isOpen)
    }

    func testCloseLeavesNothingReachable() async throws {
        let backend = try fake()
        try await backend.unlock(password: demo())
        XCTAssertGreaterThan(backend.heldCount, 0)
        await backend.close()
        XCTAssertEqual(backend.heldCount, 0)
        await assertThrows(.locked) { _ = try await backend.items() }

        // The password is the way back in, and a changed one the only
        // one from then on.
        try await backend.unlock(password: demo())
        let reopened = try await backend.items()
        XCTAssertEqual(reopened.count, 8)
        await backend.endSession()
        XCTAssertEqual(backend.heldCount, 0)
        backend.changePassword(to: "another")
        await assertThrows(.refused(FakeBackend.wrongPassword)) { try await backend.unlock(password: self.demo()) }
        try await backend.unlock(password: SecretBytes("another"))
    }

    func testItCanBeToldToRefuseToBeOfflineAndToBeLoggedOut() async throws {
        let backend = try fake()
        try await backend.unlock(password: demo())
        backend.refusal = .refused("Premium status is required to use this feature.")
        await assertThrows(.refused("Premium status is required to use this feature.")) {
            _ = try await backend.items()
        }
        backend.refusal = nil

        backend.isOffline = true
        await assertThrows(.refused(FakeBackend.offline)) { try await backend.sync() }
        let offline = try await backend.items()
        XCTAssertEqual(offline.count, 8, "offline still reads what it had")
        let bank = offline[0]
        await assertThrows(.refused(FakeBackend.offline)) { try await backend.archive(bank) }
        backend.isOffline = false

        backend.isLoggedIn = false
        let status = try await backend.status()
        XCTAssertEqual(status.state, .loggedOut)
        await assertThrows(.loggedOut) { _ = try await backend.items() }
    }

    func testItCanBeSlow() async throws {
        let backend = try fake()
        backend.delay = 0.05
        let started = Date()
        try await backend.unlock(password: demo())
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.05)
    }

    func testWritesLandWhereTheyShould() async throws {
        let backend = try fake()
        try await backend.unlock(password: demo())
        let before = try await backend.items()
        let bank = try XCTUnwrap(before.first { $0.name == "İş Bankası" })

        try await backend.delete(bank, permanently: false)
        let afterDelete = try await backend.items()
        let trash = try await backend.trash()
        XCTAssertEqual(afterDelete.count, before.count - 1)
        XCTAssertEqual(trash.map(\.name), ["İş Bankası"])

        let folders = try await backend.folders()
        let folder = try XCTUnwrap(folders.first { $0.id == bank.folderID })
        try await backend.restore(bank)
        try await backend.delete(folder)
        let afterFolder = try await backend.items()
        let orphan = try XCTUnwrap(afterFolder.first { $0.id == bank.id })
        XCTAssertNil(orphan.folderID, "a deleted folder's items are kept, in no folder")

        // And a lock does not lose a write.
        await backend.close()
        try await backend.unlock(password: demo())
        let afterLock = try await backend.items()
        XCTAssertNil(afterLock.first { $0.id == bank.id }?.folderID)
    }

    private func assertThrows(_ expected: VaultError, file: StaticString = #filePath,
                              line: UInt = #line, _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("did not throw", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? VaultError, expected, file: file, line: line)
        }
    }
}
