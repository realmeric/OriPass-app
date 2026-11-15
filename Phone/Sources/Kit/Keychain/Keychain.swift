import Foundation
import LocalAuthentication
import Security

/// The app's and the extension's keychain items, in the group they share.
/// Each item is a generic password under one service, named by its account.
struct Keychain: Sendable {
    let service: String

    static let app = Keychain(service: "com.meric.oripass")

    enum Protection: Sendable {
        /// Readable after the first unlock since boot, on this phone only.
        case afterFirstUnlock
        /// Readable only while the phone is unlocked, on this phone only.
        case whileUnlocked
        /// Readable only after a face enrolled now, on a phone with a
        /// passcode, on this phone only.
        case currentFace
    }

    func write(_ data: Data, as account: String, protection: Protection = .afterFirstUnlock) throws {
        delete(account)
        var query = base(account)
        query[kSecValueData] = data
        switch protection {
        case .afterFirstUnlock:
            query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        case .whileUnlocked:
            query[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        case .currentFace:
            var error: Unmanaged<CFError>?
            guard let control = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, &error
            ) else { throw KeychainError(status: errSecParam) }
            query[kSecAttrAccessControl] = control
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// Nil when there is no such item. An item behind a face asks for one
    /// with `context`'s reason, and fails when it is refused.
    func read(_ account: String, context: LAContext? = nil) throws -> Data? {
        var query = base(account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        if let context { query[kSecUseAuthenticationContext] = context }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return result as? Data
    }

    /// Whether an item is there, asking nobody for a face.
    func holds(_ account: String) -> Bool {
        var query = base(account)
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext] = context
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    func delete(_ account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }

    func deleteAll() {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                       kSecAttrAccessGroup: Shared.keychainGroup] as CFDictionary)
    }

    private func base(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
         kSecAttrAccessGroup: Shared.keychainGroup, kSecUseDataProtectionKeychain: true]
    }
}

struct KeychainError: Error, Equatable {
    let status: OSStatus

    var refused: Bool { status == errSecUserCanceled || status == errSecAuthFailed }
}
