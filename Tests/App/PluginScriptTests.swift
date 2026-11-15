import XCTest

/// `scripts/plugin-check.sh` runs the Claude Code plugin's hook as Claude Code
/// would, against OpenSSH's own `ssh-agent` on a temp socket with a throwaway
/// key and a HOME of its own: with a socket, with none, with a dead one and
/// with no `CLAUDE_ENV_FILE`, and then `ssh-add -L` and a signature through
/// what the hook wrote. It needs no Claude Code and no OriPass.
final class PluginScriptTests: XCTestCase {
    func testTheHookPointsASessionAtALiveAgentAndAsksItNothing() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/plugin-check.sh")
        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/bin/bash")
        run.arguments = [script.path]
        let said = Pipe()
        run.standardOutput = said
        run.standardError = said
        try run.run()
        let output = String(decoding: said.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        run.waitUntilExit()
        XCTAssertEqual(run.terminationStatus, 0, output)
        XCTAssertTrue(output.hasSuffix("plugin-check: ok\n"), output)
        XCTAssertTrue(output.contains("no socket: nothing written"), output)
        XCTAssertTrue(output.contains("no env file: nothing written"), output)
        XCTAssertTrue(output.contains("agent: ssh-add -L lists the key through what the hook wrote"), output)
    }
}
