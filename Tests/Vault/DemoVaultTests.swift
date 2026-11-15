import XCTest
@testable import OriPass

@MainActor
final class DemoVaultTests: XCTestCase {
    private func everything() async throws -> [Item] {
        let backend = DemoVault.backend()
        try await backend.unlock(password: SecretBytes(DemoVault.password))
        let items = try await backend.items()
        let trash = try await backend.trash()
        return items + trash
    }

    func testEveryTypeAndEveryOddityIsPresent() async throws {
        let all = try await everything()
        XCTAssertGreaterThanOrEqual(all.count, 40)
        for type in [ItemType.login, .secureNote, .card, .identity, .sshKey, .unknown(9)] {
            XCTAssertTrue(all.contains { $0.type == type }, "no item of type \(type.rawValue)")
        }
        XCTAssertEqual(all.filter(\.isInTrash).count, 1)
        XCTAssertEqual(all.filter(\.isArchived).count, 1)
        XCTAssertGreaterThanOrEqual(all.filter(\.favorite).count, 2)
        XCTAssertEqual(all.filter(\.reprompt).count, 1)
        XCTAssertEqual(all.filter { $0.login?.passkeysCreated.isEmpty == false }.count, 1)
        XCTAssertEqual(all.filter { $0.login?.password == DemoVault.shared }.count, 2)
        XCTAssertEqual(all.filter { DemoVault.weak.contains($0.login?.password ?? "") }.count, 3)
        XCTAssertEqual(all.filter { $0.login?.uris.contains { $0.uri.hasPrefix("http://") } == true }.count, 1)
        XCTAssertTrue(all.contains { $0.name == "İş Bankası" })
        XCTAssertTrue(all.contains { $0.name.hasPrefix("Şişecam") })

        let backend = DemoVault.backend()
        try await backend.unlock(password: SecretBytes(DemoVault.password))
        let folders = try await backend.folders()
        XCTAssertEqual(folders.map(\.name), DemoVault.folderNames)
        XCTAssertTrue(all.contains { $0.folderID == nil })
    }

    func testEveryItemWasMadeBeforeItWasLastChanged() async throws {
        let all = try await everything()
        XCTAssertGreaterThanOrEqual(all.count, 40)
        for item in all {
            let created = try XCTUnwrap(item.created, item.name)
            let revised = try XCTUnwrap(item.revised, item.name)
            XCTAssertLessThan(created, revised, item.name)
            for entry in item.passwordHistory {
                let used = try XCTUnwrap(entry.lastUsed, item.name)
                XCTAssertLessThan(created, used, "\(item.name) had a password before it was made")
            }
        }
    }

    func testACardExpiresNextMonth() async throws {
        let now = try XCTUnwrap(VaultDate.parse("2026-12-15T12:00:00Z"))
        let cards = DemoVault.objects(now: now).items.compactMap { try? Item(json: $0) }
            .compactMap { item -> Card? in
                if case .card(let card) = item.payload { return card }
                return nil
            }
        XCTAssertTrue(cards.contains { $0.expMonth == "1" && $0.expYear == "2027" })
    }

    /// The whole point of the list: if a secret is in the vault and not in
    /// `canaries`, `make canary` cannot find it leaking.
    func testEverySecretIsACanary() async throws {
        func isCanary(_ secret: String?) -> Bool {
            guard let secret, !secret.isEmpty else { return true }
            return DemoVault.canaries.contains { secret.contains($0) }
        }
        for item in try await everything() {
            let who = "item \(item.id)"
            for field in item.fields where field.kind == .hidden {
                XCTAssertTrue(isCanary(field.value), who)
            }
            for entry in item.passwordHistory { XCTAssertTrue(isCanary(entry.password), who) }
            switch item.payload {
            case .login(let login):
                XCTAssertTrue(isCanary(login.password), who)
                XCTAssertTrue(isCanary(login.totp), who)
                XCTAssertTrue(isCanary(login.username), who)
                for passkey in item.raw["login"]?["fido2Credentials"]?.array ?? [] {
                    XCTAssertTrue(isCanary(passkey["keyValue"]?.string), who)
                }
            case .card(let card):
                XCTAssertTrue(isCanary(card.number), who)
                XCTAssertTrue(isCanary(card.code), who)
            case .identity(let identity):
                for key in Identity.Key.allCases where key.isHidden {
                    XCTAssertTrue(isCanary(identity[key]), who)
                }
            case .sshKey(let key):
                XCTAssertTrue(isCanary(key.privateKey), who)
            case .secureNote:
                XCTAssertTrue(isCanary(item.notes), who)
            case .unknown(let payload):
                XCTAssertTrue(isCanary(payload["licenseNumber"]?.string), who)
            }
        }
        XCTAssertEqual(Set(DemoVault.canaries).count, DemoVault.canaries.count)
    }
}
