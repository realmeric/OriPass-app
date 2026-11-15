import XCTest
@testable import OriPass

final class CensusTests: XCTestCase {
    func testTheFixtureCounted() throws {
        let plain = FakeServer.vault["plain"] as! [String: Any]
        let data = try JSONSerialization.data(withJSONObject: FakeServer.vault["sync"]!)
        let census = Census(vault: try Vault(data: data, userKey: VaultKey(Data(b64: plain["userKey"]))), data: data)
        XCTAssertEqual(census.items, ["Logins": 7, "Notes": 1, "Cards": 1, "Identities": 1, "SSH Keys": 1])
        XCTAssertEqual(Set(census.strings.keys), [2])
        XCTAssertGreaterThan(census.strings[2] ?? 0, 50)
        XCTAssertEqual(census.withOwnKey, 1)
        XCTAssertEqual(census.withCode, 2)
        XCTAssertEqual(census.withPasskey, 1)
        XCTAssertEqual(census.inOrganisations, 1)
        XCTAssertEqual(census.inTrash, 1)
        XCTAssertEqual(census.unread, [:])
    }
}
