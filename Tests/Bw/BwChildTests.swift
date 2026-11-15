import XCTest
@testable import OriPass

final class BwChildTests: XCTestCase {
    func testStartReadyStopAndNothingLeft() async throws {
        let standIn = try StandIn()
        let child = standIn.child()
        try await child.start()

        let pid = try XCTUnwrap(child.pid)
        XCTAssertTrue(isAlive(pid))
        XCTAssertEqual(standIn.requests.first, "GET /status ", "ready means the child answered")
        XCTAssertEqual(standIn.arguments.last, ["serve", "--hostname", "fd+connected://3"])
        XCTAssertEqual(standIn.left, ["child.pid"], "the pid and nothing else")
        XCTAssertEqual(standIn.sockets, [], "no socket file while it runs")

        // The stand-in would take two seconds to go by itself, as the real
        // one does. A stop does not wait for them.
        let asked = Date()
        await child.stop()
        XCTAssertLessThan(Date().timeIntervalSince(asked), 1)
        XCTAssertFalse(isAlive(pid))
        XCTAssertEqual(standIn.left, [])
        XCTAssertEqual(standIn.sockets, [], "and none after it stops")
        XCTAssertNil(child.pid)
    }

    func testTheRunDirectoryIsPrivate() async throws {
        let standIn = try StandIn()
        // Made beforehand, and too open.
        try FileManager.default.createDirectory(at: standIn.run, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let child = standIn.child()
        try await child.start()
        let mode = try FileManager.default.attributesOfItem(atPath: standIn.run.path)[.posixPermissions]
        XCTAssertEqual(mode as? Int, 0o700)
        await child.stop()
    }

    /// What the real one did on 2026-10-11 with nothing watching it: its
    /// connection ended, and two seconds later it had exited by itself.
    func testAChildWhoseConnectionEndsGoesByItselfTwoSecondsLater() async throws {
        let standIn = try StandIn()
        let child = standIn.child()
        try await child.start()
        let pid = try XCTUnwrap(child.pid)

        // The connection and no signal: what a crash of the app comes to.
        child.connection?.shut()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertTrue(isAlive(pid), "the stand-in takes its two seconds, as the real one did")
        let gone = await eventually(within: 2) { !isAlive(pid) }
        XCTAssertTrue(gone)
        XCTAssertNil(child.pid, "and its pid is written down no longer")
        await child.stop()
    }

    func testTheChildDiesWithAParentThatWasKilled() async throws {
        let standIn = try StandIn()
        let helper = Process()
        helper.executableURL = Bundle.main.executableURL
        helper.environment = ["OP_DEMO": "child", "OP_CHILD_BW": standIn.binary.path,
                              "OP_CHILD_RUN": standIn.run.path]
        let output = Pipe()
        helper.standardOutput = output
        try helper.run()

        let said = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        let pid = try XCTUnwrap(pid_t(said.split(separator: " ").last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""), "the helper said: \(said)")
        XCTAssertTrue(isAlive(pid))
        XCTAssertEqual(standIn.left, ["child.pid"])
        XCTAssertEqual(standIn.sockets, [])

        // SIGKILL runs no handler in the helper. Whatever takes the child
        // down is not code of this app's, and so not a timer of its: it is
        // the child reading the end of its connection. The real one took
        // 2.010 s and 2.026 s from there, so this waits three.
        kill(helper.processIdentifier, SIGKILL)
        let gone = await eventually(within: 3) { !isAlive(pid) }
        XCTAssertTrue(gone, "the stand-in outlived its parent")
    }

    func testAChildThatExitsByItselfIsHeardOf() async throws {
        let standIn = try StandIn(["exitAfter": 0.3])
        let child = standIn.child()
        let heard = expectation(description: "onExit")
        child.onExit = { heard.fulfill() }
        try await child.start()
        let started = Date()
        await fulfillment(of: [heard], timeout: 1.3)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.3)
        XCTAssertEqual(standIn.left, [], "its pid went with it")
        await child.stop()
    }

