import XCTest
@testable import OriPass

@MainActor
final class ServeBackendTests: XCTestCase {
    private var kept: [StandIn] = []

    private func backend(_ options: [String: Any] = [:]) throws -> (StandIn, ServeBackend) {
        let standIn = try StandIn(options.merging(["password": "demo"]) { asked, _ in asked })
        kept.append(standIn)
        return (standIn, ServeBackend(preferredPath: standIn.binary.path, runDirectory: standIn.run,
                                      dataDirectory: standIn.data))
    }

    /// The session in `Tests/Fixtures/unlock.json`, which the stand-in
    /// answers every unlock with, and the tour's canary for it.
    private static let session = DemoVault.session

    private func childIsGone(_ standIn: StandIn) -> Bool {
        standIn.left.isEmpty
    }

    func testAPasswordOpensAndListsAndIsTheOnlyWayBackIn() async throws {
        let (standIn, backend) = try backend()
        XCTAssertEqual((try Fixture.json("unlock"))["data"]?["raw"]?.string, Self.session)
        let typed = SecretBytes("demo")
        try await backend.unlock(password: typed)
        XCTAssertTrue(typed.isWiped)
        let unlocked = try await backend.items()
        XCTAssertEqual(unlocked.count, 8)

        await backend.close()
        XCTAssertTrue(childIsGone(standIn))
        do {
            _ = try await backend.items()
            XCTFail("listed with no child")
        } catch {
            XCTAssertEqual(error as? VaultError, .locked)
        }

        try await backend.unlock(password: SecretBytes("demo"))
        let reopened = try await backend.items()
        XCTAssertEqual(reopened.map(\.name), unlocked.map(\.name))
        XCTAssertEqual(standIn.requests.filter { $0.hasPrefix("POST /unlock") }.count, 2)
        XCTAssertEqual(standIn.arguments.filter { $0.first == "serve" }.count, 2, "a child for each")
        await backend.close()
    }

