import AuthenticationServices
import CryptoKit
import Foundation
import XCTest
@testable import OriPass

/// As much CBOR as a test needs to read an attestation back, written here
/// and not shared with what wrote it.
private enum Read: Equatable {
    case int(Int), bytes(Data), text(String), map([Pair])

    struct Pair: Equatable {
        let key: Read
        let value: Read
    }

    static func whole(_ data: Data) throws -> Read {
        var at = data.startIndex
        let read = try next(data, &at)
        XCTAssertEqual(at, data.endIndex, "bytes after the object")
        return read
    }

    static func next(_ data: Data, _ at: inout Data.Index) throws -> Read {
        let first = try XCTUnwrap(data[safe: at])
        at += 1
        let major = first >> 5, low = Int(first & 0x1F)
        func length() throws -> Int {
            switch low {
            case ..<24: return low
            case 24:
                defer { at += 1 }
                return Int(try XCTUnwrap(data[safe: at]))
            case 25:
                defer { at += 2 }
                return Int(try XCTUnwrap(data[safe: at])) << 8 | Int(try XCTUnwrap(data[safe: at + 1]))
            default: throw CocoaError(.coderInvalidValue)
            }
        }
        switch major {
        case 0: return .int(try length())
        case 1: return .int(-1 - (try length()))
        case 2, 3:
            let count = try length()
            let body = data[at..<(at + count)]
            at += count
            return major == 2 ? .bytes(Data(body)) : .text(String(decoding: body, as: UTF8.self))
        case 5:
            return .map(try (0..<(try length())).map { _ in
                let key = try next(data, &at)
                return Pair(key: key, value: try next(data, &at))
            })
        default: throw CocoaError(.coderInvalidValue)
        }
    }

    subscript(key: Read) -> Read? {
        guard case .map(let pairs) = self else { return nil }
        return pairs.first { $0.key == key }?.value
    }

    var data: Data? {
        if case .bytes(let data) = self { return data }
        return nil
    }
}

private extension Data {
    subscript(safe index: Index) -> UInt8? { indices.contains(index) ? self[index] : nil }
}