    func testStopIsNotHeardAsAnExit() async throws {
        let standIn = try StandIn()
        let child = standIn.child()
        child.onExit = { XCTFail("a stop is not the child dying by itself") }
        try await child.start()
        await child.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    /// A child that hangs when its connection ends, which no run has seen
    /// of the real one: told to go, waited for, and then killed.
    func testAChildThatWillNotGoIsKilled() async throws {
        let standIn = try StandIn(["stubborn": true])
        let child = standIn.child()
        try await child.start()
        let pid = try XCTUnwrap(child.pid)

        let asked = Date()
        await child.stop()
        let took = Date().timeIntervalSince(asked)
        XCTAssertGreaterThan(took, 2, "it was given a little over two seconds")
        XCTAssertLessThan(took, 4)
        XCTAssertFalse(isAlive(pid))
        XCTAssertEqual(standIn.left, [])
    }

    /// No process outlives SIGKILL in a test, so this one is a child that
    /// no signal is sent to: `stop` waits both times, the wait says it is
    /// still there, and its pid stays written down. The next start's
    /// cleanup is then what kills it.
    func testAChildThatOutlivesItsKillKeepsItsPidForTheNextCleanup() async throws {
        let standIn = try StandIn(["stubborn": true])
        var sent: [Int32] = []
        let child = BwChild(binary: standIn.binary, runDirectory: standIn.run, dataDirectory: standIn.data,
                            signal: { _, signal in sent.append(signal) })
        try await child.start()
        let pid = try XCTUnwrap(child.pid)

        await child.stop()

        XCTAssertEqual(sent, [SIGTERM, SIGKILL])
        XCTAssertTrue(isAlive(pid))
        XCTAssertEqual(standIn.left, ["child.pid"])
        XCTAssertEqual(child.pid, pid)

        BwChild.clearLeftovers(in: standIn.run)
        let gone = await eventually(within: 1) { !isAlive(pid) || ProcessArguments.of(pid) == nil }
        XCTAssertTrue(gone)
        XCTAssertEqual(standIn.left, [])
    }

    func testAChildThatNeverAnswersIsNotReadyAndIsNotLeftRunning() async throws {
        let standIn = try StandIn(["mute": true])
        let child = standIn.child()
        do {
            try await child.start(readyWithin: 0.3)
            XCTFail("started")
        } catch {
            XCTAssertEqual(error as? BwChild.Failure, .notReady)
        }
        XCTAssertEqual(standIn.arguments.count, 1, "it was started")
        XCTAssertEqual(standIn.left, [])
    }

    func testTheChildsArgumentsAreTheBinaryAndTheDescriptor() async throws {
        let standIn = try StandIn()
        let child = standIn.child()
        try await child.start()

        let everyArgument = try PS.run(["-axww", "-o", "args="])
        XCTAssertTrue(everyArgument.contains("\(standIn.binary.path) serve --hostname fd+connected://3"),
                      "ps did list the child")
        let arguments = try XCTUnwrap(ProcessArguments.of(try XCTUnwrap(child.pid)))
        XCTAssertEqual(Array(arguments.suffix(3)), ["serve", "--hostname", "fd+connected://3"])
        await child.stop()
    }

    func testABwWithNoAccountSaysSoAndIsNotLeftRunning() async throws {
        let standIn = try StandIn(["loggedOut": true])
        let child = standIn.child()
        do {
            try await child.start()
            XCTFail("started")
        } catch {
            XCTAssertEqual(error as? BwChild.Failure, .exited("You are not logged in."))
        }
        XCTAssertEqual(standIn.left, [])
    }

    func testWhatAPreviousLifeLeftIsCleared() async throws {
        let standIn = try StandIn()
        // A child nobody stopped and whose connection never ended: started
        // by hand on one end of a socketpair, with the other end kept open
        // here. The shell is only how a test hands it descriptor 3.
        var ends: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &ends), 0)
        defer { ends.forEach { close($0) } }
        let orphan = Process()
        orphan.executableURL = URL(fileURLWithPath: "/bin/sh")
        orphan.arguments = ["-c", #"exec "$0" serve --hostname fd+connected://3 3<&0 </dev/null"#,
                            standIn.binary.path]
        orphan.standardInput = FileHandle(fileDescriptor: ends[1], closeOnDealloc: false)
        try orphan.run()
        try FileManager.default.createDirectory(at: standIn.run, withIntermediateDirectories: true)
        try "\(orphan.processIdentifier)\n".write(to: standIn.run.appendingPathComponent("child.pid"),
                                                  atomically: true, encoding: .utf8)
        // And what a build from before D5 was rewritten left beside it. A
        // file of that name, since no test makes a socket.
        let old = standIn.run.appendingPathComponent("serve.sock")
        try Data().write(to: old)
        let serving = await eventually(within: 3) {
            ProcessArguments.of(orphan.processIdentifier)?.contains("fd+connected://3") == true
        }
        XCTAssertTrue(serving)

        BwChild.clearLeftovers(in: standIn.run)
        let gone = await eventually(within: 1) { !orphan.isRunning }
        XCTAssertTrue(gone)
        XCTAssertEqual(standIn.left, [])

        // A pid that is somebody else's by now is left alone.
        try "\(ProcessInfo.processInfo.processIdentifier)\n"
            .write(to: standIn.run.appendingPathComponent("child.pid"), atomically: true, encoding: .utf8)
        BwChild.clearLeftovers(in: standIn.run)
        XCTAssertTrue(isAlive(ProcessInfo.processInfo.processIdentifier))
    }
}
