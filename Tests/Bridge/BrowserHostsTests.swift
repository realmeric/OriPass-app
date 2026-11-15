import Foundation
import XCTest
@testable import OriPass

/// Orion's file, under a folder of the test's own.
final class BrowserHostsTests: XCTestCase {
    private static let installed = URL(fileURLWithPath: "/Applications/OriPass.app")
    private static let built = URL(fileURLWithPath: "/Users/someone/Library/Developer/Xcode/DerivedData/OriPass-x/Build/Products/Debug/OriPass.app")

    private var directory: URL!

    private var orion: URL { directory.appendingPathComponent("Orion") }
    private var manifest: URL {
        orion.appendingPathComponent("NativeMessagingHosts/com.meric.oripass.bridge.json")
    }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hosts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: orion, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func hosts(app: URL = installed, isDemo: Bool = false) -> BrowserHosts {
        BrowserHosts(orion: orion, app: app, isDemo: isDemo)
    }

    private func choices(on: Bool, allowed: [String] = []) -> BrowserChoices {
        var choices = BrowserChoices()
        choices.inOrion = on
        choices.allowed = allowed
        return choices
    }

    private func written() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
    }

    private var isThere: Bool { FileManager.default.fileExists(atPath: manifest.path) }

    func testAFolderIsWhatMakesOrionHere() throws {
        XCTAssertTrue(hosts().hasOrion)
        try FileManager.default.removeItem(at: orion)
        XCTAssertFalse(hosts().hasOrion)
    }

    func testWritten() throws {
        hosts().follow(choices(on: true, allowed: ["chrome-extension://abc/"]))
        let manifest = try written()
        XCTAssertEqual(manifest["name"] as? String, BridgeCaller.host.rawValue)
        XCTAssertEqual(manifest["path"] as? String, "/Applications/OriPass.app/Contents/Helpers/oripass-bridge")
        XCTAssertEqual(manifest["type"] as? String, "stdio")
        XCTAssertEqual(manifest["allowed_origins"] as? [String], ["chrome-extension://abc/"])
    }

    func testWrittenAgainWithAnotherPath() throws {
        hosts().follow(choices(on: true))
        hosts(app: URL(fileURLWithPath: "/Users/someone/Applications/OriPass.app")).follow(choices(on: true))
        XCTAssertEqual(try written()["path"] as? String,
                       "/Users/someone/Applications/OriPass.app/Contents/Helpers/oripass-bridge")
    }

    func testRemovedWhenTheChoiceIsOff() {
        hosts().follow(choices(on: true))
        XCTAssertTrue(isThere)
        hosts().follow(choices(on: false))
        XCTAssertFalse(isThere)
    }

    func testOffWithNoFileIsNothing() {
        hosts().follow(choices(on: false))
        XCTAssertFalse(isThere)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orion.appendingPathComponent("NativeMessagingHosts").path))
    }

    func testNothingWhenOrionsFolderIsMissing() throws {
        try FileManager.default.removeItem(at: orion)
        hosts().follow(choices(on: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orion.path))
    }

    func testACopyInDerivedDataLeavesTheFileAlone() throws {
        hosts(app: Self.built).follow(choices(on: true))
        XCTAssertFalse(isThere)
        hosts().follow(choices(on: true))
        hosts(app: Self.built).follow(choices(on: false))
        XCTAssertTrue(isThere)
    }

    func testADemoMayWriteAndItsOffTakesNothingAway() throws {
        hosts(app: Self.built, isDemo: true).follow(choices(on: true))
        XCTAssertEqual(try written()["path"] as? String, Self.built.appendingPathComponent("Contents/Helpers/oripass-bridge").path)
        hosts(app: Self.built, isDemo: true).follow(choices(on: false))
        XCTAssertTrue(isThere)
    }
}
