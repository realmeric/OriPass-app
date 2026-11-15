import XCTest
@testable import OriPass

final class BwBinaryTests: XCTestCase {
    func testThePreferredPathWinsThenThePath() throws {
        let standIn = try StandIn()
        XCTAssertEqual(BwBinary.find(preferred: standIn.binary.path, fallback: nil, path: ""), standIn.binary)
        XCTAssertEqual(BwBinary.find(preferred: "/nowhere/bw", fallback: nil,
                                     path: standIn.directory.path)?.path, standIn.binary.path)
    }

    func testTheFallbackComesBeforeThePathAndAfterThePreferred() throws {
        let standIn = try StandIn()
        let other = try StandIn()
        XCTAssertEqual(BwBinary.find(preferred: "/nowhere/bw", fallback: standIn.binary.path,
                                     path: other.directory.path), standIn.binary)
        XCTAssertEqual(BwBinary.find(preferred: other.binary.path, fallback: standIn.binary.path,
                                     path: ""), other.binary)
        XCTAssertNil(BwBinary.find(preferred: "/nowhere/bw", fallback: nil, path: ""))
    }

    func testItSaysItsVersionAndSaysSoWhenThereIsNone() async throws {
        let standIn = try StandIn(["version": "2026.9.1"])
        let found = try await BwBinary.locate(preferred: standIn.binary.path, dataDirectory: standIn.data)
        XCTAssertEqual(found, BwBinary(url: standIn.binary, version: "2026.9.1"))
    }

    /// Four names and no way to ask for a fifth: there is no session to
    /// hand it (D7).
    func testTheEnvironmentIsBuiltNotInheritedAndHoldsNoSession() {
        let directory = URL(fileURLWithPath: "/tmp/op-data")
        XCTAssertEqual(Set(BwBinary.environment(dataDirectory: directory).keys),
                       ["BITWARDENCLI_APPDATA_DIR", "BW_NOINTERACTION", "PATH", "HOME"])
        XCTAssertEqual(Set(BwBinary.environment(dataDirectory: directory, asks: true).keys),
                       ["BITWARDENCLI_APPDATA_DIR", "PATH", "HOME"])
    }
}