    /// D7, seen as another process of his would see it: with the vault
    /// open, `ps eww` prints the child's arguments and its environment,
    /// and neither holds the name of the variable, the session the unlock
    /// answered with or the password.
    func testAnOpenChildShowsNoSessionAndNoPasswordToPS() async throws {
        let password = "KNOWN-PASSWORD-\(UUID().uuidString)"
        let (standIn, backend) = try backend(["password": password])
        try await backend.unlock(password: SecretBytes(password))
        let listed = try await backend.items()
        XCTAssertEqual(listed.count, 8)
        let pid = try XCTUnwrap(pid_t(String(contentsOf: standIn.run.appendingPathComponent("child.pid"),
                                             encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))

        let seen = try PS.everything(of: pid)

        XCTAssertTrue(seen.contains("serve --hostname fd+connected://3"), "ps did list the child")
        XCTAssertTrue(seen.contains("BITWARDENCLI_APPDATA_DIR=\(standIn.data.path)"), "and its environment")
        XCTAssertFalse(seen.contains("BW_SESSION"))
        XCTAssertFalse(seen.contains(Self.session))
        XCTAssertFalse(seen.contains(password))
        XCTAssertFalse(ProcessArguments.of(pid)?.contains { $0.contains(password) || $0.contains(Self.session) } ?? true)
        await backend.close()
    }

    /// The unlock's answer is not read for a session: one with no `raw` in
    /// it opens the vault like any other.
    func testAnUnlockThatAnswersWithNoSessionStillOpens() async throws {
        let bare = try Fixture.changed("unlock") { object in
            var envelope = object["data"] as? [String: Any] ?? [:]
            envelope["raw"] = nil
            envelope["message"] = nil
            object["data"] = envelope
        }
        let standIn = try StandIn(["password": "demo"], changed: ["unlock": bare])
        kept.append(standIn)
        let backend = ServeBackend(preferredPath: standIn.binary.path, runDirectory: standIn.run,
                                   dataDirectory: standIn.data)
        try await backend.unlock(password: SecretBytes("demo"))
        let listed = try await backend.items()
        XCTAssertEqual(listed.count, 8)
        try await backend.confirm(password: SecretBytes("demo"))
        await backend.close()
    }

    func testAWrongPasswordIsRefusedInBwsOwnSentenceAndLeavesNoChild() async throws {
        let (standIn, backend) = try backend()
        do {
            try await backend.unlock(password: SecretBytes("nope"))
            XCTFail("unlocked")
        } catch {
            XCTAssertEqual(error as? VaultError, .refused("Cryptography error, The decryption operation failed"))
        }
        XCTAssertTrue(childIsGone(standIn))
    }

    /// The password asked for again (`Reprompt`) is a second `POST /unlock`
    /// to the child that is serving, and a wrong one shuts nothing.
    func testAPasswordAskedAgainIsJudgedByTheChildThatIsAlreadyServing() async throws {
        let (standIn, backend) = try backend()
        do {
            try await backend.confirm(password: SecretBytes("demo"))
            XCTFail("confirmed with no child")
        } catch {
            XCTAssertEqual(error as? VaultError, .locked)
        }
        try await backend.unlock(password: SecretBytes("demo"))

        let wrong = SecretBytes("nope")
        do {
            try await backend.confirm(password: wrong)
            XCTFail("confirmed a wrong password")
        } catch {
            XCTAssertEqual(error as? VaultError, .refused("Cryptography error, The decryption operation failed"))
        }
        XCTAssertTrue(wrong.isWiped)
        XCTAssertFalse(childIsGone(standIn), "the child that was serving still is")

        let right = SecretBytes("demo")
        try await backend.confirm(password: right)
        XCTAssertTrue(right.isWiped)
        XCTAssertEqual(standIn.requests.last, #"POST /unlock {"password":"demo"}"#)
        XCTAssertEqual(standIn.requests.filter { $0.hasPrefix("POST /unlock") }.count, 3)
        await backend.close()
    }

    /// "Lock and forget" on an open vault is `POST /lock` and then the
    /// child gone. With no child it starts nothing: there is no session
    /// anywhere for a `bw lock` to end.
    func testEndingTheSessionLocksAServingChildAndStartsNoneToDoIt() async throws {
        let (standIn, backend) = try backend()
        try await backend.unlock(password: SecretBytes("demo"))
        await backend.endSession()
        XCTAssertEqual(standIn.requests.last, "POST /lock ")
        XCTAssertTrue(childIsGone(standIn))

        let started = standIn.arguments.count
        await backend.endSession()
        XCTAssertEqual(standIn.arguments.count, started, "a bw was started to end a session nobody holds")
        XCTAssertEqual(standIn.requests.last, "POST /lock ")

        try await backend.unlock(password: SecretBytes("demo"))
        let listed = try await backend.items()
        XCTAssertEqual(listed.count, 8)
        await backend.close()
    }

    /// It has no template for a key, and says so in a sentence the store
    /// has to know, or ⌘N could not make one.
    func testAKeyIsMadeWithoutATemplateAsTheRealOneHasNone() async throws {
        let (_, backend) = try backend()
        do {
            try await backend.unlock(password: SecretBytes("demo"))
            _ = try await backend.template("item.sshkey")
            XCTFail("a template for a key")
        } catch {
            XCTAssertEqual(error as? VaultError, .refused("Unknown template object."))
        }
        await backend.close()

        let store = VaultStore(backend: backend)
        await store.unlock(password: SecretBytes("demo"))
        let blank = try await store.blank(.sshKey)
        XCTAssertEqual(blank.type, .sshKey)
        XCTAssertEqual(blank.raw["sshKey"], Item.keyPart)
        await store.lock()
    }

    func testThePasswordIsZerosOnceUnlockReturns() async throws {
        let (_, backend) = try backend()
        let right = SecretBytes("demo")
        try await backend.unlock(password: right)
        XCTAssertTrue(right.isWiped)
        XCTAssertEqual(right.count, 4)
        await backend.close()

        let wrong = SecretBytes("nope")
        _ = try? await backend.unlock(password: wrong)
        XCTAssertTrue(wrong.isWiped)
    }

    func testAPasswordWithAQuoteInItIsStillOneJSONString() async throws {
        let (standIn, backend) = try backend(["password": #"de"mo\ş"#])
        try await backend.unlock(password: SecretBytes(#"de"mo\ş"#))
        XCTAssertEqual(standIn.requests.last, #"POST /unlock {"password":"de\"mo\\ş"}"#)
        await backend.close()
    }

    // MARK: What 2026.9.1 said when it was written to

    private func refusal(_ work: () async throws -> Void) async -> VaultError? {
        do {
            try await work()
            return nil
        } catch {
            return error as? VaultError
        }
    }

    /// An account without Premium may not archive, and the store shows the
    /// engine's sentence for it and moves nothing.
    func testAFreeAccountIsRefusedTheArchiveInTheEnginesSentence() async throws {
        let (_, serve) = try backend(["free": true])
        let sentence = try XCTUnwrap(Fixture.json("refused-premium")["message"]?.string)
        XCTAssertEqual(sentence, FakeBackend.needsPremium)
        let store = VaultStore(backend: serve)
        await store.unlock(password: SecretBytes("demo"))
        await store.backgroundSync?.value
        let bank = try Fixture.item(named: "İş Bankası")

        let thrown = await refusal { try await store.apply(.archive, to: bank.id) }
        XCTAssertEqual(thrown, .refused(sentence))
        XCTAssertEqual(Panes.sentence(for: VaultError.refused(sentence)), sentence)
        XCTAssertEqual(store.entry(id: bank.id)?.item.isArchived, false)
        await store.lock()
    }

    /// `restore` is the way out of the trash and of nothing else that is
    /// known, and an item deleted for good is not found again.
    func testAnItemIsRestoredOnlyFromWhereItIsAndIsGoneWhenDeletedForGood() async throws {
        let (_, backend) = try backend()
        try await backend.unlock(password: SecretBytes("demo"))
        let bank = try Fixture.item(named: "İş Bankası")

        var thrown = await refusal { try await backend.restore(bank) }
        XCTAssertEqual(thrown, .refused("Cipher is not in trash."))
        try await backend.delete(bank, permanently: false)
        try await backend.restore(bank)
        thrown = await refusal { try await backend.restore(bank) }
        XCTAssertEqual(thrown, .refused("Cipher is not in trash."))

        try await backend.delete(bank, permanently: false)
        try await backend.delete(bank, permanently: true)
        thrown = await refusal { try await backend.restore(bank) }
        XCTAssertEqual(thrown, .refused("Not found."))
        await backend.close()
    }

    /// A write made from a copy older than the server's is refused in the
    /// server's whole answer, which the app knows and does not show.
    func testAWriteFromAnOldCopyIsRefusedAndKnownForWhatItIs() async throws {
        let (_, backend) = try backend()
        try await backend.unlock(password: SecretBytes("demo"))
        let bank = try Fixture.item(named: "İş Bankası")
        let sentence = try XCTUnwrap(Fixture.json("refused-out-of-date")["message"]?.string)
        XCTAssertEqual(sentence, FakeBackend.outOfDate)

        let old = bank.raw.setting(["revisionDate"], to: .string("2026-09-01T00:00:00.000Z"))
        let thrown = await refusal { _ = try await backend.save(bank, as: old) }
        XCTAssertEqual(thrown, .refused(sentence))
        XCTAssertTrue(Editor.isOutOfDate(sentence))
        XCTAssertEqual(Panes.sentence(for: VaultError.refused(sentence)), Editor.behind)

        // The copy it holds is taken, and comes back whole.
        let saved = try await backend.save(bank, as: bank.raw)
        XCTAssertEqual(saved.id, bank.id)
        XCTAssertEqual(saved.raw["key"]?.string?.count, 180)
        await backend.close()
    }

    func testEveryCallIsTheRouteTheNotesName() async throws {
        let (standIn, backend) = try backend()
        try await backend.unlock(password: SecretBytes("demo"))
        let before = standIn.requests.count
        let bank = try Fixture.item(named: "İş Bankası")
        let folder = Folder(id: "f-1", name: "Ev")

        _ = try await backend.status()
        try await backend.sync()
        _ = try await backend.items()
        _ = try await backend.trash()
        _ = try await backend.folders()
        let collections = try await backend.collections()
        XCTAssertEqual(collections.map(\.name), ["Ortak"])
        _ = try await backend.create(.object(["name": .string("Yeni"), "type": .int(2)]))
        _ = try await backend.save(bank, as: .object(["name": .string("İş")]))
        try await backend.delete(bank, permanently: false)
        try await backend.restore(bank)
        try await backend.archive(bank)
        try await backend.unarchive(bank)
        try await backend.delete(bank, permanently: true)
        _ = try await backend.createFolder(named: "Yeni")
        _ = try await backend.rename(folder, to: "Yuva")
        try await backend.delete(folder)
        _ = try await backend.generate(.random(length: 24, digits: true, symbols: false))
        await backend.endSession()

        XCTAssertEqual(Array(standIn.requests.dropFirst(before)), [
            "GET /status ",
            "POST /sync ",
            "GET /list/object/items ",
            "GET /list/object/items?trash=true ",
            "GET /list/object/folders ",
            "GET /list/object/collections ",
            #"POST /object/item {"name":"Yeni","type":2}"#,
            #"PUT /object/item/\#(bank.id) {"name":"İş"}"#,
            "DELETE /object/item/\(bank.id) ",
            "POST /restore/item/\(bank.id) ",
            "POST /archive/item/\(bank.id) ",
            "POST /restore/item/\(bank.id) ",
            "DELETE /object/item/\(bank.id)?permanent=true ",
            #"POST /object/folder {"name":"Yeni"}"#,
            #"PUT /object/folder/f-1 {"name":"Yuva"}"#,
            "DELETE /object/folder/f-1 ",
            "GET /generate?length=24&uppercase=true&lowercase=true&number=true ",
            "POST /lock ",
        ])
        XCTAssertTrue(childIsGone(standIn))
    }

    /// An id is whatever the server's answer held, and it goes into the
    /// request line. One with a space and a line's end in it is a second
    /// request of the server's own writing to a child that has the vault
    /// open, and one with a question mark rewrites the query.
    func testAnIdThatIsNotOneWordNeverReachesTheWire() async throws {
        let (standIn, backend) = try backend()
        try await backend.unlock(password: SecretBytes("demo"))
        let bank = try Fixture.item(named: "İş Bankası")
        let second = "x HTTP/1.1\r\nHost: localhost:8087\r\n\r\nDELETE /object/item/\(bank.id)?permanent=true&z="
        let before = standIn.requests.count

        for id in [second, "abc?permanent=true", "a b", "a/b", "a%20b", "é", ""] {
            let odd = try Item(json: try XCTUnwrap(bank.raw.setting(["id"], to: .string(id))))
            let file = Attachment(json: .object(["id": .string(id), "fileName": .string("a.txt")]))
            let place = FileManager.default.temporaryDirectory.appendingPathComponent("oripass-test-\(UUID().uuidString)")
            let asked: [(String, () async throws -> Void)] = [
                ("save", { _ = try await backend.save(odd, as: .object(["name": .string("x")])) }),
                ("delete", { try await backend.delete(odd, permanently: false) }),
                ("restore", { try await backend.restore(odd) }),
                ("archive", { try await backend.archive(odd) }),
                ("unarchive", { try await backend.unarchive(odd) }),
                ("fetch by item", { try await backend.fetch(Attachment(json: .object(["id": .string("a-1")])), of: odd, to: place) }),
                ("fetch by file", { try await backend.fetch(file, of: bank, to: place) }),
                ("attach", { _ = try await backend.attach(standIn.binary, to: odd) }),
                ("rename", { _ = try await backend.rename(Folder(id: id, name: "Ev"), to: "Yuva") }),
                ("delete folder", { try await backend.delete(Folder(id: id, name: "Ev")) }),
            ]
            for (name, ask) in asked {
                do {
                    try await ask()
                    XCTFail("\(name) was sent with the id \(id.debugDescription)")
                } catch {
                    XCTAssertEqual(error as? VaultError, .refused(ServeBackend.oddID), "\(name), \(id.debugDescription)")
                }
            }
        }
        XCTAssertEqual(Array(standIn.requests.dropFirst(before)), [], "something of it reached the engine")

        // The connection is as it was, and an id of the usual kind goes.
        try await backend.delete(bank, permanently: false)
        XCTAssertEqual(standIn.requests.last, "DELETE /object/item/\(bank.id) ")
        await backend.close()
    }

    /// The last line of defence, whoever builds the path.
    func testARequestLineWithASpaceOrALinesEndInItIsNotWritten() async throws {
        let standIn = try StandIn(["unlocked": true])
        kept.append(standIn)
        let child = standIn.child()
        try await child.start()
        let client = ServeClient(connection: try XCTUnwrap(child.connection), deadline: 5)
        let before = standIn.requests.count
        for path in ["/status HTTP/1.1\r\nHost: localhost:8087\r\n\r\nPOST /lock", "/sta tus", "/status\n", "/st\u{7F}atus", "status"] {
            do {
                _ = try await client.send("GET", path, body: nil, type: "")
                XCTFail("sent \(path.debugDescription)")
            } catch {
                XCTAssertEqual(error as? VaultError, .refused(ServeBackend.oddID))
            }
        }
        XCTAssertEqual(Array(standIn.requests.dropFirst(before)), [])
        let answer = try await client.call("GET", "/status")
        XCTAssertEqual(answer["template"]?["status"]?.string, "unlocked")
        await child.stop()
    }

    /// `bw` takes a third of a second to come up, and longer on a cold
    /// start. A lock in that time has to reach the child that is coming.
    func testClosingWhileTheChildIsStillComingUpStopsItAndTheUnlockOpensNothing() async throws {
        let (standIn, backend) = try backend(["slow": 0.6])
        let opening = Task { try await backend.unlock(password: SecretBytes("demo")) }
        let isBorn = await eventually(within: 5) { !standIn.left.isEmpty }
        XCTAssertTrue(isBorn, "no child was started")

        await backend.close()
        do {
            try await opening.value
            XCTFail("the unlock went on after the close")
        } catch {
            XCTAssertEqual(error as? VaultError, .locked)
        }
        let isGone = await eventually(within: 5) { self.childIsGone(standIn) }
        XCTAssertTrue(isGone, "the child that was coming up outlived the close")
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertFalse(standIn.requests.contains { $0.hasPrefix("POST /unlock") }, "the password was still sent")
        do {
            _ = try await backend.items()
            XCTFail("listed after the close")
        } catch {
            XCTAssertEqual(error as? VaultError, .locked)
        }
    }

    /// The same through the store, which is where a lock comes from.
    func testALockWhileBwIsStillStartingLeavesNoChildAndNoOpenVault() async throws {
        let (standIn, backend) = try backend(["slow": 0.6])
        let store = VaultStore(backend: backend)
        let opening = Task { await store.unlock(password: SecretBytes("demo")) }
        let isBorn = await eventually(within: 5) { !standIn.left.isEmpty }
        XCTAssertTrue(isBorn)
        XCTAssertEqual(store.state, .unlocking)

        await store.lock()
        let opened = await opening.value
        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertFalse(opened)
        XCTAssertEqual(store.state, .locked)
        XCTAssertNil(store.refusal)
        XCTAssertTrue(store.shelves.all.isEmpty)
        let isGone = await eventually(within: 5) { self.childIsGone(standIn) }
        XCTAssertTrue(isGone, "a child is serving behind the lock")
        XCTAssertFalse(standIn.requests.contains { $0.hasPrefix("GET /list") }, "the vault was read after the lock")
    }

    func testAWriteAnswersWithTheItemReadBackOut() async throws {
        let (_, backend) = try backend()
        try await backend.unlock(password: SecretBytes("demo"))
        let bank = try Fixture.item(named: "İş Bankası")
        let saved = try await backend.save(bank, as: try XCTUnwrap(bank.patched(bank)))
        XCTAssertEqual(saved.id, bank.id)
        XCTAssertEqual(saved.login?.username, "deniz.yilmaz")
        await backend.close()
    }

    func testAFilesNameGoesBetweenTheQuotesWhateverIsInIt() async throws {
        let (standIn, backend) = try backend()
        try await backend.unlock(password: SecretBytes("demo"))
        let bank = try Fixture.item(named: "İş Bankası")
        let directory = standIn.directory.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let before = standIn.requests.count
        for name in ["sözleşme.txt", #"the "signed" one.txt"#, #"back\slash.txt"#, "two\r\nlines.txt"] {
            let file = directory.appendingPathComponent(name)
            try Data("invented".utf8).write(to: file)
            XCTAssertEqual(file.lastPathComponent, name)
            let item = try await backend.attach(file, to: bank)
            XCTAssertEqual(item.id, bank.id, "the stand-in refuses a part whose head it cannot read")
        }
        XCTAssertEqual(Array(standIn.requests.dropFirst(before)), [
            "POST /attachment?itemid=\(bank.id) file sözleşme.txt",
            "POST /attachment?itemid=\(bank.id) file the %22signed%22 one.txt",
            "POST /attachment?itemid=\(bank.id) file back%5Cslash.txt",
            "POST /attachment?itemid=\(bank.id) file two%0D%0Alines.txt",
        ])
        await backend.close()
    }

    func testTheGeneratorsQueries() {
        XCTAssertEqual(ServeBackend.query(for: .random(length: 20, digits: false, symbols: true)),
                       "length=20&uppercase=true&lowercase=true&special=true")
        XCTAssertEqual(ServeBackend.query(for: .memorable(words: 4, separator: "-", capitals: true, number: true)),
                       "passphrase=true&words=4&separator=-&capitalize=true&includeNumber=true")
        XCTAssertEqual(ServeBackend.query(for: .memorable(words: 3, separator: " ", capitals: false, number: false)),
                       "passphrase=true&words=3&separator=%20")
        XCTAssertEqual(ServeBackend.query(for: .pin(digits: 6)), "length=6&number=true")
    }

    func testStatusWithNoChildAsksBwItself() async throws {
        let (standIn, backend) = try backend()
        let locked = try await backend.status()
        XCTAssertEqual(locked.state, .locked)
        XCTAssertEqual(locked.email, "deniz@example.com")
        XCTAssertNotNil(locked.lastSync)
        XCTAssertTrue(standIn.requests.isEmpty, "nothing was served to answer that")

        let (_, loggedOut) = try self.backend(["loggedOut": true])
        let status = try await loggedOut.status()
        XCTAssertEqual(status.state, .loggedOut)
        do {
            try await loggedOut.unlock(password: SecretBytes("demo"))
            XCTFail("unlocked with no account")
        } catch {
            XCTAssertEqual(error as? VaultError, .loggedOut)
        }

        let nowhere = ServeBackend(preferredPath: "/nowhere/bw",
                                   finder: { BwBinary.find(preferred: $0, fallback: nil, path: "") },
                                   runDirectory: standIn.run, dataDirectory: standIn.data)
        let none = try await nowhere.status()
        XCTAssertEqual(none.state, .noCLI)
    }

    func testBwDyingIsHeardOnce() async throws {
        let (_, backend) = try backend(["exitAfter": 0.4])
        let lost = expectation(description: "onEngineLost")
        backend.onEngineLost = { lost.fulfill() }
        try await backend.unlock(password: SecretBytes("demo"))
        await fulfillment(of: [lost], timeout: 2)
        do {
            _ = try await backend.items()
            XCTFail("listed from a dead child")
        } catch {
            XCTAssertEqual(error as? VaultError, .locked)
        }
    }

    // MARK: What the last run left

    /// What the app does as it launches, before any unlock: a `bw` the
    /// last run left serving, with its pid written down, is killed.
    func testAChildTheLastRunLeftIsKilledBeforeAnyUnlock() async throws {
        let (standIn, backend) = try backend()
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
        let serving = await eventually(within: 3) {
            ProcessArguments.of(orphan.processIdentifier)?.contains("fd+connected://3") == true
        }
        XCTAssertTrue(serving)

        backend.clearLeftovers()

        let gone = await eventually(within: 1) { !orphan.isRunning }
        XCTAssertTrue(gone)
        XCTAssertEqual(standIn.left, [])
    }

    /// Asked while the vault is open, it leaves the child that holds it.
    func testTheCleanupLeavesTheBackendsOwnChild() async throws {
        let (standIn, backend) = try backend()
        try await backend.unlock(password: SecretBytes("demo"))
        XCTAssertEqual(standIn.left, ["child.pid"])

        backend.clearLeftovers()

        XCTAssertEqual(standIn.left, ["child.pid"])
        let listed = try await backend.items()
        XCTAssertEqual(listed.count, 8)
        await backend.close()
    }

    // MARK: One connection

    /// A store over the stand-in, open, with the sync that follows an
    /// unlock behind it, and a deadline short enough to wait out.
    private func openStore(_ options: [String: Any] = [:]) async throws -> (StandIn, VaultStore) {
        let standIn = try StandIn(options.merging(["password": "demo"]) { asked, _ in asked })
        kept.append(standIn)
        let store = VaultStore(backend: ServeBackend(preferredPath: standIn.binary.path, runDirectory: standIn.run,
                                                     dataDirectory: standIn.data, deadline: 0.3))
        let opened = await store.unlock(password: SecretBytes("demo"))
        XCTAssertTrue(opened)
        await store.sync()
        XCTAssertEqual(store.state, .unlocked)
        XCTAssertEqual(standIn.left, ["child.pid"])
        XCTAssertEqual(standIn.sockets, [], "open, and no socket file anywhere")
        return (standIn, store)
    }

    /// There is one connection, so an answer that never comes is the end
    /// of the engine: the call returns at its deadline, the vault shuts
    /// and the lock screen says why.
    func testAnAnswerThatNeverComesEndsInTheStoreLockedAndNotInAHang() async throws {
        let (standIn, store) = try await openStore()
        standIn.leave("mute")

        let started = Date()
        await store.sync()
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "the sync came back")
        let locked = await eventually(within: 2) { store.state == .locked && store.refusal != nil }
        XCTAssertTrue(locked)
        XCTAssertEqual(store.refusal, "The engine stopped answering.")
        XCTAssertTrue(store.shelves.all.isEmpty)
        let gone = await eventually(within: 1) { standIn.left.isEmpty }
        XCTAssertTrue(gone, "and the child that would not answer is gone")
    }

    func testAConnectionTheChildClosedLocksTheStoreWithASentence() async throws {
        let (standIn, store) = try await openStore()
        standIn.leave("hang-up")

        await store.sync()
        let locked = await eventually(within: 2) { store.state == .locked && store.refusal != nil }
        XCTAssertTrue(locked)
        XCTAssertEqual(store.refusal, "The engine stopped answering.")
        XCTAssertTrue(store.shelves.all.isEmpty)
        let gone = await eventually(within: 1) { standIn.left.isEmpty }
        XCTAssertTrue(gone, "a child that closed its connection and stayed is told to go")
    }

    func testAChildThatDiesLocksTheStoreWithASentence() async throws {
        let (standIn, store) = try await openStore(["exitAfter": 1.0])
        let locked = await eventually(within: 3) { store.state == .locked && store.refusal != nil }
        XCTAssertTrue(locked)
        XCTAssertEqual(store.refusal, "The engine stopped answering.")
        XCTAssertEqual(standIn.left, [])
    }

    /// A lock of one's own says nothing, and neither does the next unlock.
    func testALockOfOnesOwnSaysNothing() async throws {
        let (standIn, store) = try await openStore()
        await store.lock()
        XCTAssertEqual(store.state, .locked)
        XCTAssertNil(store.refusal)
        XCTAssertEqual(standIn.left, [])
        XCTAssertEqual(standIn.sockets, [])
    }
}
