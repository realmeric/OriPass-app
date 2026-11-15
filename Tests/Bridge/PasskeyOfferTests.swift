import Foundation
import XCTest
@testable import OriPass

/// The second exception to D6, behind a list that remembers: the system is
/// never called with the switch off, and with it on it hears three things
/// and is emptied at the lock.
@MainActor
final class PasskeyOfferTests: XCTestCase {
    private struct Rig {
        let store: VaultStore
        let preferences: Preferences
        let list: FakeIdentityList
        let offer: PasskeyOffer
    }

    private func rig(on: Bool) -> Rig {
        let vault = DemoVault.objects()
        let backend = FakeBackend(items: vault.items, folders: vault.folders, password: DemoVault.password)
        backend.lastSync = Date().addingTimeInterval(-60)
        let store = VaultStore(backend: backend)
        let preferences = Preferences()
        preferences.settings.privacy.passkeysInSystemList = on
        let list = FakeIdentityList()
        return Rig(store: store, preferences: preferences, list: list,
                   offer: PasskeyOffer(store: store, preferences: preferences, list: list))
    }

    private func settled(_ rig: Rig) async {
        for _ in 0..<5 {
            await Task.yield()
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        }
        await rig.offer.writing?.value
    }

    func testTheDefaultIsOff() {
        XCTAssertFalse(Settings().privacy.passkeysInSystemList)
    }

    func testWithTheSwitchOffTheSystemIsNeverCalled() async {
        let rig = rig(on: false)
        await settled(rig)
        await rig.store.unlock(password: SecretBytes(DemoVault.password))
        await settled(rig)
        await rig.store.lock()
        await settled(rig)
        XCTAssertEqual(rig.list.calls, 0)
    }

    func testALaunchWithTheSwitchOnEmptiesWhatAKilledRunLeft() async {
        let rig = rig(on: true)
        await settled(rig)
        XCTAssertEqual(rig.list.calls, 1)
        XCTAssertEqual(rig.list.identities, [])
    }

    func testWithItOnTheSystemHearsARelyingPartyAUsernameAndAnIdAndNoSecret() async throws {
        let rig = rig(on: true)
        await rig.store.unlock(password: SecretBytes(DemoVault.password))
        await settled(rig)
        // It has these three and no room for a fourth, and a key would have
        // to be in one of them.
        let id = withUnsafeBytes(of: UUID(uuidString: DemoVault.passkeyCredential)!.uuid) { Data($0) }
        XCTAssertEqual(rig.list.identities, [PasskeyIdentity(relyingParty: "github.com", userName: "deniz", credentialID: id)])
        XCTAssertEqual(id.count, 16)
        XCTAssertEqual("\(try XCTUnwrap(rig.list.identities.first))", "PasskeyIdentity")
    }

    func testTheLockEmptiesIt() async {
        let rig = rig(on: true)
        await rig.store.unlock(password: SecretBytes(DemoVault.password))
        await settled(rig)
        XCTAssertFalse(rig.list.identities.isEmpty)
        await rig.store.lock()
        await settled(rig)
        XCTAssertEqual(rig.list.identities, [])
    }

    func testTheLockIsWrittenInItsOwnTurnWithTheStoreStillFull() async {
        let rig = rig(on: true)
        await rig.store.unlock(password: SecretBytes(DemoVault.password))
        await settled(rig)
        let before = rig.list.calls
        NotificationCenter.default.post(name: VaultStore.willLock, object: rig.store)
        await rig.offer.writing?.value
        XCTAssertEqual(rig.list.calls, before + 1)
        XCTAssertEqual(rig.list.identities, [])
    }

    func testAQuitTakesItOutWithTheVaultStillOpen() async {
        let rig = rig(on: true)
        await rig.store.unlock(password: SecretBytes(DemoVault.password))
        await settled(rig)
        await rig.offer.quit()
        XCTAssertEqual(rig.list.identities, [])
    }

    func testTheSwitchThrownOnAndOffFollowsItWithTheVaultOpen() async {
        let rig = rig(on: false)
        await rig.store.unlock(password: SecretBytes(DemoVault.password))
        await settled(rig)
        XCTAssertEqual(rig.list.calls, 0)
        rig.preferences.settings.privacy.passkeysInSystemList = true
        await settled(rig)
        XCTAssertEqual(rig.list.identities.count, 1)
        rig.preferences.settings.privacy.passkeysInSystemList = false
        await settled(rig)
        XCTAssertEqual(rig.list.identities, [])
    }

    func testTheSameListIsNotWrittenTwice() async {
        let rig = rig(on: true)
        await rig.store.unlock(password: SecretBytes(DemoVault.password))
        await settled(rig)
        let calls = rig.list.calls
        await rig.store.refresh()
        await settled(rig)
        XCTAssertEqual(rig.list.calls, calls)
    }

    /// The name of the system's store is in this file and in no other that
    /// goes into a target, and the provider does not hold that file.
    func testOnlyTheOfferNamesTheSystemsStore() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        let provider = try XCTUnwrap(project.components(separatedBy: "  OriPassAutoFill:\n").last)
            .components(separatedBy: "    info:").first
        XCTAssertFalse(try XCTUnwrap(provider).contains("Sources/Bridge/Passkey"))
        XCTAssertTrue(try XCTUnwrap(provider).contains("- path: Sources/AutoFill\n"))
    }
}
