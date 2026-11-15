import XCTest
@testable import OriPass

final class FaceKeyTests: XCTestCase {
    private let keychain = Keychain(service: "com.meric.oripass.tests")

    override func tearDown() {
        keychain.deleteAll()
    }

    func testAKeyKeptUnderOtherFacesIsForgottenBeforeAnyoneIsAsked() async throws {
        let before = FaceKey(keychain: keychain, faces: { Data("faces-before".utf8) })
        try before.keep(VaultKey.random())
        XCTAssertTrue(before.isKept)
        XCTAssertFalse(before.forgetIfFacesChanged(), "the same faces keep it")

        let after = FaceKey(keychain: keychain, faces: { Data("faces-after".utf8) })
        do {
            _ = try await after.open(reason: "a test")
            XCTFail("opened")
        } catch {
            XCTAssertEqual(error as? FaceKey.Failure, .gone)
        }
        XCTAssertFalse(after.isKept)
        XCTAssertNil(try keychain.read(FaceKey.marked))
    }

    func testNoKeyIsGoneWithoutAQuestion() async {
        do {
            _ = try await FaceKey(keychain: keychain).open(reason: "a test")
            XCTFail("opened")
        } catch {
            XCTAssertEqual(error as? FaceKey.Failure, .gone)
        }
    }
}
