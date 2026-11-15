import XCTest
@testable import OriPass

final class ServeClientTests: XCTestCase {
    /// A `StandIn` removes its directory when it is let go of, so the test
    /// holds on to every one it makes.
    private var kept: [StandIn] = []

    /// A stand-in serving one connected socket, already unlocked, and a
    /// client over this end of it.
    private func serving(_ options: [String: Any] = [:],
                         deadline: TimeInterval = 5) async throws -> (StandIn, BwChild, ServeClient) {
        let standIn = try StandIn(options.merging(["unlocked": true]) { $1 })
        kept.append(standIn)
        let child = standIn.child()
        try await child.start()
        return (standIn, child, ServeClient(connection: try XCTUnwrap(child.connection), deadline: deadline))
    }

    func testAPlainBody() async throws {
        let (_, child, client) = try await serving()
        let list = try await client.call("GET", "/list/object/items")
        XCTAssertEqual(list["object"]?.string, "list")
        XCTAssertEqual(list["data"]?.array?.count, 8)
        await child.stop()
    }

    func testAChunkedBody() async throws {
        let (_, child, client) = try await serving(["chunked": true])
        let list = try await client.call("GET", "/list/object/items")
        XCTAssertEqual(list["data"]?.array?.count, 8)
        XCTAssertEqual(list["data"]?.array?.first?["name"]?.string, "İş Bankası")
        await child.stop()
    }

    func testABodySplitAcrossReads() async throws {
        let (_, child, client) = try await serving(["split": true])
        let list = try await client.call("GET", "/list/object/items")
        XCTAssertEqual(list["data"]?.array?.count, 8)
        await child.stop()
    }

    func testABodyCutShortIsATransportFailureAndTheEndOfTheChild() async throws {
        let (standIn, child, client) = try await serving()
        let heard = expectation(description: "onExit")
        child.onExit = { heard.fulfill() }
        standIn.leave("short")
        await assertThrows(.transport) { _ = try await client.call("GET", "/list/object/items") }
        await fulfillment(of: [heard], timeout: 1)
        let gone = await eventually(within: 1) { standIn.left.isEmpty }
        XCTAssertTrue(gone)
    }

