import XCTest
@testable import OriPass

/// `scripts/spike-bw.sh` and `scripts/spike-fd.py` are run by hand against
/// a real vault, and what they print is read before it is kept. Each one's own
/// check of what it lets through is run here: no `bw`, no account, bodies
/// made up inside the script.
final class SpikeScriptTests: XCTestCase {
    func testTheSpikePrintsShapesAndCountsOfAnInventedBodyAndNoValue() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/spike-bw.sh")
        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/bin/bash")
        run.arguments = [script.path, "--selftest"]
        let said = Pipe()
        run.standardOutput = said
        run.standardError = said
        try run.run()
        let output = String(decoding: said.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        run.waitUntilExit()
        XCTAssertEqual(run.terminationStatus, 0, output)
        XCTAssertTrue(output.hasSuffix("selftest: ok\n"), output)
        XCTAssertFalse(output.contains("selftest-"), "a made-up value came through")
    }

    /// `scripts/spike-fd.py` is OP-64's, run by hand against a real `bw`
    /// on one end of a socketpair. Here it asks the same things of a fake
    /// child it starts itself, four times: one that holds the connection,
    /// one that closes it, one that goes once the vault is open and one
    /// that will not exit. The password and the sessions are made up.
    func testTheSocketSpikeAsksEverythingOfAFakeChildAndPrintsNoValue() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/spike-fd.py")
        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        run.arguments = [script.path, "--selftest"]
        let said = Pipe()
        run.standardOutput = said
        run.standardError = said
        try run.run()
        let output = String(decoding: said.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        run.waitUntilExit()
        XCTAssertEqual(run.terminationStatus, 0, output)
        XCTAssertTrue(output.hasSuffix("selftest: ok\n"), output)
        XCTAssertFalse(output.contains("selftest-"), "a made-up value came through")
        XCTAssertTrue(output.contains("h. locked: the last thing the vault was sent was POST /lock"), output)
        XCTAssertTrue(output.contains("h. NOT LOCKED BY THIS RUN"), output)
    }

    /// `scripts/spike-passkey.py` is OP-76's, run once by hand against a
    /// real `bw` on a throwaway login. Here it asks the same things of a fake
    /// child it starts itself, one that keeps a passkey as hoped and one for
    /// each way of not keeping it, and says yes to the first alone.
    func testThePasskeySpikeSaysYesOnlyToAnEngineThatKeepsItEncrypted() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/spike-passkey.py")
        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        run.arguments = [script.path, "--selftest"]
        let said = Pipe()
        run.standardOutput = said
        run.standardError = said
        try run.run()
        let output = String(decoding: said.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        run.waitUntilExit()
        XCTAssertEqual(run.terminationStatus, 0, output)
        XCTAssertTrue(output.hasSuffix("selftest: ok\n"), output)
        XCTAssertFalse(output.contains("selftest-"), "a made-up value came through")
    }

    /// `scripts/spike-sync.py` is OP-84's, run once by hand against a real
    /// `bw`. Here it counts the reads of a fake child it starts itself, steady,
    /// empty behind a sync and short behind one.
    func testTheSyncSpikeCountsAShortReadAndPrintsNoValue() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/spike-sync.py")
        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        run.arguments = [script.path, "--selftest"]
        let said = Pipe()
        run.standardOutput = said
        run.standardError = said
        try run.run()
        let output = String(decoding: said.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        run.waitUntilExit()
        XCTAssertEqual(run.terminationStatus, 0, output)
        XCTAssertTrue(output.hasSuffix("selftest: ok\n"), output)
    }
}
