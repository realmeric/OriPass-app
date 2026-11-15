import Foundation

/// Everything the account left on this phone, gone: the vault file, the
/// account record, the recents, the sync's marks, the tokens and the key
/// in the keychain, the site icons and every identity iOS keeps for the
/// keyboard. The install's device id stays, as Bitwarden's apps keep theirs,
/// so that signing in again is not a new device that wants an emailed code.
enum SignOut {
    static func wipe(keychain: Keychain = .app, defaults: UserDefaults? = UserDefaults(suiteName: Shared.appGroup)) async {
        VaultFile.forget()
        Account.forget()
        Recents.forget()
        if let trace = Shared.container?.appending(path: "trace.log") { try? FileManager.default.removeItem(at: trace) }
        defaults?.removeObject(forKey: "revision")
        defaults?.removeObject(forKey: "synced")
        let device = try? keychain.read("device")
        keychain.deleteAll()
        if let device { try? keychain.write(device, as: "device") }
        await IconStore.shared.forget()
        await IdentityStore.empty()
    }
}