/// A passkey made through the door, with the test as the provider, and the
/// fake backend or the stand-in behind the store. The door makes the key and
/// nothing else has it. How it gets out of the app is `spike-passkey.py`'s.
@MainActor
final class PasskeyMakingTests: XCTestCase {
    private static let site = "made.oripass.invalid"
    private static let hash = Data(SHA256.hash(data: Data(#"{"type":"webauthn.create","challenge":"canary"}"#.utf8)))
    private static let handle = Data("a person at the site".utf8)
    private static let github = "GitHub"

    private struct Rig {
        let backend: FakeBackend
        let store: VaultStore
        let authoriser: FakeAuthoriser
        let reprompt: Reprompt
        let door: BrowserDoor
    }

    private func rig(change: (JSONValue) -> JSONValue = { $0 }) async -> Rig {
        let vault = DemoVault.objects()
        let backend = FakeBackend(items: vault.items.map(change), folders: vault.folders, password: DemoVault.password)
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        let authoriser = FakeAuthoriser()
        let reprompt = Reprompt(store: store, authoriser: authoriser)
        let door = BrowserDoor(store: store, reprompt: reprompt, preferences: Preferences())
        await store.unlock(password: SecretBytes(DemoVault.password))
        return Rig(backend: backend, store: store, authoriser: authoriser, reprompt: reprompt, door: door)
    }

    private func request(_ fields: [String: Any]) throws -> BridgeRequest {
        var message: [String: Any] = ["v": BridgeWire.version, "type": "make", "rp": Self.site, "user": "kanarya",
                                      "handle": Self.handle.base64EncodedString(),
                                      "hash": Self.hash.base64EncodedString(), "algorithms": [-8, -7]]
        message.merge(fields) { $1 }
        return try XCTUnwrap(BridgeRequest(try JSONSerialization.data(withJSONObject: message)))
    }

    private func make(_ rig: Rig, _ fields: [String: Any] = [:], as caller: BridgeCaller = .autofill) async throws -> BridgeAnswer {
        await rig.door.answer(try request(fields), from: caller)
    }

    private func registration(_ answer: BridgeAnswer) throws -> BridgeRegistration {
        guard case .made(let registration) = answer else {
            XCTFail("the door said \(answer.type)")
            throw CocoaError(.coderInvalidValue)
        }
        return registration
    }

    private func login(_ rig: Rig, named name: String) throws -> Item {
        try XCTUnwrap(rig.store.shelves.all.first { $0.item.name == name }?.item)
    }

    private func refusal(_ answer: BridgeAnswer) -> BridgeRefusal? {
        if case .refused(let reason) = answer { return reason }
        return nil
    }

    private struct Attested {
        let object: Read
        let authenticatorData: Data
        let key: P256.Signing.PublicKey
        let credential: Data
    }

    /// The attestation read as a relying party reads it.
    private func read(_ attestation: Data) throws -> Attested {
        let object = try Read.whole(attestation)
        let data = try XCTUnwrap(object[.text("authData")]?.data)
        let length = Int(data[53]) << 8 | Int(data[54])
        let credential = data[55..<(55 + length)]
        var at = 55 + length
        let cose = try Read.next(data, &at)
        XCTAssertEqual(at, data.count, "nothing follows the key")
        XCTAssertEqual(cose[.int(1)], .int(2), "EC2")
        XCTAssertEqual(cose[.int(3)], .int(-7), "ES256")
        XCTAssertEqual(cose[.int(-1)], .int(1), "P-256")
        let x = try XCTUnwrap(cose[.int(-2)]?.data), y = try XCTUnwrap(cose[.int(-3)]?.data)
        XCTAssertEqual(x.count, 32)
        XCTAssertEqual(y.count, 32)
        let key = try P256.Signing.PublicKey(rawRepresentation: x + y)
        return Attested(object: object, authenticatorData: data, key: key, credential: Data(credential))
    }

    // MARK: On a new login

    func testANewLoginHoldsThePasskey() async throws {
        let rig = await rig()
        let before = rig.store.shelves.all.count
        let made = try registration(try await make(rig))
        XCTAssertEqual(rig.store.shelves.all.count, before + 1)
        let item = try login(rig, named: Self.site)
        XCTAssertEqual(item.login?.username, "kanarya")
        XCTAssertNil(item.login?.password, "a passkey is not a password")
        XCTAssertEqual(item.login?.uris.map(\.uri), ["https://\(Self.site)"])
        let passkeys = Passkey.all(in: item)
        XCTAssertEqual(passkeys.map(\.credentialID), [made.credential])
        XCTAssertEqual(passkeys.first?.relyingParty, Self.site)
        XCTAssertEqual(passkeys.first?.userName, "kanarya")
        XCTAssertEqual(passkeys.first?.userHandle, Self.handle)
        XCTAssertEqual(passkeys.first?.isES256, true)
        XCTAssertEqual(item.login?.passkeysCreated.count, 1)
        XCTAssertNotNil(item.login?.passkeysCreated.first ?? nil, "the date reads as the engine's own would")
    }

    func testTheEntryIsTheThirteenKeysTheEngineKeepsEveryOneAString() async throws {
        let rig = await rig()
        _ = try registration(try await make(rig))
        let sent = try XCTUnwrap(rig.backend.lastCreated?["login"]?["fido2Credentials"]?.array?.first?.object)
        XCTAssertEqual(Set(sent.keys), ["credentialId", "keyType", "keyAlgorithm", "keyCurve", "keyValue", "rpId", "rpName",
                                        "userHandle", "userName", "userDisplayName", "counter", "discoverable", "creationDate"])
        XCTAssertTrue(sent.values.allSatisfy { $0.string != nil }, "docs/notes.md, What an item looks like")
        XCTAssertEqual(sent["counter"]?.string, "0")
        XCTAssertEqual(sent["discoverable"]?.string, "true")
        XCTAssertEqual(sent["keyType"]?.string, "public-key")
        XCTAssertNotNil(sent["credentialId"]?.string.flatMap(UUID.init(uuidString:)))
    }

    func testTheKeyIsPKCS8InTheURLsAlphabetAsOtherClientsRead() async throws {
        let rig = await rig()
        let made = try registration(try await make(rig))
        let entry = try XCTUnwrap(rig.backend.lastCreated?["login"]?["fido2Credentials"]?.array?.first)
        let written = try XCTUnwrap(entry["keyValue"]?.string)
        XCTAssertNil(written.first { "+/=".contains($0) }, "base64url, with no padding")
        var base64 = written.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        let der = try XCTUnwrap(Data(base64Encoded: base64))
        // A SEQUENCE, version 0, and the algorithm: id-ecPublicKey on prime256v1.
        let head = Data([0x30, 0x81, 0x87, 0x02, 0x01, 0x00, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
                         0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
        XCTAssertEqual(der.prefix(head.count), head)
        let key = try P256.Signing.PrivateKey(derRepresentation: der)
        XCTAssertEqual(key.publicKey.rawRepresentation, try read(made.attestation).key.rawRepresentation)
    }

    func testANewLoginIsSentWithNothingTheFormWouldNotHaveSent() async throws {
        let rig = await rig()
        let blank = try await rig.store.blank(.login)
        _ = try registration(try await make(rig))
        let sent = try XCTUnwrap(rig.backend.lastCreated)
        let stripped = sent.setting(["login", "fido2Credentials"], to: .array([]))
        var form = blank
        form.name = Self.site
        guard case .login(var login) = form.payload else { return XCTFail("no login in a blank login") }
        login.username = "kanarya"
        login.uris = [LoginURI(uri: "https://\(Self.site)")]
        form.payload = .login(login)
        XCTAssertTrue(stripped == blank.patched(form), "only the passkey is more than a form would send")
    }

    // MARK: On a login that has one

    func testALoginForTheSiteKeepsItsOtherKeysAndThePasskeyItHad() async throws {
        let rig = await rig { $0["name"]?.string == Self.github ? $0.setting(["keyNobodyModelled"], to: .string("kept")) : $0 }
        let github = try login(rig, named: Self.github)
        let had = try XCTUnwrap(github.raw["login"]?["fido2Credentials"]?.array)
        XCTAssertEqual(had.count, 1)
        let made = try registration(try await make(rig, ["rp": "github.com", "login": github.id]))
        let now = try login(rig, named: Self.github)
        let held = try XCTUnwrap(now.raw["login"]?["fido2Credentials"]?.array)
        XCTAssertEqual(held.count, 2)
        XCTAssertTrue(held[0] == had[0], "the one it had goes back as it came")
        XCTAssertEqual(Passkey.all(in: now).map(\.credentialID).last, made.credential)
        XCTAssertEqual(now.raw["keyNobodyModelled"]?.string, "kept")
        XCTAssertEqual(now.login?.password, github.login?.password)
        XCTAssertEqual(now.login?.username, github.login?.username)
        XCTAssertEqual(now.name, Self.github, "the login is named what it was")
    }

    func testTheObjectSentHasOnlyWhatChanged() async throws {
        let rig = await rig()
        let github = try login(rig, named: Self.github)
        _ = try registration(try await make(rig, ["rp": "github.com", "login": github.id]))
        XCTAssertEqual(rig.backend.count(of: "save"), 1, "one call on the engine")
        let sent = try XCTUnwrap(rig.backend.lastSaved)
        let list = try XCTUnwrap(sent["login"]?["fido2Credentials"]?.array)
        let back = sent.setting(["login", "fido2Credentials"], to: .array(Array(list.dropLast())))
        XCTAssertTrue(back == github.raw, "take the new entry off and it is the object the item was read from")
    }

    func testASecondPasskeyGoesAfterTheFirstAndBothSign() async throws {
        let rig = await rig()
        let first = try registration(try await make(rig))
        let id = try login(rig, named: Self.site).id
        let second = try registration(try await make(rig, ["login": id]))
        XCTAssertEqual(Passkey.all(in: try login(rig, named: Self.site)).map(\.credentialID), [first.credential, second.credential])
        for made in [first, second] {
            let answer = await rig.door.answer(
                .assert(id: made.credential, PasskeyAsk(relyingParty: Self.site, allowed: []), hash: Self.hash), from: .autofill)
            XCTAssertEqual(answer.type, "asserted")
        }
    }

    func testAPasskeyTheLoginGotIsThereForAnEditAfterIt() async throws {
        let rig = await rig()
        let github = try login(rig, named: Self.github)
        _ = try registration(try await make(rig, ["rp": "github.com", "login": github.id]))
        var edited = try login(rig, named: Self.github)
        edited.notes = "changed"
        try await rig.store.apply(.edit(edited), to: github.id)
        XCTAssertEqual(rig.backend.lastSaved?["login"]?["fido2Credentials"]?.array?.count, 2)
        XCTAssertEqual(Passkey.all(in: try login(rig, named: Self.github)).count, 2)
    }

    func testAFormOpenedBeforeThePasskeyCameDoesNotPutTheOldObjectBack() async throws {
        let rig = await rig()
        var form = try login(rig, named: Self.github)
        _ = try registration(try await make(rig, ["rp": "github.com", "login": form.id]))
        form.notes = "changed"
        do {
            try await rig.store.apply(.edit(form), to: form.id)
            XCTFail("the form held the object from before the passkey")
        } catch {
            XCTAssertTrue(error is ItemChangedElsewhere)
        }
    }

    // MARK: The answer

    func testAnAssertionMadeAfterwardsVerifiesAgainstThePublicKeyTheRegistrationHandedBack() async throws {
        let rig = await rig()
        let made = try registration(try await make(rig))
        let attested = try read(made.attestation)
        XCTAssertEqual(attested.credential, made.credential)

        let ask = PasskeyAsk(relyingParty: Self.site, allowed: [])
        guard case .logins(_, let listed) = await rig.door.answer(.passkeys(ask), from: .autofill) else {
            return XCTFail("no list")
        }
        XCTAssertEqual(listed.map(\.id), [made.credential.base64EncodedString()])

        let challenge = Data(SHA256.hash(data: Data(#"{"type":"webauthn.get"}"#.utf8)))
        guard case .asserted(let assertion) = await rig.door.answer(.assert(id: made.credential, ask, hash: challenge), from: .autofill) else {
            return XCTFail("no assertion")
        }
        XCTAssertEqual(assertion.credential, made.credential)
        XCTAssertEqual(assertion.userHandle, Self.handle)
        XCTAssertEqual(assertion.authenticatorData.prefix(32), attested.authenticatorData.prefix(32), "the one relying party")
        let signature = try P256.Signing.ECDSASignature(derRepresentation: assertion.signature)
        XCTAssertTrue(attested.key.isValidSignature(signature, for: assertion.authenticatorData + challenge))
    }

    func testTheAttestationIsNoneInTheFormARegistrationCredentialCarries() async throws {
        let rig = await rig()
        let made = try registration(try await make(rig))
        let attested = try read(made.attestation)
        XCTAssertEqual(attested.object[.text("fmt")], .text("none"))
        XCTAssertEqual(attested.object[.text("attStmt")], .map([]))
        guard case .map(let pairs) = attested.object else { return XCTFail("not a map") }
        XCTAssertEqual(pairs.map(\.key), [.text("fmt"), .text("attStmt"), .text("authData")], "three keys, in CTAP's order")

        let data = attested.authenticatorData
        XCTAssertEqual(data.prefix(32), Data(SHA256.hash(data: Data(Self.site.utf8))))
        XCTAssertEqual(data[32], 0x5D, "present, verified, eligible, backed up, and a key follows")
        XCTAssertEqual(data[33..<37], Data(count: 4), "the counter starts at nothing")
        XCTAssertEqual(data[37..<53], Data(count: 16), "`none` names no maker")
        XCTAssertEqual(data[53..<55], Data([0, 16]), "a GUID's sixteen bytes")

        let credential = ASPasskeyRegistrationCredential(relyingParty: Self.site, clientDataHash: Self.hash,
                                                         credentialID: made.credential, attestationObject: made.attestation)
        XCTAssertEqual(credential.attestationObject, made.attestation)
        XCTAssertEqual(credential.credentialID, made.credential)
        XCTAssertEqual(try Read.whole(credential.attestationObject)[.text("fmt")], .text("none"))
    }

    func testAnAnswerHoldsNoKey() async throws {
        let rig = await rig()
        let answer = try await make(rig)
        _ = try registration(answer)
        let entry = try XCTUnwrap(rig.backend.lastCreated?["login"]?["fido2Credentials"]?.array?.first)
        let key = try XCTUnwrap(entry["keyValue"]?.string)
        let body = try JSONSerialization.jsonObject(with: answer.body) as? [String: Any]
        XCTAssertEqual(body?["type"] as? String, "made")
        XCTAssertEqual(Set((body?["registration"] as? [String: Any] ?? [:]).keys), ["credential", "attestation"])
        XCTAssertFalse(String(decoding: answer.body, as: UTF8.self).contains(key))
        XCTAssertFalse(String(decoding: answer.body, as: UTF8.self).contains("keyValue"))
    }

    func testAKeyIsNeverMadeTwice() async throws {
        let rig = await rig()
        let one = try registration(try await make(rig))
        let two = try registration(try await make(rig, ["rp": "other.oripass.invalid"]))
        XCTAssertNotEqual(one.credential, two.credential)
        XCTAssertNotEqual(try read(one.attestation).key.rawRepresentation, try read(two.attestation).key.rawRepresentation)
    }

    // MARK: Who says

    func testEveryPasskeyTakesAFingerWhateverTheItemSays() async throws {
        let rig = await rig { $0["name"]?.string == Self.github ? $0.setting(["reprompt"], to: .int(0)) : $0 }
        let github = try login(rig, named: Self.github)
        XCTAssertFalse(rig.reprompt.asks(about: github))
        _ = try registration(try await make(rig))
        _ = try registration(try await make(rig, ["rp": "github.com", "login": github.id]))
        XCTAssertEqual(rig.authoriser.asked, [.makePasskey, .makePasskey])
    }

    func testAnItemThatAsksHasOneQuestion() async throws {
        let rig = await rig()
        let github = try login(rig, named: Self.github)
        XCTAssertTrue(rig.reprompt.asks(about: github), "the demo's GitHub asks")
        _ = try registration(try await make(rig, ["rp": "github.com", "login": github.id]))
        XCTAssertEqual(rig.authoriser.asked, [.makePasskey], "that touch stands for the item as well")
        XCTAssertFalse(rig.reprompt.asks(about: github))
    }

    func testARefusedFingerMakesNothing() async throws {
        let rig = await rig()
        rig.authoriser.answer = false
        let github = try login(rig, named: Self.github)
        let before = rig.store.shelves.all.count
        let onNew = try await make(rig)
        let onOld = try await make(rig, ["rp": "github.com", "login": github.id])
        XCTAssertEqual(refusal(onNew), .declined)
        XCTAssertEqual(refusal(onOld), .declined)
        XCTAssertEqual(rig.backend.count(of: "save") + rig.backend.count(of: "create"), 0)
        XCTAssertEqual(rig.store.shelves.all.count, before)
    }

    func testALockUnderTheQuestionWritesNothing() async throws {
        let rig = await rig()
        rig.authoriser.holds = true
        async let answer = rig.door.answer(try request([:]), from: .autofill)
        while rig.authoriser.asked.isEmpty { await Task.yield() }
        await rig.store.lock()
        let said = try await answer
        XCTAssertEqual(refusal(said), .declined)
        XCTAssertEqual(rig.backend.count(of: "create"), 0)
    }

    func testAShutVaultAnswersNothing() async throws {
        let rig = await rig()
        await rig.store.lock()
        let said = try await make(rig)
        XCTAssertEqual(said.type, "locked")
        XCTAssertTrue(rig.authoriser.asked.isEmpty)
    }

    func testALockWhileTheEngineIsWritingIsNoRegistration() async throws {
        let rig = await rig()
        rig.backend.delay = 0.2
        async let answer = rig.door.answer(try request([:]), from: .autofill)
        while rig.backend.count(of: "create") == 0 { try await Task.sleep(for: .milliseconds(5)) }
        await rig.store.lock()
        let said = try await answer
        XCTAssertEqual(said.type, "locked", "the site is told nothing it could not use")
    }

    func testNoCallerButTheProviderIsAnswered() async throws {
        let rig = await rig()
        for caller in [BridgeCaller.host, .safari] {
            let said = try await make(rig, as: caller)
            let homes = await rig.door.answer(.homes(relyingParty: "github.com"), from: caller)
            XCTAssertEqual(refusal(said), .page)
            XCTAssertEqual(refusal(homes), .page)
        }
        XCTAssertTrue(rig.authoriser.asked.isEmpty)
    }

    // MARK: What is refused first

    func testAPageThatWillNotTakeES256IsRefusedBeforeAnyoneIsAsked() async throws {
        let rig = await rig()
        let said = try await make(rig, ["algorithms": [-8, -257]])
        XCTAssertEqual(refusal(said), .page)
        XCTAssertTrue(rig.authoriser.asked.isEmpty)
    }

    func testAPasskeyThePageAlreadyHasIsRefusedBeforeAnyoneIsAsked() async throws {
        let rig = await rig()
        let held = withUnsafeBytes(of: try XCTUnwrap(UUID(uuidString: DemoVault.passkeyCredential)).uuid) { Data($0) }
        let said = try await make(rig, ["rp": "github.com", "excluded": [held.base64EncodedString()]])
        XCTAssertEqual(refusal(said), .excluded)
        XCTAssertTrue(rig.authoriser.asked.isEmpty)
        _ = try registration(try await make(rig, ["excluded": [held.base64EncodedString()]]))
    }

    func testALoginOfAnotherSiteOrNoneOrInTheTrashTakesNothing() async throws {
        let rig = await rig()
        let github = try login(rig, named: Self.github)
        let elsewhere = try await make(rig, ["login": github.id])
        let nobody = try await make(rig, ["login": "no-such-item"])
        XCTAssertEqual(refusal(elsewhere), .page)
        XCTAssertEqual(refusal(nobody), .gone)
        try await rig.store.apply(.delete, to: github.id)
        let trashed = try await make(rig, ["rp": "github.com", "login": github.id])
        XCTAssertEqual(refusal(trashed), .gone)
        XCTAssertTrue(rig.authoriser.asked.isEmpty)
    }

    func testALoginThatWentUnderTheQuestionTakesNothing() async throws {
        let rig = await rig()
        let github = try login(rig, named: Self.github)
        rig.authoriser.holds = true
        async let answer = rig.door.answer(try request(["rp": "github.com", "login": github.id]), from: .autofill)
        while rig.authoriser.asked.isEmpty { await Task.yield() }
        try await rig.store.apply(.delete, to: github.id)
        rig.authoriser.release(true)
        let said = try await answer
        XCTAssertEqual(refusal(said), .gone)
        XCTAssertEqual(rig.backend.count(of: "save"), 0)
    }

    func testARefusedWriteIsSaidAndLeavesTheStoreAsItWas() async throws {
        let rig = await rig()
        let github = try login(rig, named: Self.github)
        rig.backend.refusal = .refused(FakeBackend.outOfDate)
        let said = try await make(rig, ["rp": "github.com", "login": github.id])
        XCTAssertEqual(refusal(said), .unsaved)
        rig.backend.refusal = nil
        XCTAssertEqual(Passkey.all(in: try login(rig, named: Self.github)).count, 1)
    }

    func testAnEngineThatHandsTheItemBackWithoutItIsNotBelieved() async throws {
        let rig = await rig()
        rig.backend.losesPasskeys = true
        let github = try login(rig, named: Self.github)
        let onNew = try await make(rig)
        let onOld = try await make(rig, ["rp": "github.com", "login": github.id])
        XCTAssertEqual(refusal(onNew), .unsaved, "the site is not told of a passkey the vault does not hold")
        XCTAssertEqual(refusal(onOld), .unsaved)
    }

    // MARK: The wire

    func testHomesAreTheSitesLoginsAndNoKey() async throws {
        let rig = await rig()
        guard case .logins(let site, let found) = await rig.door.answer(.homes(relyingParty: "github.com"), from: .autofill) else {
            return XCTFail("no list")
        }
        let github = try login(rig, named: Self.github)
        XCTAssertEqual(site, "github.com")
        XCTAssertEqual(found.map(\.id), [github.id])
        XCTAssertEqual(found.first?.username, github.login?.username)
        let body = String(decoding: BridgeAnswer.logins(site: site, found).body, as: UTF8.self)
        XCTAssertFalse(body.contains(DemoVault.passkey))
    }

    func testAMessageThatCouldNotMakeOneClosesTheConnection() throws {
        func parses(_ fields: [String: Any]) throws -> Bool {
            var message: [String: Any] = ["v": BridgeWire.version, "type": "make", "rp": Self.site,
                                          "handle": Self.handle.base64EncodedString(), "hash": Self.hash.base64EncodedString()]
            message.merge(fields) { $1 }
            return BridgeRequest(try JSONSerialization.data(withJSONObject: message)) != nil
        }
        XCTAssertTrue(try parses([:]))
        XCTAssertFalse(try parses(["rp": ""]), "no relying party")
        XCTAssertFalse(try parses(["hash": Data(count: 31).base64EncodedString()]), "a hash of another length")
        XCTAssertFalse(try parses(["handle": ""]), "a handle of nothing")
        XCTAssertFalse(try parses(["handle": Data(count: 65).base64EncodedString()]), "a handle past WebAuthn's sixty-four")
    }

    func testAMadePasskeyIsRedacted() {
        let order = PasskeyOrder(relyingParty: Self.site, userName: "kanarya", userHandle: Self.handle,
                                 clientDataHash: Self.hash, algorithms: [-7], excluded: [], login: nil)
        let made = MadePasskey(order, key: DemoVault.newPasskeyKey(), at: Date())
        XCTAssertEqual(String(describing: made), "MadePasskey")
        XCTAssertFalse(String(describing: ItemChange.passkey(made)).contains(DemoVault.newPasskey))
        XCTAssertFalse(String(reflecting: made).contains(DemoVault.newPasskey))
        var dumped = ""
        dump(made, to: &dumped)
        XCTAssertFalse(dumped.contains(DemoVault.newPasskey))
    }

    func testTheProviderMakesNoPasskeyUntilTheSpikeHasSaidYes() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AutoFill/CredentialProviderViewController.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(source.contains("forPasskeyRegistration"), "a page making one is answered, with a refusal")
        XCTAssertFalse(source.contains("completeRegistrationRequest"), "OP-76: the card stops at the door until the spike says yes")
    }

    // MARK: Through the engine's own wire

    /// The real `ServeBackend` and `ServeClient` over the stand-in's socket:
    /// what `bw` is handed, and what comes of its answer. What `bw` does
    /// with it is the spike's to say.
    func testThroughTheRealBackendTheStandInIsHandedTheEntryAndItsAnswerSigns() async throws {
        let standIn = try StandIn(["password": "demo"])
        let backend = ServeBackend(preferredPath: standIn.binary.path, runDirectory: standIn.run, dataDirectory: standIn.data)
        let store = VaultStore(backend: backend)
        let authoriser = FakeAuthoriser()
        let door = BrowserDoor(store: store, reprompt: Reprompt(store: store, authoriser: authoriser), preferences: Preferences())
        let opened = await store.unlock(password: SecretBytes("demo"))
        XCTAssertTrue(opened)
        addTeardownBlock { await store.lock() }

        let id = try XCTUnwrap(store.shelves.all.first { $0.item.login?.uris.isEmpty == false }?.id)
        let site = try XCTUnwrap(store.entry(id: id)?.item.login?.uris.first.flatMap { Address.page($0.uri)?.host })
        let hadBefore = store.entry(id: id)?.item.login?.passkeysCreated.count ?? 0
        let said = await door.answer(try request(["rp": site, "login": id]), from: .autofill)
        let made = try registration(said)

        let log = try String(contentsOf: standIn.log, encoding: .utf8)
        let line = try XCTUnwrap(log.split(separator: "\n").last { $0.hasPrefix("PUT /object/item/\(id)") })
        XCTAssertTrue(line.contains("fido2Credentials"))
        XCTAssertTrue(line.contains("credentialId"))
        let saved = try XCTUnwrap(store.shelves.all.first { entry in
            Passkey.all(in: entry.item).contains { $0.credentialID == made.credential }
        })
        XCTAssertEqual(Passkey.all(in: saved.item).count, hadBefore + 1)

        let challenge = Data(SHA256.hash(data: Data("assert".utf8)))
        guard case .asserted(let assertion) = await door.answer(
            .assert(id: made.credential, PasskeyAsk(relyingParty: site, allowed: []), hash: challenge), from: .autofill) else {
            return XCTFail("no assertion")
        }
        let signature = try P256.Signing.ECDSASignature(derRepresentation: assertion.signature)
        XCTAssertTrue(try read(made.attestation).key.isValidSignature(signature, for: assertion.authenticatorData + challenge))
    }
}
