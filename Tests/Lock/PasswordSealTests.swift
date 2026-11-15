import CryptoKit
import LocalAuthentication
import XCTest
@testable import OriPass

/// The master password kept for a finger: what is written, what opens it,
/// and every way it ends. The enclave is a fake throughout, except where the question
/// is what the real one writes.
@MainActor
final class PasswordSealTests: XCTestCase {
    private static let known = "KNOWN-PASSWORD-b3Vq81LmZx0pTt"

    private var directory: URL!
    private var enclave: FakeEnclave!
    private var defaults: UserDefaults!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oripass-seal-tests-\(UUID().uuidString)")
        enclave = FakeEnclave()
        let suite = "oripass-seal-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func seal(over enclave: Enclave? = nil) -> PasswordSeal {
        PasswordSeal(directory: directory, enclave: enclave ?? self.enclave, now: { self.clock })
    }

    private func files() throws -> [String: Data] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [:] }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return try Dictionary(uniqueKeysWithValues: names.map {
            ($0, try Data(contentsOf: directory.appendingPathComponent($0)))
        })
    }

    private func days(_ count: Double) -> TimeInterval { count * 24 * 60 * 60 }

    /// The demo vault behind a door that has a finger. The door is in front
    /// unless the test says otherwise.
    private func door(inFront: @escaping () -> Bool = { true }) -> (FakeBackend, VaultStore, Door) {
        let backend = DemoVault.backend()
        // Synced a minute ago, so no sync is running behind the unlock.
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        return (backend, store, Door(store: store, seal: seal(), defaults: defaults, isInFront: inFront))
    }

    /// Long enough for a sheet the door raised by itself to have been
    /// answered and the store to have opened.
    private func turn(_ seconds: Double = 0.1) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// The password, and yes to the question.
    private func unlockAndSeal(_ door: Door) async {
        await door.unlock(with: SecretBytes(DemoVault.password)).value
        door.answerFingerOffer(true)
    }

    // MARK: The two files

    func testASealedPasswordComesBackUnderTheReasonTheSheetShows() throws {
        let seal = seal()
        XCTAssertEqual(seal.standing, .none)

        try seal.seal(SecretBytes(Self.known))

        XCTAssertEqual(seal.standing, .ready)
        XCTAssertTrue(try seal.unseal().matches(SecretBytes(Self.known)))
        XCTAssertEqual(enclave.asked, ["unlock OriPass"])
    }

    func testItIsTwoFilesOnlyTheirOwnerCanRead() throws {
        try seal().seal(SecretBytes(Self.known))

        XCTAssertEqual(Set(try files().keys), ["key", "password"])
        let files = FileManager.default
        XCTAssertEqual(try files.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o700)
        for name in ["key", "password"] {
            let path = directory.appendingPathComponent(name).path
            XCTAssertEqual(try files.attributesOfItem(atPath: path)[.posixPermissions] as? Int, 0o600)
        }
    }

    func testTheDateIsBesideTheSealInTheClear() throws {
        try seal().seal(SecretBytes(Self.known))

        let written = try JSONValue(data: try XCTUnwrap(try files()["password"]))
        XCTAssertEqual(written["made"]?.int, Int(clock.timeIntervalSince1970))
    }

    /// The secret as it is, and under base64 wherever in a run of three
    /// bytes it begins: the middle of each encoding, which is the same
    /// whatever stands before the secret and after it.
    private static func forms(of secret: String) -> [Data] {
        let plain = Data(secret.utf8)
        return [plain] + (0..<3).map { shift in
            let coded = (Data(count: shift) + plain).base64EncodedString()
            return Data(coded.dropFirst(shift == 0 ? 0 : 4).dropLast(4).utf8)
        }
    }

    private func holders(of secret: String) throws -> [String] {
        try files().filter { _, bytes in Self.forms(of: secret).contains { bytes.range(of: $0) != nil } }
            .keys.sorted()
    }

    private func assertNoFileHolds(_ secret: String, file: StaticString = #filePath,
                                   line: UInt = #line) throws {
        XCTAssertEqual(try files().count, 2, file: file, line: line)
        XCTAssertEqual(try holders(of: secret), [], "the password is in a file in the clear",
                       file: file, line: line)
    }

    func testNeitherFileHoldsThePasswordInTheClear() throws {
        try seal().seal(SecretBytes(Self.known))

        try assertNoFileHolds(Self.known)
    }

    /// An enclave that seals nothing, so that the search above is seen to
    /// find a password: in the box as it is, which the file writes under
    /// base64 with the bytes of a tag after it.
    private struct NoEnclave: Enclave {
        var hasFinger: Bool { true }
        var fingerprints: Data? { nil }

        func seal(_ secret: SecretBytes, beside plain: Data) throws -> EnclaveSeal {
            EnclaveSeal(key: Data("key".utf8), encapsulated: Data("e".utf8),
                        box: secret.withBytes { Data($0) } + Data(repeating: 7, count: 16))
        }

        func open(_ sealed: EnclaveSeal, beside plain: Data, reason: String, on context: LAContext?) throws -> SecretBytes {
            SecretBytes(sealed.box.dropLast(16))
        }

        func withdraw() {}
    }

    func testTheSearchFindsAPasswordThatWasNotSealed() throws {
        for lead in ["", "x", "xy"] {
            try seal(over: NoEnclave()).seal(SecretBytes(lead + Self.known))
            XCTAssertEqual(try holders(of: Self.known), ["password"], "after \(lead.count) bytes")
        }
        try Data(Self.known.utf8).write(to: directory.appendingPathComponent("key"))
        XCTAssertEqual(try holders(of: Self.known), ["key", "password"])
    }

    /// The same search over what the real enclave writes. Sealing asks for
    /// nothing; nothing here opens it, which would raise the sheet.
    func testNeitherFileOfTheRealEnclaveHoldsThePasswordInTheClear() throws {
        try Screen.skipIfLocked("that what the real enclave writes holds no password in the clear")
        let real = TouchIDEnclave()
        // -4 is a shut lid: the sensor is under it, and Touch ID is enrolled all the same.
        try XCTSkipUnless(real.hasFinger, "the real enclave has no finger to ask now (\(real.refusal ?? "no reason"))")
        let seal = seal(over: real)

        try seal.seal(SecretBytes(Self.known))

        XCTAssertEqual(seal.standing, .ready)
        try assertNoFileHolds(Self.known)
        // The mark of the enrolled fingers is there, and is the same when
        // asked again, or every seal would be taken for an orphan.
        let mark = try XCTUnwrap(real.fingerprints)
        XCTAssertFalse(mark.isEmpty)
        XCTAssertEqual(real.fingerprints, mark)
        let written = try JSONValue(data: try XCTUnwrap(try files()["password"]))
        XCTAssertEqual(written["fingers"]?.string, mark.base64EncodedString())
    }

    func testSealingAgainReplacesWhatWasSealed() throws {
        let seal = seal()
        try seal.seal(SecretBytes("the-first-password"))
        try seal.seal(SecretBytes(Self.known))

        XCTAssertTrue(try seal.unseal().matches(SecretBytes(Self.known)))
        XCTAssertEqual(try files().count, 2)
    }

    func testForgetDeletesBothFiles() throws {
        let seal = seal()
        try seal.seal(SecretBytes(Self.known))

        seal.forget()

        XCTAssertEqual(seal.standing, .none)
        XCTAssertTrue(try files().isEmpty)
        XCTAssertThrowsError(try seal.unseal())
    }

    // MARK: What refuses

    func testAChangedSetOfFingerprintsRefuses() throws {
        let seal = seal()
        try seal.seal(SecretBytes(Self.known))

        enclave.enrolAnotherFinger()

        XCTAssertThrowsError(try seal.unseal())
        XCTAssertEqual(seal.standing, .orphaned)
    }

    /// With the lid shut there is no saying which fingers are enrolled,
    /// and that is not a reason to delete a seal.
    func testAnEnclaveThatCannotSayWhichFingersLeavesTheSealReady() throws {
        let seal = seal()
        try seal.seal(SecretBytes(Self.known))

        enclave.hasFinger = false

        XCTAssertEqual(seal.standing, .ready)
    }

    // MARK: A seal from before

    /// What the build before this one left: a key, and a `session` file
    /// holding a sealed session. Made over that directory, a seal deletes
    /// both without asking the enclave anything.
    private func leaveAnOldSeal() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("an enclave key".utf8).write(to: directory.appendingPathComponent("key"))
        try Data(#"{"made":1800000000,"encapsulated":"AAAA","box":"AAAA"}"#.utf8)
            .write(to: directory.appendingPathComponent("session"))
    }

    func testASealOfASessionIsDeletedUnopened() throws {
        try leaveAnOldSeal()

        let seal = seal()

        XCTAssertTrue(try files().isEmpty)
        XCTAssertEqual(seal.standing, .none)
        XCTAssertTrue(enclave.asked.isEmpty)
    }

    func testAfterAnOldSealTheLockScreenHasTheFieldAndTheNextPasswordSealsUnasked() async throws {
        try leaveAnOldSeal()
        // He said yes to the finger when that seal was made.
        Preferences(defaults: defaults).settings.lock.unlockWithFinger = true
        let (backend, store, door) = door()

        XCTAssertFalse(door.hasSeal, "the lock screen would draw the fingerprint")
        door.lockScreenAppeared()
        try await turn()
        XCTAssertTrue(enclave.asked.isEmpty, "a sheet was raised for a seal that is gone")
        XCTAssertEqual(store.state, .locked)

        await door.unlock(with: SecretBytes(DemoVault.password)).value

        XCTAssertEqual(store.state, .unlocked)
        XCTAssertFalse(door.isOfferingFinger, "asked again")
        XCTAssertTrue(door.hasSeal)
        XCTAssertEqual(Set(try files().keys), ["key", "password"])
        XCTAssertTrue(try seal().unseal().matches(SecretBytes(DemoVault.password)))
        XCTAssertEqual(backend.count(of: "unlock"), 1)
    }

    func testACancelledSheetRefusesAndTheNextFingerOpens() throws {
        let seal = seal()
        try seal.seal(SecretBytes(Self.known))

        enclave.cancels = true
        XCTAssertThrowsError(try seal.unseal())
        enclave.cancels = false

        XCTAssertTrue(try seal.unseal().matches(SecretBytes(Self.known)))
    }

    /// The date is not hidden, so it is bound: moved by a day, the seal no
    /// longer opens.
    func testAMovedDateRefuses() throws {
        let seal = seal()
        try seal.seal(SecretBytes(Self.known))
        let file = directory.appendingPathComponent("password")
        let written = try JSONValue(data: try Data(contentsOf: file))
        let made = try XCTUnwrap(written["made"]?.int)
        let moved = written.setting(["made"], to: .int(Int64(made + Int(days(1)))))
        try moved.data().write(to: file)

        XCTAssertEqual(seal.standing, .ready)
        XCTAssertThrowsError(try seal.unseal())
    }

    /// The mark of the fingers is not hidden either, and is bound the same
    /// way: changed or taken out, so that an orphan would read as ready,
    /// the seal no longer opens.
    func testAMovedMarkOfTheFingersRefuses() throws {
        let seal = seal()
        let file = directory.appendingPathComponent("password")
        for change in ["another", "none"] {
            try seal.seal(SecretBytes(Self.known))
            let written = try JSONValue(data: try Data(contentsOf: file))
            XCTAssertEqual(written["fingers"]?.string, enclave.fingerprints?.base64EncodedString())
            guard case .object(var fields) = written else { return XCTFail("no object") }
            fields["fingers"] = change == "another" ? .string(Data("set 7".utf8).base64EncodedString()) : nil
            try JSONValue.object(fields).data().write(to: file)

            XCTAssertThrowsError(try seal.unseal(), change) {
                XCTAssertEqual($0 as? FakeEnclave.Refusal, .tampered, change)
            }
        }
    }

    /// What the build of 940534f wrote: the same two files, with the date
    /// bound and the mark of the fingers only beside it.
    private func leaveASealThatBoundOnlyTheDate() throws {
        let made = Int(clock.timeIntervalSince1970)
        let sealed = try enclave.seal(SecretBytes(DemoVault.password), beside: Data(String(made).utf8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try sealed.key.write(to: directory.appendingPathComponent("key"))
        let written: [String: Any] = [
            "made": made, "encapsulated": sealed.encapsulated.base64EncodedString(),
            "box": sealed.box.base64EncodedString(),
            "fingers": try XCTUnwrap(enclave.fingerprints).base64EncodedString(),
        ]
        try JSONSerialization.data(withJSONObject: written).write(to: directory.appendingPathComponent("password"))
    }

    func testASealThatBoundOnlyTheDateIsDeletedUnopened() throws {
        try leaveASealThatBoundOnlyTheDate()

        let seal = seal()

        XCTAssertEqual(seal.standing, .none)
        XCTAssertTrue(try files().isEmpty)
        XCTAssertThrowsError(try seal.unseal())
        XCTAssertTrue(enclave.asked.isEmpty)
    }

    /// And one put there after the seal was made over the directory, or
    /// any file that is not a seal: nothing, and no finger is asked.
    func testAFileThatIsNoSealOfThisFormIsNoSeal() throws {
        let seal = seal()
        try leaveASealThatBoundOnlyTheDate()
        XCTAssertEqual(seal.standing, .none)
        XCTAssertThrowsError(try seal.unseal())

        try Data("not json".utf8).write(to: directory.appendingPathComponent("password"))
        XCTAssertEqual(seal.standing, .none)
        XCTAssertThrowsError(try seal.unseal())
        XCTAssertTrue(enclave.asked.isEmpty)
    }

    func testAfterASealThatBoundOnlyTheDateTheNextPasswordSealsUnasked() async throws {
        try leaveASealThatBoundOnlyTheDate()
        Preferences(defaults: defaults).settings.lock.unlockWithFinger = true
        let (_, store, door) = door()

        XCTAssertFalse(door.hasSeal)
        door.lockScreenAppeared()
        try await turn()
        XCTAssertTrue(enclave.asked.isEmpty)
        XCTAssertEqual(store.state, .locked)

        await door.unlock(with: SecretBytes(DemoVault.password)).value
        XCTAssertFalse(door.isOfferingFinger, "asked again")
        XCTAssertTrue(door.hasSeal)
        await store.lock()
        try await turn()
        XCTAssertEqual(store.state, .unlocked, "the finger did not open the seal made again")
    }

    func testItExpiresAtFourteenDaysAndNotAtThirteen() throws {
        let seal = seal()
        try seal.seal(SecretBytes(Self.known))
        let made = clock

        clock = made.addingTimeInterval(days(13))
        XCTAssertEqual(seal.standing, .ready)
        clock = made.addingTimeInterval(days(14) - 1)
        XCTAssertEqual(seal.standing, .ready)
        clock = made.addingTimeInterval(days(14))
        XCTAssertEqual(seal.standing, .expired)
    }

    // MARK: Through the door

    func testHeIsAskedOnceAndYesSealsThePassword() async throws {
        let (_, store, door) = door()
        XCTAssertFalse(door.hasSeal)

        await door.unlock(with: SecretBytes(DemoVault.password)).value
        XCTAssertTrue(door.isOfferingFinger)
        XCTAssertTrue(try files().isEmpty, "sealed before he said yes")

        door.answerFingerOffer(true)
        XCTAssertFalse(door.isOfferingFinger)
        XCTAssertTrue(door.hasSeal)
        try assertNoFileHolds(DemoVault.password)
        XCTAssertTrue(try seal().unseal().matches(SecretBytes(DemoVault.password)))

        // In front, so the lock raises the sheet by itself and the fake's
        // finger is already on it.
        await store.lock()
        try await turn()
        XCTAssertEqual(store.state, .unlocked)
        await store.lock()
        try await turn()
        await store.lock(forget: true)
        await door.unlock(with: SecretBytes(DemoVault.password)).value
        XCTAssertFalse(door.isOfferingFinger, "asked a second time")
    }

    func testNoMeansNoFilesAndNoSecondQuestion() async throws {
        let (_, store, door) = door()
        await door.unlock(with: SecretBytes(DemoVault.password)).value

        door.answerFingerOffer(false)

        XCTAssertFalse(door.hasSeal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        await store.lock()
        await door.unlock(with: SecretBytes(DemoVault.password)).value
        XCTAssertFalse(door.isOfferingFinger)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testALockBeforeTheAnswerSealsNothingAndTheQuestionComesBack() async throws {
        let (_, store, door) = door()
        await door.unlock(with: SecretBytes(DemoVault.password)).value

        await store.lock()
        XCTAssertFalse(door.isOfferingFinger)
        door.answerFingerOffer(true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        await door.unlock(with: SecretBytes(DemoVault.password)).value
        XCTAssertTrue(door.isOfferingFinger)
    }

    func testWithNoFingerToAskNothingIsOffered() async throws {
        enclave.hasFinger = false
        let (_, _, door) = door()

        await door.unlock(with: SecretBytes(DemoVault.password)).value

        XCTAssertFalse(door.isOfferingFinger)
    }

    func testAFingerOpensTheVaultWithoutThePassword() async throws {
        let (backend, store, door) = door(inFront: { false })
        await unlockAndSeal(door)
        await store.lock()
        XCTAssertEqual(store.state, .locked)

        await door.askForFinger().value

        XCTAssertEqual(store.state, .unlocked)
        XCTAssertNotNil(door.panes)
        XCTAssertFalse(store.shelves.all.isEmpty)
        // The engine is sent the password again: there is no other way in.
        XCTAssertEqual(backend.count(of: "unlock"), 2)
        XCTAssertEqual(enclave.asked, [PasswordSeal.reason])
    }

    /// What is sealed is a copy of what was typed, and the copy is wiped
    /// once it is in the box: with the question unanswered it is held, and
    /// a lock wipes it.
    func testThePasswordHeldForTheQuestionIsWipedByTheLock() async throws {
        let (_, store, door) = door()
        await door.unlock(with: SecretBytes(DemoVault.password)).value
        let held = try XCTUnwrap(door.heldForTheQuestion)
        XCTAssertTrue(held.matches(SecretBytes(DemoVault.password)))

        await store.lock()

        XCTAssertTrue(held.isWiped)
        XCTAssertNil(door.heldForTheQuestion)
    }

    func testAPasswordTheEngineRefusedIsNotSealed() async throws {
        Preferences(defaults: defaults).settings.lock.unlockWithFinger = true
        let (_, store, door) = door()

        await door.unlock(with: SecretBytes("not-the-password")).value

        XCTAssertEqual(store.state, .locked)
        XCTAssertFalse(door.hasSeal)
        XCTAssertTrue(try files().isEmpty)
    }

    func testTheSheetRaisesItselfWhenTheLockScreenAppearsInFront() async throws {
        let (_, store, door) = door()
        await unlockAndSeal(door)

        await store.lock()
        try await turn()

        XCTAssertEqual(enclave.asked.count, 1)
        XCTAssertEqual(store.state, .unlocked)
    }

    func testBehindAnotherAppTheSheetWaitsUntilTheAppIsInFront() async throws {
        var inFront = false
        let (_, store, door) = door(inFront: { inFront })
        await unlockAndSeal(door)

        await store.lock()
        try await turn()
        door.raiseFingerIfOwed()
        try await turn()
        XCTAssertTrue(enclave.asked.isEmpty)
        XCTAssertEqual(store.state, .locked)

        inFront = true
        door.raiseFingerIfOwed()
        try await turn()
        XCTAssertEqual(enclave.asked.count, 1)
        XCTAssertEqual(store.state, .unlocked)
    }

    func testCancelLeavesThePasswordFieldAndTheSeal() async throws {
        let (_, store, door) = door()
        await unlockAndSeal(door)
        enclave.cancels = true

        await store.lock()
        try await turn()

        XCTAssertEqual(enclave.asked.count, 1)
        XCTAssertEqual(store.state, .locked)
        XCTAssertNil(store.refusal)
        XCTAssertTrue(door.hasSeal)
        XCTAssertEqual(try files().count, 2)

        // Nothing raises it a second time by itself, and a wrong password
        // does not either.
        door.raiseFingerIfOwed()
        await door.unlock(with: SecretBytes("not-the-password")).value
        try await turn()
        XCTAssertEqual(enclave.asked.count, 1)

        // The fingerprint in the field still does.
        enclave.cancels = false
        await door.askForFinger().value
        XCTAssertEqual(store.state, .unlocked)
    }

    /// A master password changed in the web vault: the engine refuses the
    /// one that comes out of the seal, as it would a wrong one typed.
    func testAPasswordTheEngineRefusesDeletesTheSealAndAsksForTheNewOne() async throws {
        let (backend, store, door) = door(inFront: { false })
        await unlockAndSeal(door)
        await store.lock()
        backend.changePassword(to: "the-new-password")

        await door.askForFinger().value

        XCTAssertEqual(store.state, .locked)
        XCTAssertFalse(door.hasSeal)
        XCTAssertTrue(try files().isEmpty)
        XCTAssertEqual(store.refusal, VaultStore.keptPasswordRefused,
                       "nobody typed a password, so the sentence for a wrong one would be a lie")

        // The new one opens it and is sealed, unasked.
        await door.unlock(with: SecretBytes("the-new-password")).value
        XCTAssertNil(store.refusal)
        XCTAssertFalse(door.isOfferingFinger)
        XCTAssertTrue(door.hasSeal)
        await store.lock()
        await door.askForFinger().value
        XCTAssertEqual(store.state, .unlocked)
    }

    /// Another fingerprint enrolled, or one taken away, and the seal is of
    /// no use to anyone (D7): it is deleted as the lock screen comes up,
    /// with no sheet, and the password is typed.
    func testAChangedSetOfFingerprintsDeletesTheSealAtTheLockScreen() async throws {
        let (backend, store, door) = door()
        await unlockAndSeal(door)
        enclave.enrolAnotherFinger()

        await store.lock()
        try await turn()

        XCTAssertTrue(enclave.asked.isEmpty, "a sheet was raised for a seal no finger opens")
        XCTAssertEqual(store.state, .locked)
        XCTAssertFalse(door.hasSeal)
        XCTAssertTrue(try files().isEmpty)
        XCTAssertFalse(backend.isOpen)
        await door.askForFinger().value
        XCTAssertEqual(store.state, .locked, "something other than the password opened it")

        // Sealed again under the fingers enrolled now.
        await door.unlock(with: SecretBytes(DemoVault.password)).value
        XCTAssertTrue(door.hasSeal)
        await store.lock()
        try await turn()
        XCTAssertEqual(store.state, .unlocked)
    }

    /// Only a password the engine says is wrong, or an account that is
    /// gone, deletes the seal. Every other way an unlock fails says
    /// nothing of the password, and the next finger may open it.
    func testAnEngineThatOnlyFailedKeepsTheSeal() async throws {
        let failures: [VaultError] = [.timeout, .transport, .locked, .turnedAway(403),
                                      .refused("mac failed."), .refused("")]
        for failure in failures {
            let (backend, store, door) = door(inFront: { false })
            await unlockAndSeal(door)
            await store.lock()
            backend.refusal = failure

            await door.askForFinger().value

            XCTAssertNotEqual(store.state, .unlocked, "\(failure)")
            XCTAssertTrue(door.hasSeal, "\(failure)")
            XCTAssertEqual(try files().count, 2, "\(failure)")
            XCTAssertNotEqual(store.refusal, VaultStore.keptPasswordRefused, "\(failure)")

            backend.refusal = nil
            if store.state != .locked { await store.refresh() }
            await door.askForFinger().value
            XCTAssertEqual(store.state, .unlocked, "the finger after \(failure)")
            await store.lock(forget: true)
            seal().forget()
        }
    }

    func testAnAccountThatIsGoneDeletesTheSeal() async throws {
        let (backend, store, door) = door(inFront: { false })
        await unlockAndSeal(door)
        await store.lock()
        backend.refusal = .loggedOut

        await door.askForFinger().value

        XCTAssertEqual(store.state, .loggedOut)
        XCTAssertFalse(door.hasSeal)
        XCTAssertTrue(try files().isEmpty)
    }

    // MARK: Through the door, over a child

    /// The same door over `ServeBackend` and the stand-in, whose next
    /// child can be told to be another one.
    private func doorOverAChild() throws -> (StandIn, VaultStore, Door) {
        let standIn = try StandIn(["password": DemoVault.password])
        let store = VaultStore(backend: ServeBackend(preferredPath: standIn.binary.path, runDirectory: standIn.run,
                                                     dataDirectory: standIn.data, deadline: 5))
        return (standIn, store, Door(store: store, seal: seal(), defaults: defaults, isInFront: { false }))
    }

    /// A `bw` that exits as it starts, with a sentence that is not about
    /// the account: `ServeBackend` hands that on as a refusal, as it does
    /// a wrong password, and it is not one.
    func testAChildThatExitsAtStartUnderAFingerKeepsTheSeal() async throws {
        let (standIn, store, door) = try doorOverAChild()
        await unlockAndSeal(door)
        XCTAssertEqual(store.state, .unlocked)
        await store.lock()
        try standIn.change(["dies": "Error: Cannot find module 'node:sqlite'"])

        await door.askForFinger().value

        XCTAssertEqual(store.state, .locked)
        XCTAssertEqual(store.refusal, "Error: Cannot find module 'node:sqlite'")
        XCTAssertTrue(door.hasSeal)
        XCTAssertEqual(try files().count, 2)

        // The same seal opens the vault once `bw` starts again.
        try standIn.change(["dies": ""])
        await door.askForFinger().value
        XCTAssertEqual(store.state, .unlocked)
        await store.lock()
    }

    func testAChildThatTurnsTheAppAwayUnderAFingerKeepsTheSeal() async throws {
        let (standIn, store, door) = try doorOverAChild()
        await unlockAndSeal(door)
        await store.lock()
        try standIn.change(["host": "elsewhere:1"])

        await door.askForFinger().value

        XCTAssertEqual(store.state, .failed(VaultError.turnedAwaySentence(403)))
        XCTAssertEqual(try files().count, 2)
        XCTAssertTrue(try seal().unseal().matches(SecretBytes(DemoVault.password)))
    }

    func testAChildThatNeverAnswersTheUnlockUnderAFingerKeepsTheSeal() async throws {
        let standIn = try StandIn(["password": DemoVault.password])
        let store = VaultStore(backend: ServeBackend(preferredPath: standIn.binary.path, runDirectory: standIn.run,
                                                     dataDirectory: standIn.data, deadline: 0.5))
        let door = Door(store: store, seal: seal(), defaults: defaults, isInFront: { false })
        await unlockAndSeal(door)
        await store.lock()
        try standIn.change(["deaf": true])

        await door.askForFinger().value

        XCTAssertNotEqual(store.state, .unlocked)
        XCTAssertNotEqual(store.state, .locked, "a timeout is not a refusal")
        XCTAssertEqual(try files().count, 2)
        // Nobody awaits the stop of a child whose connection was lost.
        let gone = await eventually(within: 3) { standIn.left.isEmpty }
        XCTAssertTrue(gone, "the child that did not answer was left running")
    }

    func testAChildThatRefusesTheKeptPasswordDeletesTheSeal() async throws {
        let (standIn, store, door) = try doorOverAChild()
        await unlockAndSeal(door)
        await store.lock()
        try standIn.change(["password": "the-new-password"])

        await door.askForFinger().value

        XCTAssertEqual(store.state, .locked)
        XCTAssertEqual(store.refusal, VaultStore.keptPasswordRefused)
        XCTAssertFalse(door.hasSeal)
        XCTAssertTrue(try files().isEmpty)
    }

    func testASealOfFourteenDaysIsDeletedAndOnlyThePasswordOpensTheVault() async throws {
        let (backend, store, door) = door()
        await unlockAndSeal(door)
        let asked = enclave.asked.count

        clock = clock.addingTimeInterval(days(14))
        await store.lock()
        try await turn()

        XCTAssertEqual(enclave.asked.count, asked, "a sheet was raised for an expired seal")
        XCTAssertEqual(store.state, .locked)
        XCTAssertFalse(door.hasSeal)
        XCTAssertTrue(try files().isEmpty)
        XCTAssertFalse(backend.isOpen)
        await door.askForFinger().value
        XCTAssertEqual(enclave.asked.count, asked)
        XCTAssertEqual(store.state, .locked, "something other than the password opened it")
        await door.unlock(with: SecretBytes(DemoVault.password)).value
        XCTAssertEqual(store.state, .unlocked)
    }

    func testAtThirteenDaysTheFingerStillOpens() async throws {
        let (_, store, door) = door(inFront: { false })
        await unlockAndSeal(door)
        await store.lock()

        clock = clock.addingTimeInterval(days(13))
        await door.askForFinger().value

        XCTAssertEqual(store.state, .unlocked)
    }

    /// Lock and Forget is enabled whenever there is a seal, an opening
    /// vault included. The password that was opening it is not sealed
    /// again behind the command that exists to leave none.
    func testLockAndForgetWhileTheVaultIsOpeningLeavesNoSealAndNoOpenVault() async throws {
        let (backend, store, door) = door()
        await unlockAndSeal(door)
        await store.lock()
        XCTAssertTrue(door.hasSeal)

        backend.delay = 0.2
        let opening = door.unlock(with: SecretBytes(DemoVault.password))
        try await turn(0.05)
        XCTAssertEqual(store.state, .unlocking)
        await door.lockAndForget()
        await opening.value
        try await turn(0.3)

        XCTAssertEqual(store.state, .locked)
        XCTAssertNil(door.panes)
        XCTAssertFalse(backend.isOpen)
        XCTAssertFalse(door.hasSeal)
        XCTAssertTrue(try files().isEmpty, "the password was sealed again after Lock and Forget")
    }

    func testAfterLockAndForgetOnlyThePasswordOpensTheVault() async throws {
        let (backend, store, door) = door()
        await unlockAndSeal(door)
        let asked = enclave.asked.count

        await door.lockAndForget()
        try await turn()

        XCTAssertEqual(store.state, .locked)
        XCTAssertFalse(door.hasSeal)
        XCTAssertTrue(try files().isEmpty)
        XCTAssertEqual(backend.count(of: "endSession"), 1, "the engine dropped its session before it went")
        XCTAssertFalse(backend.isOpen)
        await door.askForFinger().value
        XCTAssertEqual(enclave.asked.count, asked)
        XCTAssertEqual(store.state, .locked, "something other than the password opened it")

        // Touch ID is still wanted, so the next password seals again.
        await door.unlock(with: SecretBytes(DemoVault.password)).value
        XCTAssertFalse(door.isOfferingFinger)
        XCTAssertTrue(door.hasSeal)
    }
}