    func testAnAnswerShorterThanItSaysIsNoAnswer() throws {
        let body = Fixture.data("list-folders")
        let cut = Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count + 10)\r\n\r\n".utf8) + body
        XCTAssertNil(try ServeClient.answer(in: cut, isAll: false), "more may still come")
        XCTAssertThrowsError(try ServeClient.answer(in: cut, isAll: true)) {
            XCTAssertEqual($0 as? VaultError, .transport)
        }
        XCTAssertThrowsError(try ServeClient.parse(cut))
    }

    /// One connection carries one answer after another, so where an answer
    /// ends is read from the answer and not from the connection closing.
    func testAnAnswerIsCutFromWhatHasBeenReadByItsLengthOrItsChunks() throws {
        let first = Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nfirst".utf8)
        let second = Data("HTTP/1.1 400 Bad Request\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nsec\r\n3;x=y\r\nond\r\n0\r\n\r\n".utf8)
        let both = first + second
        let one = try XCTUnwrap(try ServeClient.answer(in: both, isAll: false))
        XCTAssertEqual(one.length, first.count)
        XCTAssertEqual(String(decoding: one.response.body, as: UTF8.self), "first")
        let two = try XCTUnwrap(try ServeClient.answer(in: both.dropFirst(one.length), isAll: false))
        XCTAssertEqual(two.length, second.count)
        XCTAssertEqual(two.response.status, 400)
        XCTAssertEqual(String(decoding: two.response.body, as: UTF8.self), "second")

        // Every cut short of the whole is "not yet", never half an answer.
        for count in 0..<first.count {
            XCTAssertNil(try ServeClient.answer(in: first.prefix(count), isAll: false), "\(count) bytes")
        }
        for count in 0..<second.count {
            XCTAssertNil(try ServeClient.answer(in: second.prefix(count), isAll: false), "\(count) bytes")
        }
        // No length and no chunks: it ends where the connection does.
        let open = Data("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n".utf8)
        XCTAssertNil(try ServeClient.answer(in: open, isAll: false))
        XCTAssertEqual(try ServeClient.answer(in: open, isAll: true)?.response.status, 400)
    }

    /// The store asks for its four lists at once, and there is one
    /// connection: every answer goes to the call that asked for it, the
    /// stand-in was started once and was sent every request.
    func testCallsMadeAtOnceAreAnsweredOneAfterAnotherEachWithItsOwn() async throws {
        let (standIn, child, client) = try await serving()
        let paths = ["/status", "/list/object/items", "/list/object/folders", "/generate",
                     "/list/object/items?trash=true", "/list/object/collections", "/object/template/item.login"]
        let asked = (0..<4).flatMap { _ in paths }
        let answers = try await withThrowingTaskGroup(of: (Int, JSONValue).self) { group in
            for (place, path) in asked.enumerated() {
                group.addTask { (place, try await client.call("GET", path)) }
            }
            var answers: [Int: JSONValue] = [:]
            for try await (place, answer) in group { answers[place] = answer }
            return answers
        }
        // What each of those is answered with when it is asked alone.
        var alone: [String: JSONValue] = [:]
        for path in paths { alone[path] = try await client.call("GET", path) }
        XCTAssertEqual(Set(alone.values.map { try? $0.data() }).count, paths.count, "seven different answers")
        for (place, path) in asked.enumerated() {
            XCTAssertEqual(try answers[place]?.data(), try alone[path]?.data(), "\(place) \(path)")
        }
        XCTAssertEqual(standIn.requests.count, 1 + asked.count + paths.count)
        XCTAssertEqual(standIn.arguments.count, 1, "one child, and so one connection")
        XCTAssertEqual(standIn.sockets, [])
        await child.stop()
    }

    func testARefusalCarriesTheSentence() async throws {
        let (standIn, child, client) = try await serving()
        let someID = "3f9d0c7a-0001-4b6e-9d1f-b2f400a1e000"
        await assertThrows(.refused("Premium status is required to use this feature.")) {
            _ = try await client.call("GET", "/object/totp/\(someID)")
        }
        XCTAssertEqual(standIn.requests.last, "GET /object/totp/\(someID) ")
        await child.stop()
    }

    func testABodyIsSentWhole() async throws {
        let (standIn, child, client) = try await serving()
        _ = try await client.call("PUT", "/object/item/abc", json: .object(["name": .string("İş")]))
        XCTAssertEqual(standIn.requests.last, #"PUT /object/item/abc {"name":"İş"}"#)
        await child.stop()
    }

    /// An answer that never comes. The call ends at its deadline, and the
    /// connection is of no more use: the answer, if it came late, would be
    /// read as the next request's. So the child is heard of as gone, and
    /// goes.
    func testAnAnswerThatNeverComesTimesOutAndEndsTheChild() async throws {
        let (standIn, child, client) = try await serving(deadline: 0.3)
        let pid = try XCTUnwrap(child.pid)
        let heard = expectation(description: "onExit")
        child.onExit = { heard.fulfill() }
        standIn.leave("mute")

        let started = Date()
        await assertThrows(.timeout) { _ = try await client.call("GET", "/status") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        await assertThrows(.transport) { _ = try await client.call("GET", "/status") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "the second did not wait for a deadline")
        await fulfillment(of: [heard], timeout: 1)
        let gone = await eventually(within: 1) { !isAlive(pid) }
        XCTAssertTrue(gone)
        XCTAssertEqual(standIn.left, [])
    }

    /// A child that closes its connection and does not exit is gone all
    /// the same: there is no other way to it.
    func testAConnectionTheChildClosedIsTheChildGone() async throws {
        let (standIn, child, client) = try await serving()
        let pid = try XCTUnwrap(child.pid)
        let heard = expectation(description: "onExit")
        child.onExit = { heard.fulfill() }
        standIn.leave("hang-up")

        await assertThrows(.transport) { _ = try await client.call("GET", "/status") }
        await fulfillment(of: [heard], timeout: 1)
        let gone = await eventually(within: 1) { !isAlive(pid) }
        XCTAssertTrue(gone, "it did not exit by itself, and was told to")
        XCTAssertEqual(standIn.left, [])
    }

    func testAConnectionThatWasShutAnswersNothingAndSaysNothing() async throws {
        let (_, child, client) = try await serving()
        child.onExit = { XCTFail("a stop is not the child dying by itself") }
        await child.stop()
        await assertThrows(.transport) { _ = try await client.call("GET", "/status") }
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    func testTheTwoStatesHaveTheirOwnErrors() async throws {
        // A stand-in nobody has unlocked is locked, and says so as `bw` does.
        let standIn = try StandIn()
        let child = standIn.child()
        try await child.start()
        let client = ServeClient(connection: try XCTUnwrap(child.connection))
        await assertThrows(.locked) { _ = try await client.call("GET", "/list/object/items") }
        await child.stop()

        func thrown(by fixture: String) -> VaultError? {
            let body = Fixture.data(fixture)
            let head = "HTTP/1.1 400 Bad Request\r\nContent-Length: \(body.count)\r\n\r\n"
            guard let response = try? ServeClient.parse(Data(head.utf8) + body),
                  let envelope = try? JSONValue(data: response.body) else { return nil }
            switch envelope["message"]?.string {
            case "You are not logged in.": return .loggedOut
            case "Vault is locked.": return .locked
            default: return nil
            }
        }
        XCTAssertEqual(thrown(by: "refused-logged-out"), .loggedOut)
        XCTAssertEqual(thrown(by: "refused-locked"), .locked)
    }

    /// What the real `bw` did to this app the first time it was asked
    /// (`docs/notes.md`, "`bw serve`"): a Host without the port is 403 and a
    /// word, and so is anything with an Origin.
    func testTheStandInAnswersOnlyTheHostsTheRealOneDoes() async throws {
        let (_, child, _) = try await serving()
        func asked(_ headers: String, of child: BwChild) async throws -> ServeClient.Response {
            try await XCTUnwrap(child.connection)
                .exchange(SecretBytes("GET /status HTTP/1.1\r\n\(headers)\r\n"), deadline: 2)
        }
        // gethostname, as node's and the stand-in's is: `ProcessInfo.hostName`
        // asks the resolver and takes half a minute over it.
        var buffer = [CChar](repeating: 0, count: 256)
        gethostname(&buffer, buffer.count)
        let name = String(cString: buffer).lowercased()
        for host in ["localhost:8087", "127.0.0.1:8087", "[::1]:8087", "LOCALHOST:8087", "\(name):8087"] {
            let answer = try await asked("Host: \(host)\r\n", of: child)
            XCTAssertEqual(answer.status, 200, host)
        }
        // Each refusal is followed by the next question on the same
        // connection, which the real one left open after a 403.
        for host in ["localhost", "127.0.0.1", "localhost:80", "localhost:8088", "evil.example", "evil.example:8087"] {
            let answer = try await asked("Host: \(host)\r\n", of: child)
            XCTAssertEqual(answer.status, 403, host)
            XCTAssertEqual(String(decoding: answer.body, as: UTF8.self), "Forbidden", host)
        }
        let withOrigin = try await asked("Host: localhost:8087\r\nOrigin: http://localhost:8087\r\n", of: child)
        XCTAssertEqual(withOrigin.status, 403)
        let after = try await asked("Host: localhost:8087\r\n", of: child)
        XCTAssertEqual(after.status, 200, "and it still answers")
        await child.stop()

        // No Host is 400 and the end of that connection, here.
        for headers in ["Host:\r\n", ""] {
            let (_, other, _) = try await serving()
            let answer = try await asked(headers, of: other)
            XCTAssertEqual(answer.status, 400, headers)
            await other.stop()
        }
    }

    func testEveryRequestNamesAHostTheRealOneAnswers() async throws {
        let (standIn, child, client) = try await serving()
        let status = try await client.call("GET", "/status")
        XCTAssertEqual(status["template"]?["status"]?.string, "unlocked")
        let sent = try await client.send("GET", "/generate", body: nil, type: "")
        XCTAssertEqual(sent.status, 200)
        XCTAssertEqual(standIn.arguments.last, ["serve", "--hostname", "fd+connected://3"],
                       "and the child is told no port and is not told to stop checking")
        await child.stop()
    }

    /// A `bw` whose rule has moved again: the child is up at once, and the
    /// first call says which status it was turned away with.
    func testARefusalWithNoEnvelopeIsNotASlowStartAndNamesItsStatus() async throws {
        let standIn = try StandIn(["host": "elsewhere:1"])
        kept.append(standIn)
        let child = standIn.child()
        let started = Date()
        try await child.start(readyWithin: 5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        let client = ServeClient(connection: try XCTUnwrap(child.connection), deadline: 5)
        await assertThrows(.turnedAway(403)) { _ = try await client.call("GET", "/status") }
        await assertThrows(.turnedAway(403)) {
            _ = try await client.call("POST", "/unlock", secret: SecretBytes(#"{"password":"demo"}"#))
        }
        await child.stop()
    }

    func testOnlyAnAnswerWithNoEnvelopeIsTurnedAway() throws {
        func thrown(_ status: String, _ body: String) -> VaultError? {
            let raw = Data("HTTP/1.1 \(status)\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
            do {
                _ = try ServeClient.envelope(of: try ServeClient.parse(raw))
                return nil
            } catch { return error as? VaultError }
        }
        XCTAssertEqual(thrown("403 Forbidden", "Forbidden"), .turnedAway(403))
        XCTAssertEqual(thrown("400 Bad Request", ""), .turnedAway(400))
        XCTAssertEqual(thrown("500 Internal Server Error", "<html>"), .turnedAway(500))
        XCTAssertEqual(thrown("200 OK", "not json"), .transport)
        XCTAssertNil(thrown("400 Bad Request", #"{"success":false,"message":"Vault is locked."}"#))
    }

    func testTheLogLineCarriesNoIdAndNoBody() {
        let uuid = "3f9d0c7a-0001-4b6e-9d1f-b2f400a1e000"
        let line = ServeClient.logLine("PUT", "/object/item/\(uuid)", status: 200, since: Date())
        XCTAssertTrue(line.hasPrefix("PUT /object/item/:id 200 "), line)
        XCTAssertFalse(line.contains(uuid))

        // The client is never handed anything but the path to write down, so
        // a body cannot reach the line; a search can, through the query.
        let search = ServeClient.logLine("GET", "/list/object/items?search=CANARY-1", status: 200,
                                         since: Date())
        XCTAssertFalse(search.contains("CANARY"))
        XCTAssertTrue(search.hasPrefix("GET /list/object/items 200 "), search)
        XCTAssertTrue(ServeClient.logLine("GET", "/object/template/item.login", status: nil, since: Date())
            .hasPrefix("GET /object/template/item.login failed "))
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
