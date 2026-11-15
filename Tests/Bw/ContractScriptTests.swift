import XCTest
@testable import OriPass

/// `scripts/contract.sh` is run by hand against a real `bw` after an
/// upgrade, and prints which fixtures no longer match, by key. Its own
/// check of what it lets through and what it finds is run here: no `bw`, no
/// account, bodies made up inside the script and the fixtures in this repo.
final class ContractScriptTests: XCTestCase {
    private func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/contract.sh")
        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/bin/bash")
        run.arguments = [script.path] + arguments
        let said = Pipe()
        run.standardOutput = said
        run.standardError = said
        try run.run()
        let output = String(decoding: said.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        run.waitUntilExit()
        return (run.terminationStatus, output)
    }

    func testTheContractFindsAChangedShapeByKeyAndPrintsNoValue() throws {
        let (status, output) = try run(["--selftest"])
        XCTAssertEqual(status, 0, output)
        XCTAssertTrue(output.hasSuffix("selftest: ok\n"), output)
        XCTAssertFalse(output.contains("selftest-yes"), "a made-up value came through")
        XCTAssertFalse(output.contains("CANARY"), "a fixture's value came through")
        // A key no vault uses, the fixture's own key and a key known under
        // another type are said and fail nothing; the selftest judges each.
        XCTAssertTrue(output.contains("long: 0 of 1 differ"), "an answer longer than a pipe was not compared")
        XCTAssertFalse(output.contains("Broken pipe"), "a writer was left with nobody reading")
    }

    /// The script cannot read Swift, so the months it says it was written
    /// for are held to the range `BwBinary` judges by.
    func testTheMonthsTheScriptComparesAgainstAreTheOnesTheAppJudgesBy() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/contract.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(text.contains("\nWRITTEN=\"\(BwVersion.writtenWords)\"\n"), "WRITTEN in contract.sh")
    }
}
