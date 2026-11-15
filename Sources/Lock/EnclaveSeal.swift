import CryptoKit
import Foundation
import LocalAuthentication

/// A few bytes sealed to a key that lives in this Mac's Secure Enclave and
/// answers only to a finger (D7).
///
/// Sealing needs the key's public half and asks for nothing. Opening asks the
/// enclave for the key agreement, and the enclave raises the Touch ID sheet.
/// The key is made under `biometryCurrentSet`, so enrolling another fingerprint
/// kills it, and no keychain is involved: the enclave hands back a blob only
/// this Mac can use, and it is kept in a file. That is why this works with no
/// entitlement and no provisioning profile (`docs/notes.md`, "A finger without
/// a provisioning profile").
struct EnclaveSeal: Equatable {
    /// The enclave key, as the enclave wrapped it. Useless on any other Mac.
    let key: Data
    /// HPKE's encapsulated key, the sender's half of the agreement.
    let encapsulated: Data
    let box: Data

    private static let suite = HPKE.Ciphersuite.P256_SHA256_AES_GCM_256
    private static let info = Data("com.meric.oripass.seal".utf8)

    /// `plain` is not hidden and is not kept here. It is bound to the box, so
    /// the same bytes have to be handed to `open`, and whoever keeps a date
    /// beside a seal cannot have it moved under them.
    static func seal<Secret: DataProtocol>(_ secret: Secret,
                                           authenticating plain: Data = Data()) throws -> EnclaveSeal {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet], &error
        ) else {
            throw error?.takeRetainedValue() ?? CocoaError(.coderInvalidValue) as Error
        }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        var sender = try HPKE.Sender(recipientKey: key.publicKey, ciphersuite: suite, info: info)
        let box = try sender.seal(secret, authenticating: plain)
        return EnclaveSeal(key: key.dataRepresentation,
                           encapsulated: sender.encapsulatedKey, box: box)
    }

    /// Blocks on the finger, so never from the main thread. It is asked for
    /// on the Touch ID sheet, or in the `LAAuthenticationView` paired with
    /// `context` if there is one, and no sheet then (`docs/notes.md`, "A
    /// finger without a provisioning profile"). Invalidating `context` from
    /// another thread ends either.
    func open(authenticating plain: Data = Data(), reason: String, context: LAContext = LAContext()) throws -> Data {
        context.localizedReason = reason
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(
            dataRepresentation: key, authenticationContext: context
        )
        var recipient = try HPKE.Recipient(privateKey: key, ciphersuite: Self.suite,
                                           info: Self.info, encapsulatedKey: encapsulated)
        return try recipient.open(box, authenticating: plain)
    }
}
